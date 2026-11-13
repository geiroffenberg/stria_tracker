import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/pattern_model.dart';
import '../models/song_model.dart';
import '../models/song_plan_step.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/transport_bar.dart';

/// Song Plan editing is saved independently of the current playback queue.
class SongPlanScreen extends StatelessWidget {
  const SongPlanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final patterns = state.song.patterns;

    return Scaffold(
      backgroundColor: kBgColor,
      appBar: AppBar(
        backgroundColor: kBgTopNav,
        foregroundColor: kColAccent,
        title: Text('Song Plan', style: kStyleHeader),
        actions: [
          TextButton(
            onPressed: state.canEditSongPlan
                ? () => state.setSongPlanEnabled(!state.song.songPlanEnabled)
                : null,
            child: Text(
              state.song.songPlanEnabled ? 'ON' : 'OFF',
              style: kStyleHeader.copyWith(
                color: state.song.songPlanEnabled ? kColAccent : kColInactive,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Song Plan help',
            icon: const Icon(Icons.info_outline),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Song Plan'),
                content: const Text(
                  'OFF keeps normal Song View playback, live jumps, and island looping. '
                  'ON plays the plan from the selected step; Song View follows it. '
                  'Loop restarts the plan at step 01. '
                  'COUNT plays consecutive Song View patterns; REPEAT repeats the whole group. '
                  'START/END apply to every pattern. Automatic END follows each pattern length; '
                  'the table shows the first pattern end. Empty patterns stop the run. '
                  'While stopped, tap STEP to select, or tap another value to select and edit. '
                  'Switching mode, editing, and selecting are disabled during playback. '
                  'The mute row shows the selected step when stopped and the playing step when running. '
                  'Tap a track number to mute it (M); tap M to clear it. '
                  'Mutes apply to the whole counted group and all repeats, only with the plan ON. '
                  'Live mute/solo still applies independently. '
                  'Save Song in the Song menu saves the plan and its ON/OFF setting. '
                  'Plan audio export is not available yet; turn the plan OFF to export Song View.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('OK'),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Reset to sequential plan',
            icon: const Icon(Icons.restore),
            onPressed: state.song.songPlan == null || !state.canEditSongPlan
                ? null
                : () => _resetPlan(context, state),
          ),
        ],
      ),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Container(
                color: kBgHeader,
                child: _cells(
                  ['STEP', 'PATTERN', 'START', 'END', 'REPEAT', 'COUNT'],
                  kColHeader,
                  header: true,
                ),
              ),
            ),
            SliverList.builder(
              itemCount: kMaxSongPatterns,
              itemBuilder: (context, index) {
                final step = state.song.planStepAt(index);
                final patternLines = state.song.planPatternLines(step);
                final isEmpty =
                    step.patternIndex >= patterns.length ||
                    patterns[step.patternIndex].isEmpty;
                final isPlayingStep =
                    state.isPlaying &&
                    (state.playingSongPlan
                        ? state.playingSongPlanStep == index
                        : state.playbackFollowsSong &&
                              state.playheadArrangementSlot == index);
                final isSelected =
                    !state.isPlaying && state.selectedSongPlanStep == index;
                final number = (index + 1).toString().padLeft(2, '0');
                final color = !state.song.hasValidPlanRange(step)
                    ? kColStopBtn
                    : isEmpty
                    ? kColInactive
                    : kColHeader;
                return Semantics(
                  selected: isPlayingStep || isSelected,
                  child: Container(
                    key: ValueKey('song-plan-step-$number'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: isPlayingStep
                          ? kBgPlayhead
                          : isSelected
                          ? kBgSelected
                          : index.isEven
                          ? kBgBeat
                          : kBgColor,
                      border: Border(
                        left: BorderSide(
                          color: isPlayingStep || isSelected
                              ? kColAccent
                              : Colors.transparent,
                          width: 3,
                        ),
                        bottom: BorderSide(color: kBgHeader),
                      ),
                    ),
                    child: InkWell(
                      onTap: state.canEditSongPlan
                          ? () => state.selectSongPlanStep(index)
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 16,
                        ),
                        child: _cells(
                          [
                            number,
                            (step.patternIndex + 1).toString().padLeft(2, '0'),
                            step.startLine.toString(),
                            step.effectiveEndLine(patternLines).toString(),
                            step.repeats.toString(),
                            step.count.toString(),
                          ],
                          color,
                          stepNumber: number,
                          onCellTap: state.canEditSongPlan
                              ? (column) {
                                  state.selectSongPlanStep(index);
                                  if (column != 0) {
                                    _editStep(context, state, index);
                                  }
                                }
                              : null,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) => Container(
            color: kBgTrackHeader,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _muteRow(state),
                SizedBox(
                  height: 76,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: SizedBox(
                      // The shared transport has fixed-width controls.
                      width: constraints.maxWidth < 360
                          ? 360
                          : constraints.maxWidth,
                      child: MediaQuery.withClampedTextScaling(
                        maxScaleFactor: 1,
                        child: TransportBar(
                          onPlay: state.song.songPlanEnabled
                              ? state.playSongPlan
                              : state.play,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _muteRow(AppState state) {
    final index = state.playingSongPlanStep ?? state.selectedSongPlanStep;
    final step = state.song.planStepAt(index);
    final number = (index + 1).toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'STEP $number MUTES',
            key: const ValueKey('song-plan-mute-label'),
            style: kStyleHeader.copyWith(color: kColHeader, fontSize: 12),
          ),
          LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: constraints.maxWidth < 512 ? 512 : constraints.maxWidth,
                child: Row(
                  children: [
                    for (var track = 0; track < 16; track++)
                      Expanded(
                        child: Semantics(
                          label: 'Track ${track + 1} plan mute',
                          toggled: step.isTrackMuted(track),
                          enabled: state.canEditSongPlan,
                          button: true,
                          child: InkWell(
                            key: ValueKey('song-plan-mute-$track'),
                            onTap: state.canEditSongPlan
                                ? () => state.toggleSongPlanTrackMute(track)
                                : null,
                            child: Container(
                              height: 40,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: step.isTrackMuted(track)
                                    ? kBgSelected
                                    : kBgHeader,
                                border: Border.all(color: kBgTrackHeader),
                              ),
                              child: Text(
                                step.isTrackMuted(track) ? 'M' : '${track + 1}',
                                style: kStyleBase.copyWith(
                                  color: step.isTrackMuted(track)
                                      ? kColAccent
                                      : kColHeader,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editStep(
    BuildContext context,
    AppState state,
    int index,
  ) async {
    if (!state.canEditSongPlan) return;
    final song = state.song;
    final step = await showDialog<SongPlanStep>(
      context: context,
      builder: (_) => _SongPlanStepDialog(song: song, index: index),
    );
    if (step == null || !context.mounted) return;
    if (!state.canEditSongPlan) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Stop playback before editing Song Plan.'),
        ),
      );
      return;
    }
    if (!identical(song, state.song)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Song changed. Reopen the step to edit it.'),
        ),
      );
      return;
    }
    state.setSongPlanStep(index, step);
  }

  Future<void> _resetPlan(BuildContext context, AppState state) async {
    final song = state.song;
    final reset = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Song Plan?'),
        content: const Text(
          'Replace the custom plan with the sequential default?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (reset == true && context.mounted && identical(song, state.song)) {
      state.resetSongPlan();
    }
  }

  Widget _cells(
    List<String> values,
    Color color, {
    bool header = false,
    String? stepNumber,
    ValueChanged<int>? onCellTap,
  }) {
    return Row(
      children: [
        for (var i = 0; i < values.length; i++)
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onCellTap == null ? null : () => onCellTap(i),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  values[i],
                  key: stepNumber == null
                      ? null
                      : ValueKey('song-plan-cell-$stepNumber-$i'),
                  textAlign: TextAlign.center,
                  style: (header ? kStyleHeader : kStyleBase).copyWith(
                    color: color,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SongPlanStepDialog extends StatefulWidget {
  final SongModel song;
  final int index;

  const _SongPlanStepDialog({required this.song, required this.index});

  @override
  State<_SongPlanStepDialog> createState() => _SongPlanStepDialogState();
}

class _SongPlanStepDialogState extends State<_SongPlanStepDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _pattern;
  late final TextEditingController _count;
  late final TextEditingController _start;
  late final TextEditingController _end;
  late final TextEditingController _repeat;
  late bool _followEnd;
  int? _fixedEnd;

  @override
  void initState() {
    super.initState();
    final step = widget.song.planStepAt(widget.index);
    final lines = widget.song.planPatternLines(step);
    _pattern = TextEditingController(text: '${step.patternIndex + 1}');
    _count = TextEditingController(text: '${step.count}');
    _start = TextEditingController(text: '${step.startLine}');
    _end = TextEditingController(text: '${step.effectiveEndLine(lines)}');
    _repeat = TextEditingController(text: '${step.repeats}');
    _followEnd = step.endLine == null;
    _fixedEnd = step.endLine;
  }

  int get _patternLines {
    final number = int.tryParse(_pattern.text);
    if (number == null || number < 1 || number > kMaxSongPatterns) {
      return kDefaultBeats * kDefaultLinesPerBeat;
    }
    return widget.song.planPatternLines(SongPlanStep(patternIndex: number - 1));
  }

  @override
  void dispose() {
    for (final controller in [_pattern, _count, _start, _end, _repeat]) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _validateNumber(String? value, int max) {
    final number = int.tryParse(value ?? '');
    return number == null || number < 1 || number > max
        ? 'Enter a number from 1 to $max.'
        : null;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kBgTrackHeader,
      title: Text(
        'Edit step ${(widget.index + 1).toString().padLeft(2, '0')}',
        style: kStyleHeader.copyWith(color: kColAccent, fontSize: 16),
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _field(
                'Pattern',
                _pattern,
                validator: (value) => _validateNumber(value, kMaxSongPatterns),
                onChanged: (_) => setState(() {
                  if (_followEnd) _end.text = '$_patternLines';
                }),
              ),
              _field(
                'Count',
                _count,
                helperText:
                    'Consecutive patterns. Repeat repeats the whole group.',
                validator: (value) {
                  final pattern = int.tryParse(_pattern.text);
                  final max = pattern != null && pattern >= 1 && pattern <= 99
                      ? kMaxSongPatterns - pattern + 1
                      : kMaxSongPatterns;
                  return _validateNumber(value, max);
                },
              ),
              _field(
                'Start line',
                _start,
                validator: (value) {
                  final error = _validateNumber(value, _patternLines);
                  if (error != null) return error;
                  final pattern = int.tryParse(_pattern.text);
                  final count = int.tryParse(_count.text);
                  if (pattern == null ||
                      pattern < 1 ||
                      pattern > 99 ||
                      count == null ||
                      count < 1 ||
                      pattern + count - 1 > 99) {
                    return null;
                  }
                  final step = SongPlanStep(
                    patternIndex: pattern - 1,
                    count: count,
                    startLine: int.parse(value!),
                  );
                  return widget.song.hasValidPlanRange(step)
                      ? null
                      : 'Start exceeds a pattern length in this group.';
                },
              ),
              _field(
                'End line',
                _end,
                helperText:
                    'Last line: $_patternLines. A higher end plays to the last line.',
                validator: (value) {
                  final error = _validateNumber(value, kMaxSongPlanLines);
                  if (error != null) return error;
                  final start = int.tryParse(_start.text);
                  return start != null && int.parse(value!) < start
                      ? 'End must be at or after start.'
                      : null;
                },
                onChanged: (_) => setState(() {
                  final end = int.tryParse(_end.text);
                  _followEnd = end != null && end >= _patternLines;
                  _fixedEnd = _followEnd ? null : end;
                }),
              ),
              _field(
                'Repeat',
                _repeat,
                validator: (value) =>
                    _validateNumber(value, kMaxSongPlanRepeats),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.pop(
              context,
              SongPlanStep(
                patternIndex: int.parse(_pattern.text) - 1,
                count: int.parse(_count.text),
                startLine: int.parse(_start.text),
                endLine: _fixedEnd,
                muteMask: widget.song.planStepAt(widget.index).muteMask,
                repeats: int.parse(_repeat.text),
              ),
            );
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    required FormFieldValidator<String> validator,
    String? helperText,
    ValueChanged<String>? onChanged,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      key: ValueKey('song-plan-edit-$label'),
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        helperMaxLines: 3,
      ),
      validator: validator,
      onChanged: onChanged,
    ),
  );
}
