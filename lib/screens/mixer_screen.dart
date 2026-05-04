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
  final List<String?> _masterInserts = List<String?>.filled(kInsertSlots, null);
  final List<bool> _masterBypassed = List<bool>.filled(kInsertSlots, false);
  final List<_ReverbUiState> _masterReverbStates = List.generate(
    kInsertSlots,
    (_) => const _ReverbUiState(),
  );
  bool _insertsInitialized = false;

  static const int kInsertSlots = 6;

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
    _insertsInitialized = true;
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final tracks = state.currentPattern.tracks;
    _ensureSized(tracks.length);

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
                onVolume: (v) => state.setTrackMixerVolume(i, v),
                onPan: (v) => state.setTrackMixerPan(i, v),
                onMute: () => state.toggleTrackMixerMute(i),
                onSolo: () => state.toggleTrackMixerSolo(i),
                onInsertTap: (slot) => _onInsertSlotTap(i, slot),
                onInsertClear: (slot) {
                  setState(() {
                    _inserts[i][slot] = null;
                    _trackBypassed[i][slot] = false;
                    _trackReverbStates[i][slot] = const _ReverbUiState();
                  });
                  state.setTrackInsertOccupied(i, slot, false);
                  AudioEngine.instance.setTrackInsertEffect(i, slot, -1, 0.0);
                },
              ),
          ],
        ),
      ),
    );
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

    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: kBgTrackHeader,
      builder: (_) => const _FxPicker(),
    );

    if (picked != null) {
      setState(() => _inserts[trackIdx][slotIdx] = picked);
      state.setTrackInsertOccupied(trackIdx, slotIdx, true);

      if (picked == 'REVERB') {
        final reverbState = _trackReverbStates[trackIdx][slotIdx];
        await AudioEngine.instance.setTrackInsertEffect(trackIdx, slotIdx, 0, 0.3);
        await AudioEngine.instance.setTrackInsertMix(
          trackIdx,
          slotIdx,
          reverbState.dry,
          reverbState.wet,
        );
        await AudioEngine.instance.setTrackReverbParams(
          trackIdx,
          slotIdx,
          reverbState.roomSize,
          reverbState.damp,
          reverbState.width,
          reverbState.freeze,
        );
        await _openReverbEditor(
          onMaster: false,
          trackIdx: trackIdx,
          slotIdx: slotIdx,
        );
      } else {
        // Non-reverb inserts are UI-only for now; disable native reverb if present.
        await AudioEngine.instance.setTrackInsertEffect(trackIdx, slotIdx, -1, 0.0);
      }
    }
  }

  void _onMasterInsertTap(int slotIdx) async {
    final currentFx = _masterInserts[slotIdx];
    if (currentFx == 'REVERB') {
      await _openReverbEditor(onMaster: true, slotIdx: slotIdx);
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
        final reverbState = _masterReverbStates[slotIdx];
        await AudioEngine.instance.setMasterInsertEffect(slotIdx, 0, 0.3);
        await AudioEngine.instance.setMasterInsertMix(
          slotIdx,
          reverbState.dry,
          reverbState.wet,
        );
        await AudioEngine.instance.setMasterReverbParams(
          slotIdx,
          reverbState.roomSize,
          reverbState.damp,
          reverbState.width,
          reverbState.freeze,
        );
        await _openReverbEditor(onMaster: true, slotIdx: slotIdx);
      } else {
        // Non-reverb inserts are UI-only for now; disable native reverb if present.
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
                          activeTrackColor: kColAccent,
                          inactiveTrackColor: kColInactive,
                          thumbColor: kColAccent,
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
  final ValueChanged<double> onVolume;
  final ValueChanged<double> onPan;
  final VoidCallback onMute;
  final VoidCallback onSolo;
  final void Function(int slot) onInsertTap;
  final void Function(int slot) onInsertClear;

  const _ChannelStrip({
    required this.index,
    required this.name,
    required this.volume,
    required this.pan,
    required this.muted,
    required this.soloed,
    required this.inserts,
    required this.bypassed,
    required this.onVolume,
    required this.onPan,
    required this.onMute,
    required this.onSolo,
    required this.onInsertTap,
    required this.onInsertClear,
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
                          activeTrackColor: kColAccent,
                          inactiveTrackColor: kColInactive,
                          thumbColor: kColAccent,
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
      audioEngine.setTrackInsertBypass(widget.trackIdx ?? 0, widget.slotIdx, _bypass);
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
      audioEngine.setMasterInsertMix(
        widget.slotIdx,
        _dry,
        _wet,
      );
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
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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

class _ReverbSlider extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  const _ReverbSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final percent = (value * 99).round().clamp(0, 99).toString().padLeft(2, '0');

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
              activeTrackColor: Colors.amber.shade600,
              inactiveTrackColor: kColInactive,
              thumbColor: Colors.amber.shade600,
            ),
            child: Slider(
              value: value,
              onChanged: onChanged,
              divisions: 99,
              min: 0,
              max: 1,
              label: percent,
            ),
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            percent,
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
