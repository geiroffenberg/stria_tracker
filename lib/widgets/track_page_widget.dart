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

class _TrackPageWidgetState extends State<TrackPageWidget>
    with TickerProviderStateMixin {
  late final ScrollController _scrollController;
  int _lastFollowedRow = -1;
  AppState? _observedState;

  // Plays a brief directional slide when a scroll gesture switches to an
  // adjacent pattern — the vertical equivalent of the obvious "push" motion
  // seen when side-scrolling between tracks. Purely cosmetic: it animates
  // the already-updated grid content sliding in from the direction implied
  // by the switch, rather than showing a text popup.
  late final AnimationController _patternSlideCtrl;
  Offset _slideBegin = Offset.zero;

  // Dragging past the top/bottom row edge accumulates raw drag distance;
  // once it crosses the threshold, jump to the previous/next pattern — the
  // vertical equivalent of side-scrolling between tracks. This tracks raw
  // pointer movement directly (rather than relying on ListView overscroll
  // notifications) so it works reliably even when the pattern is shorter
  // than the viewport. Only armed when the drag started on the row-number
  // column (left side) — the data cells claim vertical drags for value
  // nudging, so this keeps pattern-switching from firing while editing
  // note/value cells.
  double _topDragAccum = 0;
  double _bottomDragAccum = 0;
  bool _dragOnRowNumberColumn = false;
  static const double _patternSwitchThreshold = 60.0;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _patternSlideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      value: 1.0, // starts "settled" so the gap indicator is hidden at rest
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppStateScope.of(context);
    if (_observedState != state) {
      _observedState?.removeListener(_onStateChanged);
      _observedState = state;
      state.addListener(_onStateChanged);
    }
  }

  void _onStateChanged() {
    final state = _observedState;
    if (state == null || !state.isPlaying || !state.followPlayhead) return;
    if (!_scrollController.hasClients) return;
    final row = state.playheadRow;
    if (row == _lastFollowedRow) return;
    _lastFollowedRow = row;
    final pos = _scrollController.position;
    final target =
        (row * kRowHeight - pos.viewportDimension / 2 + kRowHeight / 2).clamp(
          pos.minScrollExtent,
          pos.maxScrollExtent,
        );
    _scrollController.jumpTo(target);
  }

  @override
  void dispose() {
    _observedState?.removeListener(_onStateChanged);
    _scrollController.dispose();
    _patternSlideCtrl.dispose();
    super.dispose();
  }

  void _handleRowNumberPointerDown(PointerDownEvent event) {
    _dragOnRowNumberColumn = event.localPosition.dx <= (kWRow + 2);
    _topDragAccum = 0;
    _bottomDragAccum = 0;
  }

  void _handleRowNumberPointerMove(PointerMoveEvent event, AppState state) {
    if (!_dragOnRowNumberColumn) return;
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    const epsilon = 0.5;
    final atTop = position.pixels <= position.minScrollExtent + epsilon;
    final atBottom = position.pixels >= position.maxScrollExtent - epsilon;
    final dy = event.delta.dy;

    if (dy > 0 && atTop) {
      // Dragging further down while already at the first row — go to the
      // previous pattern.
      _topDragAccum += dy;
      _bottomDragAccum = 0;
      if (_topDragAccum >= _patternSwitchThreshold) {
        _topDragAccum = 0;
        _switchPattern(state, -1);
      }
    } else if (dy < 0 && atBottom) {
      // Dragging further up while already at the last row — go to the next
      // pattern.
      _bottomDragAccum -= dy;
      _topDragAccum = 0;
      if (_bottomDragAccum >= _patternSwitchThreshold) {
        _bottomDragAccum = 0;
        _switchPattern(state, 1);
      }
    } else {
      _topDragAccum = 0;
      _bottomDragAccum = 0;
    }
  }

  void _handleRowNumberPointerEnd(PointerEvent event) {
    _topDragAccum = 0;
    _bottomDragAccum = 0;
  }

  // Switches to the adjacent pattern (direction -1 = previous, +1 = next),
  // then: (a) lands the scroll at the edge that keeps the transition
  // feeling continuous — the next pattern's rows continue on directly
  // below the current bottom, so we land at its top; the previous
  // pattern's rows sit directly above the current top, so we land at its
  // bottom; and (b) plays a brief directional slide of the grid content —
  // the vertical equivalent of the obvious "push" motion seen when
  // side-scrolling between tracks.
  //
  // The scroll-landing jump and animation start are deferred to a
  // post-frame callback so that the ListView for the *new* pattern has
  // already been laid out (with its true content dimensions and updated
  // maxScrollExtent) by the time we jump; jumping against the old
  // pattern's dimensions was silently clamped and made "land at bottom"
  // land at whatever the previous pattern's bottom was instead.
  void _switchPattern(AppState state, int direction) {
    final before = state.currentPatternIndex;
    state.goToAdjacentPattern(direction);
    if (state.currentPatternIndex == before) return;

    setState(() {
      _slideBegin = Offset(0, direction > 0 ? 0.5 : -0.5);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollController.hasClients) {
        final pos = _scrollController.position;
        _scrollController.jumpTo(
          direction < 0 ? pos.maxScrollExtent : pos.minScrollExtent,
        );
      }
      _patternSlideCtrl.forward(from: 0);
    });
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
    final state = AppStateScope.of(context);
    final selected = state.selectedCell;
    final playheadRow = state.playheadRow;
    final rowCount = state.rowCount;

    return Column(
      children: [
        _buildColumnHeader(state, false),
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
                  state.beginBoxSelection(
                    widget.trackIndex,
                    hit.row,
                    hit.column,
                  );
                },
                onLongPressMoveUpdate: (details) {
                  final renderBox = context.findRenderObject() as RenderBox?;
                  if (renderBox == null || rowCount <= 0) return;
                  final local = renderBox.globalToLocal(details.globalPosition);
                  final hit = _hitTestGrid(local, rowCount);
                  if (hit == null) return;
                  state.updateBoxSelection(
                    widget.trackIndex,
                    hit.row,
                    hit.column,
                  );
                },
                onLongPressEnd: (_) => state.endBoxSelection(),
                child: Listener(
                  // Opaque so drag-to-switch-pattern gestures are caught
                  // across the full pane even when the pattern has fewer
                  // rows than fit the viewport (i.e. the ListView doesn't
                  // paint the empty area below the last row).
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _handleRowNumberPointerDown,
                  onPointerMove: (e) => _handleRowNumberPointerMove(e, state),
                  onPointerUp: _handleRowNumberPointerEnd,
                  onPointerCancel: _handleRowNumberPointerEnd,
                  child: SlideTransition(
                    position:
                        Tween<Offset>(
                          begin: _slideBegin,
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: _patternSlideCtrl,
                            curve: Curves.easeOutCubic,
                          ),
                        ),
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
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // Columns whose header can be tapped to select the entire column (normal
  // view only). FX columns are intentionally excluded.
  static const Set<CellColumn> _selectableHeaderColumns = {
    CellColumn.note,
    CellColumn.instrument,
    CellColumn.volume,
  };

  Widget _buildColumnHeader(AppState state, bool collapsed) {
    final cols = collapsed
        ? [CellColumn.note, CellColumn.instrument]
        : CellColumn.values;

    final List<Widget> children = [
      // Placeholder for row number column
      SizedBox(width: kWRow + 2 /* tick */),
    ];

    for (final col in cols) {
      final isSelectable = !collapsed && _selectableHeaderColumns.contains(col);
      final isSelected = isSelectable && state.selectedColumn == col;
      Widget headerCell = SizedBox(
        width: _colWidth(col),
        child: Text(
          col.header,
          style: isSelected
              ? kStyleHeader.copyWith(color: kColAccent)
              : kStyleHeader,
        ),
      );
      if (isSelectable) {
        headerCell = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => state.selectColumn(col),
          child: headerCell,
        );
      }
      children.add(headerCell);
      children.add(SizedBox(width: _gapAfter(col)));
    }

    return Container(
      height: 22,
      color: kBgHeader,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(children: children),
    );
  }

  static double _colWidth(CellColumn col) {
    switch (col) {
      case CellColumn.note:
        return kWNote;
      case CellColumn.instrument:
        return kWInst;
      case CellColumn.volume:
        return kWVol;
      case CellColumn.fx0cmd:
      case CellColumn.fx1cmd:
      case CellColumn.fx2cmd:
        return kWFxCmd;
      case CellColumn.fx0val:
      case CellColumn.fx1val:
      case CellColumn.fx2val:
        return kWFxVal;
    }
  }

  static double _gapAfter(CellColumn col) {
    switch (col) {
      case CellColumn.note:
        return kWGap;
      case CellColumn.instrument:
        return kWGap;
      case CellColumn.volume:
        return kWGap;
      case CellColumn.fx0cmd:
        return 2;
      case CellColumn.fx0val:
        return kWGap;
      case CellColumn.fx1cmd:
        return 2;
      case CellColumn.fx1val:
        return kWGap;
      case CellColumn.fx2cmd:
        return 2;
      case CellColumn.fx2val:
        return 0;
    }
  }
}

class _GridHit {
  final int row;
  final CellColumn column;

  const _GridHit({required this.row, required this.column});
}
