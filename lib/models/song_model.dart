import 'pattern_model.dart';

class SongModel {
  String name;
  double bpm;
  List<PatternModel> patterns;
  /// Song arrangement: each entry is a pattern index played in order.
  List<int> arrangement;
  /// Mute flags parallel to [arrangement]; muted slots are skipped on playback.
  List<bool> arrangementMutes;

  SongModel({
    required this.name,
    this.bpm = 120.0,
    List<PatternModel>? patterns,
    List<int>? arrangement,
    List<bool>? arrangementMutes,
  })  : patterns         = patterns         ?? [PatternModel(name: 'PAT 01')],
        arrangement      = arrangement      ?? <int>[0],
        arrangementMutes = arrangementMutes ??
            List<bool>.filled(arrangement?.length ?? 1, false, growable: true);

  factory SongModel.initial() => SongModel(name: 'New Song');

  /// Create a brand-new empty pattern and return its index.
  int addPattern() {
    final idx = patterns.length + 1;
    patterns.add(PatternModel(
      name: 'PAT ${idx.toString().padLeft(2, '0')}',
    ));
    return patterns.length - 1;
  }
}
