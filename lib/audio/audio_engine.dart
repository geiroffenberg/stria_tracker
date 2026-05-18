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

  /// Consume and return the number of row boundaries crossed natively since
  /// the last poll.
  Future<int> consumePendingRowAdvances() async {
    if (!_initialised) return 0;
    final result = await _channel.invokeMethod<int>('consumePendingRowAdvances');
    return result ?? 0;
  }

  /// Reset the native playhead phase so the current row timing restarts now.
  Future<void> resetPlayheadPhase() async {
    if (!_initialised) return;
    await _channel.invokeMethod('resetPlayheadPhase');
  }

  Future<void> clearQueuedPlaybackRows() async {
    if (!_initialised) return;
    await _channel.invokeMethod('clearQueuedPlaybackRows');
  }

  Future<void> setQueuedPlaybackLooping(bool loop) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setQueuedPlaybackLooping', {'loop': loop});
  }

  Future<void> enqueuePlaybackRow({
    required int lineSamples,
    required List<int> rowData,
    List<int> immediateKillMask = const [],
    List<int> retrigData = const [],
    List<int> arpData = const [],
    List<int> delayData = const [],
    List<int> killData = const [],
    List<int> sliceCommandData = const [],
    List<int> mixerCommandData = const [],
    List<int> insertFxCommandData = const [],
  }) async {
    if (!_initialised) return;
    await _channel.invokeMethod('enqueuePlaybackRow', {
      'lineSamples': lineSamples,
      'rowData': rowData,
      'immediateKillMask': immediateKillMask,
      'retrigData': retrigData,
      'arpData': arpData,
      'delayData': delayData,
      'killData': killData,
      'sliceCommandData': sliceCommandData,
      'mixerCommandData': mixerCommandData,
      'insertFxCommandData': insertFxCommandData,
    });
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
  /// channel: 0=master, 1-16=mixer channels
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

  /// Check if a voice (track) is currently playing.
  /// [trackIdx] is 0-15 (track index).
  /// Returns true if the voice has an active note or is in release stage.
  Future<bool> isVoicePlaying(int trackIdx) async {
    if (!_initialised) return false;
    final result = await _channel.invokeMethod<bool>('isVoicePlaying', {'trackIdx': trackIdx});
    return result ?? false;
  }

  /// Get the current envelope stage of a voice.
  /// [trackIdx] is 0-15 (track index).
  /// Returns: 0=Idle, 1=Attack, 2=Decay, 3=Sustain, 4=Release
  Future<int> getVoiceEnvelopeStage(int trackIdx) async {
    if (!_initialised) return 0;
    final result = await _channel.invokeMethod<int>('getVoiceEnvelopeStage', {'trackIdx': trackIdx});
    return result ?? 0;
  }

  /// Return packed stereo peak meter values as linear amplitudes.
  /// Layout: [track0L..track15L, track0R..track15R, masterL, masterR].
  Future<List<double>> getMeterValues() async {
    if (!_initialised) return List<double>.filled(34, 0.0);
    final result = await _channel.invokeListMethod<dynamic>('getMeterValues');
    if (result == null || result.length != 34) {
      return List<double>.filled(34, 0.0);
    }
    return result.map((value) => (value as num).toDouble()).toList(growable: false);
  }

  /// Begin capturing the stereo master output into an internal buffer.
  /// Call before starting song playback for WAV export.
  Future<void> startExportTap() async {
    if (!_initialised) return;
    await _channel.invokeMethod('startExportTap');
  }

  /// Set the send routing for all tracks. [routingPerTrack] is one int per
  /// track: 0=route to master, 1-16=route audio into that channel's bus.
  Future<void> setSendRouting(List<int> routingPerTrack) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setSendRouting', routingPerTrack);
  }

  /// Stop capturing and return the captured interleaved stereo float samples
  /// and the stream sample rate. Returns null samples on failure.
  Future<({List<double> samples, int sampleRate})> stopExportTap() async {
    if (!_initialised) return (samples: const <double>[], sampleRate: 48000);
    final result = await _channel.invokeMethod<Map>('stopExportTap');
    final rawSamples = result?['samples'] as List? ?? const [];
    final sampleRate = (result?['sampleRate'] as int?) ?? 48000;
    final samples = rawSamples.map((e) => (e as num).toDouble()).toList();
    return (samples: samples, sampleRate: sampleRate);
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
  /// [trackIdx] is 0-15 (track index), [slotIdx] is 0-5.
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

  Future<void> setVoicePreviewBypassTrackInserts(int trackIdx, bool bypass) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setVoicePreviewBypassTrackInserts', {
      'trackIdx': trackIdx,
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

  /// Configure delay parameters on a master insert effect slot (type 1).
  Future<void> setMasterDelayParams(int slotIdx, double timeMs, double feedback, double hpCutoff, bool sync) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setMasterDelayParams', {
      'slotIdx': slotIdx,
      'timeMs': timeMs,
      'feedback': feedback,
      'hpCutoff': hpCutoff,
      'sync': sync,
    });
  }

  /// Configure delay parameters on a track insert effect slot (type 1).
  Future<void> setTrackDelayParams(int trackIdx, int slotIdx, double timeMs, double feedback, double hpCutoff, bool sync) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setTrackDelayParams', {
      'trackIdx': trackIdx,
      'slotIdx': slotIdx,
      'timeMs': timeMs,
      'feedback': feedback,
      'hpCutoff': hpCutoff,
      'sync': sync,
    });
  }

  /// Configure filter parameters on a track insert effect slot (type 2).
  Future<void> setTrackFilterParams(int trackIdx, int slotIdx, double cutoff, double resonance, int mode) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setTrackFilterParams', {
      'trackIdx': trackIdx,
      'slotIdx': slotIdx,
      'cutoff': cutoff,
      'resonance': resonance,
      'mode': mode,
    });
  }

  Future<void> setMasterFilterParams(int slotIdx, double cutoff, double resonance, int mode) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setMasterFilterParams', {
      'slotIdx': slotIdx,
      'cutoff': cutoff,
      'resonance': resonance,
      'mode': mode,
    });
  }

  /// Configure distortion parameters on a track insert effect slot (type 3).
  Future<void> setTrackDistortionParams(int trackIdx, int slotIdx, double drive, double tone, int distType) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setTrackDistortionParams', {
      'trackIdx': trackIdx,
      'slotIdx': slotIdx,
      'drive': drive,
      'tone': tone,
      'distType': distType,
    });
  }

  Future<void> setMasterDistortionParams(int slotIdx, double drive, double tone, int distType) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setMasterDistortionParams', {
      'slotIdx': slotIdx,
      'drive': drive,
      'tone': tone,
      'distType': distType,
    });
  }

  /// Configure bitcrusher parameters on a track insert effect slot (type 4).
  Future<void> setTrackBitcrusherParams(int trackIdx, int slotIdx, double bits, double rate) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setTrackBitcrusherParams', {
      'trackIdx': trackIdx,
      'slotIdx': slotIdx,
      'bits': bits,
      'rate': rate,
    });
  }

  Future<void> setMasterBitcrusherParams(int slotIdx, double bits, double rate) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setMasterBitcrusherParams', {
      'slotIdx': slotIdx,
      'bits': bits,
      'rate': rate,
    });
  }

  Future<void> setTrackLimiterParams(int trackIdx, int slotIdx, double gain) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setTrackLimiterParams', {
      'trackIdx': trackIdx,
      'slotIdx': slotIdx,
      'gain': gain,
    });
  }

  Future<void> setMasterLimiterParams(int slotIdx, double gain) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setMasterLimiterParams', {
      'slotIdx': slotIdx,
      'gain': gain,
    });
  }

  Future<void> setTrackChorusParams(int trackIdx, int slotIdx, double rate, double depth, double delay, int stereo) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setTrackChorusParams', {
      'trackIdx': trackIdx,
      'slotIdx': slotIdx,
      'rate': rate,
      'depth': depth,
      'delay': delay,
      'stereo': stereo,
    });
  }

  Future<void> setMasterChorusParams(int slotIdx, double rate, double depth, double delay, int stereo) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setMasterChorusParams', {
      'slotIdx': slotIdx,
      'rate': rate,
      'depth': depth,
      'delay': delay,
      'stereo': stereo,
    });
  }

  Future<void> setTrackFlangerParams(int trackIdx, int slotIdx, double rate, double depth, double delay, double feedback, int stereo) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setTrackFlangerParams', {
      'trackIdx': trackIdx,
      'slotIdx': slotIdx,
      'rate': rate,
      'depth': depth,
      'delay': delay,
      'feedback': feedback,
      'stereo': stereo,
    });
  }

  Future<void> setMasterFlangerParams(int slotIdx, double rate, double depth, double delay, double feedback, int stereo) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setMasterFlangerParams', {
      'slotIdx': slotIdx,
      'rate': rate,
      'depth': depth,
      'delay': delay,
      'feedback': feedback,
      'stereo': stereo,
    });
  }

  Future<void> setTrackEqParams(int trackIdx, int slotIdx,
      double lowGain, double lowFreq,
      double midGain, double midFreq, double midQ,
      double highGain, double highFreq) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setTrackEqParams', {
      'trackIdx': trackIdx,
      'slotIdx': slotIdx,
      'lowGain': lowGain,
      'lowFreq': lowFreq,
      'midGain': midGain,
      'midFreq': midFreq,
      'midQ': midQ,
      'highGain': highGain,
      'highFreq': highFreq,
    });
  }

  Future<void> setMasterEqParams(int slotIdx,
      double lowGain, double lowFreq,
      double midGain, double midFreq, double midQ,
      double highGain, double highFreq) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setMasterEqParams', {
      'slotIdx': slotIdx,
      'lowGain': lowGain,
      'lowFreq': lowFreq,
      'midGain': midGain,
      'midFreq': midFreq,
      'midQ': midQ,
      'highGain': highGain,
      'highFreq': highFreq,
    });
  }

  Future<void> setTrackCompressorParams(int trackIdx, int slotIdx,
      double threshold, double ratio, double attack, double release,
      double makeup, int knee) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setTrackCompressorParams', {
      'trackIdx': trackIdx,
      'slotIdx': slotIdx,
      'threshold': threshold,
      'ratio': ratio,
      'attack': attack,
      'release': release,
      'makeup': makeup,
      'knee': knee,
    });
  }

  Future<void> setMasterCompressorParams(int slotIdx,
      double threshold, double ratio, double attack, double release,
      double makeup, int knee) async {
    if (!_initialised) return;
    await _channel.invokeMethod('setMasterCompressorParams', {
      'slotIdx': slotIdx,
      'threshold': threshold,
      'ratio': ratio,
      'attack': attack,
      'release': release,
      'makeup': makeup,
      'knee': knee,
    });
  }

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

  /// Apply (or remove) offline beat-sync time-stretching for a sampler slot.
  ///
  /// [slot] — instrument slot index (0-based).
  /// [enabled] — true = stretch to [beats]; false = restore original audio.
  /// [beats] — target beat length (1–99).
  /// [bpm] — project BPM snapshot at the moment of baking (not live-linked).
  /// [preservePitch] — reserved for future SoundTouch integration; currently
  ///                   ignored (speed and pitch are linked in Method A).
  ///
  /// Runs on a Kotlin background thread; awaiting this future blocks until done.
  Future<void> updateStretch({
    required int slot,
    required bool enabled,
    required int beats,
    required double bpm,
    required bool preservePitch,
  }) async {
    if (!_initialised) return;
    await _channel.invokeMethod<void>('updateStretch', {
      'slot': slot,
      'enabled': enabled,
      'beats': beats,
      'bpm': bpm,
      'preservePitch': preservePitch,
    });
  }

  /// Open the mic input stream and keep it warm (no accumulation).
  /// Call when entering the recording UI. Avoids Android duplex-mode transients
  /// that would otherwise appear at the start of the first RECORD take.
  Future<void> openRecordingStream() async {
    if (!_initialised) return;
    await _channel.invokeMethod('openRecordingStream');
  }

  /// Close the persistent mic input stream.
  /// Call when leaving the recording UI.
  Future<void> closeRecordingStream() async {
    if (!_initialised) return;
    await _channel.invokeMethod('closeRecordingStream');
  }

  /// Start accumulating mic input into the buffer (stream must already be open).
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
