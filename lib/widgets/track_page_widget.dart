import 'package:flutter/material.dart';
import '../models/cell.dart';
import '../models/track_model.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'cell_row_widget.dart';

/// Displays one full track page: column header row + scrollable pattern grid.
class TrackPageWidget extends StatelessWidget {
  final TrackModel track;
  final int trackIndex;

  const TrackPageWidget({
    super.key,
    required this.track,
    required this.trackIndex,
  });

  @override
  Widget build(BuildContext context) {
    final state      = AppStateScope.of(context);
    final selected   = state.selectedCell;
    final playheadRow = state.playheadRow;
    final rowCount = state.rowCount;

    return Column(
      children: [
        _buildColumnHeader(false),
        Expanded(
          child: ListView.builder(
            itemCount: rowCount,
            itemExtent: kRowHeight,
            itemBuilder: (_, row) {
              final cell      = track.cells[row];
              final rowSel    = selected?.row == row;
              return CellRowWidget(
                row:         row,
                cell:        cell,
                isSelected:  rowSel,
                isPlayhead:  state.isPlaying && row == playheadRow,
                selectedCell: selected,
                collapsed:   false,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildColumnHeader(bool collapsed) {
    final cols = collapsed
        ? [CellColumn.note, CellColumn.instrument]
        : CellColumn.values;

    final List<Widget> children = [
      // Placeholder for row number column
      SizedBox(width: kWRow + 2 /* tick */),
    ];

    for (final col in cols) {
      children.add(SizedBox(
        width: _colWidth(col),
        child: Text(col.header, style: kStyleHeader),
      ));
      children.add(SizedBox(width: _gapAfter(col)));
    }

    return Container(
      height: 22,
      color:  kBgHeader,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(children: children),
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
