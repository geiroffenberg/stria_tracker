#include "audio_engine.h"
#include <android/log.h>
#include <algorithm>

namespace {
float byteToNorm(int v) {
    return static_cast<float>(std::clamp(v, 0, 255)) / 255.0f;
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
} // namespace

#define LOG_TAG "TrackerAudio"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

AudioEngine::AudioEngine() {
    for (auto& v : mVoices) v = Voice{};
}

AudioEngine::~AudioEngine() {
    close();
}

bool AudioEngine::open() {
    oboe::AudioStreamBuilder builder;
    builder.setDirection(oboe::Direction::Output);
    builder.setPerformanceMode(oboe::PerformanceMode::LowLatency);
    builder.setSharingMode(oboe::SharingMode::Exclusive);
    builder.setFormat(oboe::AudioFormat::Float);
    builder.setChannelCount(oboe::ChannelCount::Stereo);
    builder.setDataCallback(this);

    oboe::Result result = builder.openManagedStream(mStream);
    if (result != oboe::Result::OK) {
        LOGE("Failed to open stream: %s", oboe::convertToText(result));
        return false;
    }
    LOGI("Oboe stream opened: sampleRate=%d", mStream->getSampleRate());
    return true;
}

void AudioEngine::start() {
    if (mStream) {
        if (!mStarted) {
            mStream->requestStart();
            mStarted = true;
            LOGI("Stream started");
        }
    }
}

void AudioEngine::stop() {
    if (mStream) {
        {
            std::lock_guard<std::mutex> lock(mVoiceMutex);
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
            }
        }
        LOGI("Transport stopped (voices muted, stream kept running)");
    }
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

void AudioEngine::setTempo(double bpm) {
    mBpm.store(bpm);
}

void AudioEngine::triggerRow(const std::vector<int>& rowData) {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    int stride = 4;
    if (rowData.size() % 17 == 0) {
        stride = 17;
    } else if (rowData.size() % 12 == 0) {
        stride = 12;
    } else if (rowData.size() % 10 == 0) {
        stride = 10;
    } else if (rowData.size() % 9 == 0) {
        stride = 9;
    }
    const int trackCount = static_cast<int>(std::min(rowData.size() / stride, mVoices.size()));
    for (int i = 0; i < trackCount; ++i) {
        const int base = i * stride;
        const int n = rowData[base];
        const int vol = rowData[base + 1];
        const int pan = rowData[base + 2];
        const int wave = rowData[base + 3];

        const int cutoff = (stride >= 12) ? rowData[base + 4] : static_cast<int>(0.70f * 255.0f);
        const int resonance = (stride >= 12) ? rowData[base + 5] : static_cast<int>(0.20f * 255.0f);

        const int fatk = (stride >= 17) ? rowData[base + 6] : static_cast<int>(0.01f * 255.0f);
        const int fdec = (stride >= 17) ? rowData[base + 7] : static_cast<int>(0.25f * 255.0f);
        const int fsus = (stride >= 17) ? rowData[base + 8] : 0;
        const int frel = (stride >= 17) ? rowData[base + 9] : static_cast<int>(0.25f * 255.0f);
        const int famt = (stride >= 17) ? rowData[base + 10] : static_cast<int>(0.50f * 255.0f);

        const int atk = (stride >= 17)
            ? rowData[base + 11]
            : ((stride >= 12)
                ? rowData[base + 6]
                : ((stride >= 9) ? rowData[base + 4] : static_cast<int>(0.02f * 255.0f)));
        const int dec = (stride >= 17)
            ? rowData[base + 12]
            : ((stride >= 12)
                ? rowData[base + 7]
                : ((stride >= 9) ? rowData[base + 5] : static_cast<int>(0.30f * 255.0f)));
        const int sus = (stride >= 17)
            ? rowData[base + 13]
            : ((stride >= 12)
                ? rowData[base + 8]
                : ((stride >= 9) ? rowData[base + 6] : static_cast<int>(0.80f * 255.0f)));
        const int rel = (stride >= 17)
            ? rowData[base + 14]
            : ((stride >= 12)
                ? rowData[base + 9]
                : ((stride >= 9) ? rowData[base + 7] : static_cast<int>(0.25f * 255.0f)));
        const int glide = (stride >= 17)
            ? rowData[base + 15]
            : ((stride >= 12)
                ? rowData[base + 10]
                : ((stride >= 10) ? rowData[base + 8] : 0));
        const int instVol = (stride >= 17)
            ? rowData[base + 16]
            : ((stride >= 12)
                ? rowData[base + 11]
                : ((stride >= 10)
                    ? rowData[base + 9]
                    : ((stride >= 9) ? rowData[base + 8] : static_cast<int>(0.80f * 255.0f))));
        auto& v = mVoices[i];

        const int clampedWave = std::clamp(wave, 0, 5);
        const bool waveChanging = (clampedWave != v.waveform);

        v.attackSec = normToAttackSec(byteToNorm(atk));
        v.decaySec = normToDecaySec(byteToNorm(dec));
        v.sustainLevel = byteToNorm(sus);
        v.releaseSec = normToReleaseSec(byteToNorm(rel));
        v.glideSec = normToGlideSec(byteToNorm(glide));

        v.filterAttackSec = normToAttackSec(byteToNorm(fatk));
        v.filterDecaySec = normToDecaySec(byteToNorm(fdec));
        v.filterSustainLevel = byteToNorm(fsus);
        v.filterReleaseSec = normToReleaseSec(byteToNorm(frel));
        v.filterEnvAmt = byteToNorm(famt);

        v.cutoffNorm = byteToNorm(cutoff);
        v.resonanceNorm = byteToNorm(resonance);
        v.instrumentVolume = byteToNorm(instVol);

        if (vol >= 0) {
            const int clampedVol = std::clamp(vol, 0, 255);
            v.level = static_cast<float>(clampedVol) / 255.0f;
        }

        if (pan >= 0) {
            const int clampedPan = std::clamp(pan, 0, 255);
            v.panTarget = static_cast<float>(clampedPan) / 255.0f;
        }

        if (n >= 0) {
            // Note on: change pitch but keep phase to avoid discontinuity click
            v.midiNote   = n;
            v.targetFreq = static_cast<float>(midiToFreq(n));
            if (v.currentFreq <= 0.0f || v.glideSec <= 0.0f) {
                v.currentFreq = v.targetFreq;
            }
            // Reset filter integrator state on each note-on to avoid stale-energy bursts.
            v.filterLow = 0.0f;
            v.filterBand = 0.0f;
            v.noteHeld   = true;
            v.envStage   = EnvelopeStage::Attack;
            v.filterEnvStage = EnvelopeStage::Attack;
            v.gainTarget = 1.0f;
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

oboe::DataCallbackResult AudioEngine::onAudioReady(
        oboe::AudioStream* stream,
        void*              audioData,
        int32_t            numFrames) {

    auto* out = static_cast<float*>(audioData);
    std::fill(out, out + numFrames * 2, 0.0f);

    const double sampleRate = stream->getSampleRate();
    const double twoPi = 2.0 * M_PI;
    // One-pole gain smoother: ~5 ms time constant, eliminates clicks.
    const float smoothK = 1.0f - std::exp(-1.0f / (static_cast<float>(sampleRate) * 0.005f));
    const float panSmoothK = 1.0f - std::exp(-1.0f / (static_cast<float>(sampleRate) * 0.003f));

    std::lock_guard<std::mutex> lock(mVoiceMutex);

    for (auto& v : mVoices) {
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
        // Chamberlin SVF stays stable with conservative damping.
        const float damp = std::clamp(1.8f - (v.resonanceNorm * 1.4f), 0.25f, 1.8f);

        for (int i = 0; i < numFrames; ++i) {
            v.gain += smoothK * (v.gainTarget - v.gain);
            v.pan += panSmoothK * (v.panTarget - v.pan);
            if (v.glideSec > 0.0f) {
                v.currentFreq += glideK * (v.targetFreq - v.currentFreq);
            } else {
                v.currentFreq = v.targetFreq;
            }

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

            const double phaseInc = twoPi * std::max(1.0f, v.currentFreq) / sampleRate;
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

            const float dry = osc * v.gain * v.envLevel * v.level * v.instrumentVolume * 0.15f;

            const float cutoffNormDyn = std::clamp(v.cutoffNorm + (v.filterEnvLevel * v.filterEnvAmt),
                0.0f, 1.0f);
            // Keep cutoff inside the stable range for this SVF formulation.
            const float cutoffHz = std::clamp(normToCutoffHz(cutoffNormDyn), 20.0f,
                static_cast<float>(sampleRate) * 0.20f);
            const float f = std::clamp(2.0f * std::sin(static_cast<float>(M_PI) * cutoffHz /
                static_cast<float>(sampleRate)), 0.001f, 0.99f);

            // Chamberlin-style state variable low-pass filter.
            const float high = dry - v.filterLow - (damp * v.filterBand);
            v.filterBand += f * high;
            v.filterLow += f * v.filterBand;
            if (!std::isfinite(v.filterLow) || !std::isfinite(v.filterBand)) {
                v.filterLow = 0.0f;
                v.filterBand = 0.0f;
            }
            const float sample = v.filterLow;

            // Equal-power panning for a mono voice into stereo output.
            const float pan01 = std::clamp(v.pan, 0.0f, 1.0f);
            const float angle = pan01 * 1.57079632679f;
            const float leftGain = std::cos(angle);
            const float rightGain = std::sin(angle);

            out[i * 2]     += sample * leftGain;
            out[i * 2 + 1] += sample * rightGain;
            v.phase += phaseInc;
            if (v.phase >= twoPi) v.phase -= twoPi;
        }
    }

    return oboe::DataCallbackResult::Continue;
}
