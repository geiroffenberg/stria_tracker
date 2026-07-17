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

class _CollapsedTracksWidgetState extends State<CollapsedTracksWidget> {
  late final ScrollController _hHeader;
  late final ScrollController _hBody;
  bool _syncing = false;
  int _lastFollowedRow = -1;
  AppState? _observedState;

  @override
  void initState() {
    super.initState();
    _hHeader = ScrollController();
    _hBody = ScrollController();
    _hHeader.addListener(() => _sync(_hHeader, _hBody));
    _hBody.addListener(() => _sync(_hBody, _hHeader));
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

  void _onStateChanged() {
    final state = _observedState;
    if (state == null || !state.isPlaying || !state.followPlayhead) return;
    if (!_vBodyCtrl.hasClients) return;
    final row = state.playheadRow;
    if (row == _lastFollowedRow) return;
    _lastFollowedRow = row;
    final pos = _vBodyCtrl.position;
    final target = (row * kRowHeight - pos.viewportDimension / 2 + kRowHeight / 2)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    _vBodyCtrl.jumpTo(target);
  }

  @override
  void dispose() {
    _observedState?.removeListener(_onStateChanged);
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
              // and synced with the body)
              SizedBox(
                width: leftColWidth,
                child: ListView.builder(
                  itemCount: rowCount,
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
                      itemCount: rowCount,
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
  double _dragAccum = 0.0;
  static const double _pixelsPerStep = 11.0;
  static const int _defaultNoteScrollIndex = 49; // C-4

  DateTime? _lastTapTime;
  static const Duration _doubleTapWindow = Duration(milliseconds: 300);

  void _select(AppState state) {
    if (state.currentTrackIndex != widget.trackIndex) {
      state.selectTrack(widget.trackIndex);
    }
    if (widget.column == CellColumn.note && widget.cell.note.isEmpty) {
      state.setNote(
        widget.row,
        NoteValue.fromScrollIndex(_defaultNoteScrollIndex),
      );
    }
    if (widget.column == CellColumn.instrument &&
        cellIsEmpty(widget.column, widget.cell)) {
      // Drum mode: auto-fill with the track number (1-based)
      if (widget.drumPill) {
        final trackInstrument = widget.trackIndex + 1; // 1-based track = 1-based instrument
        state.currentTrack.writeColumnValue(widget.row, widget.column, trackInstrument);
        state.updateLastInstrument(trackInstrument);
        // Also auto-fill the note with C-4 if empty
        if (widget.cell.note.isEmpty) {
          state.setNote(
            widget.row,
            NoteValue.fromScrollIndex(_defaultNoteScrollIndex),
          );
        }
      } else {
        // Normal mode: use last instrument value
        state.insertDefaultValue(widget.row, widget.column);
      }
    }
    state.selectCell(widget.row, widget.column);
  }
  void _handleTap(AppState state) {
    final now = DateTime.now();
    final last = _lastTapTime;
    _lastTapTime = now;

    if (last != null && now.difference(last) < _doubleTapWindow) {
      _lastTapTime = null;
      // Double-tap: always clear the cell
      state.clearCellInTrack(widget.row, widget.trackIndex);
      return;
    }

    // Single tap:
    // Drum mode on non-empty cell: cycle velocity
    // Otherwise: just select
    if (widget.drumPill && widget.cell.instrument != null && !widget.cell.note.isOff) {
      // Non-empty drum cell: cycle velocity
      state.cycleDrumVelocity(widget.row, widget.trackIndex);
    } else {
      // Empty or normal cell: just select
      _select(state);
    }
  }

  void _onDragStart(AppState state) {
    if (cellIsEmpty(widget.column, widget.cell)) {
      _select(state);
      state.insertDefaultValue(widget.row, widget.column);
    }
    _dragAccum = 0.0;
    _select(state);
  }

  void _onDragUpdate(AppState state, DragUpdateDetails d) {
    _dragAccum -= d.delta.dy;
    final steps = (_dragAccum / _pixelsPerStep).truncate();
    if (steps != 0) {
      _dragAccum -= steps * _pixelsPerStep;
      state.nudgeCell(widget.row, widget.column, steps);
      // Preview note when editing note cells
      if (widget.column == CellColumn.note) {
        state.previewCellNoteOneShot(widget.row);
      }
    }
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

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _handleTap(state),
      onVerticalDragStart: (_) => _onDragStart(state),
      onVerticalDragUpdate: (d) => _onDragUpdate(state, d),
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
