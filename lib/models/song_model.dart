import 'pattern_model.dart';
import 'song_plan_step.dart';

/// Maximum number of pattern slots in the song.
const int kMaxSongPatterns = 99;

class SongPlanPosition {
  final int stepIndex;
  final int pass;
  final int patternIndex;
  final int line;
  final bool passStart;
  final bool planEnd;

  const SongPlanPosition({
    required this.stepIndex,
    required this.pass,
    required this.patternIndex,
    required this.line,
    required this.passStart,
    required this.planEnd,
  });
}

class SongModel {
  String name;

  /// Pattern slots used by live sequential playback and referenced by the plan.
  /// With the plan off, playback stops at the first empty pattern.
  List<PatternModel> patterns;

  /// Master output level: 0..1 (default 1.0 = 0 dB).
  double masterVolume;

  /// When true the master output is silenced.
  bool masterMute;

  /// Null uses the automatic sequential default. Custom plans have 99 steps.
  List<SongPlanStep>? songPlan;
  bool songPlanEnabled = false;

  SongModel({
    required this.name,
    List<PatternModel>? patterns,
    this.masterVolume = 1.0,
    this.masterMute = false,
  }) : patterns = patterns ?? [PatternModel(name: 'PAT 01')];

  factory SongModel.initial() => SongModel(name: 'New Song');

  int _nextPatternNumber() {
    var maxSeen = 0;
    for (final p in patterns) {
      final m = RegExp(r'(\d+)$').firstMatch(p.name.trim());
      if (m == null) continue;
      final n = int.tryParse(m.group(1) ?? '');
      if (n != null && n > maxSeen) maxSeen = n;
    }
    return maxSeen + 1;
  }

  PatternModel createEmptyPattern() {
    final num = _nextPatternNumber();
    return PatternModel(name: 'PAT ${num.toString().padLeft(2, '0')}');
  }

  /// Insert a deep copy of [source] at [destIndex].
  void insertCopyAt(int sourceIndex, int destIndex) {
    if (sourceIndex < 0 || sourceIndex >= patterns.length) return;
    final clamped = destIndex.clamp(0, patterns.length);
    final newIdx = _nextPatternNumber();
    final copy = patterns[sourceIndex].copyWithName(
      'PAT ${newIdx.toString().padLeft(2, '0')}',
    );
    patterns.insert(clamped, copy);
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'masterVolume': masterVolume,
    'masterMute': masterMute,
    'patterns': patterns.map((p) => p.toJson()).toList(),
    if (songPlan != null)
      'songPlan': songPlan!.map((step) => step.toJson()).toList(),
    'songPlanEnabled': songPlanEnabled,
  };

  SongPlanStep planStepAt(int index) =>
      songPlan?[index] ?? SongPlanStep(patternIndex: index);

  int planPatternLines(SongPlanStep step) => step.patternIndex < patterns.length
      ? patterns[step.patternIndex].rowCount
      : kDefaultBeats * kDefaultLinesPerBeat;

  /// Empty patterns end playback, including inside a counted group.
  int playablePlanPatternCount(SongPlanStep step) {
    var count = 0;
    while (count < step.count &&
        step.patternIndex + count < patterns.length &&
        !patterns[step.patternIndex + count].isEmpty) {
      count++;
    }
    return count;
  }

  bool hasValidPlanRange(SongPlanStep step) {
    final count = playablePlanPatternCount(step);
    if (count == 0) return step.hasValidRange(planPatternLines(step));
    for (var offset = 0; offset < count; offset++) {
      if (!step.hasValidRange(patterns[step.patternIndex + offset].rowCount)) {
        return false;
      }
    }
    return true;
  }

  /// Validates a run without expanding repeats or allocating playback rows.
  int validateSongPlan(int startStep) {
    RangeError.checkValueInInterval(startStep, 0, kMaxSongPatterns - 1);
    var endStep = startStep;
    for (; endStep < kMaxSongPatterns; endStep++) {
      final step = planStepAt(endStep);
      final count = playablePlanPatternCount(step);
      if (count == 0) break;
      for (var offset = 0; offset < count; offset++) {
        final patternIndex = step.patternIndex + offset;
        if (!step.hasValidRange(patterns[patternIndex].rowCount)) {
          throw StateError(
            'Song Plan step ${endStep + 1}, pattern ${patternIndex + 1}: '
            'start line exceeds the pattern length.',
          );
        }
      }
      if (count < step.count) return endStep + 1;
    }
    return endStep;
  }

  Iterable<SongPlanPosition> songPlanPositions(int startStep) sync* {
    var first = startStep;
    while (true) {
      final endStep = validateSongPlan(first);
      if (endStep == first) return;
      for (var index = first; index < endStep; index++) {
        final step = planStepAt(index);
        final count = playablePlanPatternCount(step);
        final repeats = count < step.count ? 1 : step.repeats;
        for (var pass = 1; pass <= repeats; pass++) {
          for (var offset = 0; offset < count; offset++) {
            final patternIndex = step.patternIndex + offset;
            final endLine = step.effectiveEndLine(
              patterns[patternIndex].rowCount,
            );
            for (var line = step.startLine; line <= endLine; line++) {
              yield SongPlanPosition(
                stepIndex: index,
                pass: pass,
                patternIndex: patternIndex,
                line: line,
                passStart: line == step.startLine,
                planEnd:
                    index == endStep - 1 &&
                    pass == repeats &&
                    offset == count - 1 &&
                    line == endLine,
              );
            }
          }
        }
      }
      first = 0;
    }
  }

  static List<SongPlanStep>? readSongPlan(dynamic json) {
    if (json == null) return null;
    if (json is! List || json.length != kMaxSongPatterns) {
      throw const FormatException('Song Plan must contain 99 steps.');
    }
    return List.unmodifiable(
      json.map((step) => SongPlanStep.fromJson(step as Map<String, dynamic>)),
    );
  }

  factory SongModel.fromJson(Map<String, dynamic> j) {
    // Handle both old saves (with arrangement list) and new saves (patterns only).
    // Old saves: arrangement[i] is a pattern index; we rebuild the ordered list.
    final rawPatterns = (j['patterns'] as List<dynamic>)
        .map((e) => PatternModel.fromJson(e as Map<String, dynamic>))
        .toList();

    List<PatternModel> orderedPatterns;
    if (j.containsKey('arrangement')) {
      // Legacy: reorder patterns according to the old arrangement, deduplicating.
      final arr = List<int>.from(j['arrangement'] as List<dynamic>);
      final seen = <int>{};
      orderedPatterns = [];
      for (final idx in arr) {
        if (idx >= 0 && idx < rawPatterns.length && seen.add(idx)) {
          orderedPatterns.add(rawPatterns[idx]);
        }
      }
      // Append any patterns not referenced in the arrangement.
      for (int i = 0; i < rawPatterns.length; i++) {
        if (!seen.contains(i)) orderedPatterns.add(rawPatterns[i]);
      }
    } else {
      orderedPatterns = rawPatterns;
    }

    return SongModel(
        name: j['name'] as String,
        masterVolume: ((j['masterVolume'] as num?)?.toDouble() ?? 1.0).clamp(
          0.0,
          4.0,
        ),
        masterMute: (j['masterMute'] as bool?) ?? false,
        patterns: orderedPatterns,
      )
      ..songPlan = readSongPlan(j['songPlan'])
      ..songPlanEnabled = (j['songPlanEnabled'] as bool?) ?? false;
  }
}
