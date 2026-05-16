package com.metamind.stria

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Bridges Flutter MethodChannel calls to the native Oboe AudioEngine
 * via JNI.  All JNI functions are declared at the bottom of this file.
 */
class AudioEnginePlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var channel: MethodChannel
    private var enginePtr: Long = 0L // pointer to C++ AudioEngine

    // ── FlutterPlugin ────────────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        if (enginePtr != 0L) {
            nativeDispose(enginePtr)
            enginePtr = 0L
        }
    }

    // ── MethodCallHandler ────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "initialize" -> {
                enginePtr = nativeCreate()
                if (enginePtr != 0L && nativeOpen(enginePtr)) {
                    result.success(null)
                } else {
                    result.error("INIT_FAILED", "Failed to open Oboe stream", null)
                }
            }
            "start" -> {
                if (enginePtr != 0L) nativeStart(enginePtr)
                result.success(null)
            }
            "stop" -> {
                if (enginePtr != 0L) nativeStop(enginePtr)
                result.success(null)
            }
            "setTempo" -> {
                val bpm = call.argument<Double>("bpm") ?: 120.0
                if (enginePtr != 0L) nativeSetTempo(enginePtr, bpm)
                result.success(null)
            }
            "setLineSamplesPerRow" -> {
                val samples = call.argument<Int>("samples") ?: 0
                if (enginePtr != 0L) nativeSetLineSamplesPerRow(enginePtr, samples)
                result.success(null)
            }
            "consumePendingRowAdvances" -> {
                result.success(if (enginePtr != 0L) nativeConsumePendingRowAdvances(enginePtr) else 0)
            }
            "resetPlayheadPhase" -> {
                if (enginePtr != 0L) nativeResetPlayheadPhase(enginePtr)
                result.success(null)
            }
            "clearQueuedPlaybackRows" -> {
                if (enginePtr != 0L) nativeClearQueuedPlaybackRows(enginePtr)
                result.success(null)
            }
            "setQueuedPlaybackLooping" -> {
                val loop = call.argument<Boolean>("loop") ?: false
                if (enginePtr != 0L) nativeSetQueuedPlaybackLooping(enginePtr, loop)
                result.success(null)
            }
            "enqueuePlaybackRow" -> {
                val lineSamples = call.argument<Int>("lineSamples") ?: 0
                @Suppress("UNCHECKED_CAST")
                val rowData = call.argument<List<Int>>("rowData") ?: emptyList()
                @Suppress("UNCHECKED_CAST")
                val immediateKillMask = call.argument<List<Int>>("immediateKillMask") ?: emptyList()
                @Suppress("UNCHECKED_CAST")
                val retrigData = call.argument<List<Int>>("retrigData") ?: emptyList()
                @Suppress("UNCHECKED_CAST")
                val arpData = call.argument<List<Int>>("arpData") ?: emptyList()
                @Suppress("UNCHECKED_CAST")
                val delayData = call.argument<List<Int>>("delayData") ?: emptyList()
                @Suppress("UNCHECKED_CAST")
                val killData = call.argument<List<Int>>("killData") ?: emptyList()
                @Suppress("UNCHECKED_CAST")
                val sliceCommandData = call.argument<List<Int>>("sliceCommandData") ?: emptyList()
                @Suppress("UNCHECKED_CAST")
                val mixerCommandData = call.argument<List<Int>>("mixerCommandData") ?: emptyList()
                @Suppress("UNCHECKED_CAST")
                val insertFxCommandData = call.argument<List<Int>>("insertFxCommandData") ?: emptyList()
                if (enginePtr != 0L) {
                    nativeEnqueuePlaybackRow(
                        enginePtr,
                        lineSamples,
                        rowData.toIntArray(),
                        immediateKillMask.toIntArray(),
                        retrigData.toIntArray(),
                        arpData.toIntArray(),
                        delayData.toIntArray(),
                        killData.toIntArray(),
                        sliceCommandData.toIntArray(),
                        mixerCommandData.toIntArray(),
                        insertFxCommandData.toIntArray(),
                    )
                }
                result.success(null)
            }
            "setRowData" -> {
                @Suppress("UNCHECKED_CAST")
                val data = call.argument<List<Int>>("data") ?: emptyList()
                if (enginePtr != 0L) nativeSetRowData(enginePtr, data.toIntArray())
                result.success(null)
            }
            "killVoices" -> {
                @Suppress("UNCHECKED_CAST")
                val mask = call.argument<List<Int>>("mask") ?: emptyList()
                if (enginePtr != 0L) nativeKillVoices(enginePtr, mask.toIntArray())
                result.success(null)
            }
            "queueRetrigs" -> {
                @Suppress("UNCHECKED_CAST")
                val data = call.argument<List<Int>>("data") ?: emptyList()
                if (enginePtr != 0L) nativeQueueRetrigs(enginePtr, data.toIntArray())
                result.success(null)
            }
            "queueArp" -> {
                @Suppress("UNCHECKED_CAST")
                val data = call.argument<List<Int>>("data") ?: emptyList()
                if (enginePtr != 0L) nativeQueueArp(enginePtr, data.toIntArray())
                result.success(null)
            }
            "queueDelays" -> {
                @Suppress("UNCHECKED_CAST")
                val data = call.argument<List<Int>>("data") ?: emptyList()
                if (enginePtr != 0L) nativeQueueDelays(enginePtr, data.toIntArray())
                result.success(null)
            }
            "queueKills" -> {
                @Suppress("UNCHECKED_CAST")
                val data = call.argument<List<Int>>("data") ?: emptyList()
                if (enginePtr != 0L) nativeQueueKills(enginePtr, data.toIntArray())
                result.success(null)
            }
            "queueSliceCommands" -> {
                @Suppress("UNCHECKED_CAST")
                val data = call.argument<List<Int>>("data") ?: emptyList()
                if (enginePtr != 0L) nativeQueueSliceCommands(enginePtr, data.toIntArray())
                result.success(null)
            }
            "queueMixerCommands" -> {
                @Suppress("UNCHECKED_CAST")
                val data = call.argument<List<Int>>("data") ?: emptyList()
                if (enginePtr != 0L) nativeQueueMixerCommands(enginePtr, data.toIntArray())
                result.success(null)
            }
            "queueInsertFxCommands" -> {
                @Suppress("UNCHECKED_CAST")
                val data = call.argument<List<Int>>("data") ?: emptyList()
                if (enginePtr != 0L) nativeQueueInsertFxCommands(enginePtr, data.toIntArray())
                result.success(null)
            }
            "setMasterInsertEffect" -> {
                val slotIdx = call.argument<Int>("slotIdx") ?: 0
                val effectType = call.argument<Int>("effectType") ?: -1
                val dryWet = call.argument<Double>("dryWet") ?: 0.5
                if (enginePtr != 0L) nativeSetMasterInsertEffect(enginePtr, slotIdx, effectType, dryWet.toFloat())
                result.success(null)
            }
            "setMasterInsertMix" -> {
                val slotIdx = call.argument<Int>("slotIdx") ?: 0
                val dryLevel = call.argument<Double>("dryLevel") ?: 1.0
                val wetLevel = call.argument<Double>("wetLevel") ?: 0.3
                if (enginePtr != 0L) nativeSetMasterInsertMix(enginePtr, slotIdx, dryLevel.toFloat(), wetLevel.toFloat())
                result.success(null)
            }
            "setMasterInsertBypass" -> {
                val slotIdx = call.argument<Int>("slotIdx") ?: 0
                val bypass = call.argument<Boolean>("bypass") ?: false
                if (enginePtr != 0L) nativeSetMasterInsertBypass(enginePtr, slotIdx, bypass)
                result.success(null)
            }
            "setMasterReverbParams" -> {
                val slotIdx = call.argument<Int>("slotIdx") ?: 0
                val roomSize = call.argument<Double>("roomSize") ?: 0.5
                val damp = call.argument<Double>("damp") ?: 0.5
                val width = call.argument<Double>("width") ?: 1.0
                val freeze = call.argument<Boolean>("freeze") ?: false
                if (enginePtr != 0L) nativeSetMasterReverbParams(enginePtr, slotIdx, roomSize.toFloat(), damp.toFloat(), width.toFloat(), freeze)
                result.success(null)
            }
            "setTrackInsertEffect" -> {
                val trackIdx = call.argument<Int>("trackIdx") ?: 0
                val slotIdx = call.argument<Int>("slotIdx") ?: 0
                val effectType = call.argument<Int>("effectType") ?: -1
                val dryWet = call.argument<Double>("dryWet") ?: 0.5
                if (enginePtr != 0L) nativeSetTrackInsertEffect(enginePtr, trackIdx, slotIdx, effectType, dryWet.toFloat())
                result.success(null)
            }
            "setTrackInsertMix" -> {
                val trackIdx = call.argument<Int>("trackIdx") ?: 0
                val slotIdx = call.argument<Int>("slotIdx") ?: 0
                val dryLevel = call.argument<Double>("dryLevel") ?: 1.0
                val wetLevel = call.argument<Double>("wetLevel") ?: 0.3
                if (enginePtr != 0L) nativeSetTrackInsertMix(enginePtr, trackIdx, slotIdx, dryLevel.toFloat(), wetLevel.toFloat())
                result.success(null)
            }
            "setTrackInsertBypass" -> {
                val trackIdx = call.argument<Int>("trackIdx") ?: 0
                val slotIdx = call.argument<Int>("slotIdx") ?: 0
                val bypass = call.argument<Boolean>("bypass") ?: false
                if (enginePtr != 0L) nativeSetTrackInsertBypass(enginePtr, trackIdx, slotIdx, bypass)
                result.success(null)
            }
            "setVoicePreviewBypassTrackInserts" -> {
                val trackIdx = call.argument<Int>("trackIdx") ?: 0
                val bypass = call.argument<Boolean>("bypass") ?: false
                if (enginePtr != 0L) nativeSetVoicePreviewBypassTrackInserts(enginePtr, trackIdx, bypass)
                result.success(null)
            }
            "setTrackReverbParams" -> {
                val trackIdx = call.argument<Int>("trackIdx") ?: 0
                val slotIdx = call.argument<Int>("slotIdx") ?: 0
                val roomSize = call.argument<Double>("roomSize") ?: 0.5
                val damp = call.argument<Double>("damp") ?: 0.5
                val width = call.argument<Double>("width") ?: 1.0
                val freeze = call.argument<Boolean>("freeze") ?: false
                if (enginePtr != 0L) nativeSetTrackReverbParams(enginePtr, trackIdx, slotIdx, roomSize.toFloat(), damp.toFloat(), width.toFloat(), freeze)
                result.success(null)
            }
            "setMasterDelayParams" -> {
                val slotIdx   = call.argument<Int>("slotIdx") ?: 0
                val timeMs    = call.argument<Double>("timeMs") ?: 375.0
                val feedback  = call.argument<Double>("feedback") ?: 0.4
                val hpCutoff  = call.argument<Double>("hpCutoff") ?: 0.0
                val sync      = call.argument<Boolean>("sync") ?: false
                if (enginePtr != 0L) nativeSetMasterDelayParams(enginePtr, slotIdx, timeMs.toFloat(), feedback.toFloat(), hpCutoff.toFloat(), sync)
                result.success(null)
            }
            "setTrackDelayParams" -> {
                val trackIdx  = call.argument<Int>("trackIdx") ?: 0
                val slotIdx   = call.argument<Int>("slotIdx") ?: 0
                val timeMs    = call.argument<Double>("timeMs") ?: 375.0
                val feedback  = call.argument<Double>("feedback") ?: 0.4
                val hpCutoff  = call.argument<Double>("hpCutoff") ?: 0.0
                val sync      = call.argument<Boolean>("sync") ?: false
                if (enginePtr != 0L) nativeSetTrackDelayParams(enginePtr, trackIdx, slotIdx, timeMs.toFloat(), feedback.toFloat(), hpCutoff.toFloat(), sync)
                result.success(null)
            }
            "setTrackFilterParams" -> {
                val trackIdx  = call.argument<Int>("trackIdx") ?: 0
                val slotIdx   = call.argument<Int>("slotIdx") ?: 0
                val cutoff    = call.argument<Double>("cutoff") ?: 0.5
                val resonance = call.argument<Double>("resonance") ?: 0.2
                val mode      = call.argument<Int>("mode") ?: 0
                if (enginePtr != 0L) nativeSetTrackFilterParams(enginePtr, trackIdx, slotIdx, cutoff.toFloat(), resonance.toFloat(), mode)
                result.success(null)
            }
            "setMasterFilterParams" -> {
                val slotIdx   = call.argument<Int>("slotIdx") ?: 0
                val cutoff    = call.argument<Double>("cutoff") ?: 0.5
                val resonance = call.argument<Double>("resonance") ?: 0.2
                val mode      = call.argument<Int>("mode") ?: 0
                if (enginePtr != 0L) nativeSetMasterFilterParams(enginePtr, slotIdx, cutoff.toFloat(), resonance.toFloat(), mode)
                result.success(null)
            }
            "setTrackDistortionParams" -> {
                val trackIdx = call.argument<Int>("trackIdx") ?: 0
                val slotIdx  = call.argument<Int>("slotIdx") ?: 0
                val drive    = call.argument<Double>("drive") ?: 0.5
                val tone     = call.argument<Double>("tone") ?: 0.5
                val distType = call.argument<Int>("distType") ?: 0
                if (enginePtr != 0L) nativeSetTrackDistortionParams(enginePtr, trackIdx, slotIdx, drive.toFloat(), tone.toFloat(), distType)
                result.success(null)
            }
            "setMasterDistortionParams" -> {
                val slotIdx  = call.argument<Int>("slotIdx") ?: 0
                val drive    = call.argument<Double>("drive") ?: 0.5
                val tone     = call.argument<Double>("tone") ?: 0.5
                val distType = call.argument<Int>("distType") ?: 0
                if (enginePtr != 0L) nativeSetMasterDistortionParams(enginePtr, slotIdx, drive.toFloat(), tone.toFloat(), distType)
                result.success(null)
            }
            "setTrackBitcrusherParams" -> {
                val trackIdx = call.argument<Int>("trackIdx") ?: 0
                val slotIdx  = call.argument<Int>("slotIdx") ?: 0
                val bits     = call.argument<Double>("bits") ?: 1.0
                val rate     = call.argument<Double>("rate") ?: 1.0
                if (enginePtr != 0L) nativeSetTrackBitcrusherParams(enginePtr, trackIdx, slotIdx, bits.toFloat(), rate.toFloat())
                result.success(null)
            }
            "setMasterBitcrusherParams" -> {
                val slotIdx = call.argument<Int>("slotIdx") ?: 0
                val bits    = call.argument<Double>("bits") ?: 1.0
                val rate    = call.argument<Double>("rate") ?: 1.0
                if (enginePtr != 0L) nativeSetMasterBitcrusherParams(enginePtr, slotIdx, bits.toFloat(), rate.toFloat())
                result.success(null)
            }
            "setTrackLimiterParams" -> {
                val trackIdx = call.argument<Int>("trackIdx") ?: 0
                val slotIdx  = call.argument<Int>("slotIdx") ?: 0
                val gain     = call.argument<Double>("gain") ?: 0.0
                if (enginePtr != 0L) nativeSetTrackLimiterParams(enginePtr, trackIdx, slotIdx, gain.toFloat())
                result.success(null)
            }
            "setMasterLimiterParams" -> {
                val slotIdx = call.argument<Int>("slotIdx") ?: 0
                val gain    = call.argument<Double>("gain") ?: 0.0
                if (enginePtr != 0L) nativeSetMasterLimiterParams(enginePtr, slotIdx, gain.toFloat())
                result.success(null)
            }
            "setTrackChorusParams" -> {
                val trackIdx = call.argument<Int>("trackIdx") ?: 0
                val slotIdx  = call.argument<Int>("slotIdx") ?: 0
                val rate     = call.argument<Double>("rate") ?: 0.3
                val depth    = call.argument<Double>("depth") ?: 0.5
                val delay    = call.argument<Double>("delay") ?: 0.3
                val stereo   = call.argument<Int>("stereo") ?: 0
                if (enginePtr != 0L) nativeSetTrackChorusParams(enginePtr, trackIdx, slotIdx, rate.toFloat(), depth.toFloat(), delay.toFloat(), stereo)
                result.success(null)
            }
            "setMasterChorusParams" -> {
                val slotIdx = call.argument<Int>("slotIdx") ?: 0
                val rate    = call.argument<Double>("rate") ?: 0.3
                val depth   = call.argument<Double>("depth") ?: 0.5
                val delay   = call.argument<Double>("delay") ?: 0.3
                val stereo  = call.argument<Int>("stereo") ?: 0
                if (enginePtr != 0L) nativeSetMasterChorusParams(enginePtr, slotIdx, rate.toFloat(), depth.toFloat(), delay.toFloat(), stereo)
                result.success(null)
            }
            "setTrackEqParams" -> {
                val trackIdx  = call.argument<Int>("trackIdx") ?: 0
                val slotIdx   = call.argument<Int>("slotIdx") ?: 0
                val lowGain   = call.argument<Double>("lowGain") ?: 0.0
                val lowFreq   = call.argument<Double>("lowFreq") ?: 0.2
                val midGain   = call.argument<Double>("midGain") ?: 0.0
                val midFreq   = call.argument<Double>("midFreq") ?: 0.3
                val midQ      = call.argument<Double>("midQ") ?: 0.3
                val highGain  = call.argument<Double>("highGain") ?: 0.0
                val highFreq  = call.argument<Double>("highFreq") ?: 0.5
                if (enginePtr != 0L) nativeSetTrackEqParams(enginePtr, trackIdx, slotIdx, lowGain.toFloat(), lowFreq.toFloat(), midGain.toFloat(), midFreq.toFloat(), midQ.toFloat(), highGain.toFloat(), highFreq.toFloat())
                result.success(null)
            }
            "setMasterEqParams" -> {
                val slotIdx   = call.argument<Int>("slotIdx") ?: 0
                val lowGain   = call.argument<Double>("lowGain") ?: 0.0
                val lowFreq   = call.argument<Double>("lowFreq") ?: 0.2
                val midGain   = call.argument<Double>("midGain") ?: 0.0
                val midFreq   = call.argument<Double>("midFreq") ?: 0.3
                val midQ      = call.argument<Double>("midQ") ?: 0.3
                val highGain  = call.argument<Double>("highGain") ?: 0.0
                val highFreq  = call.argument<Double>("highFreq") ?: 0.5
                if (enginePtr != 0L) nativeSetMasterEqParams(enginePtr, slotIdx, lowGain.toFloat(), lowFreq.toFloat(), midGain.toFloat(), midFreq.toFloat(), midQ.toFloat(), highGain.toFloat(), highFreq.toFloat())
                result.success(null)
            }
            "setTrackCompressorParams" -> {
                val trackIdx  = call.argument<Int>("trackIdx") ?: 0
                val slotIdx   = call.argument<Int>("slotIdx") ?: 0
                val threshold = call.argument<Double>("threshold") ?: 0.7
                val ratio     = call.argument<Double>("ratio") ?: 0.2
                val attack    = call.argument<Double>("attack") ?: 0.1
                val release   = call.argument<Double>("release") ?: 0.2
                val makeup    = call.argument<Double>("makeup") ?: 0.0
                val knee      = call.argument<Int>("knee") ?: 0
                if (enginePtr != 0L) nativeSetTrackCompressorParams(enginePtr, trackIdx, slotIdx, threshold.toFloat(), ratio.toFloat(), attack.toFloat(), release.toFloat(), makeup.toFloat(), knee)
                result.success(null)
            }
            "setMasterCompressorParams" -> {
                val slotIdx   = call.argument<Int>("slotIdx") ?: 0
                val threshold = call.argument<Double>("threshold") ?: 0.7
                val ratio     = call.argument<Double>("ratio") ?: 0.2
                val attack    = call.argument<Double>("attack") ?: 0.1
                val release   = call.argument<Double>("release") ?: 0.2
                val makeup    = call.argument<Double>("makeup") ?: 0.0
                val knee      = call.argument<Int>("knee") ?: 0
                if (enginePtr != 0L) nativeSetMasterCompressorParams(enginePtr, slotIdx, threshold.toFloat(), ratio.toFloat(), attack.toFloat(), release.toFloat(), makeup.toFloat(), knee)
                result.success(null)
            }
            "setSamplerSample" -> {
                val slot = call.argument<Int>("slot") ?: -1
                val path = call.argument<String>("path")
                val ok = if (enginePtr != 0L && slot >= 0) {
                    nativeSetSamplerSample(enginePtr, slot, path ?: "")
                } else false
                result.success(ok)
            }
            "openRecordingStream" -> {
                if (enginePtr != 0L) nativeOpenRecordingStream(enginePtr)
                result.success(null)
            }
            "closeRecordingStream" -> {
                if (enginePtr != 0L) nativeCloseRecordingStream(enginePtr)
                result.success(null)
            }
            "startRecording" -> {
                if (enginePtr != 0L) nativeStartRecording(enginePtr)
                result.success(null)
            }
            "stopRecording" -> {
                if (enginePtr != 0L) {
                    val sampleRateArray = IntArray(1)
                    val samples = nativeStopRecording(enginePtr, sampleRateArray)
                    val sampleRate = sampleRateArray[0]
                    result.success(mapOf(
                        "samples" to samples,
                        "sampleRate" to sampleRate
                    ))
                } else {
                    result.success(null)
                }
            }
            "isVoicePlaying" -> {
                val trackIdx = call.argument<Int>("trackIdx") ?: 0
                if (enginePtr != 0L) {
                    val isPlaying = nativeIsVoicePlaying(enginePtr, trackIdx)
                    result.success(isPlaying)
                } else {
                    result.success(false)
                }
            }
            "getVoiceEnvelopeStage" -> {
                val trackIdx = call.argument<Int>("trackIdx") ?: 0
                if (enginePtr != 0L) {
                    val stage = nativeGetVoiceEnvelopeStage(enginePtr, trackIdx)
                    result.success(stage)
                } else {
                    result.success(0)
                }
            }
            "getMeterValues" -> {
                if (enginePtr != 0L) {
                    result.success(nativeGetMeterValues(enginePtr).toList())
                } else {
                    result.success(List(34) { 0.0f })
                }
            }
            "startExportTap" -> {
                if (enginePtr != 0L) nativeStartExportTap(enginePtr)
                result.success(null)
            }
            "setSendRouting" -> {
                if (enginePtr != 0L) {
                    val routing = (call.arguments as List<*>)
                        .map { (it as Number).toInt() }
                        .toIntArray()
                    nativeSetSendRouting(enginePtr, routing)
                }
                result.success(null)
            }
            "stopExportTap" -> {
                if (enginePtr != 0L) {
                    val outRate = IntArray(1)
                    val samples = nativeStopExportTap(enginePtr, outRate)
                    result.success(mapOf(
                        "samples" to samples?.toList(),
                        "sampleRate" to outRate[0]
                    ))
                } else {
                    result.success(mapOf("samples" to emptyList<Float>(), "sampleRate" to 48000))
                }
            }
            "dispose" -> {
                if (enginePtr != 0L) {
                    nativeDispose(enginePtr)
                    enginePtr = 0L
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ── JNI declarations ─────────────────────────────────────────────────────

    private external fun nativeCreate(): Long
    private external fun nativeOpen(ptr: Long): Boolean
    private external fun nativeStart(ptr: Long)
    private external fun nativeStop(ptr: Long)
    private external fun nativeSetTempo(ptr: Long, bpm: Double)
    private external fun nativeSetLineSamplesPerRow(ptr: Long, samples: Int)
    private external fun nativeConsumePendingRowAdvances(ptr: Long): Int
    private external fun nativeResetPlayheadPhase(ptr: Long)
    private external fun nativeClearQueuedPlaybackRows(ptr: Long)
    private external fun nativeSetQueuedPlaybackLooping(ptr: Long, loop: Boolean)
    private external fun nativeEnqueuePlaybackRow(
        ptr: Long,
        lineSamples: Int,
        rowData: IntArray,
        immediateKillMask: IntArray,
        retrigData: IntArray,
        arpData: IntArray,
        delayData: IntArray,
        killData: IntArray,
        sliceCommandData: IntArray,
        mixerCommandData: IntArray,
        insertFxCommandData: IntArray,
    )
    private external fun nativeSetRowData(ptr: Long, data: IntArray)
    private external fun nativeKillVoices(ptr: Long, mask: IntArray)
    private external fun nativeQueueRetrigs(ptr: Long, data: IntArray)
    private external fun nativeQueueArp(ptr: Long, data: IntArray)
    private external fun nativeQueueDelays(ptr: Long, data: IntArray)
    private external fun nativeQueueKills(ptr: Long, data: IntArray)
    private external fun nativeQueueSliceCommands(ptr: Long, data: IntArray)
    private external fun nativeQueueMixerCommands(ptr: Long, data: IntArray)
    private external fun nativeQueueInsertFxCommands(ptr: Long, data: IntArray)
    private external fun nativeSetMasterInsertEffect(ptr: Long, slotIdx: Int, effectType: Int, dryWet: Float)
    private external fun nativeSetMasterInsertMix(ptr: Long, slotIdx: Int, dryLevel: Float, wetLevel: Float)
    private external fun nativeSetMasterInsertBypass(ptr: Long, slotIdx: Int, bypass: Boolean)
    private external fun nativeSetMasterReverbParams(ptr: Long, slotIdx: Int, roomSize: Float, damp: Float, width: Float, freeze: Boolean)
    private external fun nativeSetTrackInsertEffect(ptr: Long, trackIdx: Int, slotIdx: Int, effectType: Int, dryWet: Float)
    private external fun nativeSetTrackInsertMix(ptr: Long, trackIdx: Int, slotIdx: Int, dryLevel: Float, wetLevel: Float)
    private external fun nativeSetTrackInsertBypass(ptr: Long, trackIdx: Int, slotIdx: Int, bypass: Boolean)
    private external fun nativeSetVoicePreviewBypassTrackInserts(ptr: Long, trackIdx: Int, bypass: Boolean)
    private external fun nativeSetTrackReverbParams(ptr: Long, trackIdx: Int, slotIdx: Int, roomSize: Float, damp: Float, width: Float, freeze: Boolean)
    private external fun nativeSetMasterDelayParams(ptr: Long, slotIdx: Int, timeMs: Float, feedback: Float, hpCutoff: Float, sync: Boolean)
    private external fun nativeSetTrackDelayParams(ptr: Long, trackIdx: Int, slotIdx: Int, timeMs: Float, feedback: Float, hpCutoff: Float, sync: Boolean)
    private external fun nativeSetTrackFilterParams(ptr: Long, trackIdx: Int, slotIdx: Int, cutoff: Float, resonance: Float, mode: Int)
    private external fun nativeSetMasterFilterParams(ptr: Long, slotIdx: Int, cutoff: Float, resonance: Float, mode: Int)
    private external fun nativeSetTrackDistortionParams(ptr: Long, trackIdx: Int, slotIdx: Int, drive: Float, tone: Float, distType: Int)
    private external fun nativeSetMasterDistortionParams(ptr: Long, slotIdx: Int, drive: Float, tone: Float, distType: Int)
    private external fun nativeSetTrackBitcrusherParams(ptr: Long, trackIdx: Int, slotIdx: Int, bits: Float, rate: Float)
    private external fun nativeSetMasterBitcrusherParams(ptr: Long, slotIdx: Int, bits: Float, rate: Float)
    private external fun nativeSetTrackLimiterParams(ptr: Long, trackIdx: Int, slotIdx: Int, gain: Float)
    private external fun nativeSetMasterLimiterParams(ptr: Long, slotIdx: Int, gain: Float)
    private external fun nativeSetTrackChorusParams(ptr: Long, trackIdx: Int, slotIdx: Int, rate: Float, depth: Float, delay: Float, stereo: Int)
    private external fun nativeSetMasterChorusParams(ptr: Long, slotIdx: Int, rate: Float, depth: Float, delay: Float, stereo: Int)
    private external fun nativeSetTrackEqParams(ptr: Long, trackIdx: Int, slotIdx: Int, lowGain: Float, lowFreq: Float, midGain: Float, midFreq: Float, midQ: Float, highGain: Float, highFreq: Float)
    private external fun nativeSetMasterEqParams(ptr: Long, slotIdx: Int, lowGain: Float, lowFreq: Float, midGain: Float, midFreq: Float, midQ: Float, highGain: Float, highFreq: Float)
    private external fun nativeSetTrackCompressorParams(ptr: Long, trackIdx: Int, slotIdx: Int, threshold: Float, ratio: Float, attack: Float, release: Float, makeup: Float, knee: Int)
    private external fun nativeSetMasterCompressorParams(ptr: Long, slotIdx: Int, threshold: Float, ratio: Float, attack: Float, release: Float, makeup: Float, knee: Int)
    private external fun nativeSetSamplerSample(ptr: Long, slot: Int, path: String): Boolean
    private external fun nativeOpenRecordingStream(ptr: Long)
    private external fun nativeCloseRecordingStream(ptr: Long)
    private external fun nativeStartRecording(ptr: Long)
    private external fun nativeStopRecording(ptr: Long, outSampleRate: IntArray): FloatArray?
    private external fun nativeIsVoicePlaying(ptr: Long, trackIdx: Int): Boolean
    private external fun nativeGetVoiceEnvelopeStage(ptr: Long, trackIdx: Int): Int
    private external fun nativeGetMeterValues(ptr: Long): FloatArray
    private external fun nativeStartExportTap(ptr: Long)
    private external fun nativeStopExportTap(ptr: Long, outSampleRate: IntArray): FloatArray?
    private external fun nativeSetSendRouting(ptr: Long, routing: IntArray)
    private external fun nativeDispose(ptr: Long)

    companion object {
        const val CHANNEL_NAME = "com.example.tracker/audio"

        init {
            System.loadLibrary("tracker_audio")
        }
    }
}
