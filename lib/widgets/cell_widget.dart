import 'package:flutter/material.dart';
import '../models/cell.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// Returns the 2-3 character display string for a given column in a cell.
String cellDisplay(CellColumn column, TrackerCell cell) {
  switch (column) {
    case CellColumn.note:
      return cell.note.display;
    case CellColumn.instrument:
      return FxSlot.hexDisplay(cell.instrument);
    case CellColumn.volume:
      return FxSlot.hexDisplay(cell.volume);
    case CellColumn.pan:
      return FxSlot.hexDisplay(cell.pan);
    case CellColumn.fx0cmd:
      return FxSlot.hexDisplay(cell.fxSlots[0].command);
    case CellColumn.fx0val:
      return FxSlot.fxValueDisplay(cell.fxSlots[0].value);
    case CellColumn.fx1cmd:
      return FxSlot.hexDisplay(cell.fxSlots[1].command);
    case CellColumn.fx1val:
      return FxSlot.fxValueDisplay(cell.fxSlots[1].value);
    case CellColumn.fx2cmd:
      return FxSlot.hexDisplay(cell.fxSlots[2].command);
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
    case CellColumn.pan:
      return cell.pan == null;
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
  Offset _longPressPos = Offset.zero;

  void _handleTap(AppState state) {
    final empty = cellIsEmpty(widget.column, widget.cell);
    if (empty) {
      state.insertDefaultValue(widget.row, widget.column);
    }
    state.selectCell(widget.row, widget.column);
  }

  Future<void> _handleLongPress(AppState state) async {
    state.selectCell(widget.row, widget.column);

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final pos = RelativeRect.fromRect(
      _longPressPos & Size.zero,
      Offset.zero & overlay.size,
    );

    final items = <PopupMenuEntry<String>>[
      const PopupMenuItem(value: 'copy', child: Text('Copy row')),
      PopupMenuItem(
        value: 'paste',
        enabled: state.hasRowClipboard,
        child: const Text('Paste row'),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'delete', child: Text('Delete row')),
    ];

    final choice = await showMenu<String>(
      context: context,
      position: pos,
      items: items,
      color: const Color(0xFF1E2030),
    );

    if (!mounted) return;
    switch (choice) {
      case 'copy':
        state.copyRow(widget.row);
      case 'paste':
        state.pasteRow(widget.row);
      case 'delete':
        state.deleteRow(widget.row);
    }
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
      onLongPressStart: (d) => _longPressPos = d.globalPosition,
      onLongPress: () => _handleLongPress(state),
      onVerticalDragStart: (_) {
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
        color: widget.isSelected ? kBgSelected : Colors.transparent,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(text, style: style, maxLines: 1),
      ),
    );
  }
}
