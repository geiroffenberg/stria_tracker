import 'package:flutter/material.dart';
import '../models/note_value.dart';
import '../models/pattern_model.dart';
import '../models/song_model.dart';
import '../models/track_model.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

class OpenPatternTrackNotification extends Notification {
  OpenPatternTrackNotification();
}

/// Song arrangement screen.
///
/// Layout:
///   • LEFT  — vertical column of pattern slots (numbered squares).
///             Tap to focus the pattern in the editor; the … menu allows
///             muting, duplicating, removing, and adding slots.
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
  final _slotsCtrl    = ScrollController();
  final _timelineCtrl = ScrollController();
  final _nameCtrl = TextEditingController();
  final _nameFocus = FocusNode();
  bool _syncing = false;
  bool _editingName = false;
  bool _showLoadMenu = false;
  bool _loadingSongNames = false;
  bool _showTrashCan = false;
  bool _trashHovered = false;
  List<String> _savedSongNames = const [];

  static const double kSlotSize   = 64.0;
  static const double kSlotGap    = 6.0;

  @override
  void initState() {
    super.initState();
    _slotsCtrl.addListener(()    => _sync(_slotsCtrl,    _timelineCtrl));
    _timelineCtrl.addListener(() => _sync(_timelineCtrl, _slotsCtrl));
  }

  void _sync(ScrollController src, ScrollController dst) {
    if (_syncing || !dst.hasClients) return;
    if (dst.offset == src.offset)    return;
    _syncing = true;
    dst.jumpTo(src.offset.clamp(
      dst.position.minScrollExtent,
      dst.position.maxScrollExtent,
    ));
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
    final slotPitch  = kSlotSize + kSlotGap;

    return Container(
      color: kBgColor,
      child: Stack(
        children: [
          Column(
            children: [
              _buildSaveLoadPanel(context, state),
              Container(height: 1, color: kColInactive.withAlpha(60)),
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
                          Expanded(
                            child: ListView.builder(
                              controller: _slotsCtrl,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4,
                              ),
                              itemExtent: slotPitch,
                              itemCount: kMaxSongPatterns,
                              itemBuilder: (_, i) {
                                final isReal = i < state.song.patterns.length;
                                final isFirstVirtual =
                                    i == state.song.patterns.length;
                                if (!isReal) {
                                  // Show the first empty slot after the list as
                                  // a tappable '+'. The rest are visual placeholders.
                                  return _EmptySlot(
                                    slotNumber: i + 1,
                                    active: isFirstVirtual &&
                                        state.song.patterns.length < kMaxSongPatterns,
                                    gap: kSlotGap,
                                    onTap: isFirstVirtual
                                        ? state.appendNewPattern
                                        : null,
                                    onAcceptDrop: (srcIdx) {
                                      // Drag onto empty virtual slot = copy to end.
                                      state.copyPatternInsertAt(srcIdx, i);
                                    },
                                  );
                                }
                                return _PatternSlot(
                                  patternIndex: i,
                                  isCurrent: i == state.currentArrangementSlotIndex,
                                  size: kSlotSize,
                                  gap: kSlotGap,
                                  onDragStarted: _handlePatternDragStarted,
                                  onDragFinished: _handlePatternDragFinished,
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),

                    Container(width: 1, color: kColInactive.withAlpha(80)),

                    // ── Right column: timeline overview ────────────────────────────
                    Expanded(
                      child: Column(
                        children: [
                          _buildRightHeader(state),
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
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 10,
            child: SafeArea(
              minimum: const EdgeInsets.symmetric(horizontal: 14),
              child: IgnorePointer(
                ignoring: !_showTrashCan,
                child: AnimatedOpacity(
                  opacity: _showTrashCan ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 140),
                  child: Center(
                    child: DragTarget<int>(
                      onWillAcceptWithDetails: (_) {
                        if (!_trashHovered) setState(() => _trashHovered = true);
                        return true;
                      },
                      onLeave: (_) {
                        if (_trashHovered) setState(() => _trashHovered = false);
                      },
                      onAcceptWithDetails: (details) {
                        state.removePattern(details.data);
                        if (mounted) {
                          setState(() {
                            _trashHovered = false;
                            _showTrashCan = false;
                          });
                        }
                      },
                      builder: (_, __, ___) {
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: _trashHovered
                                ? const Color(0x55FF4444)
                                : const Color(0xCC1A1A1A),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: _trashHovered
                                  ? const Color(0xFFFF6666)
                                  : kColInactive,
                              width: 1.2,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.delete_outline,
                                size: 20,
                                color: _trashHovered
                                    ? const Color(0xFFFF6666)
                                    : kColInactive,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'DROP TO DELETE',
                                style: kStyleHeader.copyWith(
                                  color: _trashHovered
                                      ? const Color(0xFFFF6666)
                                      : kColInactive,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _handlePatternDragStarted() {
    if (!mounted) return;
    setState(() {
      _showTrashCan = true;
      _trashHovered = false;
    });
  }

  void _handlePatternDragFinished() {
    if (!mounted) return;
    setState(() {
      _showTrashCan = false;
      _trashHovered = false;
    });
  }

  Widget _buildLeftHeader() {
    return Container(
      height: 28,
      alignment: Alignment.center,
      color: kBgHeader,
      child: Text('PATTERNS',
          style: kStyleHeader.copyWith(color: kColAccent)),
    );
  }

  Widget _buildRightHeader(AppState state) {
    return Container(
      height: 28,
      color: kBgHeader,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          const Spacer(),
          if (state.isPlaying)
            Text(
                'PLAY · row ${(state.playheadRow + 1).toString().padLeft(2, '0')}',
                style: kStyleHeader.copyWith(color: kColPlayBtn)),
        ],
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
            GestureDetector(
              onTap: () => _startRename(state),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      state.song.name,
                      style: kStyleHeader.copyWith(
                          color: Colors.white70, fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(Icons.edit, size: 11, color: Colors.white38),
                ],
              ),
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
                            horizontal: 8, vertical: 6),
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
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _BigBtn(
                  label: 'SAVE',
                  icon: Icons.save_outlined,
                  onTap: () => _handleSave(ctx, state),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _BigBtn(
                  label: 'LOAD',
                  icon: Icons.folder_open_outlined,
                  onTap: () => _toggleLoadMenu(state),
                ),
              ),
            ],
          ),
          if (_showLoadMenu) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                color: kBgTrackHeader,
                border: Border.all(color: kColInactive.withAlpha(120)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: _loadingSongNames
                  ? Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        'Loading songs...',
                        style: kStyleHeader.copyWith(
                            color: kColInactive, fontSize: 11),
                      ),
                    )
                  : _savedSongNames.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            'No saved songs',
                            style: kStyleHeader.copyWith(
                                color: kColInactive, fontSize: 11),
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: _savedSongNames
                              .map((name) => GestureDetector(
                                    onTap: () => _loadFromName(ctx, state, name),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 7),
                                      child: Text(
                                        name,
                                        style: kStyleHeader.copyWith(
                                            color: kColAccent, fontSize: 12),
                                      ),
                                    ),
                                  ))
                              .toList(),
                        ),
            ),
          ],
        ],
      ),
    );
  }

  void _startRename(AppState state) {
    _nameCtrl.text = state.song.name == 'New Song' ? '' : state.song.name;
    setState(() {
      _editingName = true;
      _showLoadMenu = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nameFocus.requestFocus();
    });
  }

  void _commitRename(AppState state) {
    final value = _nameCtrl.text.trim();
    if (value.isEmpty) return;
    state.renameSong(value);
    if (!mounted) return;
    setState(() => _editingName = false);
  }

  void _cancelRename() {
    if (!mounted) return;
    setState(() => _editingName = false);
  }

  Future<void> _handleSave(BuildContext ctx, AppState state) async {
    if (_editingName) _commitRename(state);
    if (state.song.name == 'New Song') {
      _startRename(state);
      if (!ctx.mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
        content: Text('Name the song first, then press SAVE.'),
        duration: Duration(seconds: 2),
      ));
      return;
    }
    final ok = await state.saveSong();
    if (!ctx.mounted) return;
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
      content: Text(ok ? 'Saved "${state.song.name}".' : 'Save failed.'),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _toggleLoadMenu(AppState state) async {
    if (_showLoadMenu) {
      setState(() => _showLoadMenu = false);
      return;
    }
    setState(() {
      _editingName = false;
      _loadingSongNames = true;
      _showLoadMenu = true;
    });
    final names = await state.listSavedSongs();
    if (!mounted) return;
    setState(() {
      _savedSongNames = names;
      _loadingSongNames = false;
    });
  }

  Future<void> _loadFromName(BuildContext ctx, AppState state, String name) async {
    final ok = await state.loadSongByName(name);
    if (!ctx.mounted) return;
    setState(() => _showLoadMenu = false);
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
      content: Text(ok ? 'Loaded "$name".' : 'Load failed.'),
      duration: const Duration(seconds: 2),
    ));
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
              patterns:    state.song.patterns,
              slotPitch:   slotPitch,
              playheadSlot: state.isPlaying ? state.playheadArrangementSlot : null,
              playheadRow:  state.isPlaying ? state.playheadRow : null,
            ),
            child: SizedBox(
              width: width,
              height: totalH,
            ),
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

/// A slot that holds a real pattern. Long-press draggable; also a drop target.
class _PatternSlot extends StatelessWidget {
  final int    patternIndex; // index in song.patterns
  final bool   isCurrent;
  final double size;
  final double gap;
  final VoidCallback onDragStarted;
  final VoidCallback onDragFinished;

  const _PatternSlot({
    required this.patternIndex,
    required this.isCurrent,
    required this.size,
    required this.gap,
    required this.onDragStarted,
    required this.onDragFinished,
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
          color: kColInactive,
          width: 1,
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
      child: DragTarget<int>(
        onWillAcceptWithDetails: (details) => details.data != patternIndex,
        onAcceptWithDetails: (details) {
          // Drag real → real: move (insert before target).
          state.movePattern(details.data, patternIndex);
        },
        builder: (ctx, candidateData, _) {
          final isHovered = candidateData.isNotEmpty;
          return LongPressDraggable<int>(
            data: patternIndex,
            delay: const Duration(milliseconds: 300),
            onDragStarted: onDragStarted,
            onDragEnd: (_) => onDragFinished(),
            feedback: Material(
              color: Colors.transparent,
              child: Opacity(
                opacity: 0.85,
                child: Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    color: kColAccent.withAlpha(40),
                    border: Border.all(color: kColAccent, width: 1.5),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Center(
                    child: Text(
                      displayLabel,
                      style: kStyleBase.copyWith(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: kColAccent,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            childWhenDragging: Opacity(opacity: 0.3, child: square),
            child: GestureDetector(
              onTap: () => state.selectSongPattern(patternIndex),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  color: isHovered ? kColAccent.withAlpha(25) : Colors.transparent,
                ),
                child: square,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// An empty virtual slot — shows '+' and accepts drag-copy.
class _EmptySlot extends StatelessWidget {
  final int    slotNumber;  // 1-based display number
  final bool   active;      // true = shows '+' and is tappable
  final double gap;
  final VoidCallback? onTap;
  final void Function(int srcPatternIndex) onAcceptDrop;

  const _EmptySlot({
    required this.slotNumber,
    required this.active,
    required this.gap,
    required this.onAcceptDrop,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: gap),
      child: DragTarget<int>(
        onWillAcceptWithDetails: (_) => true,
        onAcceptWithDetails: (details) => onAcceptDrop(details.data),
        builder: (ctx, candidateData, _) {
          final isHovered = candidateData.isNotEmpty;
          return GestureDetector(
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              decoration: BoxDecoration(
                border: Border.all(
                  color: isHovered ? kColAccent : kColInactive,
                  style: BorderStyle.solid,
                ),
                borderRadius: BorderRadius.circular(6),
                color: isHovered ? kColAccent.withAlpha(20) : Colors.transparent,
              ),
              child: active
                  ? Center(
                      child: Icon(
                        Icons.add,
                        color: isHovered ? kColAccent : kColInactive,
                        size: 28,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          );
        },
      ),
    );
  }
}

// ─── Right column timeline ───────────────────────────────────────────────────

class _SongTimelinePainter extends CustomPainter {
  final List<PatternModel> patterns;
  final double             slotPitch;
  final int?               playheadSlot;
  final int?               playheadRow;

  _SongTimelinePainter({
    required this.patterns,
    required this.slotPitch,
    required this.playheadSlot,
    required this.playheadRow,
  });

  static const double _padTop    = 4;
  static const double _padBottom = 4;
  static const double _laneGap   = 1;

  @override
  void paint(Canvas canvas, Size size) {
    final laneCount = kMaxTracks;
    final laneAreaW = size.width - 8;
    final laneW     = (laneAreaW - (laneCount - 1) * _laneGap) / laneCount;
    const originX   = 4.0;

    final dividerPaint = Paint()
      ..color = kColInactive.withAlpha(60)
      ..strokeWidth = 0.5;
    final bgEven = Paint()..color = const Color(0xFF0A0A0A);
    final bgOdd  = Paint()..color = const Color(0xFF050505);

    // Index of the first empty pattern — the "stop marker".
    final firstEmpty = patterns.indexWhere((p) => p.isEmpty);

    for (int s = 0; s < patterns.length; s++) {
      final pat    = patterns[s];
      final yTop   = s * slotPitch + _padTop;
      final blockH = slotPitch - _padTop - _padBottom;
      final isAfterStop = firstEmpty >= 0 && s > firstEmpty;

      canvas.drawRect(
        Rect.fromLTWH(originX, yTop, laneAreaW, blockH),
        s.isEven ? bgEven : bgOdd,
      );

      for (int t = 0; t < laneCount; t++) {
        final lx = originX + t * (laneW + _laneGap);
        canvas.drawRect(
          Rect.fromLTWH(lx, yTop, laneW, blockH),
          Paint()..color = const Color(0xFF111111),
        );
        if (t < pat.tracks.length) {
          _drawLaneNotes(canvas, pat.tracks[t], lx, yTop, laneW, blockH,
              pat.rowCount, isAfterStop);
        }
      }

      // Dim patterns after the stop marker.
      if (isAfterStop) {
        canvas.drawRect(
          Rect.fromLTWH(originX, yTop, laneAreaW, blockH),
          Paint()..color = const Color(0x55000000),
        );
      }

      canvas.drawLine(
        Offset(0,          yTop + blockH + _padBottom - 0.5),
        Offset(size.width, yTop + blockH + _padBottom - 0.5),
        dividerPaint,
      );
    }

    // Playhead line.
    if (playheadSlot != null && playheadRow != null) {
      final s = playheadSlot!.clamp(0, patterns.length - 1);
      if (s < patterns.length) {
        final pat    = patterns[s];
        final yTop   = s * slotPitch + _padTop;
        final blockH = slotPitch - _padTop - _padBottom;
        final y      = yTop + (playheadRow! / pat.rowCount) * blockH;
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

  void _drawLaneNotes(Canvas canvas, TrackModel track,
      double x, double y, double w, double h, int rowCount, bool dimmed) {
    final paint    = Paint();
    final pxPerRow = h / rowCount;
    for (int r = 0; r < track.cells.length && r < rowCount; r++) {
      final n = track.cells[r].note;
      if (n.isEmpty) continue;
      final dotY = y + r * pxPerRow;
      final dotH = pxPerRow.clamp(1.0, 3.0);
      paint.color = dimmed
          ? kColInactive.withAlpha(50)
          : n == NoteValue.off
              ? kColInactive
              : kColNote;
      canvas.drawRect(Rect.fromLTWH(x + 1, dotY, w - 2, dotH), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SongTimelinePainter old) =>
      old.patterns != patterns ||
      old.playheadSlot != playheadSlot ||
      old.playheadRow != playheadRow;
}

// ─── Header button ────────────────────────────────────────────────────────────

class _BigBtn extends StatelessWidget {
  final String   label;
  final IconData icon;
  final VoidCallback onTap;

  const _BigBtn({required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: kColAccent.withOpacity(0.12),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: kColAccent.withOpacity(0.5), width: 1),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: kColAccent),
            const SizedBox(width: 5),
            Text(label,
                style: kStyleHeader.copyWith(color: kColAccent, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
