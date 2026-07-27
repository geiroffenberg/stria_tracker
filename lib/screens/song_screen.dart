import 'dart:math' show sqrt;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../main.dart' show switchPalette, paletteNotifier;
import '../models/note_value.dart';
import '../models/pattern_model.dart';
import '../models/song_model.dart';
import '../models/track_model.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

enum _SongMenuAction {
  newSong,
  saveSong,
  loadSong,
  chooseProjectFolder,
  showProjectPath,
  changePalette,
  exportWav,
  showManual,
  autosave,
  stabilityMode,
}

/// Song arrangement screen.
///
/// Layout:
///   • LEFT  — vertical column of pattern slots (numbered squares).
///             Tap to focus the pattern in the editor; long-press opens
///             the bottom action bar for move/duplicate/delete actions.
///   • RIGHT — read-only mini-overview showing all 16 tracks for every
///             slot in the arrangement, scrolling top-to-bottom.
///             A horizontal line marks the current playhead.
class SongScreen extends StatefulWidget {
  const SongScreen({super.key});

  @override
  State<SongScreen> createState() => _SongScreenState();
}

class _SongScreenState extends State<SongScreen> {
  // Vertical scroll for both columns kept in sync so the slot square next
  // to the timeline always lines up.
  final _slotsCtrl = ScrollController();
  final _timelineCtrl = ScrollController();
  final _nameCtrl = TextEditingController();
  final _nameFocus = FocusNode();
  bool _syncing = false;
  bool _editingName = false;
  bool _saveAfterRename = false;

  // ── Timeline (track-cell) selection ────────────────────────────────────
  // The selection is a rectangle from [_selectionAnchor] to [_selectionEnd].
  // A single-cell selection has anchor == end.
  //
  // Gestures:
  //   • TAP on a cell (no selection or otherwise): collapses to a fresh
  //     single-cell selection at that cell. Replaces any prior range.
  //   • Long-press when nothing is selected: sets anchor = end = hit cell.
  //     A drag within that same long-press acts as the classic single-cell
  //     "drag-to-move" (with the Overwrite / Swap dialog when the target
  //     already has data).
  //   • Long-press while a selection already exists (single or range):
  //     EXTENDS the selection so it spans the anchor and the newly pressed
  //     cell. A drag within this second long-press keeps updating the end
  //     corner. No drag-to-move in this case.
  //   • Any action button (CUT / COPY / PASTE / DEL / ✕) clears the
  //     selection so the very next tap/long-press starts fresh.
  ({int patternIndex, int trackIndex})? _selectionAnchor;
  ({int patternIndex, int trackIndex})? _selectionEnd;
  // Drag-to-move destination while a *fresh* long-press is in progress.
  // Only used when the current gesture is NOT extending an existing range.
  ({int patternIndex, int trackIndex})? _dragTargetTimelineCell;
  // True for the duration of a long-press that is extending an existing
  // range (i.e. a second/third/... press while a selection is already up).
  bool _gestureExtendsRange = false;

  static const double kSlotSize = 22.0; // small square around the pattern number
  static const double kRowHeight = 64.0; // timeline row height (per pattern)
  static const double kSlotGap = 6.0;

  bool get _hasTimelineSelection => _selectionAnchor != null;

  /// Normalized top-left / bottom-right of the current selection (or null).
  ({int pTop, int tLeft, int pBottom, int tRight})? get _selectionRect {
    final a = _selectionAnchor;
    final e = _selectionEnd;
    if (a == null || e == null) return null;
    final pTop = a.patternIndex < e.patternIndex
        ? a.patternIndex
        : e.patternIndex;
    final pBottom = a.patternIndex < e.patternIndex
        ? e.patternIndex
        : a.patternIndex;
    final tLeft = a.trackIndex < e.trackIndex ? a.trackIndex : e.trackIndex;
    final tRight = a.trackIndex < e.trackIndex ? e.trackIndex : a.trackIndex;
    return (pTop: pTop, tLeft: tLeft, pBottom: pBottom, tRight: tRight);
  }

  void _clearTimelineSelection(AppState state) {
    _selectionAnchor = null;
    _selectionEnd = null;
    _dragTargetTimelineCell = null;
    _gestureExtendsRange = false;
    state.clearSongTimelineSelectionAnchor();
  }

  void _handleSlotTap(AppState state, int patternIndex) {
    // All slots behave the same whether or not a real pattern exists yet —
    // tapping an empty (virtual) slot just creates it transparently.
    if (patternIndex >= state.song.patterns.length) {
      state.createPatternAt(patternIndex);
    }
    // A plain slot tap is playhead-only — it must never leave a timeline
    // selection (and its action bar) open behind it.
    setState(() => _clearTimelineSelection(state));
    if (state.isPlaying && state.playbackFollowsSong) {
      state.queueSongPatternJump(patternIndex);
      // Local repaint only: avoids whole-app rebuild jitter during playback.
      setState(() {});
      return;
    }
    state.selectSongPattern(patternIndex);
  }

  int _hitTestPatternSlot(Offset localPosition, double slotPitch) {
    // Calculate which slot is being hovered
    final scrollOffset = _slotsCtrl.offset;
    final relativeY = localPosition.dy + scrollOffset;
    final slotIndex = (relativeY / slotPitch).floor();
    return slotIndex.clamp(0, kMaxSongPatterns - 1);
  }

  void _handleTrackDragDrop(
    BuildContext context,
    AppState state,
    ({int patternIndex, int trackIndex}) source,
    ({int patternIndex, int trackIndex}) target,
  ) {
    // Check if target track is empty
    if (state.isTrackEmpty(target.patternIndex, target.trackIndex)) {
      // Target is empty, just move the source's cells directly across.
      state.moveTrackFullTo(
        source.patternIndex,
        source.trackIndex,
        target.patternIndex,
        target.trackIndex,
      );
    } else {
      // Target has data, show dialog with options
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: kBgColor,
          title: Text(
            'Target cell has data',
            style: kStyleLabel.copyWith(color: kColAccent),
          ),
          content: Text(
            'Pattern ${target.patternIndex + 1}, Track ${target.trackIndex + 1} already has data.',
            style: kStyleBase.copyWith(color: kColHeader),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                'Cancel',
                style: kStyleBase.copyWith(color: kColInactive),
              ),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                state.moveTrackFullTo(
                  source.patternIndex,
                  source.trackIndex,
                  target.patternIndex,
                  target.trackIndex,
                );
              },
              child: Text(
                'Overwrite',
                style: kStyleBase.copyWith(color: kColActive),
              ),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                state.swapTracks(
                  source.patternIndex,
                  source.trackIndex,
                  target.patternIndex,
                  target.trackIndex,
                );
              },
              child: Text(
                'Swap',
                style: kStyleBase.copyWith(color: kColSelection),
              ),
            ),
          ],
        ),
      );
    }
  }

  // ── Range action-bar handlers ─────────────────────────────────────────────

  void _copyTimelineSelection(AppState state) {
    final r = _selectionRect;
    if (r == null) return;
    state.copyTrackRange(r.pTop, r.tLeft, r.pBottom, r.tRight);
    // Clear selection so the very next tap/long-press starts fresh at the
    // paste target — no accidental range-extension into the source area.
    setState(() => _clearTimelineSelection(state));
  }

  void _cutTimelineSelection(AppState state) {
    final r = _selectionRect;
    if (r == null) return;
    state.cutTrackRange(r.pTop, r.tLeft, r.pBottom, r.tRight);
    setState(() => _clearTimelineSelection(state));
  }

  void _deleteTimelineSelection(AppState state) {
    final r = _selectionRect;
    if (r == null) return;
    state.deleteTrackRange(r.pTop, r.tLeft, r.pBottom, r.tRight);
    setState(() => _clearTimelineSelection(state));
  }

  void _insertPatternAfterSelection(BuildContext context, AppState state) {
    final r = _selectionRect;
    if (r == null) return;
    // For a multi-row selection, insert after the bottom-most selected row.
    final ok = state.insertEmptyPatternAfter(r.pBottom);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Song is full (99 patterns max).'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    setState(() => _clearTimelineSelection(state));
  }

  void _duplicatePatternAtSelection(BuildContext context, AppState state) {
    final r = _selectionRect;
    if (r == null) return;
    // Duplicate the row that holds the selected cell (top of selection).
    final ok = state.duplicatePatternAfter(r.pTop);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Song is full (99 patterns max).'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    setState(() => _clearTimelineSelection(state));
  }

  void _pasteTimelineSelection(BuildContext context, AppState state) {
    final r = _selectionRect;
    if (r == null) return;
    if (!state.hasTrackRangeClipboard) return;

    final ph = state.trackRangeClipboardPatternCount;
    final tw = state.trackRangeClipboardTrackCount;
    // Paste anchor is the top-left of the current selection; the target
    // rectangle takes the clipboard's own dimensions, so a bigger selection
    // rectangle acts as a "hint" of where to start rather than sizing the
    // paste itself.
    final anchorP = r.pTop;
    final anchorT = r.tLeft;

    final targetHasData = !state.isTrackRangeEmpty(anchorP, anchorT, ph, tw);
    if (!targetHasData) {
      state.pasteTrackRange(anchorP, anchorT);
      setState(() => _clearTimelineSelection(state));
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgColor,
        title: Text(
          'Target range has data',
          style: kStyleLabel.copyWith(color: kColAccent),
        ),
        content: Text(
          ph == 1 && tw == 1
              ? 'The target cell already has data.'
              : 'One or more of the target cells already have data.',
          style: kStyleBase.copyWith(color: kColHeader),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: kStyleBase.copyWith(color: kColInactive),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              state.pasteTrackRange(anchorP, anchorT);
              setState(() => _clearTimelineSelection(state));
            },
            child: Text(
              'Overwrite',
              style: kStyleBase.copyWith(color: kColActive),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              state.pasteTrackRangeSwap(anchorP, anchorT);
              setState(() => _clearTimelineSelection(state));
            },
            child: Text(
              'Swap',
              style: kStyleBase.copyWith(color: kColSelection),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _slotsCtrl.addListener(() => _sync(_slotsCtrl, _timelineCtrl));
    _timelineCtrl.addListener(() => _sync(_timelineCtrl, _slotsCtrl));
  }

  void _sync(ScrollController src, ScrollController dst) {
    if (_syncing || !dst.hasClients) return;
    if (dst.offset == src.offset) return;
    _syncing = true;
    dst.jumpTo(
      src.offset.clamp(
        dst.position.minScrollExtent,
        dst.position.maxScrollExtent,
      ),
    );
    _syncing = false;
  }

  @override
  void dispose() {
    _slotsCtrl.dispose();
    _timelineCtrl.dispose();
    _nameCtrl.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final slotPitch = kRowHeight + kSlotGap;
    final pendingSlot = state.queuedArrangementSlot;
    final shouldBlink =
        state.isPlaying &&
        pendingSlot != null &&
        pendingSlot != state.playheadArrangementSlot;
    final pendingBlinkOn = state.playheadRow.isEven;

    return Container(
      color: kBgColor,
      child: Column(
        children: [
          _buildSaveLoadPanel(context, state),
          Container(height: 1, color: kColActive.withAlpha(160)),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Left column: pattern slots ────────────────────────────────
                SizedBox(
                  width: kSlotSize + 8,
                  child: Column(
                    children: [
                      _buildLeftHeader(),
                      Container(height: 1, color: kColActive.withAlpha(160)),
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (details) {
                            // Tap on specific position to hit-test exact slot.
                            // Row numbers are tap-only — long-press has no
                            // action here anymore; all track-editing gestures
                            // happen inside the timeline on the right.
                            final slotIndex = _hitTestPatternSlot(
                              details.localPosition,
                              slotPitch,
                            );
                            _handleSlotTap(state, slotIndex);
                          },
                          child: ListView.builder(
                            controller: _slotsCtrl,
                            padding: EdgeInsets.zero,
                            itemExtent: slotPitch,
                            itemCount: kMaxSongPatterns,
                            itemBuilder: (_, i) {
                              // Every slot renders identically whether or not a
                              // real pattern exists yet — empty ones are just
                              // dimmed. No separate "virtual"/plus-sign state.
                              return _PatternSlot(
                                patternIndex: i,
                                isCurrent:
                                    i ==
                                    (state.isPlaying
                                        ? state.playheadArrangementSlot
                                        : state.currentArrangementSlotIndex),
                                isPending: shouldBlink && i == pendingSlot,
                                pendingBlinkOn: pendingBlinkOn,
                                rowHeight: slotPitch,
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                Container(width: 1, color: kColActive.withAlpha(160)),

                // ── Right column: timeline overview ────────────────────────────
                Expanded(
                  child: Column(
                    children: [
                      _buildRightHeader(state),
                      Container(height: 1, color: kColActive.withAlpha(160)),
                      Expanded(
                        child: SingleChildScrollView(
                          controller: _timelineCtrl,
                          child: _buildTimeline(state, slotPitch),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_hasTimelineSelection) ...[
            const Divider(height: 1, thickness: 1, color: Color(0xFF226666)),
            _TrackCellActionBar(
              canPaste: state.hasTrackRangeClipboard,
              onCopy: () => _copyTimelineSelection(state),
              onCut: () => _cutTimelineSelection(state),
              onPaste: () => _pasteTimelineSelection(context, state),
              onIn: () => _insertPatternAfterSelection(context, state),
              onDup: () => _duplicatePatternAtSelection(context, state),
              onDelete: () => _deleteTimelineSelection(state),
              onClose: () => setState(() => _clearTimelineSelection(state)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLeftHeader() {
    return Container(
      height: 40,
      alignment: Alignment.center,
      color: kBgHeader,
      child: Text('PN', style: kStyleHeader.copyWith(color: kColAccent)),
    );
  }

  Widget _buildRightHeader(AppState state) {
    const laneGap = 0.0;
    const originX = 0.0;
    return Container(
      height: 40,
      color: kBgHeader,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final laneAreaW = constraints.maxWidth - originX * 2;
          final laneW = (laneAreaW - (kMaxTracks - 1) * laneGap) / kMaxTracks;
          return Stack(
            children: [
              // Draw divider lines between lanes
              for (int t = 1; t < kMaxTracks; t++)
                Positioned(
                  left: originX + t * (laneW + laneGap) - 0.5,
                  top: 0,
                  bottom: 0,
                  width: 1,
                  child: Container(color: kColInactive.withAlpha(80)),
                ),
              // Track number buttons
              for (int t = 0; t < kMaxTracks; t++)
                Positioned(
                  left: originX + t * (laneW + laneGap),
                  top: 0,
                  bottom: 0,
                  width: laneW,
                  child: Material(
                    color: Colors.transparent,
                    child: GestureDetector(
                      onTap: () => state.toggleTrackMixerSolo(t),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(
                            color:
                                t < state.currentPattern.tracks.length &&
                                    state.currentPattern.tracks[t].mixerSolo
                                ? kColStopBtn
                                : kColInactive.withAlpha(60),
                            width: 0.5,
                          ),
                        ),
                        child: Text(
                          t < state.currentPattern.tracks.length &&
                                  state.currentPattern.tracks[t].mixerSolo
                              ? 'S'
                              : '${t + 1}',
                          style: kStyleHeader.copyWith(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color:
                                t < state.currentPattern.tracks.length &&
                                    state.currentPattern.tracks[t].mixerSolo
                                ? kColStopBtn
                                : kColAccent,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSaveLoadPanel(BuildContext ctx, AppState state) {
    if (!_editingName && _nameCtrl.text != state.song.name) {
      _nameCtrl.text = state.song.name;
    }

    return Container(
      color: kBgHeader,
      padding: const EdgeInsets.fromLTRB(10, 5, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_editingName)
            Row(
              children: [
                Expanded(
                  child: Text(
                    state.song.name,
                    style: TextStyle(
                      color: kColHeader,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                GestureDetector(
                  onTap: () => _startRename(state),
                  child: Icon(Icons.edit, size: 22, color: kColInactive),
                ),
                const SizedBox(width: 4),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  icon: Icon(
                    Icons.undo,
                    size: 22,
                    color: state.canUndoSong ? kColAccent : kColInactive,
                  ),
                  tooltip: state.undoSongLabel != null
                      ? 'Undo: ${state.undoSongLabel}'
                      : 'Nothing to undo',
                  onPressed: state.canUndoSong ? () => state.undoSong() : null,
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  icon: Icon(
                    Icons.redo,
                    size: 22,
                    color: state.canRedoSong ? kColAccent : kColInactive,
                  ),
                  tooltip: state.redoSongLabel != null
                      ? 'Redo: ${state.redoSongLabel}'
                      : 'Nothing to redo',
                  onPressed: state.canRedoSong ? () => state.redoSong() : null,
                ),
                const SizedBox(width: 4),
                PopupMenuButton<_SongMenuAction>(
                  tooltip: 'Song actions',
                  color: kBgTrackHeader,
                  icon: Icon(Icons.menu, size: 28, color: kColAccent),
                  onSelected: (action) =>
                      _handleSongMenuAction(ctx, state, action),
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: _SongMenuAction.newSong,
                      child: Text('New Song', style: TextStyle(fontSize: 16)),
                    ),
                    const PopupMenuItem(
                      value: _SongMenuAction.saveSong,
                      child: Text('Save Song', style: TextStyle(fontSize: 16)),
                    ),
                    const PopupMenuItem(
                      value: _SongMenuAction.loadSong,
                      child: Text('Load Song', style: TextStyle(fontSize: 16)),
                    ),
                    const PopupMenuItem(
                      value: _SongMenuAction.chooseProjectFolder,
                      child: Text(
                        'Project Folder',
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                    const PopupMenuItem(
                      value: _SongMenuAction.showProjectPath,
                      child: Text('Show Path', style: TextStyle(fontSize: 16)),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: _SongMenuAction.changePalette,
                      child: Text(
                        'Color Palette',
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                    PopupMenuItem(
                      value: _SongMenuAction.autosave,
                      child: Row(
                        children: [
                          Icon(
                            state.autosaveEnabled
                                ? Icons.check_box
                                : Icons.check_box_outline_blank,
                            size: 18,
                            color: kColAccent,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Autosave (10 min)',
                            style: TextStyle(fontSize: 16),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: _SongMenuAction.stabilityMode,
                      child: Row(
                        children: [
                          Icon(
                            state.stabilityModeEnabled
                                ? Icons.check_box
                                : Icons.check_box_outline_blank,
                            size: 18,
                            color: kColAccent,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Stability Mode (Screen Recording)',
                            style: TextStyle(fontSize: 16),
                          ),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: _SongMenuAction.exportWav,
                      child: Text('Export WAV', style: TextStyle(fontSize: 16)),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: _SongMenuAction.showManual,
                      child: Text('How to Use', style: TextStyle(fontSize: 16)),
                    ),
                  ],
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 30,
                    child: TextField(
                      controller: _nameCtrl,
                      focusNode: _nameFocus,
                      autofocus: true,
                      style: TextStyle(color: kColHeader),
                      autocorrect: false,
                      enableSuggestions: false,
                      autofillHints: const <String>[],
                      decoration: InputDecoration(
                        hintText: 'Song name',
                        hintStyle: TextStyle(color: kColInactive),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: kColAccent),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: kColAccent),
                        ),
                      ),
                      onSubmitted: (_) => _commitRename(state),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => _commitRename(state),
                  child: Icon(Icons.check, size: 18, color: kColAccent),
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: _cancelRename,
                  child: Icon(Icons.close, size: 18, color: kColInactive),
                ),
              ],
            ),
        ],
      ),
    );
  }

  void _startRename(AppState state) {
    _nameCtrl.text = state.song.name == 'New Song' ? '' : state.song.name;
    setState(() {
      _editingName = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nameFocus.requestFocus();
    });
  }

  Future<void> _commitRename(AppState state) async {
    final value = _nameCtrl.text.trim();
    if (value.isEmpty) return;
    state.renameSong(value);
    if (!mounted) return;
    setState(() => _editingName = false);

    if (_saveAfterRename) {
      _saveAfterRename = false;
      await _handleSave(context, state);
    }
  }

  void _cancelRename() {
    if (!mounted) return;
    _saveAfterRename = false;
    setState(() => _editingName = false);
  }

  /// Show a dialog to prompt user for a new song name with validation.
  /// Returns the song name on success, or null if cancelled.
  Future<String?> _showNewSongDialog(BuildContext ctx, AppState state) async {
    final controller = TextEditingController();
    String? errorText;
    return showDialog<String>(
      context: ctx,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) => AlertDialog(
          title: const Text('New Song'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Enter a unique name for your new song:'),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Song name',
                  errorText: errorText,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) {
                  if (errorText != null) {
                    setDialogState(() => errorText = null);
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                final name = controller.text.trim();
                if (name.isEmpty) {
                  setDialogState(
                    () => errorText = 'Song name cannot be empty.',
                  );
                  return;
                }
                final exists = await state.songNameExists(name);
                if (!dialogCtx.mounted) return;
                if (exists) {
                  setDialogState(
                    () => errorText =
                        'A song with this name already exists. Choose a different name.',
                  );
                  return;
                }
                Navigator.pop(dialogCtx, name);
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleNew(BuildContext ctx, AppState state) async {
    if (_editingName) _commitRename(state);
    final ready = await _ensureProjectFolder(ctx, state);
    if (!ready) return;
    final newName = await _showNewSongDialog(ctx, state);
    if (newName == null) return; // User cancelled
    final saved = await state.newSongWithName(newName);
    if (!ctx.mounted) return;
    setState(() {
      _editingName = false;
      _clearTimelineSelection(state);
    });
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text(
          saved
              ? 'Song saved. New project "$newName" created.'
              : 'New project "$newName" created (save failed).',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _handleSave(BuildContext ctx, AppState state) async {
    if (_editingName) _commitRename(state);
    final ready = await _ensureProjectFolder(ctx, state);
    if (!ready) return;
    if (state.song.name == 'New Song') {
      _saveAfterRename = true;
      _startRename(state);
      if (!ctx.mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(
          content: Text('Name the song, then confirm to save it.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    final ok = await state.saveSong();
    if (!ctx.mounted) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Saved "${state.song.name}".' : 'Save failed.'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _handleSongMenuAction(
    BuildContext ctx,
    AppState state,
    _SongMenuAction action,
  ) {
    switch (action) {
      case _SongMenuAction.newSong:
        _handleNew(ctx, state);
        break;
      case _SongMenuAction.saveSong:
        _handleSave(ctx, state);
        break;
      case _SongMenuAction.loadSong:
        _handleLoadMenu(ctx, state);
        break;
      case _SongMenuAction.chooseProjectFolder:
        _handleChooseProjectFolder(ctx, state);
        break;
      case _SongMenuAction.showProjectPath:
        _showProjectPath(ctx, state);
        break;
      case _SongMenuAction.changePalette:
        _showPalettePicker(ctx);
        break;
      case _SongMenuAction.exportWav:
        _handleExportWav(ctx, state);
        break;
      case _SongMenuAction.showManual:
        _showManual(ctx);
        break;
      case _SongMenuAction.autosave:
        state.setAutosaveEnabled(!state.autosaveEnabled);
        break;
      case _SongMenuAction.stabilityMode:
        state.setStabilityMode(!state.stabilityModeEnabled);
        break;
    }
  }

  Future<void> _showManual(BuildContext ctx) async {
    final navigator = Navigator.of(ctx);
    await navigator.push<void>(
      MaterialPageRoute<void>(builder: (_) => const _ManualPage()),
    );
  }

  Future<bool> _ensureProjectFolder(BuildContext ctx, AppState state) async {
    if (state.hasProjectRootFolder) return true;
    final picked = await state.chooseProjectRootFolder();
    if (!ctx.mounted) return false;
    if (picked == null) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(
          content: Text(
            'Choose a project folder before saving, loading, or exporting songs.',
          ),
          duration: Duration(seconds: 2),
        ),
      );
      return false;
    }
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text('Project folder selected.'),
        duration: const Duration(seconds: 2),
      ),
    );
    return true;
  }

  Future<void> _handleLoadMenu(BuildContext ctx, AppState state) async {
    final ready = await _ensureProjectFolder(ctx, state);
    if (!ready || !mounted) return;
    await _showLoadBottomSheet(ctx, state);
  }

  Future<void> _showLoadBottomSheet(BuildContext ctx, AppState state) async {
    List<String> names = [];
    bool loading = true;

    await showModalBottomSheet<void>(
      context: ctx,
      backgroundColor: kBgTrackHeader,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          // Kick off load on first build.
          if (loading) {
            state.listSavedSongs().then((result) {
              if (sheetCtx.mounted) {
                setSheetState(() {
                  names = result;
                  loading = false;
                });
              }
            });
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Load Song',
                  style: TextStyle(
                    color: kColAccent,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    fontFamily: kFontMono,
                  ),
                ),
                const SizedBox(height: 12),
                if (loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (names.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        'No saved songs found.',
                        style: TextStyle(color: kColInactive, fontSize: 15),
                      ),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 360),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: names.length,
                      separatorBuilder: (_, _) =>
                          Divider(height: 1, color: kColInactive.withAlpha(80)),
                      itemBuilder: (_, i) => InkWell(
                        onTap: () {
                          Navigator.of(sheetCtx).pop();
                          _loadFromName(ctx, state, names[i]);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 14,
                          ),
                          child: Text(
                            names[i],
                            style: TextStyle(color: kColHeader, fontSize: 17),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _handleChooseProjectFolder(
    BuildContext ctx,
    AppState state,
  ) async {
    final picked = await state.chooseProjectRootFolder();
    if (!ctx.mounted || picked == null) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      const SnackBar(
        content: Text('Project folder updated.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _showProjectPath(BuildContext ctx, AppState state) async {
    final projectPath = await state.currentProjectPath();
    if (!ctx.mounted) return;

    final text = projectPath ?? 'No project folder set yet.';
    await showDialog<void>(
      context: ctx,
      builder: (_) => AlertDialog(
        title: const Text('Project Path'),
        content: SelectableText(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleExportWav(BuildContext ctx, AppState state) async {
    final ready = await _ensureProjectFolder(ctx, state);
    if (!ready) return;

    if (state.isPlaying) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(
          content: Text('Stop playback before exporting.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // Show progress dialog — export takes as long as the song.
    if (!ctx.mounted) return;
    showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        title: Text('Exporting WAV'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 16),
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Playing song and capturing audio…'),
          ],
        ),
      ),
    );

    final path = await state.exportSongToWav();

    if (!ctx.mounted) return;
    Navigator.of(ctx).pop(); // close progress dialog

    if (path == null) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(
          content: Text('Export failed or song is empty.'),
          duration: Duration(seconds: 3),
        ),
      );
    } else {
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text('Saved: $path'),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  void _showPalettePicker(BuildContext ctx) {
    showModalBottomSheet<void>(
      context: ctx,
      backgroundColor: kBgTrackHeader,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => ValueListenableBuilder<TrackerPalette>(
        valueListenable: paletteNotifier,
        builder: (_, active, _) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Color Palette',
                    style: TextStyle(
                      color: kColAccent,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      fontFamily: kFontMono,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    alignment: WrapAlignment.spaceEvenly,
                    spacing: 12,
                    runSpacing: 16,
                    children: kAllPalettes.map((p) {
                      final selected = p.name == active.name;
                      return GestureDetector(
                        onTap: () {
                          switchPalette(p);
                          Navigator.of(ctx).pop();
                        },
                        child: SizedBox(
                          width: 64,
                          child: Column(
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: p.previewColor,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: selected
                                        ? (ThemeData.estimateBrightnessForColor(
                                                    p.previewColor,
                                                  ) ==
                                                  Brightness.dark
                                              ? Colors.white
                                              : Colors.black)
                                        : Colors.transparent,
                                    width: 3,
                                  ),
                                  boxShadow: selected
                                      ? [
                                          BoxShadow(
                                            color: p.previewColor.withAlpha(
                                              180,
                                            ),
                                            blurRadius: 12,
                                          ),
                                        ]
                                      : null,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                p.name,
                                style: TextStyle(
                                  color: selected ? kColAccent : kColHeader,
                                  fontSize: 11,
                                  fontFamily: kFontMono,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.normal,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _loadFromName(
    BuildContext ctx,
    AppState state,
    String name,
  ) async {
    final ok = await state.loadSongByName(name);
    if (!ctx.mounted) return;
    final failReason = state.lastLoadError;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Loaded "$name".'
              : failReason == null || failReason.isEmpty
              ? 'Load failed.'
              : 'Load failed: $failReason',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Widget _buildTimeline(AppState state, double slotPitch) {
    // Draw all slots including virtual empty ones, up to kMaxSongPatterns.
    final totalH = kMaxSongPatterns * slotPitch;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            _handleTimelineTap(
              state,
              details.localPosition,
              width,
              slotPitch,
            );
          },
          onLongPressStart: (details) {
            final hit = _hitTestTimelineCell(
              state,
              details.localPosition,
              width,
              slotPitch,
            );
            if (hit == null) return;
            // Empty/virtual slots don't have a real pattern yet — create
            // one transparently first, same as tapping the slot number or
            // the cell itself does. Without this, rows below the last real
            // pattern could never be long-press-selected at all.
            if (hit.patternIndex >= state.song.patterns.length) {
              state.createPatternAt(hit.patternIndex);
            }
            setState(() {
              if (_selectionAnchor == null) {
                // Fresh selection: single cell, drag-to-move is armed.
                _selectionAnchor = hit;
                _selectionEnd = hit;
                _dragTargetTimelineCell = null;
                _gestureExtendsRange = false;
              } else {
                // A selection already exists → this long-press EXTENDS it.
                // Anchor stays put; end jumps to the newly-pressed cell so
                // the rectangle spans both.
                _selectionEnd = hit;
                _dragTargetTimelineCell = null;
                _gestureExtendsRange = true;
              }
            });
            state.setSongTimelineSelectionAnchor(
              hit.patternIndex,
              hit.trackIndex,
            );
            // NOTE: the range clipboard is only touched by the explicit
            // COPY / CUT action-bar buttons. Auto-copying here on every
            // long-press would clobber whatever the user had already
            // staged as soon as they long-press a paste target.
          },
          onLongPressMoveUpdate: (details) {
            final hit = _hitTestTimelineCell(
              state,
              details.localPosition,
              width,
              slotPitch,
            );
            if (hit == null) return;
            if (_gestureExtendsRange) {
              // Drag inside an extending gesture keeps updating the range's
              // end corner — same as the "long-press a second cell" flow.
              if (hit != _selectionEnd) {
                setState(() => _selectionEnd = hit);
              }
            } else {
              // Fresh single-cell gesture → this is a drag-to-paste preview.
              if (hit != _dragTargetTimelineCell) {
                setState(() => _dragTargetTimelineCell = hit);
              }
            }
          },
          onLongPressEnd: (details) {
            if (_gestureExtendsRange) {
              setState(() {
                _gestureExtendsRange = false;
                _dragTargetTimelineCell = null;
              });
              return;
            }
            // Fresh single-cell gesture: if the finger was dragged to a
            // different cell, treat it as the classic drag-to-paste. The
            // Overwrite / Swap dialog only fires when the drag target
            // differs from the source.
            if (_dragTargetTimelineCell != null &&
                _selectionAnchor != null &&
                _dragTargetTimelineCell != _selectionAnchor) {
              final source = _selectionAnchor!;
              final target = _dragTargetTimelineCell!;
              _handleTrackDragDrop(context, state, source, target);
              setState(() {
                _selectionAnchor = target;
                _selectionEnd = target;
                _dragTargetTimelineCell = null;
              });
              state.setSongTimelineSelectionAnchor(
                target.patternIndex,
                target.trackIndex,
              );
            } else {
              setState(() => _dragTargetTimelineCell = null);
            }
          },
          onLongPressCancel: () {
            // User released or gesture was cancelled - keep selection
            setState(() {
              _dragTargetTimelineCell = null;
              _gestureExtendsRange = false;
            });
          },
          child: CustomPaint(
            size: Size(width, totalH),
            painter: _SongTimelinePainter(
              patterns: List.of(state.song.patterns),
              slotPitch: slotPitch,
              playheadSlot: state.isPlaying
                  ? state.playheadArrangementSlot
                  : null,
              playheadRow: state.isPlaying ? state.playheadRow : null,
              selectionRect: _selectionRect,
              dragTargetPatternIndex: _dragTargetTimelineCell?.patternIndex,
              dragTargetTrackIndex: _dragTargetTimelineCell?.trackIndex,
            ),
            child: SizedBox(width: width, height: totalH),
          ),
        );
      },
    );
  }

  /// Returns the (patternIndex, trackIndex) that [localPos] maps to in the
  /// timeline, or null if the position is outside the content area.
  ({int patternIndex, int trackIndex})? _hitTestTimelineCell(
    AppState state,
    Offset localPos,
    double width,
    double slotPitch,
  ) {
    final patternIndex = (localPos.dy / slotPitch).floor();
    if (patternIndex < 0 || patternIndex >= kMaxSongPatterns) {
      return null;
    }

    const laneGap = 0.0;
    const originX = 0.0;
    const laneCount = kMaxTracks;
    final laneAreaW = width;
    if (laneAreaW <= 0) return null;

    final x = localPos.dx - originX;
    if (x < 0 || x > laneAreaW) return null;

    final laneW = (laneAreaW - (laneCount - 1) * laneGap) / laneCount;
    if (laneW <= 0) return null;

    final lanePitch = laneW + laneGap;
    final rawTrack = (x / lanePitch).floor();
    if (rawTrack < 0 || rawTrack >= laneCount) return null;

    // Ignore positions in the 1px gap between lanes.
    final laneStart = rawTrack * lanePitch;
    if (x - laneStart > laneW) return null;

    // Empty/virtual slots beyond the real pattern list don't have a track
    // list yet, so fall back to the full lane count.
    final trackCount = patternIndex < state.song.patterns.length
        ? state.song.patterns[patternIndex].tracks.length
        : laneCount;
    final trackIndex = rawTrack.clamp(0, trackCount - 1);
    return (patternIndex: patternIndex, trackIndex: trackIndex);
  }

  /// Tap on a timeline cell → make it the single-cell selection.
  ///
  /// Tapping never opens the pattern view anymore. Navigation into the
  /// pattern view happens only via the PATTERN tab in the top nav, which
  /// uses this selection as the anchor for what to focus on.
  void _handleTimelineTap(
    AppState state,
    Offset localPos,
    double width,
    double slotPitch,
  ) {
    final hit = _hitTestTimelineCell(state, localPos, width, slotPitch);
    if (hit == null) return;

    // Tapping an empty/virtual pattern row's cell creates it transparently
    // so subsequent range operations work on a real pattern.
    if (hit.patternIndex >= state.song.patterns.length) {
      state.createPatternAt(hit.patternIndex);
    }
    setState(() {
      _selectionAnchor = hit;
      _selectionEnd = hit;
      _dragTargetTimelineCell = null;
      _gestureExtendsRange = false;
    });
    state.setSongTimelineSelectionAnchor(hit.patternIndex, hit.trackIndex);
  }
}

// ─── Left column widgets ─────────────────────────────────────────────────────

/// A song arrangement slot. Tap-only display widget for the pattern-row
/// number. All track-editing gestures live in the timeline on the right.
class _PatternSlot extends StatelessWidget {
  final int patternIndex; // index in song.patterns
  final bool isCurrent;
  final bool isPending;
  final bool pendingBlinkOn;
  final double rowHeight;

  const _PatternSlot({
    required this.patternIndex,
    required this.isCurrent,
    required this.isPending,
    required this.pendingBlinkOn,
    required this.rowHeight,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final exists = patternIndex < state.song.patterns.length;
    final pat = exists ? state.song.patterns[patternIndex] : null;
    final isEmptySlot = pat == null || pat.isEmpty;
    final slotOpacity = isEmptySlot ? kEmptyRowOpacity : 1.0;

    // Slot numbers are permanent — they always equal the fixed position in
    // the 99-row arrangement grid, never derived from the pattern's own
    // name. Pattern data (and its name) can move between slots, but the
    // slot label itself must never move with it.
    final displayLabel = (patternIndex + 1).toString().padLeft(2, '0');

    final square = Container(
      width: double.infinity,
      height: rowHeight,
      decoration: BoxDecoration(
        color: kBgTrackHeader,
        border: Border.all(
          color: isPending
              ? (pendingBlinkOn ? kColAccent : kColInactive)
              : (isCurrent ? kColAccent : kColInactive),
          width: (isCurrent || isPending) ? 2 : 1,
        ),
      ),
      child: Center(
        child: Text(
          displayLabel,
          style: kStyleBase.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: kColHeader,
            letterSpacing: 0,
          ),
        ),
      ),
    );

    // Minimal left margin just enough to keep the left border visible; the
    // right edge butts right up against the divider that separates this
    // column from the timeline grid.
    return Opacity(
      opacity: slotOpacity,
      child: Padding(padding: const EdgeInsets.only(left: 2), child: square),
    );
  }
}

// ─── Right column timeline ───────────────────────────────────────────────────

class _SongTimelinePainter extends CustomPainter {
  final List<PatternModel> patterns;
  final double slotPitch;
  final int? playheadSlot;
  final int? playheadRow;
  final ({int pTop, int tLeft, int pBottom, int tRight})? selectionRect;
  final int? dragTargetPatternIndex;
  final int? dragTargetTrackIndex;

  _SongTimelinePainter({
    required this.patterns,
    required this.slotPitch,
    required this.playheadSlot,
    required this.playheadRow,
    this.selectionRect,
    this.dragTargetPatternIndex,
    this.dragTargetTrackIndex,
  });

  static const double _padTop = 0;
  static const double _padBottom = 0;
  static const double _laneGap = 0;

  @override
  void paint(Canvas canvas, Size size) {
    final laneCount = kMaxTracks;
    final laneAreaW = size.width;
    final laneW = (laneAreaW - (laneCount - 1) * _laneGap) / laneCount;
    const originX = 0.0;

    final dividerPaint = Paint()
      ..color = kColInactive.withAlpha(60)
      ..strokeWidth = 0.5;

    for (int s = 0; s < kMaxSongPatterns; s++) {
      final hasPattern = s < patterns.length;
      final pat = hasPattern ? patterns[s] : null;
      final isEmptySlot = pat == null || pat.isEmpty;
      final rowOpacity = isEmptySlot ? kEmptyRowOpacity : 1.0;
      final yTop = s * slotPitch + _padTop;
      final blockH = slotPitch - _padTop - _padBottom;

      final laneBorderPaint = Paint()
        ..color = kColInactive.withAlpha((180 * rowOpacity).round())
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5;

      for (int t = 0; t < laneCount; t++) {
        final lx = originX + t * (laneW + _laneGap);
        canvas.drawRect(
          Rect.fromLTWH(lx, yTop, laneW, blockH),
          Paint()..color = kBgBeat.withAlpha((255 * rowOpacity).round()),
        );
        canvas.drawRect(
          Rect.fromLTWH(lx, yTop, laneW, blockH),
          laneBorderPaint,
        );
        if (pat != null && t < pat.tracks.length) {
          _drawLaneNotes(
            canvas,
            pat.tracks[t],
            lx,
            yTop,
            laneW,
            blockH,
            pat.rowCount,
          );
        }
      }

      canvas.drawLine(
        Offset(0, yTop + blockH + _padBottom - 0.5),
        Offset(size.width, yTop + blockH + _padBottom - 0.5),
        dividerPaint,
      );

      // END OF SONG marker removed: playback now stops at empty rows naturally
    }

    // Playhead line.
    if (playheadSlot != null && playheadRow != null) {
      final s = playheadSlot!.clamp(0, patterns.length - 1);
      if (s < patterns.length) {
        final pat = patterns[s];
        final yTop = s * slotPitch + _padTop;
        final blockH = slotPitch - _padTop - _padBottom;
        final y = yTop + (playheadRow! / pat.rowCount) * blockH;
        canvas.drawLine(
          Offset(0, y),
          Offset(size.width, y),
          Paint()
            ..color = kColPlayBtn
            ..strokeWidth = 1.5,
        );
      }
    }

    // Selected track-cell range border. anchor==end draws a single-cell box;
    // wider selections span multiple patterns and/or tracks.
    if (selectionRect != null) {
      final r = selectionRect!;
      final firstS = r.pTop;
      final lastS = r.pBottom;
      final firstT = r.tLeft;
      final lastT = r.tRight;
      if (firstS < kMaxSongPatterns) {
        final yTop = firstS * slotPitch + _padTop;
        final yBot =
            lastS * slotPitch + _padTop + (slotPitch - _padTop - _padBottom);
        final lx = originX + firstT * (laneW + _laneGap);
        final rx = originX + lastT * (laneW + _laneGap) + laneW;
        final rect = Rect.fromLTRB(lx, yTop, rx, yBot);
        // Very light fill so the selected area reads as a group, especially
        // for multi-cell selections.
        canvas.drawRect(
          rect,
          Paint()..color = const Color(0xFF44FF88).withAlpha(40),
        );
        canvas.drawRect(
          rect,
          Paint()
            ..color = const Color(0xFF44FF88)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0,
        );
      }
    }

    // Drag target border (shown while dragging, with a lighter/dashed appearance).
    if (dragTargetPatternIndex != null && dragTargetTrackIndex != null) {
      final s = dragTargetPatternIndex!;
      final t = dragTargetTrackIndex!;
      // Show drag target if it's different from the anchor cell of the
      // current single-cell selection (drag-to-paste is only meaningful for
      // single-cell selections).
      final anchorP = selectionRect?.pTop;
      final anchorT = selectionRect?.tLeft;
      final isDifferentFromSource = (s != anchorP || t != anchorT);
      if (s < patterns.length && isDifferentFromSource) {
        final yTop = s * slotPitch + _padTop;
        final blockH = slotPitch - _padTop - _padBottom;
        final lx = originX + t * (laneW + _laneGap);
        // Draw with a dotted/dashed effect using smaller dash segments
        final dashPaint = Paint()
          ..color = const Color(0xFF88FF88).withAlpha(150)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5;
        _drawDashedRect(
          canvas,
          Rect.fromLTWH(lx, yTop, laneW, blockH),
          dashPaint,
          4.0,
          2.0,
        );
      }
    }

    // Whole-row highlight for the pattern row that's long-press edit-selected
    // (or being dragged), so the selection/preview spans the full width —
    // not just the slot-number square in the left column — for a single,
    // consistent "whole row" selection concept.
  }

  /// Helper to draw a dashed rectangle border.
  void _drawDashedRect(
    Canvas canvas,
    Rect rect,
    Paint paint,
    double dashLength,
    double gapLength,
  ) {
    const segments = [
      (Offset(0, 0), Offset(1, 0)), // top
      (Offset(1, 0), Offset(1, 1)), // right
      (Offset(1, 1), Offset(0, 1)), // bottom
      (Offset(0, 1), Offset(0, 0)), // left
    ];

    for (final (start, end) in segments) {
      final p1 = Offset(
        rect.left + start.dx * rect.width,
        rect.top + start.dy * rect.height,
      );
      final p2 = Offset(
        rect.left + end.dx * rect.width,
        rect.top + end.dy * rect.height,
      );
      _drawDashedLine(canvas, p1, p2, paint, dashLength, gapLength);
    }
  }

  /// Helper to draw a dashed line between two points.
  void _drawDashedLine(
    Canvas canvas,
    Offset p1,
    Offset p2,
    Paint paint,
    double dashLength,
    double gapLength,
  ) {
    final dx = p2.dx - p1.dx;
    final dy = p2.dy - p1.dy;
    final distance = sqrt(dx * dx + dy * dy);
    if (distance == 0) return;

    final segments = (distance / (dashLength + gapLength)).ceil();
    for (int i = 0; i < segments; i++) {
      final start = dashLength * i / distance;
      final end = (dashLength * i + dashLength) / distance;
      if (start >= 1) break;

      final p1s = Offset(
        p1.dx + dx * start.clamp(0, 1),
        p1.dy + dy * start.clamp(0, 1),
      );
      final p2s = Offset(
        p1.dx + dx * end.clamp(0, 1),
        p1.dy + dy * end.clamp(0, 1),
      );
      canvas.drawLine(p1s, p2s, paint);
    }
  }

  void _drawLaneNotes(
    Canvas canvas,
    TrackModel track,
    double x,
    double y,
    double w,
    double h,
    int rowCount,
  ) {
    final paint = Paint();
    final pxPerRow = h / rowCount;
    for (int r = 0; r < track.cells.length && r < rowCount; r++) {
      final n = track.cells[r].note;
      if (n.isEmpty) continue;
      final dotY = y + r * pxPerRow;
      final dotH = pxPerRow.clamp(1.0, 1.0);
      paint.color = n == NoteValue.off ? kColInactive : kColNote;
      canvas.drawRect(Rect.fromLTWH(x + 1, dotY, w - 2, dotH), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SongTimelinePainter old) =>
      old.patterns != patterns ||
      old.playheadSlot != playheadSlot ||
      old.playheadRow != playheadRow ||
      old.selectionRect != selectionRect ||
      old.dragTargetPatternIndex != dragTargetPatternIndex ||
      old.dragTargetTrackIndex != dragTargetTrackIndex;
}

class _TrackCellActionBar extends StatelessWidget {
  final bool canPaste;
  final VoidCallback onCopy;
  final VoidCallback onCut;
  final VoidCallback onPaste;
  final VoidCallback onIn;
  final VoidCallback onDup;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  const _TrackCellActionBar({
    required this.canPaste,
    required this.onCopy,
    required this.onCut,
    required this.onPaste,
    required this.onIn,
    required this.onDup,
    required this.onDelete,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      color: kBgTrackHeader,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Row(
        children: [
          _SongActionBtn(label: 'CUT', onTap: onCut),
          _SongActionBtn(label: 'COPY', onTap: onCopy),
          _SongActionBtn(label: 'PASTE', onTap: onPaste, enabled: canPaste),
          _SongActionBtn(label: 'INS', onTap: onIn),
          _SongActionBtn(label: 'DUP', onTap: onDup),
          const Spacer(),
          _SongActionBtn(label: 'DEL', onTap: onDelete, color: kColStopBtn),
          _SongActionBtn(label: '✕', onTap: onClose),
        ],
      ),
    );
  }
}

class _SongActionBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool enabled;
  final Color? color;

  const _SongActionBtn({
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = enabled ? (color ?? kColAccent) : kColInactive;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          height: 44,
          constraints: const BoxConstraints(minWidth: 44),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.withAlpha(20),
            border: Border.all(color: c),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: kStyleBase.copyWith(
              color: c,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ),
    );
  }
}

enum _ManualSection {
  overview('Overview', 'manual_01_overview.md'),
  coreConcepts('Core Concepts', 'manual_02_core_concepts.md'),
  songScreen('Song Screen', 'manual_03_song_screen.md'),
  patternScreen('Pattern Screen', 'manual_04_pattern_screen.md'),
  instrumentScreen('Instrument Screen', 'manual_05_instrument_screen.md'),
  mixerScreen('Mixer Screen', 'manual_06_mixer_screen.md'),
  instruments('Instruments', 'manual_07_instruments.md'),
  fxCommands('FX Commands', 'manual_08_fx_commands.md'),
  insertEffects('Insert Effects', 'manual_09_insert_effects.md'),
  transportBar('Transport Bar', 'manual_10_transport_bar.md'),
  projectManagement('Project Management', 'manual_11_project_management.md');

  final String title;
  final String assetFile;

  const _ManualSection(this.title, this.assetFile);
}

class _ManualPage extends StatefulWidget {
  const _ManualPage();

  @override
  State<_ManualPage> createState() => _ManualPageState();
}

class _ManualPageState extends State<_ManualPage> {
  _ManualSection? _selectedSection;

  @override
  Widget build(BuildContext context) {
    if (_selectedSection == null) {
      return _buildMenuPage(context);
    }
    return _buildSectionPage(context, _selectedSection!);
  }

  Widget _buildMenuPage(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16213E),
        title: const Text('How to Use', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView.builder(
        itemCount: _ManualSection.values.length,
        itemBuilder: (ctx, idx) {
          final section = _ManualSection.values[idx];
          return GestureDetector(
            onTap: () => setState(() => _selectedSection = section),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF16213E),
                border: Border.all(color: Colors.white24, width: 1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                section.title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSectionPage(BuildContext context, _ManualSection section) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16213E),
        title: Text(section.title, style: const TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() => _selectedSection = null),
        ),
      ),
      body: FutureBuilder<String>(
        future: rootBundle.loadString('assets/${section.assetFile}'),
        builder: (ctx, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFFFFD700)),
            );
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error loading section: ${snapshot.error}',
                style: const TextStyle(color: Colors.white70),
              ),
            );
          }
          final content = snapshot.data ?? '';
          return Markdown(
            data: content,
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                .copyWith(
                  p: const TextStyle(color: Colors.white70, fontSize: 14),
                  h1: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                  h2: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  h3: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  code: const TextStyle(
                    color: Color(0xFFFFD700),
                    backgroundColor: Color(0xFF0D1B2A),
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                  codeblockDecoration: BoxDecoration(
                    color: const Color(0xFF0D1B2A),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  blockquoteDecoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: Colors.white38, width: 3),
                    ),
                  ),
                  tableBody: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                  ),
                  tableHead: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                  tableBorder: TableBorder.all(color: Colors.white24),
                ),
            selectable: true,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          );
        },
      ),
    );
  }
}
