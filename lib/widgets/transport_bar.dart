import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// Global bottom bar: Play/Stop toggle | BPM | BEATS | LPB.
class TransportBar extends StatefulWidget {
  final Future<void> Function()? onPlay;

  const TransportBar({super.key, this.onPlay});

  @override
  State<TransportBar> createState() => _TransportBarState();
}

class _TransportBarState extends State<TransportBar> {
  AppState? _state;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppStateScope.of(context);
    if (identical(state, _state)) return;
    _state?.playbackError.removeListener(_showPlaybackError);
    _state = state;
    state.playbackError.addListener(_showPlaybackError);
  }

  void _showPlaybackError() {
    final error = _state?.playbackError.value;
    if (!mounted ||
        error == null ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  Future<void> _play(AppState state) async {
    try {
      await (widget.onPlay ?? state.play)();
    } on StateError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message.toString())));
      }
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message ?? error.code)));
      }
    } on MissingPluginException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  @override
  void dispose() {
    _state?.playbackError.removeListener(_showPlaybackError);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final running = state.isPlaying || state.songPlanStarting;

    return Container(
      height: 76,
      color: kBgTrackHeader,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          _TransportButton(
            icon: running ? Icons.stop : Icons.play_arrow,
            color: running ? kColStopBtn : kColPlayBtn,
            label: running ? 'STOP' : 'PLAY',
            onTap: running ? state.stop : () => _play(state),
          ),
          const SizedBox(width: 8),
          _TransportButton(
            icon: Icons.repeat,
            color: state.loopPlaybackEnabled ? kColAccent : kColInactive,
            label: 'LOOP',
            pressed: state.loopPlaybackEnabled,
            onTap: () =>
                state.setLoopPlaybackEnabled(!state.loopPlaybackEnabled),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
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
                  enabled: state.canChangeBeats,
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

  void _applyDragDelta(Offset delta) {
    // Vertical up increases value, horizontal right increases value.
    final useHorizontal = delta.dx.abs() >= delta.dy.abs();
    final signedDelta = useHorizontal ? delta.dx : -delta.dy;
    _dragAccum += signedDelta;

    final steps = (_dragAccum / _pixelsPerStep).truncate();
    if (steps != 0) {
      _dragAccum -= steps * _pixelsPerStep;
      widget.onStep(steps);
    }
  }

  @override
  Widget build(BuildContext context) {
    final valueColor = widget.enabled ? kColAccent : kColInactive;
    final labelColor = widget.enabled ? kColHeader : kColInactive;

    return GestureDetector(
      behavior: widget.enabled
          ? HitTestBehavior.opaque
          : HitTestBehavior.deferToChild,
      onPanStart: widget.enabled ? (_) => _dragAccum = 0 : null,
      onPanUpdate: widget.enabled ? (d) => _applyDragDelta(d.delta) : null,
      child: SizedBox(
        width: 56,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              widget.label,
              style: kStyleHeader.copyWith(fontSize: 14, color: labelColor),
            ),
            Text(
              widget.value,
              style: kStyleLabel.copyWith(fontSize: 22, color: valueColor),
            ),
          ],
        ),
      ),
    );
  }
}

class _TransportButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final bool pressed;
  final VoidCallback onTap;

  const _TransportButton({
    required this.icon,
    required this.color,
    required this.label,
    this.pressed = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 60,
        decoration: BoxDecoration(
          color: pressed ? color.withAlpha(28) : Colors.transparent,
          border: Border.all(
            color: pressed ? color : Colors.transparent,
            width: 1,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 38),
            const SizedBox(height: 2),
            Text(
              label,
              style: kStyleHeader.copyWith(color: color, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
