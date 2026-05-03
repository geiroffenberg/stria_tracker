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
  /// [note, volume, pan, wave, instrumentType, detune, cutoff, resonance, filterMode,
  ///  filterAttack, filterDecay, filterSustain, filterRelease, filterEnvAmt,
  ///  attack, decay, sustain, release, glide, instVol,
  ///  lfoRate, lfoDepth, lfoTarget, drive, ...].
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

  /// Kill voices on specific tracks. [killMask] has one entry per track:
  /// 1 = trigger note-off, 0 = leave playing.
  Future<void> killVoices(List<int> killMask) async {
    if (!_initialised) return;
    await _channel.invokeMethod('killVoices', {'mask': killMask});
  }

  /// Assigns a sample file to a sampler instrument slot.
  /// [slot] is 0-based instrument index.
  /// Pass null or empty [path] to clear sample assignment.
  /// Returns true on success, false if the file could not be loaded.
  Future<bool> setSamplerSample(int slot, String? path) async {
    if (!_initialised) return false;
    final result = await _channel.invokeMethod<bool>('setSamplerSample', {
      'slot': slot,
      'path': path,
    });
    return result ?? false;
  }

  /// Start recording audio from the output mix to buffer.
  Future<void> startRecording() async {
    if (!_initialised) return;
    await _channel.invokeMethod('startRecording');
  }

  /// Stop recording and return the recorded samples.
  /// Returns a map with 'samples' (List<double>) and 'sampleRate' (int).
  Future<Map<String, dynamic>?> stopRecording() async {
    if (!_initialised) return null;
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('stopRecording');
    if (result == null) return null;
    
    // Convert to proper types
    return {
      'samples': (result['samples'] as List?)?.cast<double>() ?? [],
      'sampleRate': result['sampleRate'] as int? ?? 44100,
    };
  }

  Future<void> dispose() async {
    if (!_initialised) return;
    await _channel.invokeMethod('dispose');
    _initialised = false;
  }
}
