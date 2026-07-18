import 'pattern_model.dart';

/// Maximum number of pattern slots in the song.
const int kMaxSongPatterns = 99;

class SongModel {
  String name;

  /// Ordered list of patterns. This IS the arrangement — pattern[0] plays
  /// first, pattern[1] second, etc. Sequential song playback stops at the
  /// first empty pattern.
  List<PatternModel> patterns;

  /// Master output level: 0..1 (default 1.0 = 0 dB).
  double masterVolume;

  /// When true the master output is silenced.
  bool masterMute;

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

  /// Append a new empty pattern. Returns its index.
  int addPattern() {
    patterns.add(createEmptyPattern());
    return patterns.length - 1;
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
  };

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
    );
  }
}
