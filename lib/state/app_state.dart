import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../audio/audio_engine.dart';
import '../audio/wav_encoder.dart';
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
    required this.lineSamples,
  });
}

class AppState extends ChangeNotifier {
  static const int _audioVoiceCount = 8;
  static const int _audioRowStride = 25;

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
  Completer<void>? _exportCompleter; // non-null while a WAV export is in progress

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

  int _songStateVersion = 0;

  int _currentPatternIndex = 0;
  int _currentTrackIndex = 0;
  int _currentInstrumentIndex = 0;
  int _previewSamplerSlot = -1;
  int _previewBypassVoice = -1;
  String? _defaultSampleFolder;
  String? _projectRootFolder;

  static const String kDefaultProjectsFolderName = 'STRIA_PROJECTS';

  CellPosition? selectedCell;
  int? _selectedRow;
  int? get selectedRow => _selectedRow;
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

  TrackerCell? _rowClipboard;
  bool get hasRowClipboard => _rowClipboard != null;

  // Playback carry state for IN column per track.
  List<int> _carryInstrumentByTrack = const [];
  List<int?> _carryNoteByTrack = const [];
  List<int?> _carryVolumeByTrack = const [];
  List<double?> _carryVibSpeedByTrack = const [];
  List<double?> _carryVibDepthByTrack = const [];
  List<({List<int> cycle, int notesPerLine, int phase})?> _carryArpByTrack =
      const [];
  // Per-track Pxx automation carries: map of param-index → raw 00-99 value.
  List<Map<int, int>> _carryInstrumentParamsByTrack = const [];
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
  int? get queuedArrangementSlot => _queuedArrangementSlot;
  bool get playbackFollowsSong => _playbackFollowsSong;
  bool get isPreviewingCurrentSampler =>
      _previewSamplerSlot == _currentInstrumentIndex;
  String? get defaultSampleFolder => _defaultSampleFolder;
  String? get projectRootFolder => _projectRootFolder;
  bool get hasProjectRootFolder =>
      _projectRootFolder != null && _projectRootFolder!.isNotEmpty;
  int get songStateVersion => _songStateVersion;
  List<List<bool>> get trackInsertOccupied => _trackInsertOccupied;
  List<List<String?>> get trackInsertEffectNames => _trackInsertEffectNames;

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
    _selectedRow = null;
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

  /// Trigger a UI rebuild after the instrument editors mutate parameters
  /// directly. (They mutate plain fields; this just notifies listeners.)
  void instrumentParamsChanged() => notifyListeners();

  void selectTrack(int index) {
    _currentTrackIndex = index.clamp(0, currentPattern.tracks.length - 1);
    selectedCell = null;
    _selectedRow = null;
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
    currentPattern.tracks[trackIndex].mixerVolume = value.clamp(0.0, 1.0);
    final volumeValue = (currentPattern.tracks[trackIndex].mixerVolume * 99)
        .round()
        .clamp(0, 99);
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
    currentPattern.tracks[trackIndex].mixerPan = value.clamp(-1.0, 1.0);
    // Queue mixer command: M{channel}1 (pan controller)
    // Pan: -1.0 to 1.0 → 0 to 99 (0=left, 50=center, 99=right)
    final panValue = ((value + 1.0) * 49.5).round().clamp(0, 99);
    AudioEngine.instance.queueMixerCommands([trackIndex + 1, 1, panValue, 0]);
    notifyListeners();
  }

  void toggleTrackMixerMute(int trackIndex) {
    if (trackIndex < 0 || trackIndex >= currentPattern.tracks.length) return;
    final track = currentPattern.tracks[trackIndex];
    track.mixerMute = !track.mixerMute;
    // Queue mixer command: M{channel}2 (mute controller)
    // value > 0 = muted, 0 = unmuted
    final muteValue = track.mixerMute ? 1 : 0;
    AudioEngine.instance.queueMixerCommands([trackIndex + 1, 2, muteValue, 0]);
    _applyImmediateMixerMuteState();
    notifyListeners();
  }

  void toggleTrackMixerSolo(int trackIndex) {
    if (trackIndex < 0 || trackIndex >= currentPattern.tracks.length) return;
    final track = currentPattern.tracks[trackIndex];
    track.mixerSolo = !track.mixerSolo;
    // Queue mixer command: M{channel}3 (solo controller)
    // value > 0 = soloed, 0 = not soloed
    final soloValue = track.mixerSolo ? 1 : 0;
    AudioEngine.instance.queueMixerCommands([trackIndex + 1, 3, soloValue, 0]);
    _applyImmediateMixerMuteState();
    notifyListeners();
  }

  // ── Cell selection ───────────────────────────────────────────────────────

  void selectCell(int row, CellColumn column) {
    final pos = CellPosition(row, column);
    selectedCell = (selectedCell == pos) ? null : pos;
    _selectedRow = null;
    _boxSelection = null;
    _isBoxSelecting = false;
    notifyListeners();
  }

  void clearSelection() {
    selectedCell = null;
    _selectedRow = null;
    _boxSelection = null;
    _isBoxSelecting = false;
    notifyListeners();
  }

  // ── Row selection ────────────────────────────────────────────────────────

  void selectRow(int row) {
    if (row < 0 || row >= rowCount) return;
    _selectedRow = (_selectedRow == row) ? null : row;
    selectedCell = null;
    _boxSelection = null;
    _isBoxSelecting = false;
    notifyListeners();
  }

  void clearRowSelection() {
    if (_selectedRow == null) return;
    _selectedRow = null;
    notifyListeners();
  }

  void beginBoxSelection(int trackIndex, int row, CellColumn column) {
    _currentTrackIndex = trackIndex.clamp(0, currentPattern.tracks.length - 1);
    selectedCell = null;
    _selectedRow = null;
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

  /// Move the currently selected row up/down by [delta] in the current track,
  /// swapping content with the neighbouring row. Selection follows the row.
  void moveSelectedRowBy(int delta) {
    final row = _selectedRow;
    if (row == null) return;
    final newRow = (row + delta).clamp(0, rowCount - 1);
    if (newRow == row) return;
    final cells = currentTrack.cells;
    final tmp = cells[row];
    cells[row] = cells[newRow];
    cells[newRow] = tmp;
    _selectedRow = newRow;
    notifyListeners();
  }

  /// Cut row = copy + clear (current track only).
  void cutRow(int row) {
    copyRow(row);
    deleteRow(row);
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
        track.setNote(row, NoteValue.fromScrollIndex(49)); // C-4
      case CellColumn.instrument:
        track.writeColumnValue(
          row,
          column,
          _defaultInstrumentForRow(track, row),
        );
      case CellColumn.volume:
        track.writeColumnValue(row, column, 80);
      case CellColumn.fx0cmd:
      case CellColumn.fx1cmd:
      case CellColumn.fx2cmd:
        track.writeColumnValue(row, column, 0x00);
      case CellColumn.fx0val:
      case CellColumn.fx1val:
      case CellColumn.fx2val:
        final fxIndex = column == CellColumn.fx0val
            ? 0
            : column == CellColumn.fx1val
            ? 1
            : 2;
        final cmd = track.cells[row].fxSlots[fxIndex].command;
        track.writeColumnValue(row, column, cmd == kFxPAN ? 50 : 0);
    }
    notifyListeners();
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
  /// of both endpoints) with linearly interpolated values for [col].
  /// Interpolation uses time-accurate beat positions so per-beat line
  /// overrides are handled correctly. For FX value columns, every filled row
  /// is also stamped with the matching FX command from [toRow].
  void interpolateColumn(int toRow, CellColumn col) {
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
      final interpolated = (startVal + (endVal - startVal) * frac).round();
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
    song.addPattern();
    notifyListeners();
  }

  /// Insert a new empty pattern at [index] (0-based).
  void insertNewPatternAt(int index) {
    if (song.patterns.length >= kMaxSongPatterns) return;
    final clamped = index.clamp(0, song.patterns.length);
    song.patterns.insert(clamped, song.createEmptyPattern());
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
      song.patterns.add(song.createEmptyPattern());
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

  void setPlaybackFollowsSong(bool enabled) {
    if (_playbackFollowsSong == enabled) return;
    _playbackFollowsSong = enabled;
    if (!_playbackFollowsSong) {
      _queuedArrangementSlot = null;
    }
    if (isPlaying) {
      if (_playbackFollowsSong) {
        _playheadArrangementSlot = _currentArrangementSlotIndex.clamp(
          0,
          song.patterns.length - 1,
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
    final ins = instruments[safe];
    if (ins.type == InstrumentType.sampler) return 1;
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
  }) {
    final safe = slot.clamp(0, instruments.length - 1);
    final ins = instruments[safe];
    if (ins.type != InstrumentType.simpleSynth) {
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
    final isSampler =
        instruments[slot.clamp(0, instruments.length - 1)].type !=
        InstrumentType.simpleSynth;
    int overriddenWave = waveCmd;
    carry.forEach((paramIdx, rawVal) {
      if (isSampler) {
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
    _carryArpByTrack = const [];
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
    _playbackFollowsSong = true;
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

    if (tap.samples.isEmpty) return null;

    // Build stereo WAV — samples are interleaved L,R floats.
    final wavBytes = WavEncoder.encodeWav(
      samples: tap.samples,
      sampleRate: tap.sampleRate,
      numChannels: 2,
    );

    // Save next to the project folder, or fall back to app documents dir.
    final String dirPath;
    final projectRoot = _projectRootFolder;
    if (projectRoot != null && projectRoot.isNotEmpty) {
      dirPath = projectRoot;
    } else {
      final dir = await getApplicationDocumentsDirectory();
      dirPath = dir.path;
    }

    final safeName = song.name
        .replaceAll(RegExp(r'[^\w\s\-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    final fileName = '${safeName.isEmpty ? 'export' : safeName}.wav';
    final filePath = '$dirPath/$fileName';
    await File(filePath).writeAsBytes(wavBytes);
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

  /// Duration of the current playhead row (used by FX schedulers).
  Duration _lineDuration() =>
      _lineDurationForPatternRow(currentPattern, playheadRow);

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
    await AudioEngine.instance.setQueuedPlaybackLooping(true);
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
      playheadRow = (playheadRow + advanced) % rowCount;
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
    if (targetSlot < 0 ||
        targetSlot >= song.patterns.length ||
        song.patterns[targetSlot].isEmpty) {
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
      _carryArpByTrack =
          List<({List<int> cycle, int notesPerLine, int phase})?>.filled(
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
    // channel: 0=master, 1-15=mixer channels
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
      int volCmd = (track.mixerVolume.clamp(0.0, 1.0) * 255).round();
      int panCmd = (((track.mixerPan.clamp(-1.0, 1.0) + 1.0) / 2.0) * 255)
          .round();
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
      int retrigVolumeMode = 0;
      int retrigNotesPerLine = 0;
      int arpInterval1 = -1;
      int arpInterval2 = -1;
      int arcOctaveLayers = 0;
      int arcNotesPerLine = 0;
      int? chancePct;

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
          // Note-off clears VIB carry for this track.
          _carryVibSpeedByTrack[t] = null;
          _carryVibDepthByTrack[t] = null;
        }

        if (cell.volume != null) {
          volCmd = ui99ToAudio255(cell.volume!);
          _carryVolumeByTrack[t] = volCmd;
        }

        for (final fx in cell.fxSlots) {
          if (fx.command == kFxPAN && fx.value != null) {
            panCmd = ui99ToAudio255(fx.value!.clamp(0, 99));
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
            // Override volume for this row only — does not update carry state.
            volCmd = ui99ToAudio255(fx.value!.clamp(0, 99));
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

      // ARP carry: resolve noteCmd before building the segment/rowData.
      if (arpInterval1 >= 0 && noteCmd >= 0) {
        // New note with ARP: (re)start the carry.
        final layers = arcOctaveLayers > 0 ? arcOctaveLayers : 1;
        final cycle = <int>[];
        for (int oct = 0; oct < layers; oct++) {
          final offset = 12 * oct;
          cycle.add((noteCmd + offset).clamp(0, 127));
          cycle.add((noteCmd + arpInterval1 + offset).clamp(0, 127));
          cycle.add((noteCmd + arpInterval2 + offset).clamp(0, 127));
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
        (_lineDuration().inMicroseconds * kSampleRate) ~/ 1000000;

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
      if (!file.existsSync()) return;
      final raw = await file.readAsString();
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final projectRoot = j['projectRootFolder'] as String?;
      if (projectRoot != null && projectRoot.isNotEmpty) {
        final dir = Directory(projectRoot);
        if (dir.existsSync()) {
          _projectRootFolder = dir.path;
        }
      }
      final folder = j['defaultSampleFolder'] as String?;
      if (folder == null || folder.isEmpty) return;
      if (!Directory(folder).existsSync()) return;
      _defaultSampleFolder = folder;
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
      });
      await file.writeAsString(payload, flush: true);
    } catch (_) {
      // Non-fatal: app continues with in-memory setting.
    }
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
    final projectDir = await _songSamplesDir();
    await _persistSamplerAssetsForInstruments(
      instruments,
      projectDir,
      syncEngine: true,
    );
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
    _currentArrangementSlotIndex = 0;
    selectedCell = null;
    _selectedRow = null;
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
      final dir = await _projectRootDir();
      final files = dir
          .listSync()
          .whereType<Directory>()
          .map((d) => File('${d.path}/project.json'))
          .where((f) => f.existsSync())
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
      await _clearInsertEffectsInEngine();
      final raw = await file.readAsString();
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final loadedSong = SongModel.fromJson(j['song'] as Map<String, dynamic>);
      final loadedInstruments = (j['instruments'] as List<dynamic>)
          .map((e) => InstrumentModel.fromJson(e as Map<String, dynamic>))
          .toList();
      song = loadedSong;
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
          await AudioEngine.instance.setSamplerSample(
            i,
            ins.sampler.samplePath,
          );
        }
      }
      _resetSongScopedState();
      _currentPatternIndex = 0;
      _currentTrackIndex = 0;
      _currentArrangementSlotIndex = 0;
      selectedCell = null;
      _selectedRow = null;
      _songStateVersion++;
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
