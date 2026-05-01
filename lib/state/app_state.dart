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
  Timer? _previewAutoStopTimer;
  DateTime? _previewStartedAt;
  int _previewDurationMs = 1000;
  bool _playbackFollowsSong = false;
  int _currentArrangementSlotIndex = 0;
  int _playheadArrangementSlot = 0;

  static const int kTicksPerLine = 6;
  int _tickWithinLine = 0; // 0 = row trigger tick, 1–5 = sub-row ticks

  // Per-track 24-byte segments from the last row trigger (for DEL replay).
  List<List<int>> _rowSegments = [];
  // DEL FX: pending delayed notes. tick → {trackIndex → realNoteCmd}.
  final Map<int, Map<int, int>> _pendingDelays = {};

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
  double get currentSamplerPreviewNorm {
    if (_previewSamplerSlot < 0) return 0.0;
    final started = _previewStartedAt;
    if (started == null || _previewDurationMs <= 0) return 0.0;

    final elapsedMs = DateTime.now().difference(started).inMilliseconds;
    final d = _previewDurationMs;
    final mode = instruments[_previewSamplerSlot].sampler.loopMode;

    if (mode == SamplerLoopMode.off) {
      return (elapsedMs / d).clamp(0.0, 1.0);
    }

    final wrapped = elapsedMs % d;
    return (wrapped / d).clamp(0.0, 1.0);
  }

  Future<int?> _estimatePreviewDurationMs(InstrumentModel ins) async {
    final srcPath = ins.sampler.samplePath;
    if (srcPath == null || srcPath.isEmpty) return null;
    final f = File(srcPath);
    if (!f.existsSync()) return null;

    try {
      final bytes = await f.readAsBytes();
      if (bytes.length < 44) return null;

      bool matchAscii(int off, String s) {
        if (off + s.length > bytes.length) return false;
        for (int i = 0; i < s.length; i++) {
          if (bytes[off + i] != s.codeUnitAt(i)) return false;
        }
        return true;
      }

      if (!matchAscii(0, 'RIFF') || !matchAscii(8, 'WAVE')) return null;

      final bd = ByteData.sublistView(bytes);
      int readLe16(int o) => bd.getUint16(o, Endian.little);
      int readLe32(int o) => bd.getUint32(o, Endian.little);

      int channels = 0;
      int sampleRate = 0;
      int bitsPerSample = 0;
      int dataSize = 0;

      int pos = 12;
      while (pos + 8 <= bytes.length) {
        final chunkSize = readLe32(pos + 4);
        final body = pos + 8;
        if (body + chunkSize > bytes.length) break;

        if (matchAscii(pos, 'fmt ') && chunkSize >= 16) {
          channels = readLe16(body + 2);
          sampleRate = readLe32(body + 4);
          bitsPerSample = readLe16(body + 14);
        } else if (matchAscii(pos, 'data')) {
          dataSize = chunkSize;
        }

        pos = body + chunkSize + (chunkSize.isOdd ? 1 : 0);
      }

      if (channels <= 0 || bitsPerSample <= 0 || dataSize <= 0 || sampleRate <= 0) {
        return null;
      }

      final bytesPerSample = bitsPerSample ~/ 8;
      final frameSize = bytesPerSample * channels;
      if (frameSize <= 0) return null;
      final totalFrames = dataSize ~/ frameSize;
      if (totalFrames <= 0) return null;

      final start = ins.sampler.start.clamp(0.0, 1.0);
      final end = ins.sampler.end.clamp(0.0, 1.0);
      final startFrame = (start * (totalFrames - 1)).round().clamp(0, totalFrames - 1);
      final endFrame = (end * totalFrames).round().clamp(startFrame + 1, totalFrames);
      final frames = endFrame - startFrame;
      if (frames <= 0) return null;

      final previewSec = frames / sampleRate;
      final releaseSec = ins.sampler.release.clamp(0.0, 1.0) * 0.5;
      final withTail = previewSec + releaseSec;
      final ms = (withTail * 1000).round();
      return ms.clamp(80, 120000);
    } catch (_) {
      return null;
    }
  }

  Future<void> _schedulePreviewAutoStop(int slot, InstrumentModel ins) async {
    _previewAutoStopTimer?.cancel();
    _previewAutoStopTimer = null;

    final ms = await _estimatePreviewDurationMs(ins);
    if (ms != null) _previewDurationMs = ms;

    if (ins.sampler.loopMode != SamplerLoopMode.off) return;

    if (ms == null) return;

    _previewAutoStopTimer = Timer(Duration(milliseconds: ms), () {
      if (_disposed) return;
      if (_previewSamplerSlot != slot) return;
      stopPreviewCurrentSampler();
    });
  }

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

  int _defaultInstrumentForRow(TrackModel track, int row) {
    // Scan upward for last used instrument, else 01.
    int def = 1;
    for (int r = row - 1; r >= 0; r--) {
      final v = track.cells[r].instrument;
      if (v != null) {
        def = v;
        break;
      }
    }
    return def;
  }

  /// Resets a cell column to its default value (always writes a value).
  void resetColumnToDefault(int row, CellColumn column) {
    final track = currentTrack;
    switch (column) {
      case CellColumn.note:
        track.setNote(row, NoteValue.fromScrollIndex(49)); // C-4
        break;
      case CellColumn.instrument:
        track.writeColumnValue(row, column, _defaultInstrumentForRow(track, row));
        break;
      case CellColumn.volume:
        track.writeColumnValue(row, column, 80);
        break;
      case CellColumn.fx0cmd:
      case CellColumn.fx1cmd:
      case CellColumn.fx2cmd:
        track.writeColumnValue(row, column, 0x00);
        break;
      case CellColumn.fx0val:
      case CellColumn.fx1val:
      case CellColumn.fx2val:
        // Default value depends on the paired cmd: PAN defaults to 50.
        final fxIndex = column == CellColumn.fx0val ? 0
            : column == CellColumn.fx1val ? 1 : 2;
        final cmd = track.cells[row].fxSlots[fxIndex].command;
        track.writeColumnValue(row, column, cmd == kFxPAN ? 50 : 0x00);
        break;
    }
    notifyListeners();
  }

  /// Inserts the column-specific default value into an empty cell.
  void insertDefaultValue(int row, CellColumn column) {
    final track = currentTrack;
    switch (column) {
      case CellColumn.note:
        track.setNote(row, NoteValue.fromScrollIndex(49)); // C-4
      case CellColumn.instrument:
        track.writeColumnValue(row, column, _defaultInstrumentForRow(track, row));
      case CellColumn.volume:
        track.writeColumnValue(row, column, 80);
      case CellColumn.fx0cmd:
      case CellColumn.fx1cmd:
      case CellColumn.fx2cmd:
        track.writeColumnValue(row, column, 0x00);
      case CellColumn.fx0val:
      case CellColumn.fx1val:
      case CellColumn.fx2val:
        final fxIndex = column == CellColumn.fx0val ? 0
            : column == CellColumn.fx1val ? 1 : 2;
        final cmd = track.cells[row].fxSlots[fxIndex].command;
        track.writeColumnValue(row, column, cmd == kFxPAN ? 50 : 0);
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
        _norm01ToAudio255(sp.attack),  // atk  ← sampler attack
        _norm01ToAudio255(0.30), // dec
        _norm01ToAudio255(0.80), // sus
        _norm01ToAudio255(sp.release), // rel  ← sampler release
        _norm01ToAudio255(0.00), // glide
        _norm01ToAudio255(sp.volume), // sampler volume / synth instVol
        _norm01ToAudio255(startNorm), // lfoRate reused as sampler start
        _norm01ToAudio255(endNorm), // lfoDepth reused as sampler end
        0, // lfoTarget: pitch
        sp.loopMode.index, // loop mode: 0=off, 1=forward, 2=pingpong
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
    _tickWithinLine = 1;  // next timer tick is sub-tick 1 (row 0 already fired)
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

  Duration _tickDuration() {
    // One line = kTicksPerLine ticks. Timer fires at tick resolution.
    final microsPerLine = (60000000 / (bpm * linesPerBeat)).round().clamp(
      1000,
      60000000,
    );
    return Duration(microseconds: (microsPerLine / kTicksPerLine).round().clamp(500, 60000000));
  }

  void _startPlayheadTimer() {
    _playheadTimer?.cancel();
    _playheadTimer = Timer.periodic(_tickDuration(), (_) {
      if (!isPlaying) return;
      _onTick();
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

  /// Called every tick (kTicksPerLine times per row).
  void _onTick() {
    if (_tickWithinLine == 0) {
      // Advance row then trigger.
      _advanceRow();
    } else {
      // Sub-row tick: process tick-level FX.
      _processSubTick(_tickWithinLine);
    }
    _tickWithinLine = (_tickWithinLine + 1) % kTicksPerLine;
  }

  void _advanceRow() {
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

  /// Sub-row tick processing: handles tick-level FX (KIL, DEL, etc.).
  void _processSubTick(int tick) {
    final PatternModel pattern;
    if (_playbackFollowsSong && song.arrangement.isNotEmpty) {
      pattern = song.patterns[song.arrangement[_playheadArrangementSlot]];
    } else {
      pattern = currentPattern;
    }

    // KIL: kill note after N ticks.
    final killData = <int>[];
    bool anyKil = false;
    for (final track in pattern.tracks) {
      if (playheadRow >= track.cells.length) { killData.add(0); continue; }
      final cell = track.cells[playheadRow];
      int kil = 0;
      for (final fx in cell.fxSlots) {
        if (fx.command == kFxKIL && fx.value != null) {
          final kilTick = fx.value!.clamp(0, kTicksPerLine - 1);
          if (tick >= kilTick) kil = 1;
          break;
        }
      }
      killData.add(kil);
      if (kil == 1) anyKil = true;
    }
    if (anyKil) AudioEngine.instance.killVoices(killData);

    // DEL: fire delayed notes at their scheduled tick.
    final delayed = _pendingDelays[tick];
    if (delayed != null && _rowSegments.isNotEmpty) {
      final rowData = <int>[];
      for (int t = 0; t < _rowSegments.length; t++) {
        final seg = List<int>.from(_rowSegments[t]);
        seg[0] = delayed[t] ?? -1; // real note if delayed at this tick, else hold
        rowData.addAll(seg);
      }
      AudioEngine.instance.setRowData(rowData);
      _pendingDelays.remove(tick);
    }
  }

  void advancePlayhead() => _advanceRow();

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

    _pendingDelays.clear();
    _rowSegments = [];

    final rowData = <int>[];
    final immediateKillData = <int>[];
    bool anyImmediateKill = false;
    for (int t = 0; t < pattern.tracks.length; t++) {
      final track = pattern.tracks[t];
      var currentSlot = _carryInstrumentByTrack[t];
      int noteCmd = -1;
      int volCmd = -1;
      int panCmd = -1;
      int waveCmd = _waveCodeForInstrumentSlot(currentSlot);
      int instrumentTypeCmd = _instrumentTypeCodeForSlot(currentSlot);
      var synthParams = _synthParamsForInstrumentSlot(currentSlot);
      int delayTick = 0;
      bool immediateKill = false;

      if (playheadRow < track.cells.length) {
        final cell = track.cells[playheadRow];

        if (cell.instrument != null) {
          currentSlot = (cell.instrument! - 1).clamp(0, instruments.length - 1);
          _carryInstrumentByTrack[t] = currentSlot;
          waveCmd = _waveCodeForInstrumentSlot(currentSlot);
          instrumentTypeCmd = _instrumentTypeCodeForSlot(currentSlot);
          synthParams = _synthParamsForInstrumentSlot(currentSlot);
        }

        final note = cell.note;
        final playable = instruments[currentSlot].type != InstrumentType.empty;
        if (note.isOff) {
          noteCmd = -2;
        } else if (note.isNote && playable) {
          noteCmd = note.midiNote;
        }

        if (cell.volume != null) {
          volCmd = ui99ToAudio255(cell.volume!);
        }

        for (final fx in cell.fxSlots) {
          if (fx.command == kFxPAN && fx.value != null) {
            panCmd = ui99ToAudio255(fx.value!.clamp(0, 99));
          }
          if (fx.command == kFxDEL && fx.value != null) {
            delayTick = fx.value!.clamp(0, kTicksPerLine - 1);
          }
          if (fx.command == kFxKIL && (fx.value ?? 0) == 0) {
            immediateKill = true;
          }
        }

        if (playheadRow == 0) {
          if (volCmd == -1) volCmd = ui99ToAudio255(80);
          if (panCmd == -1) panCmd = ui99ToAudio255(50);
        }
      }

      // Build the per-track segment (stride 24) with the real noteCmd.
      final segment = [noteCmd, volCmd, panCmd, waveCmd, instrumentTypeCmd, ...synthParams];
      _rowSegments.add(segment);

      // DEL: if delay > 0 and there's a real note, hold now and fire later.
      final int sentNote;
      if (delayTick > 0 && noteCmd >= 0) {
        _pendingDelays.putIfAbsent(delayTick, () => {})[t] = noteCmd;
        sentNote = -1; // hold at tick 0
      } else {
        sentNote = noteCmd;
      }

      rowData.add(sentNote);
      rowData.add(volCmd);
      rowData.add(panCmd);
      rowData.add(waveCmd);
      rowData.add(instrumentTypeCmd);
      rowData.addAll(synthParams);

      immediateKillData.add(immediateKill ? 1 : 0);
      if (immediateKill) anyImmediateKill = true;
    }

    AudioEngine.instance.setRowData(rowData);
    if (anyImmediateKill) {
      AudioEngine.instance.killVoices(immediateKillData);
    }
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

  /// Chops the current sampler's start→end region into a new WAV file,
  /// places it in the next empty instrument slot as a sampler, and loads it.
  /// Returns null on success, or an error string on failure.
  Future<String?> chopToNewSlot() async {
    final src = currentInstrument.sampler;
    final srcPath = src.samplePath;
    if (srcPath == null || srcPath.isEmpty) return 'No sample loaded';

    // Find next empty slot
    final nextEmpty = instruments.indexWhere(
        (ins) => ins.type == InstrumentType.empty,
        (currentInstrumentIndex + 1) % instruments.length);
    if (nextEmpty < 0) return 'No empty instrument slots available';

    // Read source WAV
    final srcFile = File(srcPath);
    if (!srcFile.existsSync()) return 'Source file not found';
    final bytes = await srcFile.readAsBytes();
    if (bytes.length < 44) return 'Invalid WAV file';

    // Parse WAV header to find data chunk
    bool matchAscii(int off, String s) {
      if (off + s.length > bytes.length) return false;
      for (int i = 0; i < s.length; i++) {
        if (bytes[off + i] != s.codeUnitAt(i)) return false;
      }
      return true;
    }
    if (!matchAscii(0, 'RIFF') || !matchAscii(8, 'WAVE')) {
      return 'Not a WAV file';
    }
    final bd = ByteData.sublistView(bytes);
    int readLe16(int o) => bd.getUint16(o, Endian.little);
    int readLe32(int o) => bd.getUint32(o, Endian.little);

    int audioFormat = 0, channels = 0, sampleRate = 0, bitsPerSample = 0;
    int dataOffset = -1, dataSize = 0;
    int pos = 12;
    while (pos + 8 <= bytes.length) {
      final chunkSize = readLe32(pos + 4);
      final body = pos + 8;
      if (body + chunkSize > bytes.length) break;
      if (matchAscii(pos, 'fmt ') && chunkSize >= 16) {
        audioFormat  = readLe16(body + 0);
        channels     = readLe16(body + 2);
        sampleRate   = readLe32(body + 4);
        bitsPerSample= readLe16(body + 14);
      } else if (matchAscii(pos, 'data')) {
        dataOffset = body;
        dataSize   = chunkSize;
      }
      pos = body + chunkSize + (chunkSize.isOdd ? 1 : 0);
    }
    if (dataOffset < 0 || channels <= 0 || bitsPerSample <= 0 ||
        !(audioFormat == 1 || audioFormat == 3)) {
      return 'Unsupported WAV format';
    }

    final bytesPerSample = bitsPerSample ~/ 8;
    final frameSize = bytesPerSample * channels;
    final totalFrames = dataSize ~/ frameSize;
    if (totalFrames <= 0) return 'Empty audio data';

    // Compute frame range from start/end normalised values
    final startFrame =
        (src.start.clamp(0.0, 1.0) * (totalFrames - 1)).round().clamp(0, totalFrames - 1);
    final endFrame =
        (src.end.clamp(0.0, 1.0) * totalFrames).round().clamp(startFrame + 1, totalFrames);
    final chopFrames = endFrame - startFrame;
    if (chopFrames <= 0) return 'Start/end region is empty';

    // Decode region → mono float, then re-encode as 16-bit PCM WAV
    final outSamples = List<int>.filled(chopFrames, 0); // int16 range
    for (int f = 0; f < chopFrames; f++) {
      final frameOff = dataOffset + (startFrame + f) * frameSize;
      double mono = 0.0;
      for (int ch = 0; ch < channels; ch++) {
        final off = frameOff + ch * bytesPerSample;
        double s = 0.0;
        if (audioFormat == 1 && bitsPerSample == 8) {
          s = (bytes[off] - 128) / 128.0;
        } else if (audioFormat == 1 && bitsPerSample == 16) {
          s = bd.getInt16(off, Endian.little) / 32768.0;
        } else if (audioFormat == 1 && bitsPerSample == 24) {
          int raw = bytes[off] | (bytes[off + 1] << 8) | (bytes[off + 2] << 16);
          if (raw & 0x800000 != 0) raw |= ~0xFFFFFF;
          s = raw / 8388608.0;
        } else if (audioFormat == 3 && bitsPerSample == 32) {
          s = bd.getFloat32(off, Endian.little);
        }
        mono += s;
      }
      final monoVal = (mono / channels).clamp(-1.0, 1.0);
      outSamples[f] = (monoVal * 32767.0).round().clamp(-32768, 32767);
    }

    // Build output WAV (mono 16-bit PCM)
    final outSampleRate = sampleRate;
    final dataBytes = chopFrames * 2; // 16-bit mono
    final wavOut = ByteData(44 + dataBytes);
    void writeFourCC(int off, String s) {
      for (int i = 0; i < 4; i++) wavOut.setUint8(off + i, s.codeUnitAt(i));
    }
    writeFourCC(0, 'RIFF');
    wavOut.setUint32(4, 36 + dataBytes, Endian.little);
    writeFourCC(8, 'WAVE');
    writeFourCC(12, 'fmt ');
    wavOut.setUint32(16, 16, Endian.little);      // chunk size
    wavOut.setUint16(20, 1, Endian.little);       // PCM
    wavOut.setUint16(22, 1, Endian.little);       // mono
    wavOut.setUint32(24, outSampleRate, Endian.little);
    wavOut.setUint32(28, outSampleRate * 2, Endian.little); // byte rate
    wavOut.setUint16(32, 2, Endian.little);       // block align
    wavOut.setUint16(34, 16, Endian.little);      // bits per sample
    writeFourCC(36, 'data');
    wavOut.setUint32(40, dataBytes, Endian.little);
    for (int f = 0; f < chopFrames; f++) {
      wavOut.setInt16(44 + f * 2, outSamples[f], Endian.little);
    }

    // Build output filename: "<srcname>_chop_N.wav"
    final srcName = (src.sampleName ?? srcPath.split(Platform.pathSeparator).last);
    final dot = srcName.lastIndexOf('.');
    final base = dot > 0 ? srcName.substring(0, dot) : srcName;
    final lib = await _songSamplesDir();
    int chopNum = 1;
    String outName;
    do {
      outName = '${base}_chop_$chopNum.wav';
      chopNum++;
    } while (File('${lib.path}/$outName').existsSync());
    final outPath = '${lib.path}/$outName';
    await File(outPath).writeAsBytes(wavOut.buffer.asUint8List(), flush: true);

    // Set up destination slot as sampler with chopped sample
    final destIns = instruments[nextEmpty];
    destIns.type = InstrumentType.sampler;
    destIns.sampler
      ..samplePath   = outPath
      ..sampleName   = outName
      ..pitch        = src.pitch
      ..volume       = src.volume
      ..loopMode     = src.loopMode
      ..start        = 0.0
      ..end          = 1.0
      ..attack       = src.attack
      ..release      = src.release;

    // Load into the engine slot
    await AudioEngine.instance.setSamplerSample(nextEmpty, outPath);

    // Navigate to the new slot
    selectInstrument(nextEmpty);
    _notifyListenersSafe();
    return null;
  }

  /// Crops the current sampler's start→end region into a new WAV file,
  /// replaces the current sampler sample with it, and resets region to full.
  /// Returns null on success, or an error string on failure.
  Future<String?> cropCurrentSamplerToNewSample() async {
    final src = currentInstrument.sampler;
    final srcPath = src.samplePath;
    if (srcPath == null || srcPath.isEmpty) return 'No sample loaded';

    // Read source WAV
    final srcFile = File(srcPath);
    if (!srcFile.existsSync()) return 'Source file not found';
    final bytes = await srcFile.readAsBytes();
    if (bytes.length < 44) return 'Invalid WAV file';

    // Parse WAV header to find data chunk
    bool matchAscii(int off, String s) {
      if (off + s.length > bytes.length) return false;
      for (int i = 0; i < s.length; i++) {
        if (bytes[off + i] != s.codeUnitAt(i)) return false;
      }
      return true;
    }
    if (!matchAscii(0, 'RIFF') || !matchAscii(8, 'WAVE')) {
      return 'Not a WAV file';
    }
    final bd = ByteData.sublistView(bytes);
    int readLe16(int o) => bd.getUint16(o, Endian.little);
    int readLe32(int o) => bd.getUint32(o, Endian.little);

    int audioFormat = 0, channels = 0, sampleRate = 0, bitsPerSample = 0;
    int dataOffset = -1, dataSize = 0;
    int pos = 12;
    while (pos + 8 <= bytes.length) {
      final chunkSize = readLe32(pos + 4);
      final body = pos + 8;
      if (body + chunkSize > bytes.length) break;
      if (matchAscii(pos, 'fmt ') && chunkSize >= 16) {
        audioFormat  = readLe16(body + 0);
        channels     = readLe16(body + 2);
        sampleRate   = readLe32(body + 4);
        bitsPerSample= readLe16(body + 14);
      } else if (matchAscii(pos, 'data')) {
        dataOffset = body;
        dataSize   = chunkSize;
      }
      pos = body + chunkSize + (chunkSize.isOdd ? 1 : 0);
    }
    if (dataOffset < 0 || channels <= 0 || bitsPerSample <= 0 ||
        !(audioFormat == 1 || audioFormat == 3)) {
      return 'Unsupported WAV format';
    }

    final bytesPerSample = bitsPerSample ~/ 8;
    final frameSize = bytesPerSample * channels;
    final totalFrames = dataSize ~/ frameSize;
    if (totalFrames <= 0) return 'Empty audio data';

    // Compute frame range from start/end normalised values
    final startFrame =
        (src.start.clamp(0.0, 1.0) * (totalFrames - 1)).round().clamp(0, totalFrames - 1);
    final endFrame =
        (src.end.clamp(0.0, 1.0) * totalFrames).round().clamp(startFrame + 1, totalFrames);
    final cropFrames = endFrame - startFrame;
    if (cropFrames <= 0) return 'Start/end region is empty';

    // Decode region → mono float, then re-encode as 16-bit PCM WAV
    final outSamples = List<int>.filled(cropFrames, 0);
    for (int f = 0; f < cropFrames; f++) {
      final frameOff = dataOffset + (startFrame + f) * frameSize;
      double mono = 0.0;
      for (int ch = 0; ch < channels; ch++) {
        final off = frameOff + ch * bytesPerSample;
        double s = 0.0;
        if (audioFormat == 1 && bitsPerSample == 8) {
          s = (bytes[off] - 128) / 128.0;
        } else if (audioFormat == 1 && bitsPerSample == 16) {
          s = bd.getInt16(off, Endian.little) / 32768.0;
        } else if (audioFormat == 1 && bitsPerSample == 24) {
          int raw = bytes[off] | (bytes[off + 1] << 8) | (bytes[off + 2] << 16);
          if (raw & 0x800000 != 0) raw |= ~0xFFFFFF;
          s = raw / 8388608.0;
        } else if (audioFormat == 3 && bitsPerSample == 32) {
          s = bd.getFloat32(off, Endian.little);
        }
        mono += s;
      }
      final monoVal = (mono / channels).clamp(-1.0, 1.0);
      outSamples[f] = (monoVal * 32767.0).round().clamp(-32768, 32767);
    }

    // Build output WAV (mono 16-bit PCM)
    final dataBytes = cropFrames * 2;
    final wavOut = ByteData(44 + dataBytes);
    void writeFourCC(int off, String s) {
      for (int i = 0; i < 4; i++) wavOut.setUint8(off + i, s.codeUnitAt(i));
    }
    writeFourCC(0, 'RIFF');
    wavOut.setUint32(4, 36 + dataBytes, Endian.little);
    writeFourCC(8, 'WAVE');
    writeFourCC(12, 'fmt ');
    wavOut.setUint32(16, 16, Endian.little);
    wavOut.setUint16(20, 1, Endian.little);
    wavOut.setUint16(22, 1, Endian.little);
    wavOut.setUint32(24, sampleRate, Endian.little);
    wavOut.setUint32(28, sampleRate * 2, Endian.little);
    wavOut.setUint16(32, 2, Endian.little);
    wavOut.setUint16(34, 16, Endian.little);
    writeFourCC(36, 'data');
    wavOut.setUint32(40, dataBytes, Endian.little);
    for (int f = 0; f < cropFrames; f++) {
      wavOut.setInt16(44 + f * 2, outSamples[f], Endian.little);
    }

    // Build output filename: "<srcname>_crop_N.wav"
    final srcName = (src.sampleName ?? srcPath.split(Platform.pathSeparator).last);
    final dot = srcName.lastIndexOf('.');
    final base = dot > 0 ? srcName.substring(0, dot) : srcName;
    final projectDir = await _songSamplesDir();
    int cropNum = 1;
    String outName;
    do {
      outName = '${base}_crop_$cropNum.wav';
      cropNum++;
    } while (File('${projectDir.path}/$outName').existsSync());

    final outPath = '${projectDir.path}/$outName';
    await File(outPath).writeAsBytes(wavOut.buffer.asUint8List(), flush: true);

    // Replace current sampler sample with the crop.
    src
      ..samplePath = outPath
      ..sampleName = outName
      ..start = 0.0
      ..end = 1.0;

    await AudioEngine.instance.setSamplerSample(currentInstrumentIndex, outPath);
    _notifyListenersSafe();
    return null;
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
      _previewStartedAt = DateTime.now();
      notifyListeners();
      await _schedulePreviewAutoStop(slot, ins);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> stopPreviewCurrentSampler() async {
    _previewAutoStopTimer?.cancel();
    _previewAutoStopTimer = null;
    _previewStartedAt = null;

    final slot = (_previewSamplerSlot >= 0 ? _previewSamplerSlot : currentInstrumentIndex)
        .clamp(0, instruments.length - 1);
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
    _previewAutoStopTimer?.cancel();
    _previewAutoStopTimer = null;
    _previewStartedAt = null;
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

  Future<Directory> _songSamplesDir([String? songName]) async {
    final dir = await _songsDir();
    final raw = songName ?? song.name;
    final slug = _slugify(raw);
    final safe = slug.isEmpty ? 'untitled' : slug;
    final d = Directory('${dir.path}/${safe}_samples');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  String _sanitizeFileStem(String stem) {
    final cleaned = stem
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
    return cleaned.isEmpty ? 'sample' : cleaned;
  }

  Future<void> _persistSamplerAssetsForSong() async {
    final projectDir = await _songSamplesDir();
    final projectRoot = '${projectDir.path}${Platform.pathSeparator}';

    for (var i = 0; i < instruments.length; i++) {
      final ins = instruments[i];
      if (ins.type != InstrumentType.sampler) continue;

      final srcPath = ins.sampler.samplePath;
      if (srcPath == null || srcPath.isEmpty) continue;

      final src = File(srcPath);
      if (!src.existsSync()) continue;

      final absSrc = src.absolute.path;
      if (absSrc.startsWith(projectRoot)) {
        ins.sampler.sampleName = absSrc.split(Platform.pathSeparator).last;
        continue;
      }

      final srcName = ins.sampler.sampleName ??
          absSrc.split(Platform.pathSeparator).last;
      final dot = srcName.lastIndexOf('.');
      final stem = _sanitizeFileStem(dot > 0 ? srcName.substring(0, dot) : srcName);
      final ext = dot > 0 ? srcName.substring(dot) : '.wav';

      var candidate = '$stem$ext';
      var n = 2;
      while (File('${projectDir.path}/$candidate').existsSync()) {
        candidate = '${stem}_$n$ext';
        n++;
      }

      final dstPath = '${projectDir.path}/$candidate';
      await src.copy(dstPath);
      ins.sampler.samplePath = dstPath;
      ins.sampler.sampleName = candidate;
      await AudioEngine.instance.setSamplerSample(i, dstPath);
    }
  }

  void renameSong(String name) {
    song.name = name;
    _notifyListenersSafe();
  }

  /// Save to disk using song.name as the filename. Overwrites existing.
  Future<bool> saveSong() async {
    try {
      // Keep app-managed local copies of used sampler files for this song.
      await _persistSamplerAssetsForSong();
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
    _previewAutoStopTimer?.cancel();
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
