#pragma once

#include <oboe/Oboe.h>
#include <vector>
#include <array>
#include <atomic>
#include <mutex>
#include <cmath>
#include <cstdint>
#include <string>

static constexpr int kMaxVoices = 8; // one per track

enum class EnvelopeStage : int {
    Idle = 0,
    Attack,
    Decay,
    Sustain,
    Release,
};

/// Per-voice state for the sine synthesiser.
struct Voice {
    int    midiNote   = -1;    // -1 = unused
    int    waveform   = 0;     // 0=sine,1=tri,2=saw,3=square,4=pulse,5=noise
    double phase      = 0.0;
    float  level      = 0.808f; // default from UI VL=80 on 0..99 scale
    float  pan        = 0.505f; // default from UI PAN=50 on 0..99 scale
    float  panTarget  = 0.505f; // target pan [0..1]
    float  gain       = 0.0f;  // current smoothed amplitude
    float  gainTarget = 0.0f;  // 1.0 = sustain, 0.0 = silent
    uint32_t noiseState = 0x12345678u;
    int    pendingWaveform   = -1;   // waveform to apply after fade-out (-1 = none)
    float  pendingGainTarget = 0.0f; // gainTarget to restore after waveform swap
    float  instrumentVolume  = 0.8f; // from instrument editor (0..1)
    float  detuneNorm        = 0.5f; // 0..1 mapped to -12..+12 semitones (0.5 = 0)
    float  currentFreq       = 0.0f; // Hz, slewed toward targetFreq for glide
    float  targetFreq        = 0.0f; // Hz from current midi note
    float  glideSec          = 0.0f; // 0 = instant, >0 = portamento time
    float  cutoffNorm        = 0.7f; // 0..1 filter cutoff control
    float  resonanceNorm     = 0.2f; // 0..1 filter resonance control
    int    filterMode        = 0;    // 0=LP, 1=HP, 2=BP
    float  filterEnvLevel    = 0.0f; // filter ADSR output (0..1)
    EnvelopeStage filterEnvStage = EnvelopeStage::Idle;
    float  filterAttackSec   = 0.01f;
    float  filterDecaySec    = 0.25f;
    float  filterSustainLevel = 0.0f;
    float  filterReleaseSec  = 0.25f;
    float  filterEnvAmt      = 0.5f; // 0..1 depth added to base cutoff
    float  filterLow         = 0.0f; // state-variable lowpass state
    float  filterBand        = 0.0f; // state-variable bandpass state
    float  envLevel          = 0.0f; // ADSR output (0..1)
    EnvelopeStage envStage   = EnvelopeStage::Idle;
    bool   noteHeld          = false;
    float  attackSec         = 0.01f;
    float  decaySec          = 0.20f;
    float  sustainLevel      = 0.80f;
    float  releaseSec        = 0.25f;
    // LFO
    double lfoPhase          = 0.0;  // radians, accumulated per sample
    float  lfoRateNorm       = 0.2f; // 0..1 → 0.1..20 Hz
    float  lfoDepth          = 0.0f; // 0..1
    int    lfoTarget         = 0;    // 0=pitch, 1=filter, 2=amp
    // Drive / saturation
    float  drive             = 0.0f; // 0..1

    // Sampler playback state
    bool   samplerMode       = false;
    bool   sampleActive      = false;
    int    sampleSlot        = -1;
    double samplePos         = 0.0;
    double sampleStep        = 1.0;
    int    loopMode          = 0;    // 0=off 1=forward 2=ping-pong
    bool   samplePingDir     = false; // false=forward true=backward (ping-pong or reverse)
    bool   sampleReverse     = false; // true = REV FX: play region backward from end
    double sampleElapsedFrames = 0.0; // frames played since note-on (for attack/release)
    float  sampleStartNorm   = 0.0f;
    float  sampleEndNorm     = 1.0f;
    float  sampleGain        = 1.0f;
};

struct SampleData {
    std::vector<float> mono; // normalized [-1..1]
    int sampleRate = 44100;
};

/// A pending retrigger event scheduled at a specific sample offset from row start.
/// Queued via queueRetrigs() and fired sample-accurately inside onAudioReady().
struct RetrigEvent {
    int32_t sampleTarget; ///< fire when mSubRowSampleCounter >= this value
    int     trackIdx;     ///< voice index (0-based track)
    int     note;         ///< MIDI note 0-127
    int     volume;       ///< 0-255 voice level, -1 = no change
};

/// A pending pitch-only ARP event scheduled at a sample offset from row start.
struct ArpEvent {
    int32_t sampleTarget; ///< fire when mSubRowSampleCounter >= this value
    int     trackIdx;     ///< voice index (0-based track)
    int     note;         ///< MIDI note 0-127
};

/// A pending delayed note-on event (DEL) scheduled at a sample offset.
struct DelayEvent {
    int32_t sampleTarget; ///< fire when mSubRowSampleCounter >= this value
    int     trackIdx;     ///< voice index (0-based track)
    int     note;         ///< MIDI note 0-127
    int     volume;       ///< 0-255 voice level, -1 = no change
};

/// A pending kill (KIL) event scheduled at a sample offset.
struct KillEvent {
    int32_t sampleTarget; ///< fire when mSubRowSampleCounter >= this value
    int     trackIdx;     ///< voice index (0-based track)
};

/**
 * AudioEngine — polyphonic sine synthesiser via Oboe.
 *
 * Up to kMaxVoices simultaneous voices (one per tracker track).
 * Each voice generates a sine wave at the MIDI-derived frequency.
 * Amplitude is smoothed to avoid clicks on note on/off.
 *
 * TODO: replace std::mutex with a lock-free scheme for real-time safety.
 */
class AudioEngine : public oboe::AudioStreamDataCallback {
public:
    AudioEngine();
    ~AudioEngine() override;

    bool open();
    void start();
    void stop();
    void close();

    void setTempo(double bpm);

    /// Called from the Dart sequencer on each row tick.
    /// packed row data format per track:
    /// [note, volume, pan, wave, cutoff, resonance,
    ///  filterAttack, filterDecay, filterSustain, filterRelease, filterEnvAmt,
    ///  attack, decay, sustain, release, glide, instVol, ...]
    /// note: 0-127 MIDI, -1 = hold/empty, -2 = note off,
    ///       <= -1000 = pitch-only update, midi = -1000 - note.
    /// volume: 0-255 sets voice level, -1 = no change.
    /// pan: 0-255 sets stereo position, -1 = no change.
    /// wave: 0=sine,1=tri,2=saw,3=square,4=pulse,5=noise.
    /// cutoff/resonance/filterAttack/filterDecay/filterSustain/filterRelease/
    /// filterEnvAmt/attack/decay/sustain/release/glide/instVol:
    /// 0-255 mapped from instrument params.
    /// Legacy stride-4 packets are still accepted.
    void triggerRow(const std::vector<int>& rowData);

    /// Kill voices on specific tracks. One entry per track: 1 = kill, 0 = leave.
    void killVoices(const std::vector<int>& killMask);

    /// Queue sample-accurate retrigger events for the current row.
    /// [data] is packed in groups of 4: [sampleOffset, trackIdx, note, volume].
    /// Events fire when the internal sample counter reaches sampleOffset.
    /// All pending events are cleared when triggerRow() is called.
    void queueRetrigs(const std::vector<int>& data);

    /// Queue sample-accurate pitch-only ARP events for the current row.
    /// [data] is packed in groups of 3: [sampleOffset, trackIdx, note].
    /// Events retune the active voice without restarting envelopes.
    /// All pending events are cleared when triggerRow() is called.
    void queueArp(const std::vector<int>& data);

    /// Queue sample-accurate delayed note events for DEL.
    /// [data] is packed in groups of 4: [sampleOffset, trackIdx, note, volume].
    /// All pending events are cleared when triggerRow() is called.
    void queueDelays(const std::vector<int>& data);

    /// Queue sample-accurate kill events for KIL.
    /// [data] is packed in groups of 2: [sampleOffset, trackIdx].
    /// All pending events are cleared when triggerRow() is called.
    void queueKills(const std::vector<int>& data);

    /// Assign a sample file to an instrument slot for sampler playback.
    /// Pass empty path to clear assignment.
    bool setSamplerSample(int slot, const std::string& path);

    /// Start recording mic input to internal buffer
    void startRecording();

    /// Stop recording and return the recorded samples + sample rate
    /// Returns a vector of floats normalized [-1..1]
    std::vector<float> stopRecording(int& outSampleRate);

    /// Called by Oboe's recording callback (input stream audio thread)
    oboe::DataCallbackResult onRecordingAudioReady(
        oboe::AudioStream* stream,
        void*              audioData,
        int32_t            numFrames);

    // oboe::AudioStreamDataCallback (output stream)
    oboe::DataCallbackResult onAudioReady(
        oboe::AudioStream* stream,
        void*              audioData,
        int32_t            numFrames) override;

private:
    // Oboe callback shim for the recording (input) stream.
    // Oboe requires a stable pointer so we heap-allocate it.
    class RecordingCallback : public oboe::AudioStreamDataCallback {
    public:
        explicit RecordingCallback(AudioEngine& e) : mEngine(e) {}
        oboe::DataCallbackResult onAudioReady(
            oboe::AudioStream* stream,
            void*              audioData,
            int32_t            numFrames) override {
            return mEngine.onRecordingAudioReady(stream, audioData, numFrames);
        }
    private:
        AudioEngine& mEngine;
    };

    oboe::ManagedStream              mStream;
    oboe::ManagedStream              mRecordingStream;
    std::unique_ptr<RecordingCallback> mRecordingCallback;
    bool                             mStarted = false;
    std::atomic<double>              mBpm{120.0};
    std::mutex                       mVoiceMutex;
    std::array<Voice, kMaxVoices>    mVoices{};
    std::array<SampleData, 64>       mSamplerSlots{};

    // Sample-accurate retrigger state (protected by mVoiceMutex).
    std::vector<RetrigEvent> mPendingRetrigs;
    std::vector<ArpEvent>    mPendingArp;
    std::vector<DelayEvent>  mPendingDelays;
    std::vector<KillEvent>   mPendingKills;
    int32_t                  mSubRowSampleCounter = 0;

    // Recording state
    std::mutex                       mRecordingMutex;
    std::atomic<bool>                mIsRecording{false};
    std::vector<float>               mRecordingBuffer;
    int                              mRecordingWarmupFrames{0}; // frames to skip at stream open
    static constexpr int             kMaxRecordingFrames  = 44100 * 60; // 60 seconds at 44.1kHz
    static constexpr int             kWarmupFrames        = 4096;       // ~85ms at 48kHz

    bool loadWavMono16OrFloat(const std::string& path, SampleData& outSample);

    static double midiToFreq(int note) {
        return 440.0 * std::pow(2.0, (note - 69) / 12.0);
    }
};
