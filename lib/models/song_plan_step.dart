const int kMaxSongPlanRepeats = 999;
const int kMaxSongPlanLines = 99 * 99;

/// Pattern slots are zero-based; line boundaries are one-based and inclusive.
class SongPlanStep {
  final int patternIndex;
  final int count;
  final int repeats;
  final int startLine;

  /// Null follows the pattern's last line as its length changes.
  final int? endLine;

  factory SongPlanStep({
    required int patternIndex,
    int count = 1,
    int repeats = 1,
    int startLine = 1,
    int? endLine,
  }) {
    if (patternIndex < 0 || patternIndex >= 99) {
      throw const FormatException(
        'Song Plan pattern must be between 1 and 99.',
      );
    }
    if (count < 1 || patternIndex + count > 99) {
      throw const FormatException(
        'Song Plan count must stay within pattern slots 1 to 99.',
      );
    }
    if (repeats < 1 || repeats > kMaxSongPlanRepeats) {
      throw const FormatException(
        'Song Plan repeat must be between 1 and 999.',
      );
    }
    if (startLine < 1 || startLine > kMaxSongPlanLines) {
      throw const FormatException('Song Plan start line is out of range.');
    }
    if (endLine != null &&
        (endLine < startLine || endLine > kMaxSongPlanLines)) {
      throw const FormatException('Song Plan end line is out of range.');
    }
    return SongPlanStep._(patternIndex, count, repeats, startLine, endLine);
  }

  const SongPlanStep._(
    this.patternIndex,
    this.count,
    this.repeats,
    this.startLine,
    this.endLine,
  );

  int effectiveEndLine(int patternLines) =>
      endLine == null || endLine! > patternLines ? patternLines : endLine!;

  bool hasValidRange(int patternLines) =>
      startLine <= effectiveEndLine(patternLines);

  Map<String, dynamic> toJson() => {
    'patternIndex': patternIndex,
    'count': count,
    'repeats': repeats,
    'startLine': startLine,
    'endLine': endLine,
  };

  factory SongPlanStep.fromJson(Map<String, dynamic> json) => SongPlanStep(
    patternIndex: json['patternIndex'] as int,
    count: json.containsKey('count') ? json['count'] as int : 1,
    repeats: json['repeats'] as int,
    startLine: json['startLine'] as int,
    endLine: json['endLine'] as int?,
  );

  @override
  bool operator ==(Object other) =>
      other is SongPlanStep &&
      other.patternIndex == patternIndex &&
      other.count == count &&
      other.repeats == repeats &&
      other.startLine == startLine &&
      other.endLine == endLine;

  @override
  int get hashCode =>
      Object.hash(patternIndex, count, repeats, startLine, endLine);
}
