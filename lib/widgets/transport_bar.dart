import 'package:flutter/material.dart';
import '../screens/settings_screen.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// Global bottom bar: Play | Stop | … | BPM | Settings.
class TransportBar extends StatelessWidget {
  const TransportBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return Container(
      height: 76,
      color:  kBgTrackHeader,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _TransportButton(
            icon:  Icons.play_arrow,
            color: state.isPlaying ? kColPlayBtn : kColInactive,
            label: 'PLAY',
            onTap: () => state.play(),
          ),
          const SizedBox(width: 20),
          _TransportButton(
            icon:  Icons.stop,
            color: kColStopBtn,
            label: 'STOP',
            onTap: () => state.stop(),
          ),
          const Spacer(),
          // BPM — vertical drag to adjust
          GestureDetector(
            onVerticalDragUpdate: (d) {
              state.setBpm(state.bpm - d.delta.dy * 0.5);
            },
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('BPM',
                    style: kStyleHeader.copyWith(fontSize: 12)),
                Text(
                  state.bpm.toStringAsFixed(1),
                  style: kStyleLabel.copyWith(
                      fontSize: 22, color: kColAccent),
                ),
              ],
            ),
          ),
          const SizedBox(width: 24),
          _TransportButton(
            icon:  Icons.settings,
            color: kColAccent,
            label: 'SETTINGS',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
    );
  }
}

class _TransportButton extends StatelessWidget {
  final IconData icon;
  final Color    color;
  final String   label;
  final VoidCallback onTap;

  const _TransportButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 64,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 36),
            const SizedBox(height: 2),
            Text(label,
                style: kStyleHeader.copyWith(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
