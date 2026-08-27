import 'package:flutter/material.dart';
import '../models/cell.dart';
import '../models/note_value.dart';
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

/// Drum mode velocity constants for accent and half-volume
const int kDrumAccentVolume = 99;
const int kDrumHalfVolume = 50;

class CollapsedTracksWidget extends StatefulWidget {
  const CollapsedTracksWidget({super.key});

  static const double wNote = 38.0;
  static const double wInst = 34.0;
  static const double wDrumPill = 40.0;
  static const double wTrackGap = 6.0;

  /// Track column width for the active mode. Drum mode drops the NOTE
  /// column and shows a single instrument pill.
  static double trackWidthFor(bool drum) =>
      drum ? (wDrumPill + wTrackGap) : (wNote + wInst + wTrackGap);

  @override
  State<CollapsedTracksWidget> createState() => _CollapsedTracksWidgetState();
}

class _CollapsedTracksWidgetState extends State<CollapsedTracksWidget>
    with TickerProviderStateMixin {
  late final ScrollController _hHeader;
  late final ScrollController _hBody;
  bool _syncing = false;
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
  // than the viewport.
  double _topDragAccum = 0;
  double _bottomDragAccum = 0;
  static const double _patternSwitchThreshold = 60.0;

  @override
  void initState() {
    super.initState();
    _hHeader = ScrollController();
    _hBody = ScrollController();
    _hHeader.addListener(() => _sync(_hHeader, _hBody));
    _hBody.addListener(() => _sync(_hBody, _hHeader));
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

  void _sync(ScrollController src, ScrollController dst) {
    if (_syncing) return;
    if (!dst.hasClients) return;
    if (dst.offset == src.offset) return;
    _syncing = true;
    dst.jumpTo(src.offset);
    _syncing = false;
  }

  void _handleRowNumberPointerMove(PointerMoveEvent event, AppState state) {
    if (!_rowNumCtrl.hasClients) return;
    final position = _rowNumCtrl.position;
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
  // bottom (the row-number and body controllers are kept in step by the
  // existing _syncVertical listeners, so jumping the row-number column is
  // enough); and (b) plays a brief directional slide of the grid content —
  // the vertical equivalent of the obvious "push" motion seen when
  // side-scrolling between tracks.
  //
  // The scroll-landing jump and animation start are deferred to a
  // post-frame callback so that the ListView for the *new* pattern has
  // already been laid out (with its true maxScrollExtent) by the time we
  // jump; jumping against the old pattern's dimensions was silently
  // clamped and made "land at bottom" land somewhere else.
  void _switchPattern(AppState state, int direction) {
    final before = state.currentPatternIndex;
    state.goToAdjacentPattern(direction);
    if (state.currentPatternIndex == before) return;

    setState(() {
      _slideBegin = Offset(0, direction > 0 ? 0.5 : -0.5);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_rowNumCtrl.hasClients) {
        final pos = _rowNumCtrl.position;
        _rowNumCtrl.jumpTo(
          direction < 0 ? pos.maxScrollExtent : pos.minScrollExtent,
        );
      }
      _patternSlideCtrl.forward(from: 0);
    });
  }

  void _onStateChanged() {
    final state = _observedState;
    if (state == null || !state.isPlaying || !state.followPlayhead) return;
    if (!_vBodyCtrl.hasClients) return;
    final row = state.playheadRow;
    if (row == _lastFollowedRow) return;
    _lastFollowedRow = row;
    final pos = _vBodyCtrl.position;
    final target =
        (row * kRowHeight - pos.viewportDimension / 2 + kRowHeight / 2).clamp(
          pos.minScrollExtent,
          pos.maxScrollExtent,
        );
    _vBodyCtrl.jumpTo(target);
  }

  @override
  void dispose() {
    _observedState?.removeListener(_onStateChanged);
    _hHeader.dispose();
    _hBody.dispose();
    _vBodyCtrl.dispose();
    _rowNumCtrl.dispose();
    _patternSlideCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final tracks = state.currentPattern.tracks;
    final rowCount = state.rowCount;
    final drum = state.drumView;

    final tracksWidth =
        tracks.length * CollapsedTracksWidget.trackWidthFor(drum);
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
                    child: _buildTrackLabels(tracks, drum),
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
              // and synced with the body). Dragging past the top/
              // bottom edge here (and only here) switches pattern.
              SizedBox(
                width: leftColWidth,
                child: Listener(
                  // Opaque so drag-to-switch-pattern gestures are caught
                  // across the full column even when the pattern has
                  // fewer rows than fit the viewport.
                  behavior: HitTestBehavior.opaque,
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
                      itemCount: rowCount,
                      itemExtent: kRowHeight,
                      controller: _rowNumCtrl,
                      itemBuilder: (_, row) => _buildRowNumber(state, row),
                    ),
                  ),
                ),
              ),
              // Horizontally + vertically scrollable cell area
              Expanded(
                child: SingleChildScrollView(
                  controller: _hBody,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: tracksWidth,
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
                        itemCount: rowCount,
                        itemExtent: kRowHeight,
                        controller: _vBodyCtrl,
                        itemBuilder: (_, row) =>
                            _buildCellRow(state, tracks, row),
                      ),
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

  Widget _buildTrackLabels(List<TrackModel> tracks, bool drum) {
    final state = AppStateScope.of(context);
    final labelWidth = drum
        ? CollapsedTracksWidget.wDrumPill
        : CollapsedTracksWidget.wNote + CollapsedTracksWidget.wInst;
    return Container(
      color: kBgHeader,
      child: Row(
        children: [
          for (int i = 0; i < tracks.length; i++) ...[
            SizedBox(
              width: labelWidth,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => state.toggleTrackMixerSolo(i),
                child: Center(
                  child: Text(
                    'T${(i + 1).toString().padLeft(2, '0')}',
                    style: kStyleHeader.copyWith(
                      color: tracks[i].mixerSolo ? kColStopBtn : kColAccent,
                    ),
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
    final linesPerBeat = state.linesPerBeat;
    final bg = rowBgColor(row, rowSel, isPlayhead, linesPerBeat);
    final isBeatStart = row % linesPerBeat == 0;
    final rowNumStyle = isBeatStart
        ? kStyleRowNum.copyWith(color: kColAccent)
        : kStyleRowNum.copyWith(color: kColRowNum);

    return Container(
      color: bg,
      child: Row(
        children: [
          SizedBox(
            width: kWRow,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                (row + 1).toString().padLeft(2, '0'),
                style: rowNumStyle,
              ),
            ),
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }

  // ── Scrollable cell row ───────────────────────────────────────────────────

  Widget _buildCellRow(AppState state, List<TrackModel> tracks, int row) {
    final isPlayhead = state.isPlaying && row == state.playheadRow;
    final rowSel = state.selectedCell?.row == row;
    final bg = rowBgColor(row, rowSel, isPlayhead, state.linesPerBeat);

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

    // Drum mode: a single instrument pill per track (no NOTE column).
    if (state.drumView) {
      return [
        SizedBox(
          width: CollapsedTracksWidget.wDrumPill,
          height: kRowHeight,
          child: _MiniCell(
            cell: cell,
            column: CellColumn.instrument,
            row: row,
            trackIndex: trackIndex,
            drumPill: true,
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
  final bool drumPill;

  const _MiniCell({
    required this.cell,
    required this.column,
    required this.row,
    required this.trackIndex,
    required this.isSelected,
    this.drumPill = false,
  });

  @override
  State<_MiniCell> createState() => _MiniCellState();
}

class _MiniCellState extends State<_MiniCell> {
  static const int _defaultNoteScrollIndex = 49; // C-4

  DateTime? _lastTapTime;
  static const Duration _doubleTapWindow = Duration(milliseconds: 300);

  /// Selects the tile's track as current and selects the cell. When
  /// [openMenu] is true (cell already holds data) it uses a non-toggling
  /// selection so re-tapping keeps the action bar open.
  void _selectOnly(AppState state, {bool openMenu = false}) {
    if (state.currentTrackIndex != widget.trackIndex) {
      state.selectTrack(widget.trackIndex);
    }
    if (openMenu) {
      state.selectCellKeep(widget.row, widget.column);
    } else {
      state.selectCell(widget.row, widget.column);
    }
  }

  /// Selects the tile AND writes the column's default value into an empty
  /// cell. Used by double-tap to actually enter data; never clobbers an
  /// already-filled cell.
  void _enterDefault(AppState state) {
    // openMenu: true — the first tap of this double-tap may have already
    // selected the cell, so a toggling select here would deselect it again.
    _selectOnly(state, openMenu: true);
    if (!cellIsEmpty(widget.column, widget.cell)) return; // never overwrite
    if (widget.drumPill && widget.column == CellColumn.instrument) {
      // Drum mode: seed with this track's own instrument number + C-4 note.
      final trackInstrument = widget.trackIndex + 1;
      state.currentTrack.writeColumnValue(
        widget.row,
        widget.column,
        trackInstrument,
      );
      state.updateLastInstrument(trackInstrument);
      if (widget.cell.note.isEmpty) {
        state.setNote(
          widget.row,
          NoteValue.fromScrollIndex(_defaultNoteScrollIndex),
        );
      }
    } else {
      state.insertDefaultValue(widget.row, widget.column);
    }
  }

  void _handleTap(AppState state) {
    final now = DateTime.now();
    final last = _lastTapTime;
    _lastTapTime = now;

    if (last != null && now.difference(last) < _doubleTapWindow) {
      // Double-tap: enter the default value. Selection/action bar opens here
      // so the second tap isn't swallowed by a first-tap menu popup.
      _lastTapTime = null;
      _enterDefault(state);
      if (widget.column == CellColumn.note || widget.drumPill) {
        state.previewCellNoteOneShot(widget.row);
      }
      return;
    }

    // Single tap: selecting a cell is only meaningful for acting on it, so a
    // cell that already holds data opens its action bar right away (stable —
    // re-tapping keeps it open). Drum mode on a non-empty pill also cycles
    // velocity. An empty cell is selected passively: no menu, no data write,
    // keeping stray scroll taps safe and leaving the double-tap to enter data.
    final hasData = cellIsEditable(widget.column, widget.cell);
    if (widget.drumPill &&
        widget.cell.instrument != null &&
        !widget.cell.note.isOff) {
      state.cycleDrumVelocity(widget.row, widget.trackIndex);
    }
    _selectOnly(state, openMenu: hasData);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final isBoxSelected = state.isCellInBoxSelection(
      widget.trackIndex,
      widget.row,
      widget.column,
    );

    final Widget child = widget.drumPill
        ? _buildDrumPill(isBoxSelected)
        : _buildTextCell(isBoxSelected);

    // No vertical-drag handling here: a cell must never claim the vertical
    // axis, or it blocks the grid's vertical scroll. Value nudging happens
    // via the action bar's slider/+- controls after selecting the cell.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _handleTap(state),
      child: child,
    );
  }

  Widget _buildTextCell(bool isBoxSelected) {
    final text = cellDisplay(widget.column, widget.cell);
    final empty = cellIsEmpty(widget.column, widget.cell);
    final style = empty ? kStyleEmpty : columnStyle(widget.column);
    final selected = widget.isSelected || isBoxSelected;

    return Container(
      decoration: selected
          ? BoxDecoration(
              color: isBoxSelected
                  ? kBgSelected.withAlpha(widget.isSelected ? 255 : 170)
                  : kBgSelected,
              border: Border.all(color: kColSelection, width: 1.5),
            )
          : null,
      alignment: Alignment.centerLeft,
      padding: EdgeInsets.symmetric(horizontal: selected ? 0.5 : 2.0),
      child: Text(text, style: style, maxLines: 1),
    );
  }

  /// Drum-mode pill: instrument number on a colored pill with velocity gradient,
  /// OFF as a red pill with an ✕, and empty cells as a faint dot.
  /// Velocity is shown via gradient: accent has complement at top,
  /// half-volume has complement at bottom.
  Widget _buildDrumPill(bool isBoxSelected) {
    final cell = widget.cell;
    final selected = widget.isSelected || isBoxSelected;

    final Widget pill;
    if (cell.note.isOff) {
      pill = _pill(
        color: kColStopBtn,
        child: const Text(
          '✕',
          style: TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    } else if (cell.instrument != null) {
      // Render with gradient based on drum velocity
      Gradient? gradient;
      Color textBg = kColAccent;
      if (cell.drumVelocity == DrumVelocity.accent) {
        // Top half: complement color, bottom half: pill color
        gradient = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [kColComplement, kColAccent],
          stops: const [0.0, 0.5],
        );
        textBg = Color.lerp(kColComplement, kColAccent, 0.5)!;
      } else if (cell.drumVelocity == DrumVelocity.half) {
        // Top half: pill color, bottom half: complement color
        gradient = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [kColAccent, kColComplement],
          stops: const [0.5, 1.0],
        );
        textBg = Color.lerp(kColAccent, kColComplement, 0.5)!;
      }

      pill = _pill(
        color: kColAccent,
        gradient: gradient,
        child: Text(
          cell.instrument!.toString().padLeft(2, '0'),
          style: TextStyle(
            color: _contrastTextColor(textBg),
            fontSize: 12,
            fontWeight: FontWeight.w700,
            fontFamily: kFontMono,
          ),
        ),
      );
    } else {
      // Empty slot indicator.
      pill = Container(
        width: 5,
        height: 5,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: kColInactive.withAlpha(70),
        ),
      );
    }

    return Container(
      alignment: Alignment.center,
      decoration: selected
          ? BoxDecoration(
              border: Border.all(color: kColSelection, width: 1.5),
              borderRadius: BorderRadius.circular(11),
            )
          : null,
      child: pill,
    );
  }

  Widget _pill({
    required Color color,
    Gradient? gradient,
    required Widget child,
  }) {
    return Container(
      constraints: const BoxConstraints(minWidth: 28),
      height: 20,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: gradient == null ? color : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(10),
      ),
      child: child,
    );
  }
}

/// Picks black or white — whichever is more readable on top of [bg] —
/// so pill text stays legible regardless of how bright/dark the active
/// palette's accent/complement colours are (e.g. Paper's near-black accent).
Color _contrastTextColor(Color bg) {
  return ThemeData.estimateBrightnessForColor(bg) == Brightness.dark
      ? Colors.white
      : Colors.black;
}
