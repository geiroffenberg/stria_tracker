import 'package:flutter/material.dart';

import '../models/song_model.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// Read-only projection of sequential song playback, not a playback controller.
class SongPlanScreen extends StatelessWidget {
  const SongPlanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final patterns = state.song.patterns;
    var endSlot = kMaxSongPatterns;
    for (var i = 0; i < kMaxSongPatterns; i++) {
      if (i >= patterns.length || patterns[i].isEmpty) {
        endSlot = i;
        break;
      }
    }

    return Scaffold(
      backgroundColor: kBgColor,
      appBar: AppBar(
        backgroundColor: kBgTopNav,
        foregroundColor: kColAccent,
        title: Text('Song Plan', style: kStyleHeader),
      ),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'DEFAULT / SEQUENTIAL',
                      style: kStyleHeader.copyWith(color: kColAccent),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Read-only preview. Each song row plays once, in order. '
                      'The first empty song row ends the sequence. '
                      'Playback and mixer settings are unchanged.',
                      style: kStyleBase.copyWith(color: kColHeader),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      state.loopPlaybackEnabled
                          ? 'Loop ON: playback returns to the existing loop start.'
                          : 'Loop OFF: playback stops at the end of the sequence.',
                      style: kStyleBase.copyWith(color: kColAccent),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Container(
                color: kBgHeader,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 12,
                ),
                child: _cells(
                  ['STEP', 'SONG', 'LINES', 'REPEAT', 'NEXT'],
                  kColHeader,
                  header: true,
                ),
              ),
            ),
            SliverList.builder(
              itemCount: kMaxSongPatterns,
              itemBuilder: (context, index) {
                final isEnd = index == endSlot;
                final isUnreachable = index > endSlot;
                final number = (index + 1).toString().padLeft(2, '0');
                final color = isUnreachable
                    ? kColInactive
                    : isEnd
                    ? kColAccent
                    : kColHeader;
                return Container(
                  key: ValueKey('song-plan-step-$number'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: isEnd
                        ? kBgSelected
                        : index.isEven
                        ? kBgBeat
                        : kBgColor,
                    border: Border(bottom: BorderSide(color: kBgHeader)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _cells([
                        number,
                        number,
                        'ALL',
                        '1',
                        isEnd || index == kMaxSongPatterns - 1 ? 'END' : 'NEXT',
                      ], color),
                      if (isEnd)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'End of song - empty song row',
                            textAlign: TextAlign.center,
                            style: kStyleBase.copyWith(color: kColAccent),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _cells(List<String> values, Color color, {bool header = false}) {
    return Row(
      children: [
        for (final value in values)
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.center,
              style: (header ? kStyleHeader : kStyleBase).copyWith(
                color: color,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }
}
