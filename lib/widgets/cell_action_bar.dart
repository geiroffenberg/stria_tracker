import 'package:flutter/material.dart';
import '../models/cell.dart';
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
    final selRow = state.selectedRow;
    final selCell = state.selectedCell;

    Widget body;
    double height;

    if (selRow != null) {
      body = _RowActions(state: state, row: selRow);
      height = 56;
    } else if (selCell != null) {
      body = _buildForColumn(state, selCell.row, selCell.column);
      // FX cmd needs more height for the chip strip below the label row.
      height = (selCell.column == CellColumn.fx0cmd ||
              selCell.column == CellColumn.fx1cmd ||
              selCell.column == CellColumn.fx2cmd)
          ? 96
          : 56;
    } else {
      body = const _IdleBar();
      height = 56;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 100),
      height: height,
      decoration: const BoxDecoration(
        color: kBgTrackHeader,
      ),
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
        'Tap a cell to edit · tap row number to select row',
        style: kStyleHeader.copyWith(color: kColInactive),
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Row(
        children: [
          _ActionLabel(text: display, color: color, width: 56),
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
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 9),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 18),
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
          else
            _ActionBtn(
              label: 'CLR',
              color: kColStopBtn,
              onTap: () => state.clearColumnValue(row, column),
            ),
        ],
      ),
    );
  }
}

// ─── FX-CMD: chip picker ──────────────────────────────────────────────────

class _FxCmdActions extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    final cell = state.currentTrack.cells[row];
    final fx = cell.fxSlots[_fxIndex()];
    final current = fx.command;
    final desc = fxCommandDescription(current);

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
          SizedBox(
            height: 28,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: kFxCommandNames.length,
              separatorBuilder: (_, __) => const SizedBox(width: 4),
              itemBuilder: (_, i) {
                final selected = current == i;
                return GestureDetector(
                  onTap: () {
                    state.currentTrack.writeColumnValue(row, column, i);
                    state.instrumentParamsChanged();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color:
                          selected ? kColFxCmd.withAlpha(60) : Colors.transparent,
                      border: Border.all(
                        color: selected ? kColFxCmd : kColInactive,
                        width: 1,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      kFxCommandNames[i],
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
