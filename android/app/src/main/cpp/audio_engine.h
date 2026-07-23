#pragma once

#include <oboe/Oboe.h>
#include <vector>
#include <array>
#include <atomic>
#include <mutex>
#include <cmath>
#include <cstdint>
#include <string>
#include "freeverb.h"

static constexpr int kMaxVoices = 16; // one per track
// Maximum audio callback burst size we pre-allocate for. Real Oboe burst on
// modern Android devices is 96-256 frames; 1024 gives plenty of headroom and
// guarantees we never reallocate buses inside the audio thread.
static constexpr int kMaxAudioBurst = 1024;
// Maximum Karplus-Strong delay line length (matches startKarplusVoice cap).
static constexpr int kMaxKarplusBuf = 8192;

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
    float  currentFreq            = 0.0f; // Hz, slewed toward targetFreq for glide
    float  targetFreq            = 0.0f; // Hz from current midi note
    float  glideSec              = 0.0f; // 0 = instant, >0 = portamento time
    // Linear pitch ramp for SLU/SLD: runs at sample granularity, overrides glideSec slew.
    float  pitchRampFreqPerSample = 0.0f; ///< Hz added per sample (signed)
    int    pitchRampSamplesLeft   = 0;    ///< samples remaining; 0 = ramp inactive
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
    // LFO (VIB FX — pitch/filter/amp modulation)
    double lfoPhase          = 0.0;  // radians, accumulated per sample
    float  lfoRateNorm       = 0.2f; // 0..1 → 0.1..20 Hz
    float  lfoDepth          = 0.0f; // 0..1
    int    lfoTarget         = 0;    // 0=pitch, 1=filter, 2=amp
    // Tremolo/Gate LFO (TRE/GAT FX — independent volume modulation)
    double trePhase          = 0.0;  // radians, accumulated per sample
    float  treSpeedNorm      = 0.0f; // 0..1 → Hz via normToLfoHz
    float  treDepth          = 0.0f; // 0..1
    int    treMode           = 0;    // 0=off, 1=sine (TRE), 2=square (GAT)
    // Drive / saturation
    float  drive             = 0.0f; // 0..1

    // Multi-oscillator
    float  osc1Gain          = 1.0f;  // OSC 1 output gain (0..1)
    bool   osc2On            = false;
    int    osc2Waveform      = 0;
    float  osc2DetuneNorm    = 0.5f;
    float  osc2Gain          = 0.0f;
    float  osc2FmDepth       = 0.0f;  // OSC 2 → FM-modulates OSC 1 (0..1)
    int    osc2Oct           = 0;     // -2..+2 octave offset
    float  osc2OctMult       = 1.0f;  // precomputed 2^osc2Oct
    double osc2Phase         = 0.0;
    bool   osc3On            = false;
    int    osc3Waveform      = 0;
    float  osc3DetuneNorm    = 0.5f;
    float  osc3Gain          = 0.0f;
    float  osc3FmDepth       = 0.0f;  // OSC 3 → FM-modulates OSC 2 (0..1)
    int    osc3Oct           = 0;     // -2..+2 octave offset
    float  osc3OctMult       = 1.0f;  // precomputed 2^osc3Oct
    double osc3Phase         = 0.0;

    // OSC 1 octave
    int    osc1Oct           = 0;     // -2..+2 octave offset
    float  osc1OctMult       = 1.0f;  // precomputed 2^osc1Oct

    // Karplus-Strong plucked-string state
    bool   karplusMode       = false;
    bool   karplusActive     = false;
    float  karplusDecayNorm  = 0.55f;
    float  karplusDampingNorm = 0.62f;
    float  karplusToneNorm   = 0.50f;
    float  karplusStretchNorm = 0.22f;
    float  karplusPickPositionNorm = 0.30f;
    float  karplusAttackColorNorm = 0.48f;
    float  karplusBodyNorm = 0.35f;
    float  karplusDriveNorm = 0.10f;
    std::vector<float> karplusBuf;
    int    karplusPos        = 0;
    float  karplusDispersionState = 0.0f;
    float  karplusBodyState = 0.0f;
    float  karplusBodyState2 = 0.0f;

    // Sampler playback state
    bool   samplerMode       = false;
    bool   sampleActive      = false;
    bool   samplerReleaseActive = false; // true when note-off received, apply release envelope
    bool   sampleHasEnteredLoopRegion = false; // true once pos reaches loopStart
    double samplerReleaseStartFrames = 0.0; // sampleElapsedFrames value when note-off was received
    int    sampleSlot        = -1;
    double samplePos         = 0.0;
    double sampleStep        = 1.0;
    // Linear sampleStep ramp for SLU/SLD on sampler tracks.
    float  sampleStepRampPerSample = 0.0f; ///< sampleStep delta per sample (signed)
    float  sampleStepTarget        = 1.0f; ///< target sampleStep at ramp end
    int    loopMode          = 0;    // 0=off 1=forward 2=ping-pong
    bool   samplePingDir     = false; // false=forward true=backward (ping-pong or reverse)
    bool   sampleReverse     = false; // true = REV FX: play region backward from end
    double sampleElapsedFrames = 0.0; // frames played since note-on (for attack/release)
    float  sampleStartNorm   = 0.0f;
    float  sampleEndNorm     = 1.0f;
    float  loopStartNorm     = 0.0f;  // 0..1 — loop region start (default = full file)
    float  loopEndNorm       = 1.0f;  // 0..1 — loop region end
    float  sampleGain        = 1.0f;

    // Sampler HP -> LP filter (in series). Bypassed entirely when samplerFilterOn == false.
    bool   samplerFilterOn   = false;
    float  samplerHpCutoff   = 0.0f;  // 0..1 (0 = bypass, 1 = closed)
    float  samplerHpRes      = 0.0f;  // 0..1
    float  samplerLpCutoff   = 1.0f;  // 0..1 (0 = closed, 1 = open / bypass)
    float  samplerLpRes      = 0.0f;  // 0..1
    // Chamberlin SVF state (one set per HP and LP, mono path).
    float  samplerHpLow      = 0.0f;
    float  samplerHpBand     = 0.0f;
    float  samplerLpLow      = 0.0f;
    float  samplerLpBand     = 0.0f;

    // Sampler LFO (dedicated, note-synced, BPM-relative). Independent of the
    // synth VIB LFO above. Bypassed entirely (zero CPU) when samplerLfoWave==0.
    int    samplerLfoWave    = 0;    // 0=off,1=sine,2=tri,3=square,4=rampUp,5=rampDown,6=rand
    int    samplerLfoRateIdx = 5;    // index into LFO division table (cycle length)
    int    samplerLfoTargets = 0;    // bitmask: 1=vol, 2=pitch, 4=hp, 8=lp
    int    samplerLfoMode    = 2;    // anchor: 0=center, 1=up, 2=down
    float  samplerLfoDepth   = 0.0f; // 0..1 modulation depth
    double samplerLfoPhase   = 0.0;  // 0..1 normalized phase (accumulated per sample)
    float  samplerLfoRandVal = 0.0f; // current sample-and-hold random value (RND wave)
    float  samplerLfoRandNext = 0.0f; // next random value (for smoothing, unused for now)
    // Slew-limited modulation targets (smooth out volume/pitch/filter clicks)
    float  samplerLfoVolModTarget = 1.0f; // target gain multiplier for volume
    float  samplerLfoVolModCurr   = 1.0f; // current (slewed) value
};

struct SampleData {
    std::vector<float> mono;         // normalized [-1..1] — what the audio callback reads
    std::vector<float> originalMono; // unchanged original (always kept for re-baking)
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

/// A pending slice command (SLC) event scheduled at a sample offset.
/// Sets the sampler playback region boundaries.
struct SliceCommandEvent {
    int32_t sampleTarget;   ///< fire when mSubRowSampleCounter >= this value
    int     trackIdx;       ///< voice index (0-based track)
    int     startNormScaled; ///< normalized start position (0-10000 = 0.0-1.0)
    int     endNormScaled;   ///< normalized end position (0-10000 = 0.0-1.0)
};

/// A pending mixer control command.
/// Controls master/channel parameters like pan, mute, solo, volume.
struct MixerCommandEvent {
    int32_t sampleTarget; ///< fire when mSubRowSampleCounter >= this value (currently 0 = immediate)
    int     channel;      ///< 0=master, 1-16=mixer channels
    int     controller;   ///< 1-4 for pan/mute/solo/volume, 5-9 reserved
    int     value;        ///< 0-99 parameter value
};

/// A pending own-channel insert FX command.
struct InsertFxCommandEvent {
    int32_t sampleTarget; ///< fire when mSubRowSampleCounter >= this value (currently 0 = immediate)
    int     trackIdx;     ///< owning pattern track / channel index
    int     slotIdx;      ///< insert slot index (0-based)
    int     function;     ///< function number (1-9)
    int     value;        ///< 0-99 parameter value
};

struct QueuedPlaybackRow {
    std::vector<int> rowData;
    std::vector<int> immediateKillMask;
    std::vector<int> retrigData;
    std::vector<int> arpData;
    std::vector<int> delayData;
    std::vector<int> killData;
    std::vector<int> sliceCommandData;
    std::vector<int> mixerCommandData;
    std::vector<int> insertFxCommandData;
    /// Linear pitch ramp commands: groups of 3 ints — [trackIdx, targetMidiNote, durationSamples].
    /// Applied at row-fire time to start smooth cent-level slides (SLU/SLD).
    std::vector<int> pitchRampData;
    int32_t lineSamples = 0;
};

/// Effect state for a single insert effect slot
struct InsertEffect {
    int type = -1; // -1=empty, 0=reverb, 1=delay, 2=eq, 3=distortion, etc.
    bool bypass = false;
    float inputGain = 1.0f;  // 0.0-2.0
    float outputGain = 1.0f; // 0.0-2.0
    float dryWet = 0.5f;     // 0.0-1.0
    float dryLevel = 1.0f;   // 0.0-1.0
    float wetLevel = 0.3f;   // 0.0-1.0
    
    // Reverb-specific parameters
    float reverbRoomSize = 0.5f;  // 0.0-1.0
    float reverbDamp = 0.5f;      // 0.0-1.0
    float reverbWidth = 1.0f;     // 0.0-1.0
    bool reverbFreeze = false;

    freeverb::revmodel reverb;

    // Delay-specific parameters
    float delayTimeMs = 375.0f;   // 1–2000 ms (free mode)
    float delayFeedback = 0.4f;   // 0.0–0.95
    float delayHpCutoff = 0.0f;   // 0.0–1.0 (hi-pass; 0 = off)
    bool  delaySync = false;      // true = tempo-sync (not yet used)

    // Delay ring buffer (allocated on first use)
    static constexpr int kDelayMaxSamples = 96001; // ~2 s at 48 kHz
    std::vector<float> delayBufL;
    std::vector<float> delayBufR;
    int   delayWritePos = 0;
    float delayHpPrevL  = 0.0f;   // hi-pass filter state
    float delayHpPrevR  = 0.0f;

    // Filter-specific parameters (type == 2)
    // State-variable filter (SVF)
    float filterCutoff    = 0.5f;  // 0..1 → ~20 Hz .. 20 kHz
    float filterResonance = 0.2f;  // 0..1
    int   filterMode      = 0;     // 0=LP, 1=HP, 2=BP
    float svfLowL  = 0.0f, svfBandL = 0.0f;
    float svfLowR  = 0.0f, svfBandR = 0.0f;

    // Distortion-specific parameters (type == 3)
    float distDrive   = 0.5f;  // 0..1 → gain 1..20
    float distTone    = 0.5f;  // 0..1, one-pole LP on output
    int   distType    = 0;     // 0=soft-clip, 1=fold
    float distToneStateL = 0.0f;
    float distToneStateR = 0.0f;

    // Bitcrusher-specific parameters (type == 4)
    float crushBits   = 1.0f;  // 0..1 → 16..1 bits (1.0 = 16 bits = no crush)
    float crushRate   = 1.0f;  // 0..1 → downsample factor 1..32 (1.0 = no change)
    float crushHoldL  = 0.0f;  // sample-and-hold state
    float crushHoldR  = 0.0f;
    float crushAccum  = 0.0f;  // accumulator for rate reduction

    // Limiter-specific parameters (type == 5)
    float limGain     = 0.0f;  // 0..1 → 0 dB..+24 dB input gain pushed into ceiling
    // ceiling is fixed at -0.1 dBFS ≈ 0.9886 (no per-instance field needed)

    // Chorus-specific parameters (type == 6)
    float chorusRate    = 0.3f;  // 0..1 → 0.1..8 Hz LFO speed
    float chorusDepth   = 0.22f; // 0..1 → 0..15 ms modulation depth
    float chorusDelay   = 0.3f;  // 0..1 → 1..30 ms base delay
    int   chorusStereo  = 0;     // 0=mono LFO, 1=stereo (R lfo 90° offset)
    float chorusLfoPhL  = 0.0f;  // LFO phase accumulator left (radians)
    float chorusLfoPhR  = 0.0f;  // LFO phase accumulator right
    // Ring buffer: max 60 ms @ 48 kHz = 2880 samples per channel
    std::vector<float> chorusBufL;
    std::vector<float> chorusBufR;
    int   chorusBufPos  = 0;     // write head
    
    // Flanger-specific parameters (type == 9)
    float flangerRate     = 0.3f;   // 0..1 → 0.1..8 Hz LFO speed
    float flangerDepth    = 0.22f;  // 0..1 → 0..10 ms modulation depth
    float flangerDelay    = 0.2f;   // 0..1 → 0..10 ms base delay
    float flangerFeedback = 0.0f;   // -1..1 feedback amount
    int   flangerStereo   = 0;      // 0=mono LFO, 1=stereo (R lfo 90° offset)
    float flangerLfoPhL   = 0.0f;   // LFO phase accumulators
    float flangerLfoPhR   = 0.0f;
    // Ring buffer for flanger (max ~10 ms @ 48 kHz = 480 samples)
    std::vector<float> flangerBufL;
    std::vector<float> flangerBufR;
    int   flangerBufPos  = 0;

    // EQ (type == 7) — 3-band semi-parametric
    // All gains stored as linear multipliers; frequencies/Q as 0..1 normalised.
    float eqLowGain   = 0.0f;  // −1..+1 → −12..+12 dB
    float eqLowFreq   = 0.2f;  // 0..1 → 40..500 Hz (log)
    float eqMidGain   = 0.0f;  // −1..+1 → −12..+12 dB
    float eqMidFreq   = 0.3f;  // 0..1 → 200..8000 Hz (log)
    float eqMidQ      = 0.3f;  // 0..1 → 0.3..8.0
    float eqHighGain  = 0.0f;  // −1..+1 → −12..+12 dB
    float eqHighFreq  = 0.5f;  // 0..1 → 2000..16000 Hz (log)
    // Biquad state: [band][b0,b1,b2,a1,a2]
    float eqCoeffs[3][5] = {};
    // Per-channel biquad delay lines: [band][channel: 0=L,1=R][x1,x2]
    float eqZx[3][2][2] = {};
    float eqZy[3][2][2] = {};
    bool  eqDirty = true;  // recompute coefficients on next block

    // Compressor (type == 8)
    // All params stored as 0..1 normalised unless noted.
    float cmpThreshold = 0.7f;   // 0..1 → −60..0 dBFS  (0.7 ≈ −18 dBFS)
    float cmpRatio     = 0.2f;   // 0..1 → 1:1..20:1 (log)
    float cmpAttack    = 0.1f;   // 0..1 → 0.1..200 ms (log)
    float cmpRelease   = 0.2f;   // 0..1 → 10..2000 ms (log)
    float cmpMakeup    = 0.0f;   // 0..1 → 0..+24 dB
    int   cmpKnee      = 0;      // 0=hard, 1=soft (±6 dB)
    float cmpEnvL      = 0.0f;   // envelope follower state left
    float cmpEnvR      = 0.0f;   // envelope follower state right
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
class AudioEngine : public oboe::AudioStreamDataCallback,
                    public oboe::AudioStreamErrorCallback {
public:
    AudioEngine();
    ~AudioEngine() override;

    bool open();
    void start();
    void stop();
    /// Halts the playhead/sequencer (no more rows advance) WITHOUT killing
    /// any currently-sounding voices. Used when playback reaches the natural
    /// end of a pattern/song (no loop) so notes keep ringing across the
    /// boundary — mirrors letting a note ring until an explicit OFF or the
    /// user pressing Stop (which still uses the hard stop() above).
    void stopTransportSoft();
    void close();
    void restartStream();           // rebuild Oboe stream after device disconnect
    void pauseOutputStream();       // stop stream output without resetting transport
    void resumeOutputStream();      // resume stream output after focus regained

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
    /// instrumentType: 0=simple synth, 1=sampler, 2=Karplus-Strong.
    /// cutoff/resonance/filterAttack/filterDecay/filterSustain/filterRelease/
    /// filterEnvAmt/attack/decay/sustain/release/glide/instVol:
    /// 0-255 mapped from instrument params.
    /// Legacy stride-4 packets are still accepted.
    void triggerRow(const std::vector<int>& rowData);

    /// Kill voices on specific tracks. One entry per track: 1 = kill, 0 = leave.
    void killVoices(const std::vector<int>& killMask);

    /// Set the current line duration in samples (called before queueDelays/queueKills).
    /// Needed to convert delay/kill percentages to sample-accurate offsets.
    void setLineSamplesPerRow(int32_t samples) {
        mLineSamplesPerRow = samples;
    }

    /// Consume and return the number of row boundaries crossed since the last poll.
    int32_t consumePendingRowAdvances();

    /// Reset the native playhead phase so the current row restarts its timing.
    void resetPlayheadPhase();

    /// Clear any queued playback rows prepared by Dart (also clears any pending next-loop rows).
    void clearQueuedPlaybackRows();

    /// Queue one fully built playback row for native sample-accurate playback.
    void enqueuePlaybackRow(const QueuedPlaybackRow& row);

    /// Control whether queued playback rows loop when the queue end is reached.
    void setQueuedPlaybackLooping(bool loop);

    /// Double-buffer API: clear the pending next-loop row buffer.
    /// Call before a series of appendPendingRow() calls.
    void beginPendingRows();

    /// Double-buffer API: append one row to the pending next-loop buffer.
    /// At the next native loop boundary the pending buffer is atomically
    /// swapped into the live queue so playback continues without a gap.
    void appendPendingRow(const QueuedPlaybackRow& row);

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
    /// [data] is packed in groups of 4: [delayPct, trackIdx, note, volume].
    /// All pending events are cleared when triggerRow() is called.
    void queueDelays(const std::vector<int>& data);

    /// Queue sample-accurate kill events for KIL.
    /// [data] is packed in groups of 2: [killPct, trackIdx].
    /// All pending events are cleared when triggerRow() is called.
    void queueKills(const std::vector<int>& data);

    /// Queue sample-accurate slice commands for SLC.
    /// [data] is packed in groups of 3: [slicePct, sliceNum, trackIdx].
    /// sliceNum = 1-9 (which slice), slicePct = 0 or 1 (play mode).
    /// All pending events are cleared when triggerRow() is called.
    void queueSliceCommands(const std::vector<int>& data);

    /// Queue mixer control commands (M01-M99).
    /// [data] is packed in groups of 4: [channel, controller, value, unused].
    /// channel: 0=master, 1-16=mixer channels
    /// controller: 1-4 (pan, mute, solo, volume), 5-9 reserved
    /// value: 0-99 parameter value
    void queueMixerCommands(const std::vector<int>& data);

    /// Queue own-channel insert FX commands (F11-F69).
    /// [data] is packed in groups of 4: [trackIdx, slotIdx, function, value].
    void queueInsertFxCommands(const std::vector<int>& data);

    /// Configure an insert effect on the master bus.
    /// slotIdx: 0-5 (6 insert slots)
    /// effectType: -1=empty, 0=reverb
    /// initialWetLevel: default wet gain when the effect is first created.
    void setMasterInsertEffect(int slotIdx, int effectType, float initialWetLevel);
    void setMasterInsertMix(int slotIdx, float dryLevel, float wetLevel);
    void setMasterInsertBypass(int slotIdx, bool bypass);

    /// Hidden always-on master safety limiter. Sits after master inserts to
    /// prevent inter-sample peaks from clipping the DAC. Default enabled.
    void setMasterLimiterEnabled(bool enabled);
    bool isMasterLimiterEnabled() const;

    /// Direct linear-gain master volume setter (bypasses the lossy 0..99
    /// integer mixer-command transport). Accepts values above 1.0 so users
    /// can intentionally drive the safety limiter for makeup-style gain.
    void setMasterVolumeLinear(float linearGain);

    /// Configure reverb parameters on a master insert effect
    /// slotIdx: 0-5, roomSize: 0.0-1.0, damp: 0.0-1.0, width: 0.0-1.0
    void setMasterReverbParams(int slotIdx, float roomSize, float damp, float width, bool freeze);

    /// Configure an insert effect on a track (1-16).
    /// trackIdx: 0-15 (track index), slotIdx: 0-5
    /// effectType: -1=empty, 0=reverb
    void setTrackInsertEffect(int trackIdx, int slotIdx, int effectType, float initialWetLevel);
    void setTrackInsertMix(int trackIdx, int slotIdx, float dryLevel, float wetLevel);
    void setTrackInsertBypass(int trackIdx, int slotIdx, bool bypass);
    void setVoicePreviewBypassTrackInserts(int trackIdx, bool bypass);

    /// Configure reverb parameters on a track insert effect
    void setTrackReverbParams(int trackIdx, int slotIdx, float roomSize, float damp, float width, bool freeze);

    /// Configure delay parameters on a master insert effect slot (type 1).
    void setMasterDelayParams(int slotIdx, float timeMs, float feedback, float hpCutoff, bool sync);

    /// Configure delay parameters on a track insert effect slot (type 1).
    void setTrackDelayParams(int trackIdx, int slotIdx, float timeMs, float feedback, float hpCutoff, bool sync);

    /// Configure filter parameters on a track insert effect slot (type 2).
    void setTrackFilterParams(int trackIdx, int slotIdx, float cutoff, float resonance, int mode);
    void setMasterFilterParams(int slotIdx, float cutoff, float resonance, int mode);

    /// Configure distortion parameters on a track insert effect slot (type 3).
    void setTrackDistortionParams(int trackIdx, int slotIdx, float drive, float tone, int distType);
    void setMasterDistortionParams(int slotIdx, float drive, float tone, int distType);

    /// Configure bitcrusher parameters on a track insert effect slot (type 4).
    void setTrackBitcrusherParams(int trackIdx, int slotIdx, float bits, float rate);
    void setMasterBitcrusherParams(int slotIdx, float bits, float rate);

    /// Configure limiter gain on a track/master insert effect slot (type 5).
    void setTrackLimiterParams(int trackIdx, int slotIdx, float gain);
    void setMasterLimiterParams(int slotIdx, float gain);

    /// Configure chorus parameters on a track/master insert effect slot (type 6).
    void setTrackChorusParams(int trackIdx, int slotIdx, float rate, float depth, float delay, int stereo);
    void setMasterChorusParams(int slotIdx, float rate, float depth, float delay, int stereo);
    
    /// Configure flanger parameters on a track/master insert effect slot (type 9).
    void setTrackFlangerParams(int trackIdx, int slotIdx, float rate, float depth, float delay, float feedback, int stereo);
    void setMasterFlangerParams(int slotIdx, float rate, float depth, float delay, float feedback, int stereo);

    /// Configure EQ parameters on a track/master insert effect slot (type 7).
    void setTrackEqParams(int trackIdx, int slotIdx, float lowGain, float lowFreq, float midGain, float midFreq, float midQ, float highGain, float highFreq);
    void setMasterEqParams(int slotIdx, float lowGain, float lowFreq, float midGain, float midFreq, float midQ, float highGain, float highFreq);

    /// Configure compressor parameters on a track/master insert effect slot (type 8).
    void setTrackCompressorParams(int trackIdx, int slotIdx, float threshold, float ratio, float attack, float release, float makeup, int knee);
    void setMasterCompressorParams(int slotIdx, float threshold, float ratio, float attack, float release, float makeup, int knee);

    /// Assign a sample file to an instrument slot for sampler playback.
    /// Pass empty path to clear assignment.
    bool setSamplerSample(int slot, const std::string& path);

    /// Apply (or remove) beat-sync time-stretching on a sampler slot.
    /// If enabled=false the slot is restored to its original un-stretched audio.
    /// If enabled=true the original audio is resampled via linear interpolation
    /// to fit exactly (beats * 60 / bpm) seconds — computed on the calling thread
    /// (call from a worker thread in Kotlin to keep the UI responsive).
    /// preservePitch is stored for future SoundTouch integration; currently ignored
    /// (Method A: speed/pitch linked).
    void updateStretch(int slot, bool enabled, int beats, float bpm, bool preservePitch);

    /// Open the mic input stream and keep it running silently (no accumulation).
    /// Call once when entering the recording UI so the stream is warm before
    /// the first RECORD press, avoiding Android duplex-mode transients.
    void openRecordingStream();

    /// Close the persistent mic input stream. Call when leaving the recording UI.
    void closeRecordingStream();

    /// Start accumulating mic input into the internal buffer.
    /// Requires openRecordingStream() to have been called first.
    void startRecording();

    /// Stop accumulating and return the recorded samples + sample rate.
    /// The mic stream remains open and running silently.
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

    // oboe::AudioStreamErrorCallback — fires after stream is closed by Oboe
    void onErrorAfterClose(oboe::AudioStream* stream,
                           oboe::Result       error) override;

    /// Check if a specific voice (track) is currently playing.
    /// Returns true if the voice has an active note or is in release stage.
    bool isVoicePlaying(int trackIdx) const;

    /// Get the current envelope stage of a voice (for preview timing).
    /// Returns EnvelopeStage enum value: 0=Idle, 1=Attack, 2=Decay, 3=Sustain, 4=Release
    int getVoiceEnvelopeStage(int trackIdx) const;

    /// Begin capturing the stereo master output into the export buffer.
    /// Clears any previously captured data.
    void startExportTap();

    /// Stop capturing and return the accumulated interleaved stereo float samples.
    /// Also returns the stream sample rate via [outSampleRate].
    std::vector<float> stopExportTap(int& outSampleRate);

    /// Set per-track send routing. [routing] has one entry per track:
    /// 0 = route to master, 1-16 = route audio into that channel's bus (1-based).
    void setSendRouting(const std::vector<int>& routing);

    /// Return packed stereo peak meter values as linear amplitudes.
    /// Layout: [track0L..track15L, track0R..track15R, masterL, masterR].
    std::array<float, kMaxVoices * 2 + 2> getMeterValues() const;

private:
    // Shared by stop() / stopTransportSoft(): halts the sequencer/playhead
    // and resets meters. Does NOT touch mVoices — callers decide separately
    // whether to silence voices (hard stop) or leave them ringing (soft stop).
    void haltTransport();

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
    bool                             mStarted   = false;
    bool                             mHasFocus  = true;   // tracks audio-focus state
    std::atomic<double>              mBpm{120.0};
    mutable std::mutex               mVoiceMutex;
    std::array<Voice, kMaxVoices>    mVoices{};
    std::array<SampleData, 64>       mSamplerSlots{};

    // Sample-accurate retrigger state (protected by mVoiceMutex).
    std::vector<RetrigEvent> mPendingRetrigs;
    std::vector<ArpEvent>    mPendingArp;
    std::vector<DelayEvent>  mPendingDelays;
    std::vector<KillEvent>   mPendingKills;
    std::vector<SliceCommandEvent> mPendingSliceCommands;
    std::vector<MixerCommandEvent>  mPendingMixerCommands;
    std::vector<InsertFxCommandEvent> mPendingInsertFxCommands;
    
    // Mixer state (master channel: mute, volume)
    std::atomic<bool>   mMasterMute{false};  // true = muted, false = unmuted
    std::atomic<float>  mMasterVolume{1.0f};   // 0.0-1.0, 1.0 = full volume
    float               mCachedSampleRate{48000.0f}; // updated on stream open

    // ── Master safety limiter (look-ahead peak, soft knee, -0.3 dBFS ceiling).
    // Always-on (toggleable) brick-wall sitting after master inserts. Prevents
    // user mixes from clipping the DAC. ~1.5 ms lookahead via a ring buffer.
    std::atomic<bool>   mMasterLimiterEnabled{true};
    static constexpr int kMasterLimiterLookahead = 72; // ~1.5 ms @ 48 kHz
    std::array<float, kMasterLimiterLookahead> mLimRingL{};
    std::array<float, kMasterLimiterLookahead> mLimRingR{};
    int    mLimWriteIdx{0};
    float  mLimPeakEnv{0.0f};   // recent-peak envelope (1 ms release)
    float  mLimGainEnv{1.0f};   // applied gain envelope (50 ms release)
    
    int32_t                  mSubRowSampleCounter = 0;
    int32_t                  mPlayheadSampleCounter = 0;
    int32_t                  mLineSamplesPerRow = 0; // Set via setLineSamplesPerRow()
    std::atomic<int32_t>     mPendingRowAdvances{0};
    std::atomic<bool>        mPlayheadRunning{false};
    std::vector<QueuedPlaybackRow> mQueuedPlaybackRows;
    size_t                   mQueuedPlaybackRowIndex = 0;
    bool                     mQueuedPlaybackLoop = false;
    std::vector<QueuedPlaybackRow> mPendingNextLoopRows; // double-buffer: swapped in at each loop boundary

    // Recording state
    std::mutex                       mRecordingMutex;
    std::atomic<bool>                mIsRecording{false};
    std::vector<float>               mRecordingBuffer;
    int                              mRecordingWarmupFrames{0}; // frames to skip at stream open
    static constexpr int             kMaxRecordingFrames  = 44100 * 60; // 60 seconds at 44.1kHz
    static constexpr int             kWarmupFrames        = 4096;       // ~85ms at 48kHz

    // Export tap state (stereo output capture during song playback)
    std::mutex                       mExportMutex;
    std::atomic<bool>                mExportTapActive{false};
    std::vector<float>               mExportBuffer;       // interleaved stereo L,R,...
    static constexpr int             kMaxExportFrames = 48000 * 60 * 20; // 20 min at 48 kHz

    // Insert effects (master + per-track)
    static constexpr int             kMaxInsertSlots = 6;
    InsertEffect                     mMasterInserts[kMaxInsertSlots];
    InsertEffect                     mTrackInserts[kMaxVoices][kMaxInsertSlots];
    std::array<bool, kMaxVoices>     mPreviewBypassTrackInserts{};
    std::array<int, kMaxVoices>      mTrackSendChannel{}; // 0=master, 1..kMaxVoices=send to that channel (1-based)
    // Per-track bus-level mixer state (applied in routing pass, set via MixerCommandEvent)
    float mTrackVolume[kMaxVoices]; // 0..1, 1.0 = unity
    bool  mTrackMute[kMaxVoices];   // true = silenced
    bool  mTrackSolo[kMaxVoices];   // true = this track is soloed
    std::array<std::vector<float>, kMaxVoices> mTrackBusL;
    std::array<std::vector<float>, kMaxVoices> mTrackBusR;
    std::vector<float>               mMasterBusL;
    std::vector<float>               mMasterBusR;
    std::vector<float>               mFxWetL;
    std::vector<float>               mFxWetR;
    // Pre-allocated scratch for preview-audition routing (bypasses inserts/master).
    std::vector<float>               mPreviewDirectL;
    std::vector<float>               mPreviewDirectR;
    mutable std::mutex               mMeterMutex;
    std::array<float, kMaxVoices>    mTrackMeterPeakL{};
    std::array<float, kMaxVoices>    mTrackMeterPeakR{};
    float                            mMasterMeterPeakL = 0.0f;
    float                            mMasterMeterPeakR = 0.0f;

    void processEffects(float* outL, float* outR, int numFrames, InsertEffect* effects);

    bool loadWavMono16OrFloat(const std::string& path, SampleData& outSample);
    void triggerRowLocked(const std::vector<int>& rowData);
    void killVoicesLocked(const std::vector<int>& killMask);
    void queueRetrigsLocked(const std::vector<int>& data);
    void queueArpLocked(const std::vector<int>& data);
    void queueDelaysLocked(const std::vector<int>& data);
    void queueKillsLocked(const std::vector<int>& data);
    void queueSliceCommandsLocked(const std::vector<int>& data);
    void queueMixerCommandsLocked(const std::vector<int>& data);
    void queueInsertFxCommandsLocked(const std::vector<int>& data);
    void applyPitchRampsLocked(const std::vector<int>& data);
    void applyQueuedPlaybackRowLocked(const QueuedPlaybackRow& row);
    bool primeNextQueuedPlaybackRowLocked();

    static double midiToFreq(int note) {
        return 440.0 * std::pow(2.0, (note - 69) / 12.0);
    }
};
