import 'fx_envelope_run.dart';
import 'track_model.dart';

const int kDefaultLinesPerBeat = 4;
const int kDefaultBeats = 4;
const int kBeatsPerBar  = 4; // 4 lines × 4 beats = 16 lines per bar

class PatternModel {
  String name;
  double? bpm;
  int? beats;
  int? linesPerBeat;
  /// Per-beat line count overrides. Length always equals [beatCount].
  /// A null or 0 entry means "use the pattern default [lpb]".
  /// Any other value (1–16) overrides the subdivision for that beat only.
  List<int?> beatLineOverrides;
  List<TrackModel> tracks;
  List<FxEnvelopeRun> fxEnvelopes;
  /// Swing amount: 0.0 = straight, 1.0–99.0 = push even lines (0-indexed 1,
  /// 3, 5…) later within each beat. Odd lines get proportionally longer,
  /// even lines get proportionally shorter, so beat totals never drift.
  double swing;

  PatternModel({
    required this.name,
    this.bpm = 120.0,
    this.beats = kDefaultBeats,
    this.linesPerBeat = kDefaultLinesPerBeat,
    this.swing = 0.0,
    List<int?>? beatLineOverrides,
    List<TrackModel>? tracks,
    List<FxEnvelopeRun>? fxEnvelopes,
  })  : fxEnvelopes = fxEnvelopes ?? [],
        beatLineOverrides = beatLineOverrides ??
            List.filled(beats ?? kDefaultBeats, null, growable: true),
        tracks = tracks ?? _defaultTracks(
          _rowCountFor(beats ?? kDefaultBeats, linesPerBeat ?? kDefaultLinesPerBeat),
        ) {
    _syncBeatOverridesLength();
    syncTrackLengths();
  }

  static int _rowCountFor(int beats, int linesPerBeat) {
    final safeBeats = beats.clamp(1, 99);
    final safeLinesPerBeat = linesPerBeat.clamp(1, 99);
    return safeBeats * safeLinesPerBeat;
  }

  int get beatCount => (beats ?? kDefaultBeats).clamp(1, 99);
  int get lpb => (linesPerBeat ?? kDefaultLinesPerBeat).clamp(1, 99);

  /// Lines in a specific beat: override if set, else default [lpb].
  int linesForBeat(int beat) {
    if (beat < 0 || beat >= beatLineOverrides.length) return lpb;
    final v = beatLineOverrides[beat];
    return (v == null || v == 0) ? lpb : v.clamp(1, 16);
  }

  /// Which beat (0-based) does [row] fall in?
  int beatForRow(int row) {
    int remaining = row;
    for (int b = 0; b < beatCount; b++) {
      final lines = linesForBeat(b);
      if (remaining < lines) return b;
      remaining -= lines;
    }
    return beatCount - 1;
  }

  /// 0-based position of [row] within its beat.
  int rowWithinBeat(int row) {
    int remaining = row;
    for (int b = 0; b < beatCount; b++) {
      final lines = linesForBeat(b);
      if (remaining < lines) return remaining;
      remaining -= lines;
    }
    return 0;
  }

  /// Total rows = sum of linesForBeat across all beats.
  int get rowCount {
    int total = 0;
    for (int b = 0; b < beatCount; b++) {
      total += linesForBeat(b);
    }
    return total;
  }

  bool get isEmpty =>
      tracks.every((track) => track.cells.every((cell) => cell.isEmpty));

  /// Keep [beatLineOverrides] length in sync with [beatCount].
  void _syncBeatOverridesLength() {
    final n = beatCount;
    while (beatLineOverrides.length < n) {
      beatLineOverrides.add(null);
    }
    if (beatLineOverrides.length > n) {
      beatLineOverrides.removeRange(n, beatLineOverrides.length);
    }
  }

  /// Set (or clear) the per-beat line override for [beat].
  /// Pass null or 0 to remove the override (revert to pattern default).
  void setBeatLineOverride(int beat, int? lines) {
    if (beat < 0 || beat >= beatCount) return;
    beatLineOverrides[beat] = (lines == null || lines == 0) ? null : lines.clamp(1, 16);
  }

  /// Returns the time position of [row] measured in beats (fractional).
  /// This is BPM-independent and correctly handles per-beat line overrides:
  /// each beat occupies exactly 1.0 beat regardless of how many lines it has.
  double rowTimeInBeats(int row) {
    double t = 0.0;
    int remaining = row;
    for (int b = 0; b < beatCount; b++) {
      final lines = linesForBeat(b);
      if (remaining < lines) {
        t += remaining / lines; // fractional position within this beat
        return t;
      }
      t += 1.0;
      remaining -= lines;
    }
    return t;
  }

  void syncTrackLengths() {
    _syncBeatOverridesLength();
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
      swing: swing,
      beatLineOverrides: List<int?>.from(beatLineOverrides),
      fxEnvelopes: fxEnvelopes
          .map((e) => FxEnvelopeRun.fromJson(e.toJson()))
          .toList(),
      tracks: tracks
          .map((t) => TrackModel(
                name: t.name,
                collapsed: t.collapsed,
                mixerVolume: t.mixerVolume,
                mixerPan: t.mixerPan,
                mixerMute: t.mixerMute,
                mixerSolo: t.mixerSolo,
                sendChannel: t.sendChannel,
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
    'swing': swing,
    'beatOverrides': beatLineOverrides,
    'fxEnvelopes': fxEnvelopes.map((e) => e.toJson()).toList(),
    'tracks': tracks.map((t) => t.toJson()).toList(),
  };

  factory PatternModel.fromJson(Map<String, dynamic> j) {
    final loadedTracks = (j['tracks'] as List<dynamic>)
        .map((e) => TrackModel.fromJson(e as Map<String, dynamic>))
        .toList();
    List<int?>? overrides;
    if (j['beatOverrides'] != null) {
      overrides = (j['beatOverrides'] as List<dynamic>)
          .map((e) => e as int?)
          .toList(growable: true);
    }
    List<FxEnvelopeRun>? loadedEnvelopes;
    if (j['fxEnvelopes'] != null) {
      loadedEnvelopes = (j['fxEnvelopes'] as List<dynamic>)
          .map((e) => FxEnvelopeRun.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return PatternModel(
      name: j['name'] as String,
      bpm: (j['bpm'] as num?)?.toDouble() ?? 120.0,
      beats: (j['beats'] as int?) ?? kDefaultBeats,
      linesPerBeat: (j['lpb'] as int?) ?? kDefaultLinesPerBeat,
      swing: ((j['swing'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 99.0),
      beatLineOverrides: overrides,
      fxEnvelopes: loadedEnvelopes,
      tracks: loadedTracks,
    );
  }
}
