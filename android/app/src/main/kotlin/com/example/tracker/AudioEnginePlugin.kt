package com.example.tracker

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
            "setSamplerSample" -> {
                val slot = call.argument<Int>("slot") ?: -1
                val path = call.argument<String>("path")
                val ok = if (enginePtr != 0L && slot >= 0) {
                    nativeSetSamplerSample(enginePtr, slot, path ?: "")
                } else false
                result.success(ok)
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
    private external fun nativeSetTrackReverbParams(ptr: Long, trackIdx: Int, slotIdx: Int, roomSize: Float, damp: Float, width: Float, freeze: Boolean)
    private external fun nativeSetSamplerSample(ptr: Long, slot: Int, path: String): Boolean
    private external fun nativeStartRecording(ptr: Long)
    private external fun nativeStopRecording(ptr: Long, outSampleRate: IntArray): FloatArray?
    private external fun nativeDispose(ptr: Long)

    companion object {
        const val CHANNEL_NAME = "com.example.tracker/audio"

        init {
            System.loadLibrary("tracker_audio")
        }
    }
}
