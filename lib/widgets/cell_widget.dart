import 'package:flutter/material.dart';
import '../models/cell.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// Returns the 2-3 character display string for a given column in a cell.
String cellDisplay(CellColumn column, TrackerCell cell) {
  switch (column) {
    case CellColumn.note:       return cell.note.display;
    case CellColumn.instrument: return FxSlot.hexDisplay(cell.instrument);
    case CellColumn.volume:     return FxSlot.hexDisplay(cell.volume);
    case CellColumn.pan:        return FxSlot.hexDisplay(cell.pan);
    case CellColumn.fx0cmd:     return FxSlot.hexDisplay(cell.fxSlots[0].command);
    case CellColumn.fx0val:     return FxSlot.hexDisplay(cell.fxSlots[0].value);
    case CellColumn.fx1cmd:     return FxSlot.hexDisplay(cell.fxSlots[1].command);
    case CellColumn.fx1val:     return FxSlot.hexDisplay(cell.fxSlots[1].value);
    case CellColumn.fx2cmd:     return FxSlot.hexDisplay(cell.fxSlots[2].command);
    case CellColumn.fx2val:     return FxSlot.hexDisplay(cell.fxSlots[2].value);
  }
}

bool cellIsEmpty(CellColumn column, TrackerCell cell) {
  switch (column) {
    case CellColumn.note:       return cell.note.isEmpty;
    case CellColumn.instrument: return cell.instrument == null;
    case CellColumn.volume:     return cell.volume     == null;
    case CellColumn.pan:        return cell.pan        == null;
    case CellColumn.fx0cmd:     return cell.fxSlots[0].command == null;
    case CellColumn.fx0val:     return cell.fxSlots[0].value   == null;
    case CellColumn.fx1cmd:     return cell.fxSlots[1].command == null;
    case CellColumn.fx1val:     return cell.fxSlots[1].value   == null;
    case CellColumn.fx2cmd:     return cell.fxSlots[2].command == null;
    case CellColumn.fx2val:     return cell.fxSlots[2].value   == null;
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

  @override
  Widget build(BuildContext context) {
    final text   = cellDisplay(widget.column, widget.cell);
    final empty  = cellIsEmpty(widget.column, widget.cell);
    final style  = empty
        ? kStyleEmpty
        : columnStyle(widget.column);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () =>
          AppStateScope.of(context).selectCell(widget.row, widget.column),
      onVerticalDragStart: (_) {
        _dragAccum = 0.0;
        AppStateScope.of(context).selectCell(widget.row, widget.column);
      },
      onVerticalDragUpdate: (d) {
        _dragAccum -= d.delta.dy; // drag up → positive → higher value
        final steps = (_dragAccum / _pixelsPerStep).truncate();
        if (steps != 0) {
          _dragAccum -= steps * _pixelsPerStep;
          AppStateScope.of(context)
              .nudgeCell(widget.row, widget.column, steps);
        }
      },
      child: Container(
        color: widget.isSelected ? kBgSelected : Colors.transparent,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(text, style: style, maxLines: 1),
      ),
    );
  }
}
