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
            "setRowData" -> {
                @Suppress("UNCHECKED_CAST")
                val data = call.argument<List<Int>>("data") ?: emptyList()
                if (enginePtr != 0L) nativeSetRowData(enginePtr, data.toIntArray())
                result.success(null)
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
    private external fun nativeSetRowData(ptr: Long, data: IntArray)
    private external fun nativeDispose(ptr: Long)

    companion object {
        const val CHANNEL_NAME = "com.example.tracker/audio"

        init {
            System.loadLibrary("tracker_audio")
        }
    }
}
