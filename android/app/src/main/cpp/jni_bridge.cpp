#include <jni.h>
#include "audio_engine.h"
#include <vector>
#include <string>

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeCreate(JNIEnv*, jobject) {
    return reinterpret_cast<jlong>(new AudioEngine());
}

JNIEXPORT jboolean JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeOpen(JNIEnv*, jobject, jlong ptr) {
    return reinterpret_cast<AudioEngine*>(ptr)->open();
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeStart(JNIEnv*, jobject, jlong ptr) {
    reinterpret_cast<AudioEngine*>(ptr)->start();
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeStop(JNIEnv*, jobject, jlong ptr) {
    reinterpret_cast<AudioEngine*>(ptr)->stop();
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeSetTempo(
        JNIEnv*, jobject, jlong ptr, jdouble bpm) {
    reinterpret_cast<AudioEngine*>(ptr)->setTempo(bpm);
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeSetLineSamplesPerRow(
        JNIEnv*, jobject, jlong ptr, jint samples) {
    reinterpret_cast<AudioEngine*>(ptr)->setLineSamplesPerRow(static_cast<int32_t>(samples));
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeSetRowData(
        JNIEnv* env, jobject, jlong ptr, jintArray data) {
    jsize        len  = env->GetArrayLength(data);
    jint*        elms = env->GetIntArrayElements(data, nullptr);
    std::vector<int> vec(elms, elms + len);
    env->ReleaseIntArrayElements(data, elms, JNI_ABORT);
    reinterpret_cast<AudioEngine*>(ptr)->triggerRow(vec);
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeKillVoices(
        JNIEnv* env, jobject, jlong ptr, jintArray mask) {
    jsize  len  = env->GetArrayLength(mask);
    jint*  elms = env->GetIntArrayElements(mask, nullptr);
    std::vector<int> vec(elms, elms + len);
    env->ReleaseIntArrayElements(mask, elms, JNI_ABORT);
    reinterpret_cast<AudioEngine*>(ptr)->killVoices(vec);
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeQueueRetrigs(
        JNIEnv* env, jobject, jlong ptr, jintArray data) {
    jsize len  = env->GetArrayLength(data);
    jint* elms = env->GetIntArrayElements(data, nullptr);
    std::vector<int> vec(elms, elms + len);
    env->ReleaseIntArrayElements(data, elms, JNI_ABORT);
    reinterpret_cast<AudioEngine*>(ptr)->queueRetrigs(vec);
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeQueueArp(
        JNIEnv* env, jobject, jlong ptr, jintArray data) {
    jsize len  = env->GetArrayLength(data);
    jint* elms = env->GetIntArrayElements(data, nullptr);
    std::vector<int> vec(elms, elms + len);
    env->ReleaseIntArrayElements(data, elms, JNI_ABORT);
    reinterpret_cast<AudioEngine*>(ptr)->queueArp(vec);
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeQueueDelays(
        JNIEnv* env, jobject, jlong ptr, jintArray data) {
    jsize len  = env->GetArrayLength(data);
    jint* elms = env->GetIntArrayElements(data, nullptr);
    std::vector<int> vec(elms, elms + len);
    env->ReleaseIntArrayElements(data, elms, JNI_ABORT);
    reinterpret_cast<AudioEngine*>(ptr)->queueDelays(vec);
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeQueueKills(
        JNIEnv* env, jobject, jlong ptr, jintArray data) {
    jsize len  = env->GetArrayLength(data);
    jint* elms = env->GetIntArrayElements(data, nullptr);
    std::vector<int> vec(elms, elms + len);
    env->ReleaseIntArrayElements(data, elms, JNI_ABORT);
    reinterpret_cast<AudioEngine*>(ptr)->queueKills(vec);
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeQueueSliceCommands(
        JNIEnv* env, jobject, jlong ptr, jintArray data) {
    jsize len  = env->GetArrayLength(data);
    jint* elms = env->GetIntArrayElements(data, nullptr);
    std::vector<int> vec(elms, elms + len);
    env->ReleaseIntArrayElements(data, elms, JNI_ABORT);
    reinterpret_cast<AudioEngine*>(ptr)->queueSliceCommands(vec);
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeQueueMixerCommands(
        JNIEnv* env, jobject, jlong ptr, jintArray data) {
    jsize len  = env->GetArrayLength(data);
    jint* elms = env->GetIntArrayElements(data, nullptr);
    std::vector<int> vec(elms, elms + len);
    env->ReleaseIntArrayElements(data, elms, JNI_ABORT);
    reinterpret_cast<AudioEngine*>(ptr)->queueMixerCommands(vec);
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeQueueInsertFxCommands(
        JNIEnv* env, jobject, jlong ptr, jintArray data) {
    jsize len  = env->GetArrayLength(data);
    jint* elms = env->GetIntArrayElements(data, nullptr);
    std::vector<int> vec(elms, elms + len);
    env->ReleaseIntArrayElements(data, elms, JNI_ABORT);
    reinterpret_cast<AudioEngine*>(ptr)->queueInsertFxCommands(vec);
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeSetMasterInsertEffect(
        JNIEnv* env, jobject, jlong ptr, jint slotIdx, jint effectType, jfloat dryWet) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterInsertEffect(slotIdx, effectType, dryWet);
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeSetMasterInsertMix(
        JNIEnv*, jobject, jlong ptr, jint slotIdx, jfloat dryLevel, jfloat wetLevel) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterInsertMix(slotIdx, dryLevel, wetLevel);
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeSetMasterInsertBypass(
        JNIEnv*, jobject, jlong ptr, jint slotIdx, jboolean bypass) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterInsertBypass(slotIdx, bypass);
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeSetMasterReverbParams(
        JNIEnv* env, jobject, jlong ptr, jint slotIdx, jfloat roomSize, jfloat damp, jfloat width, jboolean freeze) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterReverbParams(slotIdx, roomSize, damp, width, freeze);
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeSetTrackInsertEffect(
        JNIEnv* env, jobject, jlong ptr, jint trackIdx, jint slotIdx, jint effectType, jfloat dryWet) {
    reinterpret_cast<AudioEngine*>(ptr)->setTrackInsertEffect(trackIdx, slotIdx, effectType, dryWet);
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeSetTrackInsertMix(
        JNIEnv*, jobject, jlong ptr, jint trackIdx, jint slotIdx, jfloat dryLevel, jfloat wetLevel) {
    reinterpret_cast<AudioEngine*>(ptr)->setTrackInsertMix(trackIdx, slotIdx, dryLevel, wetLevel);
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeSetTrackInsertBypass(
        JNIEnv*, jobject, jlong ptr, jint trackIdx, jint slotIdx, jboolean bypass) {
    reinterpret_cast<AudioEngine*>(ptr)->setTrackInsertBypass(trackIdx, slotIdx, bypass);
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeSetTrackReverbParams(
        JNIEnv* env, jobject, jlong ptr, jint trackIdx, jint slotIdx, jfloat roomSize, jfloat damp, jfloat width, jboolean freeze) {
    reinterpret_cast<AudioEngine*>(ptr)->setTrackReverbParams(trackIdx, slotIdx, roomSize, damp, width, freeze);
}

JNIEXPORT jboolean JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeSetSamplerSample(
        JNIEnv* env, jobject, jlong ptr, jint slot, jstring path) {
    const char* cpath = env->GetStringUTFChars(path, nullptr);
    std::string spath = cpath ? cpath : "";
    if (cpath) env->ReleaseStringUTFChars(path, cpath);
    const bool ok = reinterpret_cast<AudioEngine*>(ptr)->setSamplerSample(slot, spath);
    return static_cast<jboolean>(ok);
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeDispose(JNIEnv*, jobject, jlong ptr) {
    delete reinterpret_cast<AudioEngine*>(ptr);
}

JNIEXPORT void JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeStartRecording(
        JNIEnv*, jobject, jlong ptr) {
    reinterpret_cast<AudioEngine*>(ptr)->startRecording();
}

JNIEXPORT jfloatArray JNICALL
Java_com_example_tracker_AudioEnginePlugin_nativeStopRecording(
        JNIEnv* env, jobject, jlong ptr, jintArray outSampleRate) {
    int sampleRate = 44100;
    std::vector<float> samples = reinterpret_cast<AudioEngine*>(ptr)->stopRecording(sampleRate);
    
    // Set the sample rate in the output parameter
    jint* ratePtr = env->GetIntArrayElements(outSampleRate, nullptr);
    ratePtr[0] = sampleRate;
    env->ReleaseIntArrayElements(outSampleRate, ratePtr, 0);
    
    // Convert samples to jfloatArray
    jfloatArray result = env->NewFloatArray(samples.size());
    if (result != nullptr && !samples.empty()) {
        env->SetFloatArrayRegion(result, 0, samples.size(), samples.data());
    }
    return result;
}

} // extern "C"
