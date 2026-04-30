import 'track_model.dart';

const int kLinesPerBeat = 4;
const int kBeatsPerBar  = 4; // 4 lines × 4 beats = 16 lines per bar

class PatternModel {
  String name;
  List<TrackModel> tracks;

  PatternModel({
    required this.name,
    List<TrackModel>? tracks,
  }) : tracks = tracks ?? _defaultTracks();

  static List<TrackModel> _defaultTracks() => List.generate(
        kDefaultTracks,
        (i) => TrackModel(name: 'TRK ${(i + 1).toString().padLeft(2, '0')}'),
      );

  /// Add a new empty track (up to kMaxTracks).
  void addTrack() {
    if (tracks.length < kMaxTracks) {
      final idx = tracks.length + 1;
      tracks.add(TrackModel(name: 'TRK ${idx.toString().padLeft(2, '0')}'));
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
      tracks: tracks
          .map((t) => TrackModel(
                name: t.name,
                cells: t.cells.map((c) => c.copy()).toList(),
              ))
          .toList(),
    );
  }
}
