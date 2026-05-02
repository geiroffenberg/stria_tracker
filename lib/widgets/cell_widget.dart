import 'package:flutter/material.dart';
import '../models/cell.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

String _dec2Display(int? v) {
  if (v == null) return '--';
  return v.clamp(0, 99).toString().padLeft(2, '0');
}

/// Returns the 2-3 character display string for a given column in a cell.
String cellDisplay(CellColumn column, TrackerCell cell) {
  switch (column) {
    case CellColumn.note:
      return cell.note.display;
    case CellColumn.instrument:
      return _dec2Display(cell.instrument);
    case CellColumn.volume:
      return _dec2Display(cell.volume);
    case CellColumn.fx0cmd:
      return fxCommandName(cell.fxSlots[0].command);
    case CellColumn.fx0val:
      return FxSlot.fxValueDisplay(cell.fxSlots[0].value);
    case CellColumn.fx1cmd:
      return fxCommandName(cell.fxSlots[1].command);
    case CellColumn.fx1val:
      return FxSlot.fxValueDisplay(cell.fxSlots[1].value);
    case CellColumn.fx2cmd:
      return fxCommandName(cell.fxSlots[2].command);
    case CellColumn.fx2val:
      return FxSlot.fxValueDisplay(cell.fxSlots[2].value);
  }
}

bool cellIsEmpty(CellColumn column, TrackerCell cell) {
  switch (column) {
    case CellColumn.note:
      return cell.note.isEmpty;
    case CellColumn.instrument:
      return cell.instrument == null;
    case CellColumn.volume:
      return cell.volume == null;
    case CellColumn.fx0cmd:
      return cell.fxSlots[0].command == null;
    case CellColumn.fx0val:
      return cell.fxSlots[0].value == null;
    case CellColumn.fx1cmd:
      return cell.fxSlots[1].command == null;
    case CellColumn.fx1val:
      return cell.fxSlots[1].value == null;
    case CellColumn.fx2cmd:
      return cell.fxSlots[2].command == null;
    case CellColumn.fx2val:
      return cell.fxSlots[2].value == null;
  }
}

/// One interactive cell widget — tap to select, vertical drag to change value.
class CellWidget extends StatefulWidget {
  final int row;
  final CellColumn column;
  final TrackerCell cell;
  final bool isSelected;

  const CellWidget({
    super.key,
    required this.row,
    required this.column,
    required this.cell,
    required this.isSelected,
  });

  @override
  State<CellWidget> createState() => _CellWidgetState();
}

class _CellWidgetState extends State<CellWidget> {
  double _dragAccum = 0.0;
  static const double _pixelsPerStep = 11.0;

  // Manual double-tap detection (avoids GestureDetector's 300ms onTap delay).
  DateTime? _lastTapTime;
  static const Duration _doubleTapWindow = Duration(milliseconds: 300);

  void _handleTap(AppState state) {
    final now = DateTime.now();
    final last = _lastTapTime;
    _lastTapTime = now;

    if (last != null && now.difference(last) < _doubleTapWindow) {
      // Double-tap: reset to default.
      _lastTapTime = null;
      state.resetColumnToDefault(widget.row, widget.column);
      state.selectCell(widget.row, widget.column);
      return;
    }

    // Single tap: immediate response.
    final empty = cellIsEmpty(widget.column, widget.cell);
    if (empty) {
      state.insertDefaultValue(widget.row, widget.column);
    }
    state.selectCell(widget.row, widget.column);
  }

  @override
  Widget build(BuildContext context) {
    final text = cellDisplay(widget.column, widget.cell);
    final empty = cellIsEmpty(widget.column, widget.cell);
    final style = empty ? kStyleEmpty : columnStyle(widget.column);
    final state = AppStateScope.of(context);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _handleTap(state),
      onVerticalDragStart: (_) {
        if (cellIsEmpty(widget.column, widget.cell)) {
          state.insertDefaultValue(widget.row, widget.column);
        }
        if (cellIsEmpty(widget.column, widget.cell)) return;
        _dragAccum = 0.0;
        state.selectCell(widget.row, widget.column);
      },
      onVerticalDragUpdate: (d) {
        if (cellIsEmpty(widget.column, widget.cell)) return;
        _dragAccum -= d.delta.dy;
        final steps = (_dragAccum / _pixelsPerStep).truncate();
        if (steps != 0) {
          _dragAccum -= steps * _pixelsPerStep;
          state.nudgeCell(widget.row, widget.column, steps);
        }
      },
      child: Container(
        decoration: widget.isSelected
            ? BoxDecoration(
                color: kBgSelected,
                border: Border.all(color: kColSelection, width: 1.5),
              )
            : null,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(text, style: style, maxLines: 1),
      ),
    );
  }
}
