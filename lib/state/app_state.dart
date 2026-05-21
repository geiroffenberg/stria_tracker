import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../audio/audio_engine.dart';
import '../audio/wav_encoder.dart';
import '../models/cell.dart';
import '../models/fx_envelope_run.dart';
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

class CellBoxSelection {
  final int trackIndex;
  final int anchorRow;
  final CellColumn anchorColumn;
  final int focusRow;
  final CellColumn focusColumn;

  const CellBoxSelection({
    required this.trackIndex,
    required this.anchorRow,
    required this.anchorColumn,
    required this.focusRow,
    required this.focusColumn,
  });

  int get minRow => math.min(anchorRow, focusRow);
  int get maxRow => math.max(anchorRow, focusRow);
  int get minColumnIndex => math.min(anchorColumn.index, focusColumn.index);
  int get maxColumnIndex => math.max(anchorColumn.index, focusColumn.index);

  bool contains(int track, int row, CellColumn column) {
    if (track != trackIndex) return false;
    return row >= minRow &&
        row <= maxRow &&
        column.index >= minColumnIndex &&
        column.index <= maxColumnIndex;
  }

  CellBoxSelection copyWith({int? focusRow, CellColumn? focusColumn}) =>
      CellBoxSelection(
        trackIndex: trackIndex,
        anchorRow: anchorRow,
        anchorColumn: anchorColumn,
        focusRow: focusRow ?? this.focusRow,
        focusColumn: focusColumn ?? this.focusColumn,
      );
}

/// Central application state — passed down via InheritedNotifier.
class _ScheduledPlaybackRow {
  final List<int> rowData;
  final List<int> immediateKillMask;
  final List<int> retrigData;
  final List<int> arpData;
  final List<int> delayData;
  final List<int> killData;
  final List<int> sliceCommandData;
  final List<int> mixerCommandData;
  final List<int> insertFxCommandData;
  /// Linear pitch ramp commands for SLU/SLD: [trackIdx, targetMidiNote, durationSamples, ...].
  final List<int> pitchRampData;
  final int lineSamples;

  const _ScheduledPlaybackRow({
    required this.rowData,
    required this.immediateKillMask,
    required this.retrigData,
    required this.arpData,
    required this.delayData,
    required this.killData,
    required this.sliceCommandData,
    required this.mixerCommandData,
    required this.insertFxCommandData,
    required this.pitchRampData,
    required this.lineSamples,
  });
}

class AppState extends ChangeNotifier {
  static const int _audioVoiceCount = kMaxTracks;
  static const int _audioRowStride = 42;

  AppState() {
    _loadAppSettings();
  }

  SongModel song = SongModel.initial();
  bool _disposed = false;
  bool _notifyQueued = false;
  bool _playheadPollInFlight = false;
  bool _songPollInFlight = false;
  Timer? _playheadTimer;
  Timer?
  _previewAutoStopTimer; // Polls C++ voice state at 50ms intervals (vs one-shot estimate)
  Timer?
  _synthPreviewStopTimer; // Sends note-off after hold time, then polls for voice idle
  DateTime? _previewStartedAt;
  int _previewDurationMs = 1000;
  double? _previewRegionStartNorm;
  double? _previewRegionEndNorm;
  bool _playbackFollowsSong = false;
  int _currentArrangementSlotIndex = 0;
  int _playheadArrangementSlot = 0;
  int? _queuedArrangementSlot;
  Completer<void>?
  _exportCompleter; // non-null while a WAV export is in progress

  // Song mode native queue tracking.
  List<({int arrangementSlot, int rowWithinSlot})> _songRowMap = [];
  int _songFlatRowIndex = 0;

  // Per-track segments from the last row trigger (for DEL replay).
  List<List<int>> _rowSegments = [];

  /// Instrument bank — fixed length, indexed by the cell's instrument byte.
  final List<InstrumentModel> instruments = List.generate(
    kInstrumentSlots,
    (i) => InstrumentModel.empty(i + 1),
  );

  // Per-track insert slot occupancy, used by the FX command picker.
  // Indexed as [trackIdx][slotIdx]. Grows on demand.
  final List<List<bool>> _trackInsertOccupied = [];
  // Per-track insert effect names (e.g. DELAY, REVERB) for slot-specific UI labels/hints.
  final List<List<String?>> _trackInsertEffectNames = [];

  // Pending insert reset requests from pattern F[S]0 commands.
  // Drained by mixer_screen listener to re-send current slider values to native.
  final List<(int, int)> _pendingInsertResets = [];

  Map<String, dynamic> _insertSnapshot = {};

  // Per-pattern "last" values for the pattern editor.
  // Key: patternIndex; Value: (lastNote, lastVolume, lastInstrument, lastFx, lastFxValue)
  final Map<int, ({String note, int volume, int instrument, int fxCommand, int fxValue})> _patternLastValues = {};

  int _songStateVersion = 0;

  int _currentPatternIndex = 0;
  int _currentTrackIndex = 0;
  int _currentInstrumentIndex = 0;
  int _previewSamplerSlot = -1;
  int _previewBypassVoice = -1;
  String? _defaultSampleFolder;
  String? _projectRootFolder;
  String? _projectRootTreeUri;
  String? _lastLoadError;
  bool _autosaveEnabled = false;
  Timer? _autosaveTimer;
  Timer? _instrumentParamRebuildTimer;
  bool _liveRebuildInFlight = false;
  // Tracks the active navigation tab (0=SONG, 1=PATTERN, 2=INST, 3=MIXER).
  // Used by play() to determine song-follow vs pattern-loop mode.
  int _activeTabIndex = 1; // default matches MainScreen's initial _tabIndex

  static const String kDefaultProjectsFolderName = 'STRIA_PROJECTS';
  static const MethodChannel _projectStorageChannel = MethodChannel(
    'project_storage',
  );

  CellPosition? selectedCell;
  int? _selectedRowStart;
  int? _selectedRowEnd;
  int? get selectedRow =>
      _selectedRowStart; // For backward compat with single-row ops
  bool isRowInSelection(int row) {
    if (_selectedRowStart == null || _selectedRowEnd == null) return false;
    final min = _selectedRowStart!;
    final max = _selectedRowEnd!;
    return row >= (min <= max ? min : max) && row <= (min <= max ? max : min);
  }

  int get selectedRowCount {
    if (_selectedRowStart == null || _selectedRowEnd == null) return 0;
    final min = _selectedRowStart!;
    final max = _selectedRowEnd!;
    return (min <= max ? max - min : min - max) + 1;
  }

  /// Returns (minRow, maxRow) tuple of selected range, or null if nothing selected.
  (int, int)? get selectedRowRange {
    if (_selectedRowStart == null || _selectedRowEnd == null) return null;
    final min = _selectedRowStart!;
    final max = _selectedRowEnd!;
    return min <= max ? (min, max) : (max, min);
  }

  CellBoxSelection? _boxSelection;
  bool _isBoxSelecting = false;
  CellBoxSelection? get boxSelection => _boxSelection;
  bool get hasBoxSelection => _boxSelection != null;
  bool get isBoxSelecting => _isBoxSelecting;
  int get boxSelectionCellCount {
    final sel = _boxSelection;
    if (sel == null) return 0;
    final rows = (sel.maxRow - sel.minRow) + 1;
    final cols = (sel.maxColumnIndex - sel.minColumnIndex) + 1;
    return rows * cols;
  }

  List<TrackerCell>? _rowClipboard;
  bool get hasRowClipboard =>
      _rowClipboard != null && _rowClipboard!.isNotEmpty;

  // Playback carry state for IN column per track.
  List<int> _carryInstrumentByTrack = const [];
  List<int?> _carryNoteByTrack = const [];
  List<int?> _carryVolumeByTrack = const [];
  List<double?> _carryVibSpeedByTrack = const [];
  List<double?> _carryVibDepthByTrack = const [];
  List<int?> _carryVolFxByTrack = const [];
  List<int?> _carryPanFxByTrack = const [];
  List<double?> _carryTreSpeedByTrack = const [];
  List<double?> _carryTreDepthByTrack = const [];
  List<int?> _carryTreModeByTrack = const [];
  List<({List<int> cycle, int notesPerLine, int phase})?> _carryArpByTrack =
      const [];
  // Per-track pitch-slide carry (SLU/SLD).
  List<({int startNote, int endNote, int totalLines, int linesElapsed})?> _carrySlideByTrack = const [];
  // Per-track Pxx automation carries: map of param-index → raw 00-99 value.
  List<Map<int, int>> _carryInstrumentParamsByTrack = const [];
  int _carryPatternIndex = -1;

  bool isPlaying = false;
  bool isRecording = false;
  bool _loopPlaybackEnabled = false;
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
  int? get queuedArrangementSlot => _queuedArrangementSlot;
  bool get playbackFollowsSong => _playbackFollowsSong;
  bool get loopPlaybackEnabled => _loopPlaybackEnabled;
  bool get isPreviewingCurrentSampler =>
      _previewSamplerSlot == _currentInstrumentIndex;
  String? get defaultSampleFolder => _defaultSampleFolder;
  String? get projectRootFolder => _projectRootFolder;
  String? get projectRootTreeUri => _projectRootTreeUri;
  String? get lastLoadError => _lastLoadError;
  bool get hasProjectRootFolder =>
      (_projectRootFolder != null && _projectRootFolder!.isNotEmpty) ||
      (_projectRootTreeUri != null && _projectRootTreeUri!.isNotEmpty);
  bool get autosaveEnabled => _autosaveEnabled;
  int get songStateVersion => _songStateVersion;
  List<List<bool>> get trackInsertOccupied => _trackInsertOccupied;
  List<List<String?>> get trackInsertEffectNames => _trackInsertEffectNames;
  Map<String, dynamic> get insertSnapshot => _insertSnapshot;
  void setInsertSnapshot(Map<String, dynamic> v) => _insertSnapshot = v;

  /// Resets queued by F[S]0 pattern commands. Mixer screen drains this list
  /// by re-sending its current slider values to native, then calls [clearInsertResets].
  List<(int, int)> get pendingInsertResets =>
      List.unmodifiable(_pendingInsertResets);

  void clearInsertResets() {
    _pendingInsertResets.clear();
    // No notifyListeners — clearing is a silent acknowledgement.
  }

  double get currentSamplerPreviewStartNorm {
    final slot = _previewSamplerSlot;
    if (slot < 0 || slot >= instruments.length) {
      return currentInstrument.sampler.start.clamp(0.0, 1.0);
    }
    return (_previewRegionStartNorm ?? instruments[slot].sampler.start).clamp(
      0.0,
      1.0,
    );
  }

  double get currentSamplerPreviewEndNorm {
    final slot = _previewSamplerSlot;
    if (slot < 0 || slot >= instruments.length) {
      final s = currentInstrument.sampler.start.clamp(0.0, 1.0);
      return currentInstrument.sampler.end.clamp(
        (s + 0.001).clamp(0.0, 1.0),
        1.0,
      );
    }
    final start = currentSamplerPreviewStartNorm;
    return (_previewRegionEndNorm ?? instruments[slot].sampler.end).clamp(
      (start + 0.001).clamp(0.0, 1.0),
      1.0,
    );
  }

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

  Future<int?> _estimatePreviewDurationMs(
    InstrumentModel ins, {
    double? startNorm,
    double? endNorm,
  }) async {
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

      if (channels <= 0 ||
          bitsPerSample <= 0 ||
          dataSize <= 0 ||
          sampleRate <= 0) {
        return null;
      }

      final bytesPerSample = bitsPerSample ~/ 8;
      final frameSize = bytesPerSample * channels;
      if (frameSize <= 0) return null;
      final totalFrames = dataSize ~/ frameSize;
      if (totalFrames <= 0) return null;

      final start = (startNorm ?? ins.sampler.start).clamp(0.0, 1.0);
      final end = (endNorm ?? ins.sampler.end).clamp(0.0, 1.0);
      final startFrame = (start * (totalFrames - 1)).round().clamp(
        0,
        totalFrames - 1,
      );
      final endFrame = (end * totalFrames).round().clamp(
        startFrame + 1,
        totalFrames,
      );
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

  Future<void> _schedulePreviewAutoStop(
    int slot,
    InstrumentModel ins, {
    double? startNorm,
    double? endNorm,
  }) async {
    _previewAutoStopTimer?.cancel();
    _previewAutoStopTimer = null;

    final ms = await _estimatePreviewDurationMs(
      ins,
      startNorm: startNorm,
      endNorm: endNorm,
    );
    if (ms != null) _previewDurationMs = ms;

    if (ins.sampler.loopMode != SamplerLoopMode.off) return;

    // Use estimated duration as minimum hold time, then poll C++ to detect when
    // the voice actually finishes (handles release tails accurately).
    // The grace period prevents a false-idle read before the audio thread starts the voice.
    final graceMs = (ms ?? 200).clamp(150, 120000);
    _previewAutoStopTimer = Timer(Duration(milliseconds: graceMs), () {
      if (_disposed) return;
      if (_previewSamplerSlot != slot) return;
      // After the estimated duration, poll every 50ms until voice goes idle.
      _previewAutoStopTimer = Timer.periodic(const Duration(milliseconds: 50), (
        _,
      ) async {
        if (_disposed) return;
        if (_previewSamplerSlot != slot) {
          _previewAutoStopTimer?.cancel();
          _previewAutoStopTimer = null;
          return;
        }
        final isStillPlaying = await AudioEngine.instance.isVoicePlaying(slot);
        if (!isStillPlaying) {
          _previewAutoStopTimer?.cancel();
          _previewAutoStopTimer = null;
          await stopPreviewCurrentSampler();
        }
      });
    });
  }

  PatternModel get currentPattern => song.patterns[_currentPatternIndex];
  TrackModel get currentTrack => currentPattern.tracks[_currentTrackIndex];
  InstrumentModel get currentInstrument => instruments[_currentInstrumentIndex];

  // ─ Pattern Editor "Remember Last" Values ────────────────────────────────
  
  /// Get the last note value for the current pattern (default: "C4")
  String get lastNote {
    final last = _patternLastValues[_currentPatternIndex];
    return last?.note ?? 'C4';
  }

  /// Get the last instrument value for the current pattern (default: 01)
  int get lastInstrument {
    final last = _patternLastValues[_currentPatternIndex];
    return last?.instrument ?? 1;
  }

  /// Get the last volume value for the current pattern (default: 99)
  int get lastVolume {
    final last = _patternLastValues[_currentPatternIndex];
    return last?.volume ?? 99;
  }

  /// Get the last FX command value for the current pattern (default: ARP)
  int get lastFxCommand {
    final last = _patternLastValues[_currentPatternIndex];
    return last?.fxCommand ?? kFxARP;
  }

  /// Get the last FX value for the current pattern (default: 00)
  int get lastFxValue {
    final last = _patternLastValues[_currentPatternIndex];
    return last?.fxValue ?? 0;
  }

  /// Update the last note value for the current pattern
  void updateLastNote(String note) {
    final current = _patternLastValues[_currentPatternIndex];
    _patternLastValues[_currentPatternIndex] = (
      note: note,
      volume: current?.volume ?? 99,
      instrument: current?.instrument ?? 1,
      fxCommand: current?.fxCommand ?? kFxARP,
      fxValue: current?.fxValue ?? 0,
    );
  }

  /// Update the last instrument value for the current pattern
  void updateLastInstrument(int instrument) {
    final current = _patternLastValues[_currentPatternIndex];
    _patternLastValues[_currentPatternIndex] = (
      note: current?.note ?? 'C4',
      volume: current?.volume ?? 99,
      instrument: instrument,
      fxCommand: current?.fxCommand ?? kFxARP,
      fxValue: current?.fxValue ?? 0,
    );
  }

  /// Update the last volume value for the current pattern
  void updateLastVolume(int volume) {
    final current = _patternLastValues[_currentPatternIndex];
    _patternLastValues[_currentPatternIndex] = (
      note: current?.note ?? 'C4',
      volume: volume,
      instrument: current?.instrument ?? 1,
      fxCommand: current?.fxCommand ?? kFxARP,
      fxValue: current?.fxValue ?? 0,
    );
  }

  /// Update the last FX command value for the current pattern
  void updateLastFxCommand(int command) {
    final current = _patternLastValues[_currentPatternIndex];
    _patternLastValues[_currentPatternIndex] = (
      note: current?.note ?? 'C4',
      volume: current?.volume ?? 99,
      instrument: current?.instrument ?? 1,
      fxCommand: command,
      fxValue: current?.fxValue ?? 0,
    );
  }

  /// Update the last FX value for the current pattern
  void updateLastFxValue(int value) {
    final current = _patternLastValues[_currentPatternIndex];
    _patternLastValues[_currentPatternIndex] = (
      note: current?.note ?? 'C4',
      volume: current?.volume ?? 99,
      instrument: current?.instrument ?? 1,
      fxCommand: current?.fxCommand ?? kFxARP,
      fxValue: value,
    );
  }

  double get bpm => currentPattern.bpm ?? 120.0;
  int get beats => currentPattern.beatCount;
  int get linesPerBeat => currentPattern.lpb;
  int get rowCount => currentPattern.rowCount;
  int get trackCount => currentPattern.tracks.length;
  int get minBeatsForExistingData => _minimumBeatsForExistingData();
  bool get canChangeBeats => true;
  bool get canChangePatternLength => currentPattern.isEmpty;

  /// Which beat (0-based) a row belongs to.
  int beatForRow(int row) => currentPattern.beatForRow(row);

  /// Effective line count for a specific beat (override or pattern default).
  int linesForBeat(int beat) => currentPattern.linesForBeat(beat);

  /// The raw override for a beat — null means no override (using pattern default).
  int? beatLineOverride(int beat) {
    final overrides = currentPattern.beatLineOverrides;
    if (beat < 0 || beat >= overrides.length) return null;
    final v = overrides[beat];
    return (v == null || v == 0) ? null : v;
  }

  /// Returns true if [row] is the first row of a beat.
  bool isBeatStart(int row) {
    if (row == 0) return true;
    int acc = 0;
    for (int b = 0; b < currentPattern.beatCount; b++) {
      if (acc == row) return true;
      acc += currentPattern.linesForBeat(b);
      if (acc > row) return false;
    }
    return false;
  }

  int _minimumBeatsForExistingData() {
    int lastUsedRow = -1;
    for (final track in currentPattern.tracks) {
      for (int row = track.cells.length - 1; row >= 0; row--) {
        final cell = track.cells[row];
        final hasData = !cell.isEmpty || cell.pan != null;
        if (hasData) {
          if (row > lastUsedRow) lastUsedRow = row;
          break;
        }
      }
    }

    if (lastUsedRow < 0) return 1;
    final usedLines = lastUsedRow + 1;
    return ((usedLines + linesPerBeat - 1) ~/ linesPerBeat).clamp(1, 99);
  }

  // ── Navigation ───────────────────────────────────────────────────────────

  void selectPattern(int index) {
    _currentPatternIndex = index.clamp(0, song.patterns.length - 1);
    _currentTrackIndex = 0;
    selectedCell = null;
    _selectedRowStart = null;
    _selectedRowEnd = null;
    _clampSelectionToPattern();
    _restartPlayheadTimerIfNeeded();
    notifyListeners();
  }

  void selectInstrument(int index) {
    _currentInstrumentIndex = index.clamp(0, instruments.length - 1);
    notifyListeners();
  }

  void setInstrumentType(int index, InstrumentType type) {
    // Only call this on empty slots (UI enforces this). Setting a type on a
    // non-empty slot would leave stale data from the previous type.
    if (index < 0 || index >= instruments.length) return;
    instruments[index].type = type;
    notifyListeners();
  }

  /// Reset a slot back to empty, clearing all instrument data and unloading
  /// any sample from the native engine. Call this before letting the user
  /// pick a different instrument type.
  Future<void> clearInstrument(int index) async {
    if (index < 0 || index >= instruments.length) return;
    final ins = instruments[index];
    if (ins.sampler.samplePath != null && ins.sampler.samplePath!.isNotEmpty) {
      await AudioEngine.instance.setSamplerSample(index, null);
    }
    instruments[index] = InstrumentModel.empty(index);
    notifyListeners();
  }

  /// Copy the instrument at [fromIndex] to the next empty slot (wraps around).
  /// Returns the destination slot index, or -1 if no free slot is available.
  Future<int> copyInstrumentToFreeSlot(int fromIndex) async {
    final total = instruments.length;
    int? dest;
    for (int i = 1; i < total; i++) {
      final candidate = (fromIndex + i) % total;
      if (instruments[candidate].type == InstrumentType.empty) {
        dest = candidate;
        break;
      }
    }
    if (dest == null) return -1;

    // Deep-copy via JSON round-trip.
    final copy = InstrumentModel.fromJson(instruments[fromIndex].toJson());
    instruments[dest] = copy;

    // For samplers, load the sample into the audio engine at the new slot.
    if (copy.type == InstrumentType.sampler &&
        copy.sampler.samplePath != null &&
        copy.sampler.samplePath!.isNotEmpty) {
      await AudioEngine.instance.setSamplerSample(
        dest,
        copy.sampler.samplePath,
      );
    }

    notifyListeners();
    return dest;
  }

  /// Trigger a UI rebuild after the instrument editors mutate parameters
  /// directly. (They mutate plain fields; this just notifies listeners.)
  void instrumentParamsChanged() {
    notifyListeners();
    if (isPlaying && !_playbackFollowsSong) {
      _instrumentParamRebuildTimer?.cancel();
      _instrumentParamRebuildTimer = Timer(
        const Duration(milliseconds: 150),
        () => unawaited(_doLiveInstrumentRebuild()),
      );
    }
  }

  Future<void> _doLiveInstrumentRebuild() async {
    if (!isPlaying || _playbackFollowsSong || _liveRebuildInFlight) return;
    _liveRebuildInFlight = true;
    try {
      await _loadNativePatternPlaybackQueue(startRow: playheadRow);
      if (isPlaying && !_playbackFollowsSong) await AudioEngine.instance.start();
    } finally {
      _liveRebuildInFlight = false;
    }
  }

  void selectTrack(int index) {
    _currentTrackIndex = index.clamp(0, currentPattern.tracks.length - 1);
    selectedCell = null;
    _selectedRowStart = null;
    _selectedRowEnd = null;
    _boxSelection = null;
    _isBoxSelecting = false;
    notifyListeners();
  }

  void nextTrack() => selectTrack(_currentTrackIndex + 1);
  void prevTrack() => selectTrack(_currentTrackIndex - 1);

  PatternModel _playbackPattern() {
    if (_playbackFollowsSong && song.patterns.isNotEmpty) {
      return song.patterns[_playheadArrangementSlot.clamp(
        0,
        song.patterns.length - 1,
      )];
    }
    return currentPattern;
  }

  bool _isTrackMutedByMixer(
    PatternModel pattern,
    int trackIndex, {
    bool? hasSoloOverride,
  }) {
    if (trackIndex < 0 || trackIndex >= pattern.tracks.length) return false;
    final hasSolo =
        hasSoloOverride ?? pattern.tracks.any((track) => track.mixerSolo);
    final track = pattern.tracks[trackIndex];
    if (track.mixerMute) return true;
    if (hasSolo && !track.mixerSolo) return true;
    return false;
  }

  void _applyImmediateMixerMuteState() {
    if (!isPlaying) return;
    final pattern = _playbackPattern();
    final hasSolo = pattern.tracks.any((track) => track.mixerSolo);
    final mask = List<int>.generate(
      pattern.tracks.length,
      (i) => _isTrackMutedByMixer(pattern, i, hasSoloOverride: hasSolo) ? 1 : 0,
    );
    if (mask.any((v) => v == 1)) {
      AudioEngine.instance.killVoices(mask);
    }
  }

  bool _isMixerFxCommand(int? cmd) => isMixerValueCommand(cmd);

  void _resetSongScopedState() {
    _trackInsertOccupied.clear();
    _trackInsertEffectNames.clear();
    _pendingInsertResets.clear();
    _insertSnapshot = {};
    _queuedArrangementSlot = null;
    _rowSegments = [];
    _resetInstrumentCarry();
  }

  Future<void> _clearInsertEffectsInEngine() async {
    const insertSlots = 6;
    for (int slot = 0; slot < insertSlots; slot++) {
      await AudioEngine.instance.setMasterInsertEffect(slot, -1, 0.0);
    }

    final trackCount = currentPattern.tracks.length;
    for (int track = 0; track < trackCount; track++) {
      for (int slot = 0; slot < insertSlots; slot++) {
        await AudioEngine.instance.setTrackInsertEffect(track, slot, -1, 0.0);
      }
    }
  }

  // Apply the current _insertSnapshot to the native audio engine and update
  // _trackInsertEffectNames so MixerScreen can restore UI state on next build.
  Future<void> _applyInsertSnapshotToEngine() async {
    if (_insertSnapshot.isEmpty) return;

    // ----- helper: apply one slot (master or track) to native engine -----
    Future<void> applySlot(
      Map<String, dynamic> data, {
      required bool onMaster,
      int? trackIdx,
      required int slot,
    }) async {
      final type = data['type'] as String?;
      if (type == null) return;

      final bypass = (data['bypass'] as bool?) ?? false;

      if (!onMaster) {
        setTrackInsertEffectName(trackIdx!, slot, type);
      }

      double d(String k, double def) => (data[k] as num?)?.toDouble() ?? def;
      bool b(String k, bool def) => (data[k] as bool?) ?? def;
      int i(String k, int def) => (data[k] as num?)?.toInt() ?? def;

      switch (type) {
        case 'REVERB':
          final typeCode = 0;
          final wet = d('wet', 0.3);
          if (onMaster) {
            await AudioEngine.instance.setMasterInsertEffect(
              slot,
              typeCode,
              wet,
            );
            await AudioEngine.instance.setMasterInsertMix(
              slot,
              d('dry', 1.0),
              wet,
            );
            await AudioEngine.instance.setMasterReverbParams(
              slot,
              d('roomSize', 0.5),
              d('damp', 0.5),
              d('width', 1.0),
              b('freeze', false),
            );
          } else {
            await AudioEngine.instance.setTrackInsertEffect(
              trackIdx!,
              slot,
              typeCode,
              wet,
            );
            await AudioEngine.instance.setTrackInsertMix(
              trackIdx,
              slot,
              d('dry', 1.0),
              wet,
            );
            await AudioEngine.instance.setTrackReverbParams(
              trackIdx,
              slot,
              d('roomSize', 0.5),
              d('damp', 0.5),
              d('width', 1.0),
              b('freeze', false),
            );
          }
        case 'DELAY':
          final typeCode = 1;
          final wet = d('wet', 0.35);
          if (onMaster) {
            await AudioEngine.instance.setMasterInsertEffect(
              slot,
              typeCode,
              wet,
            );
            await AudioEngine.instance.setMasterInsertMix(
              slot,
              d('dry', 1.0),
              wet,
            );
            await AudioEngine.instance.setMasterDelayParams(
              slot,
              d('timeMs', 375.0),
              d('feedback', 0.4),
              d('hpCutoff', 0.0),
              b('sync', false),
            );
          } else {
            await AudioEngine.instance.setTrackInsertEffect(
              trackIdx!,
              slot,
              typeCode,
              wet,
            );
            await AudioEngine.instance.setTrackInsertMix(
              trackIdx,
              slot,
              d('dry', 1.0),
              wet,
            );
            await AudioEngine.instance.setTrackDelayParams(
              trackIdx,
              slot,
              d('timeMs', 375.0),
              d('feedback', 0.4),
              d('hpCutoff', 0.0),
              b('sync', false),
            );
          }
        case 'FILTER':
          final typeCode = 2;
          final wet = d('wet', 1.0);
          if (onMaster) {
            await AudioEngine.instance.setMasterInsertEffect(
              slot,
              typeCode,
              wet,
            );
            await AudioEngine.instance.setMasterInsertMix(
              slot,
              d('dry', 1.0),
              wet,
            );
            await AudioEngine.instance.setMasterFilterParams(
              slot,
              d('cutoff', 0.5),
              d('resonance', 0.2),
              i('mode', 0),
            );
          } else {
            await AudioEngine.instance.setTrackInsertEffect(
              trackIdx!,
              slot,
              typeCode,
              wet,
            );
            await AudioEngine.instance.setTrackInsertMix(
              trackIdx,
              slot,
              d('dry', 1.0),
              wet,
            );
            await AudioEngine.instance.setTrackFilterParams(
              trackIdx,
              slot,
              d('cutoff', 0.5),
              d('resonance', 0.2),
              i('mode', 0),
            );
          }
        case 'DISTORTION':
          final typeCode = 3;
          final wet = d('wet', 1.0);
          if (onMaster) {
            await AudioEngine.instance.setMasterInsertEffect(
              slot,
              typeCode,
              wet,
            );
            await AudioEngine.instance.setMasterInsertMix(
              slot,
              d('dry', 1.0),
              wet,
            );
            await AudioEngine.instance.setMasterDistortionParams(
              slot,
              d('drive', 0.5),
              d('tone', 0.5),
              i('distType', 0),
            );
          } else {
            await AudioEngine.instance.setTrackInsertEffect(
              trackIdx!,
              slot,
              typeCode,
              wet,
            );
            await AudioEngine.instance.setTrackInsertMix(
              trackIdx,
              slot,
              d('dry', 1.0),
              wet,
            );
            await AudioEngine.instance.setTrackDistortionParams(
              trackIdx,
              slot,
              d('drive', 0.5),
              d('tone', 0.5),
              i('distType', 0),
            );
          }
        case 'BITCRUSHER':
          final typeCode = 4;
          final wet = d('wet', 1.0);
          if (onMaster) {
            await AudioEngine.instance.setMasterInsertEffect(
              slot,
              typeCode,
              wet,
            );
            await AudioEngine.instance.setMasterInsertMix(
              slot,
              d('dry', 1.0),
              wet,
            );
            await AudioEngine.instance.setMasterBitcrusherParams(
              slot,
              d('bits', 1.0),
              d('rate', 1.0),
            );
          } else {
            await AudioEngine.instance.setTrackInsertEffect(
              trackIdx!,
              slot,
              typeCode,
              wet,
            );
            await AudioEngine.instance.setTrackInsertMix(
              trackIdx,
              slot,
              d('dry', 1.0),
              wet,
            );
            await AudioEngine.instance.setTrackBitcrusherParams(
              trackIdx,
              slot,
              d('bits', 1.0),
              d('rate', 1.0),
            );
          }
        case 'LIMITER':
          final typeCode = 5;
          final wet = d('wet', 1.0);
          if (onMaster) {
            await AudioEngine.instance.setMasterInsertEffect(
              slot,
              typeCode,
              wet,
            );
            await AudioEngine.instance.setMasterInsertMix(
              slot,
              d('dry', 0.0),
              wet,
            );
            await AudioEngine.instance.setMasterLimiterParams(
              slot,
              d('gain', 0.0),
            );
          } else {
            await AudioEngine.instance.setTrackInsertEffect(
              trackIdx!,
              slot,
              typeCode,
              wet,
            );
            await AudioEngine.instance.setTrackInsertMix(
              trackIdx,
              slot,
              d('dry', 0.0),
              wet,
            );
            await AudioEngine.instance.setTrackLimiterParams(
              trackIdx,
              slot,
              d('gain', 0.0),
            );
          }
        case 'CHORUS':
          final typeCode = 6;
          final wet = d('wet', 1.0);
          if (onMaster) {
            await AudioEngine.instance.setMasterInsertEffect(
              slot,
              typeCode,
              wet,
            );
            await AudioEngine.instance.setMasterInsertMix(
              slot,
              d('dry', 0.5),
              wet,
            );
            await AudioEngine.instance.setMasterChorusParams(
              slot,
              d('rate', 0.3),
              d('depth', 0.22) * (5.0 / 15.0),
              d('delay', 0.3),
              i('stereo', 0),
            );
          } else {
            await AudioEngine.instance.setTrackInsertEffect(
              trackIdx!,
              slot,
              typeCode,
              wet,
            );
            await AudioEngine.instance.setTrackInsertMix(
              trackIdx,
              slot,
              d('dry', 0.5),
              wet,
            );
            await AudioEngine.instance.setTrackChorusParams(
              trackIdx,
              slot,
              d('rate', 0.3),
              d('depth', 0.22) * (5.0 / 15.0),
              d('delay', 0.3),
              i('stereo', 0),
            );
          }
        case 'EQ':
          final typeCode = 7;
          final wet = d('wet', 1.0);
          if (onMaster) {
            await AudioEngine.instance.setMasterInsertEffect(
              slot,
              typeCode,
              wet,
            );
            await AudioEngine.instance.setMasterInsertMix(
              slot,
              d('dry', 0.0),
              wet,
            );
            await AudioEngine.instance.setMasterEqParams(
              slot,
              d('lowGain', 0.0),
              d('lowFreq', 0.2),
              d('midGain', 0.0),
              d('midFreq', 0.3),
              d('midQ', 0.3),
              d('highGain', 0.0),
              d('highFreq', 0.5),
            );
          } else {
            await AudioEngine.instance.setTrackInsertEffect(
              trackIdx!,
              slot,
              typeCode,
              wet,
            );
            await AudioEngine.instance.setTrackInsertMix(
              trackIdx,
              slot,
              d('dry', 0.0),
              wet,
            );
            await AudioEngine.instance.setTrackEqParams(
              trackIdx,
              slot,
              d('lowGain', 0.0),
              d('lowFreq', 0.2),
              d('midGain', 0.0),
              d('midFreq', 0.3),
              d('midQ', 0.3),
              d('highGain', 0.0),
              d('highFreq', 0.5),
            );
          }
        case 'COMPRESSOR':
          final typeCode = 8;
          final wet = d('wet', 1.0);
          if (onMaster) {
            await AudioEngine.instance.setMasterInsertEffect(
              slot,
              typeCode,
              wet,
            );
            await AudioEngine.instance.setMasterInsertMix(
              slot,
              d('dry', 0.0),
              wet,
            );
            await AudioEngine.instance.setMasterCompressorParams(
              slot,
              d('threshold', 0.7),
              d('ratio', 0.2),
              d('attack', 0.1),
              d('release', 0.2),
              d('makeup', 0.0),
              i('knee', 0),
            );
          } else {
            await AudioEngine.instance.setTrackInsertEffect(
              trackIdx!,
              slot,
              typeCode,
              wet,
            );
            await AudioEngine.instance.setTrackInsertMix(
              trackIdx,
              slot,
              d('dry', 0.0),
              wet,
            );
            await AudioEngine.instance.setTrackCompressorParams(
              trackIdx,
              slot,
              d('threshold', 0.7),
              d('ratio', 0.2),
              d('attack', 0.1),
              d('release', 0.2),
              d('makeup', 0.0),
              i('knee', 0),
            );
          }
      }

      if (bypass) {
        if (onMaster) {
          await AudioEngine.instance.setMasterInsertBypass(slot, true);
        } else {
          await AudioEngine.instance.setTrackInsertBypass(
            trackIdx!,
            slot,
            true,
          );
        }
      }
    }
    // ----- end helper -----

    const kSlots = 6;

    // Master inserts
    final masterData = _insertSnapshot['master'];
    if (masterData is List) {
      for (int s = 0; s < kSlots && s < masterData.length; s++) {
        final slotData = masterData[s];
        if (slotData is Map<String, dynamic>) {
          await applySlot(slotData, onMaster: true, slot: s);
        }
      }
    }

    // Track inserts
    final trackData = _insertSnapshot['tracks'];
    if (trackData is List) {
      for (int t = 0; t < trackData.length; t++) {
        final rowData = trackData[t];
        if (rowData is! List) continue;
        for (int s = 0; s < kSlots && s < rowData.length; s++) {
          final slotData = rowData[s];
          if (slotData is Map<String, dynamic>) {
            await applySlot(slotData, onMaster: false, trackIdx: t, slot: s);
          }
        }
      }
    }
  }

  void _appendMasterMixerSnapshot(List<int> queue) {
    final muteValue = song.masterMute ? 1 : 0;
    final volumeValue = (song.masterVolume * 99).round().clamp(0, 99);
    queue.addAll([0, 1, muteValue, 0]);
    queue.addAll([0, 2, volumeValue, 0]);
  }

  void _appendTrackMixerSnapshot(
    List<int> queue,
    PatternModel pattern,
    int trackIndex,
  ) {
    if (trackIndex < 0 || trackIndex >= pattern.tracks.length) return;
    final track = pattern.tracks[trackIndex];
    final panValue = ((track.mixerPan + 1.0) * 49.5).round().clamp(0, 99);
    final muteValue = track.mixerMute ? 1 : 0;
    final soloValue = track.mixerSolo ? 1 : 0;
    final volumeValue = (track.mixerVolume * 99).round().clamp(0, 99);
    final channel = trackIndex + 1;
    queue.addAll([channel, 1, panValue, 0]);
    queue.addAll([channel, 2, muteValue, 0]);
    queue.addAll([channel, 3, soloValue, 0]);
    queue.addAll([channel, 4, volumeValue, 0]);
  }

  void _appendFullMixerSnapshot(List<int> queue, PatternModel pattern) {
    _appendMasterMixerSnapshot(queue);
    for (int i = 0; i < pattern.tracks.length; i++) {
      _appendTrackMixerSnapshot(queue, pattern, i);
    }
  }

  void _queueCurrentMixerSnapshotToEngine({int? trackIndex}) {
    final queue = <int>[];
    if (trackIndex == null) {
      _appendFullMixerSnapshot(queue, currentPattern);
    } else {
      _appendTrackMixerSnapshot(queue, currentPattern, trackIndex);
    }
    if (queue.isNotEmpty) {
      AudioEngine.instance.queueMixerCommands(queue);
    }
    if (trackIndex == null) {
      _pushSendRouting();
    }
  }

  void _ensureTrackInsertLists(int trackIdx) {
    while (_trackInsertOccupied.length <= trackIdx) {
      _trackInsertOccupied.add(List<bool>.filled(6, false));
    }
    while (_trackInsertEffectNames.length <= trackIdx) {
      _trackInsertEffectNames.add(List<String?>.filled(6, null));
    }
  }

  void setTrackInsertOccupied(int trackIdx, int slotIdx, bool occupied) {
    _ensureTrackInsertLists(trackIdx);
    _trackInsertOccupied[trackIdx][slotIdx] = occupied;
    if (!occupied) {
      _trackInsertEffectNames[trackIdx][slotIdx] = null;
    }
    notifyListeners();
  }

  void setTrackInsertEffectName(int trackIdx, int slotIdx, String? effectName) {
    _ensureTrackInsertLists(trackIdx);
    _trackInsertEffectNames[trackIdx][slotIdx] = effectName;
    _trackInsertOccupied[trackIdx][slotIdx] = effectName != null;
    notifyListeners();
  }

  String? trackInsertEffectName(int trackIdx, int slotIdx) {
    if (trackIdx < 0 || trackIdx >= _trackInsertEffectNames.length) return null;
    final row = _trackInsertEffectNames[trackIdx];
    if (slotIdx < 0 || slotIdx >= row.length) return null;
    return row[slotIdx];
  }

  void setTrackMixerVolume(int trackIndex, double value) {
    if (trackIndex < 0 || trackIndex >= currentPattern.tracks.length) return;
    final clamped = value.clamp(0.0, 1.0);
    // Mixer settings are project-wide: update same track on every pattern.
    for (final pattern in song.patterns) {
      if (trackIndex < pattern.tracks.length) {
        pattern.tracks[trackIndex].mixerVolume = clamped;
      }
    }
    final volumeValue = (clamped * 99).round().clamp(0, 99);
    AudioEngine.instance.queueMixerCommands([
      trackIndex + 1,
      4,
      volumeValue,
      0,
    ]);
    notifyListeners();
  }

  void setTrackMixerPan(int trackIndex, double value) {
    if (trackIndex < 0 || trackIndex >= currentPattern.tracks.length) return;
    final clamped = value.clamp(-1.0, 1.0);
    // Mixer settings are project-wide: update same track on every pattern.
    for (final pattern in song.patterns) {
      if (trackIndex < pattern.tracks.length) {
        pattern.tracks[trackIndex].mixerPan = clamped;
      }
    }
    // Queue mixer command: M{channel}1 (pan controller)
    // Pan: -1.0 to 1.0 → 0 to 99 (0=left, 50=center, 99=right)
    final panValue = ((value + 1.0) * 49.5).round().clamp(0, 99);
    AudioEngine.instance.queueMixerCommands([trackIndex + 1, 1, panValue, 0]);
    notifyListeners();
  }

  void toggleTrackMixerMute(int trackIndex) {
    if (trackIndex < 0 || trackIndex >= currentPattern.tracks.length) return;
    final nextMute = !currentPattern.tracks[trackIndex].mixerMute;
    // Mixer settings are project-wide: update same track on every pattern.
    for (final pattern in song.patterns) {
      if (trackIndex < pattern.tracks.length) {
        pattern.tracks[trackIndex].mixerMute = nextMute;
      }
    }
    // Queue mixer command: M{channel}2 (mute controller)
    // value > 0 = muted, 0 = unmuted
    final muteValue = nextMute ? 1 : 0;
    AudioEngine.instance.queueMixerCommands([trackIndex + 1, 2, muteValue, 0]);
    _applyImmediateMixerMuteState();
    notifyListeners();
  }

  void toggleTrackMixerSolo(int trackIndex) {
    if (trackIndex < 0 || trackIndex >= currentPattern.tracks.length) return;
    final nextSolo = !currentPattern.tracks[trackIndex].mixerSolo;
    // Mixer settings are project-wide: update same track on every pattern.
    for (final pattern in song.patterns) {
      if (trackIndex < pattern.tracks.length) {
        pattern.tracks[trackIndex].mixerSolo = nextSolo;
      }
    }
    // Queue mixer command: M{channel}3 (solo controller)
    // value > 0 = soloed, 0 = not soloed
    final soloValue = nextSolo ? 1 : 0;
    AudioEngine.instance.queueMixerCommands([trackIndex + 1, 3, soloValue, 0]);
    _applyImmediateMixerMuteState();
    notifyListeners();
  }

  void _copyProjectMixerStateToPattern(PatternModel targetPattern) {
    if (song.patterns.isEmpty || targetPattern.tracks.isEmpty) return;
    final sourceTracks = currentPattern.tracks;
    final count = math.min(sourceTracks.length, targetPattern.tracks.length);
    for (int i = 0; i < count; i++) {
      targetPattern.tracks[i].mixerVolume = sourceTracks[i].mixerVolume;
      targetPattern.tracks[i].mixerPan = sourceTracks[i].mixerPan;
      targetPattern.tracks[i].mixerMute = sourceTracks[i].mixerMute;
      targetPattern.tracks[i].mixerSolo = sourceTracks[i].mixerSolo;
    }
  }

  // ── Send routing ─────────────────────────────────────────────────────────

  /// Returns true if [trackIndex] is a send bus — i.e. another track routes
  /// its audio into this track. Send buses cannot themselves send anywhere
  /// except master (no chaining).
  bool isSendBus(int trackIndex) {
    if (song.patterns.isEmpty) return false;
    final tracks = song.patterns.first.tracks;
    for (int i = 0; i < tracks.length; i++) {
      if (i == trackIndex) continue;
      if (tracks[i].sendChannel == trackIndex + 1) return true;
    }
    return false;
  }

  void setTrackSendChannel(int trackIndex, int sendChannel) {
    if (trackIndex < 0 || trackIndex >= currentPattern.tracks.length) return;
    // Clamp to valid range: 0=master, 1..16 track channels.
    final ch = sendChannel.clamp(0, kMaxTracks);
    // Disallow self-send
    if (ch == trackIndex + 1) return;
    // Send routing is project-wide: update the same track on every pattern.
    for (final pattern in song.patterns) {
      if (trackIndex < pattern.tracks.length) {
        pattern.tracks[trackIndex].sendChannel = ch;
      }
    }
    _pushSendRouting();
    notifyListeners();
  }

  void _copyProjectSendRoutingToPattern(PatternModel targetPattern) {
    if (song.patterns.isEmpty || targetPattern.tracks.isEmpty) return;
    final sourceTracks = currentPattern.tracks;
    final count = math.min(sourceTracks.length, targetPattern.tracks.length);
    for (int i = 0; i < count; i++) {
      targetPattern.tracks[i].sendChannel = sourceTracks[i].sendChannel;
    }
  }

  void _pushSendRouting() {
    final tracks = currentPattern.tracks;
    final routing = List.generate(tracks.length, (i) => tracks[i].sendChannel);
    AudioEngine.instance.setSendRouting(routing);
  }

  // ── Cell selection ───────────────────────────────────────────────────────

  void selectCell(int row, CellColumn column) {
    final pos = CellPosition(row, column);
    selectedCell = (selectedCell == pos) ? null : pos;
    _selectedRowStart = null;
    _selectedRowEnd = null;
    _boxSelection = null;
    _isBoxSelecting = false;
    notifyListeners();
  }

  void clearSelection() {
    selectedCell = null;
    _selectedRowStart = null;
    _selectedRowEnd = null;
    _boxSelection = null;
    _isBoxSelecting = false;
    notifyListeners();
  }

  // ── Row selection ────────────────────────────────────────────────────────

  /// Handle row selection with multi-line range support:
  /// - No selection: click selects a single line.
  /// - Single-line selection: click same line deselects, click another line
  ///   expands to the inclusive range between them.
  /// - Multi-line selection: click inside deselects all, click outside clears
  ///   the old range and selects only the new line.
  void selectRow(int row) {
    if (row < 0 || row >= rowCount) return;

    selectedCell = null;
    _boxSelection = null;
    _isBoxSelecting = false;

    final start = _selectedRowStart;
    final end = _selectedRowEnd;

    if (start == null || end == null) {
      _selectedRowStart = row;
      _selectedRowEnd = row;
      notifyListeners();
      return;
    }

    final minRow = start < end ? start : end;
    final maxRow = start < end ? end : start;
    final isSingleSelection = minRow == maxRow;

    final isInSelection = isRowInSelection(row);

    if (isInSelection) {
      _selectedRowStart = null;
      _selectedRowEnd = null;
      notifyListeners();
      return;
    }

    if (isSingleSelection) {
      _selectedRowStart = minRow < row ? minRow : row;
      _selectedRowEnd = maxRow > row ? maxRow : row;
      notifyListeners();
      return;
    }

    _selectedRowStart = row;
    _selectedRowEnd = row;
    notifyListeners();
  }

  void clearRowSelection() {
    if (_selectedRowStart == null && _selectedRowEnd == null) return;
    _selectedRowStart = null;
    _selectedRowEnd = null;
    notifyListeners();
  }

  void beginBoxSelection(int trackIndex, int row, CellColumn column) {
    _currentTrackIndex = trackIndex.clamp(0, currentPattern.tracks.length - 1);
    selectedCell = null;
    _selectedRowStart = null;
    _selectedRowEnd = null;
    _isBoxSelecting = true;
    _boxSelection = CellBoxSelection(
      trackIndex: _currentTrackIndex,
      anchorRow: row.clamp(0, rowCount - 1),
      anchorColumn: column,
      focusRow: row.clamp(0, rowCount - 1),
      focusColumn: column,
    );
    notifyListeners();
  }

  void updateBoxSelection(int trackIndex, int row, CellColumn column) {
    final sel = _boxSelection;
    if (!_isBoxSelecting || sel == null || sel.trackIndex != trackIndex) return;
    final clampedRow = row.clamp(0, rowCount - 1);
    if (sel.focusRow == clampedRow && sel.focusColumn == column) return;
    _boxSelection = sel.copyWith(focusRow: clampedRow, focusColumn: column);
    notifyListeners();
  }

  void endBoxSelection() {
    if (!_isBoxSelecting) return;
    _isBoxSelecting = false;
    notifyListeners();
  }

  void clearBoxSelection() {
    if (_boxSelection == null && !_isBoxSelecting) return;
    _boxSelection = null;
    _isBoxSelecting = false;
    notifyListeners();
  }

  bool isCellInBoxSelection(int trackIndex, int row, CellColumn column) {
    final sel = _boxSelection;
    if (sel == null) return false;
    return sel.contains(trackIndex, row, column);
  }

  /// Move the currently selected row range up/down by [delta] in the current track,
  /// swapping content with the neighbouring rows. Selection follows the rows.
  void moveSelectedRowBy(int delta) {
    final start = _selectedRowStart;
    final end = _selectedRowEnd;
    if (start == null || end == null) return;

    final min = start < end ? start : end;
    final max = start < end ? end : start;
    final rangeSize = max - min + 1;

    final newMin = (min + delta).clamp(0, rowCount - rangeSize);
    if (newMin == min) return;

    final cells = currentTrack.cells;
    if (delta > 0) {
      // Moving down: swap from right to left
      for (int i = 0; i < delta; i++) {
        for (int r = max; r >= min; r--) {
          final tmp = cells[r];
          cells[r] = cells[r + 1];
          cells[r + 1] = tmp;
        }
      }
    } else {
      // Moving up: swap from left to right
      for (int i = 0; i < -delta; i++) {
        for (int r = min; r <= max; r++) {
          final tmp = cells[r];
          cells[r] = cells[r - 1];
          cells[r - 1] = tmp;
        }
      }
    }

    _selectedRowStart = newMin;
    _selectedRowEnd = newMin + rangeSize - 1;
    notifyListeners();
  }

  /// Cut row = copy + clear (current track only).
  void cutRow(int row) {
    copyRow(row);
    deleteRow(row);
    clearRowSelection();
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
    
    // Remember the last value set
    if (column == CellColumn.note) {
      // Note nudging is handled via setNote, but handle it here for completeness
      final cell = track.cells[row];
      if (cell.note.isNote) {
        updateLastNote(cell.note.display);
      }
    } else if (column == CellColumn.instrument) {
      updateLastInstrument(clamped);
    } else if (column == CellColumn.fx0cmd || column == CellColumn.fx1cmd || column == CellColumn.fx2cmd) {
      updateLastFxCommand(clamped);
    } else if (column == CellColumn.fx0val || column == CellColumn.fx1val || column == CellColumn.fx2val) {
      updateLastFxValue(clamped);
    }
    notifyListeners();
  }

  void setNote(int row, NoteValue note) {
    currentTrack.setNote(row, note);
    if (note.isNote) {
      updateLastNote(note.display);
    }
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

  /// Returns the effective instrument number (1-based) for [row] on the
  /// current track: uses the cell's own IN value if set, otherwise scans
  /// backwards to the last row that has one, defaulting to 1.
  int effectiveInstrumentAtRow(int row) {
    final track = currentTrack;
    return track.cells[row].instrument ?? _defaultInstrumentForRow(track, row);
  }

  /// Resets a cell column to its default value (always writes a value).
  void resetColumnToDefault(int row, CellColumn column) {
    final track = currentTrack;
    switch (column) {
      case CellColumn.note:
        track.setNote(row, NoteValue.fromScrollIndex(49)); // C-4
        break;
      case CellColumn.instrument:
        track.writeColumnValue(
          row,
          column,
          _defaultInstrumentForRow(track, row),
        );
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
        final fxIndex = column == CellColumn.fx0val
            ? 0
            : column == CellColumn.fx1val
            ? 1
            : 2;
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
        // Use the last note if available, otherwise default to C4
        final noteDisplay = lastNote;
        final noteValue = _parseNoteDisplay(noteDisplay);
        track.setNote(row, noteValue);
      case CellColumn.instrument:
        // Use the last instrument value
        track.writeColumnValue(
          row,
          column,
          lastInstrument,
        );
      case CellColumn.volume:
        track.writeColumnValue(row, column, 80);
      case CellColumn.fx0cmd:
      case CellColumn.fx1cmd:
      case CellColumn.fx2cmd:
        // Use the last FX command
        track.writeColumnValue(row, column, lastFxCommand);
      case CellColumn.fx0val:
      case CellColumn.fx1val:
      case CellColumn.fx2val:
        // Use the last FX value
        final fxIndex = column == CellColumn.fx0val
            ? 0
            : column == CellColumn.fx1val
            ? 1
            : 2;
        final cmd = track.cells[row].fxSlots[fxIndex].command;
        // If using PAN effect and no last FX value set, default to 50 (center)
        final defaultVal = cmd == kFxPAN && lastFxValue == 0 ? 50 : lastFxValue;
        track.writeColumnValue(row, column, defaultVal);
    }
    notifyListeners();
  }

  /// Parse a note display string (e.g. "C4", "D#4", "A-1") to a NoteValue
  NoteValue _parseNoteDisplay(String display) {
    display = display.trim().toUpperCase();
    if (display == '---') return NoteValue.empty;
    if (display == 'OFF') return NoteValue.off;

    // Parse format: "N-O" (natural) or "N#O" (sharp) where N=note, O=octave
    // Examples: "C-4", "C#4", "D-0", "B-9"
    String notePart = '';
    String octavePart = '';

    // Handle both formats: "C-4" and "C#4"
    if (display.contains('-')) {
      final parts = display.split('-');
      if (parts.length == 2) {
        notePart = parts[0];
        octavePart = parts[1];
      }
    } else {
      // Format like "C#4" - extract note and octave
      if (display.length >= 2) {
        if (display.contains('#')) {
          final idx = display.indexOf('#');
          notePart = display.substring(0, idx + 1);
          octavePart = display.substring(idx + 1);
        } else {
          notePart = display.substring(0, 1);
          octavePart = display.substring(1);
        }
      }
    }

    const noteNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
    final noteIdx = noteNames.indexOf(notePart);
    final octave = int.tryParse(octavePart);

    if (noteIdx >= 0 && octave != null && octave >= 0 && octave <= 9) {
      final scrollIndex = 1 + (octave * 12) + noteIdx;
      return NoteValue.fromScrollIndex(scrollIndex);
    }

    // Default to C4 if parsing fails
    return NoteValue.fromScrollIndex(49);
  }

  /// Clears a single column value (sets to empty/null). Ignored for fx val columns.
  void clearColumnValue(int row, CellColumn column) {
    final track = currentTrack;
    _clearColumnValueInTrack(track, row, column);
    notifyListeners();
  }

  void _clearColumnValueInTrack(TrackModel track, int row, CellColumn column) {
    switch (column) {
      case CellColumn.note:
        track.cells[row].note = NoteValue.empty;
        break;
      case CellColumn.instrument:
        track.cells[row].instrument = null;
        break;
      case CellColumn.volume:
        track.cells[row].volume = null;
        break;
      case CellColumn.fx0cmd:
        track.cells[row].fxSlots[0].command = null;
        break;
      case CellColumn.fx0val:
        track.cells[row].fxSlots[0].value = null;
        break;
      case CellColumn.fx1cmd:
        track.cells[row].fxSlots[1].command = null;
        break;
      case CellColumn.fx1val:
        track.cells[row].fxSlots[1].value = null;
        break;
      case CellColumn.fx2cmd:
        track.cells[row].fxSlots[2].command = null;
        break;
      case CellColumn.fx2val:
        track.cells[row].fxSlots[2].value = null;
        break;
    }
  }

  void clearCell(int row) {
    currentPattern.tracks[_currentTrackIndex].cells[row] = TrackerCell.empty();
    notifyListeners();
  }

  /// Reads the FX command for an fxval column (null if not an fxval column).
  int? _fxCommandFor(TrackerCell cell, CellColumn col) {
    switch (col) {
      case CellColumn.fx0val:
        return cell.fxSlots[0].command;
      case CellColumn.fx1val:
        return cell.fxSlots[1].command;
      case CellColumn.fx2val:
        return cell.fxSlots[2].command;
      default:
        return null;
    }
  }

  /// Find the nearest row BEFORE [toRow] (exclusive) in [col] on [track]
  /// that has a value. Returns null if none exists.
  /// For fxval columns, the target row must already have an FX command and
  /// the previous valued row must carry that same FX command.
  int? _findInterpolationSource(TrackModel track, int toRow, CellColumn col) {
    final targetCmd = _fxCommandFor(track.cells[toRow], col);
    if (col == CellColumn.fx0val ||
        col == CellColumn.fx1val ||
        col == CellColumn.fx2val) {
      if (targetCmd == null) return null;
    }
    for (int r = toRow - 1; r >= 0; r--) {
      final cell = track.cells[r];
      if (track.readColumnValue(r, col) != null) {
        // For fxval, require matching command on the previous value row.
        if (targetCmd != null) {
          final srcCmd = _fxCommandFor(cell, col);
          if (srcCmd != targetCmd) return null;
        }
        return r;
      }
    }
    return null;
  }

  /// Returns true if interpolation can be offered for the selected cell.
  /// Requires: col is volume or fxval, the cell has a value, and there is a
  /// previous row with a value. For fxval columns, both ends must also carry
  /// the same FX command.
  bool canInterpolate(int row, CellColumn col) {
    if (col == CellColumn.note ||
        col == CellColumn.instrument ||
        col == CellColumn.fx0cmd ||
        col == CellColumn.fx1cmd ||
        col == CellColumn.fx2cmd) {
      return false;
    }
    final track = currentTrack;
    if (row <= 0 || row >= track.cells.length) return false;
    if (track.readColumnValue(row, col) == null) return false;
    return _findInterpolationSource(track, row, col) != null;
  }

  /// Fill every row between the previous valued row and [toRow] (exclusive
  /// of both endpoints) with gamma-curved interpolated values for [col].
  /// Interpolation uses time-accurate beat positions so per-beat line
  /// overrides are handled correctly. For FX value columns, every filled row
  /// is also stamped with the matching FX command from [toRow].
  /// An [FxEnvelopeRun] is stored on the pattern for visual overlay;
  /// [gamma] defaults to 1.0 (linear). If a run already exists for the same
  /// track + slot range, it is replaced.
  void interpolateColumn(int toRow, CellColumn col, {double gamma = 1.0}) {
    final track = currentTrack;
    final fromRow = _findInterpolationSource(track, toRow, col);
    if (fromRow == null) return;

    final startVal = track.readColumnValue(fromRow, col)!;
    final endVal = track.readColumnValue(toRow, col)!;
    if (startVal == endVal) return; // nothing to do

    final tStart = currentPattern.rowTimeInBeats(fromRow);
    final tEnd = currentPattern.rowTimeInBeats(toRow);
    if (tEnd <= tStart) return;

    final span = tEnd - tStart;
    for (int r = fromRow + 1; r < toRow; r++) {
      final t = currentPattern.rowTimeInBeats(r);
      final frac = (t - tStart) / span;
      final curved = math.pow(frac.clamp(0.0, 1.0), gamma).toDouble();
      final interpolated = (startVal + (endVal - startVal) * curved).round();
      track.writeColumnValue(r, col, interpolated);
      // For fxval columns, also stamp the FX command so the cell is complete.
      final cmd = _fxCommandFor(track.cells[toRow], col);
      if (cmd != null) {
        switch (col) {
          case CellColumn.fx0val:
            track.cells[r].fxSlots[0].command = cmd;
          case CellColumn.fx1val:
            track.cells[r].fxSlots[1].command = cmd;
          case CellColumn.fx2val:
            track.cells[r].fxSlots[2].command = cmd;
          default:
            break;
        }
      }
    }

    // Store envelope metadata for the visual overlay (fxval columns only).
    final slotIndex = _fxSlotIndexForColumn(col);
    if (slotIndex >= 0) {
      // Remove any existing run that overlaps this track + slot + row range.
      currentPattern.fxEnvelopes.removeWhere(
        (e) =>
            e.trackIndex == _currentTrackIndex &&
            e.fxSlotIndex == slotIndex &&
            e.startRow == fromRow &&
            e.endRow == toRow,
      );
      currentPattern.fxEnvelopes.add(
        FxEnvelopeRun(
          trackIndex: _currentTrackIndex,
          fxSlotIndex: slotIndex,
          startRow: fromRow,
          endRow: toRow,
          startValue: startVal,
          endValue: endVal,
          gamma: gamma,
        ),
      );
    }

    notifyListeners();
  }

  // ── FX Envelope helpers ──────────────────────────────────────────────────

  /// Returns the fxSlotIndex (0/1/2) for an fxval column, or -1 otherwise.
  static int _fxSlotIndexForColumn(CellColumn col) {
    switch (col) {
      case CellColumn.fx0val:
        return 0;
      case CellColumn.fx1val:
        return 1;
      case CellColumn.fx2val:
        return 2;
      default:
        return -1;
    }
  }

  /// Returns the [FxEnvelopeRun] that contains [row] for the given
  /// [trackIndex] and [fxSlotIndex], or null if none.
  FxEnvelopeRun? fxEnvelopeAt(int trackIndex, int fxSlotIndex, int row) {
    for (final run in currentPattern.fxEnvelopes) {
      if (run.trackIndex == trackIndex &&
          run.fxSlotIndex == fxSlotIndex &&
          run.containsRow(row)) {
        return run;
      }
    }
    return null;
  }

  /// Re-bake the interior rows of [run] using a new [gamma] value and
  /// update [run.gamma]. Anchor rows (startRow / endRow) are not touched.
  void updateEnvelopeGamma(FxEnvelopeRun run, double newGamma) {
    run.gamma = newGamma.clamp(0.1, 4.0);
    final track = currentPattern.tracks[run.trackIndex];
    final tStart = currentPattern.rowTimeInBeats(run.startRow);
    final tEnd = currentPattern.rowTimeInBeats(run.endRow);
    if (tEnd <= tStart) return;
    final span = tEnd - tStart;
    for (int r = run.startRow + 1; r < run.endRow; r++) {
      final t = currentPattern.rowTimeInBeats(r);
      final frac = (t - tStart) / span;
      track.writeColumnValue(r, run.valColumn, run.valueAt(frac));
    }
    notifyListeners();
  }

  /// Remove the envelope run from the pattern. Cell values are kept as-is.
  void deleteEnvelope(FxEnvelopeRun run) {
    currentPattern.fxEnvelopes.remove(run);
    notifyListeners();
  }

  void copyRow(int row) {
    _rowClipboard = [currentTrack.cells[row].copy()];
    notifyListeners();
  }

  void pasteRow(int row) {
    if (_rowClipboard == null || _rowClipboard!.isEmpty) return;
    // Paste at the specified row, using first row from clipboard
    currentTrack.cells[row] = _rowClipboard!.first.copy();
    // Select the pasted row
    _selectedRowStart = row;
    _selectedRowEnd = row;
    notifyListeners();
  }

  void deleteRow(int row) {
    currentTrack.cells[row] = TrackerCell.empty();
    notifyListeners();
  }

  /// Copy multiple rows (inclusive range).
  void copyRows(int startRow, int endRow) {
    if (startRow < 0 || endRow >= rowCount) return;
    final min = startRow < endRow ? startRow : endRow;
    final max = startRow < endRow ? endRow : startRow;
    _rowClipboard = [];
    for (int r = min; r <= max; r++) {
      _rowClipboard!.add(currentTrack.cells[r].copy());
    }
    notifyListeners();
  }

  /// Cut multiple rows = copy + clear.
  void cutRows(int startRow, int endRow) {
    copyRows(startRow, endRow);
    deleteRows(startRow, endRow);
    clearRowSelection();
  }

  /// Delete multiple rows (inclusive range) by clearing them to empty.
  void deleteRows(int startRow, int endRow) {
    if (startRow < 0 || endRow >= rowCount) return;
    final min = startRow < endRow ? startRow : endRow;
    final max = startRow < endRow ? endRow : startRow;
    for (int r = min; r <= max; r++) {
      currentTrack.cells[r] = TrackerCell.empty();
    }
    notifyListeners();
  }

  /// Paste multiple rows starting at [insertRow].
  /// If rows go beyond pattern end, they are silently truncated.
  /// Selected rows become the newly pasted range.
  void pasteRows(int insertRow) {
    if (_rowClipboard == null || _rowClipboard!.isEmpty) return;
    if (insertRow < 0 || insertRow >= rowCount) return;

    final cells = currentTrack.cells;
    final pastedCount = (_rowClipboard!.length).clamp(0, rowCount - insertRow);

    for (int i = 0; i < pastedCount; i++) {
      cells[insertRow + i] = _rowClipboard![i].copy();
    }

    // Select the newly pasted range
    _selectedRowStart = insertRow;
    _selectedRowEnd = insertRow + pastedCount - 1;
    clearBoxSelection();
    notifyListeners();
  }

  /// Duplicate the selected row block immediately below itself.
  /// This is equivalent to copy + paste at the next available row.
  /// If the duplicated block would exceed the pattern length, it is truncated.
  void duplicateSelectedRows() {
    final range = selectedRowRange;
    if (range == null) return;

    final startRow = range.$1;
    final endRow = range.$2;
    final insertRow = endRow + 1;
    if (insertRow >= rowCount) return;

    copyRows(startRow, endRow);
    pasteRows(insertRow);
  }

  // ── Row randomisers ───────────────────────────────────────────────────────

  /// SHUF: Shuffle whole cells between rows that already have an actual note.
  /// Empty rows, hold rows, and note-off rows stay in place.
  void shuffleSelectedRows() {
    final range = selectedRowRange;
    if (range == null) return;
    final cells = currentTrack.cells;
    final rnd = math.Random();

    final noteIndices = <int>[];
    for (int r = range.$1; r <= range.$2; r++) {
      if (cells[r].note.isNote) noteIndices.add(r);
    }
    if (noteIndices.length < 2) return;

    final noteCells = noteIndices.map((r) => cells[r].copy()).toList();
    // Fisher-Yates shuffle
    for (int i = noteCells.length - 1; i > 0; i--) {
      final j = rnd.nextInt(i + 1);
      final tmp = noteCells[i];
      noteCells[i] = noteCells[j];
      noteCells[j] = tmp;
    }
    for (int i = 0; i < noteIndices.length; i++) {
      cells[noteIndices[i]] = noteCells[i];
    }
    notifyListeners();
  }

  /// SCAT: Scatter whole note cells to random positions within the selection.
  /// Empty rows can receive cells; total note-cell count is preserved.
  void scatterSelectedRows() {
    final range = selectedRowRange;
    if (range == null) return;
    final cells = currentTrack.cells;
    final rnd = math.Random();

    final noteCells = <TrackerCell>[];
    for (int r = range.$1; r <= range.$2; r++) {
      if (cells[r].note.isNote) noteCells.add(cells[r].copy());
    }
    if (noteCells.isEmpty) return;

    // Pick random target rows (no duplicates) from the full range
    final rowPool = List<int>.generate(
      range.$2 - range.$1 + 1,
      (i) => range.$1 + i,
    );
    for (int i = rowPool.length - 1; i > 0; i--) {
      final j = rnd.nextInt(i + 1);
      final tmp = rowPool[i];
      rowPool[i] = rowPool[j];
      rowPool[j] = tmp;
    }

    // Clear every row in range, then place note cells at the first N targets
    for (int r = range.$1; r <= range.$2; r++) {
      cells[r] = TrackerCell.empty();
    }
    for (int i = 0; i < noteCells.length; i++) {
      cells[rowPool[i]] = noteCells[i];
    }
    notifyListeners();
  }

  /// RAND: Note positions stay fixed; pitch changes to a random MIDI value
  /// within the min–max range of notes already in the selection.
  void randomizePitchInSelection() {
    final range = selectedRowRange;
    if (range == null) return;
    final cells = currentTrack.cells;
    final rnd = math.Random();

    // Collect note row indices and find min/max pitch
    final noteRows = <int>[];
    int? minMidi, maxMidi;
    for (int r = range.$1; r <= range.$2; r++) {
      if (!cells[r].note.isNote) continue;
      noteRows.add(r);
      final midi = cells[r].note.midiNote;
      if (minMidi == null || midi < minMidi) minMidi = midi;
      if (maxMidi == null || midi > maxMidi) maxMidi = midi;
    }
    if (minMidi == null || maxMidi == null || minMidi == maxMidi) return;

    // Build pitch list: anchor min and max so the range never collapses,
    // then fill the remaining slots with random values within the range.
    final span = maxMidi - minMidi;
    final pitches = <int>[minMidi, maxMidi];
    for (int i = 2; i < noteRows.length; i++) {
      pitches.add(minMidi + rnd.nextInt(span + 1));
    }
    // Shuffle so anchored pitches land at random positions
    for (int i = pitches.length - 1; i > 0; i--) {
      final j = rnd.nextInt(i + 1);
      final tmp = pitches[i];
      pitches[i] = pitches[j];
      pitches[j] = tmp;
    }

    for (int i = 0; i < noteRows.length; i++) {
      // scrollIndex = midiNote - 11  (C-0 MIDI 12 → scrollIndex 1)
      cells[noteRows[i]].note = NoteValue.fromScrollIndex(pitches[i] - 11);
    }
    notifyListeners();
  }

  /// Transpose every note row in the selection by [delta] semitones.
  /// Notes at the edge of the range are clamped (not wrapped).
  /// Empty, hold, and note-off rows are left unchanged.
  void transposeSelectionBySemitones(int delta) {
    final range = selectedRowRange;
    if (range == null) return;
    final cells = currentTrack.cells;
    for (int r = range.$1; r <= range.$2; r++) {
      if (!cells[r].note.isNote) continue;
      final newScroll = (cells[r].note.scrollIndex + delta).clamp(1, 120);
      cells[r].note = NoteValue.fromScrollIndex(newScroll);
    }
    notifyListeners();
  }


  void deleteBoxSelection() {
    final sel = _boxSelection;
    if (sel == null) return;
    final track = currentPattern.tracks[sel.trackIndex];
    for (int row = sel.minRow; row <= sel.maxRow; row++) {
      for (
        int colIndex = sel.minColumnIndex;
        colIndex <= sel.maxColumnIndex;
        colIndex++
      ) {
        _clearColumnValueInTrack(track, row, CellColumn.values[colIndex]);
      }
    }
    _boxSelection = null;
    _isBoxSelecting = false;
    notifyListeners();
  }

  // ── Track collapse ────────────────────────────────────────────────────────

  void toggleCollapsedView() {
    collapsedView = !collapsedView;
    if (collapsedView) {
      _boxSelection = null;
      _isBoxSelecting = false;
    }
    notifyListeners();
  }

  // ── Song pattern management ──────────────────────────────────────────────

  /// Append a new empty pattern to the end of the song.
  void appendNewPattern() {
    if (song.patterns.length >= kMaxSongPatterns) return;
    final idx = song.addPattern();
    _copyProjectMixerStateToPattern(song.patterns[idx]);
    _copyProjectSendRoutingToPattern(song.patterns[idx]);
    notifyListeners();
  }

  /// Insert a new empty pattern at [index] (0-based).
  void insertNewPatternAt(int index) {
    if (song.patterns.length >= kMaxSongPatterns) return;
    final clamped = index.clamp(0, song.patterns.length);
    final pattern = song.createEmptyPattern();
    _copyProjectMixerStateToPattern(pattern);
    _copyProjectSendRoutingToPattern(pattern);
    song.patterns.insert(clamped, pattern);
    notifyListeners();
  }

  /// Move a pattern from [from] to [to] (insert-before semantics).
  void movePattern(int from, int to) {
    if (from == to) return;
    if (from < 0 || from >= song.patterns.length) return;
    final dest = to.clamp(0, song.patterns.length - 1);
    final pat = song.patterns.removeAt(from);
    // After removing [from], indices above it shift down by one.
    // To keep "insert before drop target" behavior, adjust when moving down.
    final insertAt = dest > from ? dest - 1 : dest;
    song.patterns.insert(insertAt, pat);
    // Keep editor focused on the moved pattern.
    _currentPatternIndex = insertAt.clamp(0, song.patterns.length - 1);
    _currentArrangementSlotIndex = _currentPatternIndex;
    notifyListeners();
  }

  /// Insert a deep copy of pattern [sourceIndex] at position [destIndex].
  void copyPatternInsertAt(int sourceIndex, int destIndex) {
    if (song.patterns.length >= kMaxSongPatterns) return;
    song.insertCopyAt(sourceIndex, destIndex);
    _currentPatternIndex = destIndex.clamp(0, song.patterns.length - 1);
    _currentArrangementSlotIndex = _currentPatternIndex;
    notifyListeners();
  }

  void duplicatePattern(int index) {
    if (index < 0 || index >= song.patterns.length) return;
    copyPatternInsertAt(index, index + 1);
  }

  bool canMergePatternWithNext(int index) {
    if (index < 0 || index >= song.patterns.length - 1) return false;
    final current = song.patterns[index];
    final next = song.patterns[index + 1];
    final currentBpm = current.bpm ?? 120.0;
    final nextBpm = next.bpm ?? 120.0;
    if (currentBpm != nextBpm) return false;
    if (current.lpb != next.lpb) return false;
    if (current.beatCount + next.beatCount > 99) return false;
    return true;
  }

  bool canDoublePattern(int index) {
    if (index < 0 || index >= song.patterns.length) return false;
    if (song.patterns.length >= kMaxSongPatterns) return false;
    final pattern = song.patterns[index];
    if (pattern.beatCount * 2 > 99) return false;
    return true;
  }

  void mergePatternWithNext(int index) {
    if (!canMergePatternWithNext(index)) return;
    final current = song.patterns[index];
    final next = song.patterns[index + 1];
    final mergedBeatCount = current.beatCount + next.beatCount;
    final mergedBeatOverrides = <int?>[
      ...current.beatLineOverrides,
      ...next.beatLineOverrides,
    ];

    for (int trackIndex = 0; trackIndex < current.tracks.length; trackIndex++) {
      final currentTrack = current.tracks[trackIndex];
      final nextTrack = next.tracks[trackIndex];
      currentTrack.cells.addAll(nextTrack.cells.map((cell) => cell.copy()));
    }

    current.beats = mergedBeatCount;
    current.beatLineOverrides = mergedBeatOverrides;
    current.syncTrackLengths();
    song.patterns.removeAt(index + 1);
    _currentPatternIndex = index.clamp(0, song.patterns.length - 1);
    _currentArrangementSlotIndex = _currentArrangementSlotIndex.clamp(
      0,
      song.patterns.length - 1,
    );
    notifyListeners();
  }

  void doublePattern(int index) {
    if (!canDoublePattern(index)) return;
    duplicatePattern(index);
    mergePatternWithNext(index);
    _currentPatternIndex = index.clamp(0, song.patterns.length - 1);
    _currentArrangementSlotIndex = _currentPatternIndex;
    if (_playbackFollowsSong) {
      _playheadArrangementSlot = _currentArrangementSlotIndex;
      _syncCurrentPatternToSongPlayhead();
      playheadRow = 0;
    }
    notifyListeners();
  }

  void movePatternUp(int index) {
    if (index <= 0 || index >= song.patterns.length) return;
    final pat = song.patterns.removeAt(index);
    final newIndex = index - 1;
    song.patterns.insert(newIndex, pat);
    _currentPatternIndex = newIndex;
    _currentArrangementSlotIndex = newIndex;
    notifyListeners();
  }

  void movePatternDown(int index) {
    if (index < 0 || index >= song.patterns.length - 1) return;
    final pat = song.patterns.removeAt(index);
    final newIndex = index + 1;
    song.patterns.insert(newIndex, pat);
    _currentPatternIndex = newIndex;
    _currentArrangementSlotIndex = newIndex;
    notifyListeners();
  }

  /// Ensure a real pattern exists at [index], filling any gap with empty
  /// patterns. Used to "park" a new pattern below the song boundary.
  void createPatternAt(int index) {
    if (index < 0 || index >= kMaxSongPatterns) return;
    // Fill gap with empty patterns up to and including [index].
    while (song.patterns.length <= index) {
      if (song.patterns.length >= kMaxSongPatterns) return;
      final pattern = song.createEmptyPattern();
      _copyProjectMixerStateToPattern(pattern);
      _copyProjectSendRoutingToPattern(pattern);
      song.patterns.add(pattern);
    }
    // The slot at [index] is now an existing empty pattern — leave it as the
    // newly "created" pattern (it's already blank and editable).
    _currentPatternIndex = index;
    _currentArrangementSlotIndex = index;
    notifyListeners();
  }

  void removePattern(int index) {
    if (song.patterns.length <= 1) return;
    if (index < 0 || index >= song.patterns.length) return;
    song.patterns.removeAt(index);
    if (_currentPatternIndex >= song.patterns.length) {
      _currentPatternIndex = song.patterns.length - 1;
    }
    _currentArrangementSlotIndex = _currentArrangementSlotIndex.clamp(
      0,
      song.patterns.length - 1,
    );
    notifyListeners();
  }

  double get masterVolume => song.masterVolume;
  bool get masterMute => song.masterMute;

  void setMasterVolume(double value) {
    song.masterVolume = value.clamp(0.0, 1.0);
    // Queue M02 (master volume) command: [channel=0, controller=2, value, unused]
    final volumeInt = (song.masterVolume * 99).round().clamp(0, 99);
    AudioEngine.instance.queueMixerCommands([0, 2, volumeInt, 0]);
    notifyListeners();
  }

  void toggleMasterMute() {
    song.masterMute = !song.masterMute;
    // Queue M01 (master mute) command: [channel=0, controller=1, value, unused]
    // value > 0 means muted, 0 means unmuted
    final muteValue = song.masterMute ? 1 : 0;
    AudioEngine.instance.queueMixerCommands([0, 1, muteValue, 0]);
    notifyListeners();
  }

  /// Set the editor focus to a pattern by its position in the song.
  void selectSongPattern(int patternIndex) {
    if (patternIndex < 0 || patternIndex >= song.patterns.length) return;
    _currentArrangementSlotIndex = patternIndex;

    // While song-follow playback is running, tapping a slot queues a jump
    // to happen on the next pattern boundary instead of an immediate seek.
    if (isPlaying && _playbackFollowsSong) {
      _queuedArrangementSlot = patternIndex == _playheadArrangementSlot
          ? null
          : patternIndex;
      notifyListeners();
      return;
    }

    _queuedArrangementSlot = null;
    if (!isPlaying || _playbackFollowsSong) {
      _playheadArrangementSlot = patternIndex;
    }
    selectPattern(patternIndex);
  }

  /// Queue a song jump to happen at the next pattern boundary.
  ///
  /// This is intentionally silent (no notify) so UI can opt into a cheap
  /// local redraw without forcing a whole-app rebuild during playback.
  void queueSongPatternJump(int patternIndex) {
    if (patternIndex < 0 || patternIndex >= song.patterns.length) return;
    _queuedArrangementSlot = patternIndex == _playheadArrangementSlot
        ? null
        : patternIndex;
  }

  /// Called by MainScreen whenever the user switches tabs.
  /// This is the sole source of truth for which mode play() will use next.
  void setActiveTabIndex(int index) {
    _activeTabIndex = index;
  }

  // ── Transport ────────────────────────────────────────────────────────────

  int _waveCodeForInstrumentSlot(int slot) {
    final safe = slot.clamp(0, instruments.length - 1);
    final ins = instruments[safe];
    // For sampler instruments we encode the instrument slot index here.
    // Native interprets this as sample-slot id when instrumentType=1.
    if (ins.type == InstrumentType.sampler) return safe;
    if (ins.type == InstrumentType.karplusStrong) return 0;
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
    final ins = instruments[safe];
    if (ins.type == InstrumentType.sampler) return 1;
    if (ins.type == InstrumentType.karplusStrong) return 2;
    return 0;
  }

  int _norm01ToAudio255(double v) => (v.clamp(0.0, 1.0) * 255.0).round();

  /// Converts a 00-99 UI value to a 0-255 audio byte.
  int _ui99ToAudio255(int v) => ((v.clamp(0, 99) * 255) / 99).round();

  List<int> _synthParamsForInstrumentSlot(
    int slot, {
    int samplerSlice = 0,
    bool samplerSliceActive = false,
    bool samplerPlayThrough = false,
    double? samplerStartNorm,
    double? samplerEndNorm,
    bool samplerReverse = false,
    double? vibSpeedNorm, // VIB: overrides lfoRate (pitch target)
    double? vibDepthNorm, // VIB: overrides lfoDepth
    double? treSpeedNorm, // TRE/GAT: tremolo/gate speed
    double? treDepthNorm, // TRE/GAT: tremolo/gate depth
    int? treMode, // TRE/GAT: 0=off, 1=sine (TRE), 2=square (GAT)
  }) {
    final safe = slot.clamp(0, instruments.length - 1);
    final ins = instruments[safe];
    if (ins.type == InstrumentType.sampler) {
      final sp = ins.sampler;
      final detuneNorm = ((sp.pitch + 1.0) / 2.0).clamp(0.0, 1.0);
      double startNorm = (samplerStartNorm ?? sp.start).clamp(0.0, 1.0);
      double endNorm = (samplerEndNorm ?? sp.end).clamp(0.0, 1.0);
      if (samplerSliceActive) {
        if (samplerSlice == 0) {
          // SL0: start stays at sp.start (sampler start knob) — same as a plain note.
          // startNorm is already set to sp.start above, nothing to override.
        } else {
          final sliceStart = sp.sliceStartNorm(samplerSlice);
          if (sliceStart != null) {
            startNorm = sliceStart.clamp(0.0, 1.0);
          }
          // If the slice marker is unset (sliceStart == null), startNorm stays
          // at sp.start — the user hasn't placed this slice yet.
        }
        endNorm = sp
            .sliceEndNorm(samplerSlice, playThrough: samplerPlayThrough)
            .clamp(startNorm, 1.0);
      }
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
        _norm01ToAudio255(sp.attack), // atk  ← sampler attack
        _norm01ToAudio255(0.30), // dec
        _norm01ToAudio255(0.80), // sus
        _norm01ToAudio255(sp.release), // rel  ← sampler release
        _norm01ToAudio255(0.00), // glide
        _norm01ToAudio255(sp.volume), // sampler volume / synth instVol
        _norm01ToAudio255(startNorm), // lfoRate reused as sampler start
        _norm01ToAudio255(endNorm), // lfoDepth reused as sampler end
        0, // lfoTarget: pitch
        sp
            .loopMode
            .index, // drive reused as loop mode: 0=off, 1=forward, 2=pingpong
        samplerReverse ? 1 : 0, // reverse flag (REV FX)
        // OSC fields — not applicable for sampler, use safe defaults
        255, // osc1Gain (full)
        0, // osc2On
        0, // osc2Wave
        128, // osc2Detune (0 semitones)
        0, // osc2Gain
        0, // osc3On
        0, // osc3Wave
        128, // osc3Detune
        0, // osc3Gain
        0, // osc2FmDepth
        0, // osc3FmDepth
        2, // osc1Oct (0=−2..4=+2; 2=0)
        2, // osc2Oct
        2, // osc3Oct
        _norm01ToAudio255(treSpeedNorm ?? 0.0), // treSpeed (TRE/GAT)
        _norm01ToAudio255(treDepthNorm ?? 0.0), // treDepth
        treMode ?? 0, // treMode: 0=off, 1=TRE(sine), 2=GAT(square)
      ];
    }
    if (ins.type == InstrumentType.karplusStrong) {
      final kp = ins.karplus;
      return <int>[
        _norm01ToAudio255(kp.decay),
        _norm01ToAudio255(kp.damping),
        _norm01ToAudio255(kp.tone),
        _norm01ToAudio255(kp.stretch),
        _norm01ToAudio255(kp.pickPosition),
        _norm01ToAudio255(kp.attackColor),
        _norm01ToAudio255(kp.body),
        _norm01ToAudio255(kp.drive),
        0,
        0,
        0,
        0,
        0,
        0,
        _norm01ToAudio255(0.95),
        0,
        0,
        0,
        0,
        0,
        // OSC fields — not applicable for Karplus, use safe defaults
        255, // osc1Gain (full)
        0, // osc2On
        0, // osc2Wave
        128, // osc2Detune
        0, // osc2Gain
        0, // osc3On
        0, // osc3Wave
        128, // osc3Detune
        0, // osc3Gain
        0, // osc2FmDepth
        0, // osc3FmDepth
        2, // osc1Oct (0=−2..4=+2; 2=0)
        2, // osc2Oct
        2, // osc3Oct
        _norm01ToAudio255(treSpeedNorm ?? 0.0), // treSpeed (TRE/GAT)
        _norm01ToAudio255(treDepthNorm ?? 0.0), // treDepth
        treMode ?? 0, // treMode: 0=off, 1=TRE(sine), 2=GAT(square)
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
      _norm01ToAudio255(vibSpeedNorm ?? p.lfoRate),
      _norm01ToAudio255(vibDepthNorm ?? p.lfoDepth),
      vibSpeedNorm != null
          ? 0
          : p.lfoTarget.index2, // force pitch target for VIB
      _norm01ToAudio255(p.drive),
      0, // reverse: not applicable for synth
      // Multi-oscillator
      _norm01ToAudio255(p.osc1Gain),
      p.osc2On ? 255 : 0, // osc2On
      p.osc2Wave.index, // osc2Wave (raw enum index, 0-5)
      _norm01ToAudio255((p.osc2Detune + 1.0) / 2.0), // map -1..1 → 0..1
      _norm01ToAudio255(p.osc2Gain),
      p.osc3On ? 255 : 0, // osc3On
      p.osc3Wave.index, // osc3Wave
      _norm01ToAudio255((p.osc3Detune + 1.0) / 2.0),
      _norm01ToAudio255(p.osc3Gain),
      _norm01ToAudio255(p.osc2FmDepth),
      _norm01ToAudio255(p.osc3FmDepth),
      p.osc1Oct + 2, // −2..+2 → 0..4
      p.osc2Oct + 2,
      p.osc3Oct + 2,
      _norm01ToAudio255(treSpeedNorm ?? 0.0), // treSpeed (TRE/GAT)
      _norm01ToAudio255(treDepthNorm ?? 0.0), // treDepth
      treMode ?? 0, // treMode: 0=off, 1=TRE(sine), 2=GAT(square)
    ];
  }

  /// Apply any active Pxx carries for track [t] to [synthParams] (mutates it).
  /// Returns the (possibly overridden) waveCmd for the track.
  ///
  /// synthParams layout (20 values, indices 0-19):
  ///  0=detune, 1=cutoff, 2=res, 3=fMode, 4-8=filterADSR+amt,
  ///  9=atk, 10=dec, 11=sus, 12=rel, 13=glide, 14=instVol,
  ///  15=lfoRate/start, 16=lfoDepth/end, 17=lfoTgt, 18=drive/loop, 19=reverse
  int _applyInstrumentParamCarry(
    int t,
    int slot,
    List<int> synthParams,
    int waveCmd,
  ) {
    if (t >= _carryInstrumentParamsByTrack.length) return waveCmd;
    final carry = _carryInstrumentParamsByTrack[t];
    if (carry.isEmpty) return waveCmd;
    final instrumentType =
        instruments[slot.clamp(0, instruments.length - 1)].type;
    int overriddenWave = waveCmd;
    carry.forEach((paramIdx, rawVal) {
      if (instrumentType == InstrumentType.sampler) {
        switch (paramIdx) {
          case 1:
            synthParams[15] = _ui99ToAudio255(rawVal); // start
          case 2:
            synthParams[16] = _ui99ToAudio255(rawVal); // end
          case 3:
            synthParams[0] = _ui99ToAudio255(rawVal); // pitch/detune
          case 4:
            synthParams[14] = _ui99ToAudio255(rawVal); // volume
          case 5:
            synthParams[9] = _ui99ToAudio255(rawVal); // attack
          case 6:
            synthParams[12] = _ui99ToAudio255(rawVal); // release
          case 7:
            synthParams[18] = rawVal.clamp(0, 2); // loop mode (direct)
        }
      } else if (instrumentType == InstrumentType.karplusStrong) {
        switch (paramIdx) {
          case 1:
            synthParams[0] = _ui99ToAudio255(rawVal); // decay
          case 2:
            synthParams[1] = _ui99ToAudio255(rawVal); // damping
          case 3:
            synthParams[2] = _ui99ToAudio255(rawVal); // tone
          case 4:
            synthParams[3] = _ui99ToAudio255(rawVal); // stretch
          case 5:
            synthParams[4] = _ui99ToAudio255(rawVal); // pick position
          case 6:
            synthParams[5] = _ui99ToAudio255(rawVal); // attack color
          case 7:
            synthParams[6] = _ui99ToAudio255(rawVal); // body
          case 8:
            synthParams[7] = _ui99ToAudio255(rawVal); // drive
        }
      } else {
        switch (paramIdx) {
          case 1:
            synthParams[14] = _ui99ToAudio255(rawVal); // volume
          case 2:
            synthParams[9] = _ui99ToAudio255(rawVal); // attack
          case 3:
            synthParams[10] = _ui99ToAudio255(rawVal); // decay
          case 4:
            synthParams[11] = _ui99ToAudio255(rawVal); // sustain
          case 5:
            synthParams[12] = _ui99ToAudio255(rawVal); // release
          case 6:
            synthParams[1] = _ui99ToAudio255(rawVal); // cutoff
          case 7:
            synthParams[2] = _ui99ToAudio255(rawVal); // resonance
          case 8:
            synthParams[18] = _ui99ToAudio255(rawVal); // drive
          case 9:
            synthParams[0] = _ui99ToAudio255(rawVal); // detune
          case 10:
            synthParams[13] = _ui99ToAudio255(rawVal); // glide
          case 11:
            synthParams[15] = _ui99ToAudio255(rawVal); // lfoRate
          case 12:
            synthParams[16] = _ui99ToAudio255(rawVal); // lfoDepth
          case 13:
            overriddenWave = rawVal.clamp(0, 5); // waveform (direct)
        }
      }
    });
    return overriddenWave;
  }

  int _previewVoiceIndexForInstrumentSlot(int slot) {
    return slot.clamp(0, _audioVoiceCount - 1);
  }

  List<int> _buildPreviewRowData({
    required int voiceIdx,
    required int note,
    required int waveCmd,
    required int instrumentTypeCmd,
    required List<int> synthParams,
  }) {
    final rowData = List<int>.filled(_audioVoiceCount * _audioRowStride, 0);
    for (int track = 0; track < _audioVoiceCount; track++) {
      final base = track * _audioRowStride;
      rowData[base] = -1; // hold/empty
      rowData[base + 1] = -1; // keep volume
      rowData[base + 2] = -1; // keep pan
      rowData[base + 3] = 0;
      rowData[base + 4] = 0;
      for (int i = 0; i < synthParams.length; i++) {
        rowData[base + 5 + i] = 0;
      }
    }

    final targetBase =
        voiceIdx.clamp(0, _audioVoiceCount - 1) * _audioRowStride;
    rowData[targetBase] = note;
    rowData[targetBase + 1] = 255;
    rowData[targetBase + 2] = 128;
    rowData[targetBase + 3] = waveCmd;
    rowData[targetBase + 4] = instrumentTypeCmd;
    for (int i = 0; i < synthParams.length; i++) {
      rowData[targetBase + 5 + i] = synthParams[i];
    }

    return rowData;
  }

  Future<void> _primeAudioForPreview() async {
    // Preview must not resume stale queued transport rows.
    await AudioEngine.instance.clearQueuedPlaybackRows();
    await AudioEngine.instance.setQueuedPlaybackLooping(false);
    await AudioEngine.instance.resetPlayheadPhase();
    await AudioEngine.instance.start();
  }

  Future<void> _setPreviewDryBypass(int voiceIdx, bool enabled) async {
    final safeVoice = voiceIdx.clamp(0, _audioVoiceCount - 1);
    await AudioEngine.instance.setVoicePreviewBypassTrackInserts(
      safeVoice,
      enabled,
    );
    if (enabled) {
      _previewBypassVoice = safeVoice;
    } else if (_previewBypassVoice == safeVoice) {
      _previewBypassVoice = -1;
    }
  }

  void _resetInstrumentCarry() {
    _carryInstrumentByTrack = const [];
    _carryNoteByTrack = const [];
    _carryVolumeByTrack = const [];
    _carryVibSpeedByTrack = const [];
    _carryVibDepthByTrack = const [];
    _carryVolFxByTrack = const [];
    _carryPanFxByTrack = const [];
    _carryTreSpeedByTrack = const [];
    _carryTreDepthByTrack = const [];
    _carryTreModeByTrack = const [];
    _carryArpByTrack = const [];
    _carrySlideByTrack = const [];
    _carryInstrumentParamsByTrack = const [];
    _carryPatternIndex = -1;
  }

  /// Capture current instrument states as snapshots for reset (XY0) commands.
  void _captureStartStates() {
    for (final instrument in instruments) {
      instrument.synthStartState = instrument.synth.copy();
      instrument.samplerStartState = instrument.sampler.copy();
    }
  }

  Future<void> play() async {
    if (isPlaying) return;
    // Derive song-follow mode from whichever tab is currently active.
    // SONG(0), INST(2), MIXER(3) → song follows arrangement;
    // PATTERN(1) → loops current pattern only.
    _playbackFollowsSong = (_activeTabIndex != 1);
    _queuedArrangementSlot = null;
    if (_playbackFollowsSong && song.patterns.isNotEmpty) {
      _playheadArrangementSlot = _currentArrangementSlotIndex.clamp(
        0,
        song.patterns.length - 1,
      );
      _syncCurrentPatternToSongPlayhead();
      playheadRow = 0;
    }
    _resetInstrumentCarry();
    _captureStartStates();
    isPlaying = true;

    if (_playbackFollowsSong) {
      await _loadNativeSongPlaybackQueue(
        startSlot: _playheadArrangementSlot,
        startRow: 0,
      );
      await AudioEngine.instance.start();
      _startNativeSongPoller();
      notifyListeners();
      return;
    }

    await _loadNativePatternPlaybackQueue(startRow: playheadRow);
    await AudioEngine.instance.start();
    _startNativePatternPlayheadPoller();
    notifyListeners();
  }

  void setLoopPlaybackEnabled(bool enabled) {
    if (_loopPlaybackEnabled == enabled) return;
    _loopPlaybackEnabled = enabled;
    notifyListeners();
  }

  Future<void> _restartSongFromBeginningForLoop() async {
    if (!isPlaying || !_playbackFollowsSong || song.patterns.isEmpty) return;
    _queuedArrangementSlot = null;
    _playheadArrangementSlot = 0;
    _currentArrangementSlotIndex = 0;
    _syncCurrentPatternToSongPlayhead();
    playheadRow = 0;
    _songRowMap = [];
    _songFlatRowIndex = 0;
    _resetInstrumentCarry();
    _captureStartStates();
    await _loadNativeSongPlaybackQueue(startSlot: 0, startRow: 0);
    if (!isPlaying) return;
    await AudioEngine.instance.start();
    notifyListeners();
  }

  void stop() {
    _playheadTimer?.cancel();
    _playheadTimer = null;
    _playheadPollInFlight = false;
    _songPollInFlight = false;
    isPlaying = false;
    _queuedArrangementSlot = null;
    playheadRow = 0;
    _songRowMap = [];
    _songFlatRowIndex = 0;
    _resetInstrumentCarry();
    // Queue all occupied inserts for reset so mixer_screen restores slider values.
    _pendingInsertResets.clear();
    for (int t = 0; t < _trackInsertOccupied.length; t++) {
      for (int s = 0; s < _trackInsertOccupied[t].length; s++) {
        if (_trackInsertOccupied[t][s]) _pendingInsertResets.add((t, s));
      }
    }
    // Restore mixer snapshot (UI state is source of truth) before stopping.
    _queueCurrentMixerSnapshotToEngine();
    AudioEngine.instance.stop();
    // Signal any in-progress WAV export that song playback has ended.
    final completer = _exportCompleter;
    _exportCompleter = null;
    completer?.complete();
    notifyListeners();
  }

  /// Export the current song to a WAV file by tapping the stereo output
  /// while the song plays from start to finish.
  ///
  /// Returns the path of the saved file on success, or null on failure.
  Future<String?> exportSongToWav() async {
    if (isPlaying) return null; // don't interrupt live playback
    if (song.patterns.isEmpty) return null;

    // Ensure song-follow mode so the whole arrangement plays once.
    final wasFollowing = _playbackFollowsSong;
    final wasLooping = _loopPlaybackEnabled;
    _playbackFollowsSong = true;
    _loopPlaybackEnabled = false;
    _playheadArrangementSlot = 0;
    _syncCurrentPatternToSongPlayhead();
    playheadRow = 0;

    // Arm the tap before starting the engine.
    await AudioEngine.instance.startExportTap();

    // Create a completer that stop() will signal when the song ends.
    _exportCompleter = Completer<void>();
    final done = _exportCompleter!.future;

    // Start playback.
    _resetInstrumentCarry();
    _captureStartStates();
    isPlaying = true;
    await _loadNativeSongPlaybackQueue(startSlot: 0, startRow: 0);
    await AudioEngine.instance.start();
    _startNativeSongPoller();
    notifyListeners();

    // Wait for song to finish (stop() completes the future).
    await done;

    // Retrieve captured audio.
    final tap = await AudioEngine.instance.stopExportTap();

    // Restore playback mode.
    _playbackFollowsSong = wasFollowing;
    _loopPlaybackEnabled = wasLooping;

    if (tap.samples.isEmpty) return null;

    // Build stereo WAV — samples are interleaved L,R floats.
    final wavBytes = WavEncoder.encodeWav(
      samples: tap.samples,
      sampleRate: tap.sampleRate,
      numChannels: 2,
    );

    final safeName = song.name
        .replaceAll(RegExp(r'[^\w\s\-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    final fileName = '${safeName.isEmpty ? 'export' : safeName}.wav';

    if (_usesProjectTreeStorage) {
      final slug = _slugify(song.name);
      final folderName = slug.isEmpty ? 'untitled' : slug;
      final uri = await _projectStorageChannel
          .invokeMethod<String>('writeProjectBinaryFile', {
            'treeUri': _projectRootTreeUri,
            'folderName': folderName,
            'fileName': fileName,
            'bytes': wavBytes,
          });
      return uri;
    }

    final dir = await _projectDirForName(song.name);
    final filePath = '${dir.path}/$fileName';
    await File(filePath).writeAsBytes(wavBytes, flush: true);
    return filePath;
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
    final minBeats = _minimumBeatsForExistingData();
    final clamped = value.clamp(minBeats, 99);
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

  /// Override (or clear) the line count for a single beat in the current pattern.
  /// Pass null or 0 to remove the override (beat reverts to pattern default [lpb]).
  /// Valid range: 1–16.
  void setBeatLineOverride(int beat, int? lines) {
    currentPattern.setBeatLineOverride(beat, lines);
    currentPattern.syncTrackLengths();
    _clampSelectionToPattern();
    _restartPlayheadTimerIfNeeded();
    notifyListeners();
  }

  /// Duration of one line for a specific row, respecting per-beat overrides.
  Duration _lineDurationForPatternRow(PatternModel pattern, int row) {
    final beat = pattern.beatForRow(row);
    final lpbForBeat = pattern.linesForBeat(beat);
    final microsPerLine = (60000000 / ((pattern.bpm ?? 120.0) * lpbForBeat))
        .round()
        .clamp(1000, 60000000);
    return Duration(microseconds: microsPerLine);
  }

  Future<void> _loadNativePatternPlaybackQueue({required int startRow}) async {
    final originalSong = song;
    final originalPlayheadRow = playheadRow;
    final clonedSong = SongModel.fromJson(song.toJson());
    final pattern = clonedSong.patterns[_currentPatternIndex];
    final safeStartRow = startRow.clamp(0, pattern.rowCount - 1);
    final scheduledRows = <_ScheduledPlaybackRow>[];

    song = clonedSong;
    _resetInstrumentCarry();
    for (int row = 0; row < safeStartRow; row++) {
      playheadRow = row;
      _triggerCurrentRow();
    }
    for (int offset = 0; offset < pattern.rowCount; offset++) {
      final row = (safeStartRow + offset) % pattern.rowCount;
      playheadRow = row;
      scheduledRows.add(_triggerCurrentRow());
    }

    song = originalSong;
    playheadRow = originalPlayheadRow;
    _resetInstrumentCarry();

    await AudioEngine.instance.clearQueuedPlaybackRows();
    await AudioEngine.instance.setQueuedPlaybackLooping(_loopPlaybackEnabled);
    for (final row in scheduledRows) {
      await AudioEngine.instance.enqueuePlaybackRow(
        lineSamples: row.lineSamples,
        rowData: row.rowData,
        immediateKillMask: row.immediateKillMask,
        retrigData: row.retrigData,
        arpData: row.arpData,
        delayData: row.delayData,
        killData: row.killData,
        sliceCommandData: row.sliceCommandData,
        mixerCommandData: row.mixerCommandData,
        insertFxCommandData: row.insertFxCommandData,
        pitchRampData: row.pitchRampData,
      );
    }
  }

  void _startNativePatternPlayheadPoller() {
    _playheadTimer?.cancel();
    _playheadTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      unawaited(_pollNativePatternPlayhead());
    });
  }

  Future<void> _pollNativePatternPlayhead() async {
    if (!isPlaying || _playbackFollowsSong || _playheadPollInFlight) return;
    _playheadPollInFlight = true;
    try {
      final advanced = await AudioEngine.instance.consumePendingRowAdvances();
      if (!isPlaying || advanced <= 0) return;
      final newRowRaw = playheadRow + advanced;
      final didLoop = newRowRaw >= rowCount;
      playheadRow = newRowRaw % rowCount;
      if (didLoop && !_loopPlaybackEnabled) {
        stop();
        return;
      }
      notifyListeners();
    } finally {
      _playheadPollInFlight = false;
    }
  }

  // ── Song mode native queue helpers ────────────────────────────────────────

  /// Preloads the entire song arrangement (from [startSlot]/[startRow] onward)
  /// into the native C++ playback queue as a flat sequence of rows.
  /// Looping is disabled; queue exhaustion signals end of song.
  Future<void> _loadNativeSongPlaybackQueue({
    required int startSlot,
    required int startRow,
  }) async {
    if (song.patterns.isEmpty) return;

    final originalSong = song;
    final originalPlayheadRow = playheadRow;
    final originalPlayheadSlot = _playheadArrangementSlot;
    final clonedSong = SongModel.fromJson(song.toJson());

    final rowMap = <({int arrangementSlot, int rowWithinSlot})>[];
    final scheduledRows = <_ScheduledPlaybackRow>[];

    // Swap in clone so _triggerCurrentRow reads from it.
    song = clonedSong;
    _resetInstrumentCarry();

    // Build carry state by simulating rows before the start position.
    for (
      int slotIdx = 0;
      slotIdx < startSlot && slotIdx < clonedSong.patterns.length;
      slotIdx++
    ) {
      final pat = clonedSong.patterns[slotIdx];
      if (pat.isEmpty) break;
      for (int row = 0; row < pat.rowCount; row++) {
        _playheadArrangementSlot = slotIdx;
        playheadRow = row;
        _triggerCurrentRow();
      }
    }
    if (startSlot < clonedSong.patterns.length) {
      final pat = clonedSong.patterns[startSlot];
      final safeStart = startRow.clamp(0, pat.rowCount - 1);
      for (int row = 0; row < safeStart; row++) {
        _playheadArrangementSlot = startSlot;
        playheadRow = row;
        _triggerCurrentRow();
      }
    }

    // Enqueue rows from (startSlot, startRow) to end of song.
    for (
      int slotIdx = startSlot;
      slotIdx < clonedSong.patterns.length;
      slotIdx++
    ) {
      final pat = clonedSong.patterns[slotIdx];
      if (slotIdx > startSlot && pat.isEmpty) break; // stop marker
      final firstRow = (slotIdx == startSlot)
          ? startRow.clamp(0, pat.rowCount - 1)
          : 0;
      for (int row = firstRow; row < pat.rowCount; row++) {
        _playheadArrangementSlot = slotIdx;
        playheadRow = row;
        rowMap.add((arrangementSlot: slotIdx, rowWithinSlot: row));
        scheduledRows.add(_triggerCurrentRow());
      }
      if (slotIdx + 1 >= clonedSong.patterns.length ||
          clonedSong.patterns[slotIdx + 1].isEmpty) {
        break;
      }
    }

    // Restore state.
    song = originalSong;
    playheadRow = originalPlayheadRow;
    _playheadArrangementSlot = originalPlayheadSlot;
    _resetInstrumentCarry();

    // Upload to native.
    await AudioEngine.instance.clearQueuedPlaybackRows();
    await AudioEngine.instance.setQueuedPlaybackLooping(false);
    for (final row in scheduledRows) {
      await AudioEngine.instance.enqueuePlaybackRow(
        lineSamples: row.lineSamples,
        rowData: row.rowData,
        immediateKillMask: row.immediateKillMask,
        retrigData: row.retrigData,
        arpData: row.arpData,
        delayData: row.delayData,
        killData: row.killData,
        sliceCommandData: row.sliceCommandData,
        mixerCommandData: row.mixerCommandData,
        insertFxCommandData: row.insertFxCommandData,
        pitchRampData: row.pitchRampData,
      );
    }

    _songRowMap = rowMap;
    _songFlatRowIndex = 0;
  }

  void _startNativeSongPoller() {
    _playheadTimer?.cancel();
    _playheadTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      unawaited(_pollNativeSongPlayhead());
    });
  }

  Future<void> _pollNativeSongPlayhead() async {
    if (!isPlaying || !_playbackFollowsSong || _songPollInFlight) return;
    _songPollInFlight = true;
    try {
      final advanced = await AudioEngine.instance.consumePendingRowAdvances();
      if (!isPlaying || advanced <= 0) return;

      _songFlatRowIndex += advanced;

      // Song exhausted — stop playback.
      if (_songFlatRowIndex >= _songRowMap.length) {
        if (_loopPlaybackEnabled) {
          await _restartSongFromBeginningForLoop();
          return;
        }
        stop();
        return;
      }

      final prevSlot = _playheadArrangementSlot;
      final entry = _songRowMap[_songFlatRowIndex];
      _playheadArrangementSlot = entry.arrangementSlot;
      playheadRow = entry.rowWithinSlot;

      // Pattern boundary: check for a queued jump.
      final queued = _queuedArrangementSlot;
      if (queued != null && entry.arrangementSlot != prevSlot) {
        _queuedArrangementSlot = null;
        _syncCurrentPatternToSongPlayhead();
        await _rebuildNativeSongQueueFromSlot(queued);
        return; // _rebuildNativeSongQueueFromSlot calls notifyListeners
      }

      _syncCurrentPatternToSongPlayhead();
      notifyListeners();
    } finally {
      _songPollInFlight = false;
    }
  }

  /// Rebuilds the native song queue to jump to [targetSlot] at the next
  /// pattern boundary. Called from the poller at a boundary crossing.
  Future<void> _rebuildNativeSongQueueFromSlot(int targetSlot) async {
    if (!isPlaying || song.patterns.isEmpty) return;
    if (targetSlot < 0 || targetSlot >= song.patterns.length) {
      stop();
      return;
    }
    _playheadArrangementSlot = targetSlot;
    _syncCurrentPatternToSongPlayhead();
    await _loadNativeSongPlaybackQueue(startSlot: targetSlot, startRow: 0);
    if (!isPlaying) return;
    await AudioEngine.instance.start();
    notifyListeners();
  }

  void _restartPlayheadTimerIfNeeded() {
    if (!isPlaying) return;
    if (_playbackFollowsSong) {
      unawaited(
        _loadNativeSongPlaybackQueue(
          startSlot: _playheadArrangementSlot,
          startRow: playheadRow,
        ).then((_) {
          if (isPlaying) AudioEngine.instance.start();
        }),
      );
      return;
    }
    unawaited(
      _loadNativePatternPlaybackQueue(startRow: playheadRow).then((_) {
        if (isPlaying) {
          return AudioEngine.instance.start();
        }
      }),
    );
  }

  void _clampSelectionToPattern() {
    if (playheadRow >= rowCount) {
      playheadRow = rowCount - 1;
    }
    if (selectedCell != null && selectedCell!.row >= rowCount) {
      selectedCell = null;
    }
    // Clamp row range selection to pattern bounds
    if (_selectedRowStart != null && _selectedRowStart! >= rowCount) {
      _selectedRowStart = null;
    }
    if (_selectedRowEnd != null && _selectedRowEnd! >= rowCount) {
      _selectedRowEnd = null;
    }
    final boxSel = _boxSelection;
    if (boxSel != null) {
      final trackInvalid = boxSel.trackIndex >= currentPattern.tracks.length;
      final rowInvalid = boxSel.maxRow >= rowCount;
      if (trackInvalid || rowInvalid) {
        _boxSelection = null;
        _isBoxSelecting = false;
      }
    }
  }

  /// Reads the current row from all tracks in the playing pattern and builds
  /// the packed note/volume/pan/wave + synth params for the audio engine.
  _ScheduledPlaybackRow _triggerCurrentRow() {
    int ui99ToAudio255(int v) => ((v.clamp(0, 99) * 255) / 99).round();
    int pitchOnlyNoteCmd(int midi) => -1000 - midi.clamp(0, 127);
    int retrigVolumeForStep(int baseVolume, int mode, int step) {
      if (mode <= 0 || step <= 0) return baseVolume.clamp(0, 255);
      const downFactors = [1.0, 0.88, 0.72, 0.58, 0.42];
      const upFactors = [1.0, 1.08, 1.18, 1.32, 1.5];
      final clampedMode = mode.clamp(0, 9);
      final factor = clampedMode <= 4
          ? math.pow(downFactors[clampedMode], step).toDouble()
          : math.pow(upFactors[clampedMode - 5], step).toDouble();
      return (baseVolume * factor).round().clamp(0, 255);
    }

    final rng = math.Random();

    final PatternModel pattern;
    final int patternIdx;
    if (_playbackFollowsSong && song.patterns.isNotEmpty) {
      patternIdx = _playheadArrangementSlot.clamp(0, song.patterns.length - 1);
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
      _carryNoteByTrack = List<int?>.filled(pattern.tracks.length, null);
      _carryVolumeByTrack = List<int?>.filled(pattern.tracks.length, null);
      _carryVibSpeedByTrack = List<double?>.filled(pattern.tracks.length, null);
      _carryVibDepthByTrack = List<double?>.filled(pattern.tracks.length, null);
      _carryVolFxByTrack = List<int?>.filled(pattern.tracks.length, null);
      _carryPanFxByTrack = List<int?>.filled(pattern.tracks.length, null);
      _carryTreSpeedByTrack = List<double?>.filled(pattern.tracks.length, null);
      _carryTreDepthByTrack = List<double?>.filled(pattern.tracks.length, null);
      _carryTreModeByTrack = List<int?>.filled(pattern.tracks.length, null);
      _carryArpByTrack =
          List<({List<int> cycle, int notesPerLine, int phase})?>.filled(
            pattern.tracks.length,
            null,
          );
      _carrySlideByTrack =
          List<({int startNote, int endNote, int totalLines, int linesElapsed})?>.filled(
            pattern.tracks.length,
            null,
          );
      _carryInstrumentParamsByTrack = List<Map<int, int>>.generate(
        pattern.tracks.length,
        (_) => {},
      );
    }

    _rowSegments = [];
    // Pending DEL events: [sampleOffset, trackIdx, note, volume, ...]
    // queued natively for sample-accurate firing.
    final List<int> delayQueue = [];
    // Pending KIL events: [sampleOffset, trackIdx, ...]
    // queued natively for sample-accurate firing.
    final List<int> killQueue = [];
    // Pending SLC events: [slcPlayMode, trackIdx, startNormScaled, endNormScaled, ...]
    // queued natively for sample-accurate firing.
    final List<int> sliceCommandQueue = [];
    // Pending mixer FX events: [channel, controller, value, unused, ...]
    // channel: 0=master, 1-16=mixer channels
    // controller: 1-4 for implemented (pan/mute/solo/volume), 5-9 reserved
    // value: 0-99
    final List<int> mixerCommandQueue = [];
    // Pending own-channel insert FX events: [trackIdx, slotIdx, function, value, ...]
    final List<int> insertFxCommandQueue = [];
    // Pending RET events: flat list [sampleOffset, trackIdx, note, volume, ...]
    // passed directly to the C++ engine for sample-accurate firing.
    final List<int> retrigQueue = [];
    // Pending ARP events: flat list [sampleOffset, trackIdx, note, ...]
    // passed directly to the C++ engine as pitch-only updates.
    final List<int> arpQueue = [];
    // Pending SLU/SLD pitch ramp events: collected as (trackIdx, endNote, totalLines)
    // during the per-track loop, then converted to [trackIdx, note, durationSamples]
    // after lineSamples is known.
    final List<({int track, int note, int lines})> pendingPitchRamps = [];
    // Pending ARP events: trackIndex → (expanded cycle, notesPerLine, phase).
    final Map<int, ({List<int> cycle, int notesPerLine, int phase})>
    pendingArp = {};

    final rowData = <int>[];
    final immediateKillData = <int>[];
    final hasSolo = pattern.tracks.any((track) => track.mixerSolo);
    bool anyImmediateKill = false;
    for (int t = 0; t < pattern.tracks.length; t++) {
      final track = pattern.tracks[t];
      var currentSlot = _carryInstrumentByTrack[t];
      int noteCmd = -1;
      int volCmd = (_carryVolFxByTrack.length > t && _carryVolFxByTrack[t] != null)
          ? _carryVolFxByTrack[t]!
          : (track.mixerVolume.clamp(0.0, 1.0) * 255).round();
      int panCmd = (_carryPanFxByTrack.length > t && _carryPanFxByTrack[t] != null)
          ? _carryPanFxByTrack[t]!
          : (((track.mixerPan.clamp(-1.0, 1.0) + 1.0) / 2.0) * 255).round();
      int waveCmd = _waveCodeForInstrumentSlot(currentSlot);
      int instrumentTypeCmd = _instrumentTypeCodeForSlot(currentSlot);
      var synthParams = _synthParamsForInstrumentSlot(currentSlot);
      int delayPct = 0; // 0 = no delay, 1..99 = % into the line
      int killPct = -1; // -1 = no KIL, 0 = immediate, 1..99 = % into line
      bool immediateKill = false;
      int samplerSlice = 0;
      bool samplerSliceActive = false;
      bool samplerPlayThrough = false;
      int slcPlayMode = 0; // SLC: 0 = play slice only, 1 = play through
      int slcSliceNum = 0; // SLC: 1-9 = which slice, 0 = no SLC
      int?
      ranChancePct; // RAN: if set, % chance to override slice with random active slice
      bool samplerReverse = false; // REV: play sample/slice backward
      double? vibSpeedNorm = _carryVibSpeedByTrack.length > t
          ? _carryVibSpeedByTrack[t]
          : null;
      double? vibDepthNorm = _carryVibDepthByTrack.length > t
          ? _carryVibDepthByTrack[t]
          : null;
      double? treSpeedNorm =
          _carryTreSpeedByTrack.length > t ? _carryTreSpeedByTrack[t] : null;
      double? treDepthNorm =
          _carryTreDepthByTrack.length > t ? _carryTreDepthByTrack[t] : null;
      int? treMode =
          _carryTreModeByTrack.length > t ? _carryTreModeByTrack[t] : null;
      int retrigVolumeMode = 0;
      int retrigNotesPerLine = 0;
      int arpInterval1 = -1;
      int arpInterval2 = -1;
      int arcOctaveLayers = 0;
      int arcNotesPerLine = 0;
      int? chancePct;
      // SLU/SLD: set when slide FX is found on a note row this tick.
      ({int endNote, int totalLines})? pendingSlide;

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

        if (noteCmd == -2) {
          // Note-off clears per-note FX carries for this track.
          _carryVibSpeedByTrack[t] = null;
          _carryVibDepthByTrack[t] = null;
          _carryVolFxByTrack[t] = null;
          _carryPanFxByTrack[t] = null;
          _carryTreSpeedByTrack[t] = null;
          _carryTreDepthByTrack[t] = null;
          _carryTreModeByTrack[t] = null;
        }

        // Proxy note shorthand for samplers: C-0..G#0 trigger slices 1..9.
        // The first 9 notes of octave 0 map to SLC 01..09 at C4 pitch.
        //   C-0=slice1, C#0=slice2, D-0=slice3, D#0=slice4, E-0=slice5,
        //   F-0=slice6, F#0=slice7, G-0=slice8, G#0=slice9.
        // Use C-4 (or any note above A#0) for normal full-sample playback.
        // An explicit SLC FX command in the same cell will override this.
        if (noteCmd > 0 &&
            instruments[currentSlot].type == InstrumentType.sampler) {
          // MIDI 12 = C-0, MIDI 20 = G#0 (first 9 chromatic notes of octave 0).
          if (noteCmd >= 12 && noteCmd <= 20) {
            slcSliceNum = noteCmd - 11; // C-0→1, C#0→2, … G#0→9
            slcPlayMode = 0; // slice-only
            noteCmd = 60; // redirect pitch to C-4 (normal speed)
          }
        }

        if (cell.volume != null) {
          volCmd = ui99ToAudio255(cell.volume!);
          _carryVolumeByTrack[t] = volCmd;
        }

        for (final fx in cell.fxSlots) {
          if (fx.command == kFxPAN && fx.value != null) {
            panCmd = ui99ToAudio255(fx.value!.clamp(0, 99));
            _carryPanFxByTrack[t] = panCmd;
          }
          if (fx.command == kFxDEL && fx.value != null) {
            delayPct = fx.value!.clamp(0, 99);
          }
          if (fx.command == kFxKIL) {
            killPct = (fx.value ?? 0).clamp(0, 99);
          }
          if (fx.command == kFxSLC && fx.value != null) {
            // SLC XY: X = play mode (0=slice, 1=through), Y = slice number (1-9)
            final xy = fx.value!.clamp(0, 99);
            slcPlayMode = xy ~/ 10; // tens digit
            slcSliceNum = xy % 10; // ones digit, 1-9 (0 = no slice)
          }
          if (fx.command == kFxCHA && fx.value != null) {
            chancePct = fx.value!.clamp(0, 99);
          }
          if (fx.command == kFxRAN && fx.value != null) {
            ranChancePct = fx.value!.clamp(0, 99);
          }
          if (fx.command == kFxREV) {
            samplerReverse = true;
          }
          if (fx.command == kFxVOL && fx.value != null) {
            volCmd = ui99ToAudio255(fx.value!.clamp(0, 99));
            _carryVolFxByTrack[t] = volCmd;
          }
          if (fx.command == kFxVIB && fx.value != null) {
            // XY: X = speed (tens digit, 0-9), Y = depth (ones digit, 0-9).
            final xy = fx.value!.clamp(0, 99);
            final x = xy ~/ 10; // speed digit
            final y = xy % 10; // depth digit
            vibSpeedNorm = x / 9.0;
            vibDepthNorm = y / 9.0;
            // Carry VIB so it persists on subsequent hold rows.
            _carryVibSpeedByTrack[t] = vibSpeedNorm;
            _carryVibDepthByTrack[t] = vibDepthNorm;
          }
          if ((fx.command == kFxTRE || fx.command == kFxGAT) &&
              fx.value != null) {
            // XY: X = speed (tens digit, 0-9), Y = depth (ones digit, 0-9).
            final xy = fx.value!.clamp(0, 99);
            final x = xy ~/ 10; // speed digit
            final y = xy % 10; // depth digit
            treSpeedNorm = x / 9.0;
            treDepthNorm = y / 9.0;
            treMode = fx.command == kFxTRE ? 1 : 2; // 1=sine, 2=square
            // Carry TRE/GAT so it persists on subsequent hold rows.
            _carryTreSpeedByTrack[t] = treSpeedNorm;
            _carryTreDepthByTrack[t] = treDepthNorm;
            _carryTreModeByTrack[t] = treMode;
          }
          if (fx.command == kFxRET) {
            final value = (fx.value ?? 0).clamp(0, 99);
            retrigVolumeMode = (value ~/ 10).clamp(0, 9);
            retrigNotesPerLine = (value % 10).clamp(0, 9);
          }
          if (fx.command == kFxARP && fx.value != null && fx.value! > 0) {
            // Digits are chromatic semitones: 0=unison, 1=m2, 2=M2, 3=m3,
            // 4=M3, 5=P4, 6=tritone, 7=P5, 8=m6, 9=M6.
            arpInterval1 = (fx.value! ~/ 10).clamp(0, 9);
            arpInterval2 = (fx.value! % 10).clamp(0, 9);
          }
          if (fx.command == kFxARC && fx.value != null) {
            arcOctaveLayers = (fx.value! ~/ 10).clamp(0, 9);
            arcNotesPerLine = (fx.value! % 10).clamp(0, 9);
          }
          // SLU/SLD XY: X (tens) = lines to slide over, Y (ones) = semitones.
          // Works on note rows and on hold rows that have an active carry note.
          if ((fx.command == kFxSLU || fx.command == kFxSLD) &&
              fx.value != null) {
            final slideBase = noteCmd >= 0
                ? noteCmd
                : (_carryNoteByTrack.length > t ? _carryNoteByTrack[t] : null);
            if (slideBase != null) {
              final xy = fx.value!.clamp(1, 99);
              final lines = (xy ~/ 10).clamp(1, 9);
              final semitones = xy % 10;
              if (semitones > 0) {
                final dir = fx.command == kFxSLU ? 1 : -1;
                pendingSlide = (
                  endNote: (slideBase + dir * semitones).clamp(0, 127),
                  totalLines: lines,
                );
              }
            }
          }
          if (fx.command != null &&
              fx.command! >= kFxSL0 &&
              fx.command! <= kFxSL9) {
            samplerSliceActive = true;
            samplerSlice = fx.command! - kFxSL0;
            samplerPlayThrough =
                (fx.value ?? 0) == 0; // 00=play through, 01=stop at next slice
          }
          // Mixer FX commands. UI state remains the snapshot source of truth.
          final isMixerCommand = _isMixerFxCommand(fx.command);
          if (isMixerCommand) {
            final cmd = fx.command!;
            final value = (fx.value ?? 0).clamp(0, 99);

            if (cmd == 194) {
              // M00: reset full mixer to current UI snapshot.
              _appendFullMixerSnapshot(mixerCommandQueue, pattern);
            } else if (cmd == 32) {
              // M01: master mute
              mixerCommandQueue.addAll([0, 1, value, 0]);
            } else if (cmd == 33) {
              // M02: master volume
              mixerCommandQueue.addAll([0, 2, value, 0]);
            } else if (cmd >= 34) {
              // Channels 1-16: each occupies 10 indices.
              final offset = cmd - 34;
              final channel = (offset ~/ 10) + 1;
              final slot = offset % 10;
              final trackIdx = channel - 1;

              // Slot 9 is treated as Mx0: reset this channel to snapshot.
              if (slot == 9) {
                _appendTrackMixerSnapshot(mixerCommandQueue, pattern, trackIdx);
              } else if (slot <= 3) {
                // Slot 0-3: controller 1-4 (pan, mute, solo, volume)
                final controller = slot + 1;
                mixerCommandQueue.addAll([channel, controller, value, 0]);
              }
            }
          }
          if (isInsertFxCommand(fx.command) && !isMixerCommand) {
            final cmd = fx.command!;
            final value = (fx.value ?? 0).clamp(0, 99);
            final fn = fxInsertFunctionFromCommand(cmd);
            final slotIdx = fxInsertSlotFromCommand(cmd) - 1;
            insertFxCommandQueue.addAll([t, slotIdx, fn, value]);
          }
          // Pxx: instrument parameter automation.
          if (isPParamCommand(fx.command)) {
            final idx = pParamIndex(fx.command!);
            while (_carryInstrumentParamsByTrack.length <= t) {
              _carryInstrumentParamsByTrack.add({});
            }
            if (idx == 0) {
              // P00: reset — clear all overrides for this track.
              _carryInstrumentParamsByTrack[t].clear();
            } else if (fx.value != null) {
              final val = fx.value!.clamp(0, 99);
              _carryInstrumentParamsByTrack[t][idx] = val;
            }
          }
        }

        // RAN: probabilistic random active slice override (sampler only).
        // Applied after SL so RAN can override an explicit slice selection.
        if (ranChancePct != null && ranChancePct > 0 && noteCmd >= 0) {
          final instr = instruments[currentSlot];
          if (instr.type == InstrumentType.sampler) {
            final sp = instr.sampler;
            final activeSlices = <int>[];
            for (int s = 1; s <= SamplerParams.sliceCount; s++) {
              if (sp.sliceStartValue(s) > 0) activeSlices.add(s);
            }
            if (activeSlices.isNotEmpty && rng.nextInt(100) < ranChancePct) {
              samplerSlice = activeSlices[rng.nextInt(activeSlices.length)];
            }
          }
        }

        synthParams = _synthParamsForInstrumentSlot(
          currentSlot,
          samplerSlice: samplerSlice,
          samplerSliceActive: samplerSliceActive,
          samplerPlayThrough: samplerPlayThrough,
          samplerReverse: samplerReverse,
          vibSpeedNorm: vibSpeedNorm,
          vibDepthNorm: vibDepthNorm,
          treSpeedNorm: treSpeedNorm,
          treDepthNorm: treDepthNorm,
          treMode: treMode,
        );

        if (killPct == 0) immediateKill = true;
      }

      // Pxx carry: patch synthParams (and waveCmd) with any active overrides.
      waveCmd = _applyInstrumentParamCarry(
        t,
        currentSlot,
        synthParams,
        waveCmd,
      );

      final isMixerMuted = _isTrackMutedByMixer(
        pattern,
        t,
        hasSoloOverride: hasSolo,
      );
      if (isMixerMuted) {
        // Mute/solo should immediately silence ongoing voices and prevent
        // new triggers for this track until it is active again.
        noteCmd = -1;
        delayPct = 0;
        immediateKill = true;
      }

      // CHA: 00..99 chance that a note-on this row will play.
      // If chance fails, treat as hold (no new note trigger).
      if (!isMixerMuted && noteCmd >= 0 && chancePct != null) {
        final pct = chancePct.clamp(0, 99);
        if (rng.nextInt(100) >= pct) {
          noteCmd = -1;
          delayPct = 0;
        }
      }

      if (noteCmd >= 0) {
        _carryNoteByTrack[t] = noteCmd;
        _carryVolumeByTrack[t] = volCmd;
      } else if (noteCmd == -2) {
        _carryNoteByTrack[t] = null;
        _carryVolumeByTrack[t] = null;
      }

      final retBaseNote = _carryNoteByTrack[t];
      final retBaseVolume = _carryVolumeByTrack[t] ?? volCmd;
      if (retrigNotesPerLine > 0 &&
          noteCmd == -1 &&
          retBaseNote != null &&
          !isMixerMuted) {
        // RET on held rows retriggers the last carried note.
        noteCmd = retBaseNote;
        volCmd = retBaseVolume;
      }

      // SLU/SLD slide carry: start on note/hold rows, advance pitch on hold rows.
      if (pendingSlide != null) {
        // Note or hold row with slide FX: (re)start the slide carry.
        final startNote = noteCmd >= 0
            ? noteCmd
            : (_carryNoteByTrack.length > t
                ? (_carryNoteByTrack[t] ?? pendingSlide.endNote)
                : pendingSlide.endNote);
        if (t < _carrySlideByTrack.length) {
          _carrySlideByTrack[t] = (
            startNote: startNote,
            endNote: pendingSlide.endNote,
            totalLines: pendingSlide.totalLines,
            linesElapsed: 0,
          );
        }
      } else if (noteCmd == -2 || noteCmd >= 0) {
        // Note-off or new note without slide: cancel any active slide.
        if (t < _carrySlideByTrack.length) _carrySlideByTrack[t] = null;
      } else if (noteCmd == -1 &&
          t < _carrySlideByTrack.length &&
          _carrySlideByTrack[t] != null &&
          !isMixerMuted) {
        // Hold row with active slide.
        final slide = _carrySlideByTrack[t]!;
        final nextElapsed = slide.linesElapsed + 1;
        if (slide.linesElapsed == 0) {
          // First hold row: queue a linear pitch ramp spanning the full slide
          // duration. lineSamples is computed after the per-track loop, so we
          // collect (trackIdx, endNote, totalLines) and finalize below.
          pendingPitchRamps.add((
            track: t,
            note: slide.endNote,
            lines: slide.totalLines,
          ));
        }
        // noteCmd stays -1 (hold); the C++ ramp drives pitch continuously.
        _carrySlideByTrack[t] = nextElapsed >= slide.totalLines
            ? null
            : (
                startNote: slide.startNote,
                endNote: slide.endNote,
                totalLines: slide.totalLines,
                linesElapsed: nextElapsed,
              );
      }

      // ARP carry: resolve noteCmd before building the segment/rowData.
      // Mid-note ARP: ARP FX on a hold row can start arpeggiation on the
      // currently sustaining note (using the carry note as the base pitch).
      final midNoteArp = arpInterval1 >= 0 &&
          noteCmd == -1 &&
          _carryNoteByTrack.length > t &&
          _carryNoteByTrack[t] != null &&
          !isMixerMuted;
      if (arpInterval1 >= 0 && (noteCmd >= 0 || midNoteArp)) {
        // New note or mid-note hold row with ARP: (re)start the carry.
        final baseNote = noteCmd >= 0 ? noteCmd : _carryNoteByTrack[t]!;
        final layers = arcOctaveLayers > 0 ? arcOctaveLayers : 1;
        final cycle = <int>[];
        for (int oct = 0; oct < layers; oct++) {
          final offset = 12 * oct;
          cycle.add((baseNote + offset).clamp(0, 127));
          cycle.add((baseNote + arpInterval1 + offset).clamp(0, 127));
          cycle.add((baseNote + arpInterval2 + offset).clamp(0, 127));
        }
        final notesPerLine = arcNotesPerLine > 0
            ? arcNotesPerLine
            : cycle.length;
        _carryArpByTrack[t] = (
          cycle: List<int>.unmodifiable(cycle),
          notesPerLine: notesPerLine,
          phase: 0,
        );
        pendingArp[t] = _carryArpByTrack[t]!;
        if (midNoteArp) {
          // Fire the first ARP pitch immediately as a pitch-only update.
          noteCmd = pitchOnlyNoteCmd(cycle[0]);
        }
      } else if (noteCmd == -2 || noteCmd >= 0) {
        // Note-off or new note without ARP: clear carry.
        _carryArpByTrack[t] = null;
      } else if (noteCmd == -1 &&
          _carryArpByTrack[t] != null &&
          !isMixerMuted) {
        // Held empty line with active carry: continue the ARP phase instead of
        // restarting from the first note.
        final carry = _carryArpByTrack[t]!;
        noteCmd = pitchOnlyNoteCmd(
          carry.cycle[carry.phase % carry.cycle.length],
        );
        pendingArp[t] = carry;
      }

      // Build the per-track segment (with real noteCmd) for DEL replay.
      final segment = [
        noteCmd,
        volCmd,
        panCmd,
        waveCmd,
        instrumentTypeCmd,
        ...synthParams,
      ];
      _rowSegments.add(segment);

      // DEL: if delay > 0 and there's a real note, hold now and fire later.
      // C++ will convert percentage to sample offset at queue time.
      final int sentNote;
      if (delayPct > 0 && noteCmd >= 0) {
        sentNote = -1; // hold at row trigger, fire later via queueDelays
      } else {
        sentNote = noteCmd;
      }

      // KIL: any positive % schedules a per-track note-off mid-line.
      // C++ will convert percentage to sample offset at queue time.
      if (killPct > 0) {
        killQueue.addAll([killPct, t]);
      }

      // SLC: queue slice command if valid slice is specified.
      if (slcSliceNum > 0 && slcSliceNum <= 9) {
        final instr = instruments[currentSlot];
        if (instr.type == InstrumentType.sampler) {
          final sp = instr.sampler;
          final startNorm = sp.sliceStartNorm(slcSliceNum) ?? 0.0;
          final endNorm = sp.sliceEndNorm(
            slcSliceNum,
            playThrough: slcPlayMode == 1,
          );
          // Scale normalized values to integers (0-10000 range for 0.0-1.0).
          final startScaled = (startNorm * 10000).round().clamp(0, 10000);
          final endScaled = (endNorm * 10000).round().clamp(0, 10000);
          sliceCommandQueue.addAll([slcPlayMode, t, startScaled, endScaled]);
        }
      }

      // RET: value N means N evenly spaced note-ons per line.
      final retrigBaseNote = noteCmd >= 0 ? noteCmd : retBaseNote;
      final retrigBaseVolume = noteCmd >= 0 ? volCmd : retBaseVolume;
      if (retrigNotesPerLine > 1 && retrigBaseNote != null && !isMixerMuted) {
        for (int step = 1; step < retrigNotesPerLine; step++) {
          // Send [stepNum, totalSteps, trackIdx, note, volume] — C++ calculates
          // the sample offset using mLineSamplesPerRow for sample-rate accuracy.
          retrigQueue.addAll([
            step,
            retrigNotesPerLine,
            t,
            retrigBaseNote,
            retrigVolumeForStep(retrigBaseVolume, retrigVolumeMode, step),
          ]);
        }
      }

      // Apply master mute / master volume multiplier.
      int finalNote = sentNote;
      int finalVol = volCmd;
      if (song.masterMute) {
        finalNote = -1;
      } else if (volCmd > 0) {
        finalVol = (volCmd * song.masterVolume).round().clamp(0, 255);
      }

      // Queue delayed note if applicable. C++ will convert delayPct to sample offset.
      if (delayPct > 0 && noteCmd >= 0 && !song.masterMute) {
        delayQueue.addAll([delayPct, t, noteCmd, finalVol]);
      }

      rowData.add(finalNote);
      rowData.add(finalVol);
      rowData.add(panCmd);
      rowData.add(waveCmd);
      rowData.add(instrumentTypeCmd);
      rowData.addAll(synthParams);

      immediateKillData.add(immediateKill ? 1 : 0);
      if (immediateKill) anyImmediateKill = true;
    }

    // Calculate line duration in samples for DEL/KIL timing.
    // 48000 Hz matches the Oboe stream sample rate.
    const int kSampleRate = 48000;
    final int lineSamples =
        (_lineDurationForPatternRow(pattern, playheadRow).inMicroseconds *
            kSampleRate) ~/
        1000000;

    if (pendingArp.isNotEmpty) {
      pendingArp.forEach((trackIdx, cfg) {
        for (int step = 1; step < cfg.notesPerLine; step++) {
          final int midi = cfg.cycle[(cfg.phase + step) % cfg.cycle.length];
          arpQueue.addAll([step, cfg.notesPerLine, trackIdx, midi]);
        }
        final carry = _carryArpByTrack[trackIdx];
        if (carry != null) {
          _carryArpByTrack[trackIdx] = (
            cycle: carry.cycle,
            notesPerLine: carry.notesPerLine,
            phase: (carry.phase + carry.notesPerLine) % carry.cycle.length,
          );
        }
      });
    }

    // Convert pending pitch ramps to [trackIdx, targetMidiNote, durationSamples] triples
    // now that lineSamples is known.
    final List<int> pitchRampQueue = [];
    for (final r in pendingPitchRamps) {
      pitchRampQueue.addAll([r.track, r.note, r.lines * lineSamples]);
    }

    final scheduled = _ScheduledPlaybackRow(
      rowData: List<int>.unmodifiable(rowData),
      immediateKillMask: anyImmediateKill
          ? List<int>.unmodifiable(immediateKillData)
          : const <int>[],
      retrigData: List<int>.unmodifiable(retrigQueue),
      arpData: List<int>.unmodifiable(arpQueue),
      delayData: List<int>.unmodifiable(delayQueue),
      killData: List<int>.unmodifiable(killQueue),
      sliceCommandData: List<int>.unmodifiable(sliceCommandQueue),
      mixerCommandData: List<int>.unmodifiable(mixerCommandQueue),
      insertFxCommandData: List<int>.unmodifiable(insertFxCommandQueue),
      pitchRampData: List<int>.unmodifiable(pitchRampQueue),
      lineSamples: lineSamples,
    );

    return scheduled;
  }

  void _syncCurrentPatternToSongPlayhead() {
    if (song.patterns.isEmpty) return;
    _currentPatternIndex = _playheadArrangementSlot.clamp(
      0,
      song.patterns.length - 1,
    );
    _clampSelectionToPattern();
  }

  // ── Sampler library ───────────────────────────────────────────────────────

  static const _kSamplerExts = <String>{
    '.wav',
    '.aif',
    '.aiff',
    '.flac',
    '.ogg',
    '.mp3',
    '.m4a',
    '.aac',
  };

  Future<Directory> samplerLibraryDir() async {
    final base =
        await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/samples');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Future<String> samplerLibraryPath() async => (await samplerLibraryDir()).path;

  Future<List<String>> listSamplerLibrarySamples() async {
    try {
      final d = await samplerLibraryDir();
      final names =
          d
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
      // Ensure the instrument type is set to sampler when a sample is loaded.
      currentInstrument.type = InstrumentType.sampler;
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// Bake (or un-bake) time-stretching for the current instrument's sampler slot.
  ///
  /// Called whenever the user changes stretchEnabled, stretchBeats, or
  /// stretchPreservePitch in the sampler UI. The current project BPM is
  /// snapshotted at bake time — BPM changes later have no effect unless the
  /// user manually re-bakes.
  Future<void> applyStretch() async {
    final sp = currentInstrument.sampler;
    if (sp.samplePath == null) return;
    await AudioEngine.instance.updateStretch(
      slot: currentInstrumentIndex,
      enabled: sp.stretchEnabled,
      beats: sp.stretchBeats,
      bpm: bpm,
      preservePitch: sp.stretchPreservePitch,
    );
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
      (currentInstrumentIndex + 1) % instruments.length,
    );
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
        audioFormat = readLe16(body + 0);
        channels = readLe16(body + 2);
        sampleRate = readLe32(body + 4);
        bitsPerSample = readLe16(body + 14);
      } else if (matchAscii(pos, 'data')) {
        dataOffset = body;
        dataSize = chunkSize;
      }
      pos = body + chunkSize + (chunkSize.isOdd ? 1 : 0);
    }
    if (dataOffset < 0 ||
        channels <= 0 ||
        bitsPerSample <= 0 ||
        !(audioFormat == 1 || audioFormat == 3)) {
      return 'Unsupported WAV format';
    }

    final bytesPerSample = bitsPerSample ~/ 8;
    final frameSize = bytesPerSample * channels;
    final totalFrames = dataSize ~/ frameSize;
    if (totalFrames <= 0) return 'Empty audio data';

    // Compute frame range from start/end normalised values
    final startFrame = (src.start.clamp(0.0, 1.0) * (totalFrames - 1))
        .round()
        .clamp(0, totalFrames - 1);
    final endFrame = (src.end.clamp(0.0, 1.0) * totalFrames).round().clamp(
      startFrame + 1,
      totalFrames,
    );
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
      for (int i = 0; i < 4; i++) {
        wavOut.setUint8(off + i, s.codeUnitAt(i));
      }
    }

    writeFourCC(0, 'RIFF');
    wavOut.setUint32(4, 36 + dataBytes, Endian.little);
    writeFourCC(8, 'WAVE');
    writeFourCC(12, 'fmt ');
    wavOut.setUint32(16, 16, Endian.little); // chunk size
    wavOut.setUint16(20, 1, Endian.little); // PCM
    wavOut.setUint16(22, 1, Endian.little); // mono
    wavOut.setUint32(24, outSampleRate, Endian.little);
    wavOut.setUint32(28, outSampleRate * 2, Endian.little); // byte rate
    wavOut.setUint16(32, 2, Endian.little); // block align
    wavOut.setUint16(34, 16, Endian.little); // bits per sample
    writeFourCC(36, 'data');
    wavOut.setUint32(40, dataBytes, Endian.little);
    for (int f = 0; f < chopFrames; f++) {
      wavOut.setInt16(44 + f * 2, outSamples[f], Endian.little);
    }

    // Build output filename: "<srcname>_chop_N.wav"
    final srcName =
        (src.sampleName ?? srcPath.split(Platform.pathSeparator).last);
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
      ..samplePath = outPath
      ..sampleName = outName
      ..pitch = src.pitch
      ..volume = src.volume
      ..loopMode = src.loopMode
      ..start = 0.0
      ..end = 1.0
      ..attack = src.attack
      ..release = src.release;

    // Load into the engine slot
    await AudioEngine.instance.setSamplerSample(nextEmpty, outPath);

    // Navigate to the new slot
    selectInstrument(nextEmpty);
    _notifyListenersSafe();
    return null;
  }

  /// Chops every active slice (SL1–SL9, i.e. sliceStarts[i] > 0) into its
  /// own new WAV file and places each in the next empty instrument slot.
  /// Returns null on success, or an error string on failure.
  Future<String?> chopAllSlicesToNewSlots() async {
    final src = currentInstrument.sampler;
    final srcPath = src.samplePath;
    if (srcPath == null || srcPath.isEmpty) return 'No sample loaded';

    // Collect active slice numbers (1-indexed) in position order.
    final activeSlices = <int>[];
    for (int i = 0; i < SamplerParams.sliceCount; i++) {
      if (src.sliceStarts[i] > 0) activeSlices.add(i + 1);
    }
    if (activeSlices.isEmpty) return 'No slices set (all SL1–SL9 values are 0)';

    final freeCount = instruments
        .where((ins) => ins.type == InstrumentType.empty)
        .length;
    if (freeCount < activeSlices.length) {
      return 'Not enough empty slots (need ${activeSlices.length}, have $freeCount)';
    }

    // Read source WAV once.
    final srcFile = File(srcPath);
    if (!srcFile.existsSync()) return 'Source file not found';
    final bytes = await srcFile.readAsBytes();
    if (bytes.length < 44) return 'Invalid WAV file';

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
        audioFormat = readLe16(body + 0);
        channels = readLe16(body + 2);
        sampleRate = readLe32(body + 4);
        bitsPerSample = readLe16(body + 14);
      } else if (matchAscii(pos, 'data')) {
        dataOffset = body;
        dataSize = chunkSize;
      }
      pos = body + chunkSize + (chunkSize.isOdd ? 1 : 0);
    }
    if (dataOffset < 0 ||
        channels <= 0 ||
        bitsPerSample <= 0 ||
        !(audioFormat == 1 || audioFormat == 3)) {
      return 'Unsupported WAV format';
    }

    final bytesPerSample = bitsPerSample ~/ 8;
    final frameSize = bytesPerSample * channels;
    final totalFrames = dataSize ~/ frameSize;
    if (totalFrames <= 0) return 'Empty audio data';

    final srcName =
        src.sampleName ?? srcPath.split(Platform.pathSeparator).last;
    final dot = srcName.lastIndexOf('.');
    final base = dot > 0 ? srcName.substring(0, dot) : srcName;
    final lib = await _songSamplesDir();

    int lastCreatedSlot = -1;
    int searchFrom = (currentInstrumentIndex + 1) % instruments.length;

    for (final sliceNum in activeSlices) {
      final startNorm = src.sliceStarts[sliceNum - 1] / 999.0;
      final endNorm = src.sliceEndNorm(sliceNum);

      final startFrame = (startNorm * (totalFrames - 1)).round().clamp(
        0,
        totalFrames - 1,
      );
      final endFrame = (endNorm * totalFrames).round().clamp(
        startFrame + 1,
        totalFrames,
      );
      final chopFrames = endFrame - startFrame;
      if (chopFrames <= 0) continue;

      // Decode region → mono float → 16-bit PCM.
      final outSamples = List<int>.filled(chopFrames, 0);
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
            int raw =
                bytes[off] | (bytes[off + 1] << 8) | (bytes[off + 2] << 16);
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

      // Build output WAV (mono 16-bit PCM).
      final dataBytes = chopFrames * 2;
      final wavOut = ByteData(44 + dataBytes);
      void writeFourCC(int off, String s) {
        for (int i = 0; i < 4; i++) {
          wavOut.setUint8(off + i, s.codeUnitAt(i));
        }
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
      for (int f = 0; f < chopFrames; f++) {
        wavOut.setInt16(44 + f * 2, outSamples[f], Endian.little);
      }

      // Unique filename: <base>_sl<N>.wav
      String outName = '${base}_sl$sliceNum.wav';
      int suffix = 1;
      while (File('${lib.path}/$outName').existsSync()) {
        outName = '${base}_sl${sliceNum}_$suffix.wav';
        suffix++;
      }
      final outPath = '${lib.path}/$outName';
      await File(
        outPath,
      ).writeAsBytes(wavOut.buffer.asUint8List(), flush: true);

      // Find next empty slot (with wrap-around).
      int nextEmpty = instruments.indexWhere(
        (ins) => ins.type == InstrumentType.empty,
        searchFrom,
      );
      if (nextEmpty < 0 && searchFrom > 0) {
        nextEmpty = instruments.indexWhere(
          (ins) => ins.type == InstrumentType.empty,
        );
      }
      if (nextEmpty < 0) break; // pre-check should have caught this

      final destIns = instruments[nextEmpty];
      destIns.type = InstrumentType.sampler;
      destIns.sampler
        ..samplePath = outPath
        ..sampleName = outName
        ..pitch = src.pitch
        ..volume = src.volume
        ..loopMode = SamplerLoopMode.off
        ..start = 0.0
        ..end = 1.0
        ..attack = src.attack
        ..release = src.release;

      await AudioEngine.instance.setSamplerSample(nextEmpty, outPath);
      lastCreatedSlot = nextEmpty;
      searchFrom = (nextEmpty + 1) % instruments.length;
    }

    if (lastCreatedSlot >= 0) selectInstrument(lastCreatedSlot);
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
        audioFormat = readLe16(body + 0);
        channels = readLe16(body + 2);
        sampleRate = readLe32(body + 4);
        bitsPerSample = readLe16(body + 14);
      } else if (matchAscii(pos, 'data')) {
        dataOffset = body;
        dataSize = chunkSize;
      }
      pos = body + chunkSize + (chunkSize.isOdd ? 1 : 0);
    }
    if (dataOffset < 0 ||
        channels <= 0 ||
        bitsPerSample <= 0 ||
        !(audioFormat == 1 || audioFormat == 3)) {
      return 'Unsupported WAV format';
    }

    final bytesPerSample = bitsPerSample ~/ 8;
    final frameSize = bytesPerSample * channels;
    final totalFrames = dataSize ~/ frameSize;
    if (totalFrames <= 0) return 'Empty audio data';

    // Compute frame range from start/end normalised values
    final startFrame = (src.start.clamp(0.0, 1.0) * (totalFrames - 1))
        .round()
        .clamp(0, totalFrames - 1);
    final endFrame = (src.end.clamp(0.0, 1.0) * totalFrames).round().clamp(
      startFrame + 1,
      totalFrames,
    );
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
      for (int i = 0; i < 4; i++) {
        wavOut.setUint8(off + i, s.codeUnitAt(i));
      }
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
    final srcName =
        (src.sampleName ?? srcPath.split(Platform.pathSeparator).last);
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

    await AudioEngine.instance.setSamplerSample(
      currentInstrumentIndex,
      outPath,
    );

    // If stretch is enabled, re-bake it against the newly cropped originalMono.
    if (src.stretchEnabled) await applyStretch();

    _notifyListenersSafe();
    return null;
  }

  Future<String?> startPreviewCurrentSampler() async {
    return previewCurrentSamplerRegion();
  }

  Future<String?> previewCurrentSamplerRegion({
    double? startNorm,
    double? endNorm,
  }) async {
    try {
      if (isPlaying) {
        return 'Stop playback before sampler preview';
      }

      final slot = currentInstrumentIndex.clamp(0, instruments.length - 1);
      final ins = instruments[slot];
      if (ins.type != InstrumentType.sampler) {
        return 'Current instrument is not a sampler';
      }
      if (ins.sampler.samplePath == null || ins.sampler.samplePath!.isEmpty) {
        return 'No sample loaded';
      }

      if (_previewSamplerSlot >= 0) {
        await stopPreviewCurrentSampler();
      }

      final clampedStart = (startNorm ?? ins.sampler.start).clamp(0.0, 1.0);
      final clampedEnd = (endNorm ?? ins.sampler.end).clamp(
        (clampedStart + 0.001).clamp(0.0, 1.0),
        1.0,
      );

      final waveCmd = _waveCodeForInstrumentSlot(slot);
      final instrumentTypeCmd = _instrumentTypeCodeForSlot(slot);
      final synthParams = _synthParamsForInstrumentSlot(
        slot,
        samplerStartNorm: clampedStart,
        samplerEndNorm: clampedEnd,
      );

      final previewVoice = _previewVoiceIndexForInstrumentSlot(slot);
      if (_previewBypassVoice >= 0 && _previewBypassVoice != previewVoice) {
        await _setPreviewDryBypass(_previewBypassVoice, false);
      }
      final noteOn = _buildPreviewRowData(
        voiceIdx: previewVoice,
        note: 60,
        waveCmd: waveCmd,
        instrumentTypeCmd: instrumentTypeCmd,
        synthParams: synthParams,
      );

      await _primeAudioForPreview();
      await _setPreviewDryBypass(previewVoice, true);
      await AudioEngine.instance.setRowData(noteOn);
      _previewSamplerSlot = slot;
      _previewStartedAt = DateTime.now();
      _previewRegionStartNorm = clampedStart;
      _previewRegionEndNorm = clampedEnd;
      notifyListeners();
      await _schedulePreviewAutoStop(
        slot,
        ins,
        startNorm: clampedStart,
        endNorm: clampedEnd,
      );
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// Preview the note in the current track at [row] using the cell's instrument.
  /// No-op when the sequencer is playing (to avoid disrupting playback).
  Future<void> previewCellNoteOneShot(int row, {int durationMs = 280}) async {
    if (isPlaying) return;
    if (instruments.isEmpty) return;

    final track = currentTrack;
    if (row < 0 || row >= track.cells.length) return;

    final cell = track.cells[row];
    final note = cell.note;
    if (!note.isNote) return;

    final instNum =
        cell.instrument ?? _defaultInstrumentForRow(track, row);
    final slot = (instNum - 1).clamp(0, instruments.length - 1);

    final waveCmd = _waveCodeForInstrumentSlot(slot);
    final instrumentTypeCmd = _instrumentTypeCodeForSlot(slot);
    var synthParams = _synthParamsForInstrumentSlot(slot);
    final previewVoice = _previewVoiceIndexForInstrumentSlot(slot);

    // If this is a sampler and the note is in C-0..G#0, preview the
    // corresponding slice (1..9) instead of playing the full sample pitched.
    if (instruments[slot].type == InstrumentType.sampler &&
        note.isNote) {
      final midi = note.midiNote;
      if (midi >= 12 && midi <= 20) {
        final sliceNum = (midi - 11).clamp(1, 9);
        synthParams = _synthParamsForInstrumentSlot(
          slot,
          samplerSlice: sliceNum,
          samplerSliceActive: true,
          samplerPlayThrough: false,
        );
      }
    }

    if (_previewSamplerSlot >= 0) await stopPreviewCurrentSampler();
    if (_previewBypassVoice >= 0 && _previewBypassVoice != previewVoice) {
      await _setPreviewDryBypass(_previewBypassVoice, false);
    }

    int midiToSend = note.midiNote.clamp(0, 127);

    // If the sampler slice preview was selected (C-0..G#0), play at C-4
    // so the slice plays back at normal pitch.
    if (instruments[slot].type == InstrumentType.sampler && note.isNote) {
      final midi = note.midiNote;
      if (midi >= 12 && midi <= 20) midiToSend = 60;
    }

    final noteOff = _buildPreviewRowData(
      voiceIdx: previewVoice,
      note: -2,
      waveCmd: waveCmd,
      instrumentTypeCmd: instrumentTypeCmd,
      synthParams: synthParams,
    );
    final noteOn = _buildPreviewRowData(
      voiceIdx: previewVoice,
      note: midiToSend,
      waveCmd: waveCmd,
      instrumentTypeCmd: instrumentTypeCmd,
      synthParams: synthParams,
    );

    await _primeAudioForPreview();
    await _setPreviewDryBypass(previewVoice, true);
    await AudioEngine.instance.setRowData(noteOff);
    await AudioEngine.instance.setRowData(noteOn);

    _synthPreviewStopTimer?.cancel();
    final clampedDurationMs = durationMs.clamp(80, 4000);
    final startTime = DateTime.now();
    bool noteOffSent = false;
    _synthPreviewStopTimer = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) async {
        if (_disposed) return;
        final elapsed = DateTime.now().difference(startTime).inMilliseconds;
        if (!noteOffSent && elapsed >= clampedDurationMs) {
          noteOffSent = true;
          await AudioEngine.instance.setRowData(noteOff);
        }
        final stillPlaying =
            await AudioEngine.instance.isVoicePlaying(previewVoice);
        if (!stillPlaying && elapsed >= clampedDurationMs) {
          _synthPreviewStopTimer?.cancel();
          _synthPreviewStopTimer = null;
          if (_previewBypassVoice == previewVoice) {
            await _setPreviewDryBypass(previewVoice, false);
          }
        }
      },
    );
  }

  Future<String?> previewCurrentSynthOneShot({
    int midiNote = 60,
    int durationMs = 280,
  }) async {
    try {
      if (isPlaying) {
        return 'Stop playback before synth preview';
      }

      final slot = currentInstrumentIndex.clamp(0, instruments.length - 1);
      final ins = instruments[slot];
      if (ins.type != InstrumentType.simpleSynth) {
        return 'Current instrument is not a synth';
      }

      if (_previewSamplerSlot >= 0) {
        await stopPreviewCurrentSampler();
      }

      final waveCmd = _waveCodeForInstrumentSlot(slot);
      final instrumentTypeCmd = _instrumentTypeCodeForSlot(slot);
      final synthParams = _synthParamsForInstrumentSlot(slot);

      final previewVoice = _previewVoiceIndexForInstrumentSlot(slot);
      if (_previewBypassVoice >= 0 && _previewBypassVoice != previewVoice) {
        await _setPreviewDryBypass(_previewBypassVoice, false);
      }
      final noteOff = _buildPreviewRowData(
        voiceIdx: previewVoice,
        note: -2,
        waveCmd: waveCmd,
        instrumentTypeCmd: instrumentTypeCmd,
        synthParams: synthParams,
      );
      final noteOn = _buildPreviewRowData(
        voiceIdx: previewVoice,
        note: midiNote.clamp(0, 127),
        waveCmd: waveCmd,
        instrumentTypeCmd: instrumentTypeCmd,
        synthParams: synthParams,
      );

      await _primeAudioForPreview();
      await _setPreviewDryBypass(previewVoice, true);
      await AudioEngine.instance.setRowData(noteOff);
      await AudioEngine.instance.setRowData(noteOn);

      // Send note-off after hold duration, then poll until voice goes idle.
      _synthPreviewStopTimer?.cancel();
      final clampedDurationMs = durationMs.clamp(60, 4000);
      final startTime = DateTime.now();
      bool noteOffSent = false;
      _synthPreviewStopTimer = Timer.periodic(
        const Duration(milliseconds: 50),
        (_) async {
          if (_disposed) return;
          final elapsed = DateTime.now().difference(startTime).inMilliseconds;
          if (!noteOffSent && elapsed >= clampedDurationMs) {
            noteOffSent = true;
            await AudioEngine.instance.setRowData(noteOff);
          }
          if (noteOffSent) {
            final isStillPlaying = await AudioEngine.instance.isVoicePlaying(
              previewVoice,
            );
            if (!isStillPlaying) {
              _synthPreviewStopTimer?.cancel();
              _synthPreviewStopTimer = null;
              await _setPreviewDryBypass(previewVoice, false);
            }
          }
        },
      );

      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> previewCurrentKarplusOneShot({
    int midiNote = 60,
    int durationMs = 420,
  }) async {
    try {
      if (isPlaying) {
        return 'Stop playback before Karplus preview';
      }

      final slot = currentInstrumentIndex.clamp(0, instruments.length - 1);
      final ins = instruments[slot];
      if (ins.type != InstrumentType.karplusStrong) {
        return 'Current instrument is not Karplus';
      }

      if (_previewSamplerSlot >= 0) {
        await stopPreviewCurrentSampler();
      }

      final waveCmd = _waveCodeForInstrumentSlot(slot);
      final instrumentTypeCmd = _instrumentTypeCodeForSlot(slot);
      final synthParams = _synthParamsForInstrumentSlot(slot);

      final previewVoice = _previewVoiceIndexForInstrumentSlot(slot);
      if (_previewBypassVoice >= 0 && _previewBypassVoice != previewVoice) {
        await _setPreviewDryBypass(_previewBypassVoice, false);
      }
      final noteOff = _buildPreviewRowData(
        voiceIdx: previewVoice,
        note: -2,
        waveCmd: waveCmd,
        instrumentTypeCmd: instrumentTypeCmd,
        synthParams: synthParams,
      );
      final noteOn = _buildPreviewRowData(
        voiceIdx: previewVoice,
        note: midiNote.clamp(0, 127),
        waveCmd: waveCmd,
        instrumentTypeCmd: instrumentTypeCmd,
        synthParams: synthParams,
      );

      await _primeAudioForPreview();
      await _setPreviewDryBypass(previewVoice, true);
      await AudioEngine.instance.setRowData(noteOff);
      await AudioEngine.instance.setRowData(noteOn);

      _synthPreviewStopTimer?.cancel();
      final clampedDurationMs = durationMs.clamp(80, 4000);
      final startTime = DateTime.now();
      bool noteOffSent = false;
      _synthPreviewStopTimer = Timer.periodic(
        const Duration(milliseconds: 50),
        (_) async {
          if (_disposed) return;
          final elapsed = DateTime.now().difference(startTime).inMilliseconds;
          if (!noteOffSent && elapsed >= clampedDurationMs) {
            noteOffSent = true;
            await AudioEngine.instance.setRowData(noteOff);
          }
          final stillPlaying = await AudioEngine.instance.isVoicePlaying(
            previewVoice,
          );
          if (!stillPlaying && elapsed >= clampedDurationMs) {
            _synthPreviewStopTimer?.cancel();
            _synthPreviewStopTimer = null;
            if (_previewBypassVoice == previewVoice) {
              await _setPreviewDryBypass(previewVoice, false);
            }
          }
        },
      );

      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> stopPreviewCurrentSampler() async {
    _previewAutoStopTimer?.cancel();
    _previewAutoStopTimer = null;
    _synthPreviewStopTimer?.cancel();
    _synthPreviewStopTimer = null;
    _previewStartedAt = null;
    _previewRegionStartNorm = null;
    _previewRegionEndNorm = null;

    final slot =
        (_previewSamplerSlot >= 0
                ? _previewSamplerSlot
                : currentInstrumentIndex)
            .clamp(0, instruments.length - 1);
    final waveCmd = _waveCodeForInstrumentSlot(slot);
    final instrumentTypeCmd = _instrumentTypeCodeForSlot(slot);
    final synthParams = _synthParamsForInstrumentSlot(slot);
    final previewVoice = _previewVoiceIndexForInstrumentSlot(slot);
    final noteOff = _buildPreviewRowData(
      voiceIdx: previewVoice,
      note: -2,
      waveCmd: waveCmd,
      instrumentTypeCmd: instrumentTypeCmd,
      synthParams: synthParams,
    );
    await AudioEngine.instance.setRowData(noteOff);
    // Hard-stop any lingering release/reverb tails from preview.
    await AudioEngine.instance.killVoices(
      List<int>.filled(_audioVoiceCount, 1),
    );
    await _setPreviewDryBypass(previewVoice, false);
    // Do NOT stop the output stream here — stopping it causes an Android
    // hardware route change that produces a transient burst in the next
    // mic capture. The output stream stays open but silent.
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
    _previewRegionStartNorm = null;
    _previewRegionEndNorm = null;
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

  bool _hasAnyProjectJson(Directory root) {
    if (!root.existsSync()) return false;
    try {
      for (final entry in root.listSync(followLinks: false)) {
        if (entry is! Directory) continue;
        if (File('${entry.path}/project.json').existsSync()) return true;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  Future<Directory> _projectRootDir() async {
    final configured = _projectRootFolder;
    if (configured != null && configured.isNotEmpty) {
      final d = Directory(configured);
      if (!d.existsSync()) d.createSync(recursive: true);
      return d;
    }
    return _songsDir();
  }

  Future<File> _appSettingsFile() async {
    final base = await getApplicationDocumentsDirectory();
    return File('${base.path}/app_settings.json');
  }

  Future<void> _loadAppSettings() async {
    try {
      final file = await _appSettingsFile();
      Map<String, dynamic> j = const {};
      if (file.existsSync()) {
        final raw = await file.readAsString();
        j = jsonDecode(raw) as Map<String, dynamic>;
      }

      final projectRoot = j['projectRootFolder'] as String?;
      if (projectRoot != null && projectRoot.isNotEmpty) {
        final dir = Directory(projectRoot);
        if (dir.existsSync() &&
            (_hasAnyProjectJson(dir) || dir.path.isNotEmpty)) {
          _projectRootFolder = dir.path;
        }
      }

      final projectTreeUri = j['projectRootTreeUri'] as String?;
      if (projectTreeUri != null && projectTreeUri.isNotEmpty) {
        _projectRootTreeUri = projectTreeUri;
      }

      final folder = j['defaultSampleFolder'] as String?;
      if (folder != null &&
          folder.isNotEmpty &&
          Directory(folder).existsSync()) {
        _defaultSampleFolder = folder;
      }

      final autosave = j['autosaveEnabled'] as bool? ?? false;
      _autosaveEnabled = autosave;
      _rescheduleAutosaveTimer();

      // Restore the last open song automatically.
      final lastSong = j['lastOpenSongName'] as String?;
      if (lastSong != null && lastSong.isNotEmpty && hasProjectRootFolder) {
        try {
          await loadSongByName(lastSong);
        } catch (_) {
          // Non-fatal: start fresh if last session cannot be restored.
        }
      }

      _notifyListenersSafe();
    } catch (_) {
      // Ignore malformed/unavailable settings and keep defaults.
    }
  }

  Future<void> _saveAppSettings() async {
    try {
      final file = await _appSettingsFile();
      final payload = jsonEncode({
        'defaultSampleFolder': _defaultSampleFolder,
        'projectRootFolder': _projectRootFolder,
        'projectRootTreeUri': _projectRootTreeUri,
        'autosaveEnabled': _autosaveEnabled,
        'lastOpenSongName': song.name,
      });
      await file.writeAsString(payload, flush: true);
    } catch (_) {
      // Non-fatal: app continues with in-memory setting.
    }
  }

  Future<void> setAutosaveEnabled(bool enabled) async {
    if (_autosaveEnabled == enabled) return;
    _autosaveEnabled = enabled;
    _rescheduleAutosaveTimer();
    await _saveAppSettings();
    _notifyListenersSafe();
  }

  void _rescheduleAutosaveTimer() {
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
    if (_autosaveEnabled) {
      _autosaveTimer = Timer.periodic(
        const Duration(minutes: 10),
        (_) => unawaited(_doAutosave()),
      );
    }
  }

  Future<void> _doAutosave() async {
    if (_disposed) return;
    if (!_autosaveEnabled) return;
    if (!hasProjectRootFolder) return;
    await saveSong();
  }

  /// Called when the app loses focus. Silently saves if autosave is enabled.
  Future<void> autosaveOnFocusLost() async {
    if (!_autosaveEnabled) return;
    if (!hasProjectRootFolder) return;
    await saveSong();
  }

  Future<Directory> _projectDirForName(String name) async {
    final root = await _projectRootDir();
    final slug = _slugify(name);
    final safe = slug.isEmpty ? 'untitled' : slug;
    final d = Directory('${root.path}/$safe');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  String _trimTrailingSeparators(String path) {
    var result = path.trim();
    while (result.length > 1 && result.endsWith(Platform.pathSeparator)) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  Future<bool?> chooseProjectRootFolder() async {
    if (Platform.isAndroid) {
      try {
        final pickedUri = await _projectStorageChannel.invokeMethod<String>(
          'pickProjectFolder',
        );
        if (pickedUri == null || pickedUri.trim().isEmpty) {
          return null;
        }
        _projectRootTreeUri = pickedUri.trim();
        _projectRootFolder = null;
        await _saveAppSettings();
        _notifyListenersSafe();
        return true;
      } catch (_) {
        return false;
      }
    }

    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose where to create STRIA_PROJECTS',
    );
    if (picked == null || picked.trim().isEmpty) {
      return null;
    }

    final selectedPath = _trimTrailingSeparators(picked);
    final selectedName = selectedPath.split(Platform.pathSeparator).last;
    final rootPath = selectedName.toUpperCase() == kDefaultProjectsFolderName
        ? selectedPath
        : '$selectedPath${Platform.pathSeparator}$kDefaultProjectsFolderName';

    final dir = Directory(rootPath);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _projectRootFolder = dir.path;
    _projectRootTreeUri = null;
    await _saveAppSettings();
    _notifyListenersSafe();
    return true;
  }

  Future<void> setDefaultSampleFolder(String? folderPath) async {
    if (folderPath == null || folderPath.isEmpty) {
      _defaultSampleFolder = null;
      await _saveAppSettings();
      _notifyListenersSafe();
      return;
    }
    final path = folderPath.trim();
    if (!Directory(path).existsSync()) return;
    _defaultSampleFolder = path;
    await _saveAppSettings();
    _notifyListenersSafe();
  }

  Future<File> _songFile(String name) async {
    final dir = await _projectDirForName(name);
    return File('${dir.path}/project.json');
  }

  Future<String?> currentProjectPath() async {
    if (_usesProjectTreeStorage) return _projectRootTreeUri;
    if (!hasProjectRootFolder) return null;
    final dir = await _projectDirForName(song.name);
    return dir.path;
  }

  Future<Directory> _songSamplesDir([String? songName]) async {
    final raw = songName ?? song.name;
    final dir = await _projectDirForName(raw);
    final d = Directory('${dir.path}/samples');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Future<Directory> currentProjectSamplesDir() async => _songSamplesDir();

  String _sanitizeFileStem(String stem) {
    final cleaned = stem
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
    return cleaned.isEmpty ? 'sample' : cleaned;
  }

  /// Writes [bytes] as [fileName] into the SAF project folder [folderName].
  /// Returns the local cache path where the file is also stored for playback.
  Future<String?> _writeSafSample(
    String folderName,
    String fileName,
    Uint8List bytes,
  ) async {
    try {
      await _projectStorageChannel.invokeMethod<String>(
        'writeProjectBinaryFile',
        {
          'treeUri': _projectRootTreeUri,
          'folderName': folderName,
          'fileName': fileName,
          'bytes': bytes,
        },
      );
    } catch (_) {
      return null;
    }
    // Also cache locally so the audio engine can open it via POSIX path.
    final cachePath = await _safSampleCachePath(folderName, fileName);
    try {
      final cacheFile = File(cachePath);
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsBytes(bytes, flush: true);
    } catch (_) {
      return null;
    }
    return cachePath;
  }

  /// Reads a sample stored inside a SAF project folder and caches it locally.
  /// Returns the local cache path, or null if the file cannot be found.
  Future<String?> _readSafSample(String folderName, String fileName) async {
    // Return from cache if already there.
    final cachePath = await _safSampleCachePath(folderName, fileName);
    if (File(cachePath).existsSync()) return cachePath;

    Uint8List? bytes;
    try {
      final raw = await _projectStorageChannel.invokeMethod<dynamic>(
        'readProjectBinaryFile',
        {
          'treeUri': _projectRootTreeUri,
          'folderName': folderName,
          'fileName': fileName,
        },
      );
      if (raw == null) return null;
      bytes = raw is Uint8List ? raw : Uint8List.fromList(List<int>.from(raw as List));
    } catch (_) {
      return null;
    }
    try {
      final cacheFile = File(cachePath);
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsBytes(bytes, flush: true);
    } catch (_) {
      return null;
    }
    return cachePath;
  }

  Future<String> _safSampleCachePath(String folderName, String fileName) async {
    final tmp = await getTemporaryDirectory();
    return '${tmp.path}/stria_sample_cache/$folderName/$fileName';
  }

  Future<void> _persistSamplerAssetsForInstruments(
    List<InstrumentModel> sourceInstruments,
    Directory projectDir, {
    bool syncEngine = false,
  }) async {
    final projectRoot = '${projectDir.path}${Platform.pathSeparator}';

    for (var i = 0; i < sourceInstruments.length; i++) {
      final ins = sourceInstruments[i];
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

      final srcName =
          ins.sampler.sampleName ?? absSrc.split(Platform.pathSeparator).last;
      final dot = srcName.lastIndexOf('.');
      final stem = _sanitizeFileStem(
        dot > 0 ? srcName.substring(0, dot) : srcName,
      );
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
      if (syncEngine) {
        await AudioEngine.instance.setSamplerSample(i, dstPath);
      }
    }
  }

  Future<void> _persistSamplerAssetsForSong() async {
    if (_usesProjectTreeStorage) {
      await _persistSamplerAssetsForSongViaSaf();
    } else {
      final projectDir = await _songSamplesDir();
      await _persistSamplerAssetsForInstruments(
        instruments,
        projectDir,
        syncEngine: true,
      );
    }
  }

  /// SAF-mode save: copies each sampler WAV into the SAF project folder so it
  /// survives app reinstall, and caches it locally for immediate engine use.
  Future<void> _persistSamplerAssetsForSongViaSaf() async {
    final slug = _slugify(song.name);
    final folderName = slug.isEmpty ? 'untitled' : slug;

    for (var i = 0; i < instruments.length; i++) {
      final ins = instruments[i];
      if (ins.type != InstrumentType.sampler) continue;

      final srcPath = ins.sampler.samplePath;
      if (srcPath == null || srcPath.isEmpty) continue;

      // Bare filename: already persisted to SAF on a previous save — skip.
      final isBare =
          !srcPath.contains('/') &&
          !srcPath.contains(Platform.pathSeparator);
      if (isBare) continue;

      final src = File(srcPath);
      if (!src.existsSync()) continue;

      final rawName =
          ins.sampler.sampleName ?? srcPath.split(Platform.pathSeparator).last;
      final dot = rawName.lastIndexOf('.');
      final stem = _sanitizeFileStem(
        dot > 0 ? rawName.substring(0, dot) : rawName,
      );
      final ext = dot > 0 ? rawName.substring(dot) : '.wav';
      final candidate = '$stem$ext';

      final bytes = await src.readAsBytes();
      final cachePath = await _writeSafSample(folderName, candidate, bytes);
      if (cachePath == null) continue;

      // Update in-memory path: bare name in JSON, cache path for engine.
      ins.sampler.samplePath = candidate;
      ins.sampler.sampleName = candidate;
      await AudioEngine.instance.setSamplerSample(i, cachePath);
    }
  }

  /// Resolves a raw samplePath from JSON to a usable local filesystem path.
  /// Bare filenames are SAF-relative (or filesystem-relative in non-SAF mode).
  Future<String?> _resolveSamplePath(
    String? rawPath,
    String songName,
  ) async {
    if (rawPath == null || rawPath.isEmpty) return null;

    final isBare =
        !rawPath.contains('/') && !rawPath.contains(Platform.pathSeparator);

    if (isBare) {
      final slug = _slugify(songName);
      final folderName = slug.isEmpty ? 'untitled' : slug;
      if (_usesProjectTreeStorage) {
        return _readSafSample(folderName, rawPath);
      } else {
        final dir = await _songSamplesDir(songName);
        final path = '${dir.path}/$rawPath';
        return File(path).existsSync() ? path : null;
      }
    }

    // Absolute path: use directly if it exists.
    return File(rawPath).existsSync() ? rawPath : null;
  }

  void renameSong(String name) {
    song.name = name;
    _notifyListenersSafe();
  }

  /// Save current song then reset to a blank new song.
  Future<bool> newSong() async {
    final saved = await saveSong();
    await _clearInsertEffectsInEngine();
    song = SongModel.initial();
    for (var i = 0; i < instruments.length; i++) {
      instruments[i] = InstrumentModel.empty(i + 1);
    }
    _resetSongScopedState();
    _currentPatternIndex = 0;
    _currentTrackIndex = 0;
    _currentInstrumentIndex = 0;
    _currentArrangementSlotIndex = 0;
    selectedCell = null;
    _selectedRowStart = null;
    _selectedRowEnd = null;
    _songStateVersion++;
    _notifyListenersSafe();
    return saved;
  }

  /// Save to disk using song.name as the filename. Overwrites existing.
  Future<bool> saveSong() async {
    try {
      // Keep app-managed local copies of used sampler files for this song.
      await _persistSamplerAssetsForSong();
      final payload = jsonEncode({
        'song': song.toJson(),
        'instruments': instruments.map((i) => i.toJson()).toList(),
        'inserts': _insertSnapshot,
      });

      if (_usesProjectTreeStorage) {
        final slug = _slugify(song.name);
        final folderName = slug.isEmpty ? 'untitled' : slug;
        final ok = await _projectStorageChannel.invokeMethod<bool>(
          'writeProjectFile',
          {
            'treeUri': _projectRootTreeUri,
            'folderName': folderName,
            'text': payload,
          },
        );
        if (ok == true) unawaited(_saveAppSettings());
        return ok == true;
      }

      await (await _songFile(song.name)).writeAsString(payload);
      // Update last-open tracking (non-blocking).
      unawaited(_saveAppSettings());
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<File>> _listProjectFiles() async {
    final dir = await _projectRootDir();
    final files = <File>[];
    for (final entry in dir.listSync()) {
      if (entry is! Directory) continue;
      final projectFile = File('${entry.path}/project.json');
      if (projectFile.existsSync()) {
        files.add(projectFile);
        continue;
      }

      // Legacy fallback
      final legacyFile = File('${entry.path}/song.json');
      if (legacyFile.existsSync()) {
        files.add(legacyFile);
      }
    }
    return files;
  }

  bool get _usesProjectTreeStorage =>
      Platform.isAndroid &&
      _projectRootTreeUri != null &&
      _projectRootTreeUri!.isNotEmpty;

  Future<List<({String folderName, String source, bool isUri})>>
  _listProjectEntries() async {
    if (_usesProjectTreeStorage) {
      try {
        final raw = await _projectStorageChannel.invokeMethod<List<dynamic>>(
          'listProjectFiles',
          {'treeUri': _projectRootTreeUri},
        );
        final entries = <({String folderName, String source, bool isUri})>[];
        for (final item in (raw ?? const <dynamic>[])) {
          if (item is! Map) continue;
          final map = Map<String, dynamic>.from(item);
          final folder = (map['folderName'] as String?)?.trim() ?? '';
          final uri = (map['uri'] as String?)?.trim() ?? '';
          if (uri.isEmpty) continue;
          entries.add((folderName: folder, source: uri, isUri: true));
        }
        return entries;
      } catch (_) {
        return [];
      }
    }

    final files = await _listProjectFiles();
    return files
        .map(
          (f) => (
            folderName: f.parent.path.split(Platform.pathSeparator).last,
            source: f.path,
            isUri: false,
          ),
        )
        .toList();
  }

  Future<String?> _readProjectEntryRaw(
    ({String folderName, String source, bool isUri}) entry,
  ) async {
    if (entry.isUri) {
      return await _projectStorageChannel.invokeMethod<String>('readTextFile', {
        'uri': entry.source,
      });
    }
    return File(entry.source).readAsString();
  }

  /// Returns the display names of all saved songs, sorted alphabetically.
  Future<List<String>> listSavedSongs() async {
    try {
      final entries = await _listProjectEntries();
      final names = <String>[];
      for (final entry in entries) {
        try {
          final raw = await _readProjectEntryRaw(entry);
          if (raw == null || raw.isEmpty) {
            names.add(entry.folderName);
            continue;
          }
          final j = jsonDecode(raw) as Map<String, dynamic>;
          final n = (j['song'] as Map<String, dynamic>?)?['name'] as String?;
          if (n != null && n.trim().isNotEmpty) {
            names.add(n.trim());
          } else {
            // Legacy/fallback: show folder name when song name is missing.
            names.add(entry.folderName);
          }
        } catch (_) {
          // Corrupt or older schema: still expose the folder in the picker.
          names.add(entry.folderName);
        }
      }
      final unique = names.toSet().toList()..sort();
      return unique;
    } catch (_) {
      return [];
    }
  }

  ({SongModel song, List<InstrumentModel> instruments})? _decodeSongPayload(
    String raw,
  ) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;

    Map<String, dynamic>? songJson;
    List<dynamic>? instrumentList;

    // Current schema: { "song": {...}, "instruments": [...] }
    final wrappedSong = decoded['song'];
    if (wrappedSong is Map<String, dynamic>) {
      songJson = wrappedSong;
      instrumentList = decoded['instruments'] as List<dynamic>?;
    }

    // Legacy schema: song fields at top level (optionally with instruments).
    if (songJson == null &&
        decoded['name'] is String &&
        decoded['patterns'] is List) {
      songJson = decoded;
      instrumentList = decoded['instruments'] as List<dynamic>?;
    }

    if (songJson == null) return null;

    final loadedSong = SongModel.fromJson(songJson);
    final loadedInstruments = <InstrumentModel>[];
    for (final item in (instrumentList ?? const <dynamic>[])) {
      if (item is! Map) continue;
      try {
        final map = Map<String, dynamic>.from(item);
        loadedInstruments.add(InstrumentModel.fromJson(map));
      } catch (_) {
        // Skip malformed legacy instrument entries instead of failing whole load.
      }
    }

    return (song: loadedSong, instruments: loadedInstruments);
  }

  /// Load a song by its display name.
  Future<bool> loadSongByName(String name) async {
    try {
      _lastLoadError = null;
      ({String folderName, String source, bool isUri})? selected;
      String? selectedRaw;

      if (!_usesProjectTreeStorage) {
        // Fast path for current naming scheme (slug-based folder).
        final direct = await _songFile(name);
        if (direct.existsSync()) {
          selected = (
            folderName: direct.parent.path.split(Platform.pathSeparator).last,
            source: direct.path,
            isUri: false,
          );
        }
      }

      if (selected == null) {
        // Fallback path: scan every project and match by embedded song name
        // OR by folder name. This keeps older/migrated projects loadable.
        final wanted = name.trim().toLowerCase();
        final candidates = await _listProjectEntries();
        for (final candidate in candidates) {
          final folderName = candidate.folderName.trim().toLowerCase();
          if (folderName == wanted) {
            selected = candidate;
            selectedRaw = await _readProjectEntryRaw(candidate);
            break;
          }
          try {
            final raw = await _readProjectEntryRaw(candidate);
            if (raw == null || raw.isEmpty) continue;
            final decoded = _decodeSongPayload(raw);
            final embedded = decoded?.song.name.trim().toLowerCase();
            if (embedded == wanted) {
              selected = candidate;
              selectedRaw = raw;
              break;
            }
          } catch (_) {
            // Keep scanning other candidates.
          }
        }
      }

      if (selected == null) {
        _lastLoadError = 'Project file not found for "$name".';
        return false;
      }
      await _clearInsertEffectsInEngine();
      final raw = selectedRaw ?? await _readProjectEntryRaw(selected);
      if (raw == null || raw.isEmpty) {
        _lastLoadError = 'Project file is empty for "$name".';
        return false;
      }
      final decoded = _decodeSongPayload(raw);
      if (decoded == null) {
        _lastLoadError = 'Unsupported project format in ${selected.source}';
        return false;
      }

      final loadedSong = decoded.song;
      final loadedInstruments = decoded.instruments;
      song = loadedSong;
      for (var i = 0; i < instruments.length; i++) {
        instruments[i] = InstrumentModel.empty(i + 1);
      }
      for (
        var i = 0;
        i < instruments.length && i < loadedInstruments.length;
        i++
      ) {
        instruments[i] = loadedInstruments[i];
      }
      for (var i = 0; i < instruments.length; i++) {
        final ins = instruments[i];
        if (ins.type == InstrumentType.sampler) {
          try {
            // Resolve bare filenames (SAF-relative or filesystem-relative)
            // to a usable local path before passing to the audio engine.
            final resolved = await _resolveSamplePath(
              ins.sampler.samplePath,
              loadedSong.name,
            );
            ins.sampler.samplePath = resolved;
            final ok = await AudioEngine.instance.setSamplerSample(
              i,
              resolved,
            );
            if (!ok) {
              // Keep loading the song even if a sampler file is unavailable.
              // Clear samplePath (file missing) but keep sampleName so the UI
              // can show which sample needs to be relinked via the BROWSE button.
              ins.sampler.samplePath = null;
              await AudioEngine.instance.setSamplerSample(i, null);
            }
          } catch (_) {
            // Non-fatal: project data can still be loaded without the sample.
            ins.sampler.samplePath = null;
            await AudioEngine.instance.setSamplerSample(i, null);
          }
        }
      }
      _resetSongScopedState();

      // Restore insert snapshot from the loaded JSON (reset cleared it).
      try {
        final fullJson = jsonDecode(raw) as Map<String, dynamic>;
        _insertSnapshot = (fullJson['inserts'] as Map<String, dynamic>?) ?? {};
      } catch (_) {
        _insertSnapshot = {};
      }
      await _applyInsertSnapshotToEngine();

      _currentPatternIndex = 0;
      _currentTrackIndex = 0;
      _currentInstrumentIndex = 0;
      _currentArrangementSlotIndex = 0;
      selectedCell = null;
      _selectedRowStart = null;
      _selectedRowEnd = null;
      _songStateVersion++;
      _notifyListenersSafe();
      // Track this as the last open song (non-blocking).
      unawaited(_saveAppSettings());
      return true;
    } catch (e) {
      _lastLoadError = e.toString();
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _autosaveTimer?.cancel();
    _instrumentParamRebuildTimer?.cancel();
    _playheadTimer?.cancel();
    _previewAutoStopTimer?.cancel();
    _synthPreviewStopTimer?.cancel();
    if (_previewBypassVoice >= 0) {
      unawaited(_setPreviewDryBypass(_previewBypassVoice, false));
    }
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
