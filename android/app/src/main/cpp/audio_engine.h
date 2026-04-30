#pragma once

#include <oboe/Oboe.h>
#include <vector>
#include <atomic>
#include <cmath>

/**
 * AudioEngine — wraps an Oboe output stream.
 *
 * Current implementation outputs silence; all the plumbing for
 * real synthesis (sample playback, FM, etc.) plugs in via
 * onAudioReady() once the instrument layer is added.
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
    // rowData: one MIDI note per track (-1=empty, -2=OFF, 0-127=note)
    void setRowData(const std::vector<int>& data);

    // oboe::AudioStreamDataCallback
    oboe::DataCallbackResult onAudioReady(
        oboe::AudioStream* stream,
        void*              audioData,
        int32_t            numFrames) override;

private:
    oboe::ManagedStream mStream;
    std::atomic<double> mBpm{120.0};
    std::vector<int>    mRowData;

    // simple sine for testing — remove once real synthesis is in place
    double mPhase = 0.0;
    bool   mSilent = true;
};
