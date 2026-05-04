#include "audio_engine.h"
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
                v.samplerMode       = false;
                v.sampleActive      = false;
                v.sampleSlot        = -1;
                v.samplePos         = 0.0;
                v.sampleStep        = 1.0;
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
        mSamplerSlots[safe].sampleRate = 44100;
        LOGI("Sampler: cleared slot %d", safe);
        return true;
    }

    SampleData loaded;
    if (!loadWavMono16OrFloat(path, loaded)) {
        LOGE("Sampler: load failed for slot %d path=%s", safe, path.c_str());
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(mVoiceMutex);
        mSamplerSlots[safe] = std::move(loaded);
    }
    LOGI("Sampler: loaded slot %d (%zu frames @ %d Hz) from %s",
         safe, mSamplerSlots[safe].mono.size(), mSamplerSlots[safe].sampleRate, path.c_str());
    return true;
}

void AudioEngine::triggerRow(const std::vector<int>& rowData) {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    // Reset sub-row event state for the new row so stale events from the
    // previous row cannot fire into this one.
    mSubRowSampleCounter = 0;
    mPendingRetrigs.clear();
    mPendingArp.clear();
    mPendingDelays.clear();
    mPendingKills.clear();
    // Current canonical stride is 25:
    // [note, vol, pan, wave, instrumentType, 20 params].
    // Fall back to legacy stride 24 / 23 / 18 / 4 packets.
    int stride = 4;
    if      (rowData.size() % 25 == 0) stride = 25;
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
        // instrumentType: 0=synth, 1=sampler.
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
        const int reverse = (stride == 25)    ? rowData[pBase + 19] : 0;
        auto& v = mVoices[i];

        // note encoding:
        //  0..127   = note-on
        //  -1       = hold
        //  -2       = note-off
        //  <= -1000 = pitch-only update, midi = -1000 - note
        const bool pitchOnly = (n <= -1000);
        const int pitchMidi = pitchOnly ? std::clamp(-1000 - n, 0, 127) : n;

        const bool isSampler = (instrumentType == 1);

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
        // lfoRate/lfoDepth/lfoTarget are only updated on note-on so that
        // FX like VIB persist across hold rows without being reset.
        if (n >= 0) {
            v.lfoRateNorm = byteToNorm(lfoRate);
            v.lfoDepth    = byteToNorm(lfoDepth);
            v.lfoTarget   = std::clamp(lfoTgt, 0, 2);
        }
        v.drive = byteToNorm(drive);

        if (vol >= 0) {
            const int clampedVol = std::clamp(vol, 0, 255);
            v.level = static_cast<float>(clampedVol) / 255.0f;
        }

        if (pan >= 0) {
            const int clampedPan = std::clamp(pan, 0, 255);
            v.panTarget = static_cast<float>(clampedPan) / 255.0f;
        }

        v.samplerMode = isSampler;
        if (isSampler) {
            v.sampleSlot = std::clamp(wave, 0, static_cast<int>(mSamplerSlots.size()) - 1);
            v.loopMode   = std::clamp(drive, 0, 2);
            v.sampleReverse = (reverse != 0);
            v.sampleGain = 1.0f;

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
                    v.midiNote = n;
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
                v.sampleActive = false;
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
            // Reset filter integrator state on each note-on to avoid stale-energy bursts.
            v.filterLow = 0.0f;
            v.filterBand = 0.0f;
            // Reset envelope levels so the attack ramp always starts from
            // silence — this makes every retrigger (RET) clearly audible.
            v.envLevel       = 0.0f;
            v.filterEnvLevel = 0.0f;
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

void AudioEngine::killVoices(const std::vector<int>& killMask) {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    const int n = static_cast<int>(std::min(killMask.size(), mVoices.size()));
    for (int i = 0; i < n; ++i) {
        if (killMask[i] != 1) continue;
        Voice& v = mVoices[i];
        // Trigger note-off: move to release stage without clearing the voice.
        v.noteHeld = false;
        v.envStage = EnvelopeStage::Release;
        if (v.samplerMode) v.sampleActive = false;
    }
}

void AudioEngine::queueRetrigs(const std::vector<int>& data) {
    // data format: groups of 4 ints — [sampleOffset, trackIdx, note, volume].
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    for (size_t i = 0; i + 3 < data.size(); i += 4) {
        const int32_t target = static_cast<int32_t>(data[i]) + mSubRowSampleCounter;
        mPendingRetrigs.push_back({target, data[i + 1], data[i + 2], data[i + 3]});
    }
}

void AudioEngine::queueArp(const std::vector<int>& data) {
    // data format: groups of 3 ints — [sampleOffset, trackIdx, note].
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    for (size_t i = 0; i + 2 < data.size(); i += 3) {
        const int32_t target = static_cast<int32_t>(data[i]) + mSubRowSampleCounter;
        mPendingArp.push_back({target, data[i + 1], data[i + 2]});
    }
}

void AudioEngine::queueDelays(const std::vector<int>& data) {
    // data format: groups of 4 ints — [delayPct, trackIdx, note, volume].
    // Convert delay percentage to sample offset using mLineSamplesPerRow.
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    for (size_t i = 0; i + 3 < data.size(); i += 4) {
        const int delayPct = std::clamp(data[i], 0, 99);
        const double norm = (delayPct >= 99) ? 1.0 : (delayPct / 100.0);
        const int32_t sampleOffset = std::max(0, static_cast<int32_t>(mLineSamplesPerRow * norm));
        const int32_t target = sampleOffset + mSubRowSampleCounter;
        mPendingDelays.push_back({target, data[i + 1], data[i + 2], data[i + 3]});
    }
}

void AudioEngine::queueKills(const std::vector<int>& data) {
    // data format: groups of 2 ints — [killPct, trackIdx].
    // Convert kill percentage to sample offset using mLineSamplesPerRow.
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    for (size_t i = 0; i + 1 < data.size(); i += 2) {
        const int killPct = std::clamp(data[i], 0, 99);
        const double norm = (killPct >= 99) ? 1.0 : (killPct / 100.0);
        const int32_t sampleOffset = std::max(0, static_cast<int32_t>(mLineSamplesPerRow * norm));
        const int32_t target = sampleOffset + mSubRowSampleCounter;
        mPendingKills.push_back({target, data[i + 1]});
    }
}

void AudioEngine::queueSliceCommands(const std::vector<int>& data) {
    // data format: groups of 4 ints — [playMode, trackIdx, startNormScaled, endNormScaled].
    // startNormScaled and endNormScaled are normalized positions (0-10000 = 0.0-1.0).
    // Slice commands fire immediately at row start (sampleTarget = 0).
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    for (size_t i = 0; i + 3 < data.size(); i += 4) {
        const int playMode = std::clamp(data[i], 0, 1);
        const int trackIdx = data[i + 1];
        const int startNormScaled = std::clamp(data[i + 2], 0, 10000);
        const int endNormScaled = std::clamp(data[i + 3], 0, 10000);
        mPendingSliceCommands.push_back({0, trackIdx, startNormScaled, endNormScaled});
    }
}

void AudioEngine::queueMixerCommands(const std::vector<int>& data) {
    // data format: groups of 4 ints — [channel, controller, value, unused].
    // channel: 0=master, 1-15=mixer channels
    // controller: 1-4 (pan, mute, solo, volume), 5-9 reserved
    // value: 0-99
    // Mixer commands fire immediately at row start (sampleTarget = 0).
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    for (size_t i = 0; i + 3 < data.size(); i += 4) {
        const int channel = std::clamp(data[i], 0, 15);
        const int controller = std::clamp(data[i + 1], 1, 9);
        const int value = std::clamp(data[i + 2], 0, 99);
        mPendingMixerCommands.push_back({0, channel, controller, value});
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

    // Advance the per-row sample counter and fire due sub-row events.
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
            } else {
                v.midiNote = ev.note;
                const float detuneSemitones = (v.detuneNorm - 0.5f) * 24.0f;
                v.targetFreq = static_cast<float>(midiToFreq(ev.note)) *
                    std::pow(2.0f, detuneSemitones / 12.0f);
                if (v.currentFreq <= 0.0f || v.glideSec <= 0.0f) {
                    v.currentFreq = v.targetFreq;
                }
                v.filterLow      = 0.0f;
                v.filterBand     = 0.0f;
                v.envLevel       = 0.0f;
                v.filterEnvLevel = 0.0f;
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
            } else {
                // Synth retrigger: restart amp/filter envelopes from zero.
                v.midiNote = ev.note;
                const float detuneSemitones = (v.detuneNorm - 0.5f) * 24.0f;
                v.targetFreq = static_cast<float>(midiToFreq(ev.note)) *
                    std::pow(2.0f, detuneSemitones / 12.0f);
                if (v.currentFreq <= 0.0f || v.glideSec <= 0.0f) {
                    v.currentFreq = v.targetFreq;
                }
                v.filterLow      = 0.0f;
                v.filterBand     = 0.0f;
                v.envLevel       = 0.0f;
                v.filterEnvLevel = 0.0f;
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
            // ev.channel: 0=master, 1-15=channels
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
            }
            // TODO: Channel 1-15 mute/volume/pan/solo states
        }
        // Clear mixer commands after processing.
        mPendingMixerCommands.clear();
    }

    for (auto& v : mVoices) {
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
            if (v.samplePos < regionStart || v.samplePos >= regionEnd) {
                v.samplePos = regionStart;
            }

            const double ratio =
                (static_cast<double>(s.sampleRate) / sampleRate) * v.sampleStep;

            for (int i = 0; i < numFrames; ++i) {
                int idx = static_cast<int>(v.samplePos);
                if (idx < startFrame || idx >= endFrame) {
                    if (v.loopMode == 1 && regionLen > 1.0) {
                        // Forward loop: wrap back to start
                        while (v.samplePos >= regionEnd)   v.samplePos -= regionLen;
                        while (v.samplePos < regionStart)  v.samplePos += regionLen;
                        idx = static_cast<int>(v.samplePos);
                    } else if (v.loopMode == 2 && regionLen > 1.0) {
                        // Ping-pong: bounce direction
                        if (v.samplePos >= regionEnd) {
                            v.samplePos = regionEnd - (v.samplePos - regionEnd) - 1.0;
                            v.samplePingDir = true;
                        } else if (v.samplePos < regionStart) {
                            v.samplePos = regionStart + (regionStart - v.samplePos);
                            v.samplePingDir = false;
                        }
                        idx = std::clamp(static_cast<int>(v.samplePos), startFrame, endFrame - 1);
                    } else {
                        v.sampleActive = false;
                        v.midiNote = -1;
                        break;
                    }
                }

                // Attack / release gain envelope
                float envGain = 1.0f;
                const float atkFrames = static_cast<float>(v.attackSec  * sampleRate);
                const float relFrames = static_cast<float>(v.releaseSec * sampleRate);
                const float elapsed = static_cast<float>(v.sampleElapsedFrames);
                if (atkFrames > 0.0f && elapsed < atkFrames) {
                    envGain = elapsed / atkFrames;
                }
                // Release fade: only for non-looping (looping needs note-off, future work)
                if (v.loopMode == 0 && relFrames > 0.0f) {
                    const double framesLeft = regionEnd - v.samplePos;
                    if (framesLeft < static_cast<double>(relFrames)) {
                        envGain *= static_cast<float>(framesLeft) / relFrames;
                    }
                }

                const float dry = s.mono[idx] * v.level * v.instrumentVolume * v.sampleGain * envGain;

                const float pan01 = std::clamp(v.pan, 0.0f, 1.0f);
                const float angle = pan01 * 1.57079632679f;
                const float leftGain  = std::cos(angle);
                const float rightGain = std::sin(angle);

                out[i * 2]     += dry * leftGain;
                out[i * 2 + 1] += dry * rightGain;

                v.samplePos += v.samplePingDir ? -ratio : ratio;
                v.sampleElapsedFrames += 1.0;
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

            const double phaseInc = twoPi * std::max(1.0f, voiceFreq) / sampleRate;
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

            float dry = osc * v.gain * v.envLevel * v.level * v.instrumentVolume * 0.15f * lfoAmpMod;

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

            out[i * 2]     += sample * leftGain;
            out[i * 2 + 1] += sample * rightGain;
            v.phase += phaseInc;
            if (v.phase >= twoPi) v.phase -= twoPi;
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

    // ── Record output if enabled ──────────────────────────────────────────────
    // (Recording is now done on a separate input stream, not on playback output)

    return oboe::DataCallbackResult::Continue;
}

void AudioEngine::startRecording() {
    // Clear previous recording
    {
        std::lock_guard<std::mutex> lock(mRecordingMutex);
        mRecordingBuffer.clear();
        mRecordingWarmupFrames = 0;
    }
    mIsRecording.store(true);

    // Build a callback-driven input stream (no polling thread needed)
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
        LOGE("Failed to open recording stream: %s", oboe::convertToText(result));
        mIsRecording.store(false);
        mRecordingCallback.reset();
        return;
    }

    result = mRecordingStream->start();
    if (result != oboe::Result::OK) {
        LOGE("Failed to start recording stream: %s", oboe::convertToText(result));
        mRecordingStream.reset();
        mIsRecording.store(false);
        mRecordingCallback.reset();
        return;
    }

    LOGI("Recording started (callback mode): %d Hz, framesPerBurst=%d",
         (int)mRecordingStream->getSampleRate(),
         (int)mRecordingStream->getFramesPerBurst());
}

oboe::DataCallbackResult AudioEngine::onRecordingAudioReady(
        oboe::AudioStream* /*stream*/,
        void*              audioData,
        int32_t            numFrames) {

    if (!mIsRecording.load()) {
        return oboe::DataCallbackResult::Stop;
    }

    const float* samples = static_cast<const float*>(audioData);

    std::lock_guard<std::mutex> lock(mRecordingMutex);

    // Skip the first kWarmupFrames to discard hardware start-up noise
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
            return oboe::DataCallbackResult::Stop;
        }
        mRecordingBuffer.push_back(samples[i]);
    }
    return oboe::DataCallbackResult::Continue;
}

std::vector<float> AudioEngine::stopRecording(int& outSampleRate) {
    mIsRecording.store(false);

    if (mRecordingStream) {
        outSampleRate = (int)mRecordingStream->getSampleRate();
        mRecordingStream->stop();
        mRecordingStream.reset();
    } else {
        outSampleRate = 44100;
    }
    mRecordingCallback.reset();

    std::lock_guard<std::mutex> lock(mRecordingMutex);
    LOGI("Recording stopped: %zu frames at %d Hz",
         mRecordingBuffer.size(), outSampleRate);

    std::vector<float> result = std::move(mRecordingBuffer);
    return result;
}
