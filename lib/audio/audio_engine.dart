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
  /// [rowData] is packed per track as
  /// [note, volume, pan, wave, cutoff, resonance,
  ///  filterAttack, filterDecay, filterSustain, filterRelease, filterEnvAmt,
  ///  attack, decay, sustain, release, glide, instVol, ...].
  /// note: 0-127 MIDI, -1 empty/hold, -2 OFF.
  /// volume: 0-255 sets level, -1 leaves current level unchanged.
  /// pan: 0-255 sets position, -1 leaves pan unchanged.
  /// wave: 0=sine,1=triangle,2=saw,3=square,4=pulse,5=noise.
  /// cutoff/resonance/filterAttack/filterDecay/filterSustain/filterRelease/
  /// filterEnvAmt/attack/decay/sustain/release/glide/instVol:
  ///   0-255 mapped from instrument params.
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
