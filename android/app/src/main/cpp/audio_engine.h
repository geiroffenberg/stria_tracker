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
    bool   sampleLoop        = false;
    float  sampleStartNorm   = 0.0f; // normalized region start [0..1]
    float  sampleEndNorm     = 1.0f; // normalized region end [0..1]
    float  sampleGain        = 1.0f;
};

struct SampleData {
    std::vector<float> mono; // normalized [-1..1]
    int sampleRate = 44100;
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
    /// note: 0-127 MIDI, -1 = hold/empty, -2 = note off.
    /// volume: 0-255 sets voice level, -1 = no change.
    /// pan: 0-255 sets stereo position, -1 = no change.
    /// wave: 0=sine,1=tri,2=saw,3=square,4=pulse,5=noise.
    /// cutoff/resonance/filterAttack/filterDecay/filterSustain/filterRelease/
    /// filterEnvAmt/attack/decay/sustain/release/glide/instVol:
    /// 0-255 mapped from instrument params.
    /// Legacy stride-4 packets are still accepted.
    void triggerRow(const std::vector<int>& rowData);

    /// Assign a sample file to an instrument slot for sampler playback.
    /// Pass empty path to clear assignment.
    bool setSamplerSample(int slot, const std::string& path);

    // oboe::AudioStreamDataCallback
    oboe::DataCallbackResult onAudioReady(
        oboe::AudioStream* stream,
        void*              audioData,
        int32_t            numFrames) override;

private:
    oboe::ManagedStream              mStream;
    bool                             mStarted = false;
    std::atomic<double>              mBpm{120.0};
    std::mutex                       mVoiceMutex;
    std::array<Voice, kMaxVoices>    mVoices{};
    std::array<SampleData, 16>       mSamplerSlots{};

    bool loadWavMono16OrFloat(const std::string& path, SampleData& outSample);

    static double midiToFreq(int note) {
        return 440.0 * std::pow(2.0, (note - 69) / 12.0);
    }
};
