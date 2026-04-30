import 'package:flutter/material.dart';
import '../models/cell.dart';
import '../models/track_model.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'cell_widget.dart';

/// Multi-track overview view shown when [AppState.collapsedView] is true.
///
/// Layout:
///   ┌─────────┬──────────────────────────────────────┐
///   │ row#    │ T01 T02 T03 ... (header, h-scroll)   │
///   │ header  ├──────────────────────────────────────┤
///   │  fixed  │ NOTE INST  NOTE INST  ... (h-scroll) │
///   │  left   │  (vertical scroll for rows)          │
///   └─────────┴──────────────────────────────────────┘
///   The row-number column stays put on the left.
///   The track header and the cell area share a horizontal scroll controller.
class CollapsedTracksWidget extends StatefulWidget {
  const CollapsedTracksWidget({super.key});

  static const double wNote = 38.0;
  static const double wInst = 26.0;
  static const double wTrackGap = 6.0;

  static double get trackWidth => wNote + wInst + wTrackGap;

  @override
  State<CollapsedTracksWidget> createState() => _CollapsedTracksWidgetState();
}

class _CollapsedTracksWidgetState extends State<CollapsedTracksWidget> {
  late final ScrollController _hHeader;
  late final ScrollController _hBody;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _hHeader = ScrollController();
    _hBody = ScrollController();
    _hHeader.addListener(() => _sync(_hHeader, _hBody));
    _hBody.addListener(() => _sync(_hBody, _hHeader));
  }

  void _sync(ScrollController src, ScrollController dst) {
    if (_syncing) return;
    if (!dst.hasClients) return;
    if (dst.offset == src.offset) return;
    _syncing = true;
    dst.jumpTo(src.offset);
    _syncing = false;
  }

  @override
  void dispose() {
    _hHeader.dispose();
    _hBody.dispose();
    _vBodyCtrl.dispose();
    _rowNumCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final tracks = state.currentPattern.tracks;

    final tracksWidth = tracks.length * CollapsedTracksWidget.trackWidth;
    const leftColWidth = kWRow + 2; // row# + tick

    return Column(
      children: [
        // ── Header row: fixed corner + scrollable track labels ────────────
        SizedBox(
          height: 26,
          child: Row(
            children: [
              SizedBox(
                width: leftColWidth,
                child: Container(color: kBgHeader),
              ),
              Expanded(
                child: SingleChildScrollView(
                  controller: _hHeader,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: tracksWidth,
                    child: _buildTrackLabels(tracks),
                  ),
                ),
              ),
            ],
          ),
        ),

        // ── Body: fixed row# column + scrollable cells ────────────────────
        Expanded(
          child: Row(
            children: [
              // Fixed left column — row numbers (vertically scrollable
              // and synced with the body)
              SizedBox(
                width: leftColWidth,
                child: ListView.builder(
                  itemCount: kRowsPerPattern,
                  itemExtent: kRowHeight,
                  controller: _rowNumCtrl,
                  itemBuilder: (_, row) => _buildRowNumber(state, row),
                ),
              ),
              // Horizontally + vertically scrollable cell area
              Expanded(
                child: SingleChildScrollView(
                  controller: _hBody,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: tracksWidth,
                    child: ListView.builder(
                      itemCount: kRowsPerPattern,
                      itemExtent: kRowHeight,
                      controller: _vBodyCtrl,
                      itemBuilder: (_, row) =>
                          _buildCellRow(state, tracks, row),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Vertical sync: bidirectional between body and row# column.
  late final ScrollController _vBodyCtrl = ScrollController()
    ..addListener(() => _syncVertical(_vBodyCtrl, _rowNumCtrl));
  late final ScrollController _rowNumCtrl = ScrollController()
    ..addListener(() => _syncVertical(_rowNumCtrl, _vBodyCtrl));
  bool _vSyncing = false;

  void _syncVertical(ScrollController src, ScrollController dst) {
    if (_vSyncing) return;
    if (!dst.hasClients) return;
    if (dst.offset == src.offset) return;
    _vSyncing = true;
    dst.jumpTo(
      src.offset.clamp(
        dst.position.minScrollExtent,
        dst.position.maxScrollExtent,
      ),
    );
    _vSyncing = false;
  }

  // ── Header content ────────────────────────────────────────────────────────

  Widget _buildTrackLabels(List<TrackModel> tracks) {
    return Container(
      color: kBgHeader,
      child: Row(
        children: [
          for (int i = 0; i < tracks.length; i++) ...[
            SizedBox(
              width: CollapsedTracksWidget.wNote + CollapsedTracksWidget.wInst,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  final state = AppStateScope.of(context);
                  state.selectTrack(i);
                  state.toggleCollapsedView();
                },
                child: Center(
                  child: Text(
                    'T${(i + 1).toString().padLeft(2, '0')}',
                    style: kStyleHeader.copyWith(color: kColAccent),
                  ),
                ),
              ),
            ),
            _trackDivider(),
          ],
        ],
      ),
    );
  }

  // 1px vertical divider sitting in the inter-track gap.
  Widget _trackDivider() {
    return SizedBox(
      width: CollapsedTracksWidget.wTrackGap,
      child: Center(
        child: Container(width: 1, color: kColAccent.withAlpha(60)),
      ),
    );
  }

  // ── Fixed left column row ─────────────────────────────────────────────────

  Widget _buildRowNumber(AppState state, int row) {
    final isPlayhead = state.isPlaying && row == state.playheadRow;
    final rowSel = state.selectedCell?.row == row;
    final bg = rowBgColor(row, rowSel, isPlayhead);

    return Container(
      color: bg,
      child: Row(
        children: [
          SizedBox(
            width: kWRow,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(row.toString().padLeft(2, '0'), style: kStyleRowNum),
            ),
          ),
          Container(
            width: 2,
            color: row % 16 == 0
                ? kColAccent.withAlpha(180)
                : row % 4 == 0
                ? kColAccent.withAlpha(60)
                : Colors.transparent,
          ),
        ],
      ),
    );
  }

  // ── Scrollable cell row ───────────────────────────────────────────────────

  Widget _buildCellRow(AppState state, List<TrackModel> tracks, int row) {
    final isPlayhead = state.isPlaying && row == state.playheadRow;
    final rowSel = state.selectedCell?.row == row;
    final bg = rowBgColor(row, rowSel, isPlayhead);

    return Container(
      color: bg,
      child: Row(
        children: [
          for (int t = 0; t < tracks.length; t++)
            ..._buildMiniTrack(state, tracks[t], t, row),
        ],
      ),
    );
  }

  List<Widget> _buildMiniTrack(
    AppState state,
    TrackModel track,
    int trackIndex,
    int row,
  ) {
    final cell = track.cells[row];
    final sel = state.selectedCell;
    final isCurrentTrack = trackIndex == state.currentTrackIndex;

    return [
      SizedBox(
        width: CollapsedTracksWidget.wNote,
        height: kRowHeight,
        child: _MiniCell(
          cell: cell,
          column: CellColumn.note,
          row: row,
          trackIndex: trackIndex,
          isSelected:
              isCurrentTrack &&
              sel?.row == row &&
              sel?.column == CellColumn.note,
        ),
      ),
      SizedBox(
        width: CollapsedTracksWidget.wInst,
        height: kRowHeight,
        child: _MiniCell(
          cell: cell,
          column: CellColumn.instrument,
          row: row,
          trackIndex: trackIndex,
          isSelected:
              isCurrentTrack &&
              sel?.row == row &&
              sel?.column == CellColumn.instrument,
        ),
      ),
      SizedBox(
        width: CollapsedTracksWidget.wTrackGap,
        height: kRowHeight,
        child: Center(
          child: Container(width: 1, color: kColAccent.withAlpha(40)),
        ),
      ),
    ];
  }
}

/// Cell tile in the multi-track collapsed grid.
class _MiniCell extends StatefulWidget {
  final TrackerCell cell;
  final CellColumn column;
  final int row;
  final int trackIndex;
  final bool isSelected;

  const _MiniCell({
    required this.cell,
    required this.column,
    required this.row,
    required this.trackIndex,
    required this.isSelected,
  });

  @override
  State<_MiniCell> createState() => _MiniCellState();
}

class _MiniCellState extends State<_MiniCell> {
  double _dragAccum = 0.0;
  static const double _pixelsPerStep = 11.0;

  void _select(BuildContext context) {
    final state = AppStateScope.of(context);
    if (state.currentTrackIndex != widget.trackIndex) {
      state.selectTrack(widget.trackIndex);
    }
    state.selectCell(widget.row, widget.column);
  }

  @override
  Widget build(BuildContext context) {
    final text = cellDisplay(widget.column, widget.cell);
    final empty = cellIsEmpty(widget.column, widget.cell);
    final style = empty ? kStyleEmpty : columnStyle(widget.column);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _select(context),
      onVerticalDragStart: (_) {
        _dragAccum = 0.0;
        _select(context);
      },
      onVerticalDragUpdate: (d) {
        _dragAccum -= d.delta.dy;
        final steps = (_dragAccum / _pixelsPerStep).truncate();
        if (steps != 0) {
          _dragAccum -= steps * _pixelsPerStep;
          AppStateScope.of(context).nudgeCell(widget.row, widget.column, steps);
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
