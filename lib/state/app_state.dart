import 'dart:async';

import 'package:flutter/widgets.dart';
import '../models/cell.dart';
import '../models/instrument_model.dart';
import '../models/note_value.dart';
import '../models/pattern_model.dart';
import '../models/song_model.dart';
import '../models/track_model.dart';

/// Selected cell within the pattern grid.
class CellPosition {
  final int row;
  final CellColumn column;
  const CellPosition(this.row, this.column);

  @override
  bool operator ==(Object other) =>
      other is CellPosition && other.row == row && other.column == column;

  @override
  int get hashCode => Object.hash(row, column);
}

/// Central application state — passed down via InheritedNotifier.
class AppState extends ChangeNotifier {
  SongModel song = SongModel.initial();
  Timer? _playheadTimer;
  bool _playbackFollowsSong = false;
  int _currentArrangementSlotIndex = 0;
  int _playheadArrangementSlot = 0;

  /// Instrument bank — fixed length, indexed by the cell's instrument byte.
  final List<InstrumentModel> instruments = List.generate(
    kInstrumentSlots,
    (i) => InstrumentModel.empty(i + 1),
  );

  int _currentPatternIndex = 0;
  int _currentTrackIndex   = 0;
  int _currentInstrumentIndex = 0;

  CellPosition? selectedCell;

  TrackerCell? _rowClipboard;
  bool get hasRowClipboard => _rowClipboard != null;

  bool isPlaying   = false;
  bool isRecording = false;
  int  playheadRow = 0;

  /// When true, all tracks are visible side-by-side showing only
  /// NOTE + INST columns. When false, only the current track is
  /// visible (full columns) via swipe-paging.
  bool collapsedView = false;

  // ── Getters ──────────────────────────────────────────────────────────────

  int get currentPatternIndex    => _currentPatternIndex;
  int get currentTrackIndex      => _currentTrackIndex;
  int get currentInstrumentIndex => _currentInstrumentIndex;
  int get currentArrangementSlotIndex => _currentArrangementSlotIndex;
  int get playheadArrangementSlot => _playheadArrangementSlot;
  bool get playbackFollowsSong => _playbackFollowsSong;

  PatternModel    get currentPattern    => song.patterns[_currentPatternIndex];
  TrackModel      get currentTrack      => currentPattern.tracks[_currentTrackIndex];
  InstrumentModel get currentInstrument => instruments[_currentInstrumentIndex];

  double get bpm => currentPattern.bpm ?? 120.0;
  int    get beats => currentPattern.beatCount;
  int    get linesPerBeat => currentPattern.lpb;
  int    get rowCount => currentPattern.rowCount;
  int    get trackCount => currentPattern.tracks.length;
  bool   get canChangePatternLength => currentPattern.isEmpty;

  // ── Navigation ───────────────────────────────────────────────────────────

  void selectPattern(int index) {
    _currentPatternIndex = index.clamp(0, song.patterns.length - 1);
    _currentTrackIndex   = 0;
    selectedCell = null;
    _clampSelectionToPattern();
    _restartPlayheadTimerIfNeeded();
    notifyListeners();
  }

  void selectInstrument(int index) {
    _currentInstrumentIndex = index.clamp(0, instruments.length - 1);
    notifyListeners();
  }

  void setInstrumentType(int index, InstrumentType type) {
    if (index < 0 || index >= instruments.length) return;
    instruments[index].type = type;
    notifyListeners();
  }

  /// Trigger a UI rebuild after the instrument editors mutate parameters
  /// directly. (They mutate plain fields; this just notifies listeners.)
  void instrumentParamsChanged() => notifyListeners();

  void selectTrack(int index) {
    _currentTrackIndex = index.clamp(0, currentPattern.tracks.length - 1);
    selectedCell = null;
    notifyListeners();
  }

  void nextTrack() => selectTrack(_currentTrackIndex + 1);
  void prevTrack() => selectTrack(_currentTrackIndex - 1);

  // ── Cell selection ───────────────────────────────────────────────────────

  void selectCell(int row, CellColumn column) {
    final pos = CellPosition(row, column);
    selectedCell = (selectedCell == pos) ? null : pos;
    notifyListeners();
  }

  void clearSelection() {
    selectedCell = null;
    notifyListeners();
  }

  // ── Cell editing ─────────────────────────────────────────────────────────

  /// Increment the value in a cell's column by [delta] (positive = higher).
  void nudgeCell(int row, CellColumn column, int delta) {
    final track = currentTrack;
    final current = track.readColumnValue(row, column) ?? 0;
    final clamped = (current + delta).clamp(
      track.minValue(column),
      track.maxValue(column),
    );
    track.writeColumnValue(row, column, clamped);
    notifyListeners();
  }

  void setNote(int row, NoteValue note) {
    currentTrack.setNote(row, note);
    notifyListeners();
  }

  /// Inserts the column-specific default value into an empty cell.
  void insertDefaultValue(int row, CellColumn column) {
    final track = currentTrack;
    switch (column) {
      case CellColumn.note:
        track.setNote(row, NoteValue.fromScrollIndex(49)); // C-4
      case CellColumn.instrument:
        // scan upward for last used instrument, else 0x00
        int def = 0x00;
        for (int r = row - 1; r >= 0; r--) {
          final v = track.cells[r].instrument;
          if (v != null) { def = v; break; }
        }
        track.writeColumnValue(row, column, def);
      case CellColumn.volume:
        track.writeColumnValue(row, column, 0x80);
      case CellColumn.pan:
        track.writeColumnValue(row, column, 0x50);
      case CellColumn.fx0cmd:
      case CellColumn.fx1cmd:
      case CellColumn.fx2cmd:
        track.writeColumnValue(row, column, 0x00);
      default:
        return; // fx val columns — no default insert
    }
    notifyListeners();
  }

  /// Clears a single column value (sets to empty/null). Ignored for fx val columns.
  void clearColumnValue(int row, CellColumn column) {
    final track = currentTrack;
    switch (column) {
      case CellColumn.note:
        track.cells[row].note = NoteValue.empty;
      case CellColumn.instrument:
        track.cells[row].instrument = null;
      case CellColumn.volume:
        track.cells[row].volume = null;
      case CellColumn.pan:
        track.cells[row].pan = null;
      case CellColumn.fx0cmd:
        track.cells[row].fxSlots[0].command = null;
      case CellColumn.fx1cmd:
        track.cells[row].fxSlots[1].command = null;
      case CellColumn.fx2cmd:
        track.cells[row].fxSlots[2].command = null;
      default:
        return; // fx val columns not clearable
    }
    notifyListeners();
  }

  void clearCell(int row) {
    currentPattern.tracks[_currentTrackIndex].cells[row] = TrackerCell.empty();
    notifyListeners();
  }

  void copyRow(int row) {
    _rowClipboard = currentTrack.cells[row].copy();
    notifyListeners();
  }

  void pasteRow(int row) {
    if (_rowClipboard == null) return;
    currentTrack.cells[row] = _rowClipboard!.copy();
    notifyListeners();
  }

  void deleteRow(int row) {
    currentTrack.cells[row] = TrackerCell.empty();
    notifyListeners();
  }

  // ── Track collapse ────────────────────────────────────────────────────────

  void toggleCollapsedView() {
    collapsedView = !collapsedView;
    notifyListeners();
  }

  // ── Song arrangement ─────────────────────────────────────────────────────

  /// Append a new empty pattern to the song and add a slot referencing it.
  void appendNewPattern() {
    final newIdx = song.addPattern();
    song.arrangement.add(newIdx);
    song.arrangementMutes.add(false);
    notifyListeners();
  }

  /// Append a slot referencing an existing pattern (cheap "copy" / repeat).
  void appendPatternRef(int patternIndex) {
    if (patternIndex < 0 || patternIndex >= song.patterns.length) return;
    song.arrangement.add(patternIndex);
    song.arrangementMutes.add(false);
    notifyListeners();
  }

  /// Duplicate the slot at [slotIndex] (same pattern reference).
  void duplicateArrangementSlot(int slotIndex) {
    if (slotIndex < 0 || slotIndex >= song.arrangement.length) return;
    song.arrangement.insert(slotIndex + 1, song.arrangement[slotIndex]);
    song.arrangementMutes.insert(
        slotIndex + 1, song.arrangementMutes[slotIndex]);
    notifyListeners();
  }

  /// Duplicate a pattern: create a brand-new pattern with copied content,
  /// append a slot at the end of the arrangement referring to it.
  /// The new pattern has its own number and is independent.
  void duplicatePatternToEnd(int sourcePatternIndex) {
    if (sourcePatternIndex < 0 ||
        sourcePatternIndex >= song.patterns.length) {
      return;
    }
    final src     = song.patterns[sourcePatternIndex];
    final newIdx  = song.patterns.length + 1;
    final newName = 'PAT ${newIdx.toString().padLeft(2, '0')}';
    song.patterns.add(src.copyWithName(newName));
    song.arrangement.add(song.patterns.length - 1);
    song.arrangementMutes.add(false);
    notifyListeners();
  }

  /// Append another reference to [sourcePatternIndex] at the end of the
  /// arrangement. Editing it edits every instance — same pattern.
  void repeatPatternAtEnd(int sourcePatternIndex) {
    appendPatternRef(sourcePatternIndex);
  }

  void removeArrangementSlot(int slotIndex) {
    if (song.arrangement.length <= 1) return;
    if (slotIndex < 0 || slotIndex >= song.arrangement.length) return;
    final removedPatIdx = song.arrangement[slotIndex];
    song.arrangement.removeAt(slotIndex);
    song.arrangementMutes.removeAt(slotIndex);

    // If no remaining slot references this pattern, remove the pattern
    // itself and shift all higher pattern indices down by one. Numbers
    // are renumbered (pattern at index N is "PAT (N+1)") so freed slots
    // become available for the next new pattern.
    final stillUsed = song.arrangement.contains(removedPatIdx);
    if (!stillUsed) {
      song.patterns.removeAt(removedPatIdx);
      for (int i = 0; i < song.arrangement.length; i++) {
        if (song.arrangement[i] > removedPatIdx) {
          song.arrangement[i] -= 1;
        }
      }
      // Renumber pattern names to stay consecutive.
      for (int i = 0; i < song.patterns.length; i++) {
        song.patterns[i].name =
            'PAT ${(i + 1).toString().padLeft(2, '0')}';
      }
      // Clamp current pattern selection.
      if (_currentPatternIndex >= song.patterns.length) {
        _currentPatternIndex = song.patterns.length - 1;
      }
    }
    notifyListeners();
  }

  void moveArrangementSlot(int from, int to) {
    if (from == to) return;
    if (from < 0 || from >= song.arrangement.length) return;
    if (to   < 0 || to   >= song.arrangement.length) return;
    final p = song.arrangement.removeAt(from);
    final m = song.arrangementMutes.removeAt(from);
    song.arrangement.insert(to, p);
    song.arrangementMutes.insert(to, m);
    notifyListeners();
  }

  void toggleArrangementMute(int slotIndex) {
    if (slotIndex < 0 || slotIndex >= song.arrangementMutes.length) return;
    song.arrangementMutes[slotIndex] =
        !song.arrangementMutes[slotIndex];
    notifyListeners();
  }

  /// Point an arrangement slot at a different (existing) pattern.
  void replaceArrangementSlot(int slotIndex, int patternIndex) {
    if (slotIndex < 0 || slotIndex >= song.arrangement.length) return;
    if (patternIndex < 0 || patternIndex >= song.patterns.length) return;
    song.arrangement[slotIndex] = patternIndex;
    notifyListeners();
  }

  /// Set the editor focus to the pattern referenced by this arrangement slot.
  void selectArrangementSlot(int slotIndex) {
    if (slotIndex < 0 || slotIndex >= song.arrangement.length) return;
    _currentArrangementSlotIndex = slotIndex;
    if (!isPlaying || _playbackFollowsSong) {
      _playheadArrangementSlot = slotIndex;
    }
    selectPattern(song.arrangement[slotIndex]);
  }

  void setPlaybackFollowsSong(bool enabled) {
    if (_playbackFollowsSong == enabled) return;
    _playbackFollowsSong = enabled;
    if (isPlaying) {
      if (_playbackFollowsSong) {
        _playheadArrangementSlot =
            _currentArrangementSlotIndex.clamp(0, song.arrangement.length - 1);
        _syncCurrentPatternToSongPlayhead();
        playheadRow = 0;
      }
      _restartPlayheadTimerIfNeeded();
    }
    notifyListeners();
  }

  // ── Transport ────────────────────────────────────────────────────────────

  void play() {
    if (isPlaying) return;
    if (_playbackFollowsSong && song.arrangement.isNotEmpty) {
      _playheadArrangementSlot =
          _currentArrangementSlotIndex.clamp(0, song.arrangement.length - 1);
      _syncCurrentPatternToSongPlayhead();
      playheadRow = 0;
    }
    isPlaying = true;
    _startPlayheadTimer();
    notifyListeners();
  }

  void stop() {
    _playheadTimer?.cancel();
    _playheadTimer = null;
    isPlaying   = false;
    playheadRow = 0;
    notifyListeners();
  }

  void toggleRecord() {
    isRecording = !isRecording;
    notifyListeners();
  }

  void setBpm(double value) {
    final clamped = value.round().clamp(20, 300);
    currentPattern.bpm = clamped.toDouble();
    _restartPlayheadTimerIfNeeded();
    notifyListeners();
  }

  void setBeats(int value) {
    if (!canChangePatternLength) return;
    final clamped = value.clamp(1, 99);
    currentPattern.beats = clamped;
    currentPattern.syncTrackLengths();
    _clampSelectionToPattern();
    _restartPlayheadTimerIfNeeded();
    notifyListeners();
  }

  void setLinesPerBeat(int value) {
    if (!canChangePatternLength) return;
    final clamped = value.clamp(1, 99);
    currentPattern.linesPerBeat = clamped;
    currentPattern.syncTrackLengths();
    _clampSelectionToPattern();
    _restartPlayheadTimerIfNeeded();
    notifyListeners();
  }

  Duration _lineDuration() {
    // One line lasts one beat divided by LPB.
    final microsPerLine =
        (60000000 / (bpm * linesPerBeat)).round().clamp(1000, 60000000);
    return Duration(microseconds: microsPerLine);
  }

  void _startPlayheadTimer() {
    _playheadTimer?.cancel();
    _playheadTimer = Timer.periodic(_lineDuration(), (_) {
      if (!isPlaying) return;
      advancePlayhead();
    });
  }

  void _restartPlayheadTimerIfNeeded() {
    if (!isPlaying) return;
    _startPlayheadTimer();
  }

  void _clampSelectionToPattern() {
    if (playheadRow >= rowCount) {
      playheadRow = rowCount - 1;
    }
    if (selectedCell != null && selectedCell!.row >= rowCount) {
      selectedCell = null;
    }
  }

  void advancePlayhead() {
    if (_playbackFollowsSong && song.arrangement.isNotEmpty) {
      final slotPatternIdx = song.arrangement[_playheadArrangementSlot];
      final slotPattern = song.patterns[slotPatternIdx];
      playheadRow += 1;
      if (playheadRow >= slotPattern.rowCount) {
        playheadRow = 0;
        _playheadArrangementSlot =
            (_playheadArrangementSlot + 1) % song.arrangement.length;
        _syncCurrentPatternToSongPlayhead();
        _restartPlayheadTimerIfNeeded();
      }
    } else {
      playheadRow = (playheadRow + 1) % rowCount;
    }
    notifyListeners();
  }

  void _syncCurrentPatternToSongPlayhead() {
    if (song.arrangement.isEmpty) return;
    final idx = song.arrangement[_playheadArrangementSlot]
        .clamp(0, song.patterns.length - 1);
    _currentPatternIndex = idx;
    _clampSelectionToPattern();
  }

  @override
  void dispose() {
    _playheadTimer?.cancel();
    super.dispose();
  }
}

/// InheritedWidget wrapper so any descendant can call AppState.of(context).
class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({
    super.key,
    required AppState state,
    required super.child,
  }) : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppStateScope>()!.notifier!;
}
