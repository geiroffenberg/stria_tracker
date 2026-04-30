import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/instrument_model.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// Instrument editor screen.
///
/// Top bar : current instrument number + type selector (SAMPLER / SYNTH / …).
/// Body    : editor swapped according to the chosen [InstrumentType].
class InstrumentScreen extends StatelessWidget {
  const InstrumentScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final ins   = state.currentInstrument;

    return Container(
      color: kBgColor,
      child: Column(
        children: [
          _InstrumentHeader(state: state, instrument: ins),
          Expanded(
            child: switch (ins.type) {
              InstrumentType.simpleSynth => _SimpleSynthEditor(state: state),
              InstrumentType.sampler     => _SamplerEditor(state: state),
            },
          ),
        ],
      ),
    );
  }
}

// ── Header ───────────────────────────────────────────────────────────────────

class _InstrumentHeader extends StatelessWidget {
  final AppState state;
  final InstrumentModel instrument;
  const _InstrumentHeader({required this.state, required this.instrument});

  @override
  Widget build(BuildContext context) {
    final idx = state.currentInstrumentIndex;
    final total = state.instruments.length;

    return Container(
      height: 52,
      color: kBgTrackHeader,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          // Number stepper
          _StepArrow(
              icon: Icons.chevron_left,
              enabled: idx > 0,
              onTap: () => state.selectInstrument(idx - 1)),
          GestureDetector(
            onTap: () => _pickInstrument(context, state),
            child: Container(
              width: 76,
              alignment: Alignment.center,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'I${(idx + 1).toString().padLeft(2, '0')}',
                    style: kStyleLabel.copyWith(
                      fontSize: 22, color: kColAccent),
                  ),
                  Text('${idx + 1}/$total',
                      style: kStyleHeader.copyWith(fontSize: 10)),
                ],
              ),
            ),
          ),
          _StepArrow(
              icon: Icons.chevron_right,
              enabled: idx < total - 1,
              onTap: () => state.selectInstrument(idx + 1)),
          const SizedBox(width: 12),

          // Name
          Expanded(
            child: Text(
              instrument.name,
              style: kStyleBase.copyWith(
                  color: kColHeader, fontSize: 14),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),

          // Type selector
          _TypeButton(
            type: instrument.type,
            onPick: (t) {
              state.setInstrumentType(idx, t);
            },
          ),
        ],
      ),
    );
  }

  void _pickInstrument(BuildContext context, AppState state) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBgTrackHeader,
      builder: (ctx) => SafeArea(
        child: GridView.count(
          crossAxisCount: 4,
          padding: const EdgeInsets.all(12),
          shrinkWrap: true,
          children: [
            for (int i = 0; i < state.instruments.length; i++)
              GestureDetector(
                onTap: () {
                  state.selectInstrument(i);
                  Navigator.pop(ctx);
                },
                child: Container(
                  margin: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: i == state.currentInstrumentIndex
                        ? kColAccent.withAlpha(40)
                        : Colors.transparent,
                    border: Border.all(
                      color: i == state.currentInstrumentIndex
                          ? kColAccent : kColInactive,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    (i + 1).toString().padLeft(2, '0'),
                    style: kStyleBase.copyWith(
                      color: kColHeader, fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StepArrow extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;
  const _StepArrow({
    required this.icon, required this.enabled, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Icon(
          icon,
          color: enabled ? kColAccent : kColInactive,
          size: 28,
        ),
      ),
    );
  }
}

class _TypeButton extends StatelessWidget {
  final InstrumentType type;
  final ValueChanged<InstrumentType> onPick;
  const _TypeButton({required this.type, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        final picked = await showModalBottomSheet<InstrumentType>(
          context: context,
          backgroundColor: kBgTrackHeader,
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('INSTRUMENT TYPE',
                      style: kStyleHeader.copyWith(color: kColAccent)),
                ),
                const Divider(height: 1, color: Color(0xFF1A1A1A)),
                for (final t in InstrumentType.values)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      t == InstrumentType.simpleSynth
                          ? Icons.graphic_eq
                          : Icons.audiotrack,
                      color: t == type ? kColAccent : kColHeader,
                    ),
                    title: Text(t.label,
                        style: kStyleBase.copyWith(
                          fontSize: 14,
                          color: t == type ? kColAccent : kColHeader,
                          fontWeight:
                              t == type ? FontWeight.w700 : FontWeight.normal,
                        )),
                    onTap: () => Navigator.of(ctx).pop(t),
                  ),
              ],
            ),
          ),
        );
        if (picked != null) onPick(picked);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: kColAccent),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Row(
          children: [
            Text(type.label,
                style: kStyleBase.copyWith(
                  color: kColAccent, fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                )),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down, color: kColAccent, size: 20),
          ],
        ),
      ),
    );
  }
}

// ── Simple synth editor ──────────────────────────────────────────────────────

class _SimpleSynthEditor extends StatelessWidget {
  final AppState state;
  const _SimpleSynthEditor({required this.state});

  @override
  Widget build(BuildContext context) {
    final p = state.currentInstrument.synth;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Oscillator
          _Section(
            title: 'OSCILLATOR',
            child: Column(
              children: [
                _WaveformPicker(
                  value: p.wave,
                  onChanged: (w) {
                    p.wave = w;
                    state.instrumentParamsChanged();
                  },
                ),
                const SizedBox(height: 8),
                _Knob(
                  label: 'DETUNE',
                  value: (p.detune + 1) / 2,
                  display: '${(p.detune * 12).toStringAsFixed(1)} st',
                  onChanged: (v) {
                    p.detune = (v * 2) - 1;
                    state.instrumentParamsChanged();
                  },
                ),
              ],
            ),
          ),

          // ── Filter
          _Section(
            title: 'FILTER',
            child: Row(
              children: [
                Expanded(
                  child: _Knob(
                    label: 'CUTOFF',
                    value: p.cutoff,
                    display: '${(p.cutoff * 100).round()}%',
                    onChanged: (v) {
                      p.cutoff = v;
                      state.instrumentParamsChanged();
                    },
                  ),
                ),
                Expanded(
                  child: _Knob(
                    label: 'RES',
                    value: p.resonance,
                    display: '${(p.resonance * 100).round()}%',
                    onChanged: (v) {
                      p.resonance = v;
                      state.instrumentParamsChanged();
                    },
                  ),
                ),
              ],
            ),
          ),

          // ── Amp envelope
          _Section(
            title: 'AMP ENVELOPE',
            child: Row(
              children: [
                Expanded(child: _Knob(
                  label: 'A',
                  value: p.attack,
                  display: '${(p.attack * 100).round()}',
                  onChanged: (v) {
                    p.attack = v;
                    state.instrumentParamsChanged();
                  },
                )),
                Expanded(child: _Knob(
                  label: 'D',
                  value: p.decay,
                  display: '${(p.decay * 100).round()}',
                  onChanged: (v) {
                    p.decay = v;
                    state.instrumentParamsChanged();
                  },
                )),
                Expanded(child: _Knob(
                  label: 'S',
                  value: p.sustain,
                  display: '${(p.sustain * 100).round()}',
                  onChanged: (v) {
                    p.sustain = v;
                    state.instrumentParamsChanged();
                  },
                )),
                Expanded(child: _Knob(
                  label: 'R',
                  value: p.release,
                  display: '${(p.release * 100).round()}',
                  onChanged: (v) {
                    p.release = v;
                    state.instrumentParamsChanged();
                  },
                )),
              ],
            ),
          ),

          // ── Master
          _Section(
            title: 'MASTER',
            child: Row(
              children: [
                Expanded(child: _Knob(
                  label: 'GLIDE',
                  value: p.glide,
                  display: '${(p.glide * 100).round()}%',
                  onChanged: (v) {
                    p.glide = v;
                    state.instrumentParamsChanged();
                  },
                )),
                Expanded(child: _Knob(
                  label: 'VOLUME',
                  value: p.volume,
                  display: '${(p.volume * 100).round()}%',
                  onChanged: (v) {
                    p.volume = v;
                    state.instrumentParamsChanged();
                  },
                )),
              ],
            ),
          ),

          const SizedBox(height: 16),
          Text(
            'Audio engine wiring coming next — params are stored on the\n'
            'instrument and ready to be sent over the Oboe MethodChannel.',
            textAlign: TextAlign.center,
            style: kStyleBase.copyWith(
                color: kColInactive, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// ── Sampler editor (placeholder) ─────────────────────────────────────────────

class _SamplerEditor extends StatelessWidget {
  final AppState state;
  const _SamplerEditor({required this.state});

  @override
  Widget build(BuildContext context) {
    final p = state.currentInstrument.sampler;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Section(
            title: 'SAMPLE',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  p.sampleName ?? '— no sample loaded —',
                  style: kStyleBase.copyWith(
                    color: p.sampleName == null
                        ? kColInactive : kColHeader,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: null, // wired up later (file picker / oboe load)
                  icon: const Icon(Icons.upload_file),
                  label: const Text('LOAD SAMPLE (coming soon)'),
                ),
              ],
            ),
          ),
          _Section(
            title: 'PARAMS',
            child: Row(
              children: [
                Expanded(child: _Knob(
                  label: 'PITCH',
                  value: (p.pitch + 1) / 2,
                  display: '${(p.pitch * 12).toStringAsFixed(1)} st',
                  onChanged: (v) {
                    p.pitch = (v * 2) - 1;
                    state.instrumentParamsChanged();
                  },
                )),
                Expanded(child: _Knob(
                  label: 'VOLUME',
                  value: p.volume,
                  display: '${(p.volume * 100).round()}%',
                  onChanged: (v) {
                    p.volume = v;
                    state.instrumentParamsChanged();
                  },
                )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Reusable widgets ─────────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      decoration: BoxDecoration(
        color: kBgTrackHeader,
        border: Border.all(color: kColInactive.withAlpha(80)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(title,
                style: kStyleHeader.copyWith(
                  color: kColAccent, letterSpacing: 1.2,
                )),
          ),
          child,
        ],
      ),
    );
  }
}

class _WaveformPicker extends StatelessWidget {
  final SynthWave value;
  final ValueChanged<SynthWave> onChanged;
  const _WaveformPicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final w in SynthWave.values)
          GestureDetector(
            onTap: () => onChanged(w),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: w == value
                    ? kColAccent.withAlpha(40)
                    : Colors.transparent,
                border: Border.all(
                  color: w == value ? kColAccent : kColInactive,
                ),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                w.label,
                style: kStyleBase.copyWith(
                  fontSize: 12,
                  color: w == value ? kColAccent : kColHeader,
                  fontWeight:
                      w == value ? FontWeight.w700 : FontWeight.normal,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Vertical-drag knob with label + value readout.
/// Drag up to increase, drag down to decrease. Double-tap to reset to mid.
class _Knob extends StatelessWidget {
  final String label;
  final double value;     // 0..1
  final String display;
  final ValueChanged<double> onChanged;

  const _Knob({
    required this.label,
    required this.value,
    required this.display,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: GestureDetector(
        onVerticalDragUpdate: (d) {
          final n = (value - d.delta.dy * 0.005).clamp(0.0, 1.0);
          onChanged(n);
        },
        onDoubleTap: () => onChanged(0.5),
        child: Column(
          children: [
            SizedBox(
              width: 56, height: 56,
              child: CustomPaint(painter: _KnobPainter(value)),
            ),
            const SizedBox(height: 4),
            Text(label,
                style: kStyleBase.copyWith(
                    color: kColHeader, fontSize: 10,
                    letterSpacing: 0.8)),
            Text(display,
                style: kStyleBase.copyWith(
                    color: kColAccent, fontSize: 11,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

class _KnobPainter extends CustomPainter {
  final double value; // 0..1
  _KnobPainter(this.value);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 4;

    // Body
    canvas.drawCircle(center, radius, Paint()..color = kBgColor);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = kColInactive
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    // -135° .. +135° sweep (in screen space, with 0° at +x axis).
    final startAngle = math.pi * 3 / 4 + math.pi / 2; // bottom-left
    const sweep      = math.pi * 3 / 2;
    final angle      = startAngle + sweep * value;

    // Filled arc showing value
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweep * value,
      false,
      Paint()
        ..color = kColAccent.withAlpha(80)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 2.5,
    );

    // Indicator line
    final tip = Offset(
      center.dx + radius * 0.85 * math.cos(angle),
      center.dy + radius * 0.85 * math.sin(angle),
    );
    canvas.drawLine(
      center,
      tip,
      Paint()
        ..color = kColAccent
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(tip, 2, Paint()..color = kColAccent);
  }

  @override
  bool shouldRepaint(covariant _KnobPainter old) => old.value != value;
}