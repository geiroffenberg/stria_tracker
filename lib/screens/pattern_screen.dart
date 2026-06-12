import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/track_page_widget.dart';
import '../widgets/collapsed_tracks_widget.dart';
import '../widgets/cell_action_bar.dart';

/// The main pattern editor screen.
///
/// Modes:
///   • Expanded (collapsedView=false): single-track PageView, swipe to
///     change tracks, full column set visible.
///   • Collapsed (collapsedView=true): all tracks visible side-by-side,
///     each showing only NOTE + INST.
class PatternScreen extends StatefulWidget {
  const PatternScreen({super.key});

  @override
  State<PatternScreen> createState() => _PatternScreenState();
}

class _PatternScreenState extends State<PatternScreen> {
  late PageController _pageCtrl;

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  void _goToTrack(AppState state, int index) {
    final clamped = index.clamp(0, state.trackCount - 1);
    state.selectTrack(clamped);
    if (_pageCtrl.hasClients) {
      _pageCtrl.animateToPage(
        clamped,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    // Keep the visible page aligned when pattern/track is selected externally
    // (for example from Song timeline lane taps).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || state.collapsedView || !_pageCtrl.hasClients) return;
      final currentPage = (_pageCtrl.page ?? _pageCtrl.initialPage.toDouble()).round();
      if (currentPage != state.currentTrackIndex) {
        _pageCtrl.jumpToPage(state.currentTrackIndex);
      }
    });

    return Column(
      children: [
        _buildTrackHeader(context, state),
        Expanded(
          child: state.collapsedView
              ? const CollapsedTracksWidget()
              : PageView.builder(
                  key: ValueKey<int>(state.currentPatternIndex),
                  controller: _pageCtrl,
                  itemCount: state.trackCount,
                  physics: state.isBoxSelecting || state.hasBoxSelection
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                  onPageChanged: (i) => state.selectTrack(i),
                  itemBuilder: (_, i) {
                    final track = state.currentPattern.tracks[i];
                    return TrackPageWidget(track: track, trackIndex: i);
                  },
                ),
        ),
        Container(
          height: 1,
          color: const Color(0xFF226666),
        ),
        const CellActionBar(),
      ],
    );
  }

  Widget _buildTrackHeader(BuildContext context, AppState state) {
    final trackIdx = state.currentTrackIndex;
    final pat = state.currentPattern;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
      Container(
      height: 28,
      color: kBgTrackHeader,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          _PatternMenuButton(state: state, patternName: pat.name),
          const SizedBox(width: 8),
          Text('│', style: TextStyle(color: kColInactive)),
          const SizedBox(width: 8),
          if (!state.collapsedView) ...[
            _NavBtn(
              icon: Icons.chevron_left,
              onTap: () => _goToTrack(state, trackIdx - 1),
              enabled: trackIdx > 0,
            ),
            SizedBox(
              width: 110,
              child: Center(
                child: Text(
                  'TRACK ${(trackIdx + 1).toString().padLeft(2, '0')}',
                  style: kStyleLabel.copyWith(fontSize: 13),
                ),
              ),
            ),
            _NavBtn(
              icon: Icons.chevron_right,
              onTap: () => _goToTrack(state, trackIdx + 1),
              enabled: trackIdx < state.trackCount - 1,
            ),
            const SizedBox(width: 8),
            _SoloBtn(
              soloed: state.currentPattern.tracks[trackIdx].mixerSolo,
              onTap: () => state.toggleTrackMixerSolo(trackIdx),
            ),
          ] else ...[
            Expanded(
              child: Text(
                'ALL TRACKS',
                style: kStyleLabel.copyWith(fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          ],
          const Spacer(),
          // Global collapse toggle
          GestureDetector(
            onTap: () {
              state.toggleCollapsedView();
              // When returning to expanded view, sync the PageView.
              if (!state.collapsedView) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_pageCtrl.hasClients) {
                    _pageCtrl.jumpToPage(state.currentTrackIndex);
                  }
                });
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: state.collapsedView
                    ? kColActive.withAlpha(50)
                    : Colors.transparent,
                border: Border.all(
                  color: state.collapsedView ? kColActive : kColInactive,
                ),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                state.collapsedView ? 'EXPAND' : 'COLLAPSE',
                style: kStyleBase.copyWith(
                  fontSize: 11,
                  color: state.collapsedView ? kColActive : kColHeader,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
      Container(height: 1, color: kColActive.withAlpha(160)),
    ],
    );
  }
}

class _SoloBtn extends StatelessWidget {
  final bool soloed;
  final VoidCallback onTap;

  const _SoloBtn({required this.soloed, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: soloed ? kColStopBtn.withAlpha(40) : Colors.transparent,
          border: Border.all(
            color: soloed ? kColStopBtn : kColInactive,
            width: 1,
          ),
          borderRadius: BorderRadius.circular(3),
        ),
        alignment: Alignment.center,
        child: Text(
          'S',
          style: kStyleBase.copyWith(
            fontSize: 12,
            color: soloed ? kColStopBtn : kColInactive,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _NavBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool enabled;

  const _NavBtn({
    required this.icon,
    required this.onTap,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Icon(icon, color: enabled ? kColAccent : kColInactive, size: 26),
    );
  }
}

/// Tappable pattern name in the track header. Opens a popup menu with
/// undo / redo / clear / reset actions scoped to the current pattern.
class _PatternMenuButton extends StatelessWidget {
  final AppState state;
  final String patternName;

  const _PatternMenuButton({required this.state, required this.patternName});

  Future<void> _openMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final origin = box.localToGlobal(Offset(0, box.size.height),
        ancestor: overlay);
    final position = RelativeRect.fromLTRB(
      origin.dx,
      origin.dy,
      overlay.size.width - origin.dx - 220,
      0,
    );

    final result = await showMenu<String>(
      context: context,
      position: position,
      color: kBgTrackHeader,
      items: [
        PopupMenuItem<String>(
          value: 'undo',
          enabled: state.canUndoPattern,
          child: Row(children: [
            Icon(Icons.undo, size: 18,
                color: state.canUndoPattern ? kColAccent : kColInactive),
            const SizedBox(width: 10),
            Text('Undo',
                style: kStyleBase.copyWith(
                  fontSize: 14,
                  color: state.canUndoPattern ? kColHeader : kColInactive,
                )),
          ]),
        ),
        PopupMenuItem<String>(
          value: 'redo',
          enabled: state.canRedoPattern,
          child: Row(children: [
            Icon(Icons.redo, size: 18,
                color: state.canRedoPattern ? kColAccent : kColInactive),
            const SizedBox(width: 10),
            Text('Redo',
                style: kStyleBase.copyWith(
                  fontSize: 14,
                  color: state.canRedoPattern ? kColHeader : kColInactive,
                )),
          ]),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'clear',
          child: Row(children: [
            Icon(Icons.cleaning_services_outlined,
                size: 18, color: kColHeader),
            const SizedBox(width: 10),
            Text('Clear pattern',
                style: kStyleBase.copyWith(
                    fontSize: 14, color: kColHeader)),
          ]),
        ),
        PopupMenuItem<String>(
          value: 'reset',
          child: Row(children: [
            Icon(Icons.restart_alt, size: 18, color: kColHeader),
            const SizedBox(width: 10),
            Text('Reset to defaults',
                style: kStyleBase.copyWith(
                    fontSize: 14, color: kColHeader)),
          ]),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'swing',
          child: Row(children: [
            Icon(Icons.swap_horiz, size: 18, color: kColHeader),
            const SizedBox(width: 10),
            Text(
              state.currentPatternSwing == 0.0
                  ? 'Swing: off'
                  : 'Swing: ${state.currentPatternSwing.round()}%',
              style: kStyleBase.copyWith(fontSize: 14, color: kColHeader),
            ),
          ]),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'freeze',
          child: Row(children: [
            Icon(Icons.merge_type, size: 18, color: kColHeader),
            const SizedBox(width: 10),
            Text('Copy to Sampler',
                style: kStyleBase.copyWith(fontSize: 14, color: kColHeader)),
          ]),
        ),
      ],
    );

    if (!context.mounted || result == null) return;
    switch (result) {
      case 'undo':
        state.undoCurrentPattern();
        break;
      case 'redo':
        state.redoCurrentPattern();
        break;
      case 'clear':
        final confirm = await _confirm(
          context,
          title: 'Clear pattern?',
          body: 'Erase every cell on every track in this pattern.\n'
              'Beats, lines-per-beat and mixer settings stay as they are.\n'
              'You can undo this.',
          confirmLabel: 'CLEAR',
        );
        if (confirm == true) state.clearCurrentPatternCells();
        break;
      case 'reset':
        final confirm = await _confirm(
          context,
          title: 'Reset to defaults?',
          body: 'Erase every cell AND reset BPM, beats and lines-per-beat '
              'back to their defaults. Mixer settings on the tracks are '
              'kept. You can undo this.',
          confirmLabel: 'RESET',
        );
        if (confirm == true) state.resetCurrentPatternToDefaults();
        break;
      case 'swing':
        if (context.mounted) await _showSwingDialog(context);
        break;
      case 'freeze':
        if (!context.mounted) break;
        // Show a non-dismissible progress indicator while the engine renders.
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            backgroundColor: kBgTrackHeader,
            content: Row(children: [
              CircularProgressIndicator(color: kColAccent),
              const SizedBox(width: 20),
              Text('Rendering…',
                  style: kStyleBase.copyWith(color: kColHeader)),
            ]),
          ),
        );
        final err = await state.freezePatternToSampler();
        if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
        if (context.mounted) {
          final slotNum = state.currentInstrumentIndex + 1;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
              err == null
                  ? 'Loaded into instrument slot $slotNum'
                  : 'Failed: $err',
            ),
            duration: const Duration(seconds: 4),
          ));
        }
        break;
    }
  }

  Future<void> _showSwingDialog(BuildContext context) {
    double tempSwing = state.currentPatternSwing;
    return showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          backgroundColor: kBgTrackHeader,
          title: Text('Swing',
              style: kStyleBase.copyWith(color: kColHeader, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tempSwing == 0.0
                    ? 'Off (straight)'
                    : '${tempSwing.round()}%',
                style: kStyleBase.copyWith(
                  color: kColAccent, fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Slider(
                min: 0.0,
                max: 99.0,
                divisions: 99,
                value: tempSwing,
                activeColor: kColAccent,
                inactiveColor: kColInactive,
                onChanged: (v) => setState(() => tempSwing = v),
              ),
              Text(
                'Delays even-numbered lines within each beat.\n'
                '0 = straight, 99% = near-maximum shuffle.',
                textAlign: TextAlign.center,
                style: kStyleBase.copyWith(
                    color: kColInactive, fontSize: 11),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('CANCEL',
                  style: kStyleBase.copyWith(color: kColInactive)),
            ),
            TextButton(
              onPressed: () {
                state.setPatternSwing(tempSwing);
                Navigator.of(ctx).pop();
              },
              child: Text('OK',
                  style: kStyleBase.copyWith(color: kColAccent)),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required String confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgTrackHeader,
        title: Text(title,
            style: kStyleBase.copyWith(color: kColHeader, fontSize: 16)),
        content: Text(body,
            style: kStyleBase.copyWith(color: kColHeader, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('CANCEL',
                style: kStyleBase.copyWith(color: kColInactive)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel,
                style: kStyleBase.copyWith(color: kColAccent)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openMenu(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              patternName,
              style: kStyleBase.copyWith(color: kColHeader, fontSize: 14),
            ),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down, size: 18, color: kColAccent),
          ],
        ),
      ),
    );
  }
}
