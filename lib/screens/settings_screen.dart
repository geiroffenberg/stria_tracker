import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// Settings screen.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('SETTINGS', style: kStyleLabel),
        const SizedBox(height: 24),

        // BPM
        _SettingsRow(
          label: 'BPM',
          child: Row(
            children: [
              _StepBtn('-', () => state.setBpm(state.bpm - 1)),
              const SizedBox(width: 8),
              Text(
                state.bpm.toStringAsFixed(0),
                style: kStyleNote.copyWith(fontSize: 14),
              ),
              const SizedBox(width: 8),
              _StepBtn('+', () => state.setBpm(state.bpm + 1)),
            ],
          ),
        ),

        const SizedBox(height: 12),
        const Divider(color: Color(0xFF1A1A1A)),
        const SizedBox(height: 12),

        // Pattern info
        _SettingsRow(
          label: 'ROWS / PATTERN',
          child: Text(
            state.rowCount.toString(),
            style: kStyleNote.copyWith(fontSize: 14),
          ),
        ),
        _SettingsRow(
          label: 'BEATS',
          child: Text(
            state.beats.toString().padLeft(2, '0'),
            style: kStyleNote.copyWith(fontSize: 14),
          ),
        ),
        _SettingsRow(
          label: 'LINES / BEAT',
          child: Text(
            state.linesPerBeat.toString().padLeft(2, '0'),
            style: kStyleNote.copyWith(fontSize: 14),
          ),
        ),
        _SettingsRow(
          label: 'TRACKS',
          child: Text(
            state.trackCount.toString(),
            style: kStyleNote.copyWith(fontSize: 14),
          ),
        ),
      ],
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final String label;
  final Widget child;
  const _SettingsRow({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: kStyleBase.copyWith(color: kColHeader)),
          child,
        ],
      ),
    );
  }
}

class _StepBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _StepBtn(this.label, this.onTap);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28, height: 28,
        decoration: BoxDecoration(
          border: Border.all(color: kColInactive),
          borderRadius: BorderRadius.circular(3),
        ),
        alignment: Alignment.center,
        child: Text(label, style: kStyleNote.copyWith(fontSize: 16)),
      ),
    );
  }
}
