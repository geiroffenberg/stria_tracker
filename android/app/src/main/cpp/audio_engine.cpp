#include "audio_engine.h"
#include "stria_sola_stretcher.hpp"
#include <android/log.h>
#include <algorithm>
#include <fstream>
#include <cstring>
#include <thread>
#include <chrono>
#include <cmath>

namespace {
float byteToNorm(int v) {
    return static_cast<float>(std::clamp(v, 0, 255)) / 255.0f;
}

float karplusFeedback(float n) {
    return 0.94f + std::clamp(n, 0.0f, 1.0f) * 0.0592f;
}

float karplusBrightness(float n) {
    return 0.08f + std::clamp(n, 0.0f, 1.0f) * 0.90f;
}

float karplusExcitationTone(float n) {
    return 0.05f + std::clamp(n, 0.0f, 1.0f) * 0.95f;
}

float karplusPickPosition(float n) {
    return 0.06f + std::clamp(n, 0.0f, 1.0f) * 0.44f;
}

float karplusAttackColor(float n) {
    return 0.10f + std::clamp(n, 0.0f, 1.0f) * 0.90f;
}

float karplusBodyBlend(float n) {
    return std::clamp(n, 0.0f, 1.0f);
}

float karplusDriveAmount(float n) {
    return std::clamp(n, 0.0f, 1.0f);
}

float karplusDispersion(float n) {
    const float clamped = std::clamp(n, 0.0f, 1.0f);
    return clamped * clamped * 0.24f;
}

void startKarplusVoice(Voice& v, int midiNote, int sampleRate) {
    const float detuneSemitones = (v.detuneNorm - 0.5f) * 24.0f;
    const float freq = static_cast<float>(440.0 * std::pow(2.0, ((midiNote - 69) + detuneSemitones) / 12.0));
    const float clampedFreq = std::clamp(freq, 20.0f, 12000.0f);
    const int delayLen = std::clamp(
        static_cast<int>(static_cast<float>(sampleRate) / clampedFreq + 0.5f),
        8,
        8192);

    v.midiNote = midiNote;
    v.currentFreq = clampedFreq;
    v.targetFreq = clampedFreq;
    v.karplusBuf.assign(delayLen, 0.0f);
    v.karplusPos = 0;
    v.karplusDispersionState = 0.0f;
    v.karplusBodyState = 0.0f;
    v.karplusBodyState2 = 0.0f;
    v.karplusActive = true;
    v.karplusMode = true;
    v.samplerMode = false;
    v.sampleActive = false;
    v.declickTailFramesLeft = 0;
    v.noteHeld = true;
    v.gain = 0.0f;
    v.gainTarget = 1.0f;
    v.pendingWaveform = -1;
    v.envStage = EnvelopeStage::Idle;
    v.filterEnvStage = EnvelopeStage::Idle;
    v.envLevel = 0.0f;
    v.filterEnvLevel = 0.0f;

    float excite = 0.0f;
    const float tone = karplusExcitationTone(v.karplusToneNorm);
    const float attackColor = karplusAttackColor(v.karplusAttackColorNorm);
    for (int i = 0; i < delayLen; ++i) {
        v.noiseState = v.noiseState * 1664525u + 1013904223u;
        const uint32_t bits = (v.noiseState >> 8) & 0xFFFFu;
        const float raw = (static_cast<float>(bits) / 32767.5f) - 1.0f;
        excite += tone * (raw - excite);
        v.karplusBuf[i] = raw * attackColor + excite * (1.0f - attackColor);
    }

    const int pickOffset = std::clamp(
        static_cast<int>(karplusPickPosition(v.karplusPickPositionNorm) * static_cast<float>(delayLen - 1)),
        1,
        std::max(1, delayLen - 1));
    if (pickOffset > 0 && pickOffset < delayLen) {
        const auto base = v.karplusBuf;
        for (int i = 0; i < delayLen; ++i) {
            const float delayed = base[(i + pickOffset) % delayLen];
            v.karplusBuf[i] = std::clamp(base[i] - 0.72f * delayed, -1.0f, 1.0f);
        }
    }
}

// ── Drum Synth (Kick/Snare/Hat/Tom/Crash) helpers ───────────────────────────
// Simple 0..1 -> musical-range mappings, same style as the Karplus helpers
// above. Piece constants match DrumPiece in instrument_model.dart.
enum DrumPieceId : int { kDrumKick = 0, kDrumSnare = 1, kDrumHat = 2, kDrumTom = 3, kDrumCrash = 4 };

float drumPitchEnvCoeff(float pitchDecayNorm, int sampleRate) {
    // Pitch-sweep time constant: ~15ms (punchy snap) to ~250ms (long boom).
    const float ms = 15.0f + std::clamp(pitchDecayNorm, 0.0f, 1.0f) * 235.0f;
    const float tau = ms * 0.001f * static_cast<float>(sampleRate);
    return std::exp(-1.0f / std::max(1.0f, tau));
}

float drumAmpEnvCoeff(float decayNorm, int sampleRate) {
    // Overall amplitude decay time constant: ~40ms to ~1200ms.
    const float ms = 40.0f + std::clamp(decayNorm, 0.0f, 1.0f) * 1160.0f;
    const float tau = ms * 0.001f * static_cast<float>(sampleRate);
    return std::exp(-1.0f / std::max(1.0f, tau));
}

float drumClickEnvCoeff(int sampleRate) {
    // Fixed short click/snap transient, ~4ms.
    const float tau = 0.004f * static_cast<float>(sampleRate);
    return std::exp(-1.0f / std::max(1.0f, tau));
}

float drumCombFeedback(float resonanceNorm) {
    // Stable feedback range for the metallic comb resonator (Hat/Crash).
    return 0.30f + std::clamp(resonanceNorm, 0.0f, 1.0f) * 0.55f;
}

void startDrumVoice(Voice& v, int sampleRate) {
    const float pitchN = std::clamp(v.drumPitchNorm, 0.0f, 1.0f);
    float freqStart;
    float freqEnd;
    switch (v.drumPiece) {
        case kDrumKick:
            freqStart = 90.0f + pitchN * 160.0f;   // 90-250 Hz
            freqEnd   = freqStart * 0.30f;
            break;
        case kDrumTom:
            freqStart = 130.0f + pitchN * 270.0f;  // 130-400 Hz
            freqEnd   = freqStart * 0.55f;
            break;
        case kDrumSnare:
            freqStart = 150.0f + pitchN * 200.0f;  // 150-350 Hz
            freqEnd   = freqStart * 0.65f;
            break;
        case kDrumHat:
        case kDrumCrash:
        default:
            freqStart = 2000.0f + pitchN * 6000.0f; // 2-8 kHz metallic center
            freqEnd   = freqStart;
            break;
    }
    v.drumFreqStart = freqStart;
    v.drumFreqEnd   = freqEnd;
    v.drumOscPhase  = 0.0;
    v.drumAmpEnvLevel   = 1.0f;
    v.drumPitchEnvLevel = 1.0f;
    v.drumClickEnvLevel = 1.0f;
    v.drumFilterLow  = 0.0f;
    v.drumFilterBand = 0.0f;

    // Short metallic comb delay (Hat/Crash ring; harmless no-op for other pieces).
    const float combHz = 400.0f + pitchN * 3000.0f; // 400 Hz - 3.4 kHz ring
    const int combLen = std::clamp(
        static_cast<int>(static_cast<float>(sampleRate) / combHz + 0.5f),
        4, kMaxDrumCombBuf);
    if (static_cast<int>(v.drumCombBuf.size()) != combLen) {
        v.drumCombBuf.assign(combLen, 0.0f);
    } else {
        std::fill(v.drumCombBuf.begin(), v.drumCombBuf.end(), 0.0f);
    }
    v.drumCombPos = 0;

    v.drumMode      = true;
    v.drumActive    = true;
    v.samplerMode   = false;
    v.karplusMode   = false;
    v.karplusActive = false;
    v.sampleActive  = false;
    v.declickTailFramesLeft = 0;
    v.noteHeld   = true;
    v.gain       = 0.0f;
    v.gainTarget = 1.0f;
    v.pendingWaveform = -1;
    v.envStage       = EnvelopeStage::Idle;
    v.filterEnvStage = EnvelopeStage::Idle;
    v.envLevel       = 0.0f;
    v.filterEnvLevel = 0.0f;
}

float fxValueToUnit(int value) {
    return std::clamp(value, 0, 99) / 99.0f;
}

void syncReverbState(InsertEffect& fx) {
    fx.reverb.setroomsize(fx.reverbRoomSize);
    fx.reverb.setdamp(fx.reverbDamp);
    fx.reverb.setwidth(fx.reverbWidth);
    fx.reverb.setdry(0.0f);
    fx.reverb.setwet(1.0f);
    fx.reverb.setmode(fx.reverbFreeze ? 1.0f : 0.0f);
}

void applyInsertFxCommand(InsertEffect& fx, int function, int value) {
    // function 0 = reset to defaults (value ignored)
    if (function == 0) {
        fx.bypass      = false;
        fx.dryLevel    = 1.0f;
        fx.wetLevel    = 0.3f;
        fx.dryWet      = 0.3f;
        // Reverb defaults
        fx.reverbRoomSize = 0.5f;
        fx.reverbDamp     = 0.5f;
        fx.reverbWidth    = 1.0f;
        fx.reverbFreeze   = false;
        syncReverbState(fx);
        // Delay defaults
        fx.delayTimeMs   = 375.0f;
        fx.delayFeedback = 0.4f;
        fx.delayHpCutoff = 0.0f;
        fx.delaySync     = false;
        // Clear delay buffer
        std::fill(fx.delayBufL.begin(), fx.delayBufL.end(), 0.0f);
        std::fill(fx.delayBufR.begin(), fx.delayBufR.end(), 0.0f);
        fx.delayWritePos = 0;
        fx.delayHpPrevL  = 0.0f;
        fx.delayHpPrevR  = 0.0f;
        // Filter defaults
        fx.filterCutoff    = 0.5f;
        fx.filterResonance = 0.2f;
        fx.filterMode      = 0;
        fx.svfLowL = fx.svfBandL = fx.svfLowR = fx.svfBandR = 0.0f;
        // Distortion defaults
        fx.distDrive = 0.5f;
        fx.distTone  = 0.5f;
        fx.distType  = 0;
        fx.distToneStateL = fx.distToneStateR = 0.0f;
        // Bitcrusher defaults
        fx.crushBits  = 1.0f;
        fx.crushRate  = 1.0f;
        fx.crushHoldL = fx.crushHoldR = fx.crushAccum = 0.0f;
        // Limiter defaults
        fx.limGain = 0.0f;
        // Chorus defaults
        fx.chorusRate   = 0.3f;
        fx.chorusDepth  = 0.22f;
        fx.chorusDelay  = 0.3f;
        fx.chorusStereo = 0;
        fx.dryLevel     = 0.5f;
        fx.wetLevel     = 1.0f;
        fx.chorusLfoPhL = fx.chorusLfoPhR = 0.0f;
        fx.chorusBufL.assign(2880, 0.0f);
        fx.chorusBufR.assign(2880, 0.0f);
        fx.chorusBufPos = 0;
        // EQ defaults
        fx.eqLowGain  = 0.0f; fx.eqLowFreq  = 0.2f;
        fx.eqMidGain  = 0.0f; fx.eqMidFreq  = 0.3f; fx.eqMidQ = 0.3f;
        fx.eqHighGain = 0.0f; fx.eqHighFreq = 0.5f;
        std::memset(fx.eqCoeffs, 0, sizeof(fx.eqCoeffs));
        std::memset(fx.eqZx,     0, sizeof(fx.eqZx));
        std::memset(fx.eqZy,     0, sizeof(fx.eqZy));
        fx.eqDirty = true;
        // Compressor defaults
        fx.cmpThreshold = 0.7f; fx.cmpRatio   = 0.2f;
        fx.cmpAttack    = 0.1f; fx.cmpRelease = 0.2f;
        fx.cmpMakeup    = 0.0f; fx.cmpKnee    = 0;
        fx.cmpEnvL      = 0.0f; fx.cmpEnvR    = 0.0f;
        return;
    }
    switch (function) {
        case 1:
            fx.bypass = (value > 0);
            return;
        case 6:
            fx.dryLevel = fxValueToUnit(value);
            fx.dryWet = fx.wetLevel;
            return;
        case 7:
            fx.wetLevel = fxValueToUnit(value);
            fx.dryWet = fx.wetLevel;
            return;
        default:
            break;
    }

    if (fx.type == 0) {
        switch (function) {
            case 2:
                fx.reverbFreeze = (value > 0);
                syncReverbState(fx);
                break;
            case 3:
                fx.reverbRoomSize = fxValueToUnit(value);
                syncReverbState(fx);
                break;
            case 4:
                fx.reverbDamp = fxValueToUnit(value);
                syncReverbState(fx);
                break;
            case 5:
                fx.reverbWidth = fxValueToUnit(value);
                syncReverbState(fx);
                break;
            default:
                break;
        }
    } else if (fx.type == 1) {
        // Delay
        switch (function) {
            case 2:
                fx.delaySync = (value > 0);
                break;
            case 3: {
                // 0-99 → 1 ms – 2000 ms (exponential feel via quadratic)
                float t = fxValueToUnit(value);
                fx.delayTimeMs = 1.0f + t * t * 1999.0f;
                break;
            }
            case 4:
                fx.delayFeedback = fxValueToUnit(value) * 0.95f;
                break;
            case 5:
                fx.delayHpCutoff = fxValueToUnit(value);
                break;
            default:
                break;
        }
    } else if (fx.type == 2) {
        // Filter
        switch (function) {
            case 2: fx.filterMode = std::clamp(value % 3, 0, 2); break;
            case 3: fx.filterCutoff = fxValueToUnit(value); break;
            case 4: fx.filterResonance = fxValueToUnit(value); break;
            default: break;
        }
    } else if (fx.type == 3) {
        // Distortion
        switch (function) {
            case 2: fx.distType = (value > 0) ? 1 : 0; break;
            case 3: fx.distDrive = fxValueToUnit(value); break;
            case 4: fx.distTone = fxValueToUnit(value); break;
            default: break;
        }
    } else if (fx.type == 4) {
        // Bitcrusher
        switch (function) {
            case 3: fx.crushBits = fxValueToUnit(value); break;
            case 4: fx.crushRate = fxValueToUnit(value); break;
            default: break;
        }
    } else if (fx.type == 5) {
        // Limiter
        switch (function) {
            case 3: fx.limGain = fxValueToUnit(value); break;
            default: break;
        }
    } else if (fx.type == 6) {
        // Chorus
        switch (function) {
            case 2: fx.chorusStereo = (value > 0) ? 1 : 0; break;
            case 3: fx.chorusRate  = fxValueToUnit(value); break;
            case 4: fx.chorusDepth = fxValueToUnit(value); break;
            case 5: fx.chorusDelay = fxValueToUnit(value); break;
            default: break;
        }
    } else if (fx.type == 7) {
        // EQ — gains stored as −1..+1, freqs/Q stored as 0..1
        switch (function) {
            case 3: fx.eqLowGain  = fxValueToUnit(value) * 2.0f - 1.0f; fx.eqDirty = true; break;
            case 4: fx.eqMidGain  = fxValueToUnit(value) * 2.0f - 1.0f; fx.eqDirty = true; break;
            case 5: fx.eqHighGain = fxValueToUnit(value) * 2.0f - 1.0f; fx.eqDirty = true; break;
            default: break;
        }
    } else if (fx.type == 8) {
        // Compressor
        switch (function) {
            case 2: fx.cmpKnee      = (value > 0) ? 1 : 0; break;
            case 3: fx.cmpThreshold = fxValueToUnit(value); break;
            case 4: fx.cmpRatio     = fxValueToUnit(value); break;
            case 5: fx.cmpMakeup    = fxValueToUnit(value); break;
            case 8: fx.cmpAttack    = fxValueToUnit(value); break;
            case 9: fx.cmpRelease   = fxValueToUnit(value); break;
            default: break;
        }
    }
}

// Map normalized UI values to musically useful envelope times.
float normToAttackSec(float n) {
    const float x = std::clamp(n, 0.0f, 1.0f);
    return 0.001f + x * x * 2.0f;
}

float normToDecaySec(float n) {
    const float x = std::clamp(n, 0.0f, 1.0f);
    return 0.001f + x * x * 2.5f;
}

float normToReleaseSec(float n) {
    const float x = std::clamp(n, 0.0f, 1.0f);
    return 0.002f + x * x * 3.0f;
}

float normToGlideSec(float n) {
    const float x = std::clamp(n, 0.0f, 1.0f);
    if (x < 0.01f) return 0.0f;
    return 0.003f + x * x * 1.5f;
}

float normToLfoHz(float n) {
    // 0.1 Hz .. 20 Hz, exponential-ish (matches Dart display: 0.1 + n*n*19.9)
    const float x = std::clamp(n, 0.0f, 1.0f);
    return 0.1f + x * x * 19.9f;
}

// Sampler LFO cycle-length divisions (beats per cycle). Index matches the Dart
// kSamplerLfoDivBeats table exactly.
static const double kSamplerLfoDivBeats[10] = {
    1.0 / 32.0, 1.0 / 16.0, 1.0 / 8.0, 1.0 / 4.0, 1.0 / 2.0,
    1.0, 2.0, 4.0, 8.0, 16.0
};

// Slew limiter for LFO modulation to avoid clicks. A 2ms window eliminates
// square-wave clicks while staying responsive to pitch/filter changes.
static const float kSamplerLfoSlewWindowMs = 2.0f;

// Compute a unipolar [0..1] LFO value for the given waveform and phase [0..1).
// [wave]: 1=sine,2=triangle,3=square,4=rampUp,5=rampDown,6=random.
// [randVal] is the current sample-and-hold value for the random waveform.
inline float samplerLfoValue(int wave, double phase, float randVal) {
    switch (wave) {
        case 1: // sine
            return 0.5f + 0.5f * static_cast<float>(std::sin(2.0 * M_PI * phase));
        case 2: // triangle
            return static_cast<float>(1.0 - std::fabs(2.0 * phase - 1.0));
        case 3: // square
            return (phase < 0.5) ? 1.0f : 0.0f;
        case 4: // ramp up
            return static_cast<float>(phase);
        case 5: // ramp down
            return static_cast<float>(1.0 - phase);
        case 6: // random (sample & hold)
            return randVal;
        default:
            return 0.0f;
    }
}

// Convert a unipolar LFO value [0..1] into a signed modulation offset [-1..1]
// according to the anchor mode:
//   0 = center: base is the midpoint, swings ±1   (lfo 0→1 maps -1→+1)
//   1 = up:     base is the floor,   pushes 0→+1  (lfo 0→1 maps  0→+1)
//   2 = down:   base is the ceiling, pulls -1→0   (lfo 0→1 maps -1→ 0)
// Scale the returned value externally by depth * range.
inline float samplerLfoOffset(int mode, float lfo) {
    switch (mode) {
        case 1:  return lfo;                    // UP
        case 2:  return -(1.0f - lfo);          // DOWN
        default: return (lfo - 0.5f) * 2.0f;    // CENTER
    }
}

float normToCutoffHz(float n) {
    const float x = std::clamp(n, 0.0f, 1.0f);
    // Exponential mapping keeps low-end control usable.
    const float minHz = 40.0f;
    const float maxHz = 12000.0f;
    return minHz * std::pow(maxHz / minHz, x);
}

float poleK(float sampleRate, float seconds) {
    return 1.0f - std::exp(-1.0f / (sampleRate * std::max(seconds, 1e-4f)));
}

uint16_t readLe16(const uint8_t* p) {
    return static_cast<uint16_t>(p[0] | (p[1] << 8));
}

uint32_t readLe32(const uint8_t* p) {
    return static_cast<uint32_t>(p[0] |
                                 (p[1] << 8) |
                                 (p[2] << 16) |
                                 (p[3] << 24));
}
} // namespace

#define LOG_TAG "TrackerAudio"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

AudioEngine::AudioEngine() {
    for (auto& v : mVoices) v = Voice{};
    for (int i = 0; i < kMaxVoices; ++i) {
        mTrackVolume[i] = 1.0f;
        mTrackMute[i]   = false;
        mTrackSolo[i]   = false;
    }
}

AudioEngine::~AudioEngine() {
    close();
}

bool AudioEngine::open() {
    oboe::AudioStreamBuilder builder;
    builder.setDirection(oboe::Direction::Output);
    builder.setPerformanceMode(oboe::PerformanceMode::LowLatency);
    builder.setSharingMode(oboe::SharingMode::Shared);  // Shared routes through AudioFlinger, enabling screen-recording capture
    builder.setFormat(oboe::AudioFormat::Float);
    builder.setChannelCount(oboe::ChannelCount::Stereo);
    builder.setUsage(oboe::Usage::Media);
    builder.setDataCallback(this);
    builder.setErrorCallback(this);  // triggers onErrorAfterClose on device disconnect

    oboe::Result result = builder.openManagedStream(mStream);
    if (result != oboe::Result::OK) {
        LOGE("Failed to open stream: %s", oboe::convertToText(result));
        return false;
    }
    LOGI("Oboe stream opened: sampleRate=%d", mStream->getSampleRate());
    mCachedSampleRate = static_cast<float>(mStream->getSampleRate());

    // Master limiter: clear lookahead ring & envelopes for a glitch-free start.
    mLimRingL.fill(0.0f);
    mLimRingR.fill(0.0f);
    mLimWriteIdx = 0;
    mLimPeakEnv = 0.0f;
    mLimGainEnv = 1.0f;

    // ── Real-time safety: pre-allocate every buffer the audio callback touches.
    // After this point onAudioReady() must not allocate on the audio thread.
    for (int t = 0; t < kMaxVoices; ++t) {
        mTrackBusL[t].assign(kMaxAudioBurst, 0.0f);
        mTrackBusR[t].assign(kMaxAudioBurst, 0.0f);
    }
    mMasterBusL.assign(kMaxAudioBurst, 0.0f);
    mMasterBusR.assign(kMaxAudioBurst, 0.0f);
    mFxWetL.assign(kMaxAudioBurst, 0.0f);
    mFxWetR.assign(kMaxAudioBurst, 0.0f);
    mPreviewDirectL.assign(kMaxAudioBurst, 0.0f);
    mPreviewDirectR.assign(kMaxAudioBurst, 0.0f);

    // Reserve capacity for pending event vectors so push/erase in the audio
    // path never reallocates. clear()/erase don't shrink capacity, so this
    // reserve carries through the entire session.
    constexpr size_t kEventReserve = 256;
    mPendingDelays.reserve(kEventReserve);
    mPendingArp.reserve(kEventReserve);
    mPendingRetrigs.reserve(kEventReserve);
    mPendingKills.reserve(kEventReserve);
    mPendingSliceCommands.reserve(kEventReserve);
    mPendingMixerCommands.reserve(kEventReserve);
    mPendingInsertFxCommands.reserve(kEventReserve);

    // Pre-reserve each voice's Karplus delay line so startKarplusVoice()
    // (called from the audio thread via pending events) never allocates.
    for (auto& v : mVoices) {
        v.karplusBuf.reserve(kMaxKarplusBuf);
        v.drumCombBuf.reserve(kMaxDrumCombBuf);
    }

    return true;
}

void AudioEngine::start() {
    if (mStream) {
        {
            std::lock_guard<std::mutex> lock(mVoiceMutex);
            // Only prime a row on the fresh idle→running transition.
            //
            // Dart also calls start() after re-loading the queue mid-playback
            // (queued pattern jumps in _rebuildNativeSongQueueFromSlot and
            // song-loop restart in _restartSongFromBeginningForLoop). In
            // those cases the audio callback is still running its own row
            // pump — priming row 0 here would fire the new queue's first
            // row a second time on top of the natural boundary advance,
            // producing the double-trigger of the first sample. Leaving
            // mQueuedPlaybackRowIndex at 0 (as set by the caller's
            // clearQueuedPlaybackRows()) lets the callback pick up the new
            // queue seamlessly at the next row boundary.
            if (!mPlayheadRunning.load() && !mQueuedPlaybackRows.empty()) {
                mQueuedPlaybackRowIndex = 0;
                mPlayheadSampleCounter = 0;
                primeNextQueuedPlaybackRowLocked();
                mPlayheadRunning.store(true);
            }
        }
        if (!mStarted) {
            mStream->requestStart();
            mStarted = true;
            LOGI("Stream started");
        }
    }
}

void AudioEngine::stop() {
    haltTransport();
    if (mStream) {
        {
            std::lock_guard<std::mutex> lock(mVoiceMutex);
            mPreviewBypassTrackInserts.fill(false);
            for (auto& v : mVoices) {
                v.gainTarget        = 0.0f;
                v.pendingWaveform   = -1;   // cancel any mid-swap; prevents re-trigger after stop
                v.pendingGainTarget = 0.0f;
                v.noteHeld          = false;
                v.envStage          = EnvelopeStage::Idle;
                v.envLevel          = 0.0f;
                v.filterEnvStage    = EnvelopeStage::Idle;
                v.filterEnvLevel    = 0.0f;
                v.midiNote          = -1;
                v.currentFreq       = 0.0f;
                v.targetFreq        = 0.0f;
                v.filterLow         = 0.0f;
                v.filterBand        = 0.0f;
                v.karplusMode       = false;
                v.karplusActive     = false;
                v.karplusBuf.clear();
                v.karplusPos        = 0;
                v.karplusDispersionState = 0.0f;
                v.karplusBodyState  = 0.0f;
                v.karplusBodyState2 = 0.0f;
                v.samplerMode       = false;
                v.sampleActive      = false;
                v.sampleSlot        = -1;
                v.samplePos         = 0.0;
                v.sampleStep        = 1.0;
                v.declickTailFramesLeft = 0;
                v.drumMode          = false;
                v.drumActive        = false;
                v.drumCombBuf.clear();
                v.drumCombPos       = 0;
                v.drumFilterLow     = 0.0f;
                v.drumFilterBand    = 0.0f;
            }
        }
        LOGI("Transport stopped (voices muted, stream kept running)");
    }
}

void AudioEngine::stopTransportSoft() {
    // Halts the sequencer only — deliberately does NOT touch mVoices, so
    // any currently-sounding notes/samples keep ringing (holding sustain,
    // finishing their release, etc.) exactly as if playback had not
    // stopped. This avoids the click of an instant kill when a non-looped
    // pattern/song simply reaches its natural end.
    haltTransport();
    LOGI("Transport stopped softly (voices left ringing, stream kept running)");
}

void AudioEngine::haltTransport() {
    mPlayheadRunning.store(false);
    mPendingRowAdvances.store(0);
    resetPlayheadPhase();
    std::lock_guard<std::mutex> meterLock(mMeterMutex);
    mTrackMeterPeakL.fill(0.0f);
    mTrackMeterPeakR.fill(0.0f);
    mMasterMeterPeakL = 0.0f;
    mMasterMeterPeakR = 0.0f;
}

void AudioEngine::close() {
    if (mStream) {
        if (mStarted) {
            mStream->requestStop();
            mStarted = false;
        }
        mStream->close();
        LOGI("Stream closed");
    }
}

// Called from a detached thread when onErrorAfterClose fires.
// Rebuilds the Oboe stream after a device disconnect (phone call, headphone swap, etc.)
// without disturbing transport state or loaded samples.
void AudioEngine::restartStream() {
    mStarted = false;

    oboe::AudioStreamBuilder builder;
    builder.setDirection(oboe::Direction::Output);
    builder.setPerformanceMode(oboe::PerformanceMode::LowLatency);
    builder.setSharingMode(oboe::SharingMode::Shared);  // Shared routes through AudioFlinger, enabling screen-recording capture
    builder.setFormat(oboe::AudioFormat::Float);
    builder.setChannelCount(oboe::ChannelCount::Stereo);
    builder.setUsage(oboe::Usage::Media);
    builder.setDataCallback(this);
    builder.setErrorCallback(this);

    oboe::Result result = builder.openManagedStream(mStream);
    if (result == oboe::Result::OK) {
        mCachedSampleRate = static_cast<float>(mStream->getSampleRate());
        if (mHasFocus) {
            // Only auto-start if we currently own audio focus.
            // If focus was lost (phone call in progress), leave the stream idle;
            // resumeOutputStream() will start it when focus returns.
            oboe::Result startResult = mStream->requestStart();
            if (startResult == oboe::Result::OK) {
                mStarted = true;
                LOGI("Stream restarted after disconnect: sampleRate=%d", mStream->getSampleRate());
            } else {
                LOGE("Stream restart: requestStart failed: %s", oboe::convertToText(startResult));
            }
        } else {
            LOGI("Stream rebuilt (idle — no audio focus, will start on resume): sampleRate=%d",
                 mStream->getSampleRate());
        }
    } else {
        LOGE("Stream restart failed: %s", oboe::convertToText(result));
    }
}

// Stop stream output without touching transport state (used on audio-focus loss).
void AudioEngine::pauseOutputStream() {
    mHasFocus = false;
    if (mStream && mStarted) {
        mStream->requestStop();
        mStarted = false;
        LOGI("Stream output paused (audio focus loss)");
    }
}

// Resume stream output after focus is regained.
// Falls back to a full stream rebuild if requestStart() fails (e.g. stream was
// closed by onErrorAfterClose during a phone call and never successfully reopened).
void AudioEngine::resumeOutputStream() {
    mHasFocus = true;
    if (!mStarted) {
        if (mStream) {
            oboe::Result r = mStream->requestStart();
            if (r == oboe::Result::OK) {
                mStarted = true;
                LOGI("Stream output resumed (audio focus gained)");
                return;
            }
            LOGI("requestStart failed (%s) — full stream rebuild", oboe::convertToText(r));
        }
        // Stream is null or in a bad state — rebuild from scratch.
        restartStream();
    }
}

// oboe::AudioStreamErrorCallback — fires on a background thread after the stream is closed.
void AudioEngine::onErrorAfterClose(oboe::AudioStream* /*stream*/, oboe::Result error) {
    if (error == oboe::Result::ErrorDisconnected) {
        LOGI("Audio device disconnected — scheduling stream rebuild");
        std::thread([this]() { restartStream(); }).detach();
    }
}

void AudioEngine::setTempo(double bpm) {
    mBpm.store(bpm);
}

bool AudioEngine::loadWavMono16OrFloat(const std::string& path, SampleData& outSample) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        LOGE("Sampler: failed to open file %s", path.c_str());
        return false;
    }

    std::vector<uint8_t> fileData((std::istreambuf_iterator<char>(in)),
                                  std::istreambuf_iterator<char>());
    if (fileData.size() < 44) {
        LOGE("Sampler: file too small %s", path.c_str());
        return false;
    }

    if (std::memcmp(fileData.data(), "RIFF", 4) != 0 ||
        std::memcmp(fileData.data() + 8, "WAVE", 4) != 0) {
        LOGE("Sampler: not a RIFF/WAVE file %s", path.c_str());
        return false;
    }

    uint16_t audioFormat = 0;
    uint16_t numChannels = 0;
    uint32_t sampleRate = 44100;
    uint16_t bitsPerSample = 0;
    const uint8_t* dataPtr = nullptr;
    uint32_t dataSize = 0;

    size_t pos = 12;
    while (pos + 8 <= fileData.size()) {
        const char* chunkId = reinterpret_cast<const char*>(fileData.data() + pos);
        const uint32_t chunkSize = readLe32(fileData.data() + pos + 4);
        pos += 8;
        if (pos + chunkSize > fileData.size()) break;

        if (std::memcmp(chunkId, "fmt ", 4) == 0 && chunkSize >= 16) {
            const uint8_t* fmt = fileData.data() + pos;
            audioFormat = readLe16(fmt + 0);
            numChannels = readLe16(fmt + 2);
            sampleRate = readLe32(fmt + 4);
            bitsPerSample = readLe16(fmt + 14);
        } else if (std::memcmp(chunkId, "data", 4) == 0) {
            dataPtr = fileData.data() + pos;
            dataSize = chunkSize;
        }

        pos += chunkSize;
        if (chunkSize & 1u) pos += 1; // word-align chunks
    }

    if (!dataPtr || dataSize == 0 || numChannels == 0) {
        LOGE("Sampler: missing fmt/data chunk %s", path.c_str());
        return false;
    }

    const int bytesPerSample = bitsPerSample / 8;
    const int frameBytes = bytesPerSample * numChannels;
    if (bytesPerSample <= 0 || frameBytes <= 0) {
        LOGE("Sampler: invalid sample format %s", path.c_str());
        return false;
    }

    const size_t frameCount = dataSize / static_cast<uint32_t>(frameBytes);
    if (frameCount == 0) {
        LOGE("Sampler: empty sample data %s", path.c_str());
        return false;
    }

    outSample.mono.assign(frameCount, 0.0f);
    outSample.sampleRate = static_cast<int>(sampleRate);

    // Validate format before the loop.
    const bool fmt_pcm8   = (audioFormat == 1 && bitsPerSample == 8);
    const bool fmt_pcm16  = (audioFormat == 1 && bitsPerSample == 16);
    const bool fmt_pcm24  = (audioFormat == 1 && bitsPerSample == 24);
    const bool fmt_float32 = (audioFormat == 3 && bitsPerSample == 32);
    if (!fmt_pcm8 && !fmt_pcm16 && !fmt_pcm24 && !fmt_float32) {
        LOGE("Sampler: unsupported WAV format (audioFormat=%d bits=%d) %s",
             audioFormat, bitsPerSample, path.c_str());
        return false;
    }

    for (size_t i = 0; i < frameCount; ++i) {
        const uint8_t* f = dataPtr + i * frameBytes;
        // Sum all channels then average to get mono.
        float sum = 0.0f;
        for (uint16_t ch = 0; ch < numChannels; ++ch) {
            const uint8_t* s = f + ch * (bitsPerSample / 8);
            float sample = 0.0f;
            if (fmt_pcm8) {
                // 8-bit PCM is unsigned; 128 = silence.
                sample = (static_cast<float>(s[0]) - 128.0f) / 128.0f;
            } else if (fmt_pcm16) {
                const int16_t v = static_cast<int16_t>(readLe16(s));
                sample = static_cast<float>(v) / 32768.0f;
            } else if (fmt_pcm24) {
                // 24-bit little-endian signed.
                const int32_t raw = static_cast<int32_t>(
                    static_cast<uint32_t>(s[0]) |
                    (static_cast<uint32_t>(s[1]) << 8) |
                    (static_cast<uint32_t>(s[2]) << 16));
                // Sign-extend from 24 to 32 bits.
                const int32_t v = (raw & 0x800000) ? (raw | static_cast<int32_t>(0xFF000000)) : raw;
                sample = static_cast<float>(v) / 8388608.0f;
            } else { // float32
                std::memcpy(&sample, s, sizeof(float));
            }
            sum += sample;
        }
        outSample.mono[i] = std::clamp(sum / static_cast<float>(numChannels), -1.0f, 1.0f);
    }

    return true;
}

bool AudioEngine::setSamplerSample(int slot, const std::string& path) {
    const int safe = std::clamp(slot, 0, static_cast<int>(mSamplerSlots.size()) - 1);

    if (path.empty()) {
        std::lock_guard<std::mutex> lock(mVoiceMutex);
        mSamplerSlots[safe].mono.clear();
        mSamplerSlots[safe].originalMono.clear();
        mSamplerSlots[safe].sampleRate = 44100;
        LOGI("Sampler: cleared slot %d", safe);
        return true;
    }

    SampleData loaded;
    if (!loadWavMono16OrFloat(path, loaded)) {
        LOGE("Sampler: load failed for slot %d path=%s", safe, path.c_str());
        return false;
    }
    // Keep a permanent copy of the original for re-baking stretch.
    loaded.originalMono = loaded.mono;

    {
        std::lock_guard<std::mutex> lock(mVoiceMutex);
        mSamplerSlots[safe] = std::move(loaded);
    }
    LOGI("Sampler: loaded slot %d (%zu frames @ %d Hz) from %s",
         safe, mSamplerSlots[safe].mono.size(), mSamplerSlots[safe].sampleRate, path.c_str());
    return true;
}

void AudioEngine::updateStretch(int slot, bool enabled, int beats, float bpm, bool preservePitch) {
    const int safe = std::clamp(slot, 0, static_cast<int>(mSamplerSlots.size()) - 1);

    // --- Grab a local copy of the original buffer (under lock, then release) ---
    std::vector<float> src;
    int srcSampleRate = 44100;
    {
        std::lock_guard<std::mutex> lock(mVoiceMutex);
        src           = mSamplerSlots[safe].originalMono; // copy
        srcSampleRate = mSamplerSlots[safe].sampleRate;
    }

    if (src.empty()) {
        LOGI("Stretch: slot %d has no sample, skipping", safe);
        return;
    }

    if (!enabled) {
        // Restore original buffer — instant, no DSP needed.
        std::lock_guard<std::mutex> lock(mVoiceMutex);
        mSamplerSlots[safe].mono = mSamplerSlots[safe].originalMono;
        LOGI("Stretch: slot %d restored to original (%zu frames)", safe, mSamplerSlots[safe].mono.size());
        return;
    }

    if (bpm <= 0.0f || beats <= 0) {
        LOGE("Stretch: invalid bpm=%.2f beats=%d for slot %d", bpm, beats, safe);
        return;
    }

    // --- Compute target length ---
    const size_t origFrames   = src.size();
    const double targetSecs   = (static_cast<double>(beats) * 60.0) / static_cast<double>(bpm);
    const size_t targetFrames = static_cast<size_t>(targetSecs * static_cast<double>(srcSampleRate));

    if (targetFrames < 2) {
        LOGE("Stretch: target too short (%zu frames) for slot %d", targetFrames, safe);
        return;
    }

    LOGI("Stretch: slot %d  orig=%zu  target=%zu  beats=%d  bpm=%.2f  preservePitch=%d",
         safe, origFrames, targetFrames, beats, bpm, preservePitch ? 1 : 0);

    std::vector<float> stretched;

    if (preservePitch) {
        // ── Method B: WSOLA pitch-preserved time-stretch (license-free) ──────
        const double stretchRatio = static_cast<double>(targetFrames) /
                                    static_cast<double>(origFrames);
        StriaSolaStretcher sola(srcSampleRate);
        stretched = sola.process(src, stretchRatio);
        LOGI("Stretch(SOLA): slot %d  orig=%zu  out=%zu  target=%zu",
             safe, origFrames, stretched.size(), targetFrames);

    } else {
        // ── Method A: linear-interpolation resampler (speed/pitch linked) ─────
        stretched.resize(targetFrames);
        const double ratio = static_cast<double>(origFrames - 1) /
                             static_cast<double>(targetFrames - 1);
        for (size_t i = 0; i < targetFrames; ++i) {
            const double srcIdx  = static_cast<double>(i) * ratio;
            const size_t idxLow  = static_cast<size_t>(srcIdx);
            const size_t idxHigh = (idxLow + 1 < origFrames) ? idxLow + 1 : idxLow;
            const float  t       = static_cast<float>(srcIdx - static_cast<double>(idxLow));
            stretched[i] = src[idxLow] + t * (src[idxHigh] - src[idxLow]);
        }
    }

    // --- Atomic swap under lock (audio callback reads mono under the same lock) ---
    {
        std::lock_guard<std::mutex> lock(mVoiceMutex);
        mSamplerSlots[safe].mono = std::move(stretched);
    }
    LOGI("Stretch: slot %d done (%zu frames out)", safe, mSamplerSlots[safe].mono.size());
}

void AudioEngine::triggerRow(const std::vector<int>& rowData) {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    triggerRowLocked(rowData);
}

void AudioEngine::triggerRowLocked(const std::vector<int>& rowData) {
    // Reset sub-row event state for the new row so stale events from the
    // previous row cannot fire into this one.
    mSubRowSampleCounter = 0;
    mPendingRetrigs.clear();
    mPendingArp.clear();
    mPendingDelays.clear();
    mPendingKills.clear();
    // Current canonical stride is 49 (as of sampler LFO + mode feature):
    // [note, vol, pan, wave, instrumentType, 44 params].
    // Fall back to legacy stride 48 / 44 / 42 / 39 / 36 / 34 / 25 / 24 / 23 / 18 / 4.
    int stride = 4;
    if      (rowData.size() % 49 == 0) stride = 49;
    else if (rowData.size() % 48 == 0) stride = 48;
    else if (rowData.size() % 44 == 0) stride = 44;
    else if (rowData.size() % 42 == 0) stride = 42;
    else if (rowData.size() % 39 == 0) stride = 39;
    else if (rowData.size() % 36 == 0) stride = 36;
    else if (rowData.size() % 34 == 0) stride = 34;
    else if (rowData.size() % 25 == 0) stride = 25;
    else if (rowData.size() % 24 == 0) stride = 24;
    else if (rowData.size() % 23 == 0) stride = 23;
    else if (rowData.size() % 18 == 0) stride = 18;
    const int trackCount = static_cast<int>(std::min(rowData.size() / stride, mVoices.size()));

    // Default synth values used when stride is 4 (no synth params in packet).
    static constexpr int kDefDetune  = static_cast<int>(0.50f * 255);
    static constexpr int kDefCutoff  = static_cast<int>(0.70f * 255);
    static constexpr int kDefRes     = static_cast<int>(0.20f * 255);
    static constexpr int kDefFMode   = 0;
    static constexpr int kDefFAtk    = static_cast<int>(0.01f * 255);
    static constexpr int kDefFDec    = static_cast<int>(0.25f * 255);
    static constexpr int kDefFSus    = 0;
    static constexpr int kDefFRel    = static_cast<int>(0.25f * 255);
    static constexpr int kDefFAmt    = static_cast<int>(0.50f * 255);
    static constexpr int kDefAtk     = static_cast<int>(0.02f * 255);
    static constexpr int kDefDec     = static_cast<int>(0.30f * 255);
    static constexpr int kDefSus     = static_cast<int>(0.80f * 255);
    static constexpr int kDefRel     = static_cast<int>(0.25f * 255);
    static constexpr int kDefGlide   = 0;
    static constexpr int kDefInstVol = static_cast<int>(0.80f * 255);
    static constexpr int kDefLfoRate = static_cast<int>(0.20f * 255);
    static constexpr int kDefLfoDep  = 0;
    static constexpr int kDefLfoTgt  = 0;
    static constexpr int kDefDrive   = 0;

    for (int i = 0; i < trackCount; ++i) {
        const int base = i * stride;
        const int n    = rowData[base];
        const int vol  = rowData[base + 1];
        const int pan  = rowData[base + 2];
        const int wave = rowData[base + 3];
        // instrumentType: 0=synth, 1=sampler, 2=Karplus.
        // Present in 24- and 25-stride row packets.
        const int instrumentType = (stride >= 24) ? rowData[base + 4] : 0;
        // Synth params (stride 24/23 full; stride 18 compat; stride 4 defaults)
        const int pBase = (stride >= 24) ? base + 5 : base + 4;
        const bool full24 = (stride >= 24); // includes stride 25
        const bool full23 = (stride == 23);
        const bool full   = (stride >= 18);
        const int detune    = full   ? rowData[pBase +  0] : kDefDetune;
        const int cutoff    = full   ? rowData[pBase +  1] : kDefCutoff;
        const int resonance = full   ? rowData[pBase +  2] : kDefRes;
        // stride-18 had no filterMode between resonance and filterAtk
        const int filterMode = (full24 || full23) ? rowData[pBase +  3] : kDefFMode;
        const int fatk    = (full24 || full23) ? rowData[pBase +  4] : (full ? rowData[pBase + 3] : kDefFAtk);
        const int fdec    = (full24 || full23) ? rowData[pBase +  5] : (full ? rowData[pBase + 4] : kDefFDec);
        const int fsus    = (full24 || full23) ? rowData[pBase +  6] : (full ? rowData[pBase + 5] : kDefFSus);
        const int frel    = (full24 || full23) ? rowData[pBase +  7] : (full ? rowData[pBase + 6] : kDefFRel);
        const int famt    = (full24 || full23) ? rowData[pBase +  8] : (full ? rowData[pBase + 7] : kDefFAmt);
        const int atk     = (full24 || full23) ? rowData[pBase +  9] : (full ? rowData[pBase + 8] : kDefAtk);
        const int dec     = (full24 || full23) ? rowData[pBase + 10] : (full ? rowData[pBase + 9] : kDefDec);
        const int sus     = (full24 || full23) ? rowData[pBase + 11] : (full ? rowData[pBase +10] : kDefSus);
        const int rel     = (full24 || full23) ? rowData[pBase + 12] : (full ? rowData[pBase +11] : kDefRel);
        const int glide   = (full24 || full23) ? rowData[pBase + 13] : (full ? rowData[pBase +12] : kDefGlide);
        const int instVol = (full24 || full23) ? rowData[pBase + 14] : (full ? rowData[pBase +13] : kDefInstVol);
        const int lfoRate = (full24 || full23) ? rowData[pBase + 15] : kDefLfoRate;
        const int lfoDepth= (full24 || full23) ? rowData[pBase + 16] : kDefLfoDep;
        const int lfoTgt  = (full24 || full23) ? rowData[pBase + 17] : kDefLfoTgt;
        const int drive   = (full24 || full23) ? rowData[pBase + 18] : kDefDrive;
        const int reverse     = (stride >= 25) ? rowData[pBase + 19] : 0;
        const int osc1GainRaw = (stride >= 34) ? rowData[pBase + 20] : 255;
        const int osc2OnRaw   = (stride >= 34) ? rowData[pBase + 21] : 0;
        const int osc2WaveRaw = (stride >= 34) ? rowData[pBase + 22] : 0;
        const int osc2DetRaw  = (stride >= 34) ? rowData[pBase + 23] : 128;
        const int osc2GnRaw   = (stride >= 34) ? rowData[pBase + 24] : 0;
        const int osc3OnRaw   = (stride >= 34) ? rowData[pBase + 25] : 0;
        const int osc3WaveRaw = (stride >= 34) ? rowData[pBase + 26] : 0;
        const int osc3DetRaw  = (stride >= 34) ? rowData[pBase + 27] : 128;
        const int osc3GnRaw   = (stride >= 34) ? rowData[pBase + 28] : 0;
        const int osc2FmRaw   = (stride >= 36) ? rowData[pBase + 29] : 0;
        const int osc3FmRaw   = (stride >= 36) ? rowData[pBase + 30] : 0;
        const int osc1OctRaw  = (stride >= 39) ? (int)rowData[pBase + 31] - 2 : 0;
        const int osc2OctRaw  = (stride >= 39) ? (int)rowData[pBase + 32] - 2 : 0;
        const int osc3OctRaw  = (stride >= 39) ? (int)rowData[pBase + 33] - 2 : 0;
        const int treSpeedRaw = (stride >= 42) ? rowData[pBase + 34] : 0;
        const int treDepthRaw = (stride >= 42) ? rowData[pBase + 35] : 0;
        const int treModeRaw  = (stride >= 42) ? rowData[pBase + 36] : 0;
        const int loopStartRaw = (stride >= 44) ? rowData[pBase + 37] : 0;
        const int loopEndRaw   = (stride >= 44) ? rowData[pBase + 38] : 255;
        const int lfoWaveRaw   = (stride >= 48) ? rowData[pBase + 39] : 0;
        const int lfoRateIdxRaw= (stride >= 48) ? rowData[pBase + 40] : 5;
        const int lfoTargetsRaw= (stride >= 48) ? rowData[pBase + 41] : 0;
        const int lfoDepthRaw  = (stride >= 48) ? rowData[pBase + 42] : 0;
        const int lfoModeRaw   = (stride >= 49) ? rowData[pBase + 43] : 2;
        auto& v = mVoices[i];

        // note encoding:
        //  0..127   = note-on
        //  -1       = hold
        //  -2       = note-off
        //  <= -1000 = pitch-only update, midi = -1000 - note
        const bool pitchOnly = (n <= -1000);
        const int pitchMidi = pitchOnly ? std::clamp(-1000 - n, 0, 127) : n;

        const bool isSampler = (instrumentType == 1);
        const bool isKarplus = (instrumentType == 2);
        const bool isDrum = (instrumentType == 3);

        const int clampedWave = std::clamp(wave, 0, 5);
        const bool waveChanging = (clampedWave != v.waveform);

        v.detuneNorm = byteToNorm(detune);
        v.cutoffNorm = byteToNorm(cutoff);
        v.resonanceNorm = byteToNorm(resonance);
        v.filterMode = std::clamp(filterMode, 0, 2);
        v.filterAttackSec = normToAttackSec(byteToNorm(fatk));
        v.filterDecaySec = normToDecaySec(byteToNorm(fdec));
        v.filterSustainLevel = byteToNorm(fsus);
        v.filterReleaseSec = normToReleaseSec(byteToNorm(frel));
        v.filterEnvAmt = byteToNorm(famt);
        v.attackSec = normToAttackSec(byteToNorm(atk));
        v.decaySec = normToDecaySec(byteToNorm(dec));
        v.sustainLevel = byteToNorm(sus);
        v.releaseSec = normToReleaseSec(byteToNorm(rel));
        v.glideSec = normToGlideSec(byteToNorm(glide));
        v.instrumentVolume = byteToNorm(instVol);
        // LFO params are updated on every row (note-on and hold) so that
        // a VIB command placed on a hold row can take effect mid-note.
        // The Dart carry system propagates VIB values forward through all
        // subsequent hold rows, so there is no risk of accidental reset.
        // Note-off (n == -2) is excluded as the voice is silenced anyway.
        if (n != -2) {
            v.lfoRateNorm = byteToNorm(lfoRate);
            v.lfoDepth    = byteToNorm(lfoDepth);
            v.lfoTarget   = std::clamp(lfoTgt, 0, 2);
            // TRE/GAT tremolo/gate: updated on every non-note-off row so that
            // TRE/GAT on hold rows takes effect mid-note (same as VIB).
            v.treSpeedNorm = byteToNorm(treSpeedRaw);
            v.treDepth     = byteToNorm(treDepthRaw);
            v.treMode      = std::clamp(treModeRaw, 0, 2);
        }
        v.drive = byteToNorm(drive);
        v.osc1Gain       = byteToNorm(osc1GainRaw);
        v.osc2On         = (osc2OnRaw != 0);
        v.osc2Waveform   = std::clamp(osc2WaveRaw, 0, 5);
        v.osc2DetuneNorm = byteToNorm(osc2DetRaw);
        v.osc2Gain       = byteToNorm(osc2GnRaw);
        v.osc3On         = (osc3OnRaw != 0);
        v.osc3Waveform   = std::clamp(osc3WaveRaw, 0, 5);
        v.osc3DetuneNorm = byteToNorm(osc3DetRaw);
        v.osc3Gain       = byteToNorm(osc3GnRaw);
        v.osc2FmDepth    = byteToNorm(osc2FmRaw);
        v.osc3FmDepth    = byteToNorm(osc3FmRaw);
        v.osc1Oct        = osc1OctRaw;
        v.osc1OctMult    = std::pow(2.0f, (float)osc1OctRaw);
        v.osc2Oct        = osc2OctRaw;
        v.osc2OctMult    = std::pow(2.0f, (float)osc2OctRaw);
        v.osc3Oct        = osc3OctRaw;
        v.osc3OctMult    = std::pow(2.0f, (float)osc3OctRaw);
        v.karplusDecayNorm = byteToNorm(detune);
        v.karplusDampingNorm = byteToNorm(cutoff);
        v.karplusToneNorm = byteToNorm(resonance);
        v.karplusStretchNorm = byteToNorm(filterMode);
        v.karplusPickPositionNorm = byteToNorm(fatk);
        v.karplusAttackColorNorm = byteToNorm(fdec);
        v.karplusBodyNorm = byteToNorm(fsus);
        v.karplusDriveNorm = byteToNorm(frel);
        // Drum Synth reuses the same 8 payload slots the Karplus mapping
        // above uses, since only one of isKarplus/isDrum is ever active.
        v.drumPitchNorm = byteToNorm(detune);
        v.drumPitchDecayNorm = byteToNorm(cutoff);
        v.drumToneNorm = byteToNorm(resonance);
        v.drumCutoffNorm = byteToNorm(filterMode);
        v.drumResonanceNorm = byteToNorm(fatk);
        v.drumDecayNorm = byteToNorm(fdec);
        v.drumPunchNorm = byteToNorm(fsus);
        v.drumDriveNorm = byteToNorm(frel);

        if (vol >= 0) {
            const int clampedVol = std::clamp(vol, 0, 255);
            v.level = static_cast<float>(clampedVol) / 255.0f;
        }

        if (pan >= 0) {
            const int clampedPan = std::clamp(pan, 0, 255);
            v.panTarget = static_cast<float>(clampedPan) / 255.0f;
        }

        v.samplerMode = isSampler;
        v.karplusMode = isKarplus;
        v.drumMode = isDrum;
        if (isSampler) {
            v.karplusActive = false;
            v.karplusBuf.clear();
            v.karplusBodyState = 0.0f;
            v.karplusBodyState2 = 0.0f;
            v.sampleSlot = std::clamp(wave, 0, static_cast<int>(mSamplerSlots.size()) - 1);
            v.loopMode   = std::clamp(drive, 0, 2);
            v.sampleReverse = (reverse != 0);
            v.loopStartNorm = byteToNorm(loopStartRaw);
            v.loopEndNorm   = byteToNorm(loopEndRaw);
            if (v.loopEndNorm < v.loopStartNorm) {
                std::swap(v.loopStartNorm, v.loopEndNorm);
            }
            v.sampleGain = 1.0f;

            // Sampler reuses the synth-filter byte slots in the row payload for
            // its own HP -> LP filter (zero payload-size change):
            //   payload[3] (filterMode)  -> filter enabled flag (0/1)
            //   payload[1] (cutoff)      -> HP cutoff
            //   payload[2] (resonance)   -> HP resonance
            //   payload[4] (filterAtk)   -> LP cutoff
            //   payload[5] (filterDec)   -> LP resonance
            const bool newFilterOn = (filterMode > 0);
            if (newFilterOn != v.samplerFilterOn) {
                // Clear SVF state on enable/disable to avoid pops.
                v.samplerHpLow = v.samplerHpBand = 0.0f;
                v.samplerLpLow = v.samplerLpBand = 0.0f;
            }
            v.samplerFilterOn = newFilterOn;
            v.samplerHpCutoff = byteToNorm(cutoff);
            v.samplerHpRes    = byteToNorm(resonance);
            v.samplerLpCutoff = byteToNorm(fatk);
            v.samplerLpRes    = byteToNorm(fdec);

            // Sampler LFO params. Updated on every non-note-off row so an LFO
            // set on a hold row can take effect mid-note (same policy as VIB).
            if (n != -2) {
                v.samplerLfoWave    = std::clamp(lfoWaveRaw, 0, 6);
                v.samplerLfoRateIdx = std::clamp(lfoRateIdxRaw, 0, 9);
                v.samplerLfoTargets = std::clamp(lfoTargetsRaw, 0, 15);
                v.samplerLfoDepth   = byteToNorm(lfoDepthRaw);
                v.samplerLfoMode    = std::clamp(lfoModeRaw, 0, 2);
            }

            if (n >= 0) {
                // Only update the playback region on note-on.
                // Hold rows must not overwrite the slice boundaries set by the
                // triggering row's SL command.
                v.sampleStartNorm = std::clamp(v.lfoRateNorm, 0.0f, 1.0f);
                v.sampleEndNorm   = std::clamp(v.lfoDepth,    0.0f, 1.0f);
                if (v.sampleEndNorm < v.sampleStartNorm) {
                    std::swap(v.sampleStartNorm, v.sampleEndNorm);
                }
                const auto& s = mSamplerSlots[v.sampleSlot];
                if (!s.mono.empty()) {
                    // Anti-click: if this voice is already sounding, capture
                    // its last output as a short fading tail instead of
                    // letting the jump to the new note's silent attack start
                    // produce an instantaneous (clicking) discontinuity.
                    if (v.sampleActive) {
                        constexpr float kDeclickTailMs = 3.0f;
                        v.declickTailGain0 = v.sampleLastOutput;
                        v.declickTailFramesTotal = std::max(
                            1,
                            static_cast<int>(kDeclickTailMs * 0.001f * mCachedSampleRate));
                        v.declickTailFramesLeft = v.declickTailFramesTotal;
                    }
                    v.midiNote = n;
                    // Cancel any in-flight SLU/SLD step ramp — new note takes over.
                    v.pitchRampSamplesLeft = 0;
                    const float detuneSemitones = (v.detuneNorm - 0.5f) * 24.0f;
                    const float semis = static_cast<float>(n - 60) + detuneSemitones;
                    v.sampleStep = std::pow(2.0f, semis / 12.0f);
                    const int sampleFrames = static_cast<int>(s.mono.size());
                    const int startFrame = std::clamp(
                        static_cast<int>(v.sampleStartNorm * static_cast<float>(sampleFrames - 1)),
                        0, sampleFrames - 1);
                    const int endFrame = std::clamp(
                        static_cast<int>(v.sampleEndNorm * static_cast<float>(sampleFrames)),
                        startFrame + 1, sampleFrames);
                    v.samplePos = v.sampleReverse ? static_cast<double>(endFrame - 1)
                                                  : static_cast<double>(startFrame);
                    v.sampleElapsedFrames = 0.0;
                    v.samplePingDir = v.sampleReverse;
                    v.sampleActive = true;
                    v.samplerReleaseActive = false;
                    v.samplerReleaseStartFrames = 0.0;
                    v.sampleHasEnteredLoopRegion = false;
                    // Reset LFO phase so the modulation restarts with each note
                    // (enables ramp-up / envelope-style long cycles).
                    v.samplerLfoPhase = 0.0;
                    v.samplerLfoRandVal = 0.0f;
                    // Clear filter SVF state on note-on to avoid carryover thumps.
                    v.samplerHpLow = v.samplerHpBand = 0.0f;
                    v.samplerLpLow = v.samplerLpBand = 0.0f;
                } else {
                    v.sampleActive = false;
                }
            } else if (pitchOnly) {
                if (v.sampleActive && v.sampleSlot >= 0 &&
                    v.sampleSlot < static_cast<int>(mSamplerSlots.size())) {
                    v.midiNote = pitchMidi;
                    const float detuneSemitones = (v.detuneNorm - 0.5f) * 24.0f;
                    const float semis = static_cast<float>(pitchMidi - 60) + detuneSemitones;
                    v.sampleStep = std::pow(2.0f, semis / 12.0f);
                }
            } else if (n == -2) {
                // Note-off: always fade out over the release setting instead of
                // stopping instantly — an instant stop produces an audible click.
                if (v.sampleActive) {
                    v.samplerReleaseActive = true;
                    v.samplerReleaseStartFrames = v.sampleElapsedFrames;
                }
                v.midiNote = -1;
            }

            // Disable synth envelopes while sampler mode is active.
            v.noteHeld = false;
            v.envStage = EnvelopeStage::Idle;
            v.filterEnvStage = EnvelopeStage::Idle;
            v.gain = 0.0f;
            v.gainTarget = 0.0f;
            v.pendingWaveform = -1;
            continue;
        }

        if (isKarplus) {
            v.sampleActive = false;
            v.filterLow = 0.0f;
            v.filterBand = 0.0f;
            v.pendingWaveform = -1;

            if (n >= 0) {
                startKarplusVoice(v, n, static_cast<int>(mCachedSampleRate));
            } else if (pitchOnly) {
                startKarplusVoice(v, pitchMidi, static_cast<int>(mCachedSampleRate));
            } else if (n == -2) {
                v.noteHeld = false;
                v.gainTarget = 0.0f;
            }
            continue;
        }

        if (isDrum) {
            v.sampleActive = false;
            v.filterLow = 0.0f;
            v.filterBand = 0.0f;
            v.pendingWaveform = -1;
            // Piece selector reuses the `wave` payload byte, same convention
            // Sampler uses to reuse it for the sample-slot index.
            v.drumPiece = std::clamp(wave, 0, 4);

            if (n >= 0 || pitchOnly) {
                // Drum synth ignores incoming pitch — the PITCH knob controls
                // tuning for every hit, so both note-on and pitch-only
                // (ARP/SLU/SLD) events simply (re)trigger the same voice.
                startDrumVoice(v, static_cast<int>(mCachedSampleRate));
                v.midiNote = n >= 0 ? n : pitchMidi;
            } else if (n == -2) {
                v.noteHeld = false;
                v.gainTarget = 0.0f;
            }
            continue;
        }

        if (n >= 0) {
            // Note on: change pitch but keep phase to avoid discontinuity click
            v.midiNote   = n;
            // Apply detune: detuneNorm 0.5 = 0 semitones, 0 = -12 st, 1 = +12 st
            const float detuneSemitones = (v.detuneNorm - 0.5f) * 24.0f;
            v.targetFreq = static_cast<float>(midiToFreq(n)) *
                std::pow(2.0f, detuneSemitones / 12.0f);
            if (v.currentFreq <= 0.0f || v.glideSec <= 0.0f) {
                v.currentFreq = v.targetFreq;
            }
            // Cancel any in-flight SLU/SLD pitch ramp — new note takes over.
            v.pitchRampSamplesLeft = 0;
            // Only reset filter state when the voice is effectively idle.
            // Resetting during an overlapping retrigger causes discontinuities (clicks).
            const bool voiceWasActive =
                (v.envStage != EnvelopeStage::Idle) ||
                (v.gain > 1e-4f) ||
                (v.gainTarget > 1e-4f);
            if (!voiceWasActive) {
                v.filterLow = 0.0f;
                v.filterBand = 0.0f;
            }
            // Keep envelope continuity for overlapping retriggers to avoid
            // hard amplitude/cutoff discontinuities (clicks).
            if (!voiceWasActive) {
                v.envLevel       = 0.0f;
                v.filterEnvLevel = 0.0f;
            }
            v.noteHeld   = true;
            v.envStage   = EnvelopeStage::Attack;
            v.filterEnvStage = EnvelopeStage::Attack;
            v.gainTarget = 1.0f;
            v.sampleActive = false;
        } else if (pitchOnly) {
            // Pitch-only update: retune the currently held voice without
            // retriggering amp/filter envelopes.
            if (v.midiNote >= 0) {
                v.midiNote = pitchMidi;
                const float detuneSemitones = (v.detuneNorm - 0.5f) * 24.0f;
                v.targetFreq = static_cast<float>(midiToFreq(pitchMidi)) *
                    std::pow(2.0f, detuneSemitones / 12.0f);
                if (v.currentFreq <= 0.0f || v.glideSec <= 0.0f) {
                    v.currentFreq = v.targetFreq;
                }
            }
        } else if (n == -2) {
            // Note off
            v.noteHeld = false;
            if (v.envStage != EnvelopeStage::Idle) {
                v.envStage = EnvelopeStage::Release;
            }
            if (v.filterEnvStage != EnvelopeStage::Idle) {
                v.filterEnvStage = EnvelopeStage::Release;
            }
        }
        // n == -1: hold — leave voice unchanged

        // Apply waveform: if the voice is currently sounding and the waveform
        // is changing, schedule a fade-to-silence → swap → fade-back-in.
        // This avoids the discontinuity click of an instantaneous waveform switch.
        if (waveChanging) {
            if (v.gain > 1e-3f || v.gainTarget > 1e-3f) {
                v.pendingWaveform   = clampedWave;
                v.pendingGainTarget = v.gainTarget; // save where we're heading
                v.gainTarget        = 0.0f;         // fade out now
            } else {
                // Voice is already silent; switch immediately
                v.waveform        = clampedWave;
                v.pendingWaveform = -1;
            }
        } else {
            v.pendingWaveform = -1; // clear any stale pending swap
        }
    }
}

int32_t AudioEngine::consumePendingRowAdvances() {
    return mPendingRowAdvances.exchange(0);
}

void AudioEngine::resetPlayheadPhase() {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mPlayheadSampleCounter = 0;
}

void AudioEngine::clearQueuedPlaybackRows() {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mQueuedPlaybackRows.clear();
    mQueuedPlaybackRowIndex = 0;
    mPendingNextLoopRows.clear(); // discard any pre-built next pass
}

void AudioEngine::enqueuePlaybackRow(const QueuedPlaybackRow& row) {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mQueuedPlaybackRows.push_back(row);
}

void AudioEngine::setQueuedPlaybackLooping(bool loop) {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mQueuedPlaybackLoop = loop;
}

void AudioEngine::beginPendingRows() {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mPendingNextLoopRows.clear();
}

void AudioEngine::appendPendingRow(const QueuedPlaybackRow& row) {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mPendingNextLoopRows.push_back(row);
}

void AudioEngine::applyQueuedPlaybackRowLocked(const QueuedPlaybackRow& row) {
    mLineSamplesPerRow = std::max<int32_t>(1, row.lineSamples);
    triggerRowLocked(row.rowData);
    if (!row.immediateKillMask.empty()) {
        killVoicesLocked(row.immediateKillMask);
    }
    if (!row.retrigData.empty()) queueRetrigsLocked(row.retrigData);
    if (!row.arpData.empty()) queueArpLocked(row.arpData);
    if (!row.delayData.empty()) queueDelaysLocked(row.delayData);
    if (!row.killData.empty()) queueKillsLocked(row.killData);
    if (!row.sliceCommandData.empty()) queueSliceCommandsLocked(row.sliceCommandData);
    if (!row.mixerCommandData.empty()) queueMixerCommandsLocked(row.mixerCommandData);
    if (!row.insertFxCommandData.empty()) queueInsertFxCommandsLocked(row.insertFxCommandData);
    if (!row.pitchRampData.empty()) applyPitchRampsLocked(row.pitchRampData);
}

bool AudioEngine::primeNextQueuedPlaybackRowLocked() {
    if (mQueuedPlaybackRows.empty()) return false;
    if (mQueuedPlaybackRowIndex >= mQueuedPlaybackRows.size()) {
        if (!mQueuedPlaybackLoop) {
            return false;
        }
        // Double-buffer swap: if a new pass was pre-built by Dart, use it.
        if (!mPendingNextLoopRows.empty()) {
            mQueuedPlaybackRows = std::move(mPendingNextLoopRows);
            mPendingNextLoopRows.clear();
        }
        mQueuedPlaybackRowIndex = 0;
    }
    applyQueuedPlaybackRowLocked(mQueuedPlaybackRows[mQueuedPlaybackRowIndex++]);
    return true;
}

void AudioEngine::killVoices(const std::vector<int>& killMask) {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    killVoicesLocked(killMask);
}

void AudioEngine::killVoicesLocked(const std::vector<int>& killMask) {
    const int n = static_cast<int>(std::min(killMask.size(), mVoices.size()));
    for (int i = 0; i < n; ++i) {
        if (killMask[i] != 1) continue;
        Voice& v = mVoices[i];
        // Trigger note-off: move to release stage without clearing the voice.
        v.noteHeld = false;
        v.envStage = EnvelopeStage::Release;
        if (v.samplerMode) v.sampleActive = false;
        if (v.karplusMode) v.gainTarget = 0.0f;
    }
}

void AudioEngine::queueRetrigs(const std::vector<int>& data) {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    queueRetrigsLocked(data);
}

void AudioEngine::queueRetrigsLocked(const std::vector<int>& data) {
    // data format: groups of 5 ints — [stepNum, totalSteps, trackIdx, note, volume].
    // C++ calculates sample offset from mLineSamplesPerRow so it uses the
    // real row length without relying on Dart's hardcoded 48 kHz constant.
    for (size_t i = 0; i + 4 < data.size(); i += 5) {
        const int stepNum    = data[i];
        const int totalSteps = std::max(1, data[i + 1]);
        const int32_t sampleOffset = (static_cast<int64_t>(mLineSamplesPerRow) * stepNum) / totalSteps;
        const int32_t target = sampleOffset + mSubRowSampleCounter;
        mPendingRetrigs.push_back({target, data[i + 2], data[i + 3], data[i + 4]});
    }
}

void AudioEngine::queueArp(const std::vector<int>& data) {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    queueArpLocked(data);
}

void AudioEngine::queueArpLocked(const std::vector<int>& data) {
    // data format: groups of 4 ints — [stepNum, totalSteps, trackIdx, note].
    // C++ calculates sample offset from mLineSamplesPerRow so it uses the
    // real row length without relying on Dart's hardcoded 48 kHz constant.
    for (size_t i = 0; i + 3 < data.size(); i += 4) {
        const int stepNum    = data[i];
        const int totalSteps = std::max(1, data[i + 1]);
        const int32_t sampleOffset = (static_cast<int64_t>(mLineSamplesPerRow) * stepNum) / totalSteps;
        const int32_t target = sampleOffset + mSubRowSampleCounter;
        mPendingArp.push_back({target, data[i + 2], data[i + 3]});
    }
}

void AudioEngine::applyPitchRampsLocked(const std::vector<int>& data) {
    // data format: groups of 3 ints — [trackIdx, targetMidiNote, durationSamples].
    // Sets up a linear per-sample frequency ramp from currentFreq → targetFreq
    // for sample-accurate smooth slides (SLU/SLD).
    for (size_t i = 0; i + 2 < data.size(); i += 3) {
        const int trackIdx       = data[i];
        const int targetNote     = std::clamp(data[i + 1], 0, 127);
        const int durationSamples = std::max(1, data[i + 2]);
        if (trackIdx < 0 || trackIdx >= static_cast<int>(mVoices.size())) continue;
        Voice& v = mVoices[trackIdx];
        const float detuneSemitones = (v.detuneNorm - 0.5f) * 24.0f;
        if (v.samplerMode) {
            // Sampler: ramp sampleStep (playback speed ratio) rather than currentFreq.
            if (!v.sampleActive) continue;
            const float semis = static_cast<float>(targetNote - 60) + detuneSemitones;
            const float targetStep = std::pow(2.0f, semis / 12.0f);
            v.sampleStepTarget        = targetStep;
            v.sampleStepRampPerSample = (targetStep - static_cast<float>(v.sampleStep)) /
                static_cast<float>(durationSamples);
            v.pitchRampSamplesLeft = durationSamples;
            continue;
        }
        if (v.currentFreq <= 0.0f) continue; // no synth note playing — nothing to ramp
        const float targetFreq = static_cast<float>(midiToFreq(targetNote)) *
            std::pow(2.0f, detuneSemitones / 12.0f);
        v.targetFreq = targetFreq;
        v.pitchRampFreqPerSample = (targetFreq - v.currentFreq) /
            static_cast<float>(durationSamples);
        v.pitchRampSamplesLeft = durationSamples;
    }
}

void AudioEngine::queueDelays(const std::vector<int>& data) {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    queueDelaysLocked(data);
}

void AudioEngine::queueDelaysLocked(const std::vector<int>& data) {
    // data format: groups of 4 ints — [delayPct, trackIdx, note, volume].
    // Convert delay percentage to sample offset using mLineSamplesPerRow.
    for (size_t i = 0; i + 3 < data.size(); i += 4) {
        const int delayPct = std::clamp(data[i], 0, 99);
        const double norm = (delayPct >= 99) ? 1.0 : (delayPct / 100.0);
        const int32_t sampleOffset = std::max(0, static_cast<int32_t>(mLineSamplesPerRow * norm));
        // Clamp strictly below the row length as defensive margin (the
        // audio callback now fires pending events before row-boundary
        // advancement, so this is no longer required for correctness, but
        // keeps the target from ever exactly equaling the boundary sample).
        const int32_t safeOffset = std::min(sampleOffset, mLineSamplesPerRow - 1);
        const int32_t target = safeOffset + mSubRowSampleCounter;
        mPendingDelays.push_back({target, data[i + 1], data[i + 2], data[i + 3]});
    }
}

void AudioEngine::queueKills(const std::vector<int>& data) {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    queueKillsLocked(data);
}

void AudioEngine::queueKillsLocked(const std::vector<int>& data) {
    // data format: groups of 2 ints — [killPct, trackIdx].
    // Convert kill percentage to sample offset using mLineSamplesPerRow.
    for (size_t i = 0; i + 1 < data.size(); i += 2) {
        const int killPct = std::clamp(data[i], 0, 99);
        const double norm = (killPct >= 99) ? 1.0 : (killPct / 100.0);
        const int32_t sampleOffset = std::max(0, static_cast<int32_t>(mLineSamplesPerRow * norm));
        const int32_t safeOffset = std::min(sampleOffset, mLineSamplesPerRow - 1);
        const int32_t target = safeOffset + mSubRowSampleCounter;
        mPendingKills.push_back({target, data[i + 1]});
    }
}

bool AudioEngine::isVoicePlaying(int trackIdx) const {
    if (trackIdx < 0 || trackIdx >= kMaxVoices) {
        return false;
    }
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    const Voice& v = mVoices[trackIdx];
    // Voice is playing if it has a MIDI note and is not in Idle stage.
    if (v.karplusMode) {
        return v.karplusActive || v.gain > 1e-4f || v.gainTarget > 1e-4f;
    }
    if (v.drumMode) {
        return v.drumActive || v.gain > 1e-4f || v.gainTarget > 1e-4f;
    }
    return v.midiNote >= 0 && v.envStage != EnvelopeStage::Idle;
}

int AudioEngine::getVoiceEnvelopeStage(int trackIdx) const {
    if (trackIdx < 0 || trackIdx >= kMaxVoices) {
        return 0; // Idle
    }
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    if (mVoices[trackIdx].karplusMode) {
        return mVoices[trackIdx].karplusActive ? 3 : 0;
    }
    if (mVoices[trackIdx].drumMode) {
        return mVoices[trackIdx].drumActive ? 3 : 0;
    }
    return static_cast<int>(mVoices[trackIdx].envStage);
}

void AudioEngine::queueSliceCommands(const std::vector<int>& data) {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    queueSliceCommandsLocked(data);
}

void AudioEngine::queueSliceCommandsLocked(const std::vector<int>& data) {
    // data format: groups of 4 ints — [playMode, trackIdx, startNormScaled, endNormScaled].
    // startNormScaled and endNormScaled are normalized positions (0-10000 = 0.0-1.0).
    // Slice commands fire immediately at row start (sampleTarget = 0).
    for (size_t i = 0; i + 3 < data.size(); i += 4) {
        const int playMode = std::clamp(data[i], 0, 1);
        const int trackIdx = data[i + 1];
        const int startNormScaled = std::clamp(data[i + 2], 0, 10000);
        const int endNormScaled = std::clamp(data[i + 3], 0, 10000);
        mPendingSliceCommands.push_back({0, trackIdx, startNormScaled, endNormScaled});
    }
}

void AudioEngine::queueMixerCommands(const std::vector<int>& data) {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    queueMixerCommandsLocked(data);
}

void AudioEngine::queueMixerCommandsLocked(const std::vector<int>& data) {
    // data format: groups of 4 ints — [channel, controller, value, unused].
    // channel: 0=master, 1-16=mixer channels
    // controller: 1-4 (pan, mute, solo, volume), 5-9 reserved
    // value: 0-99
    // Mixer commands fire immediately at row start (sampleTarget = 0).
    for (size_t i = 0; i + 3 < data.size(); i += 4) {
        const int channel = std::clamp(data[i], 0, kMaxVoices);
        const int controller = std::clamp(data[i + 1], 1, 9);
        const int value = std::clamp(data[i + 2], 0, 99);
        mPendingMixerCommands.push_back({0, channel, controller, value});
    }
}

void AudioEngine::queueInsertFxCommands(const std::vector<int>& data) {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    queueInsertFxCommandsLocked(data);
}

void AudioEngine::queueInsertFxCommandsLocked(const std::vector<int>& data) {
    // data format: groups of 4 ints — [trackIdx, slotIdx, function, value].
    for (size_t i = 0; i + 3 < data.size(); i += 4) {
        const int trackIdx = std::clamp(data[i], 0, kMaxVoices - 1);
        const int slotIdx = std::clamp(data[i + 1], 0, kMaxInsertSlots - 1);
        const int function = std::clamp(data[i + 2], 0, 9);
        const int value = std::clamp(data[i + 3], 0, 99);
        mPendingInsertFxCommands.push_back({0, trackIdx, slotIdx, function, value});
    }
}

void AudioEngine::setMasterInsertEffect(int slotIdx, int effectType, float initialWetLevel) {
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    InsertEffect& fx = mMasterInserts[slotIdx];
    fx.type = effectType;
    fx.dryWet = std::clamp(initialWetLevel, 0.0f, 1.0f);
    fx.dryLevel = 1.0f;
    fx.wetLevel = std::clamp(initialWetLevel, 0.0f, 1.0f);
    fx.reverb.setdry(0.0f);
    fx.reverb.setwet(1.0f);
    fx.reverb.setmode(fx.reverbFreeze ? 1.0f : 0.0f);
    
    // Reset all effect state variables
    fx.filterCutoff = 0.5f;
    fx.filterResonance = 0.2f;
    fx.filterMode = 0;
    fx.svfLowL = 0.0f;
    fx.svfBandL = 0.0f;
    fx.svfLowR = 0.0f;
    fx.svfBandR = 0.0f;
    fx.delayBufL.clear();
    fx.delayBufR.clear();
    fx.delayWritePos = 0;
    fx.delayHpPrevL = 0.0f;
    fx.delayHpPrevR = 0.0f;
    fx.distDrive = 0.5f;
    fx.distTone = 0.5f;
    fx.distType = 0;
    fx.distToneStateL = 0.0f;
    fx.distToneStateR = 0.0f;
    fx.crushBits = 1.0f;
    fx.crushRate = 1.0f;
    fx.crushHoldL = 0.0f;
    fx.crushHoldR = 0.0f;
    fx.crushAccum = 0.0f;
    fx.chorusBufL.clear();
    fx.chorusBufR.clear();
    fx.chorusBufPos = 0;
    fx.chorusLfoPhL = 0.0f;
    fx.chorusLfoPhR = 0.0f;
    fx.eqDirty = true;
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 5; ++j) {
            fx.eqCoeffs[i][j] = 0.0f;
        }
        for (int ch = 0; ch < 2; ++ch) {
            for (int j = 0; j < 2; ++j) {
                fx.eqZx[i][ch][j] = 0.0f;
                fx.eqZy[i][ch][j] = 0.0f;
            }
        }
    }
    fx.cmpEnvL = 0.0f;
    fx.cmpEnvR = 0.0f;
}

void AudioEngine::setMasterInsertMix(int slotIdx, float dryLevel, float wetLevel) {
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mMasterInserts[slotIdx].dryLevel = std::clamp(dryLevel, 0.0f, 1.0f);
    mMasterInserts[slotIdx].wetLevel = std::clamp(wetLevel, 0.0f, 1.0f);
    mMasterInserts[slotIdx].dryWet = mMasterInserts[slotIdx].wetLevel;
}

void AudioEngine::setMasterInsertBypass(int slotIdx, bool bypass) {
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mMasterInserts[slotIdx].bypass = bypass;
}

void AudioEngine::setMasterLimiterEnabled(bool enabled) {
    mMasterLimiterEnabled.store(enabled);
}

bool AudioEngine::isMasterLimiterEnabled() const {
    return mMasterLimiterEnabled.load();
}

void AudioEngine::setMasterVolumeLinear(float linearGain) {
    // Clamp to a sane ceiling. The safety limiter catches anything above 0 dB,
    // but we still cap to avoid absurd amplification that would just slam the
    // limiter into full gain reduction with no audible benefit.
    mMasterVolume.store(std::clamp(linearGain, 0.0f, 4.0f));
}

void AudioEngine::setMasterReverbParams(int slotIdx, float roomSize, float damp, float width, bool freeze) {
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    if (mMasterInserts[slotIdx].type != 0) return; // type 0 = reverb
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mMasterInserts[slotIdx].reverbRoomSize = std::clamp(roomSize, 0.0f, 1.0f);
    mMasterInserts[slotIdx].reverbDamp = std::clamp(damp, 0.0f, 1.0f);
    mMasterInserts[slotIdx].reverbWidth = std::clamp(width, 0.0f, 1.0f);
    mMasterInserts[slotIdx].reverbFreeze = freeze;
    // Update freeverb instance
    mMasterInserts[slotIdx].reverb.setroomsize(roomSize);
    mMasterInserts[slotIdx].reverb.setdamp(damp);
    mMasterInserts[slotIdx].reverb.setwidth(width);
    mMasterInserts[slotIdx].reverb.setdry(0.0f);
    mMasterInserts[slotIdx].reverb.setwet(1.0f);
    mMasterInserts[slotIdx].reverb.setmode(freeze ? 1.0f : 0.0f);
}

void AudioEngine::setTrackInsertEffect(int trackIdx, int slotIdx, int effectType, float initialWetLevel) {
    if (trackIdx < 0 || trackIdx >= kMaxVoices) return;
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    InsertEffect& fx = mTrackInserts[trackIdx][slotIdx];
    fx.type = effectType;
    fx.dryWet = std::clamp(initialWetLevel, 0.0f, 1.0f);
    fx.dryLevel = 1.0f;
    fx.wetLevel = std::clamp(initialWetLevel, 0.0f, 1.0f);
    fx.reverb.setdry(0.0f);
    fx.reverb.setwet(1.0f);
    fx.reverb.setmode(fx.reverbFreeze ? 1.0f : 0.0f);
    
    // Reset all effect state variables
    fx.filterCutoff = 0.5f;
    fx.filterResonance = 0.2f;
    fx.filterMode = 0;
    fx.svfLowL = 0.0f;
    fx.svfBandL = 0.0f;
    fx.svfLowR = 0.0f;
    fx.svfBandR = 0.0f;
    fx.delayBufL.clear();
    fx.delayBufR.clear();
    fx.delayWritePos = 0;
    fx.delayHpPrevL = 0.0f;
    fx.delayHpPrevR = 0.0f;
    fx.distDrive = 0.5f;
    fx.distTone = 0.5f;
    fx.distType = 0;
    fx.distToneStateL = 0.0f;
    fx.distToneStateR = 0.0f;
    fx.crushBits = 1.0f;
    fx.crushRate = 1.0f;
    fx.crushHoldL = 0.0f;
    fx.crushHoldR = 0.0f;
    fx.crushAccum = 0.0f;
    fx.chorusBufL.clear();
    fx.chorusBufR.clear();
    fx.chorusBufPos = 0;
    fx.chorusLfoPhL = 0.0f;
    fx.chorusLfoPhR = 0.0f;
    fx.eqDirty = true;
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 5; ++j) {
            fx.eqCoeffs[i][j] = 0.0f;
        }
        for (int ch = 0; ch < 2; ++ch) {
            for (int j = 0; j < 2; ++j) {
                fx.eqZx[i][ch][j] = 0.0f;
                fx.eqZy[i][ch][j] = 0.0f;
            }
        }
    }
    fx.cmpEnvL = 0.0f;
    fx.cmpEnvR = 0.0f;
}

void AudioEngine::setTrackInsertMix(int trackIdx, int slotIdx, float dryLevel, float wetLevel) {
    if (trackIdx < 0 || trackIdx >= kMaxVoices) return;
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mTrackInserts[trackIdx][slotIdx].dryLevel = std::clamp(dryLevel, 0.0f, 1.0f);
    mTrackInserts[trackIdx][slotIdx].wetLevel = std::clamp(wetLevel, 0.0f, 1.0f);
    mTrackInserts[trackIdx][slotIdx].dryWet = mTrackInserts[trackIdx][slotIdx].wetLevel;
}

void AudioEngine::setTrackInsertBypass(int trackIdx, int slotIdx, bool bypass) {
    if (trackIdx < 0 || trackIdx >= kMaxVoices) return;
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mTrackInserts[trackIdx][slotIdx].bypass = bypass;
}

void AudioEngine::setVoicePreviewBypassTrackInserts(int trackIdx, bool bypass) {
    if (trackIdx < 0 || trackIdx >= kMaxVoices) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mPreviewBypassTrackInserts[trackIdx] = bypass;
}

void AudioEngine::setTrackReverbParams(int trackIdx, int slotIdx, float roomSize, float damp, float width, bool freeze) {
    if (trackIdx < 0 || trackIdx >= kMaxVoices) return;
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    if (mTrackInserts[trackIdx][slotIdx].type != 0) return; // type 0 = reverb
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mTrackInserts[trackIdx][slotIdx].reverbRoomSize = std::clamp(roomSize, 0.0f, 1.0f);
    mTrackInserts[trackIdx][slotIdx].reverbDamp = std::clamp(damp, 0.0f, 1.0f);
    mTrackInserts[trackIdx][slotIdx].reverbWidth = std::clamp(width, 0.0f, 1.0f);
    mTrackInserts[trackIdx][slotIdx].reverbFreeze = freeze;
    // Update freeverb instance
    mTrackInserts[trackIdx][slotIdx].reverb.setroomsize(roomSize);
    mTrackInserts[trackIdx][slotIdx].reverb.setdamp(damp);
    mTrackInserts[trackIdx][slotIdx].reverb.setwidth(width);
    mTrackInserts[trackIdx][slotIdx].reverb.setdry(0.0f);
    mTrackInserts[trackIdx][slotIdx].reverb.setwet(1.0f);
    mTrackInserts[trackIdx][slotIdx].reverb.setmode(freeze ? 1.0f : 0.0f);
}

void AudioEngine::setMasterDelayParams(int slotIdx, float timeMs, float feedback, float hpCutoff, bool sync) {
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mMasterInserts[slotIdx].delayTimeMs  = std::clamp(timeMs,    1.0f, 2000.0f);
    mMasterInserts[slotIdx].delayFeedback = std::clamp(feedback, 0.0f, 0.95f);
    mMasterInserts[slotIdx].delayHpCutoff = std::clamp(hpCutoff, 0.0f, 1.0f);
    mMasterInserts[slotIdx].delaySync    = sync;
}

void AudioEngine::setTrackDelayParams(int trackIdx, int slotIdx, float timeMs, float feedback, float hpCutoff, bool sync) {
    if (trackIdx < 0 || trackIdx >= kMaxVoices) return;
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mTrackInserts[trackIdx][slotIdx].delayTimeMs   = std::clamp(timeMs,    1.0f, 2000.0f);
    mTrackInserts[trackIdx][slotIdx].delayFeedback = std::clamp(feedback,  0.0f, 0.95f);
    mTrackInserts[trackIdx][slotIdx].delayHpCutoff = std::clamp(hpCutoff,  0.0f, 1.0f);
    mTrackInserts[trackIdx][slotIdx].delaySync     = sync;
}

void AudioEngine::setTrackFilterParams(int trackIdx, int slotIdx, float cutoff, float resonance, int mode) {
    if (trackIdx < 0 || trackIdx >= kMaxVoices) return;
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mTrackInserts[trackIdx][slotIdx].filterCutoff    = std::clamp(cutoff,    0.0f, 1.0f);
    mTrackInserts[trackIdx][slotIdx].filterResonance = std::clamp(resonance, 0.0f, 1.0f);
    mTrackInserts[trackIdx][slotIdx].filterMode      = std::clamp(mode, 0, 2);
}

void AudioEngine::setMasterFilterParams(int slotIdx, float cutoff, float resonance, int mode) {
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mMasterInserts[slotIdx].filterCutoff    = std::clamp(cutoff,    0.0f, 1.0f);
    mMasterInserts[slotIdx].filterResonance = std::clamp(resonance, 0.0f, 1.0f);
    mMasterInserts[slotIdx].filterMode      = std::clamp(mode, 0, 2);
}

void AudioEngine::setTrackDistortionParams(int trackIdx, int slotIdx, float drive, float tone, int distType) {
    if (trackIdx < 0 || trackIdx >= kMaxVoices) return;
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mTrackInserts[trackIdx][slotIdx].distDrive = std::clamp(drive, 0.0f, 1.0f);
    mTrackInserts[trackIdx][slotIdx].distTone  = std::clamp(tone,  0.0f, 1.0f);
    mTrackInserts[trackIdx][slotIdx].distType  = std::clamp(distType, 0, 1);
}

void AudioEngine::setMasterDistortionParams(int slotIdx, float drive, float tone, int distType) {
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mMasterInserts[slotIdx].distDrive = std::clamp(drive, 0.0f, 1.0f);
    mMasterInserts[slotIdx].distTone  = std::clamp(tone,  0.0f, 1.0f);
    mMasterInserts[slotIdx].distType  = std::clamp(distType, 0, 1);
}

void AudioEngine::setTrackBitcrusherParams(int trackIdx, int slotIdx, float bits, float rate) {
    if (trackIdx < 0 || trackIdx >= kMaxVoices) return;
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mTrackInserts[trackIdx][slotIdx].crushBits = std::clamp(bits, 0.0f, 1.0f);
    mTrackInserts[trackIdx][slotIdx].crushRate = std::clamp(rate, 0.0f, 1.0f);
}

void AudioEngine::setMasterBitcrusherParams(int slotIdx, float bits, float rate) {
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mMasterInserts[slotIdx].crushBits = std::clamp(bits, 0.0f, 1.0f);
    mMasterInserts[slotIdx].crushRate = std::clamp(rate, 0.0f, 1.0f);
}

void AudioEngine::setTrackLimiterParams(int trackIdx, int slotIdx, float gain) {
    if (trackIdx < 0 || trackIdx >= kMaxVoices) return;
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mTrackInserts[trackIdx][slotIdx].limGain = std::clamp(gain, 0.0f, 1.0f);
}

void AudioEngine::setMasterLimiterParams(int slotIdx, float gain) {
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mMasterInserts[slotIdx].limGain = std::clamp(gain, 0.0f, 1.0f);
}

static void applyChorusParams(InsertEffect& fx, float rate, float depth, float delay, int stereo) {
    fx.chorusRate   = std::clamp(rate,  0.0f, 1.0f);
    fx.chorusDepth  = std::clamp(depth, 0.0f, 1.0f);
    fx.chorusDelay  = std::clamp(delay, 0.0f, 1.0f);
    fx.chorusStereo = std::clamp(stereo, 0, 1);
    // Ensure buffer is allocated (may have been cleared on reset)
    if (fx.chorusBufL.size() < 2880) { fx.chorusBufL.assign(2880, 0.0f); }
    if (fx.chorusBufR.size() < 2880) { fx.chorusBufR.assign(2880, 0.0f); }
}

static void applyFlangerParams(InsertEffect& fx, float rate, float depth, float delay, float feedback, int stereo) {
    fx.flangerRate     = std::clamp(rate,  0.0f, 1.0f);
    fx.flangerDepth    = std::clamp(depth, 0.0f, 1.0f);
    fx.flangerDelay    = std::clamp(delay, 0.0f, 1.0f);
    fx.flangerFeedback = std::clamp(feedback, -0.95f, 0.95f);
    fx.flangerStereo   = std::clamp(stereo, 0, 1);
    // Ensure buffer is allocated (may have been cleared on reset)
    if (fx.flangerBufL.size() < 480) { fx.flangerBufL.assign(480, 0.0f); }
    if (fx.flangerBufR.size() < 480) { fx.flangerBufR.assign(480, 0.0f); }
}

void AudioEngine::setTrackChorusParams(int trackIdx, int slotIdx, float rate, float depth, float delay, int stereo) {
    if (trackIdx < 0 || trackIdx >= kMaxVoices) return;
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    applyChorusParams(mTrackInserts[trackIdx][slotIdx], rate, depth, delay, stereo);
}

void AudioEngine::setTrackFlangerParams(int trackIdx, int slotIdx, float rate, float depth, float delay, float feedback, int stereo) {
    if (trackIdx < 0 || trackIdx >= kMaxVoices) return;
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    applyFlangerParams(mTrackInserts[trackIdx][slotIdx], rate, depth, delay, feedback, stereo);
}

void AudioEngine::setMasterFlangerParams(int slotIdx, float rate, float depth, float delay, float feedback, int stereo) {
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    applyFlangerParams(mMasterInserts[slotIdx], rate, depth, delay, feedback, stereo);
}

void AudioEngine::setMasterChorusParams(int slotIdx, float rate, float depth, float delay, int stereo) {
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    applyChorusParams(mMasterInserts[slotIdx], rate, depth, delay, stereo);
}

static void applyEqParams(InsertEffect& fx, float lowGain, float lowFreq,
                           float midGain, float midFreq, float midQ,
                           float highGain, float highFreq) {
    fx.eqLowGain  = std::clamp(lowGain,  -1.0f, 1.0f);
    fx.eqLowFreq  = std::clamp(lowFreq,   0.0f, 1.0f);
    fx.eqMidGain  = std::clamp(midGain,  -1.0f, 1.0f);
    fx.eqMidFreq  = std::clamp(midFreq,   0.0f, 1.0f);
    fx.eqMidQ     = std::clamp(midQ,      0.0f, 1.0f);
    fx.eqHighGain = std::clamp(highGain, -1.0f, 1.0f);
    fx.eqHighFreq = std::clamp(highFreq,  0.0f, 1.0f);
    fx.eqDirty    = true;
}

void AudioEngine::setTrackEqParams(int trackIdx, int slotIdx,
                                   float lowGain, float lowFreq,
                                   float midGain, float midFreq, float midQ,
                                   float highGain, float highFreq) {
    if (trackIdx < 0 || trackIdx >= kMaxVoices) return;
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    applyEqParams(mTrackInserts[trackIdx][slotIdx], lowGain, lowFreq, midGain, midFreq, midQ, highGain, highFreq);
}

void AudioEngine::setMasterEqParams(int slotIdx,
                                    float lowGain, float lowFreq,
                                    float midGain, float midFreq, float midQ,
                                    float highGain, float highFreq) {
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    applyEqParams(mMasterInserts[slotIdx], lowGain, lowFreq, midGain, midFreq, midQ, highGain, highFreq);
}

static void applyCompressorParams(InsertEffect& fx, float threshold, float ratio,
                                   float attack, float release, float makeup, int knee) {
    fx.cmpThreshold = std::clamp(threshold, 0.0f, 1.0f);
    fx.cmpRatio     = std::clamp(ratio,     0.0f, 1.0f);
    fx.cmpAttack    = std::clamp(attack,    0.0f, 1.0f);
    fx.cmpRelease   = std::clamp(release,   0.0f, 1.0f);
    fx.cmpMakeup    = std::clamp(makeup,    0.0f, 1.0f);
    fx.cmpKnee      = std::clamp(knee,      0,    1);
}

void AudioEngine::setTrackCompressorParams(int trackIdx, int slotIdx,
                                           float threshold, float ratio,
                                           float attack, float release,
                                           float makeup, int knee) {
    if (trackIdx < 0 || trackIdx >= kMaxVoices) return;
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    applyCompressorParams(mTrackInserts[trackIdx][slotIdx], threshold, ratio, attack, release, makeup, knee);
}

void AudioEngine::setMasterCompressorParams(int slotIdx,
                                            float threshold, float ratio,
                                            float attack, float release,
                                            float makeup, int knee) {
    if (slotIdx < 0 || slotIdx >= kMaxInsertSlots) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    applyCompressorParams(mMasterInserts[slotIdx], threshold, ratio, attack, release, makeup, knee);
}

void AudioEngine::processEffects(float* outL, float* outR, int numFrames, InsertEffect* effects) {
    if (!effects) return;

    if (static_cast<int>(mFxWetL.size()) < numFrames) {
        mFxWetL.resize(numFrames);
        mFxWetR.resize(numFrames);
    }
    
    // Process each insert effect slot
    for (int slot = 0; slot < kMaxInsertSlots; ++slot) {
        InsertEffect& fx = effects[slot];
        if (fx.type == -1 || fx.bypass) continue;
        
        if (fx.type == 0) {
            // Reverb effect
            fx.reverb.process(outL, outR, mFxWetL.data(), mFxWetR.data(), numFrames);
            for (int i = 0; i < numFrames; ++i) {
                outL[i] = (outL[i] * fx.dryLevel) + (mFxWetL[i] * fx.wetLevel);
                outR[i] = (outR[i] * fx.dryLevel) + (mFxWetR[i] * fx.wetLevel);
            }
        } else if (fx.type == 1) {
            // Stereo delay with feedback and optional hi-pass
            if (fx.delayBufL.empty()) {
                fx.delayBufL.assign(InsertEffect::kDelayMaxSamples, 0.0f);
                fx.delayBufR.assign(InsertEffect::kDelayMaxSamples, 0.0f);
                fx.delayWritePos = 0;
                fx.delayHpPrevL = 0.0f;
                fx.delayHpPrevR = 0.0f;
            }
            const int bufLen = InsertEffect::kDelayMaxSamples;
            const float sr = mCachedSampleRate > 0.0f ? mCachedSampleRate : 48000.0f;
            const int delaySamples = std::clamp(
                static_cast<int>(fx.delayTimeMs * sr / 1000.0f),
                1, bufLen - 1);
            // Hi-pass coefficient (one-pole, 0 = no filter)
            const float hpK = fx.delayHpCutoff > 0.001f
                ? std::exp(-2.0f * static_cast<float>(M_PI) * fx.delayHpCutoff * 4000.0f / sr)
                : 1.0f; // k=1 means no hi-pass (dc-bypass disabled)
            for (int i = 0; i < numFrames; ++i) {
                const int readPos = (fx.delayWritePos - delaySamples + bufLen) % bufLen;
                float delL = fx.delayBufL[readPos];
                float delR = fx.delayBufR[readPos];
                // Hi-pass filter on the delay return
                if (fx.delayHpCutoff > 0.001f) {
                    float newL = delL - hpK * fx.delayHpPrevL;
                    fx.delayHpPrevL = delL - newL + hpK * fx.delayHpPrevL;
                    delL = newL;
                    float newR = delR - hpK * fx.delayHpPrevR;
                    fx.delayHpPrevR = delR - newR + hpK * fx.delayHpPrevR;
                    delR = newR;
                }
                fx.delayBufL[fx.delayWritePos] = outL[i] + delL * fx.delayFeedback;
                fx.delayBufR[fx.delayWritePos] = outR[i] + delR * fx.delayFeedback;
                fx.delayWritePos = (fx.delayWritePos + 1) % bufLen;
                outL[i] = outL[i] * fx.dryLevel + delL * fx.wetLevel;
                outR[i] = outR[i] * fx.dryLevel + delR * fx.wetLevel;
            }
        } else if (fx.type == 2) {
            // State-variable filter (LP / HP / BP)
            const float sr = mCachedSampleRate > 0.0f ? mCachedSampleRate : 48000.0f;
            // cutoff 0..1 → ~20 Hz .. 20 kHz (exponential), clamped to stable range
            const float freq = std::clamp(20.0f * std::pow(1000.0f, fx.filterCutoff), 20.0f, sr * 0.20f);
            const float f = std::clamp(2.0f * std::sin(static_cast<float>(M_PI) * freq / sr), 0.001f, 0.99f);
            const float q = std::max(0.01f, 1.0f - fx.filterResonance * 0.95f);
            for (int i = 0; i < numFrames; ++i) {
                // Left
                fx.svfLowL  += f * fx.svfBandL;
                float highL  = outL[i] - fx.svfLowL - q * fx.svfBandL;
                fx.svfBandL += f * highL;
                // Right
                fx.svfLowR  += f * fx.svfBandR;
                float highR  = outR[i] - fx.svfLowR - q * fx.svfBandR;
                fx.svfBandR += f * highR;

                float wetL, wetR;
                switch (fx.filterMode) {
                    case 1:  wetL = highL; wetR = highR; break; // HP
                    case 2:  wetL = fx.svfBandL; wetR = fx.svfBandR; break; // BP
                    default: wetL = fx.svfLowL;  wetR = fx.svfLowR;  break; // LP
                }
                outL[i] = outL[i] * fx.dryLevel + wetL * fx.wetLevel;
                outR[i] = outR[i] * fx.dryLevel + wetR * fx.wetLevel;
            }
        } else if (fx.type == 3) {
            // Distortion: soft-clip or fold, with one-pole tone LP on output
            const float gain = 1.0f + fx.distDrive * 19.0f; // 1..20×
            // tone 0..1 → LP cutoff 200 Hz..20 kHz
            const float sr = mCachedSampleRate > 0.0f ? mCachedSampleRate : 48000.0f;
            const float toneFreq = 200.0f * std::pow(100.0f, fx.distTone);
            const float toneK = std::exp(-2.0f * static_cast<float>(M_PI) * toneFreq / sr);
            for (int i = 0; i < numFrames; ++i) {
                float inL = outL[i] * gain;
                float inR = outR[i] * gain;
                float clL, clR;
                if (fx.distType == 1) {
                    // Fold: reflect at ±1
                    auto fold = [](float x) -> float {
                        x = std::fmod(x + 1.0f, 4.0f);
                        if (x < 0.0f) x += 4.0f;
                        if (x > 2.0f) x = 4.0f - x;
                        return x - 1.0f;
                    };
                    clL = fold(inL);
                    clR = fold(inR);
                } else {
                    // Soft-clip via tanh
                    clL = std::tanh(inL);
                    clR = std::tanh(inR);
                }
                // One-pole tone LP
                fx.distToneStateL = toneK * fx.distToneStateL + (1.0f - toneK) * clL;
                fx.distToneStateR = toneK * fx.distToneStateR + (1.0f - toneK) * clR;
                outL[i] = outL[i] * fx.dryLevel + fx.distToneStateL * fx.wetLevel;
                outR[i] = outR[i] * fx.dryLevel + fx.distToneStateR * fx.wetLevel;
            }
        } else if (fx.type == 4) {
            // Bitcrusher: bit-depth reduction + sample-rate reduction
            const float levels = std::pow(2.0f, 1.0f + fx.crushBits * 15.0f); // 2..65536 levels
            const float step = 1.0f / levels;
            // rate: 0..1 → hold 1..32 samples
            const float rateHold = 1.0f + (1.0f - fx.crushRate) * 31.0f;
            for (int i = 0; i < numFrames; ++i) {
                fx.crushAccum += 1.0f;
                if (fx.crushAccum >= rateHold) {
                    fx.crushAccum -= rateHold;
                    fx.crushHoldL = std::floor(outL[i] / step + 0.5f) * step;
                    fx.crushHoldR = std::floor(outR[i] / step + 0.5f) * step;
                }
                outL[i] = outL[i] * fx.dryLevel + fx.crushHoldL * fx.wetLevel;
                outR[i] = outR[i] * fx.dryLevel + fx.crushHoldR * fx.wetLevel;
            }
        } else if (fx.type == 5) {
            // Brick-wall limiter: input gain pushed into fixed -0.1 dBFS ceiling
            constexpr float kCeiling = 0.9886f; // 10^(-0.1/20)
            // gain: 0..1 → 0 dB..+24 dB (1×..15.8×), logarithmic feel via power
            const float gainLin = std::pow(10.0f, fx.limGain * 24.0f / 20.0f);
            for (int i = 0; i < numFrames; ++i) {
                float gL = outL[i] * gainLin;
                float gR = outR[i] * gainLin;
                float peakL = std::abs(gL);
                float peakR = std::abs(gR);
                if (peakL > kCeiling) gL = (gL / peakL) * kCeiling;
                if (peakR > kCeiling) gR = (gR / peakR) * kCeiling;
                outL[i] = outL[i] * fx.dryLevel + gL * fx.wetLevel;
                outR[i] = outR[i] * fx.dryLevel + gR * fx.wetLevel;
            }
        } else if (fx.type == 9) {
            // Flanger: short modulated delay with feedback
            // rate: 0..1 → 0.1..8 Hz
            const float lfoHz    = 0.1f + fx.flangerRate * 7.9f;
            // depth: 0..1 → 0..10 ms  (in samples)
            const float depthSmp = fx.flangerDepth * 10.0f * 0.001f * mCachedSampleRate;
            // base delay: 0..1 → 0..10 ms  (in samples)
            const float baseSmp  = fx.flangerDelay * 10.0f * 0.001f * mCachedSampleRate;
            const float feedback = std::clamp(fx.flangerFeedback, -0.95f, 0.95f);
            const int   bufSize  = static_cast<int>(fx.flangerBufL.size());
            if (bufSize == 0) goto flanger_skip;
            {
                const float twoPi    = 6.28318530718f;
                const float phaseInc = twoPi * lfoHz / mCachedSampleRate;
                for (int i = 0; i < numFrames; ++i) {
                    // current input
                    float inL = outL[i];
                    float inR = outR[i];

                    // write current sample + feedback into ring buffer
                    fx.flangerBufL[fx.flangerBufPos] = inL + fx.flangerBufL[fx.flangerBufPos] * feedback;
                    fx.flangerBufR[fx.flangerBufPos] = inR + fx.flangerBufR[fx.flangerBufPos] * feedback;

                    // LFO mod
                    float modL = std::sin(fx.flangerLfoPhL);
                    float phR  = fx.flangerStereo ? (fx.flangerLfoPhL + twoPi * 0.25f) : fx.flangerLfoPhL;
                    float modR = std::sin(phR);

                    float readOffL = baseSmp + depthSmp * modL;
                    float readOffR = baseSmp + depthSmp * modR;

                    auto linearRead = [&](std::vector<float>& buf, float offset) -> float {
                        float rPos = static_cast<float>(fx.flangerBufPos) - offset;
                        int   r0   = static_cast<int>(std::floor(rPos));
                        float frac = rPos - static_cast<float>(r0);
                        int   i0   = ((r0 % bufSize) + bufSize) % bufSize;
                        int   i1   = ((r0 + 1) % bufSize + bufSize) % bufSize;
                        return buf[i0] + frac * (buf[i1] - buf[i0]);
                    };

                    float delayedL = linearRead(fx.flangerBufL, readOffL);
                    float delayedR = linearRead(fx.flangerBufR, readOffR);

                    outL[i] = inL * fx.dryLevel + delayedL * fx.wetLevel;
                    outR[i] = inR * fx.dryLevel + delayedR * fx.wetLevel;

                    fx.flangerLfoPhL += phaseInc;
                    if (fx.flangerLfoPhL >= twoPi) fx.flangerLfoPhL -= twoPi;
                    fx.flangerLfoPhR = fx.flangerLfoPhL;

                    fx.flangerBufPos = (fx.flangerBufPos + 1) % bufSize;
                }
            }
            flanger_skip:;
        } else if (fx.type == 6) {
            // Chorus: modulated delay line with sinusoidal LFO
            // rate: 0..1 → 0.1..8 Hz
            const float lfoHz    = 0.1f + fx.chorusRate * 7.9f;
            // depth: 0..1 → 0..15 ms  (in samples)
            const float depthSmp = fx.chorusDepth * 15.0f * 0.001f * mCachedSampleRate;
            // base delay: 0..1 → 1..30 ms  (in samples)
            const float baseSmp  = (1.0f + fx.chorusDelay * 29.0f) * 0.001f * mCachedSampleRate;
            const int   bufSize  = static_cast<int>(fx.chorusBufL.size());
            if (bufSize == 0) goto chorus_skip;
            {
                const float twoPi    = 6.28318530718f;
                const float phaseInc = twoPi * lfoHz / mCachedSampleRate;
                for (int i = 0; i < numFrames; ++i) {
                    // Write current sample into ring buffer
                    fx.chorusBufL[fx.chorusBufPos] = outL[i];
                    fx.chorusBufR[fx.chorusBufPos] = outR[i];

                    // LFO mod
                    float modL = std::sin(fx.chorusLfoPhL);
                    float phR  = fx.chorusStereo ? (fx.chorusLfoPhL + twoPi * 0.25f) : fx.chorusLfoPhL;
                    float modR = std::sin(phR);

                    // Read position (fractional)
                    float readOffL = baseSmp + depthSmp * modL;
                    float readOffR = baseSmp + depthSmp * modR;

                    auto linearRead = [&](std::vector<float>& buf, float offset) -> float {
                        float rPos = static_cast<float>(fx.chorusBufPos) - offset;
                        int   r0   = static_cast<int>(std::floor(rPos));
                        float frac = rPos - static_cast<float>(r0);
                        int   i0   = ((r0 % bufSize) + bufSize) % bufSize;
                        int   i1   = ((r0 + 1) % bufSize + bufSize) % bufSize;
                        return buf[i0] + frac * (buf[i1] - buf[i0]);
                    };

                    float wetL = linearRead(fx.chorusBufL, readOffL);
                    float wetR = linearRead(fx.chorusBufR, readOffR);

                    outL[i] = outL[i] * fx.dryLevel + wetL * fx.wetLevel;
                    outR[i] = outR[i] * fx.dryLevel + wetR * fx.wetLevel;

                    fx.chorusLfoPhL += phaseInc;
                    if (fx.chorusLfoPhL >= twoPi) fx.chorusLfoPhL -= twoPi;
                    fx.chorusLfoPhR = fx.chorusLfoPhL; // kept in sync; stereo uses phR inline

                    fx.chorusBufPos = (fx.chorusBufPos + 1) % bufSize;
                }
            }
            chorus_skip:;
        } else if (fx.type == 7) {
            // ── EQ: 3-band semi-parametric biquad ──────────────────────────
            // Recompute coefficients when dirty (param changed).
            if (fx.eqDirty) {
                const float sr = mCachedSampleRate > 0.0f ? mCachedSampleRate : 48000.0f;
                const float pi = 3.14159265358979f;

                // Low shelf  (40..500 Hz, log)
                {
                    float freq  = 40.0f * std::pow(500.0f / 40.0f, fx.eqLowFreq);
                    float dBgain = fx.eqLowGain * 12.0f;
                    float A     = std::pow(10.0f, dBgain / 40.0f);
                    float w0    = 2.0f * pi * freq / sr;
                    float cosw  = std::cos(w0);
                    float sinw  = std::sin(w0);
                    float S     = 1.0f; // slope
                    float alpha = sinw / 2.0f * std::sqrt((A + 1.0f/A) * (1.0f/S - 1.0f) + 2.0f);
                    float b0 =  A * ((A+1) - (A-1)*cosw + 2*std::sqrt(A)*alpha);
                    float b1 =  2*A * ((A-1) - (A+1)*cosw);
                    float b2 =  A * ((A+1) - (A-1)*cosw - 2*std::sqrt(A)*alpha);
                    float a0 =       (A+1) + (A-1)*cosw + 2*std::sqrt(A)*alpha;
                    float a1 = -2 * ((A-1) + (A+1)*cosw);
                    float a2 =       (A+1) + (A-1)*cosw - 2*std::sqrt(A)*alpha;
                    float inv = 1.0f / a0;
                    fx.eqCoeffs[0][0] = b0*inv; fx.eqCoeffs[0][1] = b1*inv; fx.eqCoeffs[0][2] = b2*inv;
                    fx.eqCoeffs[0][3] = a1*inv; fx.eqCoeffs[0][4] = a2*inv;
                }
                // Mid peaking EQ  (200..8000 Hz, log; Q 0.3..8.0)
                {
                    float freq  = 200.0f * std::pow(8000.0f / 200.0f, fx.eqMidFreq);
                    float dBgain = fx.eqMidGain * 12.0f;
                    float A     = std::pow(10.0f, dBgain / 40.0f);
                    float Q     = 0.3f + fx.eqMidQ * 7.7f;
                    float w0    = 2.0f * pi * freq / sr;
                    float alpha = std::sin(w0) / (2.0f * Q);
                    float b0 =  1.0f + alpha * A;
                    float b1 = -2.0f * std::cos(w0);
                    float b2 =  1.0f - alpha * A;
                    float a0 =  1.0f + alpha / A;
                    float a1 = -2.0f * std::cos(w0);
                    float a2 =  1.0f - alpha / A;
                    float inv = 1.0f / a0;
                    fx.eqCoeffs[1][0] = b0*inv; fx.eqCoeffs[1][1] = b1*inv; fx.eqCoeffs[1][2] = b2*inv;
                    fx.eqCoeffs[1][3] = a1*inv; fx.eqCoeffs[1][4] = a2*inv;
                }
                // High shelf  (2000..16000 Hz, log)
                {
                    float freq  = 2000.0f * std::pow(16000.0f / 2000.0f, fx.eqHighFreq);
                    float dBgain = fx.eqHighGain * 12.0f;
                    float A     = std::pow(10.0f, dBgain / 40.0f);
                    float w0    = 2.0f * pi * freq / sr;
                    float cosw  = std::cos(w0);
                    float sinw  = std::sin(w0);
                    float S     = 1.0f;
                    float alpha = sinw / 2.0f * std::sqrt((A + 1.0f/A) * (1.0f/S - 1.0f) + 2.0f);
                    float b0 =  A * ((A+1) + (A-1)*cosw + 2*std::sqrt(A)*alpha);
                    float b1 = -2*A * ((A-1) + (A+1)*cosw);
                    float b2 =  A * ((A+1) + (A-1)*cosw - 2*std::sqrt(A)*alpha);
                    float a0 =       (A+1) - (A-1)*cosw + 2*std::sqrt(A)*alpha;
                    float a1 =  2 * ((A-1) - (A+1)*cosw);
                    float a2 =       (A+1) - (A-1)*cosw - 2*std::sqrt(A)*alpha;
                    float inv = 1.0f / a0;
                    fx.eqCoeffs[2][0] = b0*inv; fx.eqCoeffs[2][1] = b1*inv; fx.eqCoeffs[2][2] = b2*inv;
                    fx.eqCoeffs[2][3] = a1*inv; fx.eqCoeffs[2][4] = a2*inv;
                }
                fx.eqDirty = false;
            }
            // Process each band in series (Direct Form I)
            // Capture dry signal first for dry/wet mix
            constexpr int kMaxFrames = 512;
            float dryBufL[kMaxFrames], dryBufR[kMaxFrames];
            int safeFr = (numFrames <= kMaxFrames) ? numFrames : kMaxFrames;
            std::memcpy(dryBufL, outL, safeFr * sizeof(float));
            std::memcpy(dryBufR, outR, safeFr * sizeof(float));

            for (int band = 0; band < 3; ++band) {
                const float b0 = fx.eqCoeffs[band][0];
                const float b1 = fx.eqCoeffs[band][1];
                const float b2 = fx.eqCoeffs[band][2];
                const float a1 = fx.eqCoeffs[band][3];
                const float a2 = fx.eqCoeffs[band][4];
                for (int i = 0; i < safeFr; ++i) {
                    // Left
                    float xL = outL[i];
                    float yL = b0*xL + b1*fx.eqZx[band][0][0] + b2*fx.eqZx[band][0][1]
                                     - a1*fx.eqZy[band][0][0] - a2*fx.eqZy[band][0][1];
                    fx.eqZx[band][0][1] = fx.eqZx[band][0][0]; fx.eqZx[band][0][0] = xL;
                    fx.eqZy[band][0][1] = fx.eqZy[band][0][0]; fx.eqZy[band][0][0] = yL;
                    outL[i] = yL;
                    // Right
                    float xR = outR[i];
                    float yR = b0*xR + b1*fx.eqZx[band][1][0] + b2*fx.eqZx[band][1][1]
                                     - a1*fx.eqZy[band][1][0] - a2*fx.eqZy[band][1][1];
                    fx.eqZx[band][1][1] = fx.eqZx[band][1][0]; fx.eqZx[band][1][0] = xR;
                    fx.eqZy[band][1][1] = fx.eqZy[band][1][0]; fx.eqZy[band][1][0] = yR;
                    outR[i] = yR;
                }
            }
            // Apply dry/wet mix
            for (int i = 0; i < safeFr; ++i) {
                outL[i] = dryBufL[i] * fx.dryLevel + outL[i] * fx.wetLevel;
                outR[i] = dryBufR[i] * fx.dryLevel + outR[i] * fx.wetLevel;
            }
        } else if (fx.type == 8) {
            // ── Compressor: peak envelope follower + gain computer ─────────
            const float sr = mCachedSampleRate > 0.0f ? mCachedSampleRate : 48000.0f;

            // Decode params
            // threshold: 0..1 → −60..0 dBFS
            const float thrDB  = -60.0f + fx.cmpThreshold * 60.0f;
            // ratio: 0..1 → 1..20 (log)
            const float ratio  = 1.0f + std::exp(fx.cmpRatio * std::log(19.0f));
            // attack: 0..1 → 0.1..200 ms (log)
            const float attMs  = 0.1f * std::pow(2000.0f, fx.cmpAttack);
            // release: 0..1 → 10..2000 ms (log)
            const float relMs  = 10.0f * std::pow(200.0f, fx.cmpRelease);
            // makeup: 0..1 → 0..+24 dB
            const float makeupDB = fx.cmpMakeup * 24.0f;
            const float makeupLin = std::pow(10.0f, makeupDB / 20.0f);

            // Time constants → per-sample coefficients
            const float attCoef = std::exp(-1.0f / (sr * attMs * 0.001f));
            const float relCoef = std::exp(-1.0f / (sr * relMs * 0.001f));

            // Soft knee half-width in dB
            const float kneeW = fx.cmpKnee ? 6.0f : 0.0f;

            for (int i = 0; i < numFrames; ++i) {
                // Peak detection (linked stereo)
                const float peak = std::max(std::abs(outL[i]), std::abs(outR[i]));
                // Envelope follower
                const float env = peak > fx.cmpEnvL
                    ? attCoef * fx.cmpEnvL + (1.0f - attCoef) * peak
                    : relCoef * fx.cmpEnvL + (1.0f - relCoef) * peak;
                fx.cmpEnvL = env;
                fx.cmpEnvR = env; // linked

                // Gain computer (log domain)
                float gainDB = 0.0f;
                if (env > 1e-10f) {
                    const float inputDB = 20.0f * std::log10(env);
                    const float overDB  = inputDB - thrDB;
                    if (fx.cmpKnee && overDB > -kneeW && overDB < kneeW) {
                        // Soft knee region
                        const float t = (overDB + kneeW) / (2.0f * kneeW);
                        gainDB = -(1.0f - 1.0f / ratio) * t * t * kneeW;
                    } else if (overDB > 0.0f) {
                        gainDB = -(overDB) * (1.0f - 1.0f / ratio);
                    }
                }
                const float gainLin = std::pow(10.0f, gainDB / 20.0f) * makeupLin;

                outL[i] = outL[i] * fx.dryLevel + outL[i] * gainLin * fx.wetLevel;
                outR[i] = outR[i] * fx.dryLevel + outR[i] * gainLin * fx.wetLevel;
            }
        }
    }
}

oboe::DataCallbackResult AudioEngine::onAudioReady(
        oboe::AudioStream* stream,
        void*              audioData,
        int32_t            numFrames) {

    auto* out = static_cast<float*>(audioData);
    std::fill(out, out + numFrames * 2, 0.0f);

#if defined(__aarch64__)
    // Enable flush-to-zero (FZ) on ARMv8 FPU for the duration of this callback.
    // Denormals on Karplus feedback / SVF filter state can cost 100x normal
    // CPU and cause audio dropouts. Save/restore the previous FPCR so we don't
    // affect other threads of the process.
    uint64_t prevFpcr;
    asm volatile("mrs %0, fpcr" : "=r"(prevFpcr));
    if ((prevFpcr & (1ULL << 24)) == 0) {
        asm volatile("msr fpcr, %0" :: "r"(prevFpcr | (1ULL << 24)));
    }
#elif defined(__arm__)
    // ARMv7: FZ bit (bit 24) lives in FPSCR.
    uint32_t prevFpscr;
    asm volatile("vmrs %0, fpscr" : "=r"(prevFpscr));
    if ((prevFpscr & (1u << 24)) == 0) {
        asm volatile("vmsr fpscr, %0" :: "r"(prevFpscr | (1u << 24)));
    }
#endif

    const double sampleRate = stream->getSampleRate();
    const double twoPi = 2.0 * M_PI;
    // One-pole gain smoother: ~5 ms time constant, eliminates clicks.
    const float smoothK = 1.0f - std::exp(-1.0f / (static_cast<float>(sampleRate) * 0.005f));
    const float panSmoothK = 1.0f - std::exp(-1.0f / (static_cast<float>(sampleRate) * 0.003f));
    std::array<float, kMaxVoices> callbackTrackPeakL{};
    std::array<float, kMaxVoices> callbackTrackPeakR{};
    float callbackMasterPeakL = 0.0f;
    float callbackMasterPeakR = 0.0f;
    // Use pre-allocated preview scratch buses (no per-callback allocation).
    // Defensive resize only triggers if Oboe ever reports a burst larger than
    // kMaxAudioBurst — should never happen in practice.
    if (static_cast<int>(mPreviewDirectL.size()) < numFrames) {
        mPreviewDirectL.resize(numFrames);
        mPreviewDirectR.resize(numFrames);
    }
    std::fill_n(mPreviewDirectL.data(), numFrames, 0.0f);
    std::fill_n(mPreviewDirectR.data(), numFrames, 0.0f);
    float* previewDirectL = mPreviewDirectL.data();
    float* previewDirectR = mPreviewDirectR.data();

    std::lock_guard<std::mutex> lock(mVoiceMutex);

    // Advance the per-row sample counter and fire due sub-row events BEFORE
    // handling row-boundary advancement below. Ordering matters here: a
    // pending DEL/ARP/RET/KIL event can be scheduled very close to the end
    // of a row (e.g. DEL 97-98). If the row-boundary-advance code ran first
    // in the same callback, primeNextQueuedPlaybackRowLocked() ->
    // triggerRowLocked() would clear the pending event before its
    // firing-check ever ran — a race whose outcome depends on exact
    // callback/row alignment, so near-end-of-row events fired sometimes and
    // silently dropped other times. Firing first guarantees every pending
    // event gets checked against this callback's updated counter before the
    // row it belongs to can end.
    // Events queued via queueArp()/queueRetrigs() fire at buffer granularity,
    // which is far more accurate than Dart Timer jitter.
    mSubRowSampleCounter += numFrames;

    if (!mPendingDelays.empty()) {
        for (auto& ev : mPendingDelays) {
            if (ev.sampleTarget < 0) continue; // already fired
            if (mSubRowSampleCounter < ev.sampleTarget) continue;
            ev.sampleTarget = -1; // mark fired
            if (ev.trackIdx < 0 || ev.trackIdx >= static_cast<int>(mVoices.size())) continue;
            Voice& v = mVoices[ev.trackIdx];
            if (ev.volume >= 0) {
                v.level = static_cast<float>(ev.volume) / 255.0f;
            }
            if (v.samplerMode) {
                v.midiNote = ev.note;
                if (v.sampleSlot >= 0 &&
                    v.sampleSlot < static_cast<int>(mSamplerSlots.size())) {
                    const auto& s = mSamplerSlots[v.sampleSlot];
                    if (!s.mono.empty()) {
                        // Anti-click: fade out whatever this voice was already
                        // playing instead of jumping straight to the new hit.
                        if (v.sampleActive) {
                            constexpr float kDeclickTailMs = 3.0f;
                            v.declickTailGain0 = v.sampleLastOutput;
                            v.declickTailFramesTotal = std::max(
                                1, static_cast<int>(kDeclickTailMs * 0.001 * sampleRate));
                            v.declickTailFramesLeft = v.declickTailFramesTotal;
                        }
                        const int sampleFrames = static_cast<int>(s.mono.size());
                        const int startFrame = std::clamp(
                            static_cast<int>(v.sampleStartNorm * static_cast<float>(sampleFrames - 1)),
                            0, sampleFrames - 1);
                        const int endFrame = std::clamp(
                            static_cast<int>(v.sampleEndNorm * static_cast<float>(sampleFrames)),
                            startFrame + 1, sampleFrames);
                        v.samplePos = v.sampleReverse ? static_cast<double>(endFrame - 1)
                                                      : static_cast<double>(startFrame);
                        v.sampleElapsedFrames = 0.0;
                        v.samplePingDir = v.sampleReverse;
                        const float detuneSemitones = (v.detuneNorm - 0.5f) * 24.0f;
                        const float semis = static_cast<float>(ev.note - 60) + detuneSemitones;
                        v.sampleStep = std::pow(2.0f, semis / 12.0f);
                        v.sampleActive = true;
                    } else {
                        v.sampleActive = false;
                    }
                } else {
                    v.sampleActive = false;
                }
                // Keep synth envelopes disabled in sampler mode.
                v.noteHeld = false;
                v.envStage = EnvelopeStage::Idle;
                v.filterEnvStage = EnvelopeStage::Idle;
                v.gain = 0.0f;
                v.gainTarget = 0.0f;
                v.pendingWaveform = -1;
            } else if (v.karplusMode) {
                startKarplusVoice(v, ev.note, sampleRate);
            } else if (v.drumMode) {
                startDrumVoice(v, sampleRate);
                v.midiNote = ev.note;
            } else {
                v.midiNote = ev.note;
                const float detuneSemitones = (v.detuneNorm - 0.5f) * 24.0f;
                v.targetFreq = static_cast<float>(midiToFreq(ev.note)) *
                    std::pow(2.0f, detuneSemitones / 12.0f);
                if (v.currentFreq <= 0.0f || v.glideSec <= 0.0f) {
                    v.currentFreq = v.targetFreq;
                }
                const bool voiceWasActive =
                    (v.envStage != EnvelopeStage::Idle) ||
                    (v.gain > 1e-4f) ||
                    (v.gainTarget > 1e-4f);
                if (!voiceWasActive) {
                    v.filterLow  = 0.0f;
                    v.filterBand = 0.0f;
                }
                if (!voiceWasActive) {
                    v.envLevel       = 0.0f;
                    v.filterEnvLevel = 0.0f;
                }
                v.noteHeld       = true;
                v.envStage       = EnvelopeStage::Attack;
                v.filterEnvStage = EnvelopeStage::Attack;
                v.gainTarget     = 1.0f;
                v.sampleActive   = false;
            }
        }
        mPendingDelays.erase(
            std::remove_if(mPendingDelays.begin(), mPendingDelays.end(),
                [](const DelayEvent& e) { return e.sampleTarget < 0; }),
            mPendingDelays.end());
    }

    if (!mPendingArp.empty()) {
        for (auto& ev : mPendingArp) {
            if (ev.sampleTarget < 0) continue; // already fired
            if (mSubRowSampleCounter < ev.sampleTarget) continue;
            ev.sampleTarget = -1; // mark fired
            if (ev.trackIdx < 0 || ev.trackIdx >= static_cast<int>(mVoices.size())) continue;
            Voice& v = mVoices[ev.trackIdx];
            if (v.midiNote < 0) continue; // no active voice for this track
            v.midiNote = ev.note;
            const float detuneSemitones = (v.detuneNorm - 0.5f) * 24.0f;
            if (v.samplerMode) {
                // Pitch-only ARP for sampler: retune sample speed only.
                const float semis = static_cast<float>(ev.note - 60) + detuneSemitones;
                v.sampleStep = std::pow(2.0f, semis / 12.0f);
            } else if (v.karplusMode) {
                startKarplusVoice(v, ev.note, sampleRate);
            } else if (v.drumMode) {
                // Pitch-only ARP for drum synth: PITCH knob controls tuning,
                // so retrigger the same one-shot rather than retuning it.
                startDrumVoice(v, sampleRate);
                v.midiNote = ev.note;
            } else {
                // Pitch-only ARP for synth: retune oscillator without retrigger.
                v.targetFreq = static_cast<float>(midiToFreq(ev.note)) *
                    std::pow(2.0f, detuneSemitones / 12.0f);
                if (v.currentFreq <= 0.0f || v.glideSec <= 0.0f) {
                    v.currentFreq = v.targetFreq;
                }
            }
        }
        mPendingArp.erase(
            std::remove_if(mPendingArp.begin(), mPendingArp.end(),
                [](const ArpEvent& e) { return e.sampleTarget < 0; }),
            mPendingArp.end());
    }

    if (!mPendingRetrigs.empty()) {
        for (auto& ev : mPendingRetrigs) {
            if (ev.sampleTarget < 0) continue; // already fired
            if (mSubRowSampleCounter < ev.sampleTarget) continue;
            ev.sampleTarget = -1; // mark fired
            if (ev.trackIdx < 0 || ev.trackIdx >= static_cast<int>(mVoices.size())) continue;
            Voice& v = mVoices[ev.trackIdx];
            if (v.midiNote < 0) continue; // no active voice for this track
            // Update volume if supplied.
            if (ev.volume >= 0) {
                v.level = static_cast<float>(ev.volume) / 255.0f;
            }
            if (v.samplerMode) {
                // Sampler retrigger: restart sample playback from region start/end.
                v.midiNote = ev.note;
                if (v.sampleSlot >= 0 &&
                    v.sampleSlot < static_cast<int>(mSamplerSlots.size())) {
                    const auto& s = mSamplerSlots[v.sampleSlot];
                    if (!s.mono.empty()) {
                        // Anti-click: fade out whatever this voice was already
                        // playing instead of jumping straight to the new hit —
                        // important here since R (retrig) can fire many times
                        // per row on a long sample.
                        if (v.sampleActive) {
                            constexpr float kDeclickTailMs = 3.0f;
                            v.declickTailGain0 = v.sampleLastOutput;
                            v.declickTailFramesTotal = std::max(
                                1, static_cast<int>(kDeclickTailMs * 0.001 * sampleRate));
                            v.declickTailFramesLeft = v.declickTailFramesTotal;
                        }
                        const int sampleFrames = static_cast<int>(s.mono.size());
                        const int startFrame = std::clamp(
                            static_cast<int>(v.sampleStartNorm * static_cast<float>(sampleFrames - 1)),
                            0, sampleFrames - 1);
                        const int endFrame = std::clamp(
                            static_cast<int>(v.sampleEndNorm * static_cast<float>(sampleFrames)),
                            startFrame + 1, sampleFrames);
                        v.samplePos = v.sampleReverse ? static_cast<double>(endFrame - 1)
                                                      : static_cast<double>(startFrame);
                        v.sampleElapsedFrames = 0.0;
                        v.samplePingDir = v.sampleReverse;
                        const float detuneSemitones = (v.detuneNorm - 0.5f) * 24.0f;
                        const float semis = static_cast<float>(ev.note - 60) + detuneSemitones;
                        v.sampleStep = std::pow(2.0f, semis / 12.0f);
                        v.sampleActive = true;
                    }
                }
            } else if (v.karplusMode) {
                startKarplusVoice(v, ev.note, sampleRate);
            } else if (v.drumMode) {
                startDrumVoice(v, sampleRate);
                v.midiNote = ev.note;
            } else {
                // Synth retrigger: restart amp/filter envelopes from zero.
                v.midiNote = ev.note;
                const float detuneSemitones = (v.detuneNorm - 0.5f) * 24.0f;
                v.targetFreq = static_cast<float>(midiToFreq(ev.note)) *
                    std::pow(2.0f, detuneSemitones / 12.0f);
                if (v.currentFreq <= 0.0f || v.glideSec <= 0.0f) {
                    v.currentFreq = v.targetFreq;
                }
                const bool voiceWasActive =
                    (v.envStage != EnvelopeStage::Idle) ||
                    (v.gain > 1e-4f) ||
                    (v.gainTarget > 1e-4f);
                if (!voiceWasActive) {
                    v.filterLow  = 0.0f;
                    v.filterBand = 0.0f;
                }
                if (!voiceWasActive) {
                    v.envLevel       = 0.0f;
                    v.filterEnvLevel = 0.0f;
                }
                v.noteHeld       = true;
                v.envStage       = EnvelopeStage::Attack;
                v.filterEnvStage = EnvelopeStage::Attack;
                v.gainTarget     = 1.0f;
                v.sampleActive   = false;
            }
        }
        // Remove fired events.
        mPendingRetrigs.erase(
            std::remove_if(mPendingRetrigs.begin(), mPendingRetrigs.end(),
                [](const RetrigEvent& e) { return e.sampleTarget < 0; }),
            mPendingRetrigs.end());
    }

    if (!mPendingKills.empty()) {
        for (auto& ev : mPendingKills) {
            if (ev.sampleTarget < 0) continue; // already fired
            if (mSubRowSampleCounter < ev.sampleTarget) continue;
            ev.sampleTarget = -1; // mark fired
            if (ev.trackIdx < 0 || ev.trackIdx >= static_cast<int>(mVoices.size())) continue;
            Voice& v = mVoices[ev.trackIdx];
            // KIL: hard stop (immediate silence, no envelope)
            v.gainTarget = 0.0f;
            v.gain = 0.0f;
            v.envStage = EnvelopeStage::Idle;
            v.envLevel = 0.0f;
            v.filterEnvStage = EnvelopeStage::Idle;
            v.filterEnvLevel = 0.0f;
            v.noteHeld = false;
            v.midiNote = -1;
            v.sampleActive = false;
        }
        mPendingKills.erase(
            std::remove_if(mPendingKills.begin(), mPendingKills.end(),
                [](const KillEvent& e) { return e.sampleTarget < 0; }),
            mPendingKills.end());
    }

    // Handle row-boundary advancement after firing this row's pending
    // events above (see comment near the mSubRowSampleCounter increment).
    if (mPlayheadRunning.load() && mLineSamplesPerRow > 0) {
        mPlayheadSampleCounter += numFrames;
        while (mPlayheadSampleCounter >= mLineSamplesPerRow) {
            mPlayheadSampleCounter -= mLineSamplesPerRow;
            // Always count the boundary so the Dart poller detects queue
            // exhaustion even when primeNextQueuedPlaybackRowLocked() fails.
            mPendingRowAdvances.fetch_add(1);
            if (!primeNextQueuedPlaybackRowLocked()) {
                mPlayheadRunning.store(false);
                break;
            }
        }
    }

    // Process slice commands (SLC) — set sampler boundaries at row start.
    // Slice commands fire immediately (sampleTarget = 0).
    if (!mPendingSliceCommands.empty()) {
        for (auto& ev : mPendingSliceCommands) {
            if (ev.trackIdx < 0 || ev.trackIdx >= static_cast<int>(mVoices.size())) continue;
            Voice& v = mVoices[ev.trackIdx];
            // Convert scaled normalized positions back to 0.0-1.0 range.
            v.sampleStartNorm = std::clamp(static_cast<float>(ev.startNormScaled) / 10000.0f, 0.0f, 1.0f);
            v.sampleEndNorm   = std::clamp(static_cast<float>(ev.endNormScaled) / 10000.0f, 0.0f, 1.0f);
        }
        // Clear slice commands after processing (they've served their purpose for this row).
        mPendingSliceCommands.clear();
    }

    // Process mixer commands (M01-M99) — control mixer state at row start.
    // Mixer commands fire immediately (sampleTarget = 0).
    if (!mPendingMixerCommands.empty()) {
        for (auto& ev : mPendingMixerCommands) {
            // ev.channel: 0=master, 1-16=channels
            // ev.controller: 1-4 (pan, mute, solo, volume), 5-9 reserved
            // ev.value: 0-99
            
            if (ev.channel == 0) {
                // Master channel
                if (ev.controller == 1) {
                    // M01: master mute (value > 0 = muted, 0 = unmuted)
                    mMasterMute.store(ev.value > 0);
                } else if (ev.controller == 2) {
                    // M02: master volume (0-99 → 0.0-1.0)
                    mMasterVolume.store(ev.value / 99.0f);
                }
            } else if (ev.channel >= 1 && ev.channel <= kMaxVoices) {
                const int ti = ev.channel - 1;
                if (ev.controller == 2) {          // mute
                    mTrackMute[ti] = (ev.value > 0);
                } else if (ev.controller == 3) {   // solo
                    mTrackSolo[ti] = (ev.value > 0);
                } else if (ev.controller == 4) {   // volume (0-99 → 0..1)
                    mTrackVolume[ti] = ev.value / 99.0f;
                }
                // controller == 1 (pan) is handled per-voice; skip at bus level
            }
        }
        // Clear mixer commands after processing.
        mPendingMixerCommands.clear();
    }

    // Process own-channel insert FX commands (F11-F69) at row start.
    if (!mPendingInsertFxCommands.empty()) {
        for (auto& ev : mPendingInsertFxCommands) {
            if (ev.trackIdx < 0 || ev.trackIdx >= kMaxVoices) continue;
            if (ev.slotIdx < 0 || ev.slotIdx >= kMaxInsertSlots) continue;
            InsertEffect& fx = mTrackInserts[ev.trackIdx][ev.slotIdx];
            if (fx.type == -1) continue;
            applyInsertFxCommand(fx, ev.function, ev.value);
        }
        mPendingInsertFxCommands.clear();
    }

    // Prepare per-track buses for insert processing.
    for (int track = 0; track < kMaxVoices; ++track) {
        if (static_cast<int>(mTrackBusL[track].size()) < numFrames) {
            mTrackBusL[track].resize(numFrames);
            mTrackBusR[track].resize(numFrames);
        }
        std::fill_n(mTrackBusL[track].data(), numFrames, 0.0f);
        std::fill_n(mTrackBusR[track].data(), numFrames, 0.0f);
    }

    for (int trackIdx = 0; trackIdx < static_cast<int>(mVoices.size()); ++trackIdx) {
        auto& v = mVoices[trackIdx];
        if (v.samplerMode) {
            if (!v.sampleActive || v.sampleSlot < 0 ||
                v.sampleSlot >= static_cast<int>(mSamplerSlots.size())) {
                continue;
            }

            const auto& s = mSamplerSlots[v.sampleSlot];
            if (s.mono.empty()) {
                v.sampleActive = false;
                continue;
            }

            const int sampleFrames = static_cast<int>(s.mono.size());
            const int startFrame = std::clamp(
                static_cast<int>(v.sampleStartNorm * static_cast<float>(sampleFrames - 1)),
                0, sampleFrames - 1);
            int endFrame = std::clamp(
                static_cast<int>(v.sampleEndNorm * static_cast<float>(sampleFrames)),
                1, sampleFrames);
            if (endFrame <= startFrame) {
                endFrame = std::min(sampleFrames, startFrame + 1);
            }
            const double regionStart = static_cast<double>(startFrame);
            const double regionEnd = static_cast<double>(endFrame);
            const double regionLen = std::max(1.0, regionEnd - regionStart);

            // Loop region: clamped within playback region.
            const int loopSFrame = std::clamp(
                static_cast<int>(v.loopStartNorm * static_cast<float>(sampleFrames)),
                startFrame, endFrame - 1);
            const int loopEFrame = std::clamp(
                static_cast<int>(v.loopEndNorm * static_cast<float>(sampleFrames)),
                loopSFrame + 1, endFrame);
            const double loopRegionStart = static_cast<double>(loopSFrame);
            const double loopRegionEnd   = static_cast<double>(loopEFrame);
            const double loopLen = std::max(1.0, loopRegionEnd - loopRegionStart);

            if (v.samplePos < regionStart || v.samplePos >= regionEnd) {
                v.samplePos = regionStart;
            }

            const double srRatio = static_cast<double>(s.sampleRate) / sampleRate;
            const double trePhaseInc = 2.0 * M_PI * normToLfoHz(v.treSpeedNorm) / sampleRate;

            // ── Sampler LFO setup (note-synced, BPM-relative) ──────────────
            const bool lfoActive = (v.samplerLfoWave > 0) &&
                                   (v.samplerLfoTargets != 0) &&
                                   (v.samplerLfoDepth > 0.001f);
            double lfoPhaseInc = 0.0;
            if (lfoActive) {
                const double bpm = std::max(1.0, mBpm.load());
                const double samplesPerBeat = sampleRate * 60.0 / bpm;
                const double beatsPerCycle = kSamplerLfoDivBeats[
                    std::clamp(v.samplerLfoRateIdx, 0, 9)];
                const double samplesPerCycle = std::max(1.0, samplesPerBeat * beatsPerCycle);
                lfoPhaseInc = 1.0 / samplesPerCycle;
            }
            const bool lfoTgtVol   = lfoActive && (v.samplerLfoTargets & 1);
            const bool lfoTgtPitch = lfoActive && (v.samplerLfoTargets & 2);
            const bool lfoTgtHp    = lfoActive && (v.samplerLfoTargets & 4);
            const bool lfoTgtLp    = lfoActive && (v.samplerLfoTargets & 8);

            // Slew limiter for volume modulation (eliminates square-wave clicks).
            const float samplesInSlewWindow = kSamplerLfoSlewWindowMs * sampleRate / 1000.0f;
            const float slewPerSample = 1.0f / std::max(1.0f, samplesInSlewWindow);

            // 4-point Hermite cubic interpolation. Smoother than linear, kills
            // the aliasing/zipper artifacts you hear when pitching a sample
            // down. Reads 4 samples around samplePos (idxA..idxD); region
            // boundaries are clamped to avoid reading past the end.
            auto hermite4 = [&](double pos) -> float {
                const int i1 = static_cast<int>(pos);
                const float frac = static_cast<float>(pos - static_cast<double>(i1));
                const int i0 = std::max(startFrame, i1 - 1);
                const int i2 = std::min(endFrame - 1, i1 + 1);
                const int i3 = std::min(endFrame - 1, i1 + 2);
                const float y0 = s.mono[i0];
                const float y1 = s.mono[i1];
                const float y2 = s.mono[i2];
                const float y3 = s.mono[i3];
                const float c0 = y1;
                const float c1 = 0.5f * (y2 - y0);
                const float c2 = y0 - 2.5f * y1 + 2.0f * y2 - 0.5f * y3;
                const float c3 = 0.5f * (y3 - y0) + 1.5f * (y1 - y2);
                return ((c3 * frac + c2) * frac + c1) * frac + c0;
            };

            // Minimum envelope time: ~2 ms. Anything shorter would produce a
            // discontinuity at note-on / note-off → audible click. Two
            // milliseconds is the standard "de-click" floor used in samplers.
            const float minEnvFrames = 0.002f * static_cast<float>(sampleRate);

            for (int i = 0; i < numFrames; ++i) {
                // ── Advance sampler LFO and compute its value for this frame ──
                float lfoVal = 0.0f;
                if (lfoActive) {
                    // Random (sample & hold): pick a new value at each cycle wrap.
                    if (v.samplerLfoWave == 6 && v.samplerLfoPhase == 0.0) {
                        v.noiseState = v.noiseState * 1664525u + 1013904223u;
                        v.samplerLfoRandVal =
                            static_cast<float>((v.noiseState >> 8) & 0xFFFFu) / 65535.0f;
                    }
                    lfoVal = samplerLfoValue(v.samplerLfoWave, v.samplerLfoPhase,
                                             v.samplerLfoRandVal);
                    v.samplerLfoPhase += lfoPhaseInc;
                    if (v.samplerLfoPhase >= 1.0) {
                        v.samplerLfoPhase -= 1.0;
                        // New random value at the start of each cycle.
                        if (v.samplerLfoWave == 6) {
                            v.noiseState = v.noiseState * 1664525u + 1013904223u;
                            v.samplerLfoRandVal =
                                static_cast<float>((v.noiseState >> 8) & 0xFFFFu) / 65535.0f;
                        }
                    }
                }

                // Apply SLU/SLD pitch ramp: interpolate sampleStep per sample.
                if (v.pitchRampSamplesLeft > 0) {
                    v.sampleStep += static_cast<double>(v.sampleStepRampPerSample);
                    if (--v.pitchRampSamplesLeft == 0) {
                        v.sampleStep = static_cast<double>(v.sampleStepTarget);
                    }
                }
                double ratio = srRatio * v.sampleStep;
                // LFO → pitch: ±12 semitones scaled by depth, per anchor mode.
                if (lfoTgtPitch) {
                    const float semis = samplerLfoOffset(v.samplerLfoMode, lfoVal)
                                        * v.samplerLfoDepth * 12.0f;
                    ratio *= std::pow(2.0f, semis / 12.0f);
                }
                int idx = static_cast<int>(v.samplePos);
                if (v.loopMode > 0 && loopLen > 1.0) {
                    // Check if we've entered the loop region yet
                    if (!v.sampleHasEnteredLoopRegion && v.samplePos >= loopRegionStart) {
                        v.sampleHasEnteredLoopRegion = true;
                    }
                    
                    // Looping: only apply wrapping once we've entered the loop region
                    if (v.sampleHasEnteredLoopRegion) {
                        if (v.loopMode == 1) {
                            // Forward loop: wrap at loop region end.
                            if (v.samplePos >= loopRegionEnd) {
                                while (v.samplePos >= loopRegionEnd) v.samplePos -= loopLen;
                            }
                        } else {
                            // Ping-pong: bounce at loop region boundaries.
                            if (v.samplePos >= loopRegionEnd) {
                                v.samplePos = loopRegionEnd - (v.samplePos - loopRegionEnd) - 1.0;
                                v.samplePingDir = true;
                            } else if (v.samplePos < loopRegionStart) {
                                v.samplePos = loopRegionStart + (loopRegionStart - v.samplePos);
                                v.samplePingDir = false;
                            }
                        }
                    }
                    // Safety clamp to full playback region.
                    if (v.samplePos < regionStart) v.samplePos = regionStart;
                    if (v.samplePos >= regionEnd)  v.samplePos = regionEnd - 1.0;
                    idx = std::clamp(static_cast<int>(v.samplePos), startFrame, endFrame - 1);
                } else if (idx < startFrame || idx >= endFrame) {
                    // Non-looping: outside playback region = stop.
                    v.sampleActive = false;
                    v.midiNote = -1;
                    break;
                }

                // Attack / release gain envelope. Enforce ~2 ms minimum so a
                // value of 0 (or anything sub-2-ms) still gets de-clicked.
                float envGain = 1.0f;
                const float atkFrames = std::max(minEnvFrames,
                    static_cast<float>(v.attackSec  * sampleRate));
                const float relFrames = std::max(minEnvFrames,
                    static_cast<float>(v.releaseSec * sampleRate));
                const float elapsed = static_cast<float>(v.sampleElapsedFrames);
                if (elapsed < atkFrames) {
                    envGain = elapsed / atkFrames;
                }
                // Release fade: if note-off was received (samplerReleaseActive,
                // set for BOTH looping and non-looping samples), fade out over
                // releaseSec measured from note-off and then stop — this is what
                // makes the OFF command respect the release setting instead of
                // clicking. Otherwise, for non-looping samples reaching the
                // natural end of the region, fade based on distance to end so
                // playing off the end of the sample never clicks either.
                if (v.samplerReleaseActive) {
                    const float releaseElapsed = static_cast<float>(v.sampleElapsedFrames - v.samplerReleaseStartFrames);
                    if (releaseElapsed >= relFrames) {
                        envGain = 0.0f; // silence this frame before stopping to avoid click
                        v.sampleActive = false;
                        v.samplerReleaseActive = false;
                        // Write zeroed sample then break — do NOT let next iteration
                        // render with envGain=1 (that would produce a click).
                        mTrackBusL[trackIdx][i] += 0.0f;
                        mTrackBusR[trackIdx][i] += 0.0f;
                        break;
                    } else {
                        envGain *= std::max(0.0f, 1.0f - (releaseElapsed / relFrames));
                    }
                } else if (v.loopMode == 0) {
                    const double framesLeft = regionEnd - v.samplePos;
                    if (framesLeft < static_cast<double>(relFrames)) {
                        envGain *= static_cast<float>(std::max(0.0, framesLeft)) / relFrames;
                    }
                }

                // TRE/GAT: independent volume LFO (sine = TRE, square = GAT).
                float treAmpMod = 1.0f;
                if (v.treMode > 0 && v.treDepth > 0.001f) {
                    const float treVal = (v.treMode == 2)
                        ? ((v.trePhase < M_PI) ? 1.0f : -1.0f)
                        : static_cast<float>(std::sin(v.trePhase));
                    treAmpMod = 1.0f - v.treDepth * (0.5f - treVal * 0.5f);
                    v.trePhase += trePhaseInc;
                    if (v.trePhase >= 2.0 * M_PI) v.trePhase -= 2.0 * M_PI;
                }

                const float interpSample = hermite4(v.samplePos);
                float dry = interpSample * v.level * v.instrumentVolume * v.sampleGain * envGain * treAmpMod;

                // Anti-click retrigger tail: blend in the fading remnant of
                // whatever this voice was outputting right before it was
                // retriggered, so the signal stays continuous instead of
                // jumping straight to the new note's silent attack start.
                if (v.declickTailFramesLeft > 0) {
                    const float tailFrac = static_cast<float>(v.declickTailFramesLeft) /
                                            static_cast<float>(v.declickTailFramesTotal);
                    dry += v.declickTailGain0 * tailFrac;
                    v.declickTailFramesLeft--;
                }

                // LFO → volume: gain multiplier per anchor mode. DOWN pulls the
                // level below the knob value (envelope-style swell with Ramp Up).
                // Slew-limited to eliminate clicks from sudden square-wave jumps.
                if (lfoTgtVol) {
                    const float target = 1.0f + samplerLfoOffset(v.samplerLfoMode, lfoVal)
                                               * v.samplerLfoDepth;
                    v.samplerLfoVolModTarget = std::clamp(target, 0.0f, 2.0f);
                    // Slew: move current value toward target at max rate per sample.
                    if (v.samplerLfoVolModCurr < v.samplerLfoVolModTarget) {
                        v.samplerLfoVolModCurr = std::min(v.samplerLfoVolModTarget,
                            v.samplerLfoVolModCurr + slewPerSample);
                    } else if (v.samplerLfoVolModCurr > v.samplerLfoVolModTarget) {
                        v.samplerLfoVolModCurr = std::max(v.samplerLfoVolModTarget,
                            v.samplerLfoVolModCurr - slewPerSample);
                    }
                    dry *= v.samplerLfoVolModCurr;
                }

                // LFO → filter cutoffs: modulate HP/LP per anchor mode. When the
                // LFO targets HP/LP the filter runs even if the static filter is
                // off, so the modulation is always audible.
                float hpCut = v.samplerHpCutoff;
                float lpCut = v.samplerLpCutoff;
                if (lfoTgtHp) {
                    hpCut = std::clamp(v.samplerHpCutoff +
                        samplerLfoOffset(v.samplerLfoMode, lfoVal) * v.samplerLfoDepth,
                        0.0f, 1.0f);
                }
                if (lfoTgtLp) {
                    lpCut = std::clamp(v.samplerLpCutoff +
                        samplerLfoOffset(v.samplerLfoMode, lfoVal) * v.samplerLfoDepth,
                        0.0f, 1.0f);
                }

                // ── Sampler HP → LP filter (in series). Zero CPU when OFF. ──
                if (v.samplerFilterOn || lfoTgtHp || lfoTgtLp) {
                    const float srF = static_cast<float>(sampleRate);
                    const float nyqLimit = srF * 0.20f;
                    // HP stage — skip when fully open (cutoff near 0).
                    if (hpCut > 0.005f) {
                        const float hz = std::clamp(normToCutoffHz(hpCut), 20.0f, nyqLimit);
                        const float f = std::clamp(2.0f * std::sin(static_cast<float>(M_PI) * hz / srF),
                                                   0.001f, 0.99f);
                        const float damp = std::max(0.05f, 1.0f - v.samplerHpRes * 0.95f);
                        const float high = dry - v.samplerHpLow - (damp * v.samplerHpBand);
                        v.samplerHpBand += f * high;
                        v.samplerHpLow  += f * v.samplerHpBand;
                        if (!std::isfinite(v.samplerHpLow) || !std::isfinite(v.samplerHpBand)) {
                            v.samplerHpLow = 0.0f;
                            v.samplerHpBand = 0.0f;
                        }
                        dry = high;
                    }
                    // LP stage — skip when fully open (cutoff near 1).
                    if (lpCut < 0.995f) {
                        const float hz = std::clamp(normToCutoffHz(lpCut), 20.0f, nyqLimit);
                        const float f = std::clamp(2.0f * std::sin(static_cast<float>(M_PI) * hz / srF),
                                                   0.001f, 0.99f);
                        const float damp = std::max(0.05f, 1.0f - v.samplerLpRes * 0.95f);
                        const float high = dry - v.samplerLpLow - (damp * v.samplerLpBand);
                        v.samplerLpBand += f * high;
                        v.samplerLpLow  += f * v.samplerLpBand;
                        if (!std::isfinite(v.samplerLpLow) || !std::isfinite(v.samplerLpBand)) {
                            v.samplerLpLow = 0.0f;
                            v.samplerLpBand = 0.0f;
                        }
                        dry = v.samplerLpLow;
                    }
                }

                const float pan01 = std::clamp(v.pan, 0.0f, 1.0f);
                const float angle = pan01 * 1.57079632679f;
                const float leftGain  = std::cos(angle);
                const float rightGain = std::sin(angle);

                v.sampleLastOutput = dry;
                mTrackBusL[trackIdx][i] += dry * leftGain;
                mTrackBusR[trackIdx][i] += dry * rightGain;

                v.samplePos += v.samplePingDir ? -ratio : ratio;
                v.sampleElapsedFrames += 1.0;
            }
            continue;
        }

        if (v.karplusMode) {
            if (!v.karplusActive || v.karplusBuf.empty()) {
                if (!v.noteHeld && v.gain < 1e-4f && v.gainTarget < 1e-4f) {
                    v.karplusMode = false;
                    v.midiNote = -1;
                }
                continue;
            }

            const float feedback = karplusFeedback(v.karplusDecayNorm);
            const float brightness = karplusBrightness(v.karplusDampingNorm);
            const float dispersion = karplusDispersion(v.karplusStretchNorm);
            const float bodyBlend = karplusBodyBlend(v.karplusBodyNorm);
            const float driveAmount = karplusDriveAmount(v.karplusDriveNorm);
            const int bufSize = static_cast<int>(v.karplusBuf.size());
            const double trePhaseInc = 2.0 * M_PI * normToLfoHz(v.treSpeedNorm) / sampleRate;

            for (int i = 0; i < numFrames; ++i) {
                v.gain += smoothK * (v.gainTarget - v.gain);
                v.pan += panSmoothK * (v.panTarget - v.pan);

                const int nextPos = (v.karplusPos + 1) % bufSize;
                const float current = v.karplusBuf[v.karplusPos];
                const float next = v.karplusBuf[nextPos];
                const float filtered = current * brightness + next * (1.0f - brightness);
                const float dispersed = filtered + dispersion * (filtered - v.karplusDispersionState);
                v.karplusDispersionState = filtered;
                v.karplusBuf[v.karplusPos] = std::clamp(dispersed * feedback, -1.0f, 1.0f);
                v.karplusPos = nextPos;

                float sample = current;
                const float bodyLowCoeff = 0.018f + bodyBlend * 0.085f;
                const float bodyHighCoeff = 0.090f + bodyBlend * 0.190f;
                v.karplusBodyState += (sample - v.karplusBodyState) * bodyLowCoeff;
                v.karplusBodyState2 += (sample - v.karplusBodyState2) * bodyHighCoeff;
                const float bodyResonance = v.karplusBodyState2 - v.karplusBodyState;
                sample = sample * (1.0f - bodyBlend * 0.24f) +
                         v.karplusBodyState * bodyBlend * 0.82f +
                         bodyResonance * bodyBlend * 1.65f;
                if (driveAmount > 0.001f) {
                    const float boosted = sample * (1.0f + driveAmount * 6.0f);
                    sample = boosted / (1.0f + std::fabs(boosted));
                }
                // TRE/GAT: independent volume LFO (sine = TRE, square = GAT).
                float treAmpMod = 1.0f;
                if (v.treMode > 0 && v.treDepth > 0.001f) {
                    const float treVal = (v.treMode == 2)
                        ? ((v.trePhase < M_PI) ? 1.0f : -1.0f)
                        : static_cast<float>(std::sin(v.trePhase));
                    treAmpMod = 1.0f - v.treDepth * (0.5f - treVal * 0.5f);
                    v.trePhase += trePhaseInc;
                    if (v.trePhase >= 2.0 * M_PI) v.trePhase -= 2.0 * M_PI;
                }
                sample = sample * v.gain * v.level * v.instrumentVolume * 0.35f * treAmpMod;

                const float pan01 = std::clamp(v.pan, 0.0f, 1.0f);
                const float angle = pan01 * 1.57079632679f;
                const float leftGain = std::cos(angle);
                const float rightGain = std::sin(angle);

                mTrackBusL[trackIdx][i] += sample * leftGain;
                mTrackBusR[trackIdx][i] += sample * rightGain;

                if (!v.noteHeld && v.gain < 1e-4f) {
                    v.karplusActive = false;
                    v.karplusMode = false;
                    v.midiNote = -1;
                    break;
                }
            }
            continue;
        }

        if (v.drumMode) {
            if (!v.drumActive) {
                if (!v.noteHeld && v.gain < 1e-4f && v.gainTarget < 1e-4f) {
                    v.drumMode = false;
                    v.midiNote = -1;
                }
                continue;
            }

            const float pitchEnvCoeff = drumPitchEnvCoeff(v.drumPitchDecayNorm, sampleRate);
            const float ampEnvCoeff   = drumAmpEnvCoeff(v.drumDecayNorm, sampleRate);
            const float clickEnvCoeff = drumClickEnvCoeff(sampleRate);
            const float toneAmt       = std::clamp(v.drumToneNorm, 0.0f, 1.0f);
            const float punchAmt      = std::clamp(v.drumPunchNorm, 0.0f, 1.0f);
            const float driveAmt      = std::clamp(v.drumDriveNorm, 0.0f, 1.0f);
            const int combLen         = static_cast<int>(v.drumCombBuf.size());
            const float combFeedback  = drumCombFeedback(v.drumResonanceNorm);
            const bool isMetallic     = (v.drumPiece == kDrumHat || v.drumPiece == kDrumCrash);
            const bool isTonalSweep   = (v.drumPiece == kDrumKick || v.drumPiece == kDrumTom);

            // Noise-layer state-variable filter coefficients (Snare/Hat/Crash).
            const float srF = static_cast<float>(sampleRate);
            const float noiseHz = isMetallic
                ? (1500.0f + std::clamp(v.drumCutoffNorm, 0.0f, 1.0f) * 7000.0f)   // 1.5-8.5 kHz HP
                : (300.0f + std::clamp(v.drumCutoffNorm, 0.0f, 1.0f) * 3500.0f);   // 300-3800 Hz BP
            const float noiseF = std::clamp(2.0f * std::sin(static_cast<float>(M_PI) * noiseHz / srF),
                                             0.001f, 0.99f);
            const float noiseDamp = std::max(0.05f, 1.0f - v.drumResonanceNorm * 0.85f);

            for (int i = 0; i < numFrames; ++i) {
                v.gain += smoothK * (v.gainTarget - v.gain);
                v.pan  += panSmoothK * (v.panTarget - v.pan);

                v.drumPitchEnvLevel *= pitchEnvCoeff;
                v.drumAmpEnvLevel   *= ampEnvCoeff;
                v.drumClickEnvLevel *= clickEnvCoeff;

                // Fresh noise sample this frame (shared PRNG, same as Karplus).
                v.noiseState = v.noiseState * 1664525u + 1013904223u;
                const float noise = (static_cast<float>((v.noiseState >> 8) & 0xFFFFu) / 32767.5f) - 1.0f;

                float sample;
                if (isMetallic) {
                    // Hi-hat / Crash: highpassed noise + short metallic comb ring.
                    const float high = noise - v.drumFilterLow - (noiseDamp * v.drumFilterBand);
                    v.drumFilterBand += noiseF * high;
                    v.drumFilterLow  += noiseF * v.drumFilterBand;
                    float combOut = 0.0f;
                    if (combLen > 0) {
                        combOut = v.drumCombBuf[v.drumCombPos];
                        const float combIn = std::clamp(high + combOut * combFeedback, -1.0f, 1.0f);
                        v.drumCombBuf[v.drumCombPos] = combIn;
                        v.drumCombPos = (v.drumCombPos + 1) % combLen;
                    }
                    sample = (high * (1.0f - toneAmt) + combOut * toneAmt) * v.drumAmpEnvLevel;
                    sample += noise * v.drumClickEnvLevel * punchAmt * 0.5f;
                } else {
                    // Kick / Tom / Snare: sine (+ pitch sweep for Kick/Tom) oscillator.
                    const float freq = v.drumFreqEnd +
                        (v.drumFreqStart - v.drumFreqEnd) *
                            (isTonalSweep ? v.drumPitchEnvLevel : 1.0f);
                    const double phaseInc = 2.0 * M_PI * freq / sampleRate;
                    v.drumOscPhase += phaseInc;
                    if (v.drumOscPhase >= 2.0 * M_PI) v.drumOscPhase -= 2.0 * M_PI;
                    const float osc = static_cast<float>(std::sin(v.drumOscPhase));
                    // TONE adds cubic harmonic content for a harder body.
                    const float shaped = osc + toneAmt * (osc * osc * osc - osc) * 0.6f;

                    if (v.drumPiece == kDrumSnare) {
                        const float high = noise - v.drumFilterLow - (noiseDamp * v.drumFilterBand);
                        v.drumFilterBand += noiseF * high;
                        v.drumFilterLow  += noiseF * v.drumFilterBand;
                        sample = (shaped * (1.0f - toneAmt) * 0.6f + v.drumFilterBand * (0.4f + toneAmt * 0.6f))
                                 * v.drumAmpEnvLevel;
                        sample += noise * v.drumClickEnvLevel * punchAmt * 0.8f;
                    } else {
                        sample = shaped * v.drumAmpEnvLevel;
                        sample += noise * v.drumClickEnvLevel * punchAmt * 0.6f;
                    }
                }

                if (driveAmt > 0.001f) {
                    const float boosted = sample * (1.0f + driveAmt * 6.0f);
                    sample = boosted / (1.0f + std::fabs(boosted));
                }
                sample = sample * v.gain * v.level * v.instrumentVolume * 0.6f;

                const float pan01 = std::clamp(v.pan, 0.0f, 1.0f);
                const float angle = pan01 * 1.57079632679f;
                const float leftGain = std::cos(angle);
                const float rightGain = std::sin(angle);

                mTrackBusL[trackIdx][i] += sample * leftGain;
                mTrackBusR[trackIdx][i] += sample * rightGain;

                if (v.drumAmpEnvLevel < 1e-4f || (v.gain < 1e-4f && !v.noteHeld)) {
                    v.drumActive = false;
                    v.drumMode = false;
                    v.midiNote = -1;
                    break;
                }
            }
            continue;
        }

        if (v.midiNote < 0) continue;
        // Skip voices that are fully silent, not ramping up, and have no pending waveform swap.
        if (v.gain < 1e-5f && v.gainTarget < 1e-5f && v.pendingWaveform < 0) continue;

        const float atkK = poleK(static_cast<float>(sampleRate), v.attackSec);
        const float decK = poleK(static_cast<float>(sampleRate), v.decaySec);
        const float relK = poleK(static_cast<float>(sampleRate), v.releaseSec);
        const float fatkK = poleK(static_cast<float>(sampleRate), v.filterAttackSec);
        const float fdecK = poleK(static_cast<float>(sampleRate), v.filterDecaySec);
        const float frelK = poleK(static_cast<float>(sampleRate), v.filterReleaseSec);
        const float glideK = (v.glideSec > 0.0f)
            ? poleK(static_cast<float>(sampleRate), v.glideSec)
            : 1.0f;
        const float lfoHz = normToLfoHz(v.lfoRateNorm);
        const double lfoPhaseInc = 2.0 * M_PI * lfoHz / sampleRate;
        const float treHz = normToLfoHz(v.treSpeedNorm);
        const double trePhaseInc = 2.0 * M_PI * treHz / sampleRate;
        // Chamberlin SVF damping: map resonance to a musically useful Q range.
        // Keeping this <= 1.0 avoids over-damping that can turn high-cutoff
        // content into mostly transients/clicks.
        const float damp = std::max(0.05f, 1.0f - (v.resonanceNorm * 0.95f));

        for (int i = 0; i < numFrames; ++i) {
            v.gain += smoothK * (v.gainTarget - v.gain);
            v.pan += panSmoothK * (v.panTarget - v.pan);
            if (v.pitchRampSamplesLeft > 0) {
                // Linear pitch ramp for SLU/SLD: interpolates in frequency space
                // at sample granularity → smooth cent-level sliding.
                v.currentFreq += v.pitchRampFreqPerSample;
                if (--v.pitchRampSamplesLeft == 0) {
                    v.currentFreq = v.targetFreq; // snap to exact target at end
                }
            } else if (v.glideSec > 0.0f) {
                v.currentFreq += glideK * (v.targetFreq - v.currentFreq);
            } else {
                v.currentFreq = v.targetFreq;
            }

            // LFO: sine oscillator, applied before frequency/filter/amp calculation.
            const float lfoVal = static_cast<float>(std::sin(v.lfoPhase)); // -1..1
            v.lfoPhase += lfoPhaseInc;
            if (v.lfoPhase >= 2.0 * M_PI) v.lfoPhase -= 2.0 * M_PI;

            // If a waveform swap is pending and gain has faded to silence,
            // apply the new waveform and restore the target gain.
            if (v.pendingWaveform >= 0 && v.gain < 1e-3f) {
                v.waveform          = v.pendingWaveform;
                v.gainTarget        = v.pendingGainTarget;
                v.pendingWaveform   = -1;
                v.pendingGainTarget = 0.0f;
            }

            switch (v.envStage) {
                case EnvelopeStage::Idle:
                    v.envLevel = 0.0f;
                    break;
                case EnvelopeStage::Attack:
                    v.envLevel += atkK * (1.0f - v.envLevel);
                    if (v.envLevel >= 0.999f) {
                        v.envLevel = 1.0f;
                        v.envStage = EnvelopeStage::Decay;
                    }
                    break;
                case EnvelopeStage::Decay:
                    v.envLevel += decK * (v.sustainLevel - v.envLevel);
                    if (std::fabs(v.envLevel - v.sustainLevel) < 1e-4f) {
                        v.envLevel = v.sustainLevel;
                        v.envStage = v.noteHeld ? EnvelopeStage::Sustain : EnvelopeStage::Release;
                    }
                    break;
                case EnvelopeStage::Sustain:
                    v.envLevel = v.sustainLevel;
                    if (!v.noteHeld) {
                        v.envStage = EnvelopeStage::Release;
                    }
                    break;
                case EnvelopeStage::Release:
                    v.envLevel += relK * (0.0f - v.envLevel);
                    if (v.envLevel < 1e-4f) {
                        v.envLevel = 0.0f;
                        v.envStage = EnvelopeStage::Idle;
                        v.midiNote = -1;
                        v.gainTarget = 0.0f;
                        v.gain = 0.0f;
                        continue;
                    }
                    break;
            }

            switch (v.filterEnvStage) {
                case EnvelopeStage::Idle:
                    v.filterEnvLevel = 0.0f;
                    break;
                case EnvelopeStage::Attack:
                    v.filterEnvLevel += fatkK * (1.0f - v.filterEnvLevel);
                    if (v.filterEnvLevel >= 0.999f) {
                        v.filterEnvLevel = 1.0f;
                        v.filterEnvStage = EnvelopeStage::Decay;
                    }
                    break;
                case EnvelopeStage::Decay:
                    v.filterEnvLevel += fdecK * (v.filterSustainLevel - v.filterEnvLevel);
                    if (std::fabs(v.filterEnvLevel - v.filterSustainLevel) < 1e-4f) {
                        v.filterEnvLevel = v.filterSustainLevel;
                        v.filterEnvStage = v.noteHeld ? EnvelopeStage::Sustain : EnvelopeStage::Release;
                    }
                    break;
                case EnvelopeStage::Sustain:
                    v.filterEnvLevel = v.filterSustainLevel;
                    if (!v.noteHeld) {
                        v.filterEnvStage = EnvelopeStage::Release;
                    }
                    break;
                case EnvelopeStage::Release:
                    v.filterEnvLevel += frelK * (0.0f - v.filterEnvLevel);
                    if (v.filterEnvLevel < 1e-4f) {
                        v.filterEnvLevel = 0.0f;
                        v.filterEnvStage = EnvelopeStage::Idle;
                    }
                    break;
            }

            // LFO application — modulate pitch, filter cutoff, or amp.
            float voiceFreq = v.currentFreq;
            float lfoAmpMod = 1.0f;
            float lfoCutoffMod = 0.0f;
            if (v.lfoDepth > 0.001f) {
                if (v.lfoTarget == 0) { // pitch ±2 semitones × depth
                    const float semitones = lfoVal * v.lfoDepth * 2.0f;
                    voiceFreq *= std::pow(2.0f, semitones / 12.0f);
                } else if (v.lfoTarget == 1) { // filter cutoff
                    lfoCutoffMod = lfoVal * v.lfoDepth * 0.35f;
                } else { // amp tremolo
                    lfoAmpMod = 1.0f - v.lfoDepth * (0.5f - lfoVal * 0.5f);
                }
            }

            // TRE/GAT: independent volume LFO (sine = TRE, square = GAT).
            if (v.treMode > 0 && v.treDepth > 0.001f) {
                const float treVal = (v.treMode == 2)
                    ? ((v.trePhase < M_PI) ? 1.0f : -1.0f)   // GAT: square wave
                    : static_cast<float>(std::sin(v.trePhase)); // TRE: sine wave
                lfoAmpMod *= 1.0f - v.treDepth * (0.5f - treVal * 0.5f);
                v.trePhase += trePhaseInc;
                if (v.trePhase >= 2.0 * M_PI) v.trePhase -= 2.0 * M_PI;
            }

            // ── OSC 3: compute first (FM source for OSC 2) ─────────────────────────
            float osc3Raw = 0.0f;
            if (v.osc3On) {
                const float det3 = (v.osc3DetuneNorm - 0.5f) * 24.0f;
                const double freq3 = static_cast<double>(std::max(1.0f, voiceFreq * v.osc3OctMult)) *
                    std::pow(2.0, static_cast<double>(det3) / 12.0);
                const double inc3 = twoPi * freq3 / sampleRate;
                const float t3 = static_cast<float>(v.osc3Phase / twoPi);
                switch (v.osc3Waveform) {
                    case 1: osc3Raw = 1.0f - 4.0f * std::fabs(t3 - 0.5f); break;
                    case 2: osc3Raw = 2.0f * t3 - 1.0f; break;
                    case 3: osc3Raw = (t3 < 0.5f) ? 1.0f : -1.0f; break;
                    case 4: osc3Raw = (t3 < 0.25f) ? 1.0f : -1.0f; break;
                    case 5: {
                        uint32_t ns3 = (v.noiseState ^ 0x5A5A5A5Au) * 22695477u + 1u;
                        osc3Raw = (static_cast<float>((ns3 >> 8) & 0xFFFFu) / 32767.5f) - 1.0f;
                        break;
                    }
                    default: osc3Raw = static_cast<float>(std::sin(v.osc3Phase)); break;
                }
                v.osc3Phase += inc3;
                if (v.osc3Phase >= twoPi) v.osc3Phase -= twoPi;
            }

            // ── OSC 2: FM-modulated by OSC 3, FM source for OSC 1 ───────────────
            float osc2Raw = 0.0f;
            if (v.osc2On) {
                const float det2 = (v.osc2DetuneNorm - 0.5f) * 24.0f;
                float freq2 = std::max(1.0f, voiceFreq * v.osc2OctMult) *
                    std::pow(2.0f, det2 / 12.0f);
                if (v.osc3On && v.osc3FmDepth > 0.001f) {
                    freq2 = std::max(1.0f, freq2 + osc3Raw * v.osc3FmDepth * freq2 * 3.0f);
                }
                const double inc2 = twoPi * static_cast<double>(freq2) / sampleRate;
                const float t2 = static_cast<float>(v.osc2Phase / twoPi);
                switch (v.osc2Waveform) {
                    case 1: osc2Raw = 1.0f - 4.0f * std::fabs(t2 - 0.5f); break;
                    case 2: osc2Raw = 2.0f * t2 - 1.0f; break;
                    case 3: osc2Raw = (t2 < 0.5f) ? 1.0f : -1.0f; break;
                    case 4: osc2Raw = (t2 < 0.25f) ? 1.0f : -1.0f; break;
                    case 5: {
                        uint32_t ns2 = (v.noiseState ^ 0xA5A5A5A5u) * 1664525u + 1013904223u;
                        osc2Raw = (static_cast<float>((ns2 >> 8) & 0xFFFFu) / 32767.5f) - 1.0f;
                        break;
                    }
                    default: osc2Raw = static_cast<float>(std::sin(v.osc2Phase)); break;
                }
                v.osc2Phase += inc2;
                if (v.osc2Phase >= twoPi) v.osc2Phase -= twoPi;
            }

            // ── OSC 1: FM-modulated by OSC 2 ───────────────────────────────
            const float oct1Freq = voiceFreq * v.osc1OctMult;
            float fm1Freq = oct1Freq;
            if (v.osc2On && v.osc2FmDepth > 0.001f) {
                fm1Freq = std::max(1.0f, oct1Freq + osc2Raw * v.osc2FmDepth * oct1Freq * 3.0f);
            }
            const double phaseInc = twoPi * static_cast<double>(std::max(1.0f, fm1Freq)) / sampleRate;
            const float t = static_cast<float>(v.phase / twoPi); // [0,1)
            float osc = 0.0f;
            switch (v.waveform) {
                case 1: // triangle
                    osc = 1.0f - 4.0f * std::fabs(t - 0.5f);
                    break;
                case 2: // saw
                    osc = 2.0f * t - 1.0f;
                    break;
                case 3: // square
                    osc = (t < 0.5f) ? 1.0f : -1.0f;
                    break;
                case 4: // pulse (25%)
                    osc = (t < 0.25f) ? 1.0f : -1.0f;
                    break;
                case 5: { // noise
                    v.noiseState = v.noiseState * 1664525u + 1013904223u;
                    const uint32_t n = (v.noiseState >> 8) & 0xFFFFu;
                    osc = (static_cast<float>(n) / 32767.5f) - 1.0f;
                    break;
                }
                default: // sine
                    osc = static_cast<float>(std::sin(v.phase));
                    break;
            }

            // Mix OSC 1 + OSC 2 + OSC 3.
            const float oscMix = osc * v.osc1Gain
                + (v.osc2On ? osc2Raw * v.osc2Gain : 0.0f)
                + (v.osc3On ? osc3Raw * v.osc3Gain : 0.0f);
            float dry = oscMix * v.gain * v.envLevel * v.level * v.instrumentVolume * 0.15f * lfoAmpMod;

            // Drive: boost then soft-clip (Doidic formula: x/(1+|x|)).
            if (v.drive > 0.001f) {
                const float boost = 1.0f + v.drive * 8.0f;
                const float driven = dry * boost;
                dry = driven / (1.0f + std::fabs(driven));
            }

            const float cutoffNormDyn = std::clamp(
                v.cutoffNorm + (v.filterEnvLevel * v.filterEnvAmt) + lfoCutoffMod,
                0.0f, 1.0f);
            // Keep cutoff inside the stable range for this SVF formulation.
            const float cutoffHz = std::clamp(normToCutoffHz(cutoffNormDyn), 20.0f,
                static_cast<float>(sampleRate) * 0.20f);
            const float f = std::clamp(2.0f * std::sin(static_cast<float>(M_PI) * cutoffHz /
                static_cast<float>(sampleRate)), 0.001f, 0.99f);

            // Chamberlin SVF — computes LP, BP, and HP simultaneously.
            const float svfHigh = dry - v.filterLow - (damp * v.filterBand);
            v.filterBand += f * svfHigh;
            v.filterLow  += f * v.filterBand;
            if (!std::isfinite(v.filterLow) || !std::isfinite(v.filterBand)) {
                v.filterLow = 0.0f;
                v.filterBand = 0.0f;
            }
            // Select output based on filter mode: 0=LP, 1=HP, 2=BP.
            float sample;
            switch (v.filterMode) {
                case 1:  sample = svfHigh;      break; // high-pass
                case 2:  sample = v.filterBand; break; // band-pass
                default: sample = v.filterLow;  break; // low-pass
            }

            // Equal-power panning for a mono voice into stereo output.
            const float pan01 = std::clamp(v.pan, 0.0f, 1.0f);
            const float angle = pan01 * 1.57079632679f;
            const float leftGain = std::cos(angle);
            const float rightGain = std::sin(angle);

            mTrackBusL[trackIdx][i] += sample * leftGain;
            mTrackBusR[trackIdx][i] += sample * rightGain;
            v.phase += phaseInc;
            if (v.phase >= twoPi) v.phase -= twoPi;
        }
    }

    // Apply track insert effects, then route via send configuration.
    //
    // Send routing rules:
    //   mTrackSendChannel[track] == 0  → direct to master output
    //   mTrackSendChannel[track] == N  → accumulate into track N-1's bus
    //
    // Two-pass approach:
    //   Pass 1: for each track, apply its own insert FX, then either:
    //           a) sum straight into `out[]` (direct-to-master), or
    //           b) accumulate into the destination track's bus (send).
    //   Pass 2: for any track bus that received sends (is a send destination),
    //           apply that track's insert FX to the accumulated signal and
    //           sum the result into master.
    //
    // We detect send destinations by scanning mTrackSendChannel once.

    // Determine which tracks are send destinations.
    std::array<bool, kMaxVoices> isSendDest{};
    for (int t = 0; t < kMaxVoices; ++t) {
        const int dest = mTrackSendChannel[t];
        if (dest > 0 && dest <= kMaxVoices && (dest - 1) != t) {
            isSendDest[dest - 1] = true;
        }
    }

    // Pre-compute solo flag: if any track is soloed, non-soloed tracks are silenced.
    bool anySolo = false;
    for (int t = 0; t < kMaxVoices; ++t) {
        if (mTrackSolo[t]) { anySolo = true; break; }
    }

    // Allocate/zero send accumulation buffers for destinations.
    // We reuse a local array of per-track accumulation vectors.
    // For send destination tracks we zero their bus here (it will be
    // filled by the sends below); their voice output has already been
    // written to mTrackBusL/R, so we save it to a temporary first.
    std::array<std::vector<float>, kMaxVoices> savedBusL;
    std::array<std::vector<float>, kMaxVoices> savedBusR;
    for (int t = 0; t < kMaxVoices; ++t) {
        if (isSendDest[t]) {
            savedBusL[t].assign(mTrackBusL[t].begin(), mTrackBusL[t].begin() + numFrames);
            savedBusR[t].assign(mTrackBusR[t].begin(), mTrackBusR[t].begin() + numFrames);
            std::fill_n(mTrackBusL[t].data(), numFrames, 0.0f);
            std::fill_n(mTrackBusR[t].data(), numFrames, 0.0f);
        }
    }

    // Pass 1: apply insert FX to each source track, then route.
    for (int track = 0; track < kMaxVoices; ++track) {
        if (isSendDest[track]) continue; // handled in pass 2

        if (!mPreviewBypassTrackInserts[track]) {
            processEffects(
                mTrackBusL[track].data(),
                mTrackBusR[track].data(),
                numFrames,
                mTrackInserts[track]
            );
        }

        // Apply per-track bus-level gain, mute, and solo.
        {
            const bool silenced = mTrackMute[track] || (anySolo && !mTrackSolo[track]);
            const float gain = silenced ? 0.0f : mTrackVolume[track];
            if (gain != 1.0f) {
                for (int i = 0; i < numFrames; ++i) {
                    mTrackBusL[track][i] *= gain;
                    mTrackBusR[track][i] *= gain;
                }
            }
        }

        for (int i = 0; i < numFrames; ++i) {
            callbackTrackPeakL[track] = std::max(callbackTrackPeakL[track], std::abs(mTrackBusL[track][i]));
            callbackTrackPeakR[track] = std::max(callbackTrackPeakR[track], std::abs(mTrackBusR[track][i]));
        }

        if (mPreviewBypassTrackInserts[track]) {
            for (int i = 0; i < numFrames; ++i) {
                previewDirectL[i] += mTrackBusL[track][i];
                previewDirectR[i] += mTrackBusR[track][i];
            }
            continue;
        }

        const int dest = mTrackSendChannel[track];
        if (dest == 0 || dest > kMaxVoices || (dest - 1) == track) {
            // Direct to master
            for (int i = 0; i < numFrames; ++i) {
                out[i * 2]     += mTrackBusL[track][i];
                out[i * 2 + 1] += mTrackBusR[track][i];
            }
        } else {
            // Accumulate into destination send bus
            const int di = dest - 1;
            for (int i = 0; i < numFrames; ++i) {
                mTrackBusL[di][i] += mTrackBusL[track][i];
                mTrackBusR[di][i] += mTrackBusR[track][i];
            }
        }
    }

    // Pass 2: process each send-destination track.
    // Its bus now holds the accumulated sends from all source tracks.
    // Also restore its own voices' signal (saved above) and mix in.
    for (int track = 0; track < kMaxVoices; ++track) {
        if (!isSendDest[track]) continue;

        // Add this track's own voice output back into the accumulated bus.
        for (int i = 0; i < numFrames; ++i) {
            mTrackBusL[track][i] += savedBusL[track][i];
            mTrackBusR[track][i] += savedBusR[track][i];
        }

        // Apply this track's insert FX to the fully-accumulated bus.
        if (!mPreviewBypassTrackInserts[track]) {
            processEffects(
                mTrackBusL[track].data(),
                mTrackBusR[track].data(),
                numFrames,
                mTrackInserts[track]
            );
        }

        // Apply per-track bus-level gain, mute, and solo for the send destination.
        {
            const bool silenced = mTrackMute[track] || (anySolo && !mTrackSolo[track]);
            const float gain = silenced ? 0.0f : mTrackVolume[track];
            if (gain != 1.0f) {
                for (int i = 0; i < numFrames; ++i) {
                    mTrackBusL[track][i] *= gain;
                    mTrackBusR[track][i] *= gain;
                }
            }
        }

        for (int i = 0; i < numFrames; ++i) {
            callbackTrackPeakL[track] = std::max(callbackTrackPeakL[track], std::abs(mTrackBusL[track][i]));
            callbackTrackPeakR[track] = std::max(callbackTrackPeakR[track], std::abs(mTrackBusR[track][i]));
        }

        if (mPreviewBypassTrackInserts[track]) {
            for (int i = 0; i < numFrames; ++i) {
                previewDirectL[i] += mTrackBusL[track][i];
                previewDirectR[i] += mTrackBusR[track][i];
            }
            continue;
        }

        // Send-destination tracks always route to master (no chaining).
        for (int i = 0; i < numFrames; ++i) {
            out[i * 2]     += mTrackBusL[track][i];
            out[i * 2 + 1] += mTrackBusR[track][i];
        }
    }


    // Apply master mute and volume ───────────────────────────────────────────────
    const bool masterMute = mMasterMute.load();
    const float masterVolume = mMasterVolume.load();
    
    if (masterMute) {
        // Master is muted: silence entire output
        std::fill(out, out + numFrames * 2, 0.0f);
    } else if (masterVolume < 1.0f) {
        // Apply master volume gain to all samples
        for (int i = 0; i < numFrames * 2; ++i) {
            out[i] *= masterVolume;
        }
    }

    // ── Apply master insert effects ─────────────────────────────────────────────
    // Process reverb and other effects on the master bus.
    if (static_cast<int>(mMasterBusL.size()) < numFrames) {
        mMasterBusL.resize(numFrames);
        mMasterBusR.resize(numFrames);
    }

    for (int i = 0; i < numFrames; ++i) {
        mMasterBusL[i] = out[i * 2];
        mMasterBusR[i] = out[i * 2 + 1];
    }

    processEffects(mMasterBusL.data(), mMasterBusR.data(), numFrames, mMasterInserts);

    for (int i = 0; i < numFrames; ++i) {
        out[i * 2] = mMasterBusL[i];
        out[i * 2 + 1] = mMasterBusR[i];
    }

    // Preview audition should bypass channel routing, inserts, and the master chain.
    for (int i = 0; i < numFrames; ++i) {
        out[i * 2] += previewDirectL[i];
        out[i * 2 + 1] += previewDirectR[i];
    }

    // ── Master safety limiter ───────────────────────────────────────────────
    // Always-on (toggleable) lookahead peak limiter. Sits AFTER the master
    // inserts and AFTER preview-direct injection so nothing can clip the DAC.
    // Soft knee at -3 dB, brick wall at -0.3 dBFS, 50 ms release.
    if (mMasterLimiterEnabled.load()) {
        constexpr float kCeiling = 0.9661f;            // -0.3 dBFS
        constexpr float kKneeStart = kCeiling * 0.7079f; // -3 dB below ceiling
        const float peakRelK = std::exp(-1.0f /
            (0.001f * static_cast<float>(sampleRate)));  // 1 ms peak decay
        const float gainRelK = 1.0f - std::exp(-1.0f /
            (0.050f * static_cast<float>(sampleRate))); // 50 ms gain release
        for (int i = 0; i < numFrames; ++i) {
            const float inL = out[i * 2];
            const float inR = out[i * 2 + 1];
            const float peakIn = std::max(std::fabs(inL), std::fabs(inR));

            // Peak envelope: instant attack, slow release.
            mLimPeakEnv = std::max(peakIn, mLimPeakEnv * peakRelK);

            // Soft-knee target gain.
            float targetGain;
            if (mLimPeakEnv <= kKneeStart) {
                targetGain = 1.0f;
            } else if (mLimPeakEnv >= kCeiling) {
                targetGain = kCeiling / mLimPeakEnv;
            } else {
                const float t = (mLimPeakEnv - kKneeStart) / (kCeiling - kKneeStart);
                const float fullGain = kCeiling / mLimPeakEnv;
                targetGain = 1.0f + (fullGain - 1.0f) * t * t;
            }

            // Fast duck (lookahead absorbs the ramp), slow release.
            if (targetGain < mLimGainEnv) {
                mLimGainEnv = targetGain;
            } else {
                mLimGainEnv += (targetGain - mLimGainEnv) * gainRelK;
            }

            // Write input into ring, output the delayed sample with current gain.
            mLimRingL[mLimWriteIdx] = inL;
            mLimRingR[mLimWriteIdx] = inR;
            mLimWriteIdx = (mLimWriteIdx + 1) % kMasterLimiterLookahead;
            out[i * 2]     = mLimRingL[mLimWriteIdx] * mLimGainEnv;
            out[i * 2 + 1] = mLimRingR[mLimWriteIdx] * mLimGainEnv;
        }
    }

    // Meter peaks reflect the FINAL post-limiter output the user actually hears.
    for (int i = 0; i < numFrames; ++i) {
        callbackMasterPeakL = std::max(callbackMasterPeakL, std::fabs(out[i * 2]));
        callbackMasterPeakR = std::max(callbackMasterPeakR, std::fabs(out[i * 2 + 1]));
    }

    {
        constexpr float kMeterRelease = 0.86f;
        std::lock_guard<std::mutex> meterLock(mMeterMutex);
        for (int track = 0; track < kMaxVoices; ++track) {
            mTrackMeterPeakL[track] = std::max(callbackTrackPeakL[track], mTrackMeterPeakL[track] * kMeterRelease);
            mTrackMeterPeakR[track] = std::max(callbackTrackPeakR[track], mTrackMeterPeakR[track] * kMeterRelease);
        }
        mMasterMeterPeakL = std::max(callbackMasterPeakL, mMasterMeterPeakL * kMeterRelease);
        mMasterMeterPeakR = std::max(callbackMasterPeakR, mMasterMeterPeakR * kMeterRelease);
    }

    // ── Export tap: copy final stereo output to export buffer ─────────────────
    if (mExportTapActive.load()) {
        std::lock_guard<std::mutex> exportLock(mExportMutex);
        if (mExportTapActive.load()) { // re-check under lock
            const int totalSamples = static_cast<int>(mExportBuffer.size());
            if (totalSamples < kMaxExportFrames * 2) {
                mExportBuffer.insert(
                    mExportBuffer.end(),
                    out,
                    out + numFrames * 2);
            }
        }
    }

    return oboe::DataCallbackResult::Continue;
}

// ---------------------------------------------------------------------------
// Persistent input stream management
// ---------------------------------------------------------------------------

void AudioEngine::openRecordingStream() {
    // Close any stale stream first.
    if (mRecordingStream) {
        mIsRecording.store(false);
        mRecordingStream->stop();
        mRecordingStream.reset();
        mRecordingCallback.reset();
    }

    mRecordingCallback = std::make_unique<RecordingCallback>(*this);

    oboe::AudioStreamBuilder builder;
    builder.setDirection(oboe::Direction::Input);
    builder.setPerformanceMode(oboe::PerformanceMode::LowLatency);
    builder.setSharingMode(oboe::SharingMode::Shared);
    builder.setFormat(oboe::AudioFormat::Float);
    builder.setChannelCount(1);
    builder.setDataCallback(mRecordingCallback.get());

    oboe::Result result = builder.openManagedStream(mRecordingStream);
    if (result != oboe::Result::OK) {
        LOGE("openRecordingStream: failed to open: %s", oboe::convertToText(result));
        mRecordingCallback.reset();
        return;
    }

    result = mRecordingStream->start();
    if (result != oboe::Result::OK) {
        LOGE("openRecordingStream: failed to start: %s", oboe::convertToText(result));
        mRecordingStream.reset();
        mRecordingCallback.reset();
        return;
    }

    // mIsRecording stays false — callbacks drain silently until RECORD pressed.
    LOGI("openRecordingStream: stream running silently at %d Hz",
         (int)mRecordingStream->getSampleRate());
}

void AudioEngine::closeRecordingStream() {
    mIsRecording.store(false);
    if (mRecordingStream) {
        mRecordingStream->stop();
        mRecordingStream.reset();
    }
    mRecordingCallback.reset();
    LOGI("closeRecordingStream: input stream closed");
}

// ---------------------------------------------------------------------------
// Per-take accumulation control
// ---------------------------------------------------------------------------

void AudioEngine::startRecording() {
    // Clear buffer for the new take. Stream is already running.
    {
        std::lock_guard<std::mutex> lock(mRecordingMutex);
        mRecordingBuffer.clear();
        // Stream has been warm for a while — no per-take warmup needed.
        mRecordingWarmupFrames = kWarmupFrames;
    }

    if (!mRecordingStream) {
        // Fallback: stream not open yet (e.g. called without openRecordingStream).
        LOGW("startRecording: stream not open, opening now (may cause transient)");
        openRecordingStream();
        // Reset warmup so we skip startup noise on this cold open.
        std::lock_guard<std::mutex> lock(mRecordingMutex);
        mRecordingWarmupFrames = 0;
    }

    mIsRecording.store(true);
    LOGI("startRecording: accumulation started");
}

oboe::DataCallbackResult AudioEngine::onRecordingAudioReady(
    oboe::AudioStream* stream,
        void*              audioData,
        int32_t            numFrames) {

    // Stream identity check — stop stale callbacks from a previous stream.
    {
        std::lock_guard<std::mutex> lock(mRecordingMutex);
        if (!mRecordingStream || mRecordingStream.get() != stream) {
            return oboe::DataCallbackResult::Stop;
        }
    }

    // When idle (not accumulating), drain silently to keep the stream alive.
    if (!mIsRecording.load()) {
        return oboe::DataCallbackResult::Continue;
    }

    const float* samples = static_cast<const float*>(audioData);

    std::lock_guard<std::mutex> lock(mRecordingMutex);

    // Re-check after lock in case stopRecording() raced.
    if (!mIsRecording.load()) {
        return oboe::DataCallbackResult::Continue;
    }

    // Per-take warmup: skip frames if the stream was cold-opened inside
    // startRecording() (the fallback path). Normally kWarmupFrames is
    // pre-satisfied so this loop body never executes.
    if (mRecordingWarmupFrames < kWarmupFrames) {
        const int32_t skip = std::min<int32_t>(numFrames, kWarmupFrames - mRecordingWarmupFrames);
        mRecordingWarmupFrames += skip;
        samples += skip;
        numFrames -= skip;
        if (numFrames <= 0) return oboe::DataCallbackResult::Continue;
    }

    for (int32_t i = 0; i < numFrames; ++i) {
        if ((int)mRecordingBuffer.size() >= kMaxRecordingFrames) {
            mIsRecording.store(false);
            LOGI("Recording buffer full");
            // Keep stream running so the next take can start without reopening.
            return oboe::DataCallbackResult::Continue;
        }
        mRecordingBuffer.push_back(samples[i]);
    }
    return oboe::DataCallbackResult::Continue;
}

std::vector<float> AudioEngine::stopRecording(int& outSampleRate) {
    // Stop accumulating. Stream stays open and drains silently.
    mIsRecording.store(false);

    std::lock_guard<std::mutex> lock(mRecordingMutex);

    if (mRecordingStream) {
        outSampleRate = (int)mRecordingStream->getSampleRate();
    } else {
        outSampleRate = 44100;
    }

    LOGI("Recording stopped: %zu frames at %d Hz",
         mRecordingBuffer.size(), outSampleRate);

    std::vector<float> result = std::move(mRecordingBuffer);
    return result;
}

// ---------------------------------------------------------------------------
// Export tap — capture stereo master output during song playback
// ---------------------------------------------------------------------------

void AudioEngine::startExportTap() {
    std::lock_guard<std::mutex> lock(mExportMutex);
    mExportBuffer.clear();
    mExportTapActive.store(true);
    LOGI("startExportTap: export capture started");
}

std::vector<float> AudioEngine::stopExportTap(int& outSampleRate) {
    mExportTapActive.store(false);

    std::lock_guard<std::mutex> lock(mExportMutex);

    outSampleRate = static_cast<int>(mCachedSampleRate);
    LOGI("stopExportTap: %zu interleaved frames captured at %d Hz",
         mExportBuffer.size() / 2, outSampleRate);

    std::vector<float> result = std::move(mExportBuffer);
    return result;
}

void AudioEngine::setSendRouting(const std::vector<int>& routing) {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    for (int i = 0; i < kMaxVoices && i < static_cast<int>(routing.size()); ++i) {
        mTrackSendChannel[i] = std::clamp(routing[i], 0, kMaxVoices);
    }
}

std::array<float, kMaxVoices * 2 + 2> AudioEngine::getMeterValues() const {
    std::array<float, kMaxVoices * 2 + 2> values{};
    std::lock_guard<std::mutex> meterLock(mMeterMutex);
    for (int track = 0; track < kMaxVoices; ++track) {
        values[track] = mTrackMeterPeakL[track];
        values[kMaxVoices + track] = mTrackMeterPeakR[track];
    }
    values[kMaxVoices * 2] = mMasterMeterPeakL;
    values[kMaxVoices * 2 + 1] = mMasterMeterPeakR;
    return values;
}
