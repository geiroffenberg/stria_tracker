import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../audio/audio_engine.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

class _ReverbUiState {
  final double roomSize;
  final double damp;
  final double width;
  final double dry;
  final double wet;
  final bool freeze;

  const _ReverbUiState({
    this.roomSize = 0.5,
    this.damp = 0.5,
    this.width = 1.0,
    this.dry = 1.0,
    this.wet = 0.3,
    this.freeze = false,
  });

  _ReverbUiState copyWith({
    double? roomSize,
    double? damp,
    double? width,
    double? dry,
    double? wet,
    bool? freeze,
  }) {
    return _ReverbUiState(
      roomSize: roomSize ?? this.roomSize,
      damp: damp ?? this.damp,
      width: width ?? this.width,
      dry: dry ?? this.dry,
      wet: wet ?? this.wet,
      freeze: freeze ?? this.freeze,
    );
  }
}

class _DelayUiState {
  final double timeMs; // 1–2000 ms
  final double feedback; // 0.0–0.95
  final double hpCutoff; // 0.0–1.0 (0 = off)
  final double dry;
  final double wet;
  final bool sync;

  const _DelayUiState({
    this.timeMs = 375.0,
    this.feedback = 0.4,
    this.hpCutoff = 0.0,
    this.dry = 1.0,
    this.wet = 0.35,
    this.sync = false,
  });

  _DelayUiState copyWith({
    double? timeMs,
    double? feedback,
    double? hpCutoff,
    double? dry,
    double? wet,
    bool? sync,
  }) {
    return _DelayUiState(
      timeMs: timeMs ?? this.timeMs,
      feedback: feedback ?? this.feedback,
      hpCutoff: hpCutoff ?? this.hpCutoff,
      dry: dry ?? this.dry,
      wet: wet ?? this.wet,
      sync: sync ?? this.sync,
    );
  }
}

class _FilterUiState {
  final double cutoff; // 0..1
  final double resonance; // 0..1
  final int mode; // 0=LP 1=HP 2=BP
  final double dry;
  final double wet;

  const _FilterUiState({
    this.cutoff = 0.5,
    this.resonance = 0.2,
    this.mode = 0,
    this.dry = 1.0,
    this.wet = 1.0,
  });

  _FilterUiState copyWith({
    double? cutoff,
    double? resonance,
    int? mode,
    double? dry,
    double? wet,
  }) => _FilterUiState(
    cutoff: cutoff ?? this.cutoff,
    resonance: resonance ?? this.resonance,
    mode: mode ?? this.mode,
    dry: dry ?? this.dry,
    wet: wet ?? this.wet,
  );
}

class _DistortionUiState {
  final double drive; // 0..1
  final double tone; // 0..1
  final int distType; // 0=soft-clip 1=fold
  final double dry;
  final double wet;

  const _DistortionUiState({
    this.drive = 0.5,
    this.tone = 0.5,
    this.distType = 0,
    this.dry = 1.0,
    this.wet = 1.0,
  });

  _DistortionUiState copyWith({
    double? drive,
    double? tone,
    int? distType,
    double? dry,
    double? wet,
  }) => _DistortionUiState(
    drive: drive ?? this.drive,
    tone: tone ?? this.tone,
    distType: distType ?? this.distType,
    dry: dry ?? this.dry,
    wet: wet ?? this.wet,
  );
}

class _BitcrusherUiState {
  final double bits; // 0..1  (1.0 = 16-bit, 0.0 = 1-bit)
  final double rate; // 0..1  (1.0 = no downsampling)
  final double dry;
  final double wet;

  const _BitcrusherUiState({
    this.bits = 1.0,
    this.rate = 1.0,
    this.dry = 1.0,
    this.wet = 1.0,
  });

  _BitcrusherUiState copyWith({
    double? bits,
    double? rate,
    double? dry,
    double? wet,
  }) => _BitcrusherUiState(
    bits: bits ?? this.bits,
    rate: rate ?? this.rate,
    dry: dry ?? this.dry,
    wet: wet ?? this.wet,
  );
}

class _LimiterUiState {
  final double gain; // 0..1  (0.0 = 0 dB unity, 1.0 = +24 dB push)
  final double dry;
  final double wet;

  const _LimiterUiState({
    this.gain = 0.0,
    this.dry = 0.0, // default: fully wet (limiter in-line)
    this.wet = 1.0,
  });

  _LimiterUiState copyWith({double? gain, double? dry, double? wet}) =>
      _LimiterUiState(
        gain: gain ?? this.gain,
        dry: dry ?? this.dry,
        wet: wet ?? this.wet,
      );
}

class _ChorusUiState {
  final double rate; // 0..1 → 0.1..8 Hz
  final double depth; // 0..1 → 0..15 ms
  final double delay; // 0..1 → 1..30 ms base
  final int stereo; // 0=mono, 1=stereo
  final double dry;
  final double wet;

  const _ChorusUiState({
    this.rate = 0.3,
    this.depth = 0.5,
    this.delay = 0.3,
    this.stereo = 0,
    this.dry = 0.0,
    this.wet = 1.0,
  });

  _ChorusUiState copyWith({
    double? rate,
    double? depth,
    double? delay,
    int? stereo,
    double? dry,
    double? wet,
  }) => _ChorusUiState(
    rate: rate ?? this.rate,
    depth: depth ?? this.depth,
    delay: delay ?? this.delay,
    stereo: stereo ?? this.stereo,
    dry: dry ?? this.dry,
    wet: wet ?? this.wet,
  );
}

class _EqUiState {
  final double lowGain; // −1..+1 → −12..+12 dB
  final double lowFreq; // 0..1 → 40..500 Hz
  final double midGain; // −1..+1 → −12..+12 dB
  final double midFreq; // 0..1 → 200..8000 Hz
  final double midQ; // 0..1 → 0.3..8.0
  final double highGain; // −1..+1 → −12..+12 dB
  final double highFreq; // 0..1 → 2000..16000 Hz
  final double dry;
  final double wet;

  const _EqUiState({
    this.lowGain = 0.0,
    this.lowFreq = 0.2,
    this.midGain = 0.0,
    this.midFreq = 0.3,
    this.midQ = 0.3,
    this.highGain = 0.0,
    this.highFreq = 0.5,
    this.dry = 0.0,
    this.wet = 1.0,
  });

  _EqUiState copyWith({
    double? lowGain,
    double? lowFreq,
    double? midGain,
    double? midFreq,
    double? midQ,
    double? highGain,
    double? highFreq,
    double? dry,
    double? wet,
  }) => _EqUiState(
    lowGain: lowGain ?? this.lowGain,
    lowFreq: lowFreq ?? this.lowFreq,
    midGain: midGain ?? this.midGain,
    midFreq: midFreq ?? this.midFreq,
    midQ: midQ ?? this.midQ,
    highGain: highGain ?? this.highGain,
    highFreq: highFreq ?? this.highFreq,
    dry: dry ?? this.dry,
    wet: wet ?? this.wet,
  );
}

class _CompressorUiState {
  final double threshold; // 0..1 → −60..0 dBFS
  final double ratio; // 0..1 → 1:1..20:1
  final double attack; // 0..1 → 0.1..200 ms
  final double release; // 0..1 → 10..2000 ms
  final double makeup; // 0..1 → 0..+24 dB
  final int knee; // 0=hard, 1=soft
  final double dry;
  final double wet;

  const _CompressorUiState({
    this.threshold = 0.7,
    this.ratio = 0.2,
    this.attack = 0.1,
    this.release = 0.2,
    this.makeup = 0.0,
    this.knee = 0,
    this.dry = 0.0,
    this.wet = 1.0,
  });

  _CompressorUiState copyWith({
    double? threshold,
    double? ratio,
    double? attack,
    double? release,
    double? makeup,
    int? knee,
    double? dry,
    double? wet,
  }) => _CompressorUiState(
    threshold: threshold ?? this.threshold,
    ratio: ratio ?? this.ratio,
    attack: attack ?? this.attack,
    release: release ?? this.release,
    makeup: makeup ?? this.makeup,
    knee: knee ?? this.knee,
    dry: dry ?? this.dry,
    wet: wet ?? this.wet,
  );
}

/// Mixer screen — one channel strip per track.
///
/// Pure UI scaffolding for now: faders/knobs/mute/solo are visual only.
/// Wiring to the audio engine will come once Oboe playback is in place.
class MixerScreen extends StatefulWidget {
  const MixerScreen({super.key});

  @override
  State<MixerScreen> createState() => _MixerScreenState();
}

class _MixerScreenState extends State<MixerScreen> {
  // Insert slots are still local placeholders for now.
  late List<List<String?>> _inserts; // [track][slot] => fx name or null
  late List<List<bool>> _trackBypassed; // [track][slot]
  late List<List<_ReverbUiState>> _trackReverbStates; // [track][slot]
  late List<List<_DelayUiState>> _trackDelayStates; // [track][slot]
  late List<List<_FilterUiState>> _trackFilterStates;
  late List<List<_DistortionUiState>> _trackDistortionStates;
  late List<List<_BitcrusherUiState>> _trackBitcrusherStates;
  late List<List<_LimiterUiState>> _trackLimiterStates;
  late List<List<_ChorusUiState>> _trackChorusStates;
  late List<List<_EqUiState>> _trackEqStates;
  late List<List<_CompressorUiState>> _trackCompressorStates;
  final List<String?> _masterInserts = List<String?>.filled(kInsertSlots, null);
  final List<bool> _masterBypassed = List<bool>.filled(kInsertSlots, false);
  final List<_ReverbUiState> _masterReverbStates = List.generate(
    kInsertSlots,
    (_) => const _ReverbUiState(),
  );
  final List<_DelayUiState> _masterDelayStates = List.generate(
    kInsertSlots,
    (_) => const _DelayUiState(),
  );
  final List<_FilterUiState> _masterFilterStates = List.generate(
    kInsertSlots,
    (_) => const _FilterUiState(),
  );
  final List<_DistortionUiState> _masterDistortionStates = List.generate(
    kInsertSlots,
    (_) => const _DistortionUiState(),
  );
  final List<_BitcrusherUiState> _masterBitcrusherStates = List.generate(
    kInsertSlots,
    (_) => const _BitcrusherUiState(),
  );
  final List<_LimiterUiState> _masterLimiterStates = List.generate(
    kInsertSlots,
    (_) => const _LimiterUiState(),
  );
  final List<_ChorusUiState> _masterChorusStates = List.generate(
    kInsertSlots,
    (_) => const _ChorusUiState(),
  );
  final List<_EqUiState> _masterEqStates = List.generate(
    kInsertSlots,
    (_) => const _EqUiState(),
  );
  final List<_CompressorUiState> _masterCompressorStates = List.generate(
    kInsertSlots,
    (_) => const _CompressorUiState(),
  );
  bool _insertsInitialized = false;
  int _seenSongStateVersion = -1;

  static const int kInsertSlots = 6;

  AppState? _boundAppState;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newState = AppStateScope.of(context);
    if (_boundAppState != newState) {
      _boundAppState?.removeListener(_handleInsertResets);
      _boundAppState = newState;
      _boundAppState!.addListener(_handleInsertResets);
      // Drain any resets queued while mixer screen was not mounted.
      _handleInsertResets();
    }
  }

  @override
  void dispose() {
    _boundAppState?.removeListener(_handleInsertResets);
    super.dispose();
  }

  /// Called whenever AppState notifies. Drains pending F[S]0 reset requests
  /// by re-sending the current Dart slider values to native, then clears them.
  void _handleInsertResets() {
    final state = _boundAppState;
    if (state == null) return;
    final resets = state.pendingInsertResets;
    if (resets.isEmpty) return;
    for (final (trackIdx, slotIdx) in resets) {
      if (trackIdx >= _inserts.length) continue;
      final effectName = _inserts[trackIdx][slotIdx];
      if (effectName == 'REVERB') {
        final r = _trackReverbStates[trackIdx][slotIdx];
        AudioEngine.instance.setTrackInsertMix(trackIdx, slotIdx, r.dry, r.wet);
        AudioEngine.instance.setTrackReverbParams(
          trackIdx,
          slotIdx,
          r.roomSize,
          r.damp,
          r.width,
          r.freeze,
        );
        if (_trackBypassed[trackIdx][slotIdx]) {
          AudioEngine.instance.setTrackInsertBypass(trackIdx, slotIdx, false);
          setState(() => _trackBypassed[trackIdx][slotIdx] = false);
        }
      } else if (effectName == 'DELAY') {
        final d = _trackDelayStates[trackIdx][slotIdx];
        AudioEngine.instance.setTrackInsertMix(trackIdx, slotIdx, d.dry, d.wet);
        AudioEngine.instance.setTrackDelayParams(
          trackIdx,
          slotIdx,
          d.timeMs,
          d.feedback,
          d.hpCutoff,
          d.sync,
        );
        if (_trackBypassed[trackIdx][slotIdx]) {
          AudioEngine.instance.setTrackInsertBypass(trackIdx, slotIdx, false);
          setState(() => _trackBypassed[trackIdx][slotIdx] = false);
        }
      } else if (effectName == 'FILTER') {
        final f = _trackFilterStates[trackIdx][slotIdx];
        AudioEngine.instance.setTrackInsertMix(trackIdx, slotIdx, f.dry, f.wet);
        AudioEngine.instance.setTrackFilterParams(
          trackIdx,
          slotIdx,
          f.cutoff,
          f.resonance,
          f.mode,
        );
        if (_trackBypassed[trackIdx][slotIdx]) {
          AudioEngine.instance.setTrackInsertBypass(trackIdx, slotIdx, false);
          setState(() => _trackBypassed[trackIdx][slotIdx] = false);
        }
      } else if (effectName == 'DISTORTION') {
        final d = _trackDistortionStates[trackIdx][slotIdx];
        AudioEngine.instance.setTrackInsertMix(trackIdx, slotIdx, d.dry, d.wet);
        AudioEngine.instance.setTrackDistortionParams(
          trackIdx,
          slotIdx,
          d.drive,
          d.tone,
          d.distType,
        );
        if (_trackBypassed[trackIdx][slotIdx]) {
          AudioEngine.instance.setTrackInsertBypass(trackIdx, slotIdx, false);
          setState(() => _trackBypassed[trackIdx][slotIdx] = false);
        }
      } else if (effectName == 'BITCRUSHER') {
        final b = _trackBitcrusherStates[trackIdx][slotIdx];
        AudioEngine.instance.setTrackInsertMix(trackIdx, slotIdx, b.dry, b.wet);
        AudioEngine.instance.setTrackBitcrusherParams(
          trackIdx,
          slotIdx,
          b.bits,
          b.rate,
        );
        if (_trackBypassed[trackIdx][slotIdx]) {
          AudioEngine.instance.setTrackInsertBypass(trackIdx, slotIdx, false);
          setState(() => _trackBypassed[trackIdx][slotIdx] = false);
        }
      } else if (effectName == 'LIMITER') {
        final l = _trackLimiterStates[trackIdx][slotIdx];
        AudioEngine.instance.setTrackInsertMix(trackIdx, slotIdx, l.dry, l.wet);
        AudioEngine.instance.setTrackLimiterParams(trackIdx, slotIdx, l.gain);
        if (_trackBypassed[trackIdx][slotIdx]) {
          AudioEngine.instance.setTrackInsertBypass(trackIdx, slotIdx, false);
          setState(() => _trackBypassed[trackIdx][slotIdx] = false);
        }
      } else if (effectName == 'CHORUS') {
        final c = _trackChorusStates[trackIdx][slotIdx];
        AudioEngine.instance.setTrackInsertMix(trackIdx, slotIdx, c.dry, c.wet);
        AudioEngine.instance.setTrackChorusParams(
          trackIdx,
          slotIdx,
          c.rate,
          c.depth,
          c.delay,
          c.stereo,
        );
        if (_trackBypassed[trackIdx][slotIdx]) {
          AudioEngine.instance.setTrackInsertBypass(trackIdx, slotIdx, false);
          setState(() => _trackBypassed[trackIdx][slotIdx] = false);
        }
      } else if (effectName == 'EQ') {
        final e = _trackEqStates[trackIdx][slotIdx];
        AudioEngine.instance.setTrackInsertMix(trackIdx, slotIdx, e.dry, e.wet);
        AudioEngine.instance.setTrackEqParams(
          trackIdx,
          slotIdx,
          e.lowGain,
          e.lowFreq,
          e.midGain,
          e.midFreq,
          e.midQ,
          e.highGain,
          e.highFreq,
        );
        if (_trackBypassed[trackIdx][slotIdx]) {
          AudioEngine.instance.setTrackInsertBypass(trackIdx, slotIdx, false);
          setState(() => _trackBypassed[trackIdx][slotIdx] = false);
        }
      } else if (effectName == 'COMPRESSOR') {
        final c = _trackCompressorStates[trackIdx][slotIdx];
        AudioEngine.instance.setTrackInsertMix(trackIdx, slotIdx, c.dry, c.wet);
        AudioEngine.instance.setTrackCompressorParams(
          trackIdx,
          slotIdx,
          c.threshold,
          c.ratio,
          c.attack,
          c.release,
          c.makeup,
          c.knee,
        );
        if (_trackBypassed[trackIdx][slotIdx]) {
          AudioEngine.instance.setTrackInsertBypass(trackIdx, slotIdx, false);
          setState(() => _trackBypassed[trackIdx][slotIdx] = false);
        }
      }
    }
    state.clearInsertResets();
  }

  Future<void> _openReverbEditor({
    required bool onMaster,
    int? trackIdx,
    required int slotIdx,
  }) async {
    final initialBypass = onMaster
        ? _masterBypassed[slotIdx]
        : _trackBypassed[trackIdx!][slotIdx];
    final initialState = onMaster
        ? _masterReverbStates[slotIdx]
        : _trackReverbStates[trackIdx!][slotIdx];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBgTrackHeader,
      isScrollControlled: true,
      builder: (_) => _ReverbEffectEditor(
        onMaster: onMaster,
        trackIdx: trackIdx,
        slotIdx: slotIdx,
        initialBypass: initialBypass,
        initialState: initialState,
        onBypassChanged: (b) {
          setState(() {
            if (onMaster) {
              _masterBypassed[slotIdx] = b;
            } else {
              _trackBypassed[trackIdx!][slotIdx] = b;
            }
          });
        },
        onParamsChanged: (state) {
          setState(() {
            if (onMaster) {
              _masterReverbStates[slotIdx] = state;
            } else {
              _trackReverbStates[trackIdx!][slotIdx] = state;
            }
          });
        },
      ),
    );
  }

  Future<void> _openDelayEditor({
    required bool onMaster,
    int? trackIdx,
    required int slotIdx,
  }) async {
    final initialBypass = onMaster
        ? _masterBypassed[slotIdx]
        : _trackBypassed[trackIdx!][slotIdx];
    final initialState = onMaster
        ? _masterDelayStates[slotIdx]
        : _trackDelayStates[trackIdx!][slotIdx];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBgTrackHeader,
      isScrollControlled: true,
      builder: (_) => _DelayEffectEditor(
        onMaster: onMaster,
        trackIdx: trackIdx,
        slotIdx: slotIdx,
        initialBypass: initialBypass,
        initialState: initialState,
        onBypassChanged: (b) {
          setState(() {
            if (onMaster) {
              _masterBypassed[slotIdx] = b;
            } else {
              _trackBypassed[trackIdx!][slotIdx] = b;
            }
          });
        },
        onParamsChanged: (s) {
          setState(() {
            if (onMaster) {
              _masterDelayStates[slotIdx] = s;
            } else {
              _trackDelayStates[trackIdx!][slotIdx] = s;
            }
          });
        },
      ),
    );
  }

  Future<void> _openFilterEditor({
    required bool onMaster,
    int? trackIdx,
    required int slotIdx,
  }) async {
    final initialBypass = onMaster
        ? _masterBypassed[slotIdx]
        : _trackBypassed[trackIdx!][slotIdx];
    final initialState = onMaster
        ? _masterFilterStates[slotIdx]
        : _trackFilterStates[trackIdx!][slotIdx];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBgTrackHeader,
      isScrollControlled: true,
      builder: (_) => _FilterEffectEditor(
        onMaster: onMaster,
        trackIdx: trackIdx,
        slotIdx: slotIdx,
        initialBypass: initialBypass,
        initialState: initialState,
        onBypassChanged: (b) => setState(() {
          if (onMaster) {
            _masterBypassed[slotIdx] = b;
          } else {
            _trackBypassed[trackIdx!][slotIdx] = b;
          }
        }),
        onParamsChanged: (s) => setState(() {
          if (onMaster) {
            _masterFilterStates[slotIdx] = s;
          } else {
            _trackFilterStates[trackIdx!][slotIdx] = s;
          }
        }),
      ),
    );
  }

  Future<void> _openDistortionEditor({
    required bool onMaster,
    int? trackIdx,
    required int slotIdx,
  }) async {
    final initialBypass = onMaster
        ? _masterBypassed[slotIdx]
        : _trackBypassed[trackIdx!][slotIdx];
    final initialState = onMaster
        ? _masterDistortionStates[slotIdx]
        : _trackDistortionStates[trackIdx!][slotIdx];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBgTrackHeader,
      isScrollControlled: true,
      builder: (_) => _DistortionEffectEditor(
        onMaster: onMaster,
        trackIdx: trackIdx,
        slotIdx: slotIdx,
        initialBypass: initialBypass,
        initialState: initialState,
        onBypassChanged: (b) => setState(() {
          if (onMaster) {
            _masterBypassed[slotIdx] = b;
          } else {
            _trackBypassed[trackIdx!][slotIdx] = b;
          }
        }),
        onParamsChanged: (s) => setState(() {
          if (onMaster) {
            _masterDistortionStates[slotIdx] = s;
          } else {
            _trackDistortionStates[trackIdx!][slotIdx] = s;
          }
        }),
      ),
    );
  }

  Future<void> _openBitcrusherEditor({
    required bool onMaster,
    int? trackIdx,
    required int slotIdx,
  }) async {
    final initialBypass = onMaster
        ? _masterBypassed[slotIdx]
        : _trackBypassed[trackIdx!][slotIdx];
    final initialState = onMaster
        ? _masterBitcrusherStates[slotIdx]
        : _trackBitcrusherStates[trackIdx!][slotIdx];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBgTrackHeader,
      isScrollControlled: true,
      builder: (_) => _BitcrusherEffectEditor(
        onMaster: onMaster,
        trackIdx: trackIdx,
        slotIdx: slotIdx,
        initialBypass: initialBypass,
        initialState: initialState,
        onBypassChanged: (b) => setState(() {
          if (onMaster) {
            _masterBypassed[slotIdx] = b;
          } else {
            _trackBypassed[trackIdx!][slotIdx] = b;
          }
        }),
        onParamsChanged: (s) => setState(() {
          if (onMaster) {
            _masterBitcrusherStates[slotIdx] = s;
          } else {
            _trackBitcrusherStates[trackIdx!][slotIdx] = s;
          }
        }),
      ),
    );
  }

  Future<void> _openLimiterEditor({
    required bool onMaster,
    int? trackIdx,
    required int slotIdx,
  }) async {
    final initialBypass = onMaster
        ? _masterBypassed[slotIdx]
        : _trackBypassed[trackIdx!][slotIdx];
    final initialState = onMaster
        ? _masterLimiterStates[slotIdx]
        : _trackLimiterStates[trackIdx!][slotIdx];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBgTrackHeader,
      isScrollControlled: true,
      builder: (_) => _LimiterEffectEditor(
        onMaster: onMaster,
        trackIdx: trackIdx,
        slotIdx: slotIdx,
        initialBypass: initialBypass,
        initialState: initialState,
        onBypassChanged: (b) => setState(() {
          if (onMaster) {
            _masterBypassed[slotIdx] = b;
          } else {
            _trackBypassed[trackIdx!][slotIdx] = b;
          }
        }),
        onParamsChanged: (s) => setState(() {
          if (onMaster) {
            _masterLimiterStates[slotIdx] = s;
          } else {
            _trackLimiterStates[trackIdx!][slotIdx] = s;
          }
        }),
      ),
    );
  }

  Future<void> _openChorusEditor({
    required bool onMaster,
    int? trackIdx,
    required int slotIdx,
  }) async {
    final initialBypass = onMaster
        ? _masterBypassed[slotIdx]
        : _trackBypassed[trackIdx!][slotIdx];
    final initialState = onMaster
        ? _masterChorusStates[slotIdx]
        : _trackChorusStates[trackIdx!][slotIdx];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBgTrackHeader,
      isScrollControlled: true,
      builder: (_) => _ChorusEffectEditor(
        onMaster: onMaster,
        trackIdx: trackIdx,
        slotIdx: slotIdx,
        initialBypass: initialBypass,
        initialState: initialState,
        onBypassChanged: (b) => setState(() {
          if (onMaster) {
            _masterBypassed[slotIdx] = b;
          } else {
            _trackBypassed[trackIdx!][slotIdx] = b;
          }
        }),
        onParamsChanged: (s) => setState(() {
          if (onMaster) {
            _masterChorusStates[slotIdx] = s;
          } else {
            _trackChorusStates[trackIdx!][slotIdx] = s;
          }
        }),
      ),
    );
  }

  Future<void> _openEqEditor({
    required bool onMaster,
    int? trackIdx,
    required int slotIdx,
  }) async {
    final initialBypass = onMaster
        ? _masterBypassed[slotIdx]
        : _trackBypassed[trackIdx!][slotIdx];
    final initialState = onMaster
        ? _masterEqStates[slotIdx]
        : _trackEqStates[trackIdx!][slotIdx];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBgTrackHeader,
      isScrollControlled: true,
      builder: (_) => _EqEffectEditor(
        onMaster: onMaster,
        trackIdx: trackIdx,
        slotIdx: slotIdx,
        initialBypass: initialBypass,
        initialState: initialState,
        onBypassChanged: (b) => setState(() {
          if (onMaster) {
            _masterBypassed[slotIdx] = b;
          } else {
            _trackBypassed[trackIdx!][slotIdx] = b;
          }
        }),
        onParamsChanged: (s) => setState(() {
          if (onMaster) {
            _masterEqStates[slotIdx] = s;
          } else {
            _trackEqStates[trackIdx!][slotIdx] = s;
          }
        }),
      ),
    );
  }

  Future<void> _openCompressorEditor({
    required bool onMaster,
    int? trackIdx,
    required int slotIdx,
  }) async {
    final initialBypass = onMaster
        ? _masterBypassed[slotIdx]
        : _trackBypassed[trackIdx!][slotIdx];
    final initialState = onMaster
        ? _masterCompressorStates[slotIdx]
        : _trackCompressorStates[trackIdx!][slotIdx];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBgTrackHeader,
      isScrollControlled: true,
      builder: (_) => _CompressorEffectEditor(
        onMaster: onMaster,
        trackIdx: trackIdx,
        slotIdx: slotIdx,
        initialBypass: initialBypass,
        initialState: initialState,
        onBypassChanged: (b) => setState(() {
          if (onMaster) {
            _masterBypassed[slotIdx] = b;
          } else {
            _trackBypassed[trackIdx!][slotIdx] = b;
          }
        }),
        onParamsChanged: (s) => setState(() {
          if (onMaster) {
            _masterCompressorStates[slotIdx] = s;
          } else {
            _trackCompressorStates[trackIdx!][slotIdx] = s;
          }
        }),
      ),
    );
  }

  void _ensureSized(int n) {
    if (_insertsInitialized && _inserts.length == n) return;
    _inserts = List.generate(
      n,
      (_) => List<String?>.filled(kInsertSlots, null),
    );
    _trackBypassed = List.generate(
      n,
      (_) => List<bool>.filled(kInsertSlots, false),
    );
    _trackReverbStates = List.generate(
      n,
      (_) => List<_ReverbUiState>.generate(
        kInsertSlots,
        (_) => const _ReverbUiState(),
      ),
    );
    _trackDelayStates = List.generate(
      n,
      (_) => List<_DelayUiState>.generate(
        kInsertSlots,
        (_) => const _DelayUiState(),
      ),
    );
    _trackFilterStates = List.generate(
      n,
      (_) => List<_FilterUiState>.generate(
        kInsertSlots,
        (_) => const _FilterUiState(),
      ),
    );
    _trackDistortionStates = List.generate(
      n,
      (_) => List<_DistortionUiState>.generate(
        kInsertSlots,
        (_) => const _DistortionUiState(),
      ),
    );
    _trackBitcrusherStates = List.generate(
      n,
      (_) => List<_BitcrusherUiState>.generate(
        kInsertSlots,
        (_) => const _BitcrusherUiState(),
      ),
    );
    _trackLimiterStates = List.generate(
      n,
      (_) => List<_LimiterUiState>.generate(
        kInsertSlots,
        (_) => const _LimiterUiState(),
      ),
    );
    _trackChorusStates = List.generate(
      n,
      (_) => List<_ChorusUiState>.generate(
        kInsertSlots,
        (_) => const _ChorusUiState(),
      ),
    );
    _trackEqStates = List.generate(
      n,
      (_) => List<_EqUiState>.generate(kInsertSlots, (_) => const _EqUiState()),
    );
    _trackCompressorStates = List.generate(
      n,
      (_) => List<_CompressorUiState>.generate(
        kInsertSlots,
        (_) => const _CompressorUiState(),
      ),
    );
    _insertsInitialized = true;
  }

  void _resetTrackInsertSlotState(int trackIdx, int slotIdx) {
    _trackBypassed[trackIdx][slotIdx] = false;
    _trackReverbStates[trackIdx][slotIdx] = const _ReverbUiState();
    _trackDelayStates[trackIdx][slotIdx] = const _DelayUiState();
    _trackFilterStates[trackIdx][slotIdx] = const _FilterUiState();
    _trackDistortionStates[trackIdx][slotIdx] = const _DistortionUiState();
    _trackBitcrusherStates[trackIdx][slotIdx] = const _BitcrusherUiState();
    _trackLimiterStates[trackIdx][slotIdx] = const _LimiterUiState();
    _trackChorusStates[trackIdx][slotIdx] = const _ChorusUiState();
    _trackEqStates[trackIdx][slotIdx] = const _EqUiState();
    _trackCompressorStates[trackIdx][slotIdx] = const _CompressorUiState();
  }

  void _resetMasterInsertState() {
    for (int slot = 0; slot < kInsertSlots; slot++) {
      _masterInserts[slot] = null;
      _masterBypassed[slot] = false;
      _masterReverbStates[slot] = const _ReverbUiState();
      _masterDelayStates[slot] = const _DelayUiState();
      _masterFilterStates[slot] = const _FilterUiState();
      _masterDistortionStates[slot] = const _DistortionUiState();
      _masterBitcrusherStates[slot] = const _BitcrusherUiState();
      _masterLimiterStates[slot] = const _LimiterUiState();
      _masterChorusStates[slot] = const _ChorusUiState();
      _masterEqStates[slot] = const _EqUiState();
      _masterCompressorStates[slot] = const _CompressorUiState();
    }
  }

  void _syncInsertStateFromAppState(AppState state) {
    final trackCount = state.currentPattern.tracks.length;
    _ensureSized(trackCount);

    if (_seenSongStateVersion != state.songStateVersion) {
      _resetMasterInsertState();
      for (int trackIdx = 0; trackIdx < trackCount; trackIdx++) {
        for (int slotIdx = 0; slotIdx < kInsertSlots; slotIdx++) {
          _inserts[trackIdx][slotIdx] = null;
          _resetTrackInsertSlotState(trackIdx, slotIdx);
        }
      }
      _seenSongStateVersion = state.songStateVersion;
    }

    for (int trackIdx = 0; trackIdx < trackCount; trackIdx++) {
      for (int slotIdx = 0; slotIdx < kInsertSlots; slotIdx++) {
        final effectName = state.trackInsertEffectName(trackIdx, slotIdx);
        if (_inserts[trackIdx][slotIdx] == effectName) continue;
        _inserts[trackIdx][slotIdx] = effectName;
        _resetTrackInsertSlotState(trackIdx, slotIdx);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final tracks = state.currentPattern.tracks;
    _syncInsertStateFromAppState(state);

    return Container(
      color: kBgColor,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Master strip (first, scrolls with tracks) ─────────────
            _MasterStrip(
              volume: state.masterVolume,
              muted: state.masterMute,
              inserts: _masterInserts,
              bypassed: _masterBypassed,
              onVolume: state.setMasterVolume,
              onMute: state.toggleMasterMute,
              onInsertTap: (slot) => _onMasterInsertTap(slot),
              onInsertClear: (slot) {
                setState(() {
                  _masterInserts[slot] = null;
                  _masterBypassed[slot] = false;
                  _masterReverbStates[slot] = const _ReverbUiState();
                  _masterDelayStates[slot] = const _DelayUiState();
                  _masterFilterStates[slot] = const _FilterUiState();
                  _masterDistortionStates[slot] = const _DistortionUiState();
                  _masterBitcrusherStates[slot] = const _BitcrusherUiState();
                  _masterLimiterStates[slot] = const _LimiterUiState();
                  _masterChorusStates[slot] = const _ChorusUiState();
                  _masterEqStates[slot] = const _EqUiState();
                  _masterCompressorStates[slot] = const _CompressorUiState();
                });
                AudioEngine.instance.setMasterInsertEffect(slot, -1, 0.0);
              },
            ),
            const SizedBox(width: 6),
            // ── Channel strips ─────────────────────────────────────────
            for (int i = 0; i < tracks.length; i++)
              _ChannelStrip(
                index: i,
                name: tracks[i].name,
                volume: tracks[i].mixerVolume,
                pan: tracks[i].mixerPan,
                muted: tracks[i].mixerMute,
                soloed: tracks[i].mixerSolo,
                inserts: _inserts[i],
                bypassed: _trackBypassed[i],
                sendChannel: tracks[i].sendChannel,
                isSendBus: state.isSendBus(i),
                onVolume: (v) => state.setTrackMixerVolume(i, v),
                onPan: (v) => state.setTrackMixerPan(i, v),
                onMute: () => state.toggleTrackMixerMute(i),
                onSolo: () => state.toggleTrackMixerSolo(i),
                onInsertTap: (slot) => _onInsertSlotTap(i, slot),
                onInsertClear: (slot) {
                  setState(() {
                    _inserts[i][slot] = null;
                    _resetTrackInsertSlotState(i, slot);
                  });
                  state.setTrackInsertEffectName(i, slot, null);
                  AudioEngine.instance.setTrackInsertEffect(i, slot, -1, 0.0);
                },
                onSendTap: () => _onSendTap(i, state),
              ),
          ],
        ),
      ),
    );
  }

  void _onSendTap(int trackIdx, AppState state) async {
    // Build choices: 0=Master, 1-8 valid channels excluding self and send buses
    final tracks = state.currentPattern.tracks;
    final numTracks = tracks.length;
    final choices = <int>[0]; // 0 = Master
    for (int ch = 1; ch <= numTracks; ch++) {
      if (ch == trackIdx + 1) continue; // no self-send
      choices.add(ch);
    }

    final currentSend = tracks[trackIdx].sendChannel;

    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(
          'SEND: T${(trackIdx + 1).toString().padLeft(2, '0')}',
          style: kStyleHeader.copyWith(color: kColAccent, fontSize: 13),
        ),
        children: choices.map((ch) {
          final label = ch == 0 ? 'MASTER' : 'CH ${ch.toString().padLeft(2, '0')}';
          final isCurrent = ch == currentSend;
          return SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(ch),
            child: Text(
              label,
              style: kStyleBase.copyWith(
                color: isCurrent ? kColAccent : kColHeader,
                fontWeight: isCurrent ? FontWeight.w700 : FontWeight.normal,
              ),
            ),
          );
        }).toList(),
      ),
    );

    if (picked != null) {
      state.setTrackSendChannel(trackIdx, picked);
    }
  }

  void _onInsertSlotTap(int trackIdx, int slotIdx) async {
    final state = AppStateScope.of(context);
    final currentFx = _inserts[trackIdx][slotIdx];
    if (currentFx == 'REVERB') {
      await _openReverbEditor(
        onMaster: false,
        trackIdx: trackIdx,
        slotIdx: slotIdx,
      );
      return;
    }
    if (currentFx == 'DELAY') {
      await _openDelayEditor(
        onMaster: false,
        trackIdx: trackIdx,
        slotIdx: slotIdx,
      );
      return;
    }
    if (currentFx == 'FILTER') {
      await _openFilterEditor(
        onMaster: false,
        trackIdx: trackIdx,
        slotIdx: slotIdx,
      );
      return;
    }
    if (currentFx == 'DISTORTION') {
      await _openDistortionEditor(
        onMaster: false,
        trackIdx: trackIdx,
        slotIdx: slotIdx,
      );
      return;
    }
    if (currentFx == 'BITCRUSHER') {
      await _openBitcrusherEditor(
        onMaster: false,
        trackIdx: trackIdx,
        slotIdx: slotIdx,
      );
      return;
    }
    if (currentFx == 'LIMITER') {
      await _openLimiterEditor(
        onMaster: false,
        trackIdx: trackIdx,
        slotIdx: slotIdx,
      );
      return;
    }
    if (currentFx == 'CHORUS') {
      await _openChorusEditor(
        onMaster: false,
        trackIdx: trackIdx,
        slotIdx: slotIdx,
      );
      return;
    }
    if (currentFx == 'EQ') {
      await _openEqEditor(
        onMaster: false,
        trackIdx: trackIdx,
        slotIdx: slotIdx,
      );
      return;
    }
    if (currentFx == 'COMPRESSOR') {
      await _openCompressorEditor(
        onMaster: false,
        trackIdx: trackIdx,
        slotIdx: slotIdx,
      );
      return;
    }

    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: kBgTrackHeader,
      builder: (_) => const _FxPicker(),
    );

    if (picked != null) {
      setState(() => _inserts[trackIdx][slotIdx] = picked);
      state.setTrackInsertEffectName(trackIdx, slotIdx, picked);

      if (picked == 'REVERB') {
        final rs = _trackReverbStates[trackIdx][slotIdx];
        await AudioEngine.instance.setTrackInsertEffect(
          trackIdx,
          slotIdx,
          0,
          rs.wet,
        );
        await AudioEngine.instance.setTrackInsertMix(
          trackIdx,
          slotIdx,
          rs.dry,
          rs.wet,
        );
        await AudioEngine.instance.setTrackReverbParams(
          trackIdx,
          slotIdx,
          rs.roomSize,
          rs.damp,
          rs.width,
          rs.freeze,
        );
        await _openReverbEditor(
          onMaster: false,
          trackIdx: trackIdx,
          slotIdx: slotIdx,
        );
      } else if (picked == 'DELAY') {
        final ds = _trackDelayStates[trackIdx][slotIdx];
        await AudioEngine.instance.setTrackInsertEffect(
          trackIdx,
          slotIdx,
          1,
          ds.wet,
        );
        await AudioEngine.instance.setTrackInsertMix(
          trackIdx,
          slotIdx,
          ds.dry,
          ds.wet,
        );
        await AudioEngine.instance.setTrackDelayParams(
          trackIdx,
          slotIdx,
          ds.timeMs,
          ds.feedback,
          ds.hpCutoff,
          ds.sync,
        );
        await _openDelayEditor(
          onMaster: false,
          trackIdx: trackIdx,
          slotIdx: slotIdx,
        );
      } else if (picked == 'FILTER') {
        final fs = _trackFilterStates[trackIdx][slotIdx];
        await AudioEngine.instance.setTrackInsertEffect(
          trackIdx,
          slotIdx,
          2,
          fs.wet,
        );
        await AudioEngine.instance.setTrackInsertMix(
          trackIdx,
          slotIdx,
          fs.dry,
          fs.wet,
        );
        await AudioEngine.instance.setTrackFilterParams(
          trackIdx,
          slotIdx,
          fs.cutoff,
          fs.resonance,
          fs.mode,
        );
        await _openFilterEditor(
          onMaster: false,
          trackIdx: trackIdx,
          slotIdx: slotIdx,
        );
      } else if (picked == 'DISTORTION') {
        final ds = _trackDistortionStates[trackIdx][slotIdx];
        await AudioEngine.instance.setTrackInsertEffect(
          trackIdx,
          slotIdx,
          3,
          ds.wet,
        );
        await AudioEngine.instance.setTrackInsertMix(
          trackIdx,
          slotIdx,
          ds.dry,
          ds.wet,
        );
        await AudioEngine.instance.setTrackDistortionParams(
          trackIdx,
          slotIdx,
          ds.drive,
          ds.tone,
          ds.distType,
        );
        await _openDistortionEditor(
          onMaster: false,
          trackIdx: trackIdx,
          slotIdx: slotIdx,
        );
      } else if (picked == 'BITCRUSHER') {
        final bs = _trackBitcrusherStates[trackIdx][slotIdx];
        await AudioEngine.instance.setTrackInsertEffect(
          trackIdx,
          slotIdx,
          4,
          bs.wet,
        );
        await AudioEngine.instance.setTrackInsertMix(
          trackIdx,
          slotIdx,
          bs.dry,
          bs.wet,
        );
        await AudioEngine.instance.setTrackBitcrusherParams(
          trackIdx,
          slotIdx,
          bs.bits,
          bs.rate,
        );
        await _openBitcrusherEditor(
          onMaster: false,
          trackIdx: trackIdx,
          slotIdx: slotIdx,
        );
      } else if (picked == 'LIMITER') {
        final ls = _trackLimiterStates[trackIdx][slotIdx];
        await AudioEngine.instance.setTrackInsertEffect(
          trackIdx,
          slotIdx,
          5,
          ls.wet,
        );
        await AudioEngine.instance.setTrackInsertMix(
          trackIdx,
          slotIdx,
          ls.dry,
          ls.wet,
        );
        await AudioEngine.instance.setTrackLimiterParams(
          trackIdx,
          slotIdx,
          ls.gain,
        );
        await _openLimiterEditor(
          onMaster: false,
          trackIdx: trackIdx,
          slotIdx: slotIdx,
        );
      } else if (picked == 'CHORUS') {
        final cs = _trackChorusStates[trackIdx][slotIdx];
        await AudioEngine.instance.setTrackInsertEffect(
          trackIdx,
          slotIdx,
          6,
          cs.wet,
        );
        await AudioEngine.instance.setTrackInsertMix(
          trackIdx,
          slotIdx,
          cs.dry,
          cs.wet,
        );
        await AudioEngine.instance.setTrackChorusParams(
          trackIdx,
          slotIdx,
          cs.rate,
          cs.depth,
          cs.delay,
          cs.stereo,
        );
        await _openChorusEditor(
          onMaster: false,
          trackIdx: trackIdx,
          slotIdx: slotIdx,
        );
      } else if (picked == 'EQ') {
        final es = _trackEqStates[trackIdx][slotIdx];
        await AudioEngine.instance.setTrackInsertEffect(
          trackIdx,
          slotIdx,
          7,
          es.wet,
        );
        await AudioEngine.instance.setTrackInsertMix(
          trackIdx,
          slotIdx,
          es.dry,
          es.wet,
        );
        await AudioEngine.instance.setTrackEqParams(
          trackIdx,
          slotIdx,
          es.lowGain,
          es.lowFreq,
          es.midGain,
          es.midFreq,
          es.midQ,
          es.highGain,
          es.highFreq,
        );
        await _openEqEditor(
          onMaster: false,
          trackIdx: trackIdx,
          slotIdx: slotIdx,
        );
      } else if (picked == 'COMPRESSOR') {
        final cs = _trackCompressorStates[trackIdx][slotIdx];
        await AudioEngine.instance.setTrackInsertEffect(
          trackIdx,
          slotIdx,
          8,
          cs.wet,
        );
        await AudioEngine.instance.setTrackInsertMix(
          trackIdx,
          slotIdx,
          cs.dry,
          cs.wet,
        );
        await AudioEngine.instance.setTrackCompressorParams(
          trackIdx,
          slotIdx,
          cs.threshold,
          cs.ratio,
          cs.attack,
          cs.release,
          cs.makeup,
          cs.knee,
        );
        await _openCompressorEditor(
          onMaster: false,
          trackIdx: trackIdx,
          slotIdx: slotIdx,
        );
      } else {
        // Non-implemented inserts are UI-only for now.
        await AudioEngine.instance.setTrackInsertEffect(
          trackIdx,
          slotIdx,
          -1,
          0.0,
        );
      }
    }
  }

  void _onMasterInsertTap(int slotIdx) async {
    final currentFx = _masterInserts[slotIdx];
    if (currentFx == 'REVERB') {
      await _openReverbEditor(onMaster: true, slotIdx: slotIdx);
      return;
    }
    if (currentFx == 'DELAY') {
      await _openDelayEditor(onMaster: true, slotIdx: slotIdx);
      return;
    }
    if (currentFx == 'FILTER') {
      await _openFilterEditor(onMaster: true, slotIdx: slotIdx);
      return;
    }
    if (currentFx == 'DISTORTION') {
      await _openDistortionEditor(onMaster: true, slotIdx: slotIdx);
      return;
    }
    if (currentFx == 'BITCRUSHER') {
      await _openBitcrusherEditor(onMaster: true, slotIdx: slotIdx);
      return;
    }
    if (currentFx == 'LIMITER') {
      await _openLimiterEditor(onMaster: true, slotIdx: slotIdx);
      return;
    }
    if (currentFx == 'CHORUS') {
      await _openChorusEditor(onMaster: true, slotIdx: slotIdx);
      return;
    }
    if (currentFx == 'EQ') {
      await _openEqEditor(onMaster: true, slotIdx: slotIdx);
      return;
    }
    if (currentFx == 'COMPRESSOR') {
      await _openCompressorEditor(onMaster: true, slotIdx: slotIdx);
      return;
    }

    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: kBgTrackHeader,
      builder: (_) => const _FxPicker(),
    );

    if (picked != null) {
      setState(() => _masterInserts[slotIdx] = picked);

      if (picked == 'REVERB') {
        final rs = _masterReverbStates[slotIdx];
        await AudioEngine.instance.setMasterInsertEffect(slotIdx, 0, rs.wet);
        await AudioEngine.instance.setMasterInsertMix(slotIdx, rs.dry, rs.wet);
        await AudioEngine.instance.setMasterReverbParams(
          slotIdx,
          rs.roomSize,
          rs.damp,
          rs.width,
          rs.freeze,
        );
        await _openReverbEditor(onMaster: true, slotIdx: slotIdx);
      } else if (picked == 'DELAY') {
        final ds = _masterDelayStates[slotIdx];
        await AudioEngine.instance.setMasterInsertEffect(slotIdx, 1, ds.wet);
        await AudioEngine.instance.setMasterInsertMix(slotIdx, ds.dry, ds.wet);
        await AudioEngine.instance.setMasterDelayParams(
          slotIdx,
          ds.timeMs,
          ds.feedback,
          ds.hpCutoff,
          ds.sync,
        );
        await _openDelayEditor(onMaster: true, slotIdx: slotIdx);
      } else if (picked == 'FILTER') {
        final fs = _masterFilterStates[slotIdx];
        await AudioEngine.instance.setMasterInsertEffect(slotIdx, 2, fs.wet);
        await AudioEngine.instance.setMasterInsertMix(slotIdx, fs.dry, fs.wet);
        await AudioEngine.instance.setMasterFilterParams(
          slotIdx,
          fs.cutoff,
          fs.resonance,
          fs.mode,
        );
        await _openFilterEditor(onMaster: true, slotIdx: slotIdx);
      } else if (picked == 'DISTORTION') {
        final ds = _masterDistortionStates[slotIdx];
        await AudioEngine.instance.setMasterInsertEffect(slotIdx, 3, ds.wet);
        await AudioEngine.instance.setMasterInsertMix(slotIdx, ds.dry, ds.wet);
        await AudioEngine.instance.setMasterDistortionParams(
          slotIdx,
          ds.drive,
          ds.tone,
          ds.distType,
        );
        await _openDistortionEditor(onMaster: true, slotIdx: slotIdx);
      } else if (picked == 'BITCRUSHER') {
        final bs = _masterBitcrusherStates[slotIdx];
        await AudioEngine.instance.setMasterInsertEffect(slotIdx, 4, bs.wet);
        await AudioEngine.instance.setMasterInsertMix(slotIdx, bs.dry, bs.wet);
        await AudioEngine.instance.setMasterBitcrusherParams(
          slotIdx,
          bs.bits,
          bs.rate,
        );
        await _openBitcrusherEditor(onMaster: true, slotIdx: slotIdx);
      } else if (picked == 'LIMITER') {
        final ls = _masterLimiterStates[slotIdx];
        await AudioEngine.instance.setMasterInsertEffect(slotIdx, 5, ls.wet);
        await AudioEngine.instance.setMasterInsertMix(slotIdx, ls.dry, ls.wet);
        await AudioEngine.instance.setMasterLimiterParams(slotIdx, ls.gain);
        await _openLimiterEditor(onMaster: true, slotIdx: slotIdx);
      } else if (picked == 'CHORUS') {
        final cs = _masterChorusStates[slotIdx];
        await AudioEngine.instance.setMasterInsertEffect(slotIdx, 6, cs.wet);
        await AudioEngine.instance.setMasterInsertMix(slotIdx, cs.dry, cs.wet);
        await AudioEngine.instance.setMasterChorusParams(
          slotIdx,
          cs.rate,
          cs.depth,
          cs.delay,
          cs.stereo,
        );
        await _openChorusEditor(onMaster: true, slotIdx: slotIdx);
      } else if (picked == 'EQ') {
        final es = _masterEqStates[slotIdx];
        await AudioEngine.instance.setMasterInsertEffect(slotIdx, 7, es.wet);
        await AudioEngine.instance.setMasterInsertMix(slotIdx, es.dry, es.wet);
        await AudioEngine.instance.setMasterEqParams(
          slotIdx,
          es.lowGain,
          es.lowFreq,
          es.midGain,
          es.midFreq,
          es.midQ,
          es.highGain,
          es.highFreq,
        );
        await _openEqEditor(onMaster: true, slotIdx: slotIdx);
      } else if (picked == 'COMPRESSOR') {
        final cs = _masterCompressorStates[slotIdx];
        await AudioEngine.instance.setMasterInsertEffect(slotIdx, 8, cs.wet);
        await AudioEngine.instance.setMasterInsertMix(slotIdx, cs.dry, cs.wet);
        await AudioEngine.instance.setMasterCompressorParams(
          slotIdx,
          cs.threshold,
          cs.ratio,
          cs.attack,
          cs.release,
          cs.makeup,
          cs.knee,
        );
        await _openCompressorEditor(onMaster: true, slotIdx: slotIdx);
      } else {
        await AudioEngine.instance.setMasterInsertEffect(slotIdx, -1, 0.0);
      }
    }
  }
}

class _FxPicker extends StatelessWidget {
  const _FxPicker();

  static const _options = <String>[
    'EQ',
    'COMPRESSOR',
    'REVERB',
    'DELAY',
    'CHORUS',
    'DISTORTION',
    'FILTER',
    'BITCRUSHER',
    'LIMITER',
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text(
                'SELECT FX',
                style: kStyleHeader.copyWith(color: kColAccent),
              ),
            ),
            const Divider(height: 1, color: Color(0xFF1A1A1A)),
            for (final fx in _options)
              ListTile(
                dense: true,
                title: Text(
                  fx,
                  style: kStyleBase.copyWith(fontSize: 14, color: kColHeader),
                ),
                onTap: () => Navigator.of(context).pop(fx),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Master strip ─────────────────────────────────────────────────────────────

class _MasterStrip extends StatelessWidget {
  final double volume;
  final bool muted;
  final List<String?> inserts;
  final List<bool> bypassed;
  final ValueChanged<double> onVolume;
  final VoidCallback onMute;
  final void Function(int slot) onInsertTap;
  final void Function(int slot) onInsertClear;

  const _MasterStrip({
    required this.volume,
    required this.muted,
    required this.inserts,
    required this.bypassed,
    required this.onVolume,
    required this.onMute,
    required this.onInsertTap,
    required this.onInsertClear,
  });

  @override
  Widget build(BuildContext context) {
    final db = volume <= 0
        ? '-INF'
        : (20 * (math.log(volume) / math.ln10)).toStringAsFixed(1);

    return Container(
      width: 76,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: kBgTrackHeader,
        border: Border.all(color: kColInactive.withAlpha(80), width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        children: [
          // ── Accent header band ──────────────────────────────────────
          Container(
            height: 20,
            decoration: BoxDecoration(
              color: kColAccent.withAlpha(40),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(3),
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              'MASTER',
              style: kStyleHeader.copyWith(
                color: kColAccent,
                fontSize: 10,
                letterSpacing: 2.0,
              ),
            ),
          ),
          // ── Mixer controls ──────────────────────────────────────────
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: [
                  const SizedBox(height: 4),
                  _MiniBtn(
                    label: 'M',
                    active: muted,
                    activeColor: kColRecBtn,
                    onTap: onMute,
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 8,
                          ),
                          overlayShape: SliderComponentShape.noOverlay,
                          activeTrackColor: kColComplement,
                          inactiveTrackColor: kColInactive,
                          thumbColor: kColComplement,
                        ),
                        child: Slider(value: volume, onChanged: onVolume),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${db}dB',
                    style: kStyleBase.copyWith(fontSize: 9, color: kColHeader),
                  ),
                ],
              ),
            ),
          ),
          // ── Divider ─────────────────────────────────────────────────
          Container(height: 1, color: kColAccent.withAlpha(60)),
          // ── FX insert slots ─────────────────────────────────────────
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
              child: Column(
                children: [
                  Text(
                    'FX',
                    style: kStyleHeader.copyWith(
                      color: kColAccent,
                      fontSize: 9,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: ListView.separated(
                      padding: EdgeInsets.zero,
                      itemCount: inserts.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 3),
                      itemBuilder: (_, slot) => _StripInsertSlot(
                        index: slot,
                        fxName: inserts[slot],
                        bypassed: bypassed[slot],
                        onTap: () => onInsertTap(slot),
                        onClear: () => onInsertClear(slot),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelStrip extends StatelessWidget {
  final int index;
  final String name;
  final double volume;
  final double pan;
  final bool muted;
  final bool soloed;
  final List<String?> inserts;
  final List<bool> bypassed;
  final int sendChannel; // 0=master, 1-8=channel number
  final bool isSendBus;
  final ValueChanged<double> onVolume;
  final ValueChanged<double> onPan;
  final VoidCallback onMute;
  final VoidCallback onSolo;
  final void Function(int slot) onInsertTap;
  final void Function(int slot) onInsertClear;
  final VoidCallback onSendTap;

  const _ChannelStrip({
    required this.index,
    required this.name,
    required this.volume,
    required this.pan,
    required this.muted,
    required this.soloed,
    required this.inserts,
    required this.bypassed,
    required this.sendChannel,
    required this.isSendBus,
    required this.onVolume,
    required this.onPan,
    required this.onMute,
    required this.onSolo,
    required this.onInsertTap,
    required this.onInsertClear,
    required this.onSendTap,
  });

  @override
  Widget build(BuildContext context) {
    final db = volume <= 0
        ? '-INF'
        : (20 * (volume == 0 ? -100 : (math.log(volume) / math.ln10)))
              .toStringAsFixed(1);

    return Container(
      width: 70,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: kBgTrackHeader,
        border: Border.all(color: kColInactive.withAlpha(80), width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        children: [
          // ── Top half: mixer controls ─────────────────────────────
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: [
                  Text(
                    'T${(index + 1).toString().padLeft(2, '0')}',
                    style: kStyleHeader.copyWith(color: kColHeader),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: kStyleBase.copyWith(fontSize: 10, color: kColHeader),
                  ),
                  const SizedBox(height: 6),
                  _PanKnob(value: pan, onChanged: onPan),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _MiniBtn(
                        label: 'M',
                        active: muted,
                        activeColor: kColRecBtn,
                        onTap: onMute,
                      ),
                      const SizedBox(width: 4),
                      _MiniBtn(
                        label: 'S',
                        active: soloed,
                        activeColor: kColPlayBtn,
                        onTap: onSolo,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 7,
                          ),
                          overlayShape: SliderComponentShape.noOverlay,
                          activeTrackColor: kColComplement,
                          inactiveTrackColor: kColInactive,
                          thumbColor: kColComplement,
                        ),
                        child: Slider(value: volume, onChanged: onVolume),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${db}dB',
                    style: kStyleBase.copyWith(fontSize: 9, color: kColHeader),
                  ),
                ],
              ),
            ),
          ),

          // ── Divider ──────────────────────────────────────────────
          Container(height: 1, color: kColInactive.withAlpha(120)),

          // ── Bottom half: per-strip FX insert slots ───────────────
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
              child: Column(
                children: [
                  Text(
                    'FX',
                    style: kStyleHeader.copyWith(
                      color: kColAccent,
                      fontSize: 9,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: ListView.separated(
                      padding: EdgeInsets.zero,
                      itemCount: inserts.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 3),
                      itemBuilder: (_, slot) => _StripInsertSlot(
                        index: slot,
                        fxName: inserts[slot],
                        bypassed: bypassed[slot],
                        onTap: () => onInsertTap(slot),
                        onClear: () => onInsertClear(slot),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // ── SEND destination button ──────────────────────
                  GestureDetector(
                    onTap: isSendBus ? null : onSendTap,
                    child: Container(
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: sendChannel > 0
                            ? kColComplement.withAlpha(40)
                            : Colors.transparent,
                        border: Border.all(
                          color: isSendBus
                              ? kColInactive.withAlpha(60)
                              : sendChannel > 0
                                  ? kColComplement
                                  : kColInactive.withAlpha(120),
                        ),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: Text(
                        sendChannel == 0
                            ? 'MST'
                            : 'CH ${sendChannel.toString().padLeft(2, '0')}',
                        style: kStyleBase.copyWith(
                          fontSize: 9,
                          letterSpacing: 0.5,
                          color: isSendBus
                              ? kColInactive.withAlpha(80)
                              : sendChannel > 0
                                  ? kColComplement
                                  : kColInactive,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StripInsertSlot extends StatelessWidget {
  final int index;
  final String? fxName;
  final bool bypassed;
  final VoidCallback onTap;
  final VoidCallback onClear;

  const _StripInsertSlot({
    required this.index,
    required this.fxName,
    required this.bypassed,
    required this.onTap,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final filled = fxName != null;
    final active = filled && !bypassed;
    return GestureDetector(
      onTap: onTap,
      onLongPress: filled ? onClear : null,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? kColAccent.withAlpha(30) : Colors.transparent,
          border: Border.all(
            color: active
                ? kColAccent
                : filled
                ? kColInactive.withAlpha(80)
                : kColInactive.withAlpha(120),
          ),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Text(
          filled ? fxName! : '·',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: kStyleBase.copyWith(
            fontSize: 10,
            letterSpacing: 0.3,
            color: active
                ? kColAccent
                : filled
                ? kColInactive
                : kColInactive,
            fontWeight: filled ? FontWeight.w700 : FontWeight.normal,
            decoration: bypassed && filled ? TextDecoration.lineThrough : null,
            decorationColor: kColInactive,
          ),
        ),
      ),
    );
  }
}

class _PanKnob extends StatelessWidget {
  final double value; // -1..1
  final ValueChanged<double> onChanged;
  const _PanKnob({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final label = value.abs() < 0.02
        ? 'C'
        : (value < 0
              ? 'L${(value.abs() * 100).round()}'
              : 'R${(value * 100).round()}');

    return GestureDetector(
      onHorizontalDragUpdate: (d) {
        final n = (value + d.delta.dx * 0.02).clamp(-1.0, 1.0);
        onChanged(n);
      },
      onDoubleTap: () => onChanged(0),
      child: Column(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: kBgColor,
              border: Border.all(color: kColInactive),
            ),
            child: CustomPaint(painter: _PanIndicator(value)),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: kStyleBase.copyWith(fontSize: 9, color: kColHeader),
          ),
        ],
      ),
    );
  }
}

class _PanIndicator extends CustomPainter {
  final double value;
  _PanIndicator(this.value);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 2;
    // angle: -135deg (full L) .. +135deg (full R)
    final angle = (-math.pi * 3 / 4) + ((value + 1) / 2) * (math.pi * 3 / 2);
    final p = Offset(
      center.dx + radius * math.cos(angle),
      center.dy + radius * math.sin(angle),
    );
    final paint = Paint()
      ..color = kColAccent
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, p, paint);
  }

  @override
  bool shouldRepaint(covariant _PanIndicator old) => old.value != value;
}

class _MiniBtn extends StatelessWidget {
  final String label;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;
  const _MiniBtn({
    required this.label,
    required this.active,
    required this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 22,
        height: 18,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? activeColor.withAlpha(60) : Colors.transparent,
          border: Border.all(color: active ? activeColor : kColInactive),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Text(
          label,
          style: kStyleBase.copyWith(
            fontSize: 10,
            color: active ? activeColor : kColHeader,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

// ── Reverb Effect Editor ─────────────────────────────────────────────────────

class _ReverbEffectEditor extends StatefulWidget {
  final bool onMaster; // true = master, false = track
  final int? trackIdx; // only used if onMaster=false
  final int slotIdx;
  final bool initialBypass;
  final _ReverbUiState initialState;
  final ValueChanged<bool> onBypassChanged;
  final ValueChanged<_ReverbUiState> onParamsChanged;

  const _ReverbEffectEditor({
    required this.onMaster,
    this.trackIdx,
    required this.slotIdx,
    required this.initialBypass,
    required this.initialState,
    required this.onBypassChanged,
    required this.onParamsChanged,
  });

  @override
  State<_ReverbEffectEditor> createState() => _ReverbEffectEditorState();
}

class _ReverbEffectEditorState extends State<_ReverbEffectEditor> {
  late double _roomSize = 0.5;
  late double _damp = 0.5;
  late double _width = 1.0;
  late double _dry = 1.0;
  late double _wet = 0.3;
  late bool _freeze;
  late bool _bypass;

  @override
  void initState() {
    super.initState();
    _roomSize = widget.initialState.roomSize;
    _damp = widget.initialState.damp;
    _width = widget.initialState.width;
    _dry = widget.initialState.dry;
    _wet = widget.initialState.wet;
    _freeze = widget.initialState.freeze;
    _bypass = widget.initialBypass;
  }

  void _toggleBypass() {
    setState(() => _bypass = !_bypass);
    widget.onBypassChanged(_bypass);
    final audioEngine = AudioEngine.instance;
    if (widget.onMaster) {
      audioEngine.setMasterInsertBypass(widget.slotIdx, _bypass);
    } else {
      audioEngine.setTrackInsertBypass(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _bypass,
      );
    }
  }

  void _emitUiState() {
    widget.onParamsChanged(
      _ReverbUiState(
        roomSize: _roomSize,
        damp: _damp,
        width: _width,
        dry: _dry,
        wet: _wet,
        freeze: _freeze,
      ),
    );
  }

  void _updateParams() {
    final audioEngine = AudioEngine.instance;
    _emitUiState();
    if (widget.onMaster) {
      audioEngine.setMasterReverbParams(
        widget.slotIdx,
        _roomSize,
        _damp,
        _width,
        _freeze,
      );
      audioEngine.setMasterInsertMix(widget.slotIdx, _dry, _wet);
    } else {
      audioEngine.setTrackReverbParams(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _roomSize,
        _damp,
        _width,
        _freeze,
      );
      audioEngine.setTrackInsertMix(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _dry,
        _wet,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return SafeArea(
      top: false,
      child: Container(
        color: kBgColor,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(12, 16, 12, bottomInset + 28),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
            decoration: BoxDecoration(
              color: kBgTrackHeader,
              border: Border.all(color: kColInactive.withAlpha(80)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 22),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'REVERB',
                          style: kStyleHeader.copyWith(
                            fontSize: 18,
                            color: _bypass ? kColInactive : kColAccent,
                            letterSpacing: 1.8,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      GestureDetector(
                        onTap: () {
                          setState(() => _freeze = !_freeze);
                          _updateParams();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: _freeze
                                ? kColAccent.withAlpha(40)
                                : kColInactive.withAlpha(24),
                            border: Border.all(
                              color: _freeze ? kColAccent : kColInactive,
                            ),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            _freeze ? 'FREEZE' : 'LIVE',
                            style: kStyleHeader.copyWith(
                              fontSize: 10,
                              color: _freeze ? kColAccent : kColInactive,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: _toggleBypass,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: _bypass
                                ? kColInactive.withAlpha(40)
                                : kColAccent.withAlpha(40),
                            border: Border.all(
                              color: _bypass ? kColInactive : kColAccent,
                            ),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            _bypass ? 'BYP' : 'ON',
                            style: kStyleHeader.copyWith(
                              fontSize: 10,
                              color: _bypass ? kColInactive : kColAccent,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'ROOM',
                    value: _roomSize,
                    onChanged: (v) {
                      setState(() => _roomSize = v);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'DAMP',
                    value: _damp,
                    onChanged: (v) {
                      setState(() => _damp = v);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'WIDTH',
                    value: _width,
                    onChanged: (v) {
                      setState(() => _width = v);
                      _updateParams();
                    },
                  ),
                ),
                _ReverbSlider(
                  label: 'DRY',
                  value: _dry,
                  onChanged: (v) {
                    setState(() => _dry = v);
                    _updateParams();
                  },
                ),
                const SizedBox(height: 28),
                _ReverbSlider(
                  label: 'WET',
                  value: _wet,
                  onChanged: (v) {
                    setState(() => _wet = v);
                    _updateParams();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DelayEffectEditor extends StatefulWidget {
  final bool onMaster;
  final int? trackIdx;
  final int slotIdx;
  final bool initialBypass;
  final _DelayUiState initialState;
  final ValueChanged<bool> onBypassChanged;
  final ValueChanged<_DelayUiState> onParamsChanged;

  const _DelayEffectEditor({
    required this.onMaster,
    this.trackIdx,
    required this.slotIdx,
    required this.initialBypass,
    required this.initialState,
    required this.onBypassChanged,
    required this.onParamsChanged,
  });

  @override
  State<_DelayEffectEditor> createState() => _DelayEffectEditorState();
}

class _DelayEffectEditorState extends State<_DelayEffectEditor> {
  late double _timeMs;
  late double _feedback;
  late double _hpCutoff;
  late double _dry;
  late double _wet;
  late bool _sync;
  late bool _bypass;

  @override
  void initState() {
    super.initState();
    _timeMs = widget.initialState.timeMs;
    _feedback = widget.initialState.feedback;
    _hpCutoff = widget.initialState.hpCutoff;
    _dry = widget.initialState.dry;
    _wet = widget.initialState.wet;
    _sync = widget.initialState.sync;
    _bypass = widget.initialBypass;
  }

  void _toggleBypass() {
    setState(() => _bypass = !_bypass);
    widget.onBypassChanged(_bypass);
    final ae = AudioEngine.instance;
    if (widget.onMaster) {
      ae.setMasterInsertBypass(widget.slotIdx, _bypass);
    } else {
      ae.setTrackInsertBypass(widget.trackIdx ?? 0, widget.slotIdx, _bypass);
    }
  }

  void _emitState() {
    widget.onParamsChanged(
      _DelayUiState(
        timeMs: _timeMs,
        feedback: _feedback,
        hpCutoff: _hpCutoff,
        dry: _dry,
        wet: _wet,
        sync: _sync,
      ),
    );
  }

  void _updateParams() {
    _emitState();
    final ae = AudioEngine.instance;
    if (widget.onMaster) {
      ae.setMasterDelayParams(
        widget.slotIdx,
        _timeMs,
        _feedback,
        _hpCutoff,
        _sync,
      );
      ae.setMasterInsertMix(widget.slotIdx, _dry, _wet);
    } else {
      ae.setTrackDelayParams(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _timeMs,
        _feedback,
        _hpCutoff,
        _sync,
      );
      ae.setTrackInsertMix(widget.trackIdx ?? 0, widget.slotIdx, _dry, _wet);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final timePct = ((_timeMs - 1.0) / 1999.0).clamp(0.0, 1.0);

    return SafeArea(
      top: false,
      child: Container(
        color: kBgColor,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(12, 16, 12, bottomInset + 28),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
            decoration: BoxDecoration(
              color: kBgTrackHeader,
              border: Border.all(color: kColInactive.withAlpha(80)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 22),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'DELAY',
                          style: kStyleHeader.copyWith(
                            fontSize: 18,
                            color: _bypass ? kColInactive : kColAccent,
                            letterSpacing: 1.8,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      GestureDetector(
                        onTap: _toggleBypass,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: _bypass
                                ? kColInactive.withAlpha(40)
                                : kColAccent.withAlpha(40),
                            border: Border.all(
                              color: _bypass ? kColInactive : kColAccent,
                            ),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            _bypass ? 'BYP' : 'ON',
                            style: kStyleHeader.copyWith(
                              fontSize: 10,
                              color: _bypass ? kColInactive : kColAccent,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // TIME slider — logarithmic feel via sqrt
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'TIME',
                    value: timePct,
                    displayText: '${_timeMs.round()} ms',
                    onChanged: (v) {
                      setState(() => _timeMs = 1.0 + v * v * 1999.0);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'FDBK',
                    value: _feedback / 0.95,
                    onChanged: (v) {
                      setState(() => _feedback = v * 0.95);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'HP',
                    value: _hpCutoff,
                    onChanged: (v) {
                      setState(() => _hpCutoff = v);
                      _updateParams();
                    },
                  ),
                ),
                _ReverbSlider(
                  label: 'DRY',
                  value: _dry,
                  onChanged: (v) {
                    setState(() => _dry = v);
                    _updateParams();
                  },
                ),
                const SizedBox(height: 28),
                _ReverbSlider(
                  label: 'WET',
                  value: _wet,
                  onChanged: (v) {
                    setState(() => _wet = v);
                    _updateParams();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Filter effect editor ──────────────────────────────────────────────────────

class _FilterEffectEditor extends StatefulWidget {
  final bool onMaster;
  final int? trackIdx;
  final int slotIdx;
  final bool initialBypass;
  final _FilterUiState initialState;
  final ValueChanged<bool> onBypassChanged;
  final ValueChanged<_FilterUiState> onParamsChanged;

  const _FilterEffectEditor({
    required this.onMaster,
    this.trackIdx,
    required this.slotIdx,
    required this.initialBypass,
    required this.initialState,
    required this.onBypassChanged,
    required this.onParamsChanged,
  });

  @override
  State<_FilterEffectEditor> createState() => _FilterEffectEditorState();
}

class _FilterEffectEditorState extends State<_FilterEffectEditor> {
  late double _cutoff;
  late double _resonance;
  late int _mode;
  late double _dry;
  late double _wet;
  late bool _bypass;

  static const _modeLabels = ['LP', 'HP', 'BP'];

  @override
  void initState() {
    super.initState();
    _cutoff = widget.initialState.cutoff;
    _resonance = widget.initialState.resonance;
    _mode = widget.initialState.mode;
    _dry = widget.initialState.dry;
    _wet = widget.initialState.wet;
    _bypass = widget.initialBypass;
  }

  void _toggleBypass() {
    setState(() => _bypass = !_bypass);
    widget.onBypassChanged(_bypass);
    if (widget.onMaster) {
      AudioEngine.instance.setMasterInsertBypass(widget.slotIdx, _bypass);
    } else {
      AudioEngine.instance.setTrackInsertBypass(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _bypass,
      );
    }
  }

  void _updateParams() {
    widget.onParamsChanged(
      _FilterUiState(
        cutoff: _cutoff,
        resonance: _resonance,
        mode: _mode,
        dry: _dry,
        wet: _wet,
      ),
    );
    if (widget.onMaster) {
      AudioEngine.instance.setMasterFilterParams(
        widget.slotIdx,
        _cutoff,
        _resonance,
        _mode,
      );
      AudioEngine.instance.setMasterInsertMix(widget.slotIdx, _dry, _wet);
    } else {
      AudioEngine.instance.setTrackFilterParams(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _cutoff,
        _resonance,
        _mode,
      );
      AudioEngine.instance.setTrackInsertMix(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _dry,
        _wet,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return SafeArea(
      top: false,
      child: Container(
        color: kBgColor,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(12, 16, 12, bottomInset + 28),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
            decoration: BoxDecoration(
              color: kBgTrackHeader,
              border: Border.all(color: kColInactive.withAlpha(80)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'FILTER',
                          style: kStyleHeader.copyWith(
                            fontSize: 18,
                            color: _bypass ? kColInactive : kColAccent,
                            letterSpacing: 1.8,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: _toggleBypass,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: (_bypass ? kColInactive : kColAccent)
                                .withAlpha(40),
                            border: Border.all(
                              color: _bypass ? kColInactive : kColAccent,
                            ),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            _bypass ? 'BYP' : 'ON',
                            style: kStyleHeader.copyWith(
                              fontSize: 10,
                              color: _bypass ? kColInactive : kColAccent,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Mode toggle
                Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 58,
                        child: Text(
                          'MODE',
                          style: kStyleBase.copyWith(
                            fontSize: 12,
                            color: kColInactive,
                          ),
                        ),
                      ),
                      for (int i = 0; i < 3; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: GestureDetector(
                            onTap: () {
                              setState(() => _mode = i);
                              _updateParams();
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: _mode == i
                                    ? kColAccent.withAlpha(40)
                                    : Colors.transparent,
                                border: Border.all(
                                  color: _mode == i
                                      ? kColAccent
                                      : kColInactive.withAlpha(80),
                                ),
                                borderRadius: BorderRadius.circular(2),
                              ),
                              child: Text(
                                _modeLabels[i],
                                style: kStyleHeader.copyWith(
                                  fontSize: 11,
                                  color: _mode == i ? kColAccent : kColInactive,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'CUTOFF',
                    value: _cutoff,
                    onChanged: (v) {
                      setState(() => _cutoff = v);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'RESO',
                    value: _resonance,
                    onChanged: (v) {
                      setState(() => _resonance = v);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'DRY',
                    value: _dry,
                    onChanged: (v) {
                      setState(() => _dry = v);
                      _updateParams();
                    },
                  ),
                ),
                _ReverbSlider(
                  label: 'WET',
                  value: _wet,
                  onChanged: (v) {
                    setState(() => _wet = v);
                    _updateParams();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Distortion effect editor ──────────────────────────────────────────────────

class _DistortionEffectEditor extends StatefulWidget {
  final bool onMaster;
  final int? trackIdx;
  final int slotIdx;
  final bool initialBypass;
  final _DistortionUiState initialState;
  final ValueChanged<bool> onBypassChanged;
  final ValueChanged<_DistortionUiState> onParamsChanged;

  const _DistortionEffectEditor({
    required this.onMaster,
    this.trackIdx,
    required this.slotIdx,
    required this.initialBypass,
    required this.initialState,
    required this.onBypassChanged,
    required this.onParamsChanged,
  });

  @override
  State<_DistortionEffectEditor> createState() =>
      _DistortionEffectEditorState();
}

class _DistortionEffectEditorState extends State<_DistortionEffectEditor> {
  late double _drive;
  late double _tone;
  late int _distType;
  late double _dry;
  late double _wet;
  late bool _bypass;

  @override
  void initState() {
    super.initState();
    _drive = widget.initialState.drive;
    _tone = widget.initialState.tone;
    _distType = widget.initialState.distType;
    _dry = widget.initialState.dry;
    _wet = widget.initialState.wet;
    _bypass = widget.initialBypass;
  }

  void _toggleBypass() {
    setState(() => _bypass = !_bypass);
    widget.onBypassChanged(_bypass);
    if (widget.onMaster) {
      AudioEngine.instance.setMasterInsertBypass(widget.slotIdx, _bypass);
    } else {
      AudioEngine.instance.setTrackInsertBypass(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _bypass,
      );
    }
  }

  void _updateParams() {
    widget.onParamsChanged(
      _DistortionUiState(
        drive: _drive,
        tone: _tone,
        distType: _distType,
        dry: _dry,
        wet: _wet,
      ),
    );
    if (widget.onMaster) {
      AudioEngine.instance.setMasterDistortionParams(
        widget.slotIdx,
        _drive,
        _tone,
        _distType,
      );
      AudioEngine.instance.setMasterInsertMix(widget.slotIdx, _dry, _wet);
    } else {
      AudioEngine.instance.setTrackDistortionParams(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _drive,
        _tone,
        _distType,
      );
      AudioEngine.instance.setTrackInsertMix(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _dry,
        _wet,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return SafeArea(
      top: false,
      child: Container(
        color: kBgColor,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(12, 16, 12, bottomInset + 28),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
            decoration: BoxDecoration(
              color: kBgTrackHeader,
              border: Border.all(color: kColInactive.withAlpha(80)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'DISTORTION',
                          style: kStyleHeader.copyWith(
                            fontSize: 18,
                            color: _bypass ? kColInactive : kColAccent,
                            letterSpacing: 1.8,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: _toggleBypass,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: (_bypass ? kColInactive : kColAccent)
                                .withAlpha(40),
                            border: Border.all(
                              color: _bypass ? kColInactive : kColAccent,
                            ),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            _bypass ? 'BYP' : 'ON',
                            style: kStyleHeader.copyWith(
                              fontSize: 10,
                              color: _bypass ? kColInactive : kColAccent,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Type toggle
                Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 58,
                        child: Text(
                          'TYPE',
                          style: kStyleBase.copyWith(
                            fontSize: 12,
                            color: kColInactive,
                          ),
                        ),
                      ),
                      for (final (i, label) in [
                        const (0, 'CLIP'),
                        const (1, 'FOLD'),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: GestureDetector(
                            onTap: () {
                              setState(() => _distType = i);
                              _updateParams();
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: _distType == i
                                    ? kColAccent.withAlpha(40)
                                    : Colors.transparent,
                                border: Border.all(
                                  color: _distType == i
                                      ? kColAccent
                                      : kColInactive.withAlpha(80),
                                ),
                                borderRadius: BorderRadius.circular(2),
                              ),
                              child: Text(
                                label,
                                style: kStyleHeader.copyWith(
                                  fontSize: 11,
                                  color: _distType == i
                                      ? kColAccent
                                      : kColInactive,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'DRIVE',
                    value: _drive,
                    onChanged: (v) {
                      setState(() => _drive = v);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'TONE',
                    value: _tone,
                    onChanged: (v) {
                      setState(() => _tone = v);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'DRY',
                    value: _dry,
                    onChanged: (v) {
                      setState(() => _dry = v);
                      _updateParams();
                    },
                  ),
                ),
                _ReverbSlider(
                  label: 'WET',
                  value: _wet,
                  onChanged: (v) {
                    setState(() => _wet = v);
                    _updateParams();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Bitcrusher effect editor ──────────────────────────────────────────────────

class _BitcrusherEffectEditor extends StatefulWidget {
  final bool onMaster;
  final int? trackIdx;
  final int slotIdx;
  final bool initialBypass;
  final _BitcrusherUiState initialState;
  final ValueChanged<bool> onBypassChanged;
  final ValueChanged<_BitcrusherUiState> onParamsChanged;

  const _BitcrusherEffectEditor({
    required this.onMaster,
    this.trackIdx,
    required this.slotIdx,
    required this.initialBypass,
    required this.initialState,
    required this.onBypassChanged,
    required this.onParamsChanged,
  });

  @override
  State<_BitcrusherEffectEditor> createState() =>
      _BitcrusherEffectEditorState();
}

class _BitcrusherEffectEditorState extends State<_BitcrusherEffectEditor> {
  late double _bits;
  late double _rate;
  late double _dry;
  late double _wet;
  late bool _bypass;

  @override
  void initState() {
    super.initState();
    _bits = widget.initialState.bits;
    _rate = widget.initialState.rate;
    _dry = widget.initialState.dry;
    _wet = widget.initialState.wet;
    _bypass = widget.initialBypass;
  }

  void _toggleBypass() {
    setState(() => _bypass = !_bypass);
    widget.onBypassChanged(_bypass);
    if (widget.onMaster) {
      AudioEngine.instance.setMasterInsertBypass(widget.slotIdx, _bypass);
    } else {
      AudioEngine.instance.setTrackInsertBypass(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _bypass,
      );
    }
  }

  void _updateParams() {
    widget.onParamsChanged(
      _BitcrusherUiState(bits: _bits, rate: _rate, dry: _dry, wet: _wet),
    );
    if (widget.onMaster) {
      AudioEngine.instance.setMasterBitcrusherParams(
        widget.slotIdx,
        _bits,
        _rate,
      );
      AudioEngine.instance.setMasterInsertMix(widget.slotIdx, _dry, _wet);
    } else {
      AudioEngine.instance.setTrackBitcrusherParams(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _bits,
        _rate,
      );
      AudioEngine.instance.setTrackInsertMix(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _dry,
        _wet,
      );
    }
  }

  String _bitsLabel() {
    final bits = (1.0 + _bits * 15.0).round();
    return '$bits-bit';
  }

  String _rateLabel() {
    final hold = (1.0 + (1.0 - _rate) * 31.0).round();
    return hold == 1 ? 'off' : '÷$hold';
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return SafeArea(
      top: false,
      child: Container(
        color: kBgColor,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(12, 16, 12, bottomInset + 28),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
            decoration: BoxDecoration(
              color: kBgTrackHeader,
              border: Border.all(color: kColInactive.withAlpha(80)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 22),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'BITCRUSHER',
                          style: kStyleHeader.copyWith(
                            fontSize: 18,
                            color: _bypass ? kColInactive : kColAccent,
                            letterSpacing: 1.8,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: _toggleBypass,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: (_bypass ? kColInactive : kColAccent)
                                .withAlpha(40),
                            border: Border.all(
                              color: _bypass ? kColInactive : kColAccent,
                            ),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            _bypass ? 'BYP' : 'ON',
                            style: kStyleHeader.copyWith(
                              fontSize: 10,
                              color: _bypass ? kColInactive : kColAccent,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'BITS',
                    value: _bits,
                    displayText: _bitsLabel(),
                    onChanged: (v) {
                      setState(() => _bits = v);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'RATE',
                    value: _rate,
                    displayText: _rateLabel(),
                    onChanged: (v) {
                      setState(() => _rate = v);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'DRY',
                    value: _dry,
                    onChanged: (v) {
                      setState(() => _dry = v);
                      _updateParams();
                    },
                  ),
                ),
                _ReverbSlider(
                  label: 'WET',
                  value: _wet,
                  onChanged: (v) {
                    setState(() => _wet = v);
                    _updateParams();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Limiter effect editor ─────────────────────────────────────────────────────

class _LimiterEffectEditor extends StatefulWidget {
  final bool onMaster;
  final int? trackIdx;
  final int slotIdx;
  final bool initialBypass;
  final _LimiterUiState initialState;
  final ValueChanged<bool> onBypassChanged;
  final ValueChanged<_LimiterUiState> onParamsChanged;

  const _LimiterEffectEditor({
    required this.onMaster,
    this.trackIdx,
    required this.slotIdx,
    required this.initialBypass,
    required this.initialState,
    required this.onBypassChanged,
    required this.onParamsChanged,
  });

  @override
  State<_LimiterEffectEditor> createState() => _LimiterEffectEditorState();
}

class _LimiterEffectEditorState extends State<_LimiterEffectEditor> {
  late double _gain;
  late double _dry;
  late double _wet;
  late bool _bypass;

  // Fixed ceiling displayed to the user
  static const String kCeilingLabel = '−0.1 dBFS';

  @override
  void initState() {
    super.initState();
    _gain = widget.initialState.gain;
    _dry = widget.initialState.dry;
    _wet = widget.initialState.wet;
    _bypass = widget.initialBypass;
  }

  void _toggleBypass() {
    setState(() => _bypass = !_bypass);
    widget.onBypassChanged(_bypass);
    if (widget.onMaster) {
      AudioEngine.instance.setMasterInsertBypass(widget.slotIdx, _bypass);
    } else {
      AudioEngine.instance.setTrackInsertBypass(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _bypass,
      );
    }
  }

  void _updateParams() {
    widget.onParamsChanged(_LimiterUiState(gain: _gain, dry: _dry, wet: _wet));
    if (widget.onMaster) {
      AudioEngine.instance.setMasterLimiterParams(widget.slotIdx, _gain);
      AudioEngine.instance.setMasterInsertMix(widget.slotIdx, _dry, _wet);
    } else {
      AudioEngine.instance.setTrackLimiterParams(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _gain,
      );
      AudioEngine.instance.setTrackInsertMix(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _dry,
        _wet,
      );
    }
  }

  String _gainLabel() {
    // gain 0..1 → 0 dB..+24 dB
    final db = (_gain * 24.0);
    return '+${db.toStringAsFixed(1)} dB';
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return SafeArea(
      top: false,
      child: Container(
        color: kBgColor,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(12, 16, 12, bottomInset + 28),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
            decoration: BoxDecoration(
              color: kBgTrackHeader,
              border: Border.all(color: kColInactive.withAlpha(80)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'LIMITER',
                          style: kStyleHeader.copyWith(
                            fontSize: 18,
                            color: _bypass ? kColInactive : kColAccent,
                            letterSpacing: 1.8,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: _toggleBypass,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: (_bypass ? kColInactive : kColAccent)
                                .withAlpha(40),
                            border: Border.all(
                              color: _bypass ? kColInactive : kColAccent,
                            ),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            _bypass ? 'BYP' : 'ON',
                            style: kStyleHeader.copyWith(
                              fontSize: 10,
                              color: _bypass ? kColInactive : kColAccent,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 22),
                  child: Text(
                    'Ceiling $kCeilingLabel',
                    style: kStyleBase.copyWith(
                      fontSize: 11,
                      color: kColInactive,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'PUSH',
                    value: _gain,
                    displayText: _gainLabel(),
                    onChanged: (v) {
                      setState(() => _gain = v);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'DRY',
                    value: _dry,
                    onChanged: (v) {
                      setState(() => _dry = v);
                      _updateParams();
                    },
                  ),
                ),
                _ReverbSlider(
                  label: 'WET',
                  value: _wet,
                  onChanged: (v) {
                    setState(() => _wet = v);
                    _updateParams();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChorusEffectEditor extends StatefulWidget {
  final bool onMaster;
  final int? trackIdx;
  final int slotIdx;
  final bool initialBypass;
  final _ChorusUiState initialState;
  final ValueChanged<bool> onBypassChanged;
  final ValueChanged<_ChorusUiState> onParamsChanged;

  const _ChorusEffectEditor({
    required this.onMaster,
    this.trackIdx,
    required this.slotIdx,
    required this.initialBypass,
    required this.initialState,
    required this.onBypassChanged,
    required this.onParamsChanged,
  });

  @override
  State<_ChorusEffectEditor> createState() => _ChorusEffectEditorState();
}

class _ChorusEffectEditorState extends State<_ChorusEffectEditor> {
  late double _rate;
  late double _depth;
  late double _delay;
  late int _stereo;
  late double _dry;
  late double _wet;
  late bool _bypass;

  @override
  void initState() {
    super.initState();
    _rate = widget.initialState.rate;
    _depth = widget.initialState.depth;
    _delay = widget.initialState.delay;
    _stereo = widget.initialState.stereo;
    _dry = widget.initialState.dry;
    _wet = widget.initialState.wet;
    _bypass = widget.initialBypass;
  }

  void _toggleBypass() {
    setState(() => _bypass = !_bypass);
    widget.onBypassChanged(_bypass);
    if (widget.onMaster) {
      AudioEngine.instance.setMasterInsertBypass(widget.slotIdx, _bypass);
    } else {
      AudioEngine.instance.setTrackInsertBypass(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _bypass,
      );
    }
  }

  void _updateParams() {
    widget.onParamsChanged(
      _ChorusUiState(
        rate: _rate,
        depth: _depth,
        delay: _delay,
        stereo: _stereo,
        dry: _dry,
        wet: _wet,
      ),
    );
    if (widget.onMaster) {
      AudioEngine.instance.setMasterChorusParams(
        widget.slotIdx,
        _rate,
        _depth,
        _delay,
        _stereo,
      );
      AudioEngine.instance.setMasterInsertMix(widget.slotIdx, _dry, _wet);
    } else {
      AudioEngine.instance.setTrackChorusParams(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _rate,
        _depth,
        _delay,
        _stereo,
      );
      AudioEngine.instance.setTrackInsertMix(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _dry,
        _wet,
      );
    }
  }

  String _rateLabel() => '${(0.1 + _rate * 7.9).toStringAsFixed(1)} Hz';
  String _depthLabel() => '${(_depth * 15.0).toStringAsFixed(1)} ms';
  String _delayLabel() => '${(1.0 + _delay * 29.0).toStringAsFixed(0)} ms';

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return SafeArea(
      top: false,
      child: Container(
        color: kBgColor,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(12, 16, 12, bottomInset + 28),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
            decoration: BoxDecoration(
              color: kBgTrackHeader,
              border: Border.all(color: kColInactive.withAlpha(80)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'CHORUS',
                          style: kStyleHeader.copyWith(
                            fontSize: 18,
                            color: _bypass ? kColInactive : kColAccent,
                            letterSpacing: 1.8,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: _toggleBypass,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: (_bypass ? kColInactive : kColAccent)
                                .withAlpha(40),
                            border: Border.all(
                              color: _bypass ? kColInactive : kColAccent,
                            ),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            _bypass ? 'BYP' : 'ON',
                            style: kStyleHeader.copyWith(
                              fontSize: 10,
                              color: _bypass ? kColInactive : kColAccent,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Stereo toggle
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'STEREO',
                        style: kStyleBase.copyWith(
                          fontSize: 11,
                          color: kColInactive,
                        ),
                      ),
                      GestureDetector(
                        onTap: () {
                          setState(() => _stereo = _stereo == 0 ? 1 : 0);
                          _updateParams();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: (_stereo == 1 ? kColAccent : kColInactive)
                                .withAlpha(40),
                            border: Border.all(
                              color: _stereo == 1 ? kColAccent : kColInactive,
                            ),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            _stereo == 1 ? 'STEREO' : 'MONO',
                            style: kStyleHeader.copyWith(
                              fontSize: 10,
                              color: _stereo == 1 ? kColAccent : kColInactive,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'RATE',
                    value: _rate,
                    displayText: _rateLabel(),
                    onChanged: (v) {
                      setState(() => _rate = v);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'DEPTH',
                    value: _depth,
                    displayText: _depthLabel(),
                    onChanged: (v) {
                      setState(() => _depth = v);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'DELAY',
                    value: _delay,
                    displayText: _delayLabel(),
                    onChanged: (v) {
                      setState(() => _delay = v);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: _ReverbSlider(
                    label: 'DRY',
                    value: _dry,
                    onChanged: (v) {
                      setState(() => _dry = v);
                      _updateParams();
                    },
                  ),
                ),
                _ReverbSlider(
                  label: 'WET',
                  value: _wet,
                  onChanged: (v) {
                    setState(() => _wet = v);
                    _updateParams();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EqEffectEditor extends StatefulWidget {
  final bool onMaster;
  final int? trackIdx;
  final int slotIdx;
  final bool initialBypass;
  final _EqUiState initialState;
  final ValueChanged<bool> onBypassChanged;
  final ValueChanged<_EqUiState> onParamsChanged;

  const _EqEffectEditor({
    required this.onMaster,
    this.trackIdx,
    required this.slotIdx,
    required this.initialBypass,
    required this.initialState,
    required this.onBypassChanged,
    required this.onParamsChanged,
  });

  @override
  State<_EqEffectEditor> createState() => _EqEffectEditorState();
}

class _EqEffectEditorState extends State<_EqEffectEditor> {
  late double _lowGain, _lowFreq;
  late double _midGain, _midFreq, _midQ;
  late double _highGain, _highFreq;
  late double _dry, _wet;
  late bool _bypass;

  @override
  void initState() {
    super.initState();
    _lowGain = widget.initialState.lowGain;
    _lowFreq = widget.initialState.lowFreq;
    _midGain = widget.initialState.midGain;
    _midFreq = widget.initialState.midFreq;
    _midQ = widget.initialState.midQ;
    _highGain = widget.initialState.highGain;
    _highFreq = widget.initialState.highFreq;
    _dry = widget.initialState.dry;
    _wet = widget.initialState.wet;
    _bypass = widget.initialBypass;
  }

  void _toggleBypass() {
    setState(() => _bypass = !_bypass);
    widget.onBypassChanged(_bypass);
    if (widget.onMaster) {
      AudioEngine.instance.setMasterInsertBypass(widget.slotIdx, _bypass);
    } else {
      AudioEngine.instance.setTrackInsertBypass(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _bypass,
      );
    }
  }

  void _updateParams() {
    final s = _EqUiState(
      lowGain: _lowGain,
      lowFreq: _lowFreq,
      midGain: _midGain,
      midFreq: _midFreq,
      midQ: _midQ,
      highGain: _highGain,
      highFreq: _highFreq,
      dry: _dry,
      wet: _wet,
    );
    widget.onParamsChanged(s);
    if (widget.onMaster) {
      AudioEngine.instance.setMasterEqParams(
        widget.slotIdx,
        _lowGain,
        _lowFreq,
        _midGain,
        _midFreq,
        _midQ,
        _highGain,
        _highFreq,
      );
      AudioEngine.instance.setMasterInsertMix(widget.slotIdx, _dry, _wet);
    } else {
      AudioEngine.instance.setTrackEqParams(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _lowGain,
        _lowFreq,
        _midGain,
        _midFreq,
        _midQ,
        _highGain,
        _highFreq,
      );
      AudioEngine.instance.setTrackInsertMix(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _dry,
        _wet,
      );
    }
  }

  // Gain: −1..+1 → −12..+12 dB, centred slider
  String _gainLabel(double g) {
    final db = g * 12.0;
    return db >= 0
        ? '+${db.toStringAsFixed(1)} dB'
        : '${db.toStringAsFixed(1)} dB';
  }

  // Low freq: 0..1 → 40..500 Hz (log)
  String _lowFreqLabel() {
    final hz = 40.0 * math.pow(500.0 / 40.0, _lowFreq);
    return hz < 1000
        ? '${hz.round()} Hz'
        : '${(hz / 1000).toStringAsFixed(2)} kHz';
  }

  // Mid freq: 0..1 → 200..8000 Hz (log)
  String _midFreqLabel() {
    final hz = 200.0 * math.pow(8000.0 / 200.0, _midFreq);
    return hz < 1000
        ? '${hz.round()} Hz'
        : '${(hz / 1000).toStringAsFixed(2)} kHz';
  }

  // High freq: 0..1 → 2000..16000 Hz (log)
  String _highFreqLabel() {
    final hz = 2000.0 * math.pow(16000.0 / 2000.0, _highFreq);
    return hz < 1000
        ? '${hz.round()} Hz'
        : '${(hz / 1000).toStringAsFixed(2)} kHz';
  }

  // Q: 0..1 → 0.3..8.0
  String _qLabel() => (0.3 + _midQ * 7.7).toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return SafeArea(
      top: false,
      child: Container(
        color: kBgColor,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(12, 16, 12, bottomInset + 28),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
            decoration: BoxDecoration(
              color: kBgTrackHeader,
              border: Border.all(color: kColInactive.withAlpha(80)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header + bypass
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'EQ',
                          style: kStyleHeader.copyWith(
                            fontSize: 18,
                            color: _bypass ? kColInactive : kColAccent,
                            letterSpacing: 1.8,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: _toggleBypass,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: (_bypass ? kColInactive : kColAccent)
                                .withAlpha(40),
                            border: Border.all(
                              color: _bypass ? kColInactive : kColAccent,
                            ),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            _bypass ? 'BYP' : 'ON',
                            style: kStyleHeader.copyWith(
                              fontSize: 10,
                              color: _bypass ? kColInactive : kColAccent,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // LOW SHELF
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    'LOW SHELF',
                    style: kStyleBase.copyWith(
                      fontSize: 10,
                      color: kColInactive,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _EqGainSlider(
                    label: 'GAIN',
                    value: (_lowGain + 1.0) / 2.0,
                    displayText: _gainLabel(_lowGain),
                    onChanged: (v) {
                      setState(() => _lowGain = v * 2.0 - 1.0);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: _ReverbSlider(
                    label: 'FREQ',
                    value: _lowFreq,
                    displayText: _lowFreqLabel(),
                    onChanged: (v) {
                      setState(() => _lowFreq = v);
                      _updateParams();
                    },
                  ),
                ),
                // MID PEAK
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    'MID PEAK',
                    style: kStyleBase.copyWith(
                      fontSize: 10,
                      color: kColInactive,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _EqGainSlider(
                    label: 'GAIN',
                    value: (_midGain + 1.0) / 2.0,
                    displayText: _gainLabel(_midGain),
                    onChanged: (v) {
                      setState(() => _midGain = v * 2.0 - 1.0);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _ReverbSlider(
                    label: 'FREQ',
                    value: _midFreq,
                    displayText: _midFreqLabel(),
                    onChanged: (v) {
                      setState(() => _midFreq = v);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: _ReverbSlider(
                    label: 'Q',
                    value: _midQ,
                    displayText: _qLabel(),
                    onChanged: (v) {
                      setState(() => _midQ = v);
                      _updateParams();
                    },
                  ),
                ),
                // HIGH SHELF
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    'HIGH SHELF',
                    style: kStyleBase.copyWith(
                      fontSize: 10,
                      color: kColInactive,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _EqGainSlider(
                    label: 'GAIN',
                    value: (_highGain + 1.0) / 2.0,
                    displayText: _gainLabel(_highGain),
                    onChanged: (v) {
                      setState(() => _highGain = v * 2.0 - 1.0);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: _ReverbSlider(
                    label: 'FREQ',
                    value: _highFreq,
                    displayText: _highFreqLabel(),
                    onChanged: (v) {
                      setState(() => _highFreq = v);
                      _updateParams();
                    },
                  ),
                ),
                // DRY / WET
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _ReverbSlider(
                    label: 'DRY',
                    value: _dry,
                    onChanged: (v) {
                      setState(() => _dry = v);
                      _updateParams();
                    },
                  ),
                ),
                _ReverbSlider(
                  label: 'WET',
                  value: _wet,
                  onChanged: (v) {
                    setState(() => _wet = v);
                    _updateParams();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CompressorEffectEditor extends StatefulWidget {
  final bool onMaster;
  final int? trackIdx;
  final int slotIdx;
  final bool initialBypass;
  final _CompressorUiState initialState;
  final ValueChanged<bool> onBypassChanged;
  final ValueChanged<_CompressorUiState> onParamsChanged;

  const _CompressorEffectEditor({
    required this.onMaster,
    this.trackIdx,
    required this.slotIdx,
    required this.initialBypass,
    required this.initialState,
    required this.onBypassChanged,
    required this.onParamsChanged,
  });

  @override
  State<_CompressorEffectEditor> createState() =>
      _CompressorEffectEditorState();
}

class _CompressorEffectEditorState extends State<_CompressorEffectEditor> {
  late double _threshold, _ratio, _attack, _release, _makeup, _dry, _wet;
  late int _knee;
  late bool _bypass;

  @override
  void initState() {
    super.initState();
    _threshold = widget.initialState.threshold;
    _ratio = widget.initialState.ratio;
    _attack = widget.initialState.attack;
    _release = widget.initialState.release;
    _makeup = widget.initialState.makeup;
    _knee = widget.initialState.knee;
    _dry = widget.initialState.dry;
    _wet = widget.initialState.wet;
    _bypass = widget.initialBypass;
  }

  void _toggleBypass() {
    setState(() => _bypass = !_bypass);
    widget.onBypassChanged(_bypass);
    if (widget.onMaster) {
      AudioEngine.instance.setMasterInsertBypass(widget.slotIdx, _bypass);
    } else {
      AudioEngine.instance.setTrackInsertBypass(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _bypass,
      );
    }
  }

  void _updateParams() {
    final s = _CompressorUiState(
      threshold: _threshold,
      ratio: _ratio,
      attack: _attack,
      release: _release,
      makeup: _makeup,
      knee: _knee,
      dry: _dry,
      wet: _wet,
    );
    widget.onParamsChanged(s);
    if (widget.onMaster) {
      AudioEngine.instance.setMasterCompressorParams(
        widget.slotIdx,
        _threshold,
        _ratio,
        _attack,
        _release,
        _makeup,
        _knee,
      );
      AudioEngine.instance.setMasterInsertMix(widget.slotIdx, _dry, _wet);
    } else {
      AudioEngine.instance.setTrackCompressorParams(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _threshold,
        _ratio,
        _attack,
        _release,
        _makeup,
        _knee,
      );
      AudioEngine.instance.setTrackInsertMix(
        widget.trackIdx ?? 0,
        widget.slotIdx,
        _dry,
        _wet,
      );
    }
  }

  String _thresholdLabel() {
    final db = -60.0 + _threshold * 60.0;
    return '${db.toStringAsFixed(1)} dBFS';
  }

  String _ratioLabel() {
    final r = 1.0 + math.exp(_ratio * math.log(19));
    return '${r.toStringAsFixed(1)}:1';
  }

  String _attackLabel() {
    final ms = 0.1 * math.pow(2000.0, _attack);
    return ms < 10 ? '${ms.toStringAsFixed(1)} ms' : '${ms.round()} ms';
  }

  String _releaseLabel() {
    final ms = 10.0 * math.pow(200.0, _release);
    return ms < 100 ? '${ms.toStringAsFixed(1)} ms' : '${ms.round()} ms';
  }

  String _makeupLabel() => '+${(_makeup * 24.0).toStringAsFixed(1)} dB';

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return SafeArea(
      top: false,
      child: Container(
        color: kBgColor,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(12, 16, 12, bottomInset + 28),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
            decoration: BoxDecoration(
              color: kBgTrackHeader,
              border: Border.all(color: kColInactive.withAlpha(80)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header + bypass
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'COMPRESSOR',
                          style: kStyleHeader.copyWith(
                            fontSize: 18,
                            color: _bypass ? kColInactive : kColAccent,
                            letterSpacing: 1.8,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: _toggleBypass,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: (_bypass ? kColInactive : kColAccent)
                                .withAlpha(40),
                            border: Border.all(
                              color: _bypass ? kColInactive : kColAccent,
                            ),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            _bypass ? 'BYP' : 'ON',
                            style: kStyleHeader.copyWith(
                              fontSize: 10,
                              color: _bypass ? kColInactive : kColAccent,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // KNEE toggle
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    children: [
                      Text(
                        'KNEE',
                        style: kStyleHeader.copyWith(
                          fontSize: 12,
                          color: kColHeader,
                        ),
                      ),
                      const SizedBox(width: 12),
                      for (final (idx, label) in [(0, 'HARD'), (1, 'SOFT')])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: GestureDetector(
                            onTap: () {
                              setState(() => _knee = idx);
                              _updateParams();
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: _knee == idx
                                    ? kColAccent.withAlpha(40)
                                    : Colors.transparent,
                                border: Border.all(
                                  color: _knee == idx
                                      ? kColAccent
                                      : kColInactive,
                                ),
                                borderRadius: BorderRadius.circular(2),
                              ),
                              child: Text(
                                label,
                                style: kStyleHeader.copyWith(
                                  fontSize: 10,
                                  color: _knee == idx
                                      ? kColAccent
                                      : kColInactive,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _ReverbSlider(
                    label: 'THRESH',
                    value: _threshold,
                    displayText: _thresholdLabel(),
                    onChanged: (v) {
                      setState(() => _threshold = v);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _ReverbSlider(
                    label: 'RATIO',
                    value: _ratio,
                    displayText: _ratioLabel(),
                    onChanged: (v) {
                      setState(() => _ratio = v);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _ReverbSlider(
                    label: 'ATTACK',
                    value: _attack,
                    displayText: _attackLabel(),
                    onChanged: (v) {
                      setState(() => _attack = v);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _ReverbSlider(
                    label: 'RELEASE',
                    value: _release,
                    displayText: _releaseLabel(),
                    onChanged: (v) {
                      setState(() => _release = v);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _ReverbSlider(
                    label: 'MAKEUP',
                    value: _makeup,
                    displayText: _makeupLabel(),
                    onChanged: (v) {
                      setState(() => _makeup = v);
                      _updateParams();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _ReverbSlider(
                    label: 'DRY',
                    value: _dry,
                    onChanged: (v) {
                      setState(() => _dry = v);
                      _updateParams();
                    },
                  ),
                ),
                _ReverbSlider(
                  label: 'WET',
                  value: _wet,
                  onChanged: (v) {
                    setState(() => _wet = v);
                    _updateParams();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Gain slider: 0..1 input but displays as ±12 dB centred.
// Visually identical to _ReverbSlider but the centre position = 0 dB.
class _EqGainSlider extends StatelessWidget {
  final String label;
  final double value; // 0..1 (0.5 = 0 dB)
  final String displayText;
  final ValueChanged<double> onChanged;

  const _EqGainSlider({
    required this.label,
    required this.value,
    required this.displayText,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _ReverbSlider(
      label: label,
      value: value,
      displayText: displayText,
      onChanged: onChanged,
    );
  }
}

class _ReverbSlider extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final String? displayText; // override the right-hand value label

  const _ReverbSlider({
    required this.label,
    required this.value,
    required this.onChanged,
    this.displayText,
  });

  @override
  Widget build(BuildContext context) {
    final percent = (value * 99)
        .round()
        .clamp(0, 99)
        .toString()
        .padLeft(2, '0');
    final rightLabel = displayText ?? percent;

    return Row(
      children: [
        SizedBox(
          width: 58,
          child: Text(
            label,
            style: kStyleHeader.copyWith(fontSize: 12, color: kColHeader),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 6,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: SliderComponentShape.noOverlay,
              activeTrackColor: kColComplement,
              inactiveTrackColor: kColInactive,
              thumbColor: kColComplement,
            ),
            child: Slider(
              value: value,
              onChanged: onChanged,
              divisions: 99,
              min: 0,
              max: 1,
              label: rightLabel,
            ),
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            rightLabel,
            textAlign: TextAlign.right,
            style: kStyleBase.copyWith(
              color: Colors.amber.shade600,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}
