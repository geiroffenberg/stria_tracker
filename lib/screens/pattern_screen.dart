import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/track_page_widget.dart';
import '../widgets/collapsed_tracks_widget.dart';

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

    return Column(
      children: [
        _buildTrackHeader(context, state),
        Expanded(
          child: state.collapsedView
              ? const CollapsedTracksWidget()
              : PageView.builder(
                  controller:    _pageCtrl,
                  itemCount:     state.trackCount,
                  physics:       const PageScrollPhysics(),
                  onPageChanged: (i) => state.selectTrack(i),
                  itemBuilder:   (_, i) {
                    final track = state.currentPattern.tracks[i];
                    return TrackPageWidget(track: track, trackIndex: i);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildTrackHeader(BuildContext context, AppState state) {
    final track    = state.currentTrack;
    final trackIdx = state.currentTrackIndex;
    final total    = state.trackCount;
    final pat      = state.currentPattern;

    return Container(
      height: 44,
      color:  kBgTrackHeader,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Text(pat.name,
              style: kStyleBase.copyWith(color: kColHeader, fontSize: 12)),
          const SizedBox(width: 8),
          const Text('│', style: TextStyle(color: Color(0xFF333333))),
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
                  '${track.name}  ${(trackIdx + 1).toString().padLeft(2, '0')}/$total',
                  style: kStyleLabel.copyWith(fontSize: 13),
                ),
              ),
            ),
            _NavBtn(
              icon: Icons.chevron_right,
              onTap: () => _goToTrack(state, trackIdx + 1),
              enabled: trackIdx < total - 1,
            ),
          ] else ...[
            Expanded(
              child: Text(
                'ALL TRACKS  ($total)',
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
                color:  state.collapsedView
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
                  color:    state.collapsedView ? kColActive : kColHeader,
                ),
              ),
            ),
          ),
        ],
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
      child: Icon(
        icon,
        color: enabled ? kColAccent : kColInactive,
        size: 26,
      ),
    );
  }
}
