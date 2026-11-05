"""Run with python3 test/native_stem_export_test.py (requires clang++).

Checks voice recovery and stem export using the complete production engine
offline; only Android logging and the audio-device API are stubbed.
No audio device or Android runtime is required.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
cpp = root / "android/app/src/main/cpp"

oboe = r"""
#pragma once
#include <memory>
#include <cstdint>
namespace oboe {
enum class Result { OK, ErrorDisconnected };
enum class DataCallbackResult { Continue, Stop };
enum class Direction { Output, Input };
enum class PerformanceMode { LowLatency };
enum class SharingMode { Shared };
enum class AudioFormat { Float };
enum class ChannelCount { Stereo };
enum class Usage { Media };
inline const char* convertToText(Result) { return "test"; }
class AudioStream;
class AudioStreamDataCallback {
public:
    virtual ~AudioStreamDataCallback() = default;
    virtual DataCallbackResult onAudioReady(AudioStream*,void*,int32_t) = 0;
};
class AudioStreamErrorCallback {
public:
    virtual ~AudioStreamErrorCallback() = default;
    virtual void onErrorAfterClose(AudioStream*,Result) = 0;
};
struct SizeResult {
    explicit operator bool() const { return true; }
    int value() const { return 192; }
    Result error() const { return Result::OK; }
};
class AudioStream {
public:
    int getSampleRate() const { return 48000; }
    int getFramesPerBurst() const { return 192; }
    int getBufferCapacityInFrames() const { return 4096; }
    SizeResult setBufferSizeInFrames(int) { return {}; }
    Result start() { return Result::OK; }
    Result stop() { return Result::OK; }
    Result requestStart() { return Result::OK; }
    Result requestStop() { return Result::OK; }
    Result close() { return Result::OK; }
};
using ManagedStream = std::shared_ptr<AudioStream>;
class AudioStreamBuilder {
public:
    void setDirection(Direction) {}
    void setPerformanceMode(PerformanceMode) {}
    void setSharingMode(SharingMode) {}
    void setFormat(AudioFormat) {}
    void setChannelCount(ChannelCount) {}
    void setChannelCount(int) {}
    void setUsage(Usage) {}
    void setDataCallback(AudioStreamDataCallback*) {}
    void setErrorCallback(AudioStreamErrorCallback*) {}
    Result openManagedStream(ManagedStream& stream) {
        stream = std::make_shared<AudioStream>(); return Result::OK;
    }
};
}
"""
log = r"""
#pragma once
#define ANDROID_LOG_INFO 1
#define ANDROID_LOG_WARN 2
#define ANDROID_LOG_ERROR 3
inline int __android_log_print(int, const char*, const char*, ...) { return 0; }
"""

tests = r"""
#include "audio_engine.h"
#include "float_wav_writer.h"
#include <algorithm>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
void check(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
std::vector<float> read(const std::string& path) {
    std::ifstream file(path, std::ios::binary);
    std::vector<char> bytes((std::istreambuf_iterator<char>(file)), {});
    check(bytes.size() >= 56, "WAV contains a complete header");
    check(std::memcmp(bytes.data(), "RIFF", 4)==0, "RIFF tag");
    check(bytes[20]==3 && bytes[22]==2 && bytes[34]==32, "stereo float32 WAV");
    check(std::memcmp(bytes.data()+36, "fact", 4)==0, "float WAV sample-count chunk");
    uint32_t dataSize;
    std::memcpy(&dataSize, bytes.data()+52, 4);
    check(dataSize+56==bytes.size(), "finalized WAV length");
    uint32_t riffSize, frameCount, sampleRate;
    std::memcpy(&riffSize, bytes.data()+4, 4);
    std::memcpy(&frameCount, bytes.data()+44, 4);
    std::memcpy(&sampleRate, bytes.data()+24, 4);
    check(riffSize+8==bytes.size() && frameCount==dataSize/8, "RIFF and fact chunk lengths");
    check(sampleRate==48000 && bytes[32]==8, "sample rate and frame alignment");
    std::vector<float> data(dataSize/4);
    std::memcpy(data.data(), bytes.data()+56, dataSize);
    return data;
}
std::unique_ptr<AudioEngine> make(bool alteredMaster, bool flags, bool sidechain=true) {
    auto engine = std::make_unique<AudioEngine>();
    check(engine->open(), "test stream opened");
    engine->setMasterLimiterEnabled(alteredMaster);
    engine->setMasterVolumeLinear(alteredMaster ? .01f : 1);
    if (alteredMaster) {
        engine->setMasterInsertEffect(0,3,1);
        engine->setMasterDistortionParams(0,1,.1,1);
    }
    std::vector<int> routing(16);
    routing[0]=3; routing[1]=3;
    engine->setSendRouting(routing);
    engine->setTrackInsertEffect(2,0,7,1);
    engine->setTrackInsertMix(2,0,0,1);
    engine->setTrackEqParams(2,0,.2,.3,-.1,.2,.3,.1,.4);
    engine->setTrackInsertEffect(13,0,1,.3);
    engine->setTrackInsertMix(13,0,0,.3);
    engine->setTrackDelayParams(13,0,700,.4,0,false);
    if (sidechain) {
        engine->setTrackInsertEffect(3,0,10,1);
        engine->setTrackInsertMix(3,0,0,1);
        engine->setTrackSidechainParams(3,0,0,.1,.9,.01,.1);
    }
    if (flags) {
        engine->queueMixerCommands({0,1,1,0, 1,2,1,0, 2,3,1,0, 3,2,1,0, 4,2,1,0});
        float silent[192*2]{};
        oboe::AudioStream stream;
        engine->onAudioReady(&stream,silent,192);
    }
    QueuedPlaybackRow row;
    row.lineSamples=4800;
    row.rowData.resize(16*4);
    for (int t=0;t<16;++t) {
        row.rowData[t*4]=-1;row.rowData[t*4+1]=-1;row.rowData[t*4+2]=128;
    }
    row.rowData[0]=48;row.rowData[1]=200;
    row.rowData[4]=55;row.rowData[5]=180;
    row.rowData[12]=72;row.rowData[13]=200;
    row.sendRoutingCommandData={3,14,50};
    if (flags) row.mixerCommandData={1,2,1,0, 3,2,1,0, 4,2,1,0};
    engine->enqueuePlaybackRow(row);
    return engine;
}
double energy(const std::vector<float>& audio) {
    double sum=0;
    for(float sample:audio) {
        check(std::isfinite(sample), "finite stem audio");
        sum+=sample*sample;
    }
    return sum;
}
std::vector<int> voiceRow(int note, int type=0) {
    std::vector<int> data(16*49, 0);
    for (int t=0;t<16;++t) {
        const int b=t*49, p=b+5;
        data[b]=t==0 ? note : -1;
        data[b+1]=255;data[b+2]=128;
        data[b+4]=t==0 ? type : 0;
        data[p]=128;data[p+1]=255;data[p+6]=255;data[p+8]=128;
        data[p+11]=255;data[p+14]=255;data[p+20]=255;
        data[p+23]=data[p+27]=128;
        data[p+31]=data[p+32]=data[p+33]=2;
        data[p+38]=255;
    }
    return data;
}
double renderVoice(AudioEngine& engine, int blocks=100) {
    oboe::AudioStream stream;
    std::vector<float> buffer(192*2);
    double sum=0;
    for (int b=0;b<blocks;++b) {
        engine.onAudioReady(&stream,buffer.data(),192);
        sum+=energy(buffer);
    }
    return sum;
}
std::unique_ptr<AudioEngine> voiceEngine() {
    auto engine=std::make_unique<AudioEngine>();
    check(engine->open(), "voice test stream opened");
    engine->setMasterLimiterEnabled(false);
    return engine;
}
void checkVoiceRecovery() {
    auto engine=voiceEngine();
    engine->triggerRow(voiceRow(60));
    check(renderVoice(*engine)>1, "fresh synth sounds");
    engine->triggerRow(voiceRow(64));
    check(engine->getVoiceEnvelopeStage(0)==4, "audible retrigger keeps anti-click release");
    engine->triggerRow(voiceRow(67));
    check(renderVoice(*engine)>1 && engine->isVoicePlaying(0), "audible synth retriggers");
    auto changedWave=voiceRow(60);
    changedWave[3]=2;
    engine->triggerRow(changedWave);
    check(renderVoice(*engine)>1, "waveform change with retrigger remains audible");
    engine->triggerRow(voiceRow(-2));
    renderVoice(*engine);
    check(!engine->isVoicePlaying(0), "synth release completes");
    engine->triggerRow(voiceRow(67));
    check(renderVoice(*engine)>1, "synth restarts after release");

    std::vector<int> mask(16,0);mask[0]=1;
    engine=voiceEngine();
    engine->killVoices(mask);
    engine->triggerRow(voiceRow(60));
    check(renderVoice(*engine)>1, "idle kill cannot deadlock synth");

    engine=voiceEngine();
    engine->triggerRow(voiceRow(-2,1));
    engine->killVoices(mask);
    engine->triggerRow(voiceRow(60));
    check(renderVoice(*engine)>1, "sampler preview cleanup cannot deadlock synth");

    engine=voiceEngine();
    engine->triggerRow(voiceRow(60,3));
    check(renderVoice(*engine,1250)>.01, "drum control sounds");
    check(renderVoice(*engine)==0, "drum has finished");
    engine->triggerRow(voiceRow(60));
    check(renderVoice(*engine)>1, "finished drum cannot deadlock synth");

    engine=voiceEngine();
    engine->triggerRow(voiceRow(60,4));
    check(renderVoice(*engine)==0, "empty instrument is silent");
    engine->triggerRow(voiceRow(60));
    check(renderVoice(*engine)>1, "synth starts after empty slot");
    engine->triggerRow(voiceRow(64,4));
    check(renderVoice(*engine)==0, "empty slot cannot keep previous synth sounding");
    engine->triggerRow(voiceRow(67));
    check(renderVoice(*engine)>1, "synth recovers after switching through empty slot");
    engine->stop();
    renderVoice(*engine);
    engine->triggerRow(voiceRow(72));
    check(renderVoice(*engine)>1, "stop and replay remain audible");
    engine=voiceEngine();
    engine->stop();
    engine->triggerRow(voiceRow(60));
    check(renderVoice(*engine)>1, "stopping an idle engine cannot deadlock synth");
    std::cout << "All synth recovery, retrigger and empty-instrument checks passed\n";
}
int main(int argc, char** argv) {
    checkVoiceRecovery();
    const std::string dir=argv[1];
    std::vector<std::string> paths(16);
    paths[2]=dir+"/group.wav";paths[3]=dir+"/lead.wav";paths[13]=dir+"/return.wav";
    auto stems=make(true,true);
    int rate;
    const auto empty=stems->renderOffline(rate,6,paths);
    check(empty.empty() && rate==48000, "streamed rather than buffered stems");
    const auto group=read(paths[2]), lead=read(paths[3]), send=read(paths[13]);
    check(group.size()==lead.size() && lead.size()==send.size(), "common start and duration");
    check(energy(group)>1 && energy(lead)>1 && energy(send)>0, "muted sources buses and aux return audible");
    check(send[0]==0, "delay return preserves initial silence");
    check(group.back()==0 && lead.back()==0 && send.back()==0, "common tail fade");
    auto reference=make(false,false);
    const auto mix=reference->renderOffline(rate,6);
    check(mix.size()==group.size(), "same offline renderer length");
    float error=0;
    for(size_t i=0;i<mix.size();++i) error=std::max(error,std::abs(mix[i]-(group[i]+lead[i]+send[i])));
    check(error<1e-5, "stems sum to unmastered mix with routing inserts sidechain and aux");

    auto noDuck=make(false,false,false);
    auto dryPaths=paths;
    dryPaths[2]=dir+"/drygroup.wav";dryPaths[3]=dir+"/unducked.wav";dryPaths[13]=dir+"/dryreturn.wav";
    noDuck->renderOffline(rate,6,dryPaths);
    check(energy(read(dryPaths[3]))>energy(lead)*1.1, "sidechain remains active in stems");

    QueuedPlaybackRow again;
    again.lineSamples=4800;again.rowData={60,200,128,0};
    stems->clearQueuedPlaybackRows();stems->enqueuePlaybackRow(again);
    const auto muted=stems->renderOffline(rate,0);
    check(energy(muted)==0, "original master mute and mixer flags preserved");
    stems->queueMixerCommands({0,1,0,0});
    stems->clearQueuedPlaybackRows();stems->enqueuePlaybackRow(again);
    check(energy(stems->renderOffline(rate,0))==0, "track mute and solo preserved independently of master mute");

    auto invalid=make(false,false);
    auto invalidPaths=paths;invalidPaths[0]=dir+"/wrong.wav";
    bool failed=false;
    try { invalid->renderOffline(rate,6,invalidPaths); } catch(const std::exception&) { failed=true; }
    check(failed, "reject routed source exported as master bus");
    invalid->renderOffline(rate,6,paths);
    check(energy(read(paths[2]))>1, "failed export releases renderer ownership");

    auto missing=make(false,false);
    auto missingPaths=paths;missingPaths[2]=dir+"/missing/file.wav";
    failed=false;
    try { missing->renderOffline(rate,6,missingPaths); } catch(const std::exception&) { failed=true; }
    check(failed, "disk write failure reported");
    missing->renderOffline(rate,6,paths);

    const std::string headroom=dir+"/headroom.wav";
    FloatWavWriter writer(headroom,48000);
    float l[]={2,-2,.1f},r[]={-3,3,.2f};
    writer.append(l,r,3);writer.finish();
    const auto floats=read(headroom);
    check(floats[0]==2 && floats[1]==-3, "float WAV preserves unclipped headroom");
    failed=false;
    try {
        FloatWavWriter full("/dev/full",48000);
        full.append(l,r,3);full.finish();
    } catch(const std::exception&) { failed=true; }
    check(failed, "disk-full errors reported when finalizing WAV");
    std::cout << "All stem routing, alignment, sidechain, state, errors and WAV checks passed\n";
}
"""

with tempfile.TemporaryDirectory(prefix="stria-native-stems-") as directory:
    directory = Path(directory)
    (directory / "oboe").mkdir()
    (directory / "android").mkdir()
    (directory / "oboe/Oboe.h").write_text(oboe)
    (directory / "android/log.h").write_text(log)
    # libc++ exposes std::sqrtf; host libstdc++ needs this compatibility alias.
    (directory / "host_math.h").write_text("#include <cmath>\nnamespace std { using ::sqrtf; }\n")
    (directory / "test.cpp").write_text(tests)
    executable = directory / "check"
    subprocess.run([
        "clang++", "-std=c++17", "-O1", "-g", "-fsanitize=address,undefined",
        "-fno-omit-frame-pointer", "-fno-sanitize-recover=all",
        "-pthread", "-include", str(directory / "host_math.h"),
        "-I", str(directory), "-I", str(cpp),
        str(directory / "test.cpp"), str(cpp / "audio_engine.cpp"),
        str(cpp / "freeverb.cpp"), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable), str(directory)], check=True)
