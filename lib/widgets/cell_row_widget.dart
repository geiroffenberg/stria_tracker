import 'package:flutter/material.dart';
import '../models/cell.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'cell_widget.dart';

/// One complete row in the tracker grid (row number + all visible columns).
class CellRowWidget extends StatelessWidget {
  final int row;
  final TrackerCell cell;
  final bool isSelected;   // true if ANY column in this row is selected
  final bool isPlayhead;
  final CellPosition? selectedCell;
  final bool collapsed; // if true, show only NOTE and INST columns

  const CellRowWidget({
    super.key,
    required this.row,
    required this.cell,
    required this.isSelected,
    required this.isPlayhead,
    required this.selectedCell,
    required this.collapsed,
  });

  @override
  Widget build(BuildContext context) {
    final bg = rowBgColor(row, isSelected, isPlayhead);

    // Which columns are visible
    final cols = collapsed
        ? [CellColumn.note, CellColumn.instrument]
        : CellColumn.values;

    return Container(
      height: kRowHeight,
      color: bg,
      child: Row(
        children: [
          // Row number
          SizedBox(
            width: kWRow,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                row.toString().padLeft(2, '0'),
                style: kStyleRowNum,
              ),
            ),
          ),
          // Beat tick mark: bright bar at beat starts
          Container(
            width: 2,
            color: row % 16 == 0
                ? kColAccent.withAlpha(180)
                : row % 4 == 0
                    ? kColAccent.withAlpha(60)
                    : Colors.transparent,
          ),
          // Data columns
          ...cols.expand((col) => [
                SizedBox(
                  width: _colWidth(col),
                  height: kRowHeight,
                  child: CellWidget(
                    row:        row,
                    column:     col,
                    cell:       cell,
                    isSelected: selectedCell?.row    == row &&
                                selectedCell?.column == col,
                  ),
                ),
                SizedBox(width: _gapAfter(col)),
              ]),
        ],
      ),
    );
  }

  static double _colWidth(CellColumn col) {
    switch (col) {
      case CellColumn.note:       return kWNote;
      case CellColumn.instrument: return kWInst;
      case CellColumn.volume:     return kWVol;
      case CellColumn.pan:        return kWPan;
      case CellColumn.fx0cmd:
      case CellColumn.fx1cmd:
      case CellColumn.fx2cmd:     return kWFxCmd;
      case CellColumn.fx0val:
      case CellColumn.fx1val:
      case CellColumn.fx2val:     return kWFxVal;
    }
  }

  static double _gapAfter(CellColumn col) {
    switch (col) {
      case CellColumn.note:       return kWGap;
      case CellColumn.instrument: return kWGap;
      case CellColumn.volume:     return kWGap;
      case CellColumn.pan:        return kWGap;
      case CellColumn.fx0cmd:     return 2;
      case CellColumn.fx0val:     return kWGap;
      case CellColumn.fx1cmd:     return 2;
      case CellColumn.fx1val:     return kWGap;
      case CellColumn.fx2cmd:     return 2;
      case CellColumn.fx2val:     return 0;
    }
  }
}
