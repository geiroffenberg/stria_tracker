"""Run with python3 test/native_insert_effects_test.py (requires clang++).

Compile the production insert state/functions verbatim in a host-only adapter,
without Android/Oboe. Android builds separately validate the platform bridge.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
cpp = root / "android/app/src/main/cpp"
source = (cpp / "audio_engine.cpp").read_text()
header = (cpp / "audio_engine.h").read_text()


def definition(text, signature):
    start = text.index(signature)
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        if text[end] == "{":
            depth += 1
        elif text[end] == "}":
            depth -= 1
        end += 1
    return text[start:end]


prefix = r"""
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <vector>
#include "freeverb.h"
constexpr int kMaxVoices = 16;
constexpr int kMaxInsertSlots = 6;
"""
adapter = r"""
struct AudioEngine {
    float mCachedSampleRate = 48000;
    std::vector<float> mFxWetL, mFxWetR;
    std::array<std::vector<float>, 16> mSidechainSnapshotL, mSidechainSnapshotR;
    void processEffects(float*, float*, int, InsertEffect*);
};
"""
tests = r"""
void check(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(message);
}
void configure(InsertEffect& fx, int type, const std::array<float, 5>& db) {
    fx.type = type; fx.dryLevel = 0; fx.wetLevel = 1;
    applyEqParams(fx, db[0]/12, std::log(60.0f/40)/std::log(500.0f/40),
        db[2]/12, std::log(1000.0f/200)/std::log(8000.0f/200), (1.0f-.3f)/7.7f,
        db[4]/12, std::log(12000.0f/2000)/std::log(16000.0f/2000),
        db[1]/12, db[3]/12);
}
double gainAt(float sr, int band, float db) {
    AudioEngine engine; engine.mCachedSampleRate = sr;
    InsertEffect fx[6];
    std::array<float,5> gains{};
    gains[band] = db;
    configure(fx[0], 11, gains);
    const float freqs[] = {60, 250, 1000, 4000, 12000};
    double input = 0, output = 0;
    int total = 0;
    for (int block = 0; block < 200; ++block) {
        float l[512], r[512], dry[512];
        for (int i=0;i<512;++i) {
            dry[i] = l[i] = r[i] = .01f * std::sin(2*M_PI*freqs[band]*(total+i)/sr);
        }
        engine.processEffects(l, r, 512, fx);
        for (int i=0;i<512;++i) {
            check(std::isfinite(l[i]) && l[i] == r[i], "finite linked stereo EQ");
            if (total+i > 48000) {
                input += dry[i]*dry[i]; output += l[i]*l[i];
            }
        }
        total += 512;
    }
    return 10*std::log10(output/input);
}
int main() {
    std::cout << std::unitbuf;
    for (float sr : {44100.0f, 48000.0f, 96000.0f}) {
        for (int band=0;band<5;++band) {
            for (float db : {-10.0f, 0.0f, 10.0f}) {
                double measured = gainAt(sr, band, db);
                std::cout << sr << " band " << band << " " << db << " -> " << measured << " dB\n";
                const float expected = (band == 0 || band == 4) ? db/2 : db;
                check(std::abs(measured-expected) < .15, "EQ corner/center response matches within 0.15 dB");
            }
        }
    }
    AudioEngine engine;
    InsertEffect fx[6], reference[6];
    configure(fx[0], 11, {3,0,-4,0,5});
    configure(reference[0], 7, {3,0,-4,0,5});
    for (int n=0;n<10;++n) {
        float l[512], r[512], a[512], b[512];
        for (int i=0;i<512;++i) a[i]=b[i]=l[i]=r[i]=.01f*std::sin((i+n*512)*.14);
        engine.processEffects(l,r,512,fx);
        engine.processEffects(a,b,512,reference);
        for (int i=0;i<512;++i) check(std::abs(l[i]-a[i]) < 1e-5, "three-band EQ remains equivalent");
    }
    float left[3] = {2,-2,.2f}, right[3] = {-2,2,-.2f};
    fx[0].type=5; fx[0].limGain=0; fx[0].dryLevel=0; fx[0].wetLevel=1;
    engine.processEffects(left,right,3,fx);
    check(left[0]==.9886f && left[1]==-.9886f && left[2]==.2f, "legacy clipper unchanged");
    fx[0].type=9;
    for (int value : {0,49,50,99}) {
        for (int function : {2,3,4,5,8}) applyInsertFxCommand(fx[0], function, value);
        check(fx[0].flangerStereo==(value>0), "flanger stereo automation");
        check(std::abs(fx[0].flangerRate-value/99.0f)<1e-6, "flanger rate automation");
        check(fx[0].flangerDepth==fx[0].flangerRate, "flanger depth automation");
        check(fx[0].flangerDelay==fx[0].flangerRate, "flanger delay automation");
        check(std::abs(fx[0].flangerFeedback-
            std::clamp(value/99.0f*2-1,-.95f,.95f))<1e-6, "flanger feedback bounded");
    }
    applyFlangerParams(fx[0],1,1,1,.95,1);
    for (int block=0;block<500;++block) {
        float l[512],r[512];
        for(int i=0;i<512;++i) l[i]=r[i]=.01f*std::sin((i+block*512)*.15);
        engine.processEffects(l,r,512,fx);
        for(int i=0;i<512;++i) check(std::isfinite(l[i]) && std::abs(l[i])<1, "flanger feedback stable");
    }
    applyInsertFxCommand(fx[0],0,0);
    check(fx[0].flangerFeedback==0 && fx[0].flangerBufPos==0, "flanger reset");
    check(fx[0].flangerRate==.3f && fx[0].flangerDepth==.22f, "flanger defaults");
    fx[0].type=11;
    for (int fn : {3,4,5,8,9}) {
        applyInsertFxCommand(fx[0],fn,99);
    }
    check(std::abs(fx[0].eqLowGain*12-10)<1e-5 &&
        std::abs(fx[0].eqWarmthGain*12-10)<1e-5 &&
        std::abs(fx[0].eqClarityGain*12-10)<1e-5, "EQ-5 automation gain range");
    applyInsertFxCommand(fx[0],0,0);
    check(fx[0].eqWarmthGain==0 && fx[0].eqClarityGain==0, "EQ-5 reset");
    fx[0].bypass=true;
    left[0]=.123f;right[0]=-.456f;
    engine.processEffects(left,right,1,fx);
    check(left[0]==.123f && right[0]==-.456f, "bypass unchanged");
    std::cout << "All native signal and automation checks passed\n";
}
"""

parts = [
    prefix, definition(header, "struct InsertEffect") + ";", adapter,
    definition(source, "float fxValueToUnit"),
    definition(source, "void syncReverbState"),
    definition(source, "void applyInsertFxCommand"),
    definition(source, "static void applyEqParams"),
    definition(source, "static void applyFlangerParams"),
    definition(source, "void AudioEngine::processEffects"),
    tests,
]
with tempfile.TemporaryDirectory(prefix="stria-insert-test-") as directory:
    directory = Path(directory)
    test = directory / "check.cpp"
    test.write_text("\n".join(parts))
    executable = directory / "check"
    subprocess.run([
        "clang++", "-std=c++17", "-O1", "-fsanitize=address,undefined",
        "-fno-omit-frame-pointer", "-I", str(cpp), str(test),
        str(cpp / "freeverb.cpp"), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)
