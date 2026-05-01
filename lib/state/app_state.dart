import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import '../audio/audio_engine.dart';
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
  bool _disposed = false;
  bool _notifyQueued = false;
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
  int _currentTrackIndex = 0;
  int _currentInstrumentIndex = 0;
  int _previewSamplerSlot = -1;

  CellPosition? selectedCell;

  TrackerCell? _rowClipboard;
  bool get hasRowClipboard => _rowClipboard != null;

  // Playback carry state for IN column per track.
  List<int> _carryInstrumentByTrack = const [];
  int _carryPatternIndex = -1;

  bool isPlaying = false;
  bool isRecording = false;
  int playheadRow = 0;

  /// When true, all tracks are visible side-by-side showing only
  /// NOTE + INST columns. When false, only the current track is
  /// visible (full columns) via swipe-paging.
  bool collapsedView = false;

  // ── Getters ──────────────────────────────────────────────────────────────

  int get currentPatternIndex => _currentPatternIndex;
  int get currentTrackIndex => _currentTrackIndex;
  int get currentInstrumentIndex => _currentInstrumentIndex;
  int get currentArrangementSlotIndex => _currentArrangementSlotIndex;
  int get playheadArrangementSlot => _playheadArrangementSlot;
  bool get playbackFollowsSong => _playbackFollowsSong;
  bool get isPreviewingCurrentSampler => _previewSamplerSlot == _currentInstrumentIndex;

  PatternModel get currentPattern => song.patterns[_currentPatternIndex];
  TrackModel get currentTrack => currentPattern.tracks[_currentTrackIndex];
  InstrumentModel get currentInstrument => instruments[_currentInstrumentIndex];

  double get bpm => currentPattern.bpm ?? 120.0;
  int get beats => currentPattern.beatCount;
  int get linesPerBeat => currentPattern.lpb;
  int get rowCount => currentPattern.rowCount;
  int get trackCount => currentPattern.tracks.length;
  bool get canChangePatternLength => currentPattern.isEmpty;

  // ── Navigation ───────────────────────────────────────────────────────────

  void selectPattern(int index) {
    _currentPatternIndex = index.clamp(0, song.patterns.length - 1);
    _currentTrackIndex = 0;
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
        // scan upward for last used instrument, else 01
        int def = 1;
        for (int r = row - 1; r >= 0; r--) {
          final v = track.cells[r].instrument;
          if (v != null) {
            def = v;
            break;
          }
        }
        track.writeColumnValue(row, column, def);
      case CellColumn.volume:
        track.writeColumnValue(row, column, 80);
      case CellColumn.pan:
        track.writeColumnValue(row, column, 50);
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
      slotIndex + 1,
      song.arrangementMutes[slotIndex],
    );
    notifyListeners();
  }

  /// Duplicate a pattern: create a brand-new pattern with copied content,
  /// append a slot at the end of the arrangement referring to it.
  /// The new pattern has its own number and is independent.
  void duplicatePatternToEnd(int sourcePatternIndex) {
    if (sourcePatternIndex < 0 || sourcePatternIndex >= song.patterns.length) {
      return;
    }
    final src = song.patterns[sourcePatternIndex];
    final newIdx = song.patterns.length + 1;
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
        song.patterns[i].name = 'PAT ${(i + 1).toString().padLeft(2, '0')}';
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
    if (to < 0 || to >= song.arrangement.length) return;
    final p = song.arrangement.removeAt(from);
    final m = song.arrangementMutes.removeAt(from);
    song.arrangement.insert(to, p);
    song.arrangementMutes.insert(to, m);
    notifyListeners();
  }

  void toggleArrangementMute(int slotIndex) {
    if (slotIndex < 0 || slotIndex >= song.arrangementMutes.length) return;
    song.arrangementMutes[slotIndex] = !song.arrangementMutes[slotIndex];
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
        _playheadArrangementSlot = _currentArrangementSlotIndex.clamp(
          0,
          song.arrangement.length - 1,
        );
        _syncCurrentPatternToSongPlayhead();
        playheadRow = 0;
      }
      _restartPlayheadTimerIfNeeded();
    }
    notifyListeners();
  }

  // ── Transport ────────────────────────────────────────────────────────────

  int _waveCodeForInstrumentSlot(int slot) {
    final safe = slot.clamp(0, instruments.length - 1);
    final ins = instruments[safe];
    // For sampler instruments we encode the instrument slot index here.
    // Native interprets this as sample-slot id when instrumentType=1.
    if (ins.type != InstrumentType.simpleSynth) return safe;
    switch (ins.synth.wave) {
      case SynthWave.sine:
        return 0;
      case SynthWave.triangle:
        return 1;
      case SynthWave.saw:
        return 2;
      case SynthWave.square:
        return 3;
      case SynthWave.pulse:
        return 4;
      case SynthWave.noise:
        return 5;
    }
  }

  int _instrumentTypeCodeForSlot(int slot) {
    final safe = slot.clamp(0, instruments.length - 1);
    return instruments[safe].type == InstrumentType.sampler ? 1 : 0;
  }

  int _norm01ToAudio255(double v) => (v.clamp(0.0, 1.0) * 255.0).round();

  List<int> _synthParamsForInstrumentSlot(int slot) {
    final safe = slot.clamp(0, instruments.length - 1);
    final ins = instruments[safe];
    if (ins.type != InstrumentType.simpleSynth) {
      final sp = ins.sampler;
      final detuneNorm = ((sp.pitch + 1.0) / 2.0).clamp(0.0, 1.0);
      final startNorm = sp.start.clamp(0.0, 1.0);
      final endNorm = sp.end.clamp(0.0, 1.0);
      return <int>[
        _norm01ToAudio255(detuneNorm), // sampler pitch / synth detune
        _norm01ToAudio255(0.70), // cutoff
        _norm01ToAudio255(0.20), // resonance
        0, // filterMode: LP
        _norm01ToAudio255(0.01), // filterAtk
        _norm01ToAudio255(0.25), // filterDec
        _norm01ToAudio255(0.00), // filterSus
        _norm01ToAudio255(0.25), // filterRel
        _norm01ToAudio255(0.50), // filterAmt
        _norm01ToAudio255(0.02), // atk
        _norm01ToAudio255(0.30), // dec
        _norm01ToAudio255(0.80), // sus
        _norm01ToAudio255(0.25), // rel
        _norm01ToAudio255(0.00), // glide
        _norm01ToAudio255(sp.volume), // sampler volume / synth instVol
        _norm01ToAudio255(startNorm), // lfoRate reused as sampler start
        _norm01ToAudio255(endNorm), // lfoDepth reused as sampler end
        0, // lfoTarget: pitch
        sp.loop ? 255 : 0, // loop flag (reuses drive byte for sampler)
      ];
    }
    final p = ins.synth;
    return <int>[
      _norm01ToAudio255((p.detune + 1.0) / 2.0), // map -1..1 → 0..1
      _norm01ToAudio255(p.cutoff),
      _norm01ToAudio255(p.resonance),
      p.filterMode.index2,
      _norm01ToAudio255(p.filterAttack),
      _norm01ToAudio255(p.filterDecay),
      _norm01ToAudio255(p.filterSustain),
      _norm01ToAudio255(p.filterRelease),
      _norm01ToAudio255(p.filterEnvAmt),
      _norm01ToAudio255(p.attack),
      _norm01ToAudio255(p.decay),
      _norm01ToAudio255(p.sustain),
      _norm01ToAudio255(p.release),
      _norm01ToAudio255(p.glide),
      _norm01ToAudio255(p.volume),
      _norm01ToAudio255(p.lfoRate),
      _norm01ToAudio255(p.lfoDepth),
      p.lfoTarget.index2,
      _norm01ToAudio255(p.drive),
    ];
  }

  void _resetInstrumentCarry() {
    _carryInstrumentByTrack = const [];
    _carryPatternIndex = -1;
  }

  void play() {
    if (isPlaying) return;
    if (_playbackFollowsSong && song.arrangement.isNotEmpty) {
      _playheadArrangementSlot = _currentArrangementSlotIndex.clamp(
        0,
        song.arrangement.length - 1,
      );
      _syncCurrentPatternToSongPlayhead();
      playheadRow = 0;
    }
    _resetInstrumentCarry();
    isPlaying = true;
    AudioEngine.instance.start();
    _triggerCurrentRow(); // fire row 0 immediately
    _startPlayheadTimer();
    notifyListeners();
  }

  void stop() {
    _playheadTimer?.cancel();
    _playheadTimer = null;
    isPlaying = false;
    playheadRow = 0;
    _resetInstrumentCarry();
    AudioEngine.instance.stop();
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
    final microsPerLine = (60000000 / (bpm * linesPerBeat)).round().clamp(
      1000,
      60000000,
    );
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
    _triggerCurrentRow();
    notifyListeners();
  }

  /// Reads the current row from all tracks in the playing pattern and
  /// sends packed note/volume/pan/wave + synth params to the audio engine.
  void _triggerCurrentRow() {
    int ui99ToAudio255(int v) => ((v.clamp(0, 99) * 255) / 99).round();

    final PatternModel pattern;
    final int patternIdx;
    if (_playbackFollowsSong && song.arrangement.isNotEmpty) {
      patternIdx = song.arrangement[_playheadArrangementSlot];
      pattern = song.patterns[patternIdx];
    } else {
      patternIdx = _currentPatternIndex;
      pattern = currentPattern;
    }

    if (_carryPatternIndex != patternIdx ||
        _carryInstrumentByTrack.length != pattern.tracks.length ||
        playheadRow == 0) {
      _carryPatternIndex = patternIdx;
      _carryInstrumentByTrack = List<int>.filled(pattern.tracks.length, 0);
    }

    final rowData = <int>[];
    for (int t = 0; t < pattern.tracks.length; t++) {
      final track = pattern.tracks[t];
      var currentSlot = _carryInstrumentByTrack[t];
      int noteCmd = -1;
      int volCmd = -1;
      int panCmd = -1;
      int waveCmd = _waveCodeForInstrumentSlot(currentSlot);
      int instrumentTypeCmd = _instrumentTypeCodeForSlot(currentSlot);
      var synthParams = _synthParamsForInstrumentSlot(currentSlot);

      if (playheadRow < track.cells.length) {
        final cell = track.cells[playheadRow];

        if (cell.instrument != null) {
          // IN column stores 1-based (01 = first instrument); convert to 0-based slot.
          currentSlot = (cell.instrument! - 1).clamp(0, instruments.length - 1);
          _carryInstrumentByTrack[t] = currentSlot;
          waveCmd = _waveCodeForInstrumentSlot(currentSlot);
          instrumentTypeCmd = _instrumentTypeCodeForSlot(currentSlot);
          synthParams = _synthParamsForInstrumentSlot(currentSlot);
        }

        // Emit note events for both synth and sampler. Native chooses playback
        // mode based on instrumentTypeCmd.
        final note = cell.note;
        if (note.isOff) {
          noteCmd = -2;
        } else if (note.isNote) {
          noteCmd = note.midiNote;
        }

        if (cell.volume != null) {
          volCmd = ui99ToAudio255(cell.volume!);
        }

        if (cell.pan != null) {
          panCmd = ui99ToAudio255(cell.pan!);
        }

        // At pattern start, reset carry values to defaults if first row is empty.
        if (playheadRow == 0) {
          if (volCmd == -1) volCmd = ui99ToAudio255(80);
          if (panCmd == -1) panCmd = ui99ToAudio255(50);
        }
      }

      rowData.add(noteCmd);
      rowData.add(volCmd);
      rowData.add(panCmd);
      rowData.add(waveCmd);
      rowData.add(instrumentTypeCmd);
      rowData.addAll(synthParams);
    }

    // Fire and forget — no await needed
    AudioEngine.instance.setRowData(rowData);
  }

  void _syncCurrentPatternToSongPlayhead() {
    if (song.arrangement.isEmpty) return;
    final idx = song.arrangement[_playheadArrangementSlot].clamp(
      0,
      song.patterns.length - 1,
    );
    _currentPatternIndex = idx;
    _clampSelectionToPattern();
  }

  // ── Sampler library ───────────────────────────────────────────────────────

  static const _kSamplerExts = <String>{
    '.wav', '.aif', '.aiff', '.flac', '.ogg', '.mp3', '.m4a', '.aac'
  };

  Future<Directory> samplerLibraryDir() async {
    final base = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/samples');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Future<String> samplerLibraryPath() async => (await samplerLibraryDir()).path;

  Future<List<String>> listSamplerLibrarySamples() async {
    try {
      final d = await samplerLibraryDir();
      final names = d
          .listSync()
          .whereType<File>()
          .map((f) => f.path.split(Platform.pathSeparator).last)
          .where((n) {
            final dot = n.lastIndexOf('.');
            if (dot < 0) return false;
            return _kSamplerExts.contains(n.substring(dot).toLowerCase());
          })
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return names;
    } catch (_) {
      return [];
    }
  }

  Future<String?> importSampleToLibrary(String sourcePath) async {
    try {
      final src = File(sourcePath);
      if (!src.existsSync()) return null;
      final lib = await samplerLibraryDir();

      final srcName = sourcePath.split(Platform.pathSeparator).last;
      final dot = srcName.lastIndexOf('.');
      final base = dot > 0 ? srcName.substring(0, dot) : srcName;
      final ext = dot > 0 ? srcName.substring(dot) : '';

      String candidate = srcName;
      var i = 2;
      while (File('${lib.path}/$candidate').existsSync()) {
        candidate = '${base}_$i$ext';
        i++;
      }
      await src.copy('${lib.path}/$candidate');
      return candidate;
    } catch (_) {
      return null;
    }
  }

  /// Import raw bytes (from content-URI file_picker result) into the library.
  Future<String?> importSampleBytesToLibrary(
    Uint8List bytes,
    String originalName,
  ) async {
    try {
      final lib = await samplerLibraryDir();
      final dot = originalName.lastIndexOf('.');
      final base = dot > 0 ? originalName.substring(0, dot) : originalName;
      final ext = dot > 0 ? originalName.substring(dot) : '';

      String candidate = originalName;
      var i = 2;
      while (File('${lib.path}/$candidate').existsSync()) {
        candidate = '${base}_$i$ext';
        i++;
      }
      await File('${lib.path}/$candidate').writeAsBytes(bytes, flush: true);
      return candidate;
    } catch (_) {
      return null;
    }
  }

  Future<String?> loadSamplerSampleFromPath(
    String path, {
    String? displayName,
  }) async {
    try {
      final file = File(path);
      if (!file.existsSync()) return 'File not found';

      if (isPreviewingCurrentSampler) {
        await stopPreviewCurrentSampler();
      }

      final ok = await AudioEngine.instance.setSamplerSample(
        currentInstrumentIndex,
        file.path,
      );
      if (!ok) {
        return 'Unsupported audio format (need WAV 8/16/24-bit PCM or 32-bit float)';
      }

      final sp = currentInstrument.sampler;
      sp.sampleName =
          displayName ?? file.path.split(Platform.pathSeparator).last;
      sp.samplePath = file.path;
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// Returns empty string on success, or an error description on failure.
  Future<String?> loadSamplerSampleFromLibrary(String fileName) async {
    try {
      final lib = await samplerLibraryDir();
      final file = File('${lib.path}/$fileName');
      if (!file.existsSync()) return 'File not found in library';

      return await loadSamplerSampleFromPath(file.path, displayName: fileName);
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> startPreviewCurrentSampler() async {
    try {
      final slot = currentInstrumentIndex.clamp(0, instruments.length - 1);
      final ins = instruments[slot];
      if (ins.type != InstrumentType.sampler) {
        return 'Current instrument is not a sampler';
      }
      if (ins.sampler.samplePath == null || ins.sampler.samplePath!.isEmpty) {
        return 'No sample loaded';
      }

      final waveCmd = _waveCodeForInstrumentSlot(slot);
      final instrumentTypeCmd = _instrumentTypeCodeForSlot(slot);
      final synthParams = _synthParamsForInstrumentSlot(slot);

      final noteOn = <int>[60, 255, 128, waveCmd, instrumentTypeCmd, ...synthParams];

      await AudioEngine.instance.start();
      await AudioEngine.instance.setRowData(noteOn);
      _previewSamplerSlot = slot;
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> stopPreviewCurrentSampler() async {
    final slot = currentInstrumentIndex.clamp(0, instruments.length - 1);
    final waveCmd = _waveCodeForInstrumentSlot(slot);
    final instrumentTypeCmd = _instrumentTypeCodeForSlot(slot);
    final synthParams = _synthParamsForInstrumentSlot(slot);
    final noteOff = <int>[-2, -1, -1, waveCmd, instrumentTypeCmd, ...synthParams];
    await AudioEngine.instance.setRowData(noteOff);
    _previewSamplerSlot = -1;
    notifyListeners();
  }

  Future<String?> togglePreviewCurrentSampler() async {
    try {
      if (isPreviewingCurrentSampler) {
        await stopPreviewCurrentSampler();
        return null;
      }
      if (_previewSamplerSlot >= 0) {
        await stopPreviewCurrentSampler();
      }
      return await startPreviewCurrentSampler();
    } catch (e) {
      return e.toString();
    }
  }

  void clearCurrentSamplerSample() {
    if (isPreviewingCurrentSampler) {
      stopPreviewCurrentSampler();
    }
    final sp = currentInstrument.sampler;
    sp.sampleName = null;
    sp.samplePath = null;
    AudioEngine.instance.setSamplerSample(currentInstrumentIndex, null);
    notifyListeners();
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  void _notifyListenersSafe() {
    if (_disposed) return;
    if (_notifyQueued) return;
    _notifyQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notifyQueued = false;
      if (!_disposed) notifyListeners();
    });
    // Ensure a frame is scheduled even if we're currently idle.
    SchedulerBinding.instance.scheduleFrame();
  }

  static String _slugify(String name) => name
      .trim()
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '')
      .replaceAll(RegExp(r'\s+'), '_')
      .toLowerCase();

  Future<Directory> _songsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/songs');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Future<File> _songFile(String name) async {
    final dir = await _songsDir();
    return File('${dir.path}/${_slugify(name)}.json');
  }

  void renameSong(String name) {
    song.name = name;
    _notifyListenersSafe();
  }

  /// Save to disk using song.name as the filename. Overwrites existing.
  Future<bool> saveSong() async {
    try {
      final payload = jsonEncode({
        'song': song.toJson(),
        'instruments': instruments.map((i) => i.toJson()).toList(),
      });
      await (await _songFile(song.name)).writeAsString(payload);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Returns the display names of all saved songs, sorted alphabetically.
  Future<List<String>> listSavedSongs() async {
    try {
      final dir = await _songsDir();
      final files = dir.listSync().whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      final names = <String>[];
      for (final f in files) {
        try {
          final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
          final n = (j['song'] as Map<String, dynamic>?)?['name'] as String?;
          if (n != null) names.add(n);
        } catch (_) {}
      }
      return names..sort();
    } catch (_) {
      return [];
    }
  }

  /// Load a song by its display name.
  Future<bool> loadSongByName(String name) async {
    try {
      final file = await _songFile(name);
      if (!file.existsSync()) return false;
      final raw = await file.readAsString();
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final loadedSong =
          SongModel.fromJson(j['song'] as Map<String, dynamic>);
      final loadedInstruments = (j['instruments'] as List<dynamic>)
          .map((e) => InstrumentModel.fromJson(e as Map<String, dynamic>))
          .toList();
      song = loadedSong;
      for (var i = 0;
          i < instruments.length && i < loadedInstruments.length;
          i++) {
        instruments[i] = loadedInstruments[i];
      }
      for (var i = 0; i < instruments.length; i++) {
        final ins = instruments[i];
        if (ins.type == InstrumentType.sampler) {
          await AudioEngine.instance.setSamplerSample(i, ins.sampler.samplePath);
        }
      }
      _currentPatternIndex = 0;
      _currentTrackIndex = 0;
      _currentArrangementSlotIndex = 0;
      selectedCell = null;
      _notifyListenersSafe();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
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
