import 'package:flutter/material.dart';
import '../models/cell.dart';
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
    } else if (selRow != null) {
      body = _RowActions(state: state, row: selRow);
      height = 56;
    } else if (selCell != null) {
      body = _buildForColumn(state, selCell.row, selCell.column);
      // FX cmd uses stacked horizontal strips for command categories.
      height =
          (selCell.column == CellColumn.fx0cmd ||
              selCell.column == CellColumn.fx1cmd ||
              selCell.column == CellColumn.fx2cmd)
          ? 208
          : 56;
      if (isFxValColumn(selCell.column) && selectedFxCommand(selCell) != null) {
        height = 78;
      }
    } else {
      body = const _IdleBar();
      height = 56;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 100),
      height: height,
      decoration: const BoxDecoration(color: kBgTrackHeader),
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
    return Center(
      child: Text(
        'Tap a cell to edit · long-press drag to box-select',
        style: kStyleHeader.copyWith(color: kColInactive),
      ),
    );
  }
}

class _BoxSelectionActions extends StatelessWidget {
  final AppState state;

  const _BoxSelectionActions({required this.state});

  @override
  Widget build(BuildContext context) {
    final count = state.boxSelectionCellCount;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Row(
        children: [
          _ActionLabel(
            text: '$count SEL',
            color: kColAccent,
            width: 88,
          ),
          const SizedBox(width: 4),
          _ActionBtn(
            label: 'DEL',
            color: kColStopBtn,
            onTap: () => state.deleteBoxSelection(),
          ),
          const Spacer(),
          _ActionBtn(
            label: '✕',
            onTap: () => state.clearBoxSelection(),
          ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Row(
        children: [
          _ActionBtn(label: '↑', onTap: () => state.moveSelectedRowBy(-1)),
          _ActionBtn(label: '↓', onTap: () => state.moveSelectedRowBy(1)),
          const SizedBox(width: 4),
          _ActionBtn(label: 'COPY', onTap: () => state.copyRow(row)),
          _ActionBtn(label: 'CUT', onTap: () => state.cutRow(row)),
          _ActionBtn(
            label: 'PASTE',
            onTap: () => state.pasteRow(row),
            enabled: state.hasRowClipboard,
          ),
          const Spacer(),
          _ActionBtn(
            label: 'CLR',
            color: kColStopBtn,
            onTap: () => state.deleteRow(row),
          ),
          _ActionBtn(label: '✕', onTap: () => state.clearRowSelection()),
        ],
      ),
    );
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
          _ActionLabel(text: note.display, color: kColNote, width: 56),
          const SizedBox(width: 4),
          _ActionBtn(
            label: 'OFF',
            onTap: () => state.setNote(row, NoteValue.off),
          ),
          const SizedBox(width: 4),
          _ActionBtn(
            label: '−OCT',
            onTap: () => state.nudgeCell(row, CellColumn.note, -12),
            enabled: note.isNote,
          ),
          _ActionBtn(
            label: '+OCT',
            onTap: () => state.nudgeCell(row, CellColumn.note, 12),
            enabled: note.isNote,
          ),
          const SizedBox(width: 4),
          _ActionBtn(
            label: '−',
            onTap: () => state.nudgeCell(row, CellColumn.note, -1),
            enabled: note.isNote,
          ),
          _ActionBtn(
            label: '+',
            onTap: () => state.nudgeCell(row, CellColumn.note, 1),
            enabled: note.isNote,
          ),
          const Spacer(),
          _ActionBtn(
            label: 'CLR',
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
    final maxV = track.maxValue(column);
    final minV = track.minValue(column);
    track.writeColumnValue(row, column, v.clamp(minV, maxV));
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

  Future<void> _showManualValueDialog(
    BuildContext context,
    int current,
    int minV,
    int maxV,
  ) async {
    final controller = TextEditingController(text: current.toString());
    final entered = await showDialog<int>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: kBgTrackHeader,
          title: Text(
            '${_entryLabel()} ($minV-$maxV)',
            style: kStyleBase.copyWith(
              color: kColHeader,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            style: kStyleBase.copyWith(
              color: kColHeader,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
            decoration: InputDecoration(
              hintText: '$minV-$maxV',
              hintStyle: kStyleBase.copyWith(color: kColInactive),
              enabledBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: kColInactive),
              ),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: kColAccent),
              ),
            ),
            onSubmitted: (raw) {
              final parsed = int.tryParse(raw.trim());
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
                final parsed = int.tryParse(controller.text.trim());
                Navigator.of(
                  context,
                ).pop((parsed ?? current).clamp(minV, maxV));
              },
              child: Text(
                'Set',
                style: kStyleBase.copyWith(color: kColAccent),
              ),
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
    final maxV = track.maxValue(column);
    final minV = track.minValue(column);
    final fxCmd = _fxCommandForCell(cell);
    final String? fxHint;
    if (isInsertFxCommand(fxCmd)) {
      final fn = fxInsertFunctionFromCommand(fxCmd!);
      final slot = fxInsertSlotFromCommand(fxCmd);
      fxHint = 'Slot $slot — ${fxInsertFunctionName(fn)}';
    } else {
      fxHint = switch (fxCmd) {
        kFxARP => 'XY: X=1st interval, Y=2nd interval (1-9=diatonic degrees)',
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
              GestureDetector(
                onTap: () => _showManualValueDialog(
                  context,
                  value.clamp(minV, maxV),
                  minV,
                  maxV,
                ),
                child: _ActionLabel(text: display, color: color, width: 56),
              ),
              const SizedBox(width: 6),
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
                  label: 'CLR',
                  color: kColStopBtn,
                  onTap: () => state.clearColumnValue(row, column),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ─── FX-CMD: chip picker ──────────────────────────────────────────────────

class _FxCmdActions extends StatelessWidget {
  static const int _classicCount = 10;

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

  List<int> _getInsertFxCommands() {
    final trackIdx = state.currentTrackIndex;
    final occupied = state.trackInsertOccupied;
    if (trackIdx >= occupied.length) return [];
    final slots = occupied[trackIdx];
    final commands = <int>[];
    for (int slot = 0; slot < slots.length; slot++) {
      if (slots[slot]) {
        final base = kFxInsertStart + slot * 10;
        for (int fn = 0; fn < 10; fn++) {
          commands.add(base + fn);
        }
      }
    }
    return commands;
  }

  /// Get assignable commands for instruments/effects that are actually configured.
  /// Returns command indices for configured instruments.
  List<int> _getAssignableCommands() {
    final assigned = <int>[];
    for (int i = 1; i <= 50; i++) {
      final instr = state.instruments[i - 1];
      if (instr.type != InstrumentType.empty) assigned.add(i);
    }
    return assigned;
  }

  /// Get valid mixer FX commands: Master (M01-M02), Channels 1-15 (M11-M14, M21-M24, etc.)
  /// Reserves M15-M19, M25-M29, etc. for future expansion
  List<int> _getMixerFxCommands() {
    final cmds = <int>[];
    // Master: commands 32-33 (M01, M02)
    cmds.addAll([32, 33]);
    // Channels 1-15: each channel has 10 slots (0-9), currently implementing 1-4
    // Channel 1: 34-43, implementing 34-37 (M11-M14)
    // Channel 2: 44-53, implementing 44-47 (M21-M24)
    // etc.
    for (int ch = 1; ch <= 15; ch++) {
      final base = 34 + (ch - 1) * 10;
      // Add only implemented controllers 1-4 (indices 0-3 in the channel block)
      cmds.addAll([base, base + 1, base + 2, base + 3]);
    }
    return cmds;
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
    return SizedBox(
      height: 28,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: indices.length,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (_, i) {
          final cmd = indices[i];
          final selected = current == cmd;
          return GestureDetector(
            onTap: () {
              state.currentTrack.writeColumnValue(row, column, cmd);
              state.instrumentParamsChanged();
            },
            child: Container(
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
          );
        },
      ),
    );
  }

  /// Display mixer FX commands using names from kFxCommandNames
  Widget _commandStripMixer(List<int> indices, int? current) {
    return SizedBox(
      height: 28,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: indices.length,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (_, i) {
          final cmd = indices[i];
          final selected = current == cmd;
          return GestureDetector(
            onTap: () {
              state.currentTrack.writeColumnValue(row, column, cmd);
              state.instrumentParamsChanged();
            },
            child: Container(
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
          );
        },
      ),
    );
  }

  /// Display assigned instrument controls as "0XY" format (instrument + controller)
  Widget _commandStripAssigned(List<int> instrumentIndices, int? current) {
    return SizedBox(
      height: 28,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: instrumentIndices.length,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (_, i) {
          final instrNum = instrumentIndices[i];
          // Format: 0XY where X=instrument (1-5), Y=controller (1 = placeholder)
          final displayNum = (instrNum * 10) + 1;
          final displayText = '0${displayNum.toString().padLeft(2, '0')}';
          final selected = current == displayNum;
          return GestureDetector(
            onTap: () {
              state.currentTrack.writeColumnValue(row, column, displayNum);
              state.instrumentParamsChanged();
            },
            child: Container(
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
                displayText,
                style: kStyleBase.copyWith(
                  color: selected ? kColFxCmd : kColHeader,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cell = state.currentTrack.cells[row];
    final fx = cell.fxSlots[_fxIndex()];
    final current = fx.command;
    final desc = fxCommandDescription(current);
    final assignedCmds = _getAssignableCommands();
    final hasAssigned = assignedCmds.isNotEmpty;

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
                  label: 'CLR',
                  color: kColStopBtn,
                  onTap: () => state.clearColumnValue(row, column),
                ),
            ],
          ),
          const SizedBox(height: 6),
          _sectionLabel('Classic FX'),
          const SizedBox(height: 3),
          _commandStrip([
            ...List<int>.generate(_classicCount, (i) => i),
            kFxARC,
            kFxSLC,
          ], current),
          ...() {
            final insertCmds = _getInsertFxCommands();
            if (insertCmds.isEmpty) return <Widget>[];
            return [
              const SizedBox(height: 5),
              _sectionLabel('Insert FX'),
              const SizedBox(height: 3),
              _commandStrip(insertCmds, current),
            ];
          }(),
          const SizedBox(height: 5),
          _sectionLabel('Mixer FX'),
          const SizedBox(height: 3),
          _commandStripMixer(_getMixerFxCommands(), current),
          if (hasAssigned) ...[
            const SizedBox(height: 5),
            _sectionLabel('Assigned'),
            const SizedBox(height: 3),
            _commandStripAssigned(assignedCmds, current),
          ],
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
