#include <jni.h>
#include "audio_engine.h"
#include <vector>
#include <string>

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeCreate(JNIEnv*, jobject) {
    return reinterpret_cast<jlong>(new AudioEngine());
}

JNIEXPORT jboolean JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeOpen(JNIEnv*, jobject, jlong ptr) {
    return reinterpret_cast<AudioEngine*>(ptr)->open();
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeStart(JNIEnv*, jobject, jlong ptr) {
    reinterpret_cast<AudioEngine*>(ptr)->start();
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeStop(JNIEnv*, jobject, jlong ptr) {
    reinterpret_cast<AudioEngine*>(ptr)->stop();
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeStopTransportSoft(JNIEnv*, jobject, jlong ptr) {
    reinterpret_cast<AudioEngine*>(ptr)->stopTransportSoft();
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativePauseStream(JNIEnv*, jobject, jlong ptr) {
    reinterpret_cast<AudioEngine*>(ptr)->pauseOutputStream();
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeResumeStream(JNIEnv*, jobject, jlong ptr) {
    reinterpret_cast<AudioEngine*>(ptr)->resumeOutputStream();
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetTempo(
        JNIEnv*, jobject, jlong ptr, jdouble bpm) {
    reinterpret_cast<AudioEngine*>(ptr)->setTempo(bpm);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetLineSamplesPerRow(
        JNIEnv*, jobject, jlong ptr, jint samples) {
    reinterpret_cast<AudioEngine*>(ptr)->setLineSamplesPerRow(static_cast<int32_t>(samples));
}

JNIEXPORT jint JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeConsumePendingRowAdvances(
        JNIEnv*, jobject, jlong ptr) {
    return reinterpret_cast<AudioEngine*>(ptr)->consumePendingRowAdvances();
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeResetPlayheadPhase(
        JNIEnv*, jobject, jlong ptr) {
    reinterpret_cast<AudioEngine*>(ptr)->resetPlayheadPhase();
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeClearQueuedPlaybackRows(
        JNIEnv*, jobject, jlong ptr) {
    reinterpret_cast<AudioEngine*>(ptr)->clearQueuedPlaybackRows();
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetQueuedPlaybackLooping(
        JNIEnv*, jobject, jlong ptr, jboolean loop) {
    reinterpret_cast<AudioEngine*>(ptr)->setQueuedPlaybackLooping(loop);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeEnqueuePlaybackRow(
        JNIEnv* env,
        jobject,
        jlong ptr,
        jint lineSamples,
        jintArray rowData,
        jintArray immediateKillMask,
        jintArray retrigData,
        jintArray arpData,
        jintArray delayData,
        jintArray killData,
        jintArray sliceCommandData,
        jintArray mixerCommandData,
        jintArray insertFxCommandData,
        jintArray pitchRampData) {
    auto toVector = [env](jintArray array) {
        jsize len = env->GetArrayLength(array);
        jint* elms = env->GetIntArrayElements(array, nullptr);
        std::vector<int> vec(elms, elms + len);
        env->ReleaseIntArrayElements(array, elms, JNI_ABORT);
        return vec;
    };
    QueuedPlaybackRow row;
    row.lineSamples = static_cast<int32_t>(lineSamples);
    row.rowData = toVector(rowData);
    row.immediateKillMask = toVector(immediateKillMask);
    row.retrigData = toVector(retrigData);
    row.arpData = toVector(arpData);
    row.delayData = toVector(delayData);
    row.killData = toVector(killData);
    row.sliceCommandData = toVector(sliceCommandData);
    row.mixerCommandData = toVector(mixerCommandData);
    row.insertFxCommandData = toVector(insertFxCommandData);
    row.pitchRampData = toVector(pitchRampData);
    reinterpret_cast<AudioEngine*>(ptr)->enqueuePlaybackRow(row);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeBeginPendingRows(
        JNIEnv*, jobject, jlong ptr) {
    reinterpret_cast<AudioEngine*>(ptr)->beginPendingRows();
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeAppendPendingRow(
        JNIEnv* env,
        jobject,
        jlong ptr,
        jint lineSamples,
        jintArray rowData,
        jintArray immediateKillMask,
        jintArray retrigData,
        jintArray arpData,
        jintArray delayData,
        jintArray killData,
        jintArray sliceCommandData,
        jintArray mixerCommandData,
        jintArray insertFxCommandData,
        jintArray pitchRampData) {
    auto toVector = [env](jintArray array) {
        jsize len = env->GetArrayLength(array);
        jint* elms = env->GetIntArrayElements(array, nullptr);
        std::vector<int> vec(elms, elms + len);
        env->ReleaseIntArrayElements(array, elms, JNI_ABORT);
        return vec;
    };
    QueuedPlaybackRow row;
    row.lineSamples = static_cast<int32_t>(lineSamples);
    row.rowData = toVector(rowData);
    row.immediateKillMask = toVector(immediateKillMask);
    row.retrigData = toVector(retrigData);
    row.arpData = toVector(arpData);
    row.delayData = toVector(delayData);
    row.killData = toVector(killData);
    row.sliceCommandData = toVector(sliceCommandData);
    row.mixerCommandData = toVector(mixerCommandData);
    row.insertFxCommandData = toVector(insertFxCommandData);
    row.pitchRampData = toVector(pitchRampData);
    reinterpret_cast<AudioEngine*>(ptr)->appendPendingRow(row);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetRowData(
        JNIEnv* env, jobject, jlong ptr, jintArray data) {
    jsize        len  = env->GetArrayLength(data);
    jint*        elms = env->GetIntArrayElements(data, nullptr);
    std::vector<int> vec(elms, elms + len);
    env->ReleaseIntArrayElements(data, elms, JNI_ABORT);
    reinterpret_cast<AudioEngine*>(ptr)->triggerRow(vec);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeKillVoices(
        JNIEnv* env, jobject, jlong ptr, jintArray mask) {
    jsize  len  = env->GetArrayLength(mask);
    jint*  elms = env->GetIntArrayElements(mask, nullptr);
    std::vector<int> vec(elms, elms + len);
    env->ReleaseIntArrayElements(mask, elms, JNI_ABORT);
    reinterpret_cast<AudioEngine*>(ptr)->killVoices(vec);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeQueueRetrigs(
        JNIEnv* env, jobject, jlong ptr, jintArray data) {
    jsize len  = env->GetArrayLength(data);
    jint* elms = env->GetIntArrayElements(data, nullptr);
    std::vector<int> vec(elms, elms + len);
    env->ReleaseIntArrayElements(data, elms, JNI_ABORT);
    reinterpret_cast<AudioEngine*>(ptr)->queueRetrigs(vec);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeQueueArp(
        JNIEnv* env, jobject, jlong ptr, jintArray data) {
    jsize len  = env->GetArrayLength(data);
    jint* elms = env->GetIntArrayElements(data, nullptr);
    std::vector<int> vec(elms, elms + len);
    env->ReleaseIntArrayElements(data, elms, JNI_ABORT);
    reinterpret_cast<AudioEngine*>(ptr)->queueArp(vec);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeQueueDelays(
        JNIEnv* env, jobject, jlong ptr, jintArray data) {
    jsize len  = env->GetArrayLength(data);
    jint* elms = env->GetIntArrayElements(data, nullptr);
    std::vector<int> vec(elms, elms + len);
    env->ReleaseIntArrayElements(data, elms, JNI_ABORT);
    reinterpret_cast<AudioEngine*>(ptr)->queueDelays(vec);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeQueueKills(
        JNIEnv* env, jobject, jlong ptr, jintArray data) {
    jsize len  = env->GetArrayLength(data);
    jint* elms = env->GetIntArrayElements(data, nullptr);
    std::vector<int> vec(elms, elms + len);
    env->ReleaseIntArrayElements(data, elms, JNI_ABORT);
    reinterpret_cast<AudioEngine*>(ptr)->queueKills(vec);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeQueueSliceCommands(
        JNIEnv* env, jobject, jlong ptr, jintArray data) {
    jsize len  = env->GetArrayLength(data);
    jint* elms = env->GetIntArrayElements(data, nullptr);
    std::vector<int> vec(elms, elms + len);
    env->ReleaseIntArrayElements(data, elms, JNI_ABORT);
    reinterpret_cast<AudioEngine*>(ptr)->queueSliceCommands(vec);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeQueueMixerCommands(
        JNIEnv* env, jobject, jlong ptr, jintArray data) {
    jsize len  = env->GetArrayLength(data);
    jint* elms = env->GetIntArrayElements(data, nullptr);
    std::vector<int> vec(elms, elms + len);
    env->ReleaseIntArrayElements(data, elms, JNI_ABORT);
    reinterpret_cast<AudioEngine*>(ptr)->queueMixerCommands(vec);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeQueueInsertFxCommands(
        JNIEnv* env, jobject, jlong ptr, jintArray data) {
    jsize len  = env->GetArrayLength(data);
    jint* elms = env->GetIntArrayElements(data, nullptr);
    std::vector<int> vec(elms, elms + len);
    env->ReleaseIntArrayElements(data, elms, JNI_ABORT);
    reinterpret_cast<AudioEngine*>(ptr)->queueInsertFxCommands(vec);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetMasterInsertEffect(
        JNIEnv* env, jobject, jlong ptr, jint slotIdx, jint effectType, jfloat dryWet) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterInsertEffect(slotIdx, effectType, dryWet);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetMasterInsertMix(
        JNIEnv*, jobject, jlong ptr, jint slotIdx, jfloat dryLevel, jfloat wetLevel) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterInsertMix(slotIdx, dryLevel, wetLevel);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetMasterInsertBypass(
        JNIEnv*, jobject, jlong ptr, jint slotIdx, jboolean bypass) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterInsertBypass(slotIdx, bypass);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetMasterLimiterEnabled(
        JNIEnv*, jobject, jlong ptr, jboolean enabled) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterLimiterEnabled(enabled);
}

JNIEXPORT jboolean JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeIsMasterLimiterEnabled(
        JNIEnv*, jobject, jlong ptr) {
    return reinterpret_cast<AudioEngine*>(ptr)->isMasterLimiterEnabled() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetStabilityMode(
        JNIEnv*, jobject, jlong ptr, jboolean enabled) {
    reinterpret_cast<AudioEngine*>(ptr)->setStabilityMode(enabled);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetMasterVolumeLinear(
        JNIEnv*, jobject, jlong ptr, jfloat linearGain) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterVolumeLinear(linearGain);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetMasterReverbParams(
        JNIEnv* env, jobject, jlong ptr, jint slotIdx, jfloat roomSize, jfloat damp, jfloat width, jboolean freeze) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterReverbParams(slotIdx, roomSize, damp, width, freeze);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetTrackInsertEffect(
        JNIEnv* env, jobject, jlong ptr, jint trackIdx, jint slotIdx, jint effectType, jfloat dryWet) {
    reinterpret_cast<AudioEngine*>(ptr)->setTrackInsertEffect(trackIdx, slotIdx, effectType, dryWet);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetTrackInsertMix(
        JNIEnv*, jobject, jlong ptr, jint trackIdx, jint slotIdx, jfloat dryLevel, jfloat wetLevel) {
    reinterpret_cast<AudioEngine*>(ptr)->setTrackInsertMix(trackIdx, slotIdx, dryLevel, wetLevel);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetTrackInsertBypass(
        JNIEnv*, jobject, jlong ptr, jint trackIdx, jint slotIdx, jboolean bypass) {
    reinterpret_cast<AudioEngine*>(ptr)->setTrackInsertBypass(trackIdx, slotIdx, bypass);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetVoicePreviewBypassTrackInserts(
        JNIEnv*, jobject, jlong ptr, jint trackIdx, jboolean bypass) {
    reinterpret_cast<AudioEngine*>(ptr)->setVoicePreviewBypassTrackInserts(trackIdx, bypass);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetTrackReverbParams(
        JNIEnv* env, jobject, jlong ptr, jint trackIdx, jint slotIdx, jfloat roomSize, jfloat damp, jfloat width, jboolean freeze) {
    reinterpret_cast<AudioEngine*>(ptr)->setTrackReverbParams(trackIdx, slotIdx, roomSize, damp, width, freeze);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetMasterDelayParams(
        JNIEnv*, jobject, jlong ptr, jint slotIdx, jfloat timeMs, jfloat feedback, jfloat hpCutoff, jboolean sync) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterDelayParams(slotIdx, timeMs, feedback, hpCutoff, sync);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetTrackDelayParams(
        JNIEnv*, jobject, jlong ptr, jint trackIdx, jint slotIdx, jfloat timeMs, jfloat feedback, jfloat hpCutoff, jboolean sync) {
    reinterpret_cast<AudioEngine*>(ptr)->setTrackDelayParams(trackIdx, slotIdx, timeMs, feedback, hpCutoff, sync);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetTrackFilterParams(
        JNIEnv*, jobject, jlong ptr, jint trackIdx, jint slotIdx, jfloat cutoff, jfloat resonance, jint mode) {
    reinterpret_cast<AudioEngine*>(ptr)->setTrackFilterParams(trackIdx, slotIdx, cutoff, resonance, mode);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetMasterFilterParams(
        JNIEnv*, jobject, jlong ptr, jint slotIdx, jfloat cutoff, jfloat resonance, jint mode) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterFilterParams(slotIdx, cutoff, resonance, mode);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetTrackDistortionParams(
        JNIEnv*, jobject, jlong ptr, jint trackIdx, jint slotIdx, jfloat drive, jfloat tone, jint distType) {
    reinterpret_cast<AudioEngine*>(ptr)->setTrackDistortionParams(trackIdx, slotIdx, drive, tone, distType);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetMasterDistortionParams(
        JNIEnv*, jobject, jlong ptr, jint slotIdx, jfloat drive, jfloat tone, jint distType) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterDistortionParams(slotIdx, drive, tone, distType);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetTrackBitcrusherParams(
        JNIEnv*, jobject, jlong ptr, jint trackIdx, jint slotIdx, jfloat bits, jfloat rate) {
    reinterpret_cast<AudioEngine*>(ptr)->setTrackBitcrusherParams(trackIdx, slotIdx, bits, rate);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetMasterBitcrusherParams(
        JNIEnv*, jobject, jlong ptr, jint slotIdx, jfloat bits, jfloat rate) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterBitcrusherParams(slotIdx, bits, rate);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetTrackLimiterParams(
        JNIEnv*, jobject, jlong ptr, jint trackIdx, jint slotIdx, jfloat gain) {
    reinterpret_cast<AudioEngine*>(ptr)->setTrackLimiterParams(trackIdx, slotIdx, gain);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetMasterLimiterParams(
        JNIEnv*, jobject, jlong ptr, jint slotIdx, jfloat gain) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterLimiterParams(slotIdx, gain);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetTrackChorusParams(
        JNIEnv*, jobject, jlong ptr, jint trackIdx, jint slotIdx, jfloat rate, jfloat depth, jfloat delay, jint stereo) {
    reinterpret_cast<AudioEngine*>(ptr)->setTrackChorusParams(trackIdx, slotIdx, rate, depth, delay, stereo);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetMasterChorusParams(
        JNIEnv*, jobject, jlong ptr, jint slotIdx, jfloat rate, jfloat depth, jfloat delay, jint stereo) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterChorusParams(slotIdx, rate, depth, delay, stereo);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetTrackFlangerParams(
        JNIEnv*, jobject, jlong ptr, jint trackIdx, jint slotIdx, jfloat rate, jfloat depth, jfloat delay, jfloat feedback, jint stereo) {
    reinterpret_cast<AudioEngine*>(ptr)->setTrackFlangerParams(trackIdx, slotIdx, rate, depth, delay, feedback, stereo);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetMasterFlangerParams(
        JNIEnv*, jobject, jlong ptr, jint slotIdx, jfloat rate, jfloat depth, jfloat delay, jfloat feedback, jint stereo) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterFlangerParams(slotIdx, rate, depth, delay, feedback, stereo);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetTrackEqParams(
        JNIEnv*, jobject, jlong ptr, jint trackIdx, jint slotIdx,
        jfloat lowGain, jfloat lowFreq, jfloat midGain, jfloat midFreq, jfloat midQ, jfloat highGain, jfloat highFreq) {
    reinterpret_cast<AudioEngine*>(ptr)->setTrackEqParams(trackIdx, slotIdx, lowGain, lowFreq, midGain, midFreq, midQ, highGain, highFreq);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetMasterEqParams(
        JNIEnv*, jobject, jlong ptr, jint slotIdx,
        jfloat lowGain, jfloat lowFreq, jfloat midGain, jfloat midFreq, jfloat midQ, jfloat highGain, jfloat highFreq) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterEqParams(slotIdx, lowGain, lowFreq, midGain, midFreq, midQ, highGain, highFreq);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetTrackCompressorParams(
        JNIEnv*, jobject, jlong ptr, jint trackIdx, jint slotIdx,
        jfloat threshold, jfloat ratio, jfloat attack, jfloat release, jfloat makeup, jint knee) {
    reinterpret_cast<AudioEngine*>(ptr)->setTrackCompressorParams(trackIdx, slotIdx, threshold, ratio, attack, release, makeup, knee);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetMasterCompressorParams(
        JNIEnv*, jobject, jlong ptr, jint slotIdx,
        jfloat threshold, jfloat ratio, jfloat attack, jfloat release, jfloat makeup, jint knee) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterCompressorParams(slotIdx, threshold, ratio, attack, release, makeup, knee);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetTrackSidechainParams(
        JNIEnv*, jobject, jlong ptr, jint trackIdx, jint slotIdx,
        jint sourceTrack, jfloat threshold, jfloat duck, jfloat attack, jfloat release) {
    reinterpret_cast<AudioEngine*>(ptr)->setTrackSidechainParams(trackIdx, slotIdx, sourceTrack, threshold, duck, attack, release);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetMasterSidechainParams(
        JNIEnv*, jobject, jlong ptr, jint slotIdx,
        jint sourceTrack, jfloat threshold, jfloat duck, jfloat attack, jfloat release) {
    reinterpret_cast<AudioEngine*>(ptr)->setMasterSidechainParams(slotIdx, sourceTrack, threshold, duck, attack, release);
}

JNIEXPORT jboolean JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetSamplerSample(
        JNIEnv* env, jobject, jlong ptr, jint slot, jstring path) {
    const char* cpath = env->GetStringUTFChars(path, nullptr);
    std::string spath = cpath ? cpath : "";
    if (cpath) env->ReleaseStringUTFChars(path, cpath);
    const bool ok = reinterpret_cast<AudioEngine*>(ptr)->setSamplerSample(slot, spath);
    return static_cast<jboolean>(ok);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeUpdateStretch(
        JNIEnv*, jobject, jlong ptr,
        jint slot, jboolean enabled, jint beats, jfloat bpm, jboolean preservePitch) {
    reinterpret_cast<AudioEngine*>(ptr)->updateStretch(
        slot,
        static_cast<bool>(enabled),
        static_cast<int>(beats),
        static_cast<float>(bpm),
        static_cast<bool>(preservePitch));
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeDispose(JNIEnv*, jobject, jlong ptr) {
    delete reinterpret_cast<AudioEngine*>(ptr);
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeStartExportTap(JNIEnv*, jobject, jlong ptr) {
    reinterpret_cast<AudioEngine*>(ptr)->startExportTap();
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeSetSendRouting(
        JNIEnv* env, jobject, jlong ptr, jintArray routing) {
    const int len = env->GetArrayLength(routing);
    jint* data = env->GetIntArrayElements(routing, nullptr);
    std::vector<int> r(data, data + len);
    env->ReleaseIntArrayElements(routing, data, JNI_ABORT);
    reinterpret_cast<AudioEngine*>(ptr)->setSendRouting(r);
}

JNIEXPORT jfloatArray JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeStopExportTap(
        JNIEnv* env, jobject, jlong ptr, jintArray outSampleRate) {
    int sampleRate = 48000;
    std::vector<float> samples = reinterpret_cast<AudioEngine*>(ptr)->stopExportTap(sampleRate);

    jint* ratePtr = env->GetIntArrayElements(outSampleRate, nullptr);
    ratePtr[0] = sampleRate;
    env->ReleaseIntArrayElements(outSampleRate, ratePtr, 0);

    jfloatArray result = env->NewFloatArray(static_cast<jsize>(samples.size()));
    if (result != nullptr && !samples.empty()) {
        env->SetFloatArrayRegion(result, 0, static_cast<jsize>(samples.size()), samples.data());
    }
    return result;
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeOpenRecordingStream(
        JNIEnv*, jobject, jlong ptr) {
    reinterpret_cast<AudioEngine*>(ptr)->openRecordingStream();
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeCloseRecordingStream(
        JNIEnv*, jobject, jlong ptr) {
    reinterpret_cast<AudioEngine*>(ptr)->closeRecordingStream();
}

JNIEXPORT void JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeStartRecording(
        JNIEnv*, jobject, jlong ptr) {
    reinterpret_cast<AudioEngine*>(ptr)->startRecording();
}

JNIEXPORT jfloatArray JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeStopRecording(
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

JNIEXPORT jboolean JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeIsVoicePlaying(
        JNIEnv*, jobject, jlong ptr, jint trackIdx) {
    return reinterpret_cast<AudioEngine*>(ptr)->isVoicePlaying(trackIdx);
}

JNIEXPORT jint JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeGetVoiceEnvelopeStage(
        JNIEnv*, jobject, jlong ptr, jint trackIdx) {
    return reinterpret_cast<AudioEngine*>(ptr)->getVoiceEnvelopeStage(trackIdx);
}

JNIEXPORT jfloatArray JNICALL
Java_com_metamind_stria_AudioEnginePlugin_nativeGetMeterValues(
        JNIEnv* env, jobject, jlong ptr) {
    const auto values = reinterpret_cast<AudioEngine*>(ptr)->getMeterValues();
    jfloatArray result = env->NewFloatArray(static_cast<jsize>(values.size()));
    if (result != nullptr) {
        env->SetFloatArrayRegion(result, 0, static_cast<jsize>(values.size()), values.data());
    }
    return result;
}

} // extern "C"
