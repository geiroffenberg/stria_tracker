import 'dart:math' as math;
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models/instrument_model.dart';
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
                DropdownButtonFormField<SynthPreset>(
                  value: null,
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
                    Expanded(child: _Knob(
                      label: 'A',
                      value: p.filterAttack,
                      display: '${(p.filterAttack * 100).round()}',
                      onChanged: (v) {
                        p.filterAttack = v;
                        state.instrumentParamsChanged();
                      },
                    )),
                    Expanded(child: _Knob(
                      label: 'D',
                      value: p.filterDecay,
                      display: '${(p.filterDecay * 100).round()}',
                      onChanged: (v) {
                        p.filterDecay = v;
                        state.instrumentParamsChanged();
                      },
                    )),
                    Expanded(child: _Knob(
                      label: 'S',
                      value: p.filterSustain,
                      display: '${(p.filterSustain * 100).round()}',
                      onChanged: (v) {
                        p.filterSustain = v;
                        state.instrumentParamsChanged();
                      },
                    )),
                    Expanded(child: _Knob(
                      label: 'R',
                      value: p.filterRelease,
                      display: '${(p.filterRelease * 100).round()}',
                      onChanged: (v) {
                        p.filterRelease = v;
                        state.instrumentParamsChanged();
                      },
                    )),
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
                  label: 'DRIVE',
                  value: p.drive,
                  display: '${(p.drive * 100).round()}%',
                  onChanged: (v) {
                    p.drive = v;
                    state.instrumentParamsChanged();
                  },
                )),
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
                    Expanded(child: _Knob(
                      label: 'RATE',
                      value: p.lfoRate,
                      display: '${_lfoRateDisplay(p.lfoRate)} Hz',
                      onChanged: (v) {
                        p.lfoRate = v;
                        state.instrumentParamsChanged();
                      },
                    )),
                    Expanded(child: _Knob(
                      label: 'DEPTH',
                      value: p.lfoDepth,
                      display: '${(p.lfoDepth * 100).round()}%',
                      onChanged: (v) {
                        p.lfoDepth = v;
                        state.instrumentParamsChanged();
                      },
                    )),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          Text(
            'SYNTH params are live in the native audio engine.',
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

class _SamplerEditor extends StatefulWidget {
  final AppState state;
  const _SamplerEditor({required this.state});

  @override
  State<_SamplerEditor> createState() => _SamplerEditorState();
}

class _SamplerEditorState extends State<_SamplerEditor> {
  bool _busy = false;
  String? _libraryPath;
  List<String> _librarySamples = const [];

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _reloadLibrary();
  }

  Future<void> _reloadLibrary() async {
    final path = await state.samplerLibraryPath();
    final names = await state.listSamplerLibrarySamples();
    if (!mounted) return;
    setState(() {
      _libraryPath = path;
      _librarySamples = names;
    });
  }

  Future<void> _importFromPhone(BuildContext context) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'wav', 'aif', 'aiff', 'flac', 'ogg', 'mp3', 'm4a', 'aac'
        ],
        allowMultiple: false,
        withData: true, // always fetch bytes — handles content URIs on Android
      );
      if (picked == null || picked.files.isEmpty) return;
      final pFile = picked.files.single;

      // Use real path when available, otherwise fall back to in-memory bytes.
      final String? importedName;
      if (pFile.path != null) {
        importedName = await state.importSampleToLibrary(pFile.path!);
      } else if (pFile.bytes != null) {
        importedName = await state.importSampleBytesToLibrary(
          pFile.bytes!,
          pFile.name,
        );
      } else {
        importedName = null;
      }

      if (importedName == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Import failed.'),
          duration: Duration(seconds: 2),
        ));
        return;
      }

      final loadErr = await state.loadSamplerSampleFromLibrary(importedName);
      await _reloadLibrary();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(loadErr == null ? 'Imported: $importedName' : 'Imported but: $loadErr'),
        duration: const Duration(seconds: 3),
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadSample(BuildContext context, String name) async {
    final err = await state.loadSamplerSampleFromLibrary(name);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(err == null ? 'Loaded: $name' : 'Load failed: $err'),
      duration: const Duration(seconds: 3),
    ));
  }

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
                if (p.samplePath != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    p.samplePath!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: kStyleBase.copyWith(
                      color: kColInactive,
                      fontSize: 10,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _busy ? null : () => _importFromPhone(context),
                        icon: const Icon(Icons.folder_open),
                        label: const Text('IMPORT FROM PHONE'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Refresh sample library',
                      onPressed: _busy ? null : _reloadLibrary,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                if (_libraryPath != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Library: $_libraryPath',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: kStyleBase.copyWith(
                      color: kColInactive,
                      fontSize: 10,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 170),
                  decoration: BoxDecoration(
                    color: kBgColor.withAlpha(60),
                    border: Border.all(color: kColInactive.withAlpha(90)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: _librarySamples.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Text(
                              'No samples in library yet.\nImport from phone to add one.',
                              textAlign: TextAlign.center,
                              style: kStyleBase.copyWith(
                                color: kColInactive,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _librarySamples.length,
                          itemBuilder: (_, i) {
                            final name = _librarySamples[i];
                            final active = p.sampleName == name;
                            return ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              leading: Icon(
                                Icons.audio_file,
                                size: 16,
                                color: active ? kColAccent : kColInactive,
                              ),
                              title: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: kStyleBase.copyWith(
                                  color: active ? kColAccent : kColHeader,
                                  fontSize: 12,
                                  fontWeight:
                                      active ? FontWeight.w700 : FontWeight.normal,
                                ),
                              ),
                              trailing: active
                                  ? const Icon(Icons.check, size: 16)
                                  : null,
                              onTap: () => _loadSample(context, name),
                            );
                          },
                        ),
                ),
                if (p.sampleName != null) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () => state.clearCurrentSamplerSample(),
                    icon: const Icon(Icons.clear),
                    label: const Text('CLEAR CURRENT SAMPLE'),
                  ),
                ],
                if (Platform.isAndroid) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Tip: You can also copy files directly into the Library folder using a file manager.',
                    style: kStyleBase.copyWith(
                      color: kColInactive,
                      fontSize: 10,
                    ),
                  ),
                ],
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
                  color: m == value ? kColAccent.withAlpha(40) : Colors.transparent,
                  border: Border.all(color: m == value ? kColAccent : kColInactive),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  m.label,
                  style: kStyleBase.copyWith(
                    fontSize: 13,
                    color: m == value ? kColAccent : kColHeader,
                    fontWeight: m == value ? FontWeight.w700 : FontWeight.normal,
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
                  color: t == value ? kColAccent.withAlpha(40) : Colors.transparent,
                  border: Border.all(color: t == value ? kColAccent : kColInactive),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  t.label,
                  style: kStyleBase.copyWith(
                    fontSize: 11,
                    color: t == value ? kColAccent : kColHeader,
                    fontWeight: t == value ? FontWeight.w700 : FontWeight.normal,
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