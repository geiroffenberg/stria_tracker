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

  static const double kSlotSize = 64.0;
  static const double kSlotGap = 6.0;

  void _handleSlotTap(AppState state, int patternIndex) {
    if (_selectedPatternIndex != null) {
      setState(() => _selectedPatternIndex = null);
    }
    if (state.isPlaying && state.playbackFollowsSong) {
      state.queueSongPatternJump(patternIndex);
      // Local repaint only: avoids whole-app rebuild jitter during playback.
      setState(() {});
      return;
    }
    state.selectSongPattern(patternIndex);
  }

  void _handleSlotLongPress(AppState state, int patternIndex) {
    if (!(state.isPlaying && state.playbackFollowsSong)) {
      state.selectSongPattern(patternIndex);
    }
    setState(() => _selectedPatternIndex = patternIndex);
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
    if (state.song.patterns.length <= 1) return;
    state.removePattern(patternIndex);
    final nextIndex = state.song.patterns.isEmpty
        ? null
        : patternIndex.clamp(0, state.song.patterns.length - 1);
    setState(() => _selectedPatternIndex = nextIndex);
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
                        child: ListView.builder(
                          controller: _slotsCtrl,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          itemExtent: slotPitch,
                          itemCount: kMaxSongPatterns,
                          itemBuilder: (_, i) {
                            final isReal = i < state.song.patterns.length;
                            if (!isReal) {
                              final isFirstVirtual =
                                  i == state.song.patterns.length;
                              final canAdd =
                                  state.song.patterns.length < kMaxSongPatterns;
                              return _EmptySlot(
                                slotNumber: i + 1,
                                active: canAdd,
                                showPlus: isFirstVirtual && canAdd,
                                gap: kSlotGap,
                                onTap: isFirstVirtual && canAdd
                                    ? state.appendNewPattern
                                    : null,
                                onLongPress: null,
                              );
                            }
                            return _PatternSlot(
                              patternIndex: i,
                              isCurrent:
                                  selectedPatternIndex == null &&
                                  i ==
                                      (state.isPlaying
                                          ? state.playheadArrangementSlot
                                          : state.currentArrangementSlotIndex),
                              isPending: shouldBlink && i == pendingSlot,
                              pendingBlinkOn: pendingBlinkOn,
                              isMenuSelected: selectedPatternIndex == i,
                              size: kSlotSize,
                              gap: kSlotGap,
                              onTap: () => _handleSlotTap(state, i),
                              onLongPress: () => _handleSlotLongPress(state, i),
                            );
                          },
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
              canDelete: state.song.patterns.length > 1,
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

  Widget _buildRightHeader(AppState state) {
    const laneGap = 1.0;
    const originX = 4.0;
    return Container(
      height: 28,
      color: kBgHeader,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final laneAreaW = constraints.maxWidth - originX * 2;
          final laneW = (laneAreaW - (kMaxTracks - 1) * laneGap) / kMaxTracks;
          return Stack(
            children: [
              for (int t = 0; t < kMaxTracks; t++)
                Positioned(
                  left: originX + t * (laneW + laneGap),
                  top: 0,
                  bottom: 0,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${t + 1}',
                      style: kStyleHeader.copyWith(color: kColAccent),
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
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                GestureDetector(
                  onTap: () => _startRename(state),
                  child: Icon(Icons.edit, size: 22, color: Colors.white54),
                ),
                const SizedBox(width: 4),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: Icon(
                    Icons.undo,
                    size: 22,
                    color: state.canUndoSong ? kColAccent : kColInactive,
                  ),
                  tooltip: state.undoSongLabel != null
                      ? 'Undo: ${state.undoSongLabel}'
                      : 'Nothing to undo',
                  onPressed: state.canUndoSong
                      ? () => state.undoSong()
                      : null,
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: Icon(
                    Icons.redo,
                    size: 22,
                    color: state.canRedoSong ? kColAccent : kColInactive,
                  ),
                  tooltip: state.redoSongLabel != null
                      ? 'Redo: ${state.redoSongLabel}'
                      : 'Nothing to redo',
                  onPressed: state.canRedoSong
                      ? () => state.redoSong()
                      : null,
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
                      style: const TextStyle(color: Colors.white),
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

  Future<void> _handleNew(BuildContext ctx, AppState state) async {
    if (_editingName) _commitRename(state);
    final ready = await _ensureProjectFolder(ctx, state);
    if (!ready) return;
    final saved = await state.newSong();
    if (!ctx.mounted) return;
    setState(() {
      _editingName = false;
      _selectedPatternIndex = null;
    });
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text(
          saved
              ? 'Song saved. New project created.'
              : 'New project created (save failed).',
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
    final content = await rootBundle.loadString('assets/MANUAL.md');
    await navigator.push<void>(
      MaterialPageRoute<void>(builder: (_) => _ManualPage(content: content)),
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
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                            ),
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
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => ValueListenableBuilder<TrackerPalette>(
        valueListenable: paletteNotifier,
        builder: (_, active, _) => Padding(
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
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: kAllPalettes.map((p) {
                  final selected = p.name == active.name;
                  return GestureDetector(
                    onTap: () {
                      switchPalette(p);
                      Navigator.of(ctx).pop();
                    },
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
                                  ? Colors.white
                                  : Colors.transparent,
                              width: 3,
                            ),
                            boxShadow: selected
                                ? [
                                    BoxShadow(
                                      color: p.previewColor.withAlpha(180),
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
                            color: selected ? Colors.white : kColHeader,
                            fontSize: 11,
                            fontFamily: kFontMono,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 8),
            ],
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
          child: CustomPaint(
            size: Size(width, totalH),
            painter: _SongTimelinePainter(
              patterns: List.of(state.song.patterns),
              slotPitch: slotPitch,
              playheadSlot: state.isPlaying
                  ? state.playheadArrangementSlot
                  : null,
              playheadRow: state.isPlaying ? state.playheadRow : null,
            ),
            child: SizedBox(width: width, height: totalH),
          ),
        );
      },
    );
  }

  void _openPatternTrackFromTimelineTap(
    BuildContext context,
    AppState state,
    Offset localPos,
    double width,
    double slotPitch,
  ) {
    if (state.song.patterns.isEmpty) return;

    final patternIndex = (localPos.dy / slotPitch).floor();
    if (patternIndex < 0 || patternIndex >= state.song.patterns.length) return;

    const laneGap = 1.0;
    const originX = 4.0;
    const laneCount = kMaxTracks;
    final laneAreaW = width - 8;
    if (laneAreaW <= 0) return;

    final x = localPos.dx - originX;
    if (x < 0 || x > laneAreaW) return;

    final laneW = (laneAreaW - (laneCount - 1) * laneGap) / laneCount;
    if (laneW <= 0) return;

    final lanePitch = laneW + laneGap;
    final rawTrack = (x / lanePitch).floor();
    if (rawTrack < 0 || rawTrack >= laneCount) return;

    // Ignore taps in the 1px gap between lanes.
    final laneStart = rawTrack * lanePitch;
    if (x - laneStart > laneW) return;

    state.selectSongPattern(patternIndex);
    final trackCount = state.song.patterns[patternIndex].tracks.length;
    final trackIndex = rawTrack.clamp(0, trackCount - 1);
    state.selectTrack(trackIndex);

    OpenPatternTrackNotification().dispatch(context);
  }
}

// ─── Left column widgets ─────────────────────────────────────────────────────

/// A song arrangement slot. Tap focuses/queues it, long-press opens actions.
class _PatternSlot extends StatelessWidget {
  final int patternIndex; // index in song.patterns
  final bool isCurrent;
  final bool isPending;
  final bool pendingBlinkOn;
  final bool isMenuSelected;
  final double size;
  final double gap;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _PatternSlot({
    required this.patternIndex,
    required this.isCurrent,
    required this.isPending,
    required this.pendingBlinkOn,
    required this.isMenuSelected,
    required this.size,
    required this.gap,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final pat = state.song.patterns[patternIndex];

    final numberMatch = RegExp(r'(\d+)$').firstMatch(pat.name.trim());
    final displayLabel = numberMatch != null
        ? numberMatch.group(1)!.padLeft(2, '0')
        : (patternIndex + 1).toString().padLeft(2, '0');

    final square = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: kBgTrackHeader,
        border: Border.all(
          color: isPending
              ? (pendingBlinkOn ? kColAccent : kColInactive)
              : (isMenuSelected
                    ? kColAccent
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
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            color: isMenuSelected
                ? kColAccent.withAlpha(20)
                : Colors.transparent,
          ),
          child: square,
        ),
      ),
    );
  }
}

/// An empty virtual slot — shows '+' and accepts drag-copy.
class _EmptySlot extends StatelessWidget {
  final int slotNumber; // 1-based display number
  final bool active; // true = tappable
  final bool showPlus;
  final double gap;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _EmptySlot({
    required this.slotNumber,
    required this.active,
    required this.gap,
    this.showPlus = false,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: gap),
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            border: Border.all(color: kColInactive, width: 1),
            borderRadius: BorderRadius.circular(6),
            color: Colors.transparent,
          ),
          child: showPlus
              ? Center(child: Icon(Icons.add, size: 32, color: kColInactive))
              : const SizedBox.shrink(),
        ),
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

  _SongTimelinePainter({
    required this.patterns,
    required this.slotPitch,
    required this.playheadSlot,
    required this.playheadRow,
  });

  static const double _padTop = 4;
  static const double _padBottom = 4;
  static const double _laneGap = 1;

  int? get _firstEmptySlot {
    for (int i = 0; i < patterns.length; i++) {
      if (patterns[i].isEmpty) return i;
    }
    return null;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final endOfSongSlot = _firstEmptySlot;
    final laneCount = kMaxTracks;
    final laneAreaW = size.width - 8;
    final laneW = (laneAreaW - (laneCount - 1) * _laneGap) / laneCount;
    const originX = 4.0;

    final dividerPaint = Paint()
      ..color = kColInactive.withAlpha(60)
      ..strokeWidth = 0.5;

    for (int s = 0; s < patterns.length; s++) {
      final pat = patterns[s];
      final yTop = s * slotPitch + _padTop;
      final blockH = slotPitch - _padTop - _padBottom;

      final laneBorderPaint = Paint()
        ..color = kColInactive.withAlpha(180)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5;

      for (int t = 0; t < laneCount; t++) {
        final lx = originX + t * (laneW + _laneGap);
        canvas.drawRect(
          Rect.fromLTWH(lx, yTop, laneW, blockH),
          Paint()..color = kBgBeat,
        );
        canvas.drawRect(
          Rect.fromLTWH(lx + 0.25, yTop + 0.25, laneW - 0.5, blockH - 0.5),
          laneBorderPaint,
        );
        if (t < pat.tracks.length) {
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

      if (s == endOfSongSlot) {
        final overlayRect = Rect.fromLTWH(4, yTop, size.width - 8, blockH);
        final tp = TextPainter(
          text: TextSpan(
            text: 'END OF SONG',
            style: kStyleBase.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: kColAccent,
              letterSpacing: 1.2,
              shadows: const [
                Shadow(
                  color: Color(0xCC000000),
                  blurRadius: 3,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.center,
        )..layout(maxWidth: overlayRect.width - 12);
        tp.paint(
          canvas,
          Offset(
            overlayRect.left + (overlayRect.width - tp.width) / 2,
            overlayRect.top + (overlayRect.height - tp.height) / 2,
          ),
        );
      }
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
      old.playheadRow != playheadRow;
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

class _ManualPage extends StatelessWidget {
  const _ManualPage({required this.content});

  final String content;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16213E),
        title: const Text('How to Use', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Markdown(
        data: content,
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
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
            border: Border(left: BorderSide(color: Colors.white38, width: 3)),
          ),
          tableBody: const TextStyle(color: Colors.white70, fontSize: 13),
          tableHead: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
          tableBorder: TableBorder.all(color: Colors.white24),
        ),
        selectable: true,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    );
  }
}
