import 'pattern_model.dart';

class SongModel {
  String name;
  List<PatternModel> patterns;
  /// Song arrangement: each entry is a pattern index played in order.
  List<int> arrangement;
  /// Mute flags parallel to [arrangement]; muted slots are skipped on playback.
  List<bool> arrangementMutes;
  /// Master output level: 0..1 (default 1.0 = 0 dB).
  double masterVolume;
  /// When true the master output is silenced.
  bool masterMute;

  SongModel({
    required this.name,
    List<PatternModel>? patterns,
    List<int>? arrangement,
    List<bool>? arrangementMutes,
    this.masterVolume = 1.0,
    this.masterMute = false,
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

  Map<String, dynamic> toJson() => {
    'name': name,
    'masterVolume': masterVolume,
    'masterMute': masterMute,
    'patterns': patterns.map((p) => p.toJson()).toList(),
    'arrangement': arrangement,
    'arrangementMutes': arrangementMutes,
  };

  factory SongModel.fromJson(Map<String, dynamic> j) => SongModel(
    name: j['name'] as String,
    masterVolume: ((j['masterVolume'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0),
    masterMute: (j['masterMute'] as bool?) ?? false,
    patterns: (j['patterns'] as List<dynamic>)
        .map((e) => PatternModel.fromJson(e as Map<String, dynamic>))
        .toList(),
    arrangement: List<int>.from(j['arrangement'] as List<dynamic>),
    arrangementMutes:
        List<bool>.from(j['arrangementMutes'] as List<dynamic>),
  );
}
