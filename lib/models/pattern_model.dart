import 'track_model.dart';

const int kDefaultLinesPerBeat = 4;
const int kDefaultBeats = 16;
const int kBeatsPerBar  = 4; // 4 lines × 4 beats = 16 lines per bar

class PatternModel {
  String name;
  double? bpm;
  int? beats;
  int? linesPerBeat;
  List<TrackModel> tracks;

  PatternModel({
    required this.name,
    this.bpm = 120.0,
    this.beats = kDefaultBeats,
    this.linesPerBeat = kDefaultLinesPerBeat,
    List<TrackModel>? tracks,
  }) : tracks = tracks ?? _defaultTracks(
          _rowCountFor(beats ?? kDefaultBeats, linesPerBeat ?? kDefaultLinesPerBeat),
        ) {
    syncTrackLengths();
  }

  static int _rowCountFor(int beats, int linesPerBeat) {
    final safeBeats = beats.clamp(1, 99);
    final safeLinesPerBeat = linesPerBeat.clamp(1, 99);
    return safeBeats * safeLinesPerBeat;
  }

  int get beatCount => (beats ?? kDefaultBeats).clamp(1, 99);
  int get lpb => (linesPerBeat ?? kDefaultLinesPerBeat).clamp(1, 99);
  int get rowCount => _rowCountFor(beatCount, lpb);
  bool get isEmpty =>
      tracks.every((track) => track.cells.every((cell) => cell.isEmpty));

  void syncTrackLengths() {
    final rows = rowCount;
    for (final track in tracks) {
      track.resizeRows(rows);
    }
  }

  static List<TrackModel> _defaultTracks(int rowCount) => List.generate(
        kDefaultTracks,
        (i) => TrackModel(
          name: 'TRK ${(i + 1).toString().padLeft(2, '0')}',
          rowCount: rowCount,
        ),
      );

  /// Add a new empty track (up to kMaxTracks).
  void addTrack() {
    if (tracks.length < kMaxTracks) {
      final idx = tracks.length + 1;
      tracks.add(TrackModel(
        name: 'TRK ${idx.toString().padLeft(2, '0')}',
        rowCount: rowCount,
      ));
    }
  }

  /// Remove the last track (minimum 1).
  void removeLastTrack() {
    if (tracks.length > 1) tracks.removeLast();
  }

  /// Deep copy this pattern (cells included) under a new name.
  PatternModel copyWithName(String newName) {
    return PatternModel(
      name: newName,
      bpm: bpm ?? 120.0,
      beats: beatCount,
      linesPerBeat: lpb,
      tracks: tracks
          .map((t) => TrackModel(
                name: t.name,
                collapsed: t.collapsed,
                mixerVolume: t.mixerVolume,
                mixerPan: t.mixerPan,
                mixerMute: t.mixerMute,
                mixerSolo: t.mixerSolo,
                cells: t.cells.map((c) => c.copy()).toList(),
              ))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'bpm': bpm ?? 120.0,
    'beats': beats ?? kDefaultBeats,
    'lpb': linesPerBeat ?? kDefaultLinesPerBeat,
    'tracks': tracks.map((t) => t.toJson()).toList(),
  };

  factory PatternModel.fromJson(Map<String, dynamic> j) {
    final loadedTracks = (j['tracks'] as List<dynamic>)
        .map((e) => TrackModel.fromJson(e as Map<String, dynamic>))
        .toList();
    return PatternModel(
      name: j['name'] as String,
      bpm: (j['bpm'] as num?)?.toDouble() ?? 120.0,
      beats: (j['beats'] as int?) ?? kDefaultBeats,
      linesPerBeat: (j['lpb'] as int?) ?? kDefaultLinesPerBeat,
      tracks: loadedTracks,
    );
  }
}
