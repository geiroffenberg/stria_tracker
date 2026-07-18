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

class OpenPatternTrackNotification extends Notification {
  OpenPatternTrackNotification();
}

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
  int? _selectedPatternIndex;
  int? _draggedPatternIndex; // Source pattern during pattern slot drag
  int? _dragTargetPatternIndex; // Target pattern slot during drag
  ({int patternIndex, int trackIndex})? _selectedTimelineCell;
  ({int patternIndex, int trackIndex})? _dragTargetTimelineCell;
  int? _selectedFullTrackIndex; // Entire track column selected
  int? _draggingFullTrackIndex; // Source track during full-track drag
  int? _dragTargetFullTrackIndex; // Target track during full-track drag

  static const double kSlotSize = 64.0;
  static const double kSlotGap = 6.0;

  /// Clears every edit-selection (pattern row / timeline cell / full track)
  /// so only one selection — and one action bar — is ever visible at once.
  /// This does NOT touch the playhead (current-playing-pattern indicator),
  /// which is a completely separate concept tracked by [AppState].
  void _clearEditSelections() {
    _selectedPatternIndex = null;
    _selectedTimelineCell = null;
    _selectedFullTrackIndex = null;
  }

  void _handleSlotTap(AppState state, int patternIndex) {
    // All slots behave the same whether or not a real pattern exists yet —
    // tapping an empty (virtual) slot just creates it transparently.
    if (patternIndex >= state.song.patterns.length) {
      state.createPatternAt(patternIndex);
    }
    // A plain tap is playhead-only — it must never leave an edit selection
    // (and its action bar) open behind it.
    setState(_clearEditSelections);
    if (state.isPlaying && state.playbackFollowsSong) {
      state.queueSongPatternJump(patternIndex);
      // Local repaint only: avoids whole-app rebuild jitter during playback.
      setState(() {});
      return;
    }
    state.selectSongPattern(patternIndex);
  }

  void _handleSlotLongPress(AppState state, int patternIndex) {
    if (patternIndex >= state.song.patterns.length) {
      state.createPatternAt(patternIndex);
    }
    if (!(state.isPlaying && state.playbackFollowsSong)) {
      state.selectSongPattern(patternIndex);
    }
    setState(() {
      _clearEditSelections();
      _selectedPatternIndex = patternIndex;
      _draggedPatternIndex = patternIndex;
      _dragTargetPatternIndex = null;
    });
  }

  int _hitTestPatternSlot(Offset localPosition, double slotPitch) {
    // Calculate which slot is being hovered
    final scrollOffset = _slotsCtrl.offset;
    final relativeY = localPosition.dy + scrollOffset;
    final slotIndex = (relativeY / slotPitch).floor();
    return slotIndex.clamp(0, kMaxSongPatterns - 1);
  }

  void _handlePatternSlotDragDrop(
    BuildContext context,
    AppState state,
    int sourceIndex,
    int targetIndex,
  ) {
    if (sourceIndex == targetIndex) return;

    // Drag-drop always offers the same two choices — Move or Swap — no
    // matter whether the source/target rows are empty or have data.
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgColor,
        title: Text(
          'Move pattern ${sourceIndex + 1}',
          style: kStyleLabel.copyWith(color: kColAccent),
        ),
        content: Text(
          'Move it to slot ${targetIndex + 1}, or swap it with the pattern there.',
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
              state.swapPatterns(sourceIndex, targetIndex);
              setState(() => _selectedPatternIndex = targetIndex);
            },
            child: Text(
              'Swap',
              style: kStyleBase.copyWith(color: kColSelection),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              state.movePatternTo(sourceIndex, targetIndex);
              setState(() => _selectedPatternIndex = targetIndex);
            },
            child: Text('Move', style: kStyleBase.copyWith(color: kColActive)),
          ),
        ],
      ),
    );
  }

  void _moveSelectedPatternUp(AppState state, int patternIndex) {
    state.movePatternUp(patternIndex);
    setState(
      () => _selectedPatternIndex = patternIndex > 0 ? patternIndex - 1 : 0,
    );
  }

  void _moveSelectedPatternDown(AppState state, int patternIndex) {
    state.movePatternDown(patternIndex);
    setState(
      () => _selectedPatternIndex = (patternIndex + 1).clamp(
        0,
        state.song.patterns.length - 1,
      ),
    );
  }

  void _copySelectedPattern(AppState state, int patternIndex) {
    state.duplicatePattern(patternIndex);
    setState(
      () => _selectedPatternIndex = (patternIndex + 1).clamp(
        0,
        state.song.patterns.length - 1,
      ),
    );
  }

  void _mergeSelectedPattern(AppState state, int patternIndex) {
    if (!state.canMergePatternWithNext(patternIndex)) return;
    state.mergePatternWithNext(patternIndex);
    setState(
      () => _selectedPatternIndex = patternIndex.clamp(
        0,
        state.song.patterns.length - 1,
      ),
    );
  }

  void _doubleSelectedPattern(AppState state, int patternIndex) {
    if (!state.canDoublePattern(patternIndex)) return;
    state.doublePattern(patternIndex);
    setState(
      () => _selectedPatternIndex = patternIndex.clamp(
        0,
        state.song.patterns.length - 1,
      ),
    );
  }

  void _newAfterSelectedPattern(AppState state, int patternIndex) {
    state.insertNewPatternAt(patternIndex + 1);
    setState(
      () => _selectedPatternIndex = (patternIndex + 1).clamp(
        0,
        state.song.patterns.length - 1,
      ),
    );
  }

  void _deleteSelectedPattern(AppState state, int patternIndex) {
    // Clears the pattern's data in place — the slot stays, just empty.
    state.removePattern(patternIndex);
    setState(
      () => _selectedPatternIndex = patternIndex.clamp(
        0,
        state.song.patterns.length - 1,
      ),
    );
  }

  void _handleTrackDragDrop(
    BuildContext context,
    AppState state,
    ({int patternIndex, int trackIndex}) source,
    ({int patternIndex, int trackIndex}) target,
  ) {
    // Check if target track is empty
    if (state.isTrackEmpty(target.patternIndex, target.trackIndex)) {
      // Target is empty, just paste
      state.pasteTrackFull(target.patternIndex, target.trackIndex);
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
                state.pasteTrackFull(target.patternIndex, target.trackIndex);
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

  void _handleFullTrackPaste(
    BuildContext context,
    AppState state,
    int targetTrack,
  ) {
    if (!state.hasFullTrackClipboard) return;
    final sourceTrack = state.fullTrackClipboardSource;

    if (state.isTrackEmptyAllPatterns(targetTrack)) {
      state.pasteTrackFullAllPatterns(targetTrack);
      return;
    }

    // Target has data — offer Overwrite / Swap / Move To (the latter two
    // require a known source track that differs from the target).
    final canRelateToSource = sourceTrack != null && sourceTrack != targetTrack;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgColor,
        title: Text(
          'Track ${targetTrack + 1} has data',
          style: kStyleLabel.copyWith(color: kColAccent),
        ),
        content: Text(
          'Choose how to combine it with the clipboard.',
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
              state.pasteTrackFullAllPatterns(targetTrack);
            },
            child: Text(
              'Overwrite',
              style: kStyleBase.copyWith(color: kColActive),
            ),
          ),
          if (canRelateToSource)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                state.swapFullTracks(sourceTrack, targetTrack);
              },
              child: Text(
                'Swap',
                style: kStyleBase.copyWith(color: kColSelection),
              ),
            ),
          if (canRelateToSource)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                state.moveFullTrack(sourceTrack, targetTrack);
              },
              child: Text(
                'Move To',
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
    final slotPitch = kSlotSize + kSlotGap;
    final selectedPatternIndex =
        _selectedPatternIndex != null &&
            _selectedPatternIndex! < state.song.patterns.length
        ? _selectedPatternIndex
        : null;
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
                  width: kSlotSize + 16,
                  child: Column(
                    children: [
                      _buildLeftHeader(),
                      Container(height: 1, color: kColActive.withAlpha(160)),
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (details) {
                            // Tap on specific position to hit-test exact slot
                            final slotIndex = _hitTestPatternSlot(
                              details.localPosition,
                              slotPitch,
                            );
                            _handleSlotTap(state, slotIndex);
                          },
                          onLongPressStart: (details) {
                            final slotIndex = _hitTestPatternSlot(
                              details.localPosition,
                              slotPitch,
                            );
                            _handleSlotLongPress(state, slotIndex);
                          },
                          onLongPressMoveUpdate: (details) {
                            if (_draggedPatternIndex == null) return;
                            final slotIndex = _hitTestPatternSlot(
                              details.localPosition,
                              slotPitch,
                            );
                            if (slotIndex != _dragTargetPatternIndex) {
                              setState(
                                () => _dragTargetPatternIndex = slotIndex,
                              );
                            }
                          },
                          onLongPressEnd: (details) {
                            if (_draggedPatternIndex != null &&
                                _dragTargetPatternIndex != null &&
                                _dragTargetPatternIndex !=
                                    _draggedPatternIndex) {
                              _handlePatternSlotDragDrop(
                                context,
                                state,
                                _draggedPatternIndex!,
                                _dragTargetPatternIndex!,
                              );
                            }
                            setState(() {
                              _draggedPatternIndex = null;
                              _dragTargetPatternIndex = null;
                            });
                          },
                          onLongPressCancel: () {
                            setState(() {
                              _draggedPatternIndex = null;
                              _dragTargetPatternIndex = null;
                            });
                          },
                          child: ListView.builder(
                            controller: _slotsCtrl,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            itemExtent: slotPitch,
                            itemCount: kMaxSongPatterns,
                            itemBuilder: (_, i) {
                              // Every slot renders identically whether or not a
                              // real pattern exists yet — empty ones are just
                              // dimmed. No separate "virtual"/plus-sign state.
                              return _PatternSlot(
                                patternIndex: i,
                                isCurrent:
                                    selectedPatternIndex == null &&
                                    i ==
                                        (state.isPlaying
                                            ? state.playheadArrangementSlot
                                            : state
                                                  .currentArrangementSlotIndex),
                                isPending: shouldBlink && i == pendingSlot,
                                pendingBlinkOn: pendingBlinkOn,
                                isMenuSelected: selectedPatternIndex == i,
                                isDragSource: _draggedPatternIndex == i,
                                isDragTarget: _dragTargetPatternIndex == i,
                                size: kSlotSize,
                                gap: kSlotGap,
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
          if (selectedPatternIndex != null) ...[
            const Divider(height: 1, thickness: 1, color: Color(0xFF226666)),
            _SongPatternActionBar(
              canMoveUp: selectedPatternIndex > 0,
              canMoveDown:
                  selectedPatternIndex < state.song.patterns.length - 1,
              canDouble: state.canDoublePattern(selectedPatternIndex),
              canMerge: state.canMergePatternWithNext(selectedPatternIndex),
              canDelete: !state.song.patterns[selectedPatternIndex].isEmpty,
              onMoveUp: () =>
                  _moveSelectedPatternUp(state, selectedPatternIndex),
              onMoveDown: () =>
                  _moveSelectedPatternDown(state, selectedPatternIndex),
              onCopy: () => _copySelectedPattern(state, selectedPatternIndex),
              onDouble: () =>
                  _doubleSelectedPattern(state, selectedPatternIndex),
              onMerge: () => _mergeSelectedPattern(state, selectedPatternIndex),
              onNewAfter: () =>
                  _newAfterSelectedPattern(state, selectedPatternIndex),
              onDelete: () =>
                  _deleteSelectedPattern(state, selectedPatternIndex),
              onClose: () => setState(() => _selectedPatternIndex = null),
            ),
          ] else if (_selectedTimelineCell != null) ...[
            const Divider(height: 1, thickness: 1, color: Color(0xFF226666)),
            _TrackCellActionBar(
              canPaste: state.hasRowClipboard,
              onCopy: () => state.copyTrackFull(
                _selectedTimelineCell!.patternIndex,
                _selectedTimelineCell!.trackIndex,
              ),
              onCut: () => state.cutTrackFull(
                _selectedTimelineCell!.patternIndex,
                _selectedTimelineCell!.trackIndex,
              ),
              onPaste: () => state.pasteTrackFull(
                _selectedTimelineCell!.patternIndex,
                _selectedTimelineCell!.trackIndex,
              ),
              onDelete: () => state.deleteTrackFull(
                _selectedTimelineCell!.patternIndex,
                _selectedTimelineCell!.trackIndex,
              ),
              onClose: () => setState(() => _selectedTimelineCell = null),
            ),
          ] else if (_selectedFullTrackIndex != null) ...[
            const Divider(height: 1, thickness: 1, color: Color(0xFF226666)),
            _TrackCellActionBar(
              canPaste: state.hasFullTrackClipboard,
              onCopy: () =>
                  state.copyTrackFullAllPatterns(_selectedFullTrackIndex!),
              onCut: () =>
                  state.cutTrackFullAllPatterns(_selectedFullTrackIndex!),
              onPaste: () => _handleFullTrackPaste(
                context,
                state,
                _selectedFullTrackIndex!,
              ),
              onDelete: () =>
                  state.deleteTrackFullAllPatterns(_selectedFullTrackIndex!),
              onClose: () => setState(() => _selectedFullTrackIndex = null),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLeftHeader() {
    return Container(
      height: 28,
      alignment: Alignment.center,
      color: kBgHeader,
      child: Text('PATTERNS', style: kStyleHeader.copyWith(color: kColAccent)),
    );
  }

  final GlobalKey _trackHeaderKey = GlobalKey();

  /// Calculate which track index a given local X offset (relative to the
  /// track-header Stack) maps to. Returns null if outside bounds.
  int? _trackAtHeaderX(double x, double originX, double laneW, double laneGap) {
    if (x < originX) return null;
    final relX = x - originX;
    final slotW = laneW + laneGap;
    final t = (relX / slotW).toInt();
    if (t < 0 || t >= kMaxTracks) return null;
    // Check if x is actually within the lane (not in a gap)
    final laneStart = t * slotW;
    if (relX - laneStart > laneW) return null;
    return t;
  }

  /// Converts a global drag position to the track index it lands on, using
  /// the track-header's RenderBox to translate global -> local coordinates.
  int? _trackAtGlobalPosition(
    Offset globalPosition,
    double originX,
    double laneW,
    double laneGap,
  ) {
    final renderObject = _trackHeaderKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) return null;
    final local = renderObject.globalToLocal(globalPosition);
    return _trackAtHeaderX(local.dx, originX, laneW, laneGap);
  }

  Widget _buildRightHeader(AppState state) {
    const laneGap = 1.0;
    const originX = 4.0;
    return Container(
      height: 40,
      color: kBgHeader,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final laneAreaW = constraints.maxWidth - originX * 2;
          final laneW = (laneAreaW - (kMaxTracks - 1) * laneGap) / kMaxTracks;
          return Stack(
            key: _trackHeaderKey,
            children: [
              // Draw divider lines between lanes
              for (int t = 1; t < kMaxTracks; t++)
                Positioned(
                  left: originX + t * (laneW + laneGap) - laneGap / 2,
                  top: 0,
                  bottom: 0,
                  width: laneGap,
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
                      onLongPressStart: (_) {
                        state.copyTrackFullAllPatterns(t);
                        setState(() {
                          _clearEditSelections();
                          _draggingFullTrackIndex = t;
                          _selectedFullTrackIndex = t;
                          _dragTargetFullTrackIndex = t;
                        });
                      },
                      onLongPressMoveUpdate: (details) {
                        final hit = _trackAtGlobalPosition(
                          details.globalPosition,
                          originX,
                          laneW,
                          laneGap,
                        );
                        if (hit != _dragTargetFullTrackIndex) {
                          setState(() => _dragTargetFullTrackIndex = hit);
                        }
                      },
                      onLongPressEnd: (details) {
                        final source = _draggingFullTrackIndex;
                        final target = _dragTargetFullTrackIndex;
                        setState(() {
                          _draggingFullTrackIndex = null;
                          _dragTargetFullTrackIndex = null;
                        });
                        if (source != null &&
                            target != null &&
                            source != target) {
                          _handleFullTrackPaste(context, state, target);
                          // Select the new location
                          setState(() => _selectedFullTrackIndex = target);
                        }
                      },
                      onLongPressCancel: () {
                        setState(() {
                          _draggingFullTrackIndex = null;
                          _dragTargetFullTrackIndex = null;
                        });
                      },
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
                          color: _dragTargetFullTrackIndex == t
                              ? const Color(0xFF44FF88).withAlpha(100)
                              : null,
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
      _selectedPatternIndex = null;
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
            _openPatternTrackFromTimelineTap(
              context,
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
            // Drag-copy only makes sense for patterns that already exist —
            // an empty/virtual slot has nothing to copy from.
            if (hit != null && hit.patternIndex < state.song.patterns.length) {
              setState(() {
                _clearEditSelections();
                _selectedTimelineCell = hit;
                _dragTargetTimelineCell = null; // Start fresh, no drag yet
              });
              // Copy to clipboard on longpress start
              state.copyTrackFull(hit.patternIndex, hit.trackIndex);
            }
          },
          onLongPressMoveUpdate: (details) {
            final hit = _hitTestTimelineCell(
              state,
              details.localPosition,
              width,
              slotPitch,
            );
            if (hit != null && hit != _dragTargetTimelineCell) {
              setState(() => _dragTargetTimelineCell = hit);
            }
          },
          onLongPressEnd: (details) {
            // Only paste if drag target is different from selected source
            if (_dragTargetTimelineCell != null &&
                _dragTargetTimelineCell != _selectedTimelineCell) {
              _handleTrackDragDrop(
                context,
                state,
                _selectedTimelineCell!,
                _dragTargetTimelineCell!,
              );
              // Select the new location
              setState(() {
                _selectedTimelineCell = _dragTargetTimelineCell;
                _dragTargetTimelineCell = null;
              });
            } else {
              // No move occurred, just clear drag target
              setState(() => _dragTargetTimelineCell = null);
            }
          },
          onLongPressCancel: () {
            // User released or gesture was cancelled - keep selection
            setState(() => _dragTargetTimelineCell = null);
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
              selectedPatternIndex: _selectedTimelineCell?.patternIndex,
              selectedTrackIndex: _selectedTimelineCell?.trackIndex,
              dragTargetPatternIndex: _dragTargetTimelineCell?.patternIndex,
              dragTargetTrackIndex: _dragTargetTimelineCell?.trackIndex,
              selectedFullTrackIndex: _selectedFullTrackIndex,
              dragTargetFullTrackIndex: _dragTargetFullTrackIndex,
              editSelectedPatternRow: _selectedPatternIndex,
              dragSourcePatternRow: _draggedPatternIndex,
              dragTargetPatternRow: _dragTargetPatternIndex,
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

    const laneGap = 1.0;
    const originX = 4.0;
    const laneCount = kMaxTracks;
    final laneAreaW = width - 8;
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

  void _openPatternTrackFromTimelineTap(
    BuildContext context,
    AppState state,
    Offset localPos,
    double width,
    double slotPitch,
  ) {
    final hit = _hitTestTimelineCell(state, localPos, width, slotPitch);
    if (hit == null) return;

    // Tapping an empty/virtual pattern row's cell creates it transparently,
    // same as tapping its slot number, so it can be edited right away.
    if (hit.patternIndex >= state.song.patterns.length) {
      state.createPatternAt(hit.patternIndex);
    }
    setState(_clearEditSelections);
    state.selectSongPattern(hit.patternIndex);
    state.selectTrack(hit.trackIndex);
    OpenPatternTrackNotification().dispatch(context);
  }
}

// ─── Left column widgets ─────────────────────────────────────────────────────

/// A song arrangement slot. Tap focuses/queues it, long-press opens actions.
/// Display-only; gesture handling is at the outer GestureDetector level.
class _PatternSlot extends StatelessWidget {
  final int patternIndex; // index in song.patterns
  final bool isCurrent;
  final bool isPending;
  final bool pendingBlinkOn;
  final bool isMenuSelected;
  final bool isDragSource;
  final bool isDragTarget;
  final double size;
  final double gap;

  const _PatternSlot({
    required this.patternIndex,
    required this.isCurrent,
    required this.isPending,
    required this.pendingBlinkOn,
    required this.isMenuSelected,
    required this.isDragSource,
    required this.isDragTarget,
    required this.size,
    required this.gap,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final exists = patternIndex < state.song.patterns.length;
    final pat = exists ? state.song.patterns[patternIndex] : null;
    final isEmptySlot = pat == null || pat.isEmpty;
    final slotOpacity = isEmptySlot ? kEmptyRowOpacity : 1.0;

    final numberMatch = pat != null
        ? RegExp(r'(\d+)$').firstMatch(pat.name.trim())
        : null;
    final displayLabel = numberMatch != null
        ? numberMatch.group(1)!.padLeft(2, '0')
        : (patternIndex + 1).toString().padLeft(2, '0');

    final square = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: kBgTrackHeader,
        border: Border.all(
          // Edit selection (long-press) uses kColSelection to stay visually
          // distinct from the playhead marker (kColAccent), so the two
          // concepts never look like the same thing.
          color: isMenuSelected
              ? kColSelection
              : (isPending
                    ? (pendingBlinkOn ? kColAccent : kColInactive)
                    : (isCurrent ? kColAccent : kColInactive)),
          width: (isCurrent || isPending || isMenuSelected) ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Center(
        child: Text(
          displayLabel,
          style: kStyleBase.copyWith(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            color: kColHeader,
            letterSpacing: 1,
          ),
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.only(bottom: gap),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: isDragTarget
              ? kColSelection.withAlpha(60)
              : (isDragSource
                    ? kColSelection.withAlpha(40)
                    : (isMenuSelected
                          ? kColSelection.withAlpha(30)
                          : Colors.transparent)),
        ),
        child: Opacity(opacity: slotOpacity, child: square),
      ),
    );
  }
}

// ─── Right column timeline ───────────────────────────────────────────────────

class _SongTimelinePainter extends CustomPainter {
  final List<PatternModel> patterns;
  final double slotPitch;
  final int? playheadSlot;
  final int? playheadRow;
  final int? selectedPatternIndex;
  final int? selectedTrackIndex;
  final int? dragTargetPatternIndex;
  final int? dragTargetTrackIndex;
  final int? selectedFullTrackIndex;
  final int? dragTargetFullTrackIndex;
  final int? editSelectedPatternRow;
  final int? dragSourcePatternRow;
  final int? dragTargetPatternRow;

  _SongTimelinePainter({
    required this.patterns,
    required this.slotPitch,
    required this.playheadSlot,
    required this.playheadRow,
    this.selectedPatternIndex,
    this.selectedTrackIndex,
    this.dragTargetPatternIndex,
    this.dragTargetTrackIndex,
    this.selectedFullTrackIndex,
    this.dragTargetFullTrackIndex,
    this.editSelectedPatternRow,
    this.dragSourcePatternRow,
    this.dragTargetPatternRow,
  });

  static const double _padTop = 4;
  static const double _padBottom = 4;
  static const double _laneGap = 1;

  @override
  void paint(Canvas canvas, Size size) {
    final laneCount = kMaxTracks;
    final laneAreaW = size.width - 8;
    final laneW = (laneAreaW - (laneCount - 1) * _laneGap) / laneCount;
    const originX = 4.0;

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
          Rect.fromLTWH(lx + 0.25, yTop + 0.25, laneW - 0.5, blockH - 0.5),
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

    // Selected track-cell border.
    if (selectedPatternIndex != null && selectedTrackIndex != null) {
      final s = selectedPatternIndex!;
      final t = selectedTrackIndex!;
      if (s < patterns.length) {
        final yTop = s * slotPitch + _padTop;
        final blockH = slotPitch - _padTop - _padBottom;
        final lx = originX + t * (laneW + _laneGap);
        canvas.drawRect(
          Rect.fromLTWH(lx, yTop, laneW, blockH),
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
      // Show drag target if it's different from the selected source cell
      final isDifferentFromSource =
          (s != selectedPatternIndex || t != selectedTrackIndex);
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

    // Full-track selection (entire column highlighted).
    if (selectedFullTrackIndex != null && patterns.isNotEmpty) {
      final t = selectedFullTrackIndex!;
      final lx = originX + t * (laneW + _laneGap);
      final totalHeight = patterns.length * slotPitch;
      canvas.drawRect(
        Rect.fromLTWH(lx, 0, laneW, totalHeight),
        Paint()
          ..color = const Color(0xFF44FF88).withAlpha(40)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRect(
        Rect.fromLTWH(lx, 0, laneW, totalHeight),
        Paint()
          ..color = const Color(0xFF44FF88)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }

    // Full-track drag target (entire column highlighted while dragging over it).
    if (dragTargetFullTrackIndex != null &&
        dragTargetFullTrackIndex != selectedFullTrackIndex &&
        patterns.isNotEmpty) {
      final t = dragTargetFullTrackIndex!;
      final lx = originX + t * (laneW + _laneGap);
      final totalHeight = patterns.length * slotPitch;
      canvas.drawRect(
        Rect.fromLTWH(lx, 0, laneW, totalHeight),
        Paint()
          ..color = const Color(0xFFFFCC44).withAlpha(50)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRect(
        Rect.fromLTWH(lx, 0, laneW, totalHeight),
        Paint()
          ..color = const Color(0xFFFFCC44)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }

    // Whole-row highlight for the pattern row that's long-press edit-selected
    // (or being dragged), so the selection/preview spans the full width —
    // not just the slot-number square in the left column — for a single,
    // consistent "whole row" selection concept.
    void drawWholeRowHighlight(int s, Color color, {required bool fill}) {
      if (s < 0 || s >= kMaxSongPatterns) return;
      final yTop = s * slotPitch + _padTop;
      final blockH = slotPitch - _padTop - _padBottom;
      final rect = Rect.fromLTWH(0, yTop, size.width, blockH);
      if (fill) {
        canvas.drawRect(rect, Paint()..color = color.withAlpha(40));
      }
      canvas.drawRect(
        rect,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }

    if (dragTargetPatternRow != null &&
        dragTargetPatternRow != dragSourcePatternRow) {
      drawWholeRowHighlight(dragTargetPatternRow!, kColSelection, fill: true);
    } else if (dragSourcePatternRow != null) {
      drawWholeRowHighlight(dragSourcePatternRow!, kColSelection, fill: true);
    } else if (editSelectedPatternRow != null) {
      drawWholeRowHighlight(
        editSelectedPatternRow!,
        kColSelection,
        fill: false,
      );
    }
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
      old.selectedPatternIndex != selectedPatternIndex ||
      old.selectedTrackIndex != selectedTrackIndex ||
      old.dragTargetPatternIndex != dragTargetPatternIndex ||
      old.dragTargetTrackIndex != dragTargetTrackIndex ||
      old.selectedFullTrackIndex != selectedFullTrackIndex ||
      old.dragTargetFullTrackIndex != dragTargetFullTrackIndex ||
      old.editSelectedPatternRow != editSelectedPatternRow ||
      old.dragSourcePatternRow != dragSourcePatternRow ||
      old.dragTargetPatternRow != dragTargetPatternRow;
}

class _TrackCellActionBar extends StatelessWidget {
  final bool canPaste;
  final VoidCallback onCopy;
  final VoidCallback onCut;
  final VoidCallback onPaste;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  const _TrackCellActionBar({
    required this.canPaste,
    required this.onCopy,
    required this.onCut,
    required this.onPaste,
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
          const Spacer(),
          _SongActionBtn(label: 'DEL', onTap: onDelete, color: kColStopBtn),
          _SongActionBtn(label: '✕', onTap: onClose),
        ],
      ),
    );
  }
}

class _SongPatternActionBar extends StatelessWidget {
  final bool canMoveUp;
  final bool canMoveDown;
  final bool canDouble;
  final bool canMerge;
  final bool canDelete;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onCopy;
  final VoidCallback onDouble;
  final VoidCallback onMerge;
  final VoidCallback onNewAfter;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  const _SongPatternActionBar({
    required this.canMoveUp,
    required this.canMoveDown,
    required this.canDouble,
    required this.canMerge,
    required this.canDelete,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onCopy,
    required this.onDouble,
    required this.onMerge,
    required this.onNewAfter,
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
          _SongActionBtn(label: '↑', onTap: onMoveUp, enabled: canMoveUp),
          _SongActionBtn(label: '↓', onTap: onMoveDown, enabled: canMoveDown),
          const SizedBox(width: 4),
          _SongActionBtn(label: 'COPY', onTap: onCopy),
          _SongActionBtn(label: '2X', onTap: onDouble, enabled: canDouble),
          _SongActionBtn(label: 'MERGE', onTap: onMerge, enabled: canMerge),
          _SongActionBtn(label: 'NEW', onTap: onNewAfter),
          const Spacer(),
          _SongActionBtn(
            label: 'DEL',
            onTap: onDelete,
            enabled: canDelete,
            color: kColStopBtn,
          ),
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
