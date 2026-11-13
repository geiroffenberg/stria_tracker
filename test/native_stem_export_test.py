"""Run with python3 test/native_stem_export_test.py (requires clang++).

Checks voice recovery, sampler loop attacks, master WAV and stem export using the complete production engine
offline; only Android logging and the audio-device API are stubbed.
No audio device or Android runtime is required.
Also checks Song Plan queue boundaries and sample-aligned track mutes.
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
#include "wav_writer.h"
#include <algorithm>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <sys/resource.h>
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
void checkPcm(const std::string& path, const std::vector<float>& reference) {
    std::ifstream file(path, std::ios::binary);
    std::vector<char> bytes((std::istreambuf_iterator<char>(file)), {});
    check(bytes.size()==44+reference.size()*2, "PCM duration matches buffered export exactly");
    check(std::memcmp(bytes.data(), "RIFF", 4)==0, "PCM RIFF tag");
    check(bytes[20]==1 && bytes[22]==2 && bytes[34]==16, "stereo 16-bit PCM");
    check(std::memcmp(bytes.data()+36, "data", 4)==0, "PCM data chunk");
    uint32_t riffSize, dataSize, sampleRate;
    std::memcpy(&riffSize, bytes.data()+4, 4);
    std::memcpy(&dataSize, bytes.data()+40, 4);
    std::memcpy(&sampleRate, bytes.data()+24, 4);
    if (riffSize+8!=bytes.size() || dataSize!=reference.size()*2) {
        throw std::runtime_error("PCM sizes: RIFF="+std::to_string(riffSize)
            +" data="+std::to_string(dataSize)+" bytes="+std::to_string(bytes.size())
            +" samples="+std::to_string(reference.size()));
    }
    check(sampleRate==48000 && bytes[32]==4, "PCM sample rate and frame alignment");
    for (size_t i=0;i<reference.size();++i) {
        const auto lo=static_cast<uint8_t>(bytes[44+i*2]);
        const auto hi=static_cast<uint8_t>(bytes[45+i*2]);
        const int16_t actual=static_cast<int16_t>(lo | (hi<<8));
        const int16_t expected=static_cast<int16_t>(
            std::clamp(static_cast<double>(reference[i]), -1.0, 1.0)*32767.0);
        check(actual==expected, "PCM samples match existing WAV encoder exactly");
    }
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
void checkSamplerLoopAttack(const std::string& dir) {
    const auto path=dir+"/sampler-attack.wav";
    std::vector<float> sample(480000,.25f);
    WavWriter writer(path,48000,WavWriter::Format::Pcm16);
    writer.append(sample.data(),sample.data(),sample.size());writer.finish();
    for (int loopMode : {0,1,2}) {
        // OFF may finish before the next pass, or still be releasing there.
        for (int release : {-1,0,255}) {
            for (int attack : {0,128}) {
                auto engine=voiceEngine();
                check(engine->setSamplerSample(0,path), "attack test sample loaded");
                QueuedPlaybackRow note;
                note.lineSamples=24000;note.rowData=voiceRow(60,1);
                note.rowData[5+9]=attack;
                note.rowData[5+12]=std::max(0,release);
                note.rowData[5+16]=255;
                note.rowData[5+18]=loopMode;
                note.rowData[5+38]=5; // Internal sample loops wrap during the attack.
                auto end=note;
                end.rowData[0]=release<0 ? -1 : -2;
                engine->enqueuePlaybackRow(note);
                engine->enqueuePlaybackRow(end);
                engine->setQueuedPlaybackLooping(true);
                engine->start();
                oboe::AudioStream stream;
                std::vector<float> audio(144000*2);
                for (int frame=0;frame<144000;frame+=192) {
                    engine->onAudioReady(&stream,audio.data()+frame*2,192);
                }
                auto windowEnergy=[&](int start) {
                    double sum=0;
                    for (int f=start;f<start+480;++f) {
                        sum+=audio[f*2]*audio[f*2]+audio[f*2+1]*audio[f*2+1];
                    }
                    return sum;
                };
                // The first row lasts 0.5 s; measure full level before OFF.
                const double full=windowEnergy(23000);
                check(full>.01, "sampler reaches audible level before OFF");
                for (int pass=0;pass<3;++pass) {
                    const double ratio=windowEnergy(pass*48000+480)/full;
                    const std::string context=" (mode="+std::to_string(loopMode)
                        +", release="+std::to_string(release)+", attack="+std::to_string(attack)
                        +", pass="+std::to_string(pass)+", ratio="+std::to_string(ratio)+")";
                    if (attack>0) {
                        check(ratio>.0002 && ratio<.003,
                              ("every pattern pass restarts the configured sampler attack, including after OFF"+context).c_str());
                    } else {
                        check(ratio>.95 && ratio<1.05,
                              ("zero-attack sampler stays immediate on every pattern pass"+context).c_str());
                    }
                }
                if (release<0 && attack>0) {
                    note.rowData[0]=-1;
                    engine->beginPendingRows();
                    engine->appendPendingRow(note);
                    engine->appendPendingRow(end);
                    renderVoice(*engine,250);
                    const double heldRatio=renderVoice(*engine,5)/(2*windowEnergy(36000));
                    check(heldRatio>.95 && heldRatio<1.05,
                          "hold rows across pattern loops keep the existing sampler envelope");
                }
            }
        }
    }
    std::cout << "All sampler pattern-loop attack and OFF checks passed\n";
}
int main(int argc, char** argv) {
    checkVoiceRecovery();
    const std::string dir=argv[1];
    checkSamplerLoopAttack(dir);
    for (bool master : {false, true}) {
        for (int tail : {0, 1, 6}) {
            auto buffered=make(master,false);
            auto streamed=make(master,false);
            int rate;
            const auto expected=buffered->renderOffline(rate,tail);
            const auto path=dir+"/master.wav";
            check(streamed->renderOffline(rate,tail,{},path).empty(),
                  "master WAV streams instead of returning whole-song audio");
            checkPcm(path,expected);
        }
    }
    {
        auto buffered=voiceEngine(), streamed=voiceEngine();
        QueuedPlaybackRow silent;
        silent.lineSamples=4800;silent.rowData={-1,-1,128,0};
        buffered->enqueuePlaybackRow(silent);streamed->enqueuePlaybackRow(silent);
        int rate;
        const auto expected=buffered->renderOffline(rate,6);
        streamed->renderOffline(rate,6,{},dir+"/silent.wav");
        checkPcm(dir+"/silent.wav",expected);
        check(expected.size()<48000*2, "quiet tail stops early as before");
    }
    {
        std::vector<float> sample(4800);
        for (size_t i=0;i<sample.size();++i) sample[i]=.4f*std::sin(i*.05f);
        const auto samplePath=dir+"/sample.wav";
        WavWriter writer(samplePath,48000,WavWriter::Format::Pcm16);
        writer.append(sample.data(),sample.data(),sample.size());writer.finish();
        auto buffered=voiceEngine(), streamed=voiceEngine();
        check(buffered->setSamplerSample(0,samplePath) &&
              streamed->setSamplerSample(0,samplePath), "sample loaded into both engines");
        QueuedPlaybackRow row;
        row.lineSamples=48000;row.rowData=voiceRow(60,1);
        row.rowData[5+16]=255; // Sampler end region, unlike synth LFO depth.
        buffered->enqueuePlaybackRow(row);streamed->enqueuePlaybackRow(row);
        int rate;
        const auto expected=buffered->renderOffline(rate,6);
        check(energy(expected)>.01, "sampler reference is audible");
        streamed->renderOffline(rate,6,{},dir+"/sampler-master.wav");
        checkPcm(dir+"/sampler-master.wav",expected);
    }
    {
        auto engine=make(false,false);
        int rate;
        bool failed=false;
        try { engine->renderOffline(rate,6,{},dir+"/missing/master.wav"); }
        catch(const std::exception&) { failed=true; }
        check(failed, "master write failure reported");
        check(engine->renderOffline(rate,6,{},dir+"/recovered.wav").empty(),
              "master write failure releases render ownership");
        engine=make(false,false);
        QueuedPlaybackRow tooLong;
        tooLong.lineSamples=48000*60*21;tooLong.rowData={-1,-1,128,0};
        engine->enqueuePlaybackRow(tooLong);
        failed=false;
        try { engine->renderOffline(rate,6,{},dir+"/too-long.wav"); }
        catch(const std::exception&) { failed=true; }
        check(failed && !std::filesystem::exists(dir+"/too-long.wav"),
              "overlength master rejected before rendering or creating a file");
        engine=make(false,false);
        failed=false;
        try { engine->renderOffline(rate,6,{},"/dev/full"); }
        catch(const std::exception&) { failed=true; }
        check(failed, "master disk-full failure reported");
        engine->clearQueuedPlaybackRows();
        QueuedPlaybackRow retry;
        retry.lineSamples=4800;retry.rowData={60,200,128,0};
        engine->enqueuePlaybackRow(retry);
        engine->renderOffline(rate,0,{},dir+"/disk-full-retry.wav");
        check(std::filesystem::file_size(dir+"/disk-full-retry.wav")>44,
              "mid-render disk failure leaves engine stopped and reusable");
    }
    {
        auto engine=voiceEngine();
        QueuedPlaybackRow longSong;
        longSong.lineSamples=48000*240;longSong.rowData={-1,-1,128,0};
        engine->enqueuePlaybackRow(longSong);
        rusage before{}, after{};
        check(getrusage(RUSAGE_SELF,&before)==0, "read initial memory usage");
        int rate;
        const auto path=dir+"/four-minutes.wav";
        check(engine->renderOffline(rate,0,{},path).empty(), "long master does not return audio");
        check(getrusage(RUSAGE_SELF,&after)==0, "read final memory usage");
        check(std::filesystem::file_size(path)==44+uint64_t(48000)*240*4,
              "four-minute WAV has exact duration without truncation");
        check(after.ru_maxrss-before.ru_maxrss<16*1024, "long export peak memory growth stays below 16 MiB");
        std::cout << "Four-minute export peak RSS growth: "
                  << after.ru_maxrss-before.ru_maxrss << " KiB\n";
    }
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
    WavWriter writer(headroom,48000);
    float l[]={2,-2,.1f},r[]={-3,3,.2f};
    writer.append(l,r,3);writer.finish();
    const auto floats=read(headroom);
    check(floats[0]==2 && floats[1]==-3, "float WAV preserves unclipped headroom");
    failed=false;
    try {
        WavWriter full("/dev/full",48000);
        full.append(l,r,3);full.finish();
    } catch(const std::exception&) { failed=true; }
    check(failed, "disk-full errors reported when finalizing WAV");
    {
        const std::vector<float> values={2,-3,-2,3,.1f,.2f};
        WavWriter pcm(dir+"/pcm.wav",48000,WavWriter::Format::Pcm16);
        pcm.appendInterleaved(values.data(),3);pcm.finish();
        checkPcm(dir+"/pcm.wav",values);
        failed=false;
        try {
            WavWriter full("/dev/full",48000,WavWriter::Format::Pcm16);
            full.appendInterleaved(values.data(),3);full.finish();
        } catch(const std::exception&) { failed=true; }
        check(failed, "PCM disk-full error reported");
    }
    std::cout << "Master streaming matches buffered PCM, processing, tail and fade exactly\n";
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
    plan_executable = directory / "song-plan-check"
    subprocess.run([
        "clang++", "-std=c++17", "-O1", "-g", "-fsanitize=address,undefined",
        "-fno-omit-frame-pointer", "-fno-sanitize-recover=all",
        "-pthread", "-include", str(directory / "host_math.h"),
        "-I", str(directory), "-I", str(cpp),
        str(root / "test/native/song_plan_queue_test.cpp"), str(cpp / "audio_engine.cpp"),
        str(cpp / "freeverb.cpp"), "-o", str(plan_executable),
    ], check=True)
    subprocess.run([str(plan_executable)], check=True)
