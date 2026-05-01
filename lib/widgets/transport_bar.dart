import 'package:flutter/material.dart';
import '../screens/settings_screen.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// Global bottom bar: Play/Stop toggle | BPM | BEATS | LPB | Settings.
class TransportBar extends StatelessWidget {
  const TransportBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return Container(
      height: 76,
      color:  kBgTrackHeader,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          _TransportButton(
            icon: state.isPlaying ? Icons.stop : Icons.play_arrow,
            color: state.isPlaying ? kColStopBtn : kColPlayBtn,
            label: state.isPlaying ? 'STOP' : 'PLAY',
            onTap: state.isPlaying ? state.stop : state.play,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _TransportValueControl(
                  label: 'BPM',
                  value: state.bpm.toStringAsFixed(0),
                  onStep: (steps) => state.setBpm(state.bpm + steps),
                ),
                const SizedBox(width: 12),
                _TransportValueControl(
                  label: 'BEATS',
                  value: state.beats.toString().padLeft(2, '0'),
                  enabled: state.canChangePatternLength,
                  onStep: (steps) => state.setBeats(state.beats + steps),
                ),
                const SizedBox(width: 12),
                _TransportValueControl(
                  label: 'LPB',
                  value: state.linesPerBeat.toString().padLeft(2, '0'),
                  enabled: state.canChangePatternLength,
                  onStep: (steps) =>
                      state.setLinesPerBeat(state.linesPerBeat + steps),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
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

class _TransportValueControl extends StatefulWidget {
  final String label;
  final String value;
  final ValueChanged<int> onStep;
  final bool enabled;

  const _TransportValueControl({
    required this.label,
    required this.value,
    required this.onStep,
    this.enabled = true,
  });

  @override
  State<_TransportValueControl> createState() => _TransportValueControlState();
}

class _TransportValueControlState extends State<_TransportValueControl> {
  static const double _pixelsPerStep = 10.0;
  double _dragAccum = 0;

  @override
  Widget build(BuildContext context) {
    final valueColor = widget.enabled ? kColAccent : kColInactive;
    final labelColor = widget.enabled ? kColHeader : kColInactive;

    return GestureDetector(
      behavior: widget.enabled ? HitTestBehavior.opaque : HitTestBehavior.deferToChild,
      onVerticalDragStart: widget.enabled ? (_) => _dragAccum = 0 : null,
      onVerticalDragUpdate: widget.enabled ? (d) {
        _dragAccum -= d.delta.dy;
        final steps = (_dragAccum / _pixelsPerStep).truncate();
        if (steps != 0) {
          _dragAccum -= steps * _pixelsPerStep;
          widget.onStep(steps);
        }
      } : null,
      child: SizedBox(
        width: 56,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              widget.label,
              style: kStyleHeader.copyWith(fontSize: 11, color: labelColor),
            ),
            Text(
              widget.value,
              style: kStyleLabel.copyWith(fontSize: 18, color: valueColor),
            ),
          ],
        ),
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
        width: 60,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 34),
            const SizedBox(height: 2),
            Text(label,
                style: kStyleHeader.copyWith(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
