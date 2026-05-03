import 'package:flutter/material.dart';
import '../models/cell.dart';
import '../models/track_model.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'cell_row_widget.dart';

/// Displays one full track page: column header row + scrollable pattern grid.
class TrackPageWidget extends StatefulWidget {
  final TrackModel track;
  final int trackIndex;

  const TrackPageWidget({
    super.key,
    required this.track,
    required this.trackIndex,
  });

  @override
  State<TrackPageWidget> createState() => _TrackPageWidgetState();
}

class _TrackPageWidgetState extends State<TrackPageWidget> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  _GridHit? _hitTestGrid(Offset localPosition, int rowCount) {
    final row = ((localPosition.dy + _scrollController.offset) / kRowHeight)
        .floor()
        .clamp(0, rowCount - 1);
    final column = _columnForDx(localPosition.dx);
    if (column == null) return null;
    return _GridHit(row: row, column: column);
  }

  CellColumn? _columnForDx(double dx) {
    double x = dx - (kWRow + 2);
    if (x < 0) return null;
    for (final col in CellColumn.values) {
      final width = _colWidth(col);
      if (x <= width) return col;
      x -= width;
      final gap = _gapAfter(col);
      if (x <= gap) return col;
      x -= gap;
    }
    return null;
  }

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
          child: LayoutBuilder(
            builder: (context, constraints) {
              return GestureDetector(
                behavior: HitTestBehavior.translucent,
                onLongPressStart: (details) {
                  final renderBox = context.findRenderObject() as RenderBox?;
                  if (renderBox == null || rowCount <= 0) return;
                  final local = renderBox.globalToLocal(details.globalPosition);
                  final hit = _hitTestGrid(local, rowCount);
                  if (hit == null) return;
                  state.beginBoxSelection(widget.trackIndex, hit.row, hit.column);
                },
                onLongPressMoveUpdate: (details) {
                  final renderBox = context.findRenderObject() as RenderBox?;
                  if (renderBox == null || rowCount <= 0) return;
                  final local = renderBox.globalToLocal(details.globalPosition);
                  final hit = _hitTestGrid(local, rowCount);
                  if (hit == null) return;
                  state.updateBoxSelection(widget.trackIndex, hit.row, hit.column);
                },
                onLongPressEnd: (_) => state.endBoxSelection(),
                child: ListView.builder(
                  controller: _scrollController,
                  itemCount: rowCount,
                  itemExtent: kRowHeight,
                  itemBuilder: (_, row) {
                    final cell = widget.track.cells[row];
                    final rowSel = selected?.row == row;
                    return CellRowWidget(
                      trackIndex: widget.trackIndex,
                      row: row,
                      cell: cell,
                      isSelected: rowSel,
                      isPlayhead: state.isPlaying && row == playheadRow,
                      selectedCell: selected,
                      collapsed: false,
                    );
                  },
                ),
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
}

class _GridHit {
  final int row;
  final CellColumn column;

  const _GridHit({required this.row, required this.column});
}
