#include "audio_engine.h"
#include <android/log.h>
#include <algorithm>

#define LOG_TAG "TrackerAudio"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

AudioEngine::AudioEngine() = default;

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
        mStream->requestStart();
        mSilent = false;
        LOGI("Stream started");
    }
}

void AudioEngine::stop() {
    if (mStream) {
        mStream->requestStop();
        mSilent = true;
        LOGI("Stream stopped");
    }
}

void AudioEngine::close() {
    if (mStream) {
        mStream->close();
        LOGI("Stream closed");
    }
}

void AudioEngine::setTempo(double bpm) {
    mBpm.store(bpm);
}

void AudioEngine::setRowData(const std::vector<int>& data) {
    mRowData = data;
    // Determine whether anything is playing on this row
    mSilent = true;
    for (int v : mRowData) {
        if (v >= 0) { mSilent = false; break; }
    }
}

oboe::DataCallbackResult AudioEngine::onAudioReady(
        oboe::AudioStream* stream,
        void*              audioData,
        int32_t            numFrames) {

    auto* out = static_cast<float*>(audioData);

    if (mSilent) {
        // Output silence
        std::fill(out, out + numFrames * 2, 0.0f);
        return oboe::DataCallbackResult::Continue;
    }

    // Placeholder: 440 Hz sine wave — replaced by real synthesis later.
    const double sampleRate = stream->getSampleRate();
    const double freq       = 440.0;
    const double twoPi      = 2.0 * M_PI;
    const double phaseInc   = twoPi * freq / sampleRate;

    for (int i = 0; i < numFrames; ++i) {
        float sample = static_cast<float>(std::sin(mPhase)) * 0.25f;
        out[i * 2]     = sample; // L
        out[i * 2 + 1] = sample; // R
        mPhase += phaseInc;
        if (mPhase >= twoPi) mPhase -= twoPi;
    }

    return oboe::DataCallbackResult::Continue;
}
