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
      // Any row with a real note has an audible volume even if none was
      // explicitly set — show the implied default (80) instead of "--".
      // Display-only: does not write to the cell, so it applies equally to
      // notes entered just now and notes loaded from an existing song.
      if (cell.volume == null && cell.note.isNote) return '80';
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
  final int trackIndex;
  final int row;
  final CellColumn column;
  final TrackerCell cell;
  final bool isSelected;

  const CellWidget({
    super.key,
    required this.trackIndex,
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
    if (widget.column == CellColumn.note) {
      state.previewCellNoteOneShot(widget.row);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = cellDisplay(widget.column, widget.cell);
    final empty = cellIsEmpty(widget.column, widget.cell);
    final style = empty ? kStyleEmpty : columnStyle(widget.column);
    final state = AppStateScope.of(context);
    final isBoxSelected = state.isCellInBoxSelection(
      widget.trackIndex,
      widget.row,
      widget.column,
    );
    final isColumnSelected =
        widget.trackIndex == state.currentTrackIndex &&
        state.selectedColumn == widget.column;
    final interactionsEnabled = !state.isBoxSelecting;

    final cell = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: interactionsEnabled ? () => _handleTap(state) : null,
      onVerticalDragStart: interactionsEnabled ? (_) {
        if (cellIsEmpty(widget.column, widget.cell)) {
          state.insertDefaultValue(widget.row, widget.column);
        }
        if (cellIsEmpty(widget.column, widget.cell)) return;
        _dragAccum = 0.0;
        state.selectCell(widget.row, widget.column);
      } : null,
      onVerticalDragUpdate: interactionsEnabled ? (d) {
        if (cellIsEmpty(widget.column, widget.cell)) return;
        _dragAccum -= d.delta.dy;
        final steps = (_dragAccum / _pixelsPerStep).truncate();
        if (steps != 0) {
          _dragAccum -= steps * _pixelsPerStep;
          state.nudgeCell(widget.row, widget.column, steps);
          if (widget.column == CellColumn.note) {
            state.previewCellNoteOneShot(widget.row);
          }
        }
      } : null,
      child: Container(
        decoration: (widget.isSelected || isBoxSelected)
            ? BoxDecoration(
                color: isBoxSelected
                    ? kBgSelected.withAlpha(widget.isSelected ? 255 : 170)
                    : kBgSelected,
                border: Border.all(color: kColSelection, width: 1.5),
              )
            : null,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(text, style: style, maxLines: 1),
      ),
    );

    if (isColumnSelected) {
      return CustomPaint(
        foregroundPainter: DottedSelectionBorderPainter(kColSelection),
        child: cell,
      );
    }
    return cell;
  }
}

/// Draws a fine dotted border around a selected row or column.
class DottedSelectionBorderPainter extends CustomPainter {
  final Color color;
  const DottedSelectionBorderPainter(this.color);

  static const double _dot = 2.0;
  static const double _gap = 3.0;

  void _drawDashed(Canvas canvas, Paint paint, Offset start, Offset end) {
    final total = (end - start).distance;
    if (total == 0) return;
    final dir = (end - start) / total;
    double d = 0;
    while (d < total) {
      canvas.drawLine(
        start + dir * d,
        start + dir * (d + _dot).clamp(0.0, total),
        paint,
      );
      d += _dot + _gap;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;
    _drawDashed(canvas, paint, Offset.zero, Offset(size.width, 0)); // top
    _drawDashed(
      canvas,
      paint,
      Offset(0, size.height),
      Offset(size.width, size.height),
    ); // bottom
    _drawDashed(canvas, paint, Offset.zero, Offset(0, size.height)); // left
    _drawDashed(
      canvas,
      paint,
      Offset(size.width, 0),
      Offset(size.width, size.height),
    ); // right
  }

  @override
  bool shouldRepaint(covariant DottedSelectionBorderPainter old) =>
      old.color != color;
}
