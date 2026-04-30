import 'package:flutter/services.dart';

/// Dart-side interface to the native Oboe audio engine.
/// All methods are no-ops until the native side is initialised.
class AudioEngine {
  static const MethodChannel _channel =
      MethodChannel('com.example.tracker/audio');

  static final AudioEngine instance = AudioEngine._();
  AudioEngine._();

  bool _initialised = false;

  Future<void> initialize() async {
    if (_initialised) return;
    try {
      await _channel.invokeMethod('initialize');
      _initialised = true;
    } on PlatformException catch (e) {
      // Native audio not available (e.g., desktop debug); fail silently.
      // ignore: avoid_print
      print('[AudioEngine] init failed: ${e.message}');
    }
  }

  Future<void> start() async {
    if (!_initialised) return;
    await _channel.invokeMethod('start');
  }

  Future<void> stop() async {
    if (!_initialised) return;
    await _channel.invokeMethod('stop');
  }

  Future<void> setTempo(double bpm) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setTempo', {'bpm': bpm});
  }

  /// Feed the current pattern row data to the engine so it knows what to play.
  /// [rowData] is a flat list of note MIDI values (0-127) per track,
  /// with -1 meaning empty and -2 meaning OFF.
  Future<void> setRowData(List<int> rowData) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setRowData', {'data': rowData});
  }

  Future<void> dispose() async {
    if (!_initialised) return;
    await _channel.invokeMethod('dispose');
    _initialised = false;
  }
}
