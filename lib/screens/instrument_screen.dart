import 'dart:async';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:permission_handler/permission_handler.dart';
import '../audio/audio_engine.dart';
import '../audio/wav_encoder.dart';
import '../models/instrument_model.dart';
import '../models/karplus_preset_bank.dart';
import '../models/synth_preset_bank.dart';
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
    final ins = state.currentInstrument;

    return Container(
      color: kBgColor,
      child: Column(
        children: [
          _InstrumentHeader(state: state, instrument: ins),
          Expanded(
            child: switch (ins.type) {
              InstrumentType.simpleSynth => _SimpleSynthEditor(state: state),
              InstrumentType.karplusStrong => _KarplusStrongEditor(
                state: state,
              ),
              InstrumentType.sampler => _SamplerEditor(state: state),
              InstrumentType.empty => _EmptyInstrumentPlaceholder(
                onPick: (t) =>
                    state.setInstrumentType(state.currentInstrumentIndex, t),
              ),
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
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          // Left arrow
          IconButton(
            icon: const Icon(Icons.chevron_left),
            color: kColAccent,
            iconSize: 28,
            padding: EdgeInsets.zero,
            onPressed: () => state.selectInstrument((idx - 1 + total) % total),
          ),
          // Tappable slot label — opens list
          GestureDetector(
            onTap: () => _pickInstrument(context, state),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'INSTRUMENT',
                    style: kStyleHeader.copyWith(
                      fontSize: 9,
                      color: kColHeader,
                      letterSpacing: 1.2,
                    ),
                  ),
                  Text(
                    (idx + 1).toString().padLeft(2, '0'),
                    style: kStyleBase.copyWith(
                      fontSize: 20,
                      color: kColAccent,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Right arrow
          IconButton(
            icon: const Icon(Icons.chevron_right),
            color: kColAccent,
            iconSize: 28,
            padding: EdgeInsets.zero,
            onPressed: () => state.selectInstrument((idx + 1) % total),
          ),
          const Spacer(),
          // Type selector
          _TypeButton(
            type: instrument.type,
            onPick: (t) => state.setInstrumentType(idx, t),
          ),
        ],
      ),
    );
  }

  void _pickInstrument(BuildContext context, AppState state) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBgTrackHeader,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.65,
          ),
          child: ListView.builder(
            itemCount: state.instruments.length,
            itemBuilder: (_, i) {
              final ins = state.instruments[i];
              final isCurrent = i == state.currentInstrumentIndex;
              final String sub;
              if (ins.type == InstrumentType.empty) {
                sub = '—  empty';
              } else if (ins.type == InstrumentType.sampler) {
                final sn = ins.sampler.sampleName;
                sub = sn != null && sn.isNotEmpty
                    ? 'SAMPLER  ·  $sn'
                    : 'SAMPLER  ·  no sample';
              } else if (ins.type == InstrumentType.karplusStrong) {
                sub = 'KARPLUS  ·  ${ins.name}';
              } else {
                sub = 'SYNTH  ·  ${ins.name}';
              }
              return ListTile(
                dense: true,
                leading: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isCurrent
                        ? kColAccent.withAlpha(40)
                        : Colors.transparent,
                    border: Border.all(
                      color: isCurrent ? kColAccent : kColInactive,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    (i + 1).toString().padLeft(2, '0'),
                    style: kStyleBase.copyWith(
                      fontSize: 14,
                      color: isCurrent ? kColAccent : kColHeader,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                title: Text(
                  sub,
                  style: kStyleBase.copyWith(
                    fontSize: 12,
                    color: isCurrent ? kColAccent : kColHeader,
                    fontWeight: isCurrent ? FontWeight.w700 : FontWeight.normal,
                  ),
                ),
                onTap: () {
                  state.selectInstrument(i);
                  Navigator.pop(ctx);
                },
              );
            },
          ),
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
        if (type != InstrumentType.empty) {
          // Non-empty: confirm reset before allowing type change.
          final confirm = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: kBgTrackHeader,
              title: Text(
                'RESET SLOT?',
                style: kStyleHeader.copyWith(color: kColAccent),
              ),
              content: Text(
                'Changing the instrument type will clear all data in this slot.',
                style: kStyleBase.copyWith(color: kColHeader, fontSize: 13),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(
                    'CANCEL',
                    style: kStyleBase.copyWith(color: kColInactive),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(
                    'RESET',
                    style: kStyleBase.copyWith(color: Colors.redAccent),
                  ),
                ),
              ],
            ),
          );
          if (confirm != true || !context.mounted) return;
          // Pop back to type picker after the slot is cleared.
          final state = AppStateScope.of(context);
          await state.clearInstrument(state.currentInstrumentIndex);
          return;
        }
        // Empty slot: show type picker.
        final picked = await showModalBottomSheet<InstrumentType>(
          context: context,
          backgroundColor: kBgTrackHeader,
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'INSTRUMENT TYPE',
                    style: kStyleHeader.copyWith(color: kColAccent),
                  ),
                ),
                const Divider(height: 1, color: Color(0xFF1A1A1A)),
                for (final t in [
                  InstrumentType.simpleSynth,
                  InstrumentType.karplusStrong,
                  InstrumentType.sampler,
                ])
                  ListTile(
                    dense: true,
                    leading: Icon(
                      t == InstrumentType.simpleSynth
                          ? Icons.graphic_eq
                          : t == InstrumentType.karplusStrong
                          ? Icons.music_note
                          : Icons.audiotrack,
                      color: t == type ? kColAccent : kColHeader,
                    ),
                    title: Text(
                      t.label,
                      style: kStyleBase.copyWith(
                        fontSize: 14,
                        color: t == type ? kColAccent : kColHeader,
                        fontWeight: t == type
                            ? FontWeight.w700
                            : FontWeight.normal,
                      ),
                    ),
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
            Text(
              type.label,
              style: kStyleBase.copyWith(
                color: kColAccent,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down, color: kColAccent, size: 20),
          ],
        ),
      ),
    );
  }
}

// ── Empty slot placeholder ───────────────────────────────────────────────────

class _EmptyInstrumentPlaceholder extends StatelessWidget {
  final ValueChanged<InstrumentType> onPick;
  const _EmptyInstrumentPlaceholder({required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.add_circle_outline, color: kColInactive, size: 48),
          const SizedBox(height: 16),
          Text(
            'EMPTY SLOT',
            style: kStyleHeader.copyWith(color: kColInactive, fontSize: 14),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final t in [
                InstrumentType.simpleSynth,
                InstrumentType.karplusStrong,
                InstrumentType.sampler,
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: ElevatedButton(
                    onPressed: () => onPick(t),
                    child: Text(t.label),
                  ),
                ),
            ],
          ),
        ],
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
    final presets = [...kFactorySynthPresets]
      ..sort((a, b) {
        final an = a.name.toLowerCase();
        final bn = b.name.toLowerCase();
        if (an == 'default' && bn != 'default') return -1;
        if (bn == 'default' && an != 'default') return 1;
        return an.compareTo(bn);
      });

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Section(
            title: 'PRESETS',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      final err = await state.previewCurrentSynthOneShot();
                      if (!context.mounted || err == null) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Preview failed: $err'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('PREVIEW'),
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<SynthPreset>(
                  initialValue: null,
                  isExpanded: true,
                  dropdownColor: kBgTrackHeader,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                  hint: const Text('Select preset'),
                  items: [
                    for (final preset in presets)
                      DropdownMenuItem<SynthPreset>(
                        value: preset,
                        child: Text(preset.name),
                      ),
                  ],
                  onChanged: (picked) {
                    if (picked == null) return;
                    picked.applyTo(state.currentInstrument.synth);
                    state.instrumentParamsChanged();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Loaded preset: ${picked.name}'),
                        duration: const Duration(milliseconds: 1200),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),

          // ── Oscillator 1
          _Section(
            title: 'OSC 1',
            child: Column(
              children: [
                _WaveformPicker(
                  value: p.wave,
                  onChanged: (w) {
                    p.wave = w;
                    state.instrumentParamsChanged();
                  },
                ),
                const SizedBox(height: 6),
                _OctChips(
                  value: p.osc1Oct,
                  onChanged: (oct) {
                    p.osc1Oct = oct;
                    state.instrumentParamsChanged();
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _Knob(
                        label: 'DETUNE',
                        value: (p.detune + 1) / 2,
                        display: '${(p.detune * 12).toStringAsFixed(1)} st',
                        onChanged: (v) {
                          p.detune = (v * 2) - 1;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                    Expanded(
                      child: _Knob(
                        label: 'GAIN',
                        value: p.osc1Gain,
                        display: '${(p.osc1Gain * 100).round()}%',
                        onChanged: (v) {
                          p.osc1Gain = v;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ── Oscillator 2
          _Section(
            title: 'OSC 2',
            trailing: _OscOnOffButton(
              on: p.osc2On,
              onTap: () {
                p.osc2On = !p.osc2On;
                state.instrumentParamsChanged();
              },
            ),
            child: IgnorePointer(
              ignoring: !p.osc2On,
              child: AnimatedOpacity(
                opacity: p.osc2On ? 1.0 : 0.35,
                duration: const Duration(milliseconds: 150),
                child: Column(
                  children: [
                    _WaveformPicker(
                      value: p.osc2Wave,
                      onChanged: (w) {
                        p.osc2Wave = w;
                        state.instrumentParamsChanged();
                      },
                    ),
                    const SizedBox(height: 6),
                    _OctChips(
                      value: p.osc2Oct,
                      onChanged: (oct) {
                        p.osc2Oct = oct;
                        state.instrumentParamsChanged();
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _Knob(
                            label: 'DETUNE',
                            value: (p.osc2Detune + 1) / 2,
                            display:
                                '${(p.osc2Detune * 12).toStringAsFixed(1)} st',
                            onChanged: (v) {
                              p.osc2Detune = (v * 2) - 1;
                              state.instrumentParamsChanged();
                            },
                          ),
                        ),
                        Expanded(
                          child: _Knob(
                            label: 'GAIN',
                            value: p.osc2Gain,
                            display: '${(p.osc2Gain * 100).round()}%',
                            onChanged: (v) {
                              p.osc2Gain = v;
                              state.instrumentParamsChanged();
                            },
                          ),
                        ),
                        Expanded(
                          child: _Knob(
                            label: 'FM→1',
                            value: p.osc2FmDepth,
                            display: '${(p.osc2FmDepth * 100).round()}%',
                            onChanged: (v) {
                              p.osc2FmDepth = v;
                              state.instrumentParamsChanged();
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Oscillator 3
          _Section(
            title: 'OSC 3',
            trailing: _OscOnOffButton(
              on: p.osc3On,
              onTap: () {
                p.osc3On = !p.osc3On;
                state.instrumentParamsChanged();
              },
            ),
            child: IgnorePointer(
              ignoring: !p.osc3On,
              child: AnimatedOpacity(
                opacity: p.osc3On ? 1.0 : 0.35,
                duration: const Duration(milliseconds: 150),
                child: Column(
                  children: [
                    _WaveformPicker(
                      value: p.osc3Wave,
                      onChanged: (w) {
                        p.osc3Wave = w;
                        state.instrumentParamsChanged();
                      },
                    ),
                    const SizedBox(height: 6),
                    _OctChips(
                      value: p.osc3Oct,
                      onChanged: (oct) {
                        p.osc3Oct = oct;
                        state.instrumentParamsChanged();
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _Knob(
                            label: 'DETUNE',
                            value: (p.osc3Detune + 1) / 2,
                            display:
                                '${(p.osc3Detune * 12).toStringAsFixed(1)} st',
                            onChanged: (v) {
                              p.osc3Detune = (v * 2) - 1;
                              state.instrumentParamsChanged();
                            },
                          ),
                        ),
                        Expanded(
                          child: _Knob(
                            label: 'GAIN',
                            value: p.osc3Gain,
                            display: '${(p.osc3Gain * 100).round()}%',
                            onChanged: (v) {
                              p.osc3Gain = v;
                              state.instrumentParamsChanged();
                            },
                          ),
                        ),
                        Expanded(
                          child: _Knob(
                            label: 'FM→2',
                            value: p.osc3FmDepth,
                            display: '${(p.osc3FmDepth * 100).round()}%',
                            onChanged: (v) {
                              p.osc3FmDepth = v;
                              state.instrumentParamsChanged();
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Filter
          _Section(
            title: 'FILTER',
            child: Column(
              children: [
                _FilterModePicker(
                  value: p.filterMode,
                  onChanged: (m) {
                    p.filterMode = m;
                    state.instrumentParamsChanged();
                  },
                ),
                const SizedBox(height: 8),
                Row(
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
              ],
            ),
          ),

          _Section(
            title: 'FILTER ENVELOPE',
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _Knob(
                        label: 'A',
                        value: p.filterAttack,
                        display: '${(p.filterAttack * 100).round()}',
                        onChanged: (v) {
                          p.filterAttack = v;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                    Expanded(
                      child: _Knob(
                        label: 'D',
                        value: p.filterDecay,
                        display: '${(p.filterDecay * 100).round()}',
                        onChanged: (v) {
                          p.filterDecay = v;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                    Expanded(
                      child: _Knob(
                        label: 'S',
                        value: p.filterSustain,
                        display: '${(p.filterSustain * 100).round()}',
                        onChanged: (v) {
                          p.filterSustain = v;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                    Expanded(
                      child: _Knob(
                        label: 'R',
                        value: p.filterRelease,
                        display: '${(p.filterRelease * 100).round()}',
                        onChanged: (v) {
                          p.filterRelease = v;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _Knob(
                        label: 'AMT',
                        value: p.filterEnvAmt,
                        display: '${(p.filterEnvAmt * 100).round()}%',
                        onChanged: (v) {
                          p.filterEnvAmt = v;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                    const Expanded(child: SizedBox.shrink()),
                  ],
                ),
              ],
            ),
          ),

          // ── Amp envelope
          _Section(
            title: 'AMP ENVELOPE',
            child: Row(
              children: [
                Expanded(
                  child: _Knob(
                    label: 'A',
                    value: p.attack,
                    display: '${(p.attack * 100).round()}',
                    onChanged: (v) {
                      p.attack = v;
                      state.instrumentParamsChanged();
                    },
                  ),
                ),
                Expanded(
                  child: _Knob(
                    label: 'D',
                    value: p.decay,
                    display: '${(p.decay * 100).round()}',
                    onChanged: (v) {
                      p.decay = v;
                      state.instrumentParamsChanged();
                    },
                  ),
                ),
                Expanded(
                  child: _Knob(
                    label: 'S',
                    value: p.sustain,
                    display: '${(p.sustain * 100).round()}',
                    onChanged: (v) {
                      p.sustain = v;
                      state.instrumentParamsChanged();
                    },
                  ),
                ),
                Expanded(
                  child: _Knob(
                    label: 'R',
                    value: p.release,
                    display: '${(p.release * 100).round()}',
                    onChanged: (v) {
                      p.release = v;
                      state.instrumentParamsChanged();
                    },
                  ),
                ),
              ],
            ),
          ),

          // ── Master
          _Section(
            title: 'MASTER',
            child: Row(
              children: [
                Expanded(
                  child: _Knob(
                    label: 'DRIVE',
                    value: p.drive,
                    display: '${(p.drive * 100).round()}%',
                    onChanged: (v) {
                      p.drive = v;
                      state.instrumentParamsChanged();
                    },
                  ),
                ),
                Expanded(
                  child: _Knob(
                    label: 'GLIDE',
                    value: p.glide,
                    display: '${(p.glide * 100).round()}%',
                    onChanged: (v) {
                      p.glide = v;
                      state.instrumentParamsChanged();
                    },
                  ),
                ),
                Expanded(
                  child: _Knob(
                    label: 'VOLUME',
                    value: p.volume,
                    display: '${(p.volume * 100).round()}%',
                    onChanged: (v) {
                      p.volume = v;
                      state.instrumentParamsChanged();
                    },
                  ),
                ),
              ],
            ),
          ),

          // ── LFO
          _Section(
            title: 'LFO',
            child: Column(
              children: [
                _LfoTargetPicker(
                  value: p.lfoTarget,
                  onChanged: (t) {
                    p.lfoTarget = t;
                    state.instrumentParamsChanged();
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _Knob(
                        label: 'RATE',
                        value: p.lfoRate,
                        display: '${_lfoRateDisplay(p.lfoRate)} Hz',
                        onChanged: (v) {
                          p.lfoRate = v;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                    Expanded(
                      child: _Knob(
                        label: 'DEPTH',
                        value: p.lfoDepth,
                        display: '${(p.lfoDepth * 100).round()}%',
                        onChanged: (v) {
                          p.lfoDepth = v;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          Text(
            'SYNTH params are live in the native audio engine.',
            textAlign: TextAlign.center,
            style: kStyleBase.copyWith(color: kColInactive, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _KarplusStrongEditor extends StatelessWidget {
  final AppState state;
  const _KarplusStrongEditor({required this.state});

  @override
  Widget build(BuildContext context) {
    final p = state.currentInstrument.karplus;
    final presets = [...kKarplusStrongPresets]
      ..sort((a, b) {
        final an = a.name.toLowerCase();
        final bn = b.name.toLowerCase();
        if (an == 'default' && bn != 'default') return -1;
        if (bn == 'default' && an != 'default') return 1;
        return an.compareTo(bn);
      });

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Section(
            title: 'PRESETS',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      final err = await state.previewCurrentKarplusOneShot();
                      if (!context.mounted || err == null) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Preview failed: $err'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('PREVIEW'),
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<KarplusStrongPreset>(
                  initialValue: null,
                  isExpanded: true,
                  dropdownColor: kBgTrackHeader,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                  hint: const Text('Select preset'),
                  items: [
                    for (final preset in presets)
                      DropdownMenuItem<KarplusStrongPreset>(
                        value: preset,
                        child: Text(preset.name),
                      ),
                  ],
                  onChanged: (picked) {
                    if (picked == null) return;
                    picked.applyTo(state.currentInstrument.karplus);
                    state.instrumentParamsChanged();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Loaded preset: ${picked.name}'),
                        duration: const Duration(milliseconds: 1200),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          _Section(
            title: 'STRING MODEL',
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _Knob(
                        label: 'DECAY',
                        value: p.decay,
                        display: '${(p.decay * 100).round()}%',
                        onChanged: (v) {
                          p.decay = v;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                    Expanded(
                      child: _Knob(
                        label: 'DAMP',
                        value: p.damping,
                        display: '${(p.damping * 100).round()}%',
                        onChanged: (v) {
                          p.damping = v;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                    Expanded(
                      child: _Knob(
                        label: 'TONE',
                        value: p.tone,
                        display: '${(p.tone * 100).round()}%',
                        onChanged: (v) {
                          p.tone = v;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                    Expanded(
                      child: _Knob(
                        label: 'STRETCH',
                        value: p.stretch,
                        display: '${(p.stretch * 100).round()}%',
                        onChanged: (v) {
                          p.stretch = v;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: _Knob(
                        label: 'PICK POS',
                        value: p.pickPosition,
                        display: '${(p.pickPosition * 100).round()}%',
                        onChanged: (v) {
                          p.pickPosition = v;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                    Expanded(
                      child: _Knob(
                        label: 'ATTACK',
                        value: p.attackColor,
                        display: '${(p.attackColor * 100).round()}%',
                        onChanged: (v) {
                          p.attackColor = v;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                    Expanded(
                      child: _Knob(
                        label: 'BODY',
                        value: p.body,
                        display: '${(p.body * 100).round()}%',
                        onChanged: (v) {
                          p.body = v;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                    Expanded(
                      child: _Knob(
                        label: 'DRIVE',
                        value: p.drive,
                        display: '${(p.drive * 100).round()}%',
                        onChanged: (v) {
                          p.drive = v;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Karplus params are live in the native audio engine.',
                  style: kStyleBase.copyWith(color: kColInactive, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Sampler editor (placeholder) ─────────────────────────────────────────────

class _SamplerEditor extends StatefulWidget {
  final AppState state;
  const _SamplerEditor({required this.state});

  @override
  State<_SamplerEditor> createState() => _SamplerEditorState();
}

class _SamplerEditorState extends State<_SamplerEditor>
    with TickerProviderStateMixin {
  static const _kSampleExts = <String>{
    '.wav',
    '.aif',
    '.aiff',
    '.flac',
    '.ogg',
    '.mp3',
    '.m4a',
    '.aac',
  };

  bool _busy = false;
  bool _previewBusy = false;
  bool _slicesOpen = false;
  String? _wavePath;
  String? _lastBrowserFolder;
  List<double>? _wavePeaks;
  bool _waveLoading = false;
  Ticker? _playheadTicker;

  // Recording state
  bool _isRecording = false;
  Ticker? _recordingTimer;
  DateTime? _recordingStart;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _syncWaveformForCurrent();
    // Open the mic input stream now so it's warm before the first RECORD press.
    // Keeps Android in duplex mode continuously, eliminating the hardware
    // route-change transient that causes a burst at the start of each take.
    AudioEngine.instance.openRecordingStream();
  }

  void _syncPlayheadTicker(bool shouldRun) {
    if (shouldRun) {
      _playheadTicker ??= createTicker((_) {
        if (!mounted) return;
        setState(() {});
      });
      if (!_playheadTicker!.isActive) {
        _playheadTicker!.start();
      }
      return;
    }
    _playheadTicker?.stop();
    _playheadTicker?.dispose();
    _playheadTicker = null;
  }

  @override
  void dispose() {
    _playheadTicker?.stop();
    _playheadTicker?.dispose();
    _playheadTicker = null;
    _recordingTimer?.stop();
    _recordingTimer?.dispose();
    _recordingTimer = null;
    AudioEngine.instance.closeRecordingStream();
    super.dispose();
  }

  bool _isLegalSamplePath(String path) {
    final name = _sampleDisplayName(path).toLowerCase();
    return _kSampleExts.any(name.endsWith);
  }

  String _sampleDisplayName(String path) =>
      path.split(Platform.pathSeparator).last;

  String _folderDisplayName(String path) {
    final parts = path.split(Platform.pathSeparator).where((p) => p.isNotEmpty);
    return parts.isEmpty ? path : parts.last;
  }

  List<String> _collectSubFolders(String folderPath) {
    try {
      final dir = Directory(folderPath);
      if (!dir.existsSync()) return const [];
      final dirs = <String>[];
      for (final e in dir.listSync()) {
        final t = FileSystemEntity.typeSync(e.path, followLinks: true);
        if (t == FileSystemEntityType.directory) {
          dirs.add(e.path);
        }
      }
      dirs.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return dirs;
    } catch (_) {
      return const [];
    }
  }

  List<String> _collectPlayableSamples(String folderPath) {
    try {
      final dir = Directory(folderPath);
      if (!dir.existsSync()) return const [];
      final samples = <String>[];
      for (final e in dir.listSync()) {
        final t = FileSystemEntity.typeSync(e.path, followLinks: true);
        if (t != FileSystemEntityType.file) continue;
        if (_isLegalSamplePath(e.path)) samples.add(e.path);
      }
      samples.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return samples;
    } catch (_) {
      return const [];
    }
  }

  Future<bool> _requestStoragePermission() async {
    // Android 13+ uses READ_MEDIA_AUDIO; older versions use READ_EXTERNAL_STORAGE
    final status = await Permission.audio.request();
    if (status.isGranted) return true;
    final statusStorage = await Permission.storage.request();
    return statusStorage.isGranted;
  }

  /// Returns the single internal-storage root for Android.
  String _internalStorageRoot() {
    const candidates = [
      '/storage/emulated/0',
      '/storage/self/primary',
      '/sdcard',
    ];
    for (final p in candidates) {
      try {
        if (Directory(p).existsSync()) return p;
      } catch (_) {}
    }
    return '/storage/emulated/0';
  }

  Future<void> _showSampleBrowser(BuildContext context) async {
    // Request storage permission at runtime
    if (Platform.isAndroid) {
      final status = await _requestStoragePermission();
      if (!status) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Storage permission denied — cannot browse files.'),
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }
    }

    final internalRoot = _internalStorageRoot();
    final savedDefault = state.defaultSampleFolder;
    final startFolder =
        (savedDefault != null && Directory(savedDefault).existsSync())
        ? savedDefault
        : internalRoot;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBgTrackHeader,
      isScrollControlled: true,
      builder: (ctx) {
        // Start at last remembered folder, else user default folder, else
        // internal storage root.
        String currentFolder = _lastBrowserFolder ?? startFolder;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.7,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: () {
                              final parent = Directory(
                                currentFolder,
                              ).parent.path;
                              if (parent == currentFolder ||
                                  parent.isEmpty ||
                                  currentFolder == internalRoot) {
                                Navigator.of(ctx).pop();
                                return;
                              }
                              currentFolder = parent;
                              setSheetState(() {});
                            },
                            icon: const Icon(Icons.arrow_upward),
                          ),
                          Expanded(
                            child: Text(
                              currentFolder == internalRoot
                                  ? 'INTERNAL STORAGE'
                                  : currentFolder,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: kStyleHeader.copyWith(color: kColAccent),
                            ),
                          ),
                          Text(
                            'Default',
                            style: kStyleHeader.copyWith(
                              color: state.defaultSampleFolder == currentFolder
                                  ? kColAccent
                                  : kColHeader,
                            ),
                          ),
                          IconButton(
                            tooltip:
                                'Set current folder as default sample folder',
                            onPressed: () async {
                              await state.setDefaultSampleFolder(currentFolder);
                              _lastBrowserFolder = currentFolder;
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Default sample folder updated.',
                                  ),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                              setSheetState(() {});
                            },
                            icon: Icon(
                              state.defaultSampleFolder == currentFolder
                                  ? Icons.bookmark
                                  : Icons.bookmark_border,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: Color(0xFF1A1A1A)),
                    Expanded(
                      child: Builder(
                        builder: (_) {
                          final activeFolder = currentFolder;
                          final folders = _collectSubFolders(activeFolder);
                          final samples = _collectPlayableSamples(activeFolder);

                          return ListView(
                            children: [
                              for (final folderPath in folders)
                                ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.folder),
                                  title: Text(
                                    _folderDisplayName(folderPath),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: kStyleBase.copyWith(
                                      color: kColHeader,
                                    ),
                                  ),
                                  onTap: () {
                                    currentFolder = folderPath;
                                    _lastBrowserFolder = folderPath;
                                    setSheetState(() {});
                                  },
                                ),
                              if (samples.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(
                                    'No playable samples in this folder.',
                                    style: kStyleBase.copyWith(
                                      color: kColInactive,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              for (final samplePath in samples)
                                Builder(
                                  builder: (_) {
                                    final name = _sampleDisplayName(samplePath);
                                    final isLoaded =
                                        state
                                            .currentInstrument
                                            .sampler
                                            .samplePath ==
                                        samplePath;
                                    final isPlaying =
                                        isLoaded &&
                                        state.isPreviewingCurrentSampler;
                                    return ListTile(
                                      dense: true,
                                      leading: IconButton(
                                        icon: Icon(
                                          isPlaying
                                              ? Icons.stop
                                              : Icons.play_arrow,
                                        ),
                                        color: isPlaying
                                            ? kColAccent
                                            : kColHeader,
                                        onPressed: () async {
                                          String? err;
                                          if (isPlaying) {
                                            await state
                                                .stopPreviewCurrentSampler();
                                          } else {
                                            err = await state
                                                .loadSamplerSampleFromPath(
                                                  samplePath,
                                                  displayName: name,
                                                );
                                            err ??= await state
                                                .startPreviewCurrentSampler();
                                          }
                                          setSheetState(() {});
                                          if (!mounted || err == null) return;
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(err),
                                              duration: const Duration(
                                                seconds: 2,
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                      title: Text(
                                        name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: kStyleBase.copyWith(
                                          color: isLoaded
                                              ? kColAccent
                                              : kColHeader,
                                          fontWeight: isLoaded
                                              ? FontWeight.w700
                                              : FontWeight.normal,
                                        ),
                                      ),
                                      trailing: TextButton(
                                        onPressed: () async {
                                          final err = await state
                                              .loadSamplerSampleFromPath(
                                                samplePath,
                                                displayName: name,
                                              );
                                          if (!mounted || err == null) {
                                            Navigator.of(ctx).pop();
                                            return;
                                          }
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(err),
                                              duration: const Duration(
                                                seconds: 2,
                                              ),
                                            ),
                                          );
                                        },
                                        child: const Text('LOAD'),
                                      ),
                                    );
                                  },
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showRecordingWindow(BuildContext context) async {
    // Request storage permission at runtime
    if (Platform.isAndroid) {
      final status = await _requestStoragePermission();
      if (!status) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Storage permission denied — cannot record files.'),
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }
    }

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBgTrackHeader,
      isScrollControlled: true,
      isDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'RECORD SAMPLE',
                          style: kStyleHeader.copyWith(color: kColAccent),
                        ),
                        if (!_isRecording)
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => Navigator.of(ctx).pop(),
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    if (_isRecording) ...[
                      // Recording in progress UI
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.red.withAlpha(30),
                          border: Border.all(
                            color: Colors.red.shade700,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: Colors.red,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'RECORDING...',
                                  style: kStyleHeader.copyWith(
                                    color: Colors.red.shade700,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _recordingStart == null
                                  ? '0:00'
                                  : _formatDuration(
                                      DateTime.now().difference(
                                        _recordingStart!,
                                      ),
                                    ),
                              style: kStyleBase.copyWith(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: () async {
                          await _stopRecording(context, setSheetState);
                          if (!ctx.mounted) return;
                        },
                        icon: const Icon(Icons.stop),
                        label: const Text('STOP RECORDING'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red.shade700,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ] else ...[
                      // Pre-recording UI
                      Text(
                        'Recording will be saved to project samples folder',
                        style: kStyleBase.copyWith(
                          color: kColInactive,
                          fontSize: 12,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: () async {
                          await _startRecording(setSheetState);
                          if (!ctx.mounted) return;
                        },
                        icon: const Icon(Icons.fiber_manual_record),
                        label: const Text('START RECORDING'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red.shade700,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    // Clean up recording state when sheet is dismissed
    if (mounted && _isRecording) {
      await _stopRecording(context, (f) {});
    }
  }

  Future<void> _startRecording(StateSetter setSheetState) async {
    // Request microphone permission before opening the native stream
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Microphone permission denied'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    try {
      await AudioEngine.instance.startRecording();

      setState(() {
        _isRecording = true;
        _recordingStart = DateTime.now();
      });

      setSheetState(() {});

      // Update ticker for duration display
      // Stop any existing ticker before creating a new one
      _recordingTimer?.stop();
      _recordingTimer?.dispose();
      _recordingTimer = createTicker((_) {
        if (mounted && _isRecording) {
          setSheetState(() {});
        }
      });
      _recordingTimer!.start();
    } catch (e) {
      if (mounted) {
        setState(() => _isRecording = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Recording failed: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _stopRecording(
    BuildContext context,
    StateSetter setSheetState,
  ) async {
    _recordingTimer?.stop();
    _recordingTimer?.dispose();
    _recordingTimer = null;

    if (!mounted) return;

    try {
      final recordingResult = await AudioEngine.instance.stopRecording();

      setState(() => _isRecording = false);
      setSheetState(() {});

      if (recordingResult == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Recording failed: no audio data'),
            duration: Duration(seconds: 2),
          ),
        );
        return;
      }

      final samples = recordingResult['samples'] as List<dynamic>? ?? [];
      final sampleRate = recordingResult['sampleRate'] as int? ?? 44100;

      if (samples.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Recording is empty'),
            duration: Duration(seconds: 2),
          ),
        );
        return;
      }

      final rawSamples = samples.cast<double>();

      // Successive takes (especially after preview) can include a startup burst.
      // Use adaptive head trim: always trim a minimum, then keep trimming while
      // the short-window average absolute amplitude is still "hot".
      final minTrimFrames = (sampleRate * 0.06).round();
      final maxSearchFrames = (sampleRate * 0.35).round();
      final windowFrames = (sampleRate * 0.02).round().clamp(8, 4096);
      final stepFrames = (windowFrames ~/ 2).clamp(1, 2048);
      int startupTrim = minTrimFrames.clamp(
        0,
        rawSamples.length > 1 ? rawSamples.length - 1 : 0,
      );
      final searchLimit = maxSearchFrames.clamp(0, rawSamples.length);
      const hotThreshold =
          0.08; // average |sample| above this is likely transient
      while (startupTrim + windowFrames < searchLimit) {
        double sumAbs = 0.0;
        for (int i = startupTrim; i < startupTrim + windowFrames; i++) {
          sumAbs += rawSamples[i].abs();
        }
        final avgAbs = sumAbs / windowFrames;
        if (avgAbs <= hotThreshold) break;
        startupTrim += stepFrames;
      }
      final trimmedSamples = startupTrim > 0 && rawSamples.length > startupTrim
          ? rawSamples.sublist(startupTrim)
          : rawSamples;

      // Normalize to peak 0.9 so quiet mic input is brought up to a useful level.
      final peak = trimmedSamples.fold<double>(
        0.0,
        (m, s) => s.abs() > m ? s.abs() : m,
      );
      final normalizedSamples = peak > 0.0
          ? trimmedSamples.map((s) => (s / peak) * 0.9).toList()
          : List<double>.from(trimmedSamples);

      // Tiny endpoint fades prevent discontinuity clicks.
      final fadeSamples = ((sampleRate * 0.005).round()).clamp(
        0,
        normalizedSamples.length ~/ 2,
      );
      for (int i = 0; i < fadeSamples; i++) {
        final gain = i / fadeSamples;
        normalizedSamples[i] *= gain;
        final tailIndex = normalizedSamples.length - 1 - i;
        normalizedSamples[tailIndex] *= gain;
      }

      // Encode as WAV and save
      final wavPath = await _saveRecordedSample(normalizedSamples, sampleRate);

      if (wavPath == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to save recording'),
            duration: Duration(seconds: 2),
          ),
        );
        return;
      }

      // Load the recording into the sampler
      final displayName = wavPath.split(Platform.pathSeparator).last;
      final err = await state.loadSamplerSampleFromPath(
        wavPath,
        displayName: displayName,
      );

      if (!mounted) return;

      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Load failed: $err'),
            duration: const Duration(seconds: 2),
          ),
        );
        return;
      }

      // Close the recording window
      Navigator.of(context).pop();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Recording saved and loaded'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          duration: const Duration(seconds: 2),
        ),
      );
      setState(() => _isRecording = false);
      setSheetState(() {});
    }
  }

  Future<String?> _saveRecordedSample(
    List<double> samples,
    int sampleRate,
  ) async {
    try {
      final lib = await state.currentProjectSamplesDir();

      // Generate filename with timestamp
      final now = DateTime.now();
      final timestamp =
          '${now.year}${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}_'
          '${now.hour.toString().padLeft(2, '0')}'
          '${now.minute.toString().padLeft(2, '0')}'
          '${now.second.toString().padLeft(2, '0')}';
      final filename = 'rec_$timestamp.wav';
      final filepath = '${lib.path}/$filename';

      // Encode and save WAV
      final wavData = WavEncoder.encodeWav(
        samples: samples,
        sampleRate: sampleRate,
        numChannels: 1,
      );

      await File(filepath).writeAsBytes(wavData, flush: true);
      return filepath;
    } catch (e) {
      return null;
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _syncWaveformForCurrent() async {
    final path = state.currentInstrument.sampler.samplePath;
    _wavePath = path;
    if (path == null || path.isEmpty) {
      if (!mounted) return;
      setState(() {
        _wavePeaks = null;
        _waveLoading = false;
      });
      return;
    }

    if (!mounted) return;
    setState(() => _waveLoading = true);
    final peaks = await _readWavPeaks(path, 220);
    if (!mounted || _wavePath != path) return;
    setState(() {
      _wavePeaks = peaks;
      _waveLoading = false;
    });
  }

  Future<List<double>?> _readWavPeaks(String path, int bins) async {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.length < 44) return null;

      bool matchAscii(int off, String s) {
        if (off + s.length > bytes.length) return false;
        for (int i = 0; i < s.length; i++) {
          if (bytes[off + i] != s.codeUnitAt(i)) return false;
        }
        return true;
      }

      if (!matchAscii(0, 'RIFF') || !matchAscii(8, 'WAVE')) return null;

      final bd = ByteData.sublistView(bytes);
      int readLe16(int o) => bd.getUint16(o, Endian.little);
      int readLe32(int o) => bd.getUint32(o, Endian.little);

      int audioFormat = 0;
      int channels = 0;
      int bitsPerSample = 0;
      int dataOffset = -1;
      int dataSize = 0;

      int pos = 12;
      while (pos + 8 <= bytes.length) {
        final chunkSize = readLe32(pos + 4);
        final body = pos + 8;
        if (body + chunkSize > bytes.length) break;

        if (matchAscii(pos, 'fmt ') && chunkSize >= 16) {
          audioFormat = readLe16(body + 0);
          channels = readLe16(body + 2);
          bitsPerSample = readLe16(body + 14);
        } else if (matchAscii(pos, 'data')) {
          dataOffset = body;
          dataSize = chunkSize;
        }

        pos = body + chunkSize + (chunkSize.isOdd ? 1 : 0);
      }

      if (dataOffset < 0 ||
          dataSize <= 0 ||
          channels <= 0 ||
          bitsPerSample <= 0) {
        return null;
      }

      final bytesPerSample = bitsPerSample ~/ 8;
      final frameBytes = bytesPerSample * channels;
      if (bytesPerSample <= 0 || frameBytes <= 0) return null;

      final frameCount = dataSize ~/ frameBytes;
      if (frameCount <= 0) return null;

      final safeBins = bins.clamp(32, 480);
      final peaks = List<double>.filled(safeBins, 0.0);
      final framesPerBin = (frameCount / safeBins).ceil().clamp(1, frameCount);

      for (int b = 0; b < safeBins; b++) {
        final startFrame = b * framesPerBin;
        if (startFrame >= frameCount) break;
        final endFrame = math.min(frameCount, startFrame + framesPerBin);
        double maxAbs = 0.0;

        for (int f = startFrame; f < endFrame; f++) {
          final frameBase = dataOffset + f * frameBytes;
          double mono = 0.0;

          for (int ch = 0; ch < channels; ch++) {
            final sampleOff = frameBase + ch * bytesPerSample;
            double sample = 0.0;
            if (audioFormat == 1 && bitsPerSample == 8) {
              sample = (bytes[sampleOff] - 128) / 128.0;
            } else if (audioFormat == 1 && bitsPerSample == 16) {
              sample = bd.getInt16(sampleOff, Endian.little) / 32768.0;
            } else if (audioFormat == 1 && bitsPerSample == 24) {
              final raw =
                  bytes[sampleOff] |
                  (bytes[sampleOff + 1] << 8) |
                  (bytes[sampleOff + 2] << 16);
              final signed = (raw & 0x800000) != 0 ? (raw | ~0xFFFFFF) : raw;
              sample = signed / 8388608.0;
            } else if (audioFormat == 3 && bitsPerSample == 32) {
              sample = bd.getFloat32(sampleOff, Endian.little);
            } else {
              return null;
            }
            mono += sample;
          }
          mono /= channels;
          final absV = mono.abs();
          if (absV > maxAbs) maxAbs = absV;
        }
        peaks[b] = maxAbs.clamp(0.0, 1.0);
      }

      return peaks;
    } catch (_) {
      return null;
    }
  }

  Future<void> _chopToNewSlot(BuildContext context) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final err = await state.chopToNewSlot();
      if (!mounted) return;
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Chop failed: $err'),
            duration: const Duration(seconds: 3),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Chopped to new slot'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chopAllSlicesToNewSlots(BuildContext context) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final err = await state.chopAllSlicesToNewSlots();
      if (!mounted) return;
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Chop failed: $err'),
            duration: const Duration(seconds: 3),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Slices chopped to new slots'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cropCurrentSample(BuildContext context) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final err = await state.cropCurrentSamplerToNewSample();
      if (!mounted) return;
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Crop failed: $err'),
            duration: const Duration(seconds: 3),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cropped current sample'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _previewFromWaveTap(
    BuildContext context,
    TapDownDetails details,
    double width,
    SamplerParams p,
  ) async {
    if (_previewBusy || p.samplePath == null || width <= 0) return;
    // If already previewing, stop and return — tap acts as stop button.
    if (state.isPreviewingCurrentSampler) {
      await state.stopPreviewCurrentSampler();
      return;
    }
    setState(() => _previewBusy = true);
    try {
      final tapNorm = (details.localPosition.dx / width).clamp(0.0, 1.0);
      final regionStart = p.start.clamp(0.0, 1.0);
      final regionEnd = p.end.clamp(regionStart + 0.001, 1.0);

      final activeSlices = <MapEntry<int, double>>[];
      for (int i = 0; i < p.sliceStarts.length; i++) {
        final v = p.sliceStarts[i];
        if (v <= 0) continue;
        final start = (v / 99.0).clamp(regionStart, regionEnd);
        activeSlices.add(MapEntry(i + 1, start));
      }
      activeSlices.sort((a, b) => a.value.compareTo(b.value));

      final boundaries = <double>[regionStart];
      boundaries.addAll(activeSlices.map((e) => e.value));
      boundaries.add(regionEnd);

      double start = regionStart;
      double end = regionEnd;
      for (int i = 0; i < boundaries.length - 1; i++) {
        final segStart = boundaries[i];
        final segEnd = boundaries[i + 1];
        final isLast = i == boundaries.length - 2;
        if ((tapNorm >= segStart && tapNorm < segEnd) ||
            (isLast && tapNorm >= segEnd)) {
          start = segStart;
          end = segEnd;
          break;
        }
      }

      if (end < start + 0.001) {
        end = (start + 0.01).clamp(start + 0.001, 1.0);
      }

      final err = await state.previewCurrentSamplerRegion(
        startNorm: start,
        endNorm: end,
      );
      if (!mounted || err == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Preview failed: $err'),
          duration: const Duration(seconds: 2),
        ),
      );
    } finally {
      if (mounted) setState(() => _previewBusy = false);
    }
  }

  Widget _buildSliceEditor(SamplerParams p) {
    return _Section(
      title: 'SLICES',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: () => setState(() => _slicesOpen = !_slicesOpen),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: kBgColor.withAlpha(60),
                border: Border.all(color: kColInactive.withAlpha(90)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _slicesOpen
                          ? 'SL0 = normal start, SL1-SL9 = slice starts'
                          : 'Open slice starts (SL1-SL9)',
                      style: kStyleBase.copyWith(
                        color: kColHeader,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    _slicesOpen ? 'HIDE' : 'OPEN',
                    style: kStyleHeader.copyWith(
                      fontSize: 11,
                      color: kColAccent,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _slicesOpen ? Icons.expand_less : Icons.expand_more,
                    color: kColAccent,
                  ),
                ],
              ),
            ),
          ),
          if (_slicesOpen) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    for (int i = 0; i < SamplerParams.sliceCount; i++) {
                      p.setSliceStart(i, 0);
                    }
                  });
                  state.instrumentParamsChanged();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: kBgColor.withAlpha(60),
                    border: Border.all(color: kColInactive.withAlpha(90)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'RESET ALL',
                    style: kStyleHeader.copyWith(
                      fontSize: 11,
                      color: kColAccent,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            for (int i = 0; i < SamplerParams.sliceCount; i++)
              Padding(
                padding: EdgeInsets.only(
                  bottom: i == SamplerParams.sliceCount - 1 ? 0 : 8,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 38,
                      child: Text(
                        'SL${i + 1}',
                        style: kStyleHeader.copyWith(
                          fontSize: 11,
                          color: kColHeader,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        value: p.sliceStarts[i].toDouble(),
                        min: 0,
                        max: 99,
                        divisions: 99,
                        activeColor: kColComplement,
                        inactiveColor: kColInactive.withAlpha(70),
                        onChanged: (v) {
                          setState(() {
                            p.setSliceStart(i, v.round());
                          });
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                    SizedBox(
                      width: 28,
                      child: Text(
                        p.sliceStarts[i].toString().padLeft(2, '0'),
                        textAlign: TextAlign.right,
                        style: kStyleBase.copyWith(
                          color: p.sliceStarts[i] == 0
                              ? kColInactive
                              : Colors.amber.shade600,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: _busy ? null : () => _chopAllSlicesToNewSlots(context),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: kBgColor.withAlpha(60),
                  border: Border.all(
                    color: _busy
                        ? kColInactive.withAlpha(60)
                        : kColAccent.withAlpha(160),
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.content_cut,
                      size: 14,
                      color: _busy ? kColInactive : kColAccent,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'CHOP ALL SLICES TO NEW INSTRUMENTS',
                      style: kStyleHeader.copyWith(
                        fontSize: 11,
                        color: _busy ? kColInactive : kColAccent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = state.currentInstrument.sampler;
    final isPreviewing = state.isPreviewingCurrentSampler;
    _syncPlayheadTicker(isPreviewing);
    if (_wavePath != p.samplePath && !_waveLoading) {
      _syncWaveformForCurrent();
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Section(
            title: 'SAMPLE',
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : () => _showSampleBrowser(context),
                    icon: const Icon(Icons.folder_open),
                    label: const Text('LOAD SAMPLE'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_busy || isPreviewing)
                        ? null
                        : () => _showRecordingWindow(context),
                    icon: const Icon(Icons.mic),
                    label: const Text('RECORD'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Delete sample',
                  onPressed: (_busy || p.samplePath == null)
                      ? null
                      : () {
                          state.clearCurrentSamplerSample();
                        },
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
          _Section(
            title: (p.sampleName != null && p.sampleName!.isNotEmpty)
                ? p.sampleName!
                : 'PREVIEW',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) {
                        _previewFromWaveTap(
                          context,
                          details,
                          constraints.maxWidth,
                          p,
                        );
                      },
                      child: Container(
                        height: 92,
                        decoration: BoxDecoration(
                          color: kBgColor.withAlpha(70),
                          border: Border.all(color: kColInactive.withAlpha(90)),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: _waveLoading
                            ? Center(
                                child: Text(
                                  'Loading waveform...',
                                  style: kStyleBase.copyWith(
                                    color: kColInactive,
                                    fontSize: 12,
                                  ),
                                ),
                              )
                            : (_wavePeaks == null || _wavePeaks!.isEmpty)
                            ? Center(
                                child: Text(
                                  'Empty',
                                  style: kStyleBase.copyWith(
                                    color: kColInactive,
                                    fontSize: 12,
                                  ),
                                ),
                              )
                            : CustomPaint(
                                painter: _SampleWaveformPainter(
                                  peaks: _wavePeaks!,
                                  waveColor: kColAccent,
                                  axisColor: kColInactive,
                                  startNorm: p.start,
                                  endNorm: p.end,
                                  sliceMarkers: [
                                    for (
                                      int i = 0;
                                      i < p.sliceStarts.length;
                                      i++
                                    )
                                      if (p.sliceStarts[i] > 0)
                                        MapEntry(
                                          i + 1,
                                          p.sliceStarts[i] / 99.0,
                                        ),
                                  ],
                                  previewStartNorm:
                                      state.currentSamplerPreviewStartNorm,
                                  previewEndNorm:
                                      state.currentSamplerPreviewEndNorm,
                                  playheadNorm: state.currentSamplerPreviewNorm,
                                  showPlayhead: isPreviewing,
                                ),
                                child: const SizedBox.expand(),
                              ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          _buildSliceEditor(p),
          _Section(
            title: 'PARAMS',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Start / End sliders ──────────────────────────────────
                Text(
                  'START  ${(p.start * 100).round()}%',
                  style: kStyleHeader.copyWith(fontSize: 11, color: kColHeader),
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: kColComplement,
                    inactiveTrackColor: kColInactive.withAlpha(80),
                    thumbColor: kColComplement,
                    overlayShape: SliderComponentShape.noOverlay,
                  ),
                  child: Slider(
                    value: p.start,
                    onChanged: (v) {
                      p.start = v.clamp(0.0, 1.0);
                      if (p.end < p.start + 0.01) {
                        p.end = (p.start + 0.01).clamp(0.0, 1.0);
                      }
                      state.instrumentParamsChanged();
                    },
                  ),
                ),
                Text(
                  'END  ${(p.end * 100).round()}%',
                  style: kStyleHeader.copyWith(fontSize: 11, color: kColHeader),
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: kColComplement,
                    inactiveTrackColor: kColInactive.withAlpha(80),
                    thumbColor: kColComplement,
                    overlayShape: SliderComponentShape.noOverlay,
                  ),
                  child: Slider(
                    value: p.end,
                    onChanged: (v) {
                      p.end = v.clamp(0.0, 1.0);
                      if (p.end < p.start + 0.01) {
                        p.start = (p.end - 0.01).clamp(0.0, 1.0);
                      }
                      state.instrumentParamsChanged();
                    },
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: (_busy || p.samplePath == null)
                            ? null
                            : () => _chopToNewSlot(context),
                        icon: const Icon(Icons.call_split),
                        label: const Text('CHOP TO SLOT'),
                        style: ElevatedButton.styleFrom(
                          foregroundColor: kColAccent,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: (_busy || p.samplePath == null)
                            ? null
                            : () => _cropCurrentSample(context),
                        icon: const Icon(Icons.content_cut),
                        label: const Text('CROP CURRENT'),
                        style: ElevatedButton.styleFrom(
                          foregroundColor: kColAccent,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // ── Knob row: Pitch · Volume · Attack · Release ──────────
                Row(
                  children: [
                    Expanded(
                      child: _Knob(
                        label: 'PITCH',
                        value: (p.pitch + 1) / 2,
                        display: '${(p.pitch * 12).toStringAsFixed(1)} st',
                        onChanged: (v) {
                          p.pitch = (v * 2) - 1;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                    Expanded(
                      child: _Knob(
                        label: 'VOLUME',
                        value: p.volume,
                        display: '${(p.volume * 100).round()}%',
                        onChanged: (v) {
                          p.volume = v;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                    Expanded(
                      child: _Knob(
                        label: 'ATTACK',
                        value: p.attack,
                        display: '${(p.attack * 500).round()} ms',
                        onChanged: (v) {
                          p.attack = v;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                    Expanded(
                      child: _Knob(
                        label: 'RELEASE',
                        value: p.release,
                        display: '${(p.release * 500).round()} ms',
                        onChanged: (v) {
                          p.release = v;
                          state.instrumentParamsChanged();
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // ── Loop mode: OFF · LOOP · PING ─────────────────────────
                Row(
                  children: [
                    Text(
                      'LOOP',
                      style: kStyleHeader.copyWith(
                        fontSize: 11,
                        color: kColHeader,
                      ),
                    ),
                    const SizedBox(width: 12),
                    for (final mode in SamplerLoopMode.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: GestureDetector(
                          onTap: () {
                            p.loopMode = mode;
                            state.instrumentParamsChanged();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: p.loopMode == mode
                                  ? kColAccent.withAlpha(40)
                                  : Colors.transparent,
                              border: Border.all(
                                color: p.loopMode == mode
                                    ? kColAccent
                                    : kColInactive,
                              ),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              mode.label,
                              style: kStyleHeader.copyWith(
                                fontSize: 11,
                                color: p.loopMode == mode
                                    ? kColAccent
                                    : kColInactive,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SampleWaveformPainter extends CustomPainter {
  final List<double> peaks;
  final Color waveColor;
  final Color axisColor;
  final double startNorm;
  final double endNorm;
  final List<MapEntry<int, double>> sliceMarkers;
  final double previewStartNorm;
  final double previewEndNorm;
  final double playheadNorm;
  final bool showPlayhead;

  const _SampleWaveformPainter({
    required this.peaks,
    required this.waveColor,
    required this.axisColor,
    required this.startNorm,
    required this.endNorm,
    required this.sliceMarkers,
    required this.previewStartNorm,
    required this.previewEndNorm,
    required this.playheadNorm,
    required this.showPlayhead,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final s = startNorm.clamp(0.0, 1.0);
    final e = endNorm.clamp(0.0, 1.0);
    final leftX = size.width * math.min(s, e);
    final rightX = size.width * math.max(s, e);

    // Dim non-selected regions so sample start/end is obvious.
    final dim = Paint()..color = axisColor.withAlpha(42);
    if (leftX > 0) {
      canvas.drawRect(Rect.fromLTWH(0, 0, leftX, size.height), dim);
    }
    if (rightX < size.width) {
      canvas.drawRect(
        Rect.fromLTWH(rightX, 0, size.width - rightX, size.height),
        dim,
      );
    }

    final centerY = size.height / 2;
    final axis = Paint()
      ..color = axisColor.withAlpha(120)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, centerY), Offset(size.width, centerY), axis);

    final marker = Paint()
      ..color = waveColor.withAlpha(180)
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(leftX, 0), Offset(leftX, size.height), marker);
    canvas.drawLine(Offset(rightX, 0), Offset(rightX, size.height), marker);

    final sliceMarker = Paint()
      ..color = Colors.amber.shade600.withAlpha(230)
      ..strokeWidth = 1.2;
    for (final markerData in sliceMarkers) {
      final sliceNorm = markerData.value;
      final x = size.width * sliceNorm.clamp(0.0, 1.0);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), sliceMarker);

      final label = '${markerData.key}';
      final labelPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: kStyleBase.copyWith(
            color: Colors.amber.shade600,
            fontSize: 9,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final dx = (x + 3.0)
          .clamp(1.0, math.max(1.0, size.width - labelPainter.width - 1))
          .toDouble();
      final dy = size.height - labelPainter.height - 1;
      labelPainter.paint(canvas, Offset(dx, dy));
    }

    if (showPlayhead) {
      final ph = playheadNorm.clamp(0.0, 1.0);
      final playStart = previewStartNorm.clamp(0.0, 1.0);
      final playEnd = previewEndNorm.clamp(
        (playStart + 0.001).clamp(0.0, 1.0),
        1.0,
      );
      final playLeftX = size.width * math.min(playStart, playEnd);
      final playRightX = size.width * math.max(playStart, playEnd);
      final x = playLeftX + (playRightX - playLeftX) * ph;
      final playhead = Paint()
        ..color = Colors.white.withAlpha(230)
        ..strokeWidth = 1.2;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), playhead);
    }

    if (peaks.isEmpty) return;
    final wave = Paint()
      ..color = waveColor
      ..strokeWidth = math.max(1.0, size.width / peaks.length * 0.8)
      ..strokeCap = StrokeCap.round;

    final step = size.width / peaks.length;
    for (int i = 0; i < peaks.length; i++) {
      final x = (i + 0.5) * step;
      final amp = (peaks[i].clamp(0.0, 1.0)) * (size.height * 0.45);
      canvas.drawLine(Offset(x, centerY - amp), Offset(x, centerY + amp), wave);
    }
  }

  @override
  bool shouldRepaint(covariant _SampleWaveformPainter oldDelegate) {
    return oldDelegate.peaks != peaks ||
        oldDelegate.waveColor != waveColor ||
        oldDelegate.axisColor != axisColor ||
        oldDelegate.startNorm != startNorm ||
        oldDelegate.endNorm != endNorm ||
        oldDelegate.sliceMarkers != sliceMarkers ||
        oldDelegate.previewStartNorm != previewStartNorm ||
        oldDelegate.previewEndNorm != previewEndNorm ||
        oldDelegate.playheadNorm != playheadNorm ||
        oldDelegate.showPlayhead != showPlayhead;
  }
}

// ── Reusable widgets ─────────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;
  const _Section({required this.title, required this.child, this.trailing});

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
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: kStyleHeader.copyWith(
                      color: kColAccent,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _OscOnOffButton extends StatelessWidget {
  final bool on;
  final VoidCallback onTap;
  const _OscOnOffButton({required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        decoration: BoxDecoration(
          color: on ? kColAccent.withAlpha(40) : Colors.transparent,
          border: Border.all(color: on ? kColAccent : kColInactive),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          on ? 'ON' : 'OFF',
          style: kStyleHeader.copyWith(
            color: on ? kColAccent : kColInactive,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
  }
}

/// Compact row of OCT chips: -2 -1 0 +1 +2.
class _OctChips extends StatelessWidget {
  final int value; // -2..+2
  final ValueChanged<int> onChanged;
  const _OctChips({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'OCT',
          style: kStyleBase.copyWith(fontSize: 10, color: kColHeader),
        ),
        const SizedBox(width: 6),
        for (int oct = -2; oct <= 2; oct++)
          GestureDetector(
            onTap: () => onChanged(oct),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: oct == value
                    ? kColAccent.withAlpha(40)
                    : Colors.transparent,
                border: Border.all(
                  color: oct == value ? kColAccent : kColInactive,
                ),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                oct >= 0 ? '+$oct' : '$oct',
                style: kStyleBase.copyWith(
                  fontSize: 11,
                  color: oct == value ? kColAccent : kColHeader,
                  fontWeight: oct == value
                      ? FontWeight.w700
                      : FontWeight.normal,
                ),
              ),
            ),
          ),
      ],
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                  fontWeight: w == value ? FontWeight.w700 : FontWeight.normal,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

String _lfoRateDisplay(double n) {
  final hz = 0.1 + n * n * 19.9;
  return hz < 10 ? hz.toStringAsFixed(2) : hz.toStringAsFixed(1);
}

class _FilterModePicker extends StatelessWidget {
  final SynthFilterMode value;
  final ValueChanged<SynthFilterMode> onChanged;
  const _FilterModePicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final m in SynthFilterMode.values)
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(m),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 3),
                padding: const EdgeInsets.symmetric(vertical: 7),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: m == value
                      ? kColAccent.withAlpha(40)
                      : Colors.transparent,
                  border: Border.all(
                    color: m == value ? kColAccent : kColInactive,
                  ),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  m.label,
                  style: kStyleBase.copyWith(
                    fontSize: 13,
                    color: m == value ? kColAccent : kColHeader,
                    fontWeight: m == value
                        ? FontWeight.w700
                        : FontWeight.normal,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _LfoTargetPicker extends StatelessWidget {
  final SynthLfoTarget value;
  final ValueChanged<SynthLfoTarget> onChanged;
  const _LfoTargetPicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final t in SynthLfoTarget.values)
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(t),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 3),
                padding: const EdgeInsets.symmetric(vertical: 7),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: t == value
                      ? kColAccent.withAlpha(40)
                      : Colors.transparent,
                  border: Border.all(
                    color: t == value ? kColAccent : kColInactive,
                  ),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  t.label,
                  style: kStyleBase.copyWith(
                    fontSize: 11,
                    color: t == value ? kColAccent : kColHeader,
                    fontWeight: t == value
                        ? FontWeight.w700
                        : FontWeight.normal,
                  ),
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
  final double value; // 0..1
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
          final n = (value - d.delta.dy * 0.012).clamp(0.0, 1.0);
          onChanged(n);
        },
        onDoubleTap: () => onChanged(0.5),
        child: Column(
          children: [
            SizedBox(
              width: 56,
              height: 56,
              child: CustomPaint(painter: _KnobPainter(value)),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: kStyleBase.copyWith(
                color: kColHeader,
                fontSize: 10,
                letterSpacing: 0.8,
              ),
            ),
            Text(
              display,
              style: kStyleBase.copyWith(
                color: kColAccent,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
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

    // 0 value at 12 o'clock, sweeps 270° clockwise to 9 o'clock at max.
    const startAngle = -math.pi / 2; // straight up
    const sweep = math.pi * 3 / 2;
    final angle = startAngle + sweep * value;

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
