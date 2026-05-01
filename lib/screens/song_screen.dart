import 'package:flutter/material.dart';
import '../models/note_value.dart';
import '../models/pattern_model.dart';
import '../models/track_model.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

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
  bool _syncing = false;

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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final slotPitch  = kSlotSize + kSlotGap;

    return Container(
      color: kBgColor,
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
                    itemCount: state.song.arrangement.length + 1,
                    itemBuilder: (_, i) {
                      if (i == state.song.arrangement.length) {
                        return _AddSlotButton(state: state);
                      }
                      return _PatternSlot(
                        slotIndex: i,
                        patternIndex: state.song.arrangement[i],
                        muted: state.song.arrangementMutes[i],
                        isCurrent: i == state.currentArrangementSlotIndex,
                        size: kSlotSize,
                        gap:  kSlotGap,
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
    );
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
            Text('PLAY · row ${(state.playheadRow + 1).toString().padLeft(2, '0')}',
                style: kStyleHeader.copyWith(color: kColPlayBtn)),
        ],
      ),
    );
  }

  Widget _buildTimeline(AppState state, double slotPitch) {
    // Total drawing area must align each slot to slotPitch so it lines up
    // with the slot squares on the left (centred vertically inside slot).
    final totalH = state.song.arrangement.length * slotPitch;

    return CustomPaint(
      size: Size.fromHeight(totalH),
      painter: _SongTimelinePainter(
        arrangement: state.song.arrangement,
        mutes:       state.song.arrangementMutes,
        patterns:    state.song.patterns,
        slotPitch:   slotPitch,
        playheadSlot: state.isPlaying ? state.playheadArrangementSlot : null,
        playheadRow:  state.isPlaying ? state.playheadRow : null,
      ),
      child: SizedBox(
        width: double.infinity,
        height: totalH,
      ),
    );
  }
}

// ─── Left column widgets ─────────────────────────────────────────────────────

class _PatternSlot extends StatelessWidget {
  final int  slotIndex;
  final int  patternIndex;
  final bool muted;
  final bool isCurrent;
  final double size;
  final double gap;

  const _PatternSlot({
    required this.slotIndex,
    required this.patternIndex,
    required this.muted,
    required this.isCurrent,
    required this.size,
    required this.gap,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: gap),
      child: GestureDetector(
        onTap:       () => state.selectArrangementSlot(slotIndex),
        onLongPress: () => _showSlotMenu(context, state),
        child: Container(
          width: size, height: size,
          decoration: BoxDecoration(
            color: muted
                ? const Color(0xFF110000)
                : isCurrent
                    ? kColAccent.withAlpha(30)
                    : kBgTrackHeader,
            border: Border.all(
              color: muted
                  ? kColRecBtn
                  : isCurrent ? kColAccent : kColInactive,
              width: isCurrent ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Stack(
            children: [
              Center(
                child: Text(
                  (patternIndex + 1).toString().padLeft(2, '0'),
                  style: kStyleBase.copyWith(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: muted
                        ? kColRecBtn
                        : isCurrent ? kColAccent : kColHeader,
                    letterSpacing: 1,
                  ),
                ),
              ),
              if (muted)
                Positioned(
                  bottom: 2, right: 4,
                  child: Text('M',
                      style: kStyleBase.copyWith(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: kColRecBtn,
                      )),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSlotMenu(BuildContext context, AppState state) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBgTrackHeader,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'SLOT #${(slotIndex + 1).toString().padLeft(2, '0')}  '
                '— PATTERN ${(patternIndex + 1).toString().padLeft(2, '0')}',
                style: kStyleHeader.copyWith(color: kColAccent),
              ),
            ),
            const Divider(height: 1, color: Color(0xFF1A1A1A)),
            _menuRow(ctx, muted ? 'UNMUTE' : 'MUTE', Icons.volume_off, () {
              state.toggleArrangementMute(slotIndex);
              Navigator.pop(ctx);
            }),
            _menuRow(
              ctx,
              'DUPLICATE',
              Icons.content_copy,
              () {
                state.duplicatePatternToEnd(patternIndex);
                Navigator.pop(ctx);
              },
              subtitle: 'New pattern (next number) at end of list',
            ),
            _menuRow(
              ctx,
              'REPEAT',
              Icons.repeat,
              () {
                state.repeatPatternAtEnd(patternIndex);
                Navigator.pop(ctx);
              },
              subtitle: 'Same pattern at end of list (edits affect all)',
            ),
            _menuRow(ctx, 'MOVE UP', Icons.arrow_upward, () {
              state.moveArrangementSlot(slotIndex, slotIndex - 1);
              Navigator.pop(ctx);
            }),
            _menuRow(ctx, 'MOVE DOWN', Icons.arrow_downward, () {
              state.moveArrangementSlot(slotIndex, slotIndex + 1);
              Navigator.pop(ctx);
            }),
            const Divider(height: 1, color: Color(0xFF1A1A1A)),
            _menuRow(ctx, 'DELETE SLOT', Icons.delete_outline, () {
              state.removeArrangementSlot(slotIndex);
              Navigator.pop(ctx);
            }, color: kColRecBtn),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _menuRow(BuildContext ctx, String label, IconData icon,
      VoidCallback onTap,
      {Color? color, String? subtitle}) {
    final c = color ?? kColHeader;
    return ListTile(
      dense: true,
      leading: Icon(icon, color: c, size: 20),
      title: Text(label,
          style: kStyleBase.copyWith(fontSize: 14, color: c)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle,
              style: kStyleBase.copyWith(
                  fontSize: 11, color: kColInactive)),
      onTap: onTap,
    );
  }
}

class _AddSlotButton extends StatelessWidget {
  final AppState state;
  const _AddSlotButton({required this.state});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: _SongScreenState.kSlotGap),
      child: GestureDetector(
        onTap: () => state.appendNewPattern(),
        child: Container(
          width:  _SongScreenState.kSlotSize,
          height: _SongScreenState.kSlotSize,
          decoration: BoxDecoration(
            border: Border.all(
              color: kColInactive,
              style: BorderStyle.solid,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Center(
            child: Icon(Icons.add, color: kColInactive, size: 28),
          ),
        ),
      ),
    );
  }
}

// ─── Right column timeline ───────────────────────────────────────────────────

class _SongTimelinePainter extends CustomPainter {
  final List<int>          arrangement;
  final List<bool>         mutes;
  final List<PatternModel> patterns;
  final double             slotPitch;
  final int?               playheadSlot;
  final int?               playheadRow;

  _SongTimelinePainter({
    required this.arrangement,
    required this.mutes,
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
    final laneCount  = kMaxTracks;
    final laneAreaW  = size.width - 8;
    final laneW      = (laneAreaW - (laneCount - 1) * _laneGap) / laneCount;
    final originX    = 4.0;

    final dividerPaint = Paint()
      ..color = kColInactive.withAlpha(60)
      ..strokeWidth = 0.5;
    final patternBgEven = Paint()..color = const Color(0xFF0A0A0A);
    final patternBgOdd  = Paint()..color = const Color(0xFF050505);
    final mutedOverlay  = Paint()..color = const Color(0x66220000);

    for (int s = 0; s < arrangement.length; s++) {
      final patIdx = arrangement[s];
      if (patIdx < 0 || patIdx >= patterns.length) continue;
      final pat = patterns[patIdx];
      final rowCount = pat.rowCount;

      final yTop = s * slotPitch + _padTop;
      final blockH = slotPitch - _padTop - _padBottom;

      // Pattern background
      canvas.drawRect(
        Rect.fromLTWH(originX, yTop, laneAreaW, blockH),
        s.isEven ? patternBgEven : patternBgOdd,
      );

      // Per-track lanes
      final tracks = pat.tracks;
      for (int t = 0; t < laneCount; t++) {
        final lx = originX + t * (laneW + _laneGap);
        // lane background
        canvas.drawRect(
          Rect.fromLTWH(lx, yTop, laneW, blockH),
          Paint()..color = const Color(0xFF111111),
        );

        if (t < tracks.length) {
          _drawLaneNotes(canvas, tracks[t], lx, yTop, laneW, blockH, rowCount);
        }
      }

      // Mute overlay
      if (s < mutes.length && mutes[s]) {
        canvas.drawRect(
          Rect.fromLTWH(originX, yTop, laneAreaW, blockH),
          mutedOverlay,
        );
      }

      // Bottom divider between slots
      canvas.drawLine(
        Offset(0,         yTop + blockH + _padBottom - 0.5),
        Offset(size.width, yTop + blockH + _padBottom - 0.5),
        dividerPaint,
      );
    }

    // Playhead
    if (playheadSlot != null && playheadRow != null) {
      final s = playheadSlot!.clamp(0, arrangement.length - 1);
      if (s >= 0 && s < arrangement.length) {
        final patIdx = arrangement[s];
        if (patIdx < 0 || patIdx >= patterns.length) return;
        final pat = patterns[patIdx];
        final yTop = s * slotPitch + _padTop;
        final blockH = slotPitch - _padTop - _padBottom;
        final y = yTop +
            (playheadRow! / pat.rowCount) * blockH;
        final p = Paint()
          ..color = kColPlayBtn
          ..strokeWidth = 1.5;
        canvas.drawLine(
          Offset(0, y),
          Offset(size.width, y),
          p,
        );
      }
    }
  }

  void _drawLaneNotes(Canvas canvas, TrackModel track,
      double x, double y, double w, double h, int rowCount) {
    final paint = Paint()..color = kColNote;
    final pxPerRow = h / rowCount;
    for (int r = 0; r < track.cells.length && r < rowCount; r++) {
      final cell = track.cells[r];
      final n = cell.note;
      if (n.isEmpty) continue;
      final dotY = y + r * pxPerRow;
      final dotH = pxPerRow.clamp(1.0, 3.0);
      paint.color = n == NoteValue.off
          ? kColInactive
          : kColNote;
      canvas.drawRect(
        Rect.fromLTWH(x + 1, dotY, w - 2, dotH),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SongTimelinePainter old) {
    return old.arrangement != arrangement ||
           old.mutes != mutes ||
           old.patterns != patterns ||
           old.playheadSlot != playheadSlot ||
           old.playheadRow != playheadRow;
  }
}
