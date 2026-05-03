import 'package:flutter/material.dart';
import '../models/cell.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'cell_widget.dart';

/// One complete row in the tracker grid (row number + all visible columns).
class CellRowWidget extends StatelessWidget {
  final int trackIndex;
  final int row;
  final TrackerCell cell;
  final bool isSelected;   // true if ANY column in this row is selected
  final bool isPlayhead;
  final CellPosition? selectedCell;
  final bool collapsed; // if true, show only NOTE and INST columns

  const CellRowWidget({
    super.key,
    required this.trackIndex,
    required this.row,
    required this.cell,
    required this.isSelected,
    required this.isPlayhead,
    required this.selectedCell,
    required this.collapsed,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final isRowSelected = state.selectedRow == row;
    final isBeatStart = state.isBeatStart(row);
    final beat = isBeatStart ? state.beatForRow(row) : -1;
    final bg = rowBgColor(row, isSelected, isPlayhead, state.linesPerBeat);
    final rowNumStyle = isBeatStart
        ? kStyleRowNum.copyWith(color: kColAccent)
        : kStyleRowNum.copyWith(color: kColRowNum);

    // Which columns are visible
    final cols = collapsed
        ? [CellColumn.note, CellColumn.instrument]
        : CellColumn.values;

    return Container(
      height: kRowHeight,
      decoration: BoxDecoration(
        color: bg,
        border: isRowSelected
            ? Border.all(color: kColSelection, width: 1.5)
            : null,
      ),
      child: Row(
        children: [
          // Row number — tap to toggle whole-row selection.
          // Long-press on a beat-start row opens the beat subdivision menu.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => state.selectRow(row),
            onLongPress: isBeatStart
                ? () => _showBeatLinesMenu(context, state, beat)
                : null,
            child: SizedBox(
              width: kWRow,
              height: kRowHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    (row + 1).toString().padLeft(2, '0'),
                    style: rowNumStyle,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
          // Data columns
          ...cols.expand((col) => [
                SizedBox(
                  width: _colWidth(col),
                  height: kRowHeight,
                  child: CellWidget(
                    trackIndex: trackIndex,
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
      case CellColumn.fx0cmd:     return 2;
      case CellColumn.fx0val:     return kWGap;
      case CellColumn.fx1cmd:     return 2;
      case CellColumn.fx1val:     return kWGap;
      case CellColumn.fx2cmd:     return 2;
      case CellColumn.fx2val:     return 0;
    }
  }

  /// Long-press context menu for beat-start rows — lets the user set or clear
  /// the per-beat line count override (1–16, or reset to pattern default).
  /// Uses int where 0 = "reset to default".
  static Future<void> _showBeatLinesMenu(
    BuildContext context,
    AppState state,
    int beat,
  ) async {
    final currentOverride = state.beatLineOverride(beat);
    final defaultLpb = state.linesPerBeat;

    // 0 = reset to default; 1-16 = override.
    final options = <PopupMenuEntry<int>>[
      PopupMenuItem<int>(
        value: 0,
        child: Text(
          'Default ($defaultLpb lines)',
          style: kStyleBase.copyWith(
            color: currentOverride == null ? kColAccent : kColHeader,
            fontWeight: currentOverride == null
                ? FontWeight.bold
                : FontWeight.normal,
          ),
        ),
      ),
      const PopupMenuDivider(),
      for (int n = 1; n <= 16; n++)
        PopupMenuItem<int>(
          value: n,
          child: Text(
            '$n line${n == 1 ? '' : 's'}${n == defaultLpb ? ' (default)' : ''}',
            style: kStyleBase.copyWith(
              color: currentOverride == n ? kColAccent : kColHeader,
              fontWeight: currentOverride == n
                  ? FontWeight.bold
                  : FontWeight.normal,
            ),
          ),
        ),
    ];

    final RenderBox? box = context.findRenderObject() as RenderBox?;
    final Offset offset = box?.localToGlobal(Offset.zero) ?? Offset.zero;
    final RelativeRect position = RelativeRect.fromLTRB(
      offset.dx,
      offset.dy,
      offset.dx + (box?.size.width ?? 80),
      offset.dy + (box?.size.height ?? 24),
    );

    final chosen = await showMenu<int>(
      context: context,
      position: position,
      color: kBgTrackHeader,
      items: options,
    );

    if (!context.mounted || chosen == null) return; // dismissed
    // 0 = reset to default, otherwise set override.
    state.setBeatLineOverride(beat, chosen == 0 ? null : chosen);
  }
}
