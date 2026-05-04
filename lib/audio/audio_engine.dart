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

  /// Set the current line duration in samples (must be called before queueDelays/queueKills).
  /// This allows the C++ engine to convert delay/kill percentages to sample-accurate offsets.
  Future<void> setLineSamplesPerRow(int samples) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setLineSamplesPerRow', {'samples': samples});
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

  /// Queue sample-accurate retrigger events for the current row.
  /// [data] is packed in groups of 4: [sampleOffset, trackIdx, note, volume].
  /// The C++ engine fires each event when its sample offset is reached inside
  /// the audio callback — giving buffer-level precision (~5 ms) instead of
  /// relying on Dart Timer jitter.
  Future<void> queueRetrigs(List<int> data) async {
    if (!_initialised) return;
    await _channel.invokeMethod('queueRetrigs', {'data': data});
  }

  /// Queue sample-accurate pitch-only ARP events for the current row.
  /// [data] is packed in groups of 3: [sampleOffset, trackIdx, note].
  /// The C++ engine applies these as pitch-only updates without retriggering
  /// envelopes, preserving ARP smoothness while improving timing precision.
  Future<void> queueArp(List<int> data) async {
    if (!_initialised) return;
    await _channel.invokeMethod('queueArp', {'data': data});
  }

  /// Queue sample-accurate delayed note events (DEL).
  /// [data] is packed in groups of 4: [delayPct, trackIdx, note, volume].
  /// The C++ engine converts the delay percentage to a sample-accurate offset.
  Future<void> queueDelays(List<int> data) async {
    if (!_initialised) return;
    await _channel.invokeMethod('queueDelays', {'data': data});
  }

  /// Queue sample-accurate kill events (KIL).
  /// [data] is packed in groups of 2: [killPct, trackIdx].
  /// The C++ engine converts the kill percentage to a sample-accurate offset.
  Future<void> queueKills(List<int> data) async {
    if (!_initialised) return;
    await _channel.invokeMethod('queueKills', {'data': data});
  }

  /// Queue sample-accurate slice commands (SLC).
  /// [data] is packed in groups of 4: [playMode, trackIdx, startNormScaled, endNormScaled].
  /// startNormScaled and endNormScaled are normalized positions scaled by 10000.
  Future<void> queueSliceCommands(List<int> data) async {
    if (!_initialised) return;
    await _channel.invokeMethod('queueSliceCommands', {'data': data});
  }

  /// Queue mixer control commands (M01-M99).
  /// [data] is packed in groups of 4: [channel, controller, value, unused].
  /// channel: 0=master, 1-15=mixer channels
  /// controller: 1-4 for pan/mute/solo/volume (or reserved 5-9 for future)
  /// value: 0-99 (normalized parameter value)
  Future<void> queueMixerCommands(List<int> data) async {
    if (!_initialised) return;
    await _channel.invokeMethod('queueMixerCommands', {'data': data});
  }

  /// Queue own-channel insert FX commands (F11-F69).
  /// [data] is packed in groups of 4: [trackIdx, slotIdx, function, value].
  /// slotIdx is 0-5, function is 1-9, value is 0-99.
  Future<void> queueInsertFxCommands(List<int> data) async {
    if (!_initialised) return;
    await _channel.invokeMethod('queueInsertFxCommands', {'data': data});
  }

  /// Configure a master bus insert effect.
  /// [slotIdx] is 0-5 (6 insert slots).
  /// [effectType] is -1=empty, 0=reverb.
  /// [dryWet] is 0.0-1.0 (0=all dry, 1.0=all wet).
  Future<void> setMasterInsertEffect(int slotIdx, int effectType, double dryWet) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setMasterInsertEffect', {
      'slotIdx': slotIdx,
      'effectType': effectType,
      'dryWet': dryWet,
    });
  }

  Future<void> setMasterInsertMix(int slotIdx, double dryLevel, double wetLevel) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setMasterInsertMix', {
      'slotIdx': slotIdx,
      'dryLevel': dryLevel,
      'wetLevel': wetLevel,
    });
  }

  Future<void> setMasterInsertBypass(int slotIdx, bool bypass) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setMasterInsertBypass', {
      'slotIdx': slotIdx,
      'bypass': bypass,
    });
  }

  /// Configure reverb parameters on a master insert effect.
  /// [roomSize], [damp], [width] are 0.0-1.0.
  Future<void> setMasterReverbParams(int slotIdx, double roomSize, double damp, double width, bool freeze) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setMasterReverbParams', {
      'slotIdx': slotIdx,
      'roomSize': roomSize,
      'damp': damp,
      'width': width,
      'freeze': freeze,
    });
  }

  /// Configure a track insert effect.
  /// [trackIdx] is 0-7 (track index), [slotIdx] is 0-5.
  Future<void> setTrackInsertEffect(int trackIdx, int slotIdx, int effectType, double dryWet) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setTrackInsertEffect', {
      'trackIdx': trackIdx,
      'slotIdx': slotIdx,
      'effectType': effectType,
      'dryWet': dryWet,
    });
  }

  Future<void> setTrackInsertMix(int trackIdx, int slotIdx, double dryLevel, double wetLevel) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setTrackInsertMix', {
      'trackIdx': trackIdx,
      'slotIdx': slotIdx,
      'dryLevel': dryLevel,
      'wetLevel': wetLevel,
    });
  }

  Future<void> setTrackInsertBypass(int trackIdx, int slotIdx, bool bypass) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setTrackInsertBypass', {
      'trackIdx': trackIdx,
      'slotIdx': slotIdx,
      'bypass': bypass,
    });
  }

  /// Configure reverb parameters on a track insert effect.
  Future<void> setTrackReverbParams(int trackIdx, int slotIdx, double roomSize, double damp, double width, bool freeze) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setTrackReverbParams', {
      'trackIdx': trackIdx,
      'slotIdx': slotIdx,
      'roomSize': roomSize,
      'damp': damp,
      'width': width,
      'freeze': freeze,
    });
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
  /// Returns a map with 'samples' (list of doubles) and 'sampleRate' (int).
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
