import 'package:flutter/material.dart';
import '../models/cell.dart';
import '../models/fx_envelope_run.dart';
import '../models/instrument_model.dart';
import '../models/note_value.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'cell_widget.dart' show cellDisplay, cellIsEmpty;

/// Context-sensitive action bar shown at the bottom of the pattern editor.
///
/// Modes:
///   • Row mode (selectedRow != null): row-level operations.
///   • Cell mode (selectedCell != null): column-specific editor.
///   • Idle: hint text.
class CellActionBar extends StatelessWidget {
  const CellActionBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final boxSel = state.boxSelection;
    final selRow = state.selectedRow;
    final selCell = state.selectedCell;
    final selCol = state.selectedColumn;

    Widget body;
    double height;

    bool isFxValColumn(CellColumn c) {
      return c == CellColumn.fx0val ||
          c == CellColumn.fx1val ||
          c == CellColumn.fx2val;
    }

    int? selectedFxCommand(CellPosition pos) {
      final cell = state.currentTrack.cells[pos.row];
      switch (pos.column) {
        case CellColumn.fx0val:
          return cell.fxSlots[0].command;
        case CellColumn.fx1val:
          return cell.fxSlots[1].command;
        case CellColumn.fx2val:
          return cell.fxSlots[2].command;
        default:
          return null;
      }
    }

    if (boxSel != null) {
      body = _BoxSelectionActions(state: state);
      height = 56;
    } else if (selCol != null) {
      body = _ColumnActions(state: state, column: selCol);
      height = 56;
    } else if (selRow != null) {
      body = _RowActions(state: state, row: selRow);
      final selRange = state.selectedRowRange;
      final hasMulti = selRange != null && (selRange.$2 - selRange.$1) > 0;
      height = hasMulti ? 112 : 56;
    } else if (selCell != null) {
      body = _buildForColumn(state, selCell.row, selCell.column);
      // FX cmd uses stacked horizontal strips for command categories.
      height =
          (selCell.column == CellColumn.fx0cmd ||
              selCell.column == CellColumn.fx1cmd ||
              selCell.column == CellColumn.fx2cmd)
          ? 240
          : 56;
      if (isFxValColumn(selCell.column) && selectedFxCommand(selCell) != null) {
        height = 78;
      }
    } else {
      body = const _IdleBar();
      height = 0;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 100),
      height: height,
      decoration: BoxDecoration(color: kBgTrackHeader),
      child: body,
    );
  }

  Widget _buildForColumn(AppState state, int row, CellColumn col) {
    switch (col) {
      case CellColumn.note:
        return _NoteActions(state: state, row: row);
      case CellColumn.instrument:
      case CellColumn.volume:
      case CellColumn.fx0val:
      case CellColumn.fx1val:
      case CellColumn.fx2val:
        return _NumericActions(state: state, row: row, column: col);
      case CellColumn.fx0cmd:
      case CellColumn.fx1cmd:
      case CellColumn.fx2cmd:
        return _FxCmdActions(state: state, row: row, column: col);
    }
  }
}

class _IdleBar extends StatelessWidget {
  const _IdleBar();

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final hasBoxClip = !state.collapsedView && state.hasBoxClipboard;
    if (hasBoxClip) {
      return Center(
        child: Text(
          'Box clipboard ready · tap a row number to paste',
          style: kStyleHeader.copyWith(color: kColAccent),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

class _BoxSelectionActions extends StatelessWidget {
  final AppState state;

  const _BoxSelectionActions({required this.state});

  @override
  Widget build(BuildContext context) {
    final count = state.boxSelectionCellCount;
    final sel = state.boxSelection;
    final hasBoxClip = !state.collapsedView && state.hasBoxClipboard;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Row(
        children: [
          _ActionLabel(text: '$count SEL', color: kColAccent, width: 88),
          const SizedBox(width: 4),
          if (hasBoxClip && sel != null)
            _ActionBtn(
              label: 'PASTE',
              color: kColAccent,
              onTap: () => state.pasteBoxSelection(sel.minRow),
            ),
          _ActionBtn(label: 'CUT', onTap: () => state.cutBoxSelection()),
          _ActionBtn(label: 'COPY', onTap: () => state.copyBoxSelection()),
          _ActionBtn(
            label: 'DEL',
            color: kColStopBtn,
            onTap: () => state.deleteBoxSelection(),
          ),
          const Spacer(),
          _ActionBtn(label: '✕', onTap: () => state.clearBoxSelection()),
        ],
      ),
    );
  }
}

// ─── COLUMN MODE (whole-column selection via header tap) ──────────────────

/// Shown when a whole NOTE/IN/VL column is selected (via header tap in the
/// normal pattern view). Applies its edits to every row of the current
/// track's column at once (empty cells are skipped, same as single-cell
/// nudging requires a value to already be present).
class _ColumnActions extends StatelessWidget {
  final AppState state;
  final CellColumn column;

  const _ColumnActions({required this.state, required this.column});

  String get _label {
    switch (column) {
      case CellColumn.note:
        return 'NOTE COL';
      case CellColumn.instrument:
        return 'IN COL';
      case CellColumn.volume:
        return 'VOL COL';
      default:
        return 'COL';
    }
  }

  @override
  Widget build(BuildContext context) {
    final buttons = column == CellColumn.note
        ? [
            _ActionBtn(
              label: '+ST',
              onTap: () => state.transposeColumnBySemitones(1),
            ),
            _ActionBtn(
              label: '-ST',
              onTap: () => state.transposeColumnBySemitones(-1),
            ),
            _ActionBtn(
              label: '+OCT',
              onTap: () => state.transposeColumnBySemitones(12),
            ),
            _ActionBtn(
              label: '-OCT',
              onTap: () => state.transposeColumnBySemitones(-12),
            ),
          ]
        : [
            _ActionBtn(label: '+1', onTap: () => state.nudgeColumn(column, 1)),
            _ActionBtn(
              label: '-1',
              onTap: () => state.nudgeColumn(column, -1),
            ),
            _ActionBtn(
              label: '+10',
              onTap: () => state.nudgeColumn(column, 10),
            ),
            _ActionBtn(
              label: '-10',
              onTap: () => state.nudgeColumn(column, -10),
            ),
          ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Row(
        children: [
          _ActionLabel(text: _label, color: kColAccent, width: 88),
          const SizedBox(width: 4),
          ...buttons,
          const Spacer(),
          _ActionBtn(label: '✕', onTap: () => state.clearColumnSelection()),
        ],
      ),
    );
  }
}

// ─── ROW MODE ─────────────────────────────────────────────────────────────

class _RowActions extends StatelessWidget {
  final AppState state;
  final int row;

  const _RowActions({required this.state, required this.row});

  @override
  Widget build(BuildContext context) {
    final selectedRange = state.selectedRowRange;
    final hasMultiLineSelection =
        selectedRange != null && (selectedRange.$2 - selectedRange.$1) > 0;

    final mainRow = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Row(
        children: [
          // Move buttons work with ranges
          _ActionBtn(label: '↑', onTap: () => state.moveSelectedRowBy(-1)),
          _ActionBtn(label: '↓', onTap: () => state.moveSelectedRowBy(1)),
          _ActionBtn(label: '2X', onTap: () => state.duplicateSelectedRows()),
          const SizedBox(width: 4),
          // Copy/cut on range if multi-line selected, else single row
          _ActionBtn(
            label: 'COPY',
            onTap: () {
              if (hasMultiLineSelection) {
                state.copyRows(selectedRange.$1, selectedRange.$2);
              } else {
                state.copyRow(row);
              }
            },
          ),
          _ActionBtn(
            label: 'CUT',
            onTap: () {
              if (hasMultiLineSelection) {
                state.cutRows(selectedRange.$1, selectedRange.$2);
              } else {
                state.cutRow(row);
              }
            },
          ),
          _ActionBtn(
            label: 'PASTE',
            onTap: () => state.pasteRows(row),
            enabled: state.hasRowClipboard,
          ),
          if (!state.collapsedView && state.hasBoxClipboard)
            _ActionBtn(
              label: 'BPST',
              color: kColAccent,
              onTap: () => state.pasteBoxSelection(row),
            ),
          const Spacer(),
          _ActionBtn(
            label: 'DEL',
            color: kColStopBtn,
            onTap: () {
              if (hasMultiLineSelection) {
                state.deleteRows(selectedRange.$1, selectedRange.$2);
                state.clearRowSelection();
              } else {
                state.deleteRow(row);
              }
            },
          ),
          _ActionBtn(label: '✕', onTap: () => state.clearRowSelection()),
        ],
      ),
    );

    if (!hasMultiLineSelection) return mainRow;

    final randRow = Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
      child: Row(
        children: [
          _ActionBtn(label: 'SHF', onTap: () => state.shuffleSelectedRows()),
          _ActionBtn(label: 'SCT', onTap: () => state.scatterSelectedRows()),
          const SizedBox(width: 4),
          _ActionBtn(label: 'HUV', onTap: () => state.humanizeVolume()),
          _ActionBtn(label: 'HUT', onTap: () => state.humanizeTiming()),
          const SizedBox(width: 4),
          _ActionBtn(
            label: '+OCT',
            onTap: () => state.transposeSelectionBySemitones(12),
          ),
          _ActionBtn(
            label: '-OCT',
            onTap: () => state.transposeSelectionBySemitones(-12),
          ),
          _ActionBtn(
            label: '+ST',
            onTap: () => state.transposeSelectionBySemitones(1),
          ),
          _ActionBtn(
            label: '-ST',
            onTap: () => state.transposeSelectionBySemitones(-1),
          ),
          const Spacer(),
        ],
      ),
    );

    return Column(children: [mainRow, randRow]);
  }
}

// ─── NOTE column ──────────────────────────────────────────────────────────

class _NoteActions extends StatelessWidget {
  final AppState state;
  final int row;

  const _NoteActions({required this.state, required this.row});

  @override
  Widget build(BuildContext context) {
    final cell = state.currentTrack.cells[row];
    final note = cell.note;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Row(
        children: [
          _ActionBtn(
            label: 'OFF',
            onTap: () => state.setNote(row, NoteValue.off),
          ),
          const SizedBox(width: 4),
          _ActionBtn(
            label: '−OCT',
            onTap: () {
              state.nudgeCell(row, CellColumn.note, -12);
              state.previewCellNoteOneShot(row);
            },
            enabled: note.isNote,
          ),
          _ActionBtn(
            label: '+OCT',
            onTap: () {
              state.nudgeCell(row, CellColumn.note, 12);
              state.previewCellNoteOneShot(row);
            },
            enabled: note.isNote,
          ),
          const SizedBox(width: 4),
          _ActionBtn(
            label: '−',
            onTap: () {
              state.nudgeCell(row, CellColumn.note, -1);
              state.previewCellNoteOneShot(row);
            },
            enabled: note.isNote,
          ),
          _ActionBtn(
            label: '+',
            onTap: () {
              state.nudgeCell(row, CellColumn.note, 1);
              state.previewCellNoteOneShot(row);
            },
            enabled: note.isNote,
          ),
          const Spacer(),
          _ActionBtn(
            label: 'DEL',
            color: kColStopBtn,
            onTap: () => state.clearColumnValue(row, CellColumn.note),
          ),
        ],
      ),
    );
  }
}

// ─── INST / VOL / FX-VAL: slider editor ───────────────────────────────────

class _NumericActions extends StatelessWidget {
  final AppState state;
  final int row;
  final CellColumn column;

  const _NumericActions({
    required this.state,
    required this.row,
    required this.column,
  });

  int _readValue(TrackerCell cell) {
    switch (column) {
      case CellColumn.instrument:
        return cell.instrument ?? 0;
      case CellColumn.volume:
        return cell.volume ?? 0;
      case CellColumn.fx0val:
        return cell.fxSlots[0].value ?? 0;
      case CellColumn.fx1val:
        return cell.fxSlots[1].value ?? 0;
      case CellColumn.fx2val:
        return cell.fxSlots[2].value ?? 0;
      default:
        return 0;
    }
  }

  void _writeValue(int v) {
    final track = state.currentTrack;
    final maxV = track.maxValue(column, row: row);
    final minV = track.minValue(column);
    final clamped = v.clamp(minV, maxV);
    track.writeColumnValue(row, column, clamped);

    // Auto-fill note with C-4 if instrument is entered and note is empty
    if (column == CellColumn.instrument && clamped > 0) {
      if (track.cells[row].note.isEmpty) {
        track.setNote(row, NoteValue.fromScrollIndex(49)); // C-4
      }
    }

    // Remember the last value set based on column type
    if (column == CellColumn.instrument) {
      state.updateLastInstrument(clamped);
    } else if (column == CellColumn.volume) {
      state.updateLastVolume(clamped);
    } else if (column == CellColumn.fx0val ||
        column == CellColumn.fx1val ||
        column == CellColumn.fx2val) {
      state.updateLastFxValue(clamped);
    }

    state.instrumentParamsChanged();
  }

  String _entryLabel() {
    switch (column) {
      case CellColumn.instrument:
        return 'Instrument';
      case CellColumn.volume:
        return 'Volume';
      case CellColumn.fx0val:
      case CellColumn.fx1val:
      case CellColumn.fx2val:
        return 'FX value';
      default:
        return 'Value';
    }
  }

  bool get _isFxValColumn =>
      column == CellColumn.fx0val ||
      column == CellColumn.fx1val ||
      column == CellColumn.fx2val;

  Future<void> _showManualValueDialog(
    BuildContext context,
    int current,
    int minV,
    int maxV,
  ) async {
    // Determine if this is a hex input (only ARP uses hex format)
    final fxCmd = _fxCommandForCell(state.currentTrack.cells[row]);
    final isHex = _isFxValColumn && fxCmd == 0; // kFxARP = 0
    
    final String initText = isHex
        ? current.toRadixString(16).toUpperCase().padLeft(2, '0')
        : current.toString().padLeft(2, '0');
    final String rangeHint = isHex
        ? '${minV.toRadixString(16).toUpperCase()}-${maxV.toRadixString(16).toUpperCase()}'
        : '$minV-$maxV';
    final controller = TextEditingController(text: initText);
    int? parse(String raw) {
      final s = raw.trim();
      return isHex ? int.tryParse(s, radix: 16) : int.tryParse(s);
    }

    final entered = await showDialog<int>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: kBgTrackHeader,
          title: Text(
            '${_entryLabel()} ($rangeHint)${isHex ? ' hex' : ''}',
            style: kStyleBase.copyWith(
              color: kColHeader,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.text,
            style: kStyleBase.copyWith(
              color: kColHeader,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
            decoration: InputDecoration(
              hintText: rangeHint,
              hintStyle: kStyleBase.copyWith(color: kColInactive),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: kColInactive),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: kColAccent),
              ),
            ),
            onSubmitted: (raw) {
              final parsed = parse(raw);
              if (parsed != null) {
                Navigator.of(context).pop(parsed.clamp(minV, maxV));
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                'Cancel',
                style: kStyleBase.copyWith(color: kColInactive),
              ),
            ),
            TextButton(
              onPressed: () {
                final parsed = parse(controller.text);
                Navigator.of(
                  context,
                ).pop((parsed ?? current).clamp(minV, maxV));
              },
              child: Text('Set', style: kStyleBase.copyWith(color: kColAccent)),
            ),
          ],
        );
      },
    );

    if (entered != null) {
      _writeValue(entered);
    }
  }

  int? _fxCommandForCell(TrackerCell cell) {
    switch (column) {
      case CellColumn.fx0val:
        return cell.fxSlots[0].command;
      case CellColumn.fx1val:
        return cell.fxSlots[1].command;
      case CellColumn.fx2val:
        return cell.fxSlots[2].command;
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = state.currentTrack;
    final cell = track.cells[row];
    final empty = cellIsEmpty(column, cell);
    final display = cellDisplay(column, cell);
    final color = columnColor(column);
    final value = _readValue(cell);
    final maxV = track.maxValue(column, row: row);
    final minV = track.minValue(column);
    final fxCmd = _fxCommandForCell(cell);
    final String? fxHint;
    if (isInsertFxCommand(fxCmd)) {
      final fn = fxInsertFunctionFromCommand(fxCmd!);
      final slot = fxInsertSlotFromCommand(fxCmd);
      final effectName = state.trackInsertEffectName(
        state.currentTrackIndex,
        slot - 1,
      );
      fxHint = 'Slot $slot - ${fxInsertFunctionHintForEffect(effectName, fn)}';
    } else {
      fxHint = switch (fxCmd) {
        kFxARP =>
          'XY (hex): X=1st interval, Y=2nd interval (0-F semitones above root)',
        // e.g. 47 = +4 and +7 semitones, A9 = +10 and +9 semitones
        kFxCHA => '00=never, 99=always, 50=50% chance to play',
        kFxDEL => '00=line start, 99=line end (delayed note-on)',
        kFxKIL => '00=immediate kill, 99=end of row',
        kFxPAN => '00=left, 50=centre, 99=right',
        kFxRAN => '00=off, 01-99=chance % to pick a random active slice',
        kFxRET => 'XY: X=vol curve (0-9), Y=retrigs per line (1-9)',
        kFxREV => 'No value needed — plays sample/slice backwards',
        kFxVIB => 'XY: X=speed (0-9), Y=depth (0-9)',
        kFxVOL => '00=silent, 99=full — sets level for this row only',
        kFxARC => 'XY: X=octave layers, Y=notes/line (Y0=full cycle)',
        kFxBPM =>
          '00=reset to pattern BPM, 01-50=+1..+50, 51-99=-49..-1 (stacks)',
        kFxSWN => '00-99: overrides pattern swing (resets at start/loop)',
        _ => null,
      };
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (fxHint != null) ...[
            Padding(
              padding: const EdgeInsets.only(left: 2, right: 2, bottom: 4),
              child: Text(
                fxHint,
                style: kStyleBase.copyWith(
                  color: kColFxCmd,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          Row(
            children: [
              _ActionBtn(
                label: '−',
                onTap: () => state.nudgeCell(row, column, -1),
                enabled: !empty,
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 4,
                    activeTrackColor: color,
                    inactiveTrackColor: color.withAlpha(50),
                    thumbColor: color,
                    overlayColor: color.withAlpha(40),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 9,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 18,
                    ),
                  ),
                  child: Slider(
                    value: value.clamp(minV, maxV).toDouble(),
                    min: minV.toDouble(),
                    max: maxV.toDouble(),
                    onChanged: empty ? null : (v) => _writeValue(v.round()),
                  ),
                ),
              ),
              _ActionBtn(
                label: '+',
                onTap: () => state.nudgeCell(row, column, 1),
                enabled: !empty,
              ),
              const SizedBox(width: 6),
              if (empty)
                _ActionBtn(
                  label: 'SET',
                  color: kColAccent,
                  onTap: () => state.insertDefaultValue(row, column),
                )
              else ...[
                if (state.canInterpolate(row, column))
                  _ActionBtn(
                    label: 'INTERP',
                    color: kColAccent,
                    onTap: () => state.interpolateColumn(row, column),
                  ),
                _ActionBtn(
                  label: 'DEL',
                  color: kColStopBtn,
                  onTap: () => state.clearColumnValue(row, column),
                ),
              ],
              const SizedBox(width: 4),
              _ActionBtn(label: '✕', onTap: state.clearSelection),
            ],
          ),
          _EnvelopeSection(state: state, row: row, column: column),
        ],
      ),
    );
  }
}

// ─── FX-CMD: chip picker ──────────────────────────────────────────────────

class _FxCmdActions extends StatelessWidget {
  // Explicit list of classic FX command IDs shown in the picker.
  // To add a new chip: append its kFxXxx constant here.
  static const List<int> _classicCommands = [
    kFxARP,
    kFxCHA,
    kFxDEL,
    kFxKIL,
    kFxPAN,
    kFxRAN,
    kFxRET,
    kFxREV,
    kFxVIB,
    kFxVOL,
    kFxSLU,
    kFxSLD,
    kFxARC,
    kFxSLC,
    kFxTRE,
    kFxGAT,
    kFxBPM,
    kFxSWN,
  ];

  final AppState state;
  final int row;
  final CellColumn column;

  const _FxCmdActions({
    required this.state,
    required this.row,
    required this.column,
  });

  int _fxIndex() {
    switch (column) {
      case CellColumn.fx0cmd:
        return 0;
      case CellColumn.fx1cmd:
        return 1;
      case CellColumn.fx2cmd:
        return 2;
      default:
        return 0;
    }
  }

  List<int> _getOccupiedInsertSlots() {
    final trackIdx = state.currentTrackIndex;
    final names = state.trackInsertEffectNames;
    final occupied = state.trackInsertOccupied;
    final slots = <int>[];
    final slotCount = 6;
    for (int slot = 0; slot < slotCount; slot++) {
      final hasName =
          trackIdx < names.length &&
          slot < names[trackIdx].length &&
          names[trackIdx][slot] != null;
      final hasOccupied =
          trackIdx < occupied.length &&
          slot < occupied[trackIdx].length &&
          occupied[trackIdx][slot];
      if (hasName || hasOccupied) slots.add(slot);
    }
    return slots;
  }

  List<int> _getInsertFxCommandsForSlot(int slot, String? effectName) {
    final base = kFxInsertStart + slot * 10;
    final commands = <int>[];
    for (int fn = 0; fn < 10; fn++) {
      if (fxInsertFunctionIsUsedForEffect(effectName, fn)) {
        commands.add(base + fn);
      }
    }
    return commands;
  }

  String? _insertEffectNameForSlot(int slot) {
    return state.trackInsertEffectName(state.currentTrackIndex, slot);
  }

  String _insertSectionLabel(int slot, String effectName) {
    return 'Insert FX ${slot + 1}: $effectName';
  }

  List<int> _getMasterMixerCommands() => [194, 32, 33];

  List<int> _getTrackMixerCommands(int trackIndex) {
    final safeTrack = trackIndex.clamp(0, 15);
    final base = 34 + (safeTrack * 10);
    // Mx0 reset + Mx1..Mx4 controls.
    return [base + 9, base, base + 1, base + 2, base + 3];
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: kStyleBase.copyWith(
        color: kColHeader,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    );
  }

  Widget _commandStrip(List<int> indices, int? current) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: indices.map((cmd) {
        final selected = current == cmd;
        return GestureDetector(
          onTap: () {
            state.currentTrack.writeColumnValue(row, column, cmd);
            state.updateLastFxCommand(cmd);
            state.instrumentParamsChanged();
          },
          child: IntrinsicWidth(
            child: Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? kColFxCmd.withAlpha(60) : Colors.transparent,
                border: Border.all(
                  color: selected ? kColFxCmd : kColInactive,
                  width: 1,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                fxCommandName(cmd),
                style: kStyleBase.copyWith(
                  color: selected ? kColFxCmd : kColHeader,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  /// Insert FX strip: Fxy command on top + effect short name as subtext.
  Widget _commandStripInsert(
    List<int> indices,
    int? current,
    String? effectName,
  ) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: indices.map((cmd) {
        final selected = current == cmd;
        final fn = fxInsertFunctionFromCommand(cmd);
        final sub = fxInsertFunctionShortLabelForEffect(effectName, fn);
        return GestureDetector(
          onTap: () {
            state.currentTrack.writeColumnValue(row, column, cmd);
            state.updateLastFxCommand(cmd);
            state.instrumentParamsChanged();
          },
          child: IntrinsicWidth(
            child: Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? kColFxCmd.withAlpha(60) : Colors.transparent,
                border: Border.all(
                  color: selected ? kColFxCmd : kColInactive,
                  width: 1,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    fxCommandName(cmd),
                    style: kStyleBase.copyWith(
                      color: selected ? kColFxCmd : kColHeader,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                  Text(
                    sub,
                    style: kStyleBase.copyWith(
                      color: selected ? kColFxCmd : kColHeader.withAlpha(160),
                      fontSize: 9,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  /// Display mixer FX commands using names from kFxCommandNames
  Widget _commandStripMixer(List<int> indices, int? current) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: indices.map((cmd) {
        final selected = current == cmd;
        final sub = mixerValueShortLabel(cmd);
        return GestureDetector(
          onTap: () {
            state.currentTrack.writeColumnValue(row, column, cmd);
            state.instrumentParamsChanged();
          },
          child: IntrinsicWidth(
            child: Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? kColFxCmd.withAlpha(60) : Colors.transparent,
                border: Border.all(
                  color: selected ? kColFxCmd : kColInactive,
                  width: 1,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    mixerValueName(cmd),
                    style: kStyleBase.copyWith(
                      color: selected ? kColFxCmd : kColHeader,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                  Text(
                    sub,
                    style: kStyleBase.copyWith(
                      color: selected ? kColFxCmd : kColHeader.withAlpha(160),
                      fontSize: 9,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  /// Get the Pxx command indices for the instrument in the current cell.
  List<int> _getPParamCommands(InstrumentType type) {
    if (type == InstrumentType.empty) return [];
    final maxIdx = switch (type) {
      InstrumentType.sampler => SamplerParams.maxParamIndex,
      InstrumentType.simpleSynth => SimpleSynthParams.maxParamIndex,
      InstrumentType.karplusStrong => KarplusStrongParams.maxParamIndex,
      InstrumentType.empty => 0,
    };
    return List<int>.generate(maxIdx + 1, (i) => kFxPParamStart + i);
  }

  String _pParamName(int cmd, InstrumentType type) {
    final idx = pParamIndex(cmd);
    if (type == InstrumentType.sampler) return SamplerParams.paramName(idx);
    if (type == InstrumentType.karplusStrong) {
      return KarplusStrongParams.paramName(idx);
    }
    return SimpleSynthParams.paramName(idx);
  }

  String _pParamDesc(int cmd, InstrumentType type) {
    final idx = pParamIndex(cmd);
    if (type == InstrumentType.sampler) {
      return SamplerParams.paramDescription(idx);
    }
    if (type == InstrumentType.karplusStrong) {
      return KarplusStrongParams.paramDescription(idx);
    }
    return SimpleSynthParams.paramDescription(idx);
  }

  Widget _commandStripPParam(
    List<int> indices,
    int? current,
    InstrumentType type,
  ) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: indices.map((cmd) {
        final selected = current == cmd;
        return GestureDetector(
          onTap: () {
            state.currentTrack.writeColumnValue(row, column, cmd);
            state.instrumentParamsChanged();
          },
          child: IntrinsicWidth(
            child: Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? kColFxCmd.withAlpha(60) : Colors.transparent,
                border: Border.all(
                  color: selected ? kColFxCmd : kColInactive,
                  width: 1,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    fxCommandName(cmd),
                    style: kStyleBase.copyWith(
                      color: selected ? kColFxCmd : kColHeader,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                  Text(
                    _pParamName(cmd, type),
                    style: kStyleBase.copyWith(
                      color: selected ? kColFxCmd : kColHeader.withAlpha(160),
                      fontSize: 9,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cell = state.currentTrack.cells[row];
    final fx = cell.fxSlots[_fxIndex()];
    final current = fx.command;
    // Resolve instrument type: use the cell's IN value if set, otherwise scan
    // backwards to the last used instrument on this track (same logic as playback).
    final instrNum = state
        .effectiveInstrumentAtRow(row)
        .clamp(1, state.instruments.length);
    final instrType = state.instruments[instrNum - 1].type;
    // Override descriptions for command families that are context-sensitive.
    final currentInsertEffect = (current != null && isInsertFxCommand(current))
        ? _insertEffectNameForSlot(fxInsertSlotFromCommand(current) - 1)
        : null;
    final desc = (current != null && isPParamCommand(current))
        ? _pParamDesc(current, instrType)
        : (current != null && isMixerValueCommand(current))
        ? mixerValueDescription(current)
        : (current != null && isInsertFxCommand(current))
        ? fxInsertFunctionHintForEffect(
            currentInsertEffect,
            fxInsertFunctionFromCommand(current),
          )
        : fxCommandDescription(current);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    desc.isNotEmpty ? desc : 'Select FX command',
                    style: kStyleBase.copyWith(
                      color: kColFxCmd,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              if (current == null)
                _ActionBtn(
                  label: 'SET',
                  color: kColAccent,
                  onTap: () => state.insertDefaultValue(row, column),
                )
              else
                _ActionBtn(
                  label: 'DEL',
                  color: kColStopBtn,
                  onTap: () => state.clearColumnValue(row, column),
                ),
              const SizedBox(width: 4),
              _ActionBtn(label: '✕', onTap: () => state.clearSelection()),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _sectionLabel('Classic FX'),
                  const SizedBox(height: 3),
                  _commandStrip(_classicCommands, current),
                  ...() {
                    final slots = _getOccupiedInsertSlots();
                    if (slots.isEmpty) return <Widget>[];
                    final widgets = <Widget>[];
                    for (final slot in slots) {
                      final fxName = _insertEffectNameForSlot(slot) ?? 'FX';
                      widgets.add(const SizedBox(height: 5));
                      widgets.add(
                        _sectionLabel(_insertSectionLabel(slot, fxName)),
                      );
                      widgets.add(const SizedBox(height: 3));
                      widgets.add(
                        _commandStripInsert(
                          _getInsertFxCommandsForSlot(slot, fxName),
                          current,
                          fxName,
                        ),
                      );
                    }
                    return widgets;
                  }(),
                  const SizedBox(height: 5),
                  _sectionLabel('Master'),
                  const SizedBox(height: 3),
                  _commandStripMixer(_getMasterMixerCommands(), current),
                  const SizedBox(height: 5),
                  _sectionLabel('Mixer Values'),
                  const SizedBox(height: 3),
                  _commandStripMixer(
                    _getTrackMixerCommands(state.currentTrackIndex),
                    current,
                  ),
                  ...() {
                    final pCmds = _getPParamCommands(instrType);
                    if (pCmds.isEmpty) return <Widget>[];
                    final label = switch (instrType) {
                      InstrumentType.sampler => 'Sampler Params',
                      InstrumentType.karplusStrong => 'Karplus Params',
                      InstrumentType.simpleSynth => 'Synth Params',
                      InstrumentType.empty => 'Instrument Params',
                    };
                    return [
                      const SizedBox(height: 5),
                      _sectionLabel(label),
                      const SizedBox(height: 3),
                      _commandStripPParam(pCmds, current, instrType),
                    ];
                  }(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Reusable small bits ──────────────────────────────────────────────────

class _ActionLabel extends StatelessWidget {
  final String text;
  final Color color;
  final double width;

  const _ActionLabel({
    required this.text,
    required this.color,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: kBgColor,
        border: Border.all(color: kColInactive),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: kStyleBase.copyWith(
          color: color,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final bool enabled;

  const _ActionBtn({
    required this.label,
    required this.onTap,
    this.color,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final c = enabled ? (color ?? kColAccent) : kColInactive;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          height: 44,
          constraints: const BoxConstraints(minWidth: 44),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.withAlpha(20),
            border: Border.all(color: c, width: 1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: kStyleBase.copyWith(
              color: c,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Envelope section ─────────────────────────────────────────────────────

/// Shows a gamma slider + "REM ENV" button below the main action row when the
/// selected cell is an fxval column that is part of an [FxEnvelopeRun].
class _EnvelopeSection extends StatelessWidget {
  final AppState state;
  final int row;
  final CellColumn column;

  const _EnvelopeSection({
    required this.state,
    required this.row,
    required this.column,
  });

  int get _slotIndex {
    switch (column) {
      case CellColumn.fx0val:
        return 0;
      case CellColumn.fx1val:
        return 1;
      case CellColumn.fx2val:
        return 2;
      default:
        return -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final slot = _slotIndex;
    if (slot < 0) return const SizedBox.shrink();
    final run = state.fxEnvelopeAt(state.currentTrackIndex, slot, row);
    if (run == null) return const SizedBox.shrink();

    const envelopeColor = Color(0xCCFF8800);
    const envelopeFaint = Color(0x44FF8800);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 8, thickness: 1, color: envelopeFaint),
        Row(
          children: [
            // Gamma label + current value.
            SizedBox(
              width: 64,
              child: Text(
                'ENV γ ${run.gamma.toStringAsFixed(2)}',
                style: kStyleBase.copyWith(
                  color: envelopeColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 4,
                  activeTrackColor: envelopeColor,
                  inactiveTrackColor: envelopeFaint,
                  thumbColor: envelopeColor,
                  overlayColor: const Color(0x22FF8800),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 9,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 18,
                  ),
                ),
                child: Slider(
                  value: run.gamma.clamp(0.1, 4.0),
                  min: 0.1,
                  max: 4.0,
                  onChanged: (v) => state.updateEnvelopeGamma(run, v),
                ),
              ),
            ),
            _ActionBtn(
              label: 'REM ENV',
              color: kColStopBtn,
              onTap: () => state.deleteEnvelope(run),
            ),
          ],
        ),
      ],
    );
  }
}
