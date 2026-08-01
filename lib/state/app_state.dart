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
  /// Row-accurate send-routing changes from SN1/SN2/SN3: [trackIdx, destChannel, ...].
  final List<int> sendRoutingCommandData;
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
    required this.sendRoutingCommandData,
    required this.lineSamples,
  });
}

/// Per-track playback carry state. Replaces what used to be 12 parallel
/// `List<...>` fields indexed by track. Keeping it in one record makes it
/// impossible to forget updating one of the fields when adding a new FX.
class _TrackCarry {
  int instrument = 0;
  int? note;
  int? volume;
  double? vibSpeed;
  double? vibDepth;
  int? volFx;
  int? panFx;
  double? treSpeed;
  double? treDepth;
  int? treMode;
  ({List<int> cycle, int notesPerLine, int phase})? arp;
  ({int startNote, int endNote, int totalLines, int linesElapsed})? slide;
  Map<int, int> instrumentParams = <int, int>{};
  int? sendChannel; // 14, 15, or 16 (from SN1/SN2/SN3); null = no active send
  int? sendPercent; // 1-99 (from SN1/SN2/SN3 value); null = no active send
}

/// Per-pattern undo / redo history. Snapshots are JSON strings of the
/// pattern's musical content (cells, beats, lpb, beat overrides, fx envelopes,
/// bpm) so the user can rewind their edits without affecting mixer state on
/// the tracks. Capped at [maxDepth] to bound memory.
class _PatternUndoStack {
  static const int maxDepth = 50;
  // Each entry: (json snapshot of state BEFORE the mutation, human label).
  final List<({String json, String label})> _undo = [];
  final List<({String json, String label})> _redo = [];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  String? get undoLabel => _undo.isEmpty ? null : _undo.last.label;
  String? get redoLabel => _redo.isEmpty ? null : _redo.last.label;

  void pushUndo(String json, String label) {
    _undo.add((json: json, label: label));
    if (_undo.length > maxDepth) {
      _undo.removeRange(0, _undo.length - maxDepth);
    }
    _redo.clear();
  }

  /// Pop an undo entry. Caller passes the CURRENT state json so it can be
  /// pushed onto the redo stack. Returns the snapshot to restore, or null.
  ({String json, String label})? popUndoSwap(String currentJson) {
    if (_undo.isEmpty) return null;
    final entry = _undo.removeLast();
    _redo.add((json: currentJson, label: entry.label));
    if (_redo.length > maxDepth) {
      _redo.removeRange(0, _redo.length - maxDepth);
    }
    return entry;
  }

  ({String json, String label})? popRedoSwap(String currentJson) {
    if (_redo.isEmpty) return null;
    final entry = _redo.removeLast();
    _undo.add((json: currentJson, label: entry.label));
    if (_undo.length > maxDepth) {
      _undo.removeRange(0, _undo.length - maxDepth);
    }
    return entry;
  }
}

/// Pattern editor display modes.
///  • normal    — single track, full columns, swipe to page.
///  • collapsed — all tracks side-by-side showing NOTE + INST.
///  • drum      — all tracks side-by-side showing INST only (pill style).
enum PatternViewMode { normal, collapsed, drum }

/// Rectangular clipboard for the Song view. Each entry [data[dp][dt]] is a
/// full list of [TrackerCell]s (one per pattern row) copied from the source
/// track. Cells are always deep-copied on both copy and paste, so mutating
/// one side never bleeds into the other.
class _TrackRangeClipboard {
  final int patternCount; // vertical extent (# of pattern rows)
  final int trackCount; // horizontal extent (# of tracks)
  final List<List<List<TrackerCell>>> data;

  _TrackRangeClipboard({
    required this.patternCount,
    required this.trackCount,
    required this.data,
  });
}

class AppState extends ChangeNotifier {
  static const int _audioVoiceCount = kMaxTracks;
  static const int _audioRowStride = 49;

  /// Max master fader gain (linear). 2.0 = +6 dB headroom for intentionally
  /// driving the always-on safety limiter (makeup-style gain).
  static const double kMaxMasterVolume = 2.0;

  // ── Per-pattern undo / redo ────────────────────────────────────────────────
  // Stack is keyed by PatternModel identity via Expando, so it follows the
  // pattern across re-orderings and is auto-collected when the pattern dies.
  final Expando<_PatternUndoStack> _patternUndo = Expando('patternUndo');
  // Coalesces snapshots within a single user gesture: the first mutation in
  // a synchronous burst pushes one snapshot; nested mutations skip. Flag
  // resets on the next microtask.
  bool _patternMutationInProgress = false;

  // ── Song arrangement undo / redo ──────────────────────────────────────────
  // Snapshots the full patterns list before each arrangement mutation
  // (add, remove, move, duplicate, merge).
  final _PatternUndoStack _songUndo = _PatternUndoStack();
  // Prevents sub-operations (e.g. duplicatePattern inside compound operations) from
  // pushing a second snapshot for the same gesture.
  final bool _songMutationInProgress = false;

  AppState() {
    _loadAppSettings();
  }

  SongModel song = SongModel.initial();
  bool _disposed = false;
  bool _notifyQueued = false;
  bool _playheadPollInFlight = false;
  bool _nextPassScheduled =
      false; // double-buffer: true once next loop pass is in C++ pending queue
  // The absolute row range locked in at play() for the current pattern session.
  // Both are inclusive indices into currentPattern. Captured once so that
  // mid-playback selection changes don't disturb the running engine.
  int _playbackStartRow = 0;
  int _playbackEndRow = 0;
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
  final Map<
    int,
    ({String note, int volume, int instrument, int fxCommand, int fxValue})
  >
  _patternLastValues = {};

  int _songStateVersion = 0;
  int _lastSavedSongStateVersion = 0;

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
  // Always-on master safety limiter; user-toggleable from the master strip.
  bool _masterLimiterEnabled = true;
  // User-toggleable extra audio-buffer margin for CPU-heavy conditions (e.g.
  // screen recording). Off by default — trades a few ms of extra output
  // latency for more headroom against underrun crackle.
  bool _stabilityModeEnabled = false;
  Timer? _autosaveTimer;
  Timer? _instrumentParamRebuildTimer;
  bool _liveRebuildInFlight = false;
  // Tracks the active navigation tab (0=SONG, 1=PATTERN, 2=INST, 3=MIXER).
  // Used by play() to determine song-follow vs pattern-loop mode.
  int _activeTabIndex = 0; // default matches MainScreen's initial _tabIndex

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

  // Whole-column selection (tap a NOTE/IN/VL header in the normal pattern
  // view to select every row of that column in the current track).
  CellColumn? _selectedColumn;
  CellColumn? get selectedColumn => _selectedColumn;

  /// Selects (or, if already selected, deselects) an entire column of the
  /// current track. Mutually exclusive with cell/row/box selection.
  void selectColumn(CellColumn column) {
    selectedCell = null;
    _selectedRowStart = null;
    _selectedRowEnd = null;
    _boxSelection = null;
    _isBoxSelecting = false;
    _selectedColumn = (_selectedColumn == column) ? null : column;
    notifyListeners();
  }

  void clearColumnSelection() {
    if (_selectedColumn == null) return;
    _selectedColumn = null;
    notifyListeners();
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

  // Song-view rectangular range clipboard: a 2D grid of whole tracks
  // (each entry is that track's cell list). data[dp][dt] holds the cells
  // copied from the source pattern (anchorPatternRow + dp) and source
  // track (anchorTrack + dt). See copyTrackRange / pasteTrackRange.
  _TrackRangeClipboard? _trackRangeClipboard;
  bool get hasTrackRangeClipboard =>
      _trackRangeClipboard != null &&
      _trackRangeClipboard!.patternCount > 0 &&
      _trackRangeClipboard!.trackCount > 0;
  int get trackRangeClipboardPatternCount =>
      _trackRangeClipboard?.patternCount ?? 0;
  int get trackRangeClipboardTrackCount =>
      _trackRangeClipboard?.trackCount ?? 0;

  // Anchor cell of the current Song-view timeline selection, if any.
  // The Song screen mirrors its local selection into this field so other
  // screens (in particular the top nav's PATTERN tab) can open Pattern
  // view on the exact cell the user last selected. Only the *anchor* is
  // stored: if the user extends the selection into a range via a second
  // long-press, this stays pointing at the first-selected cell.
  ({int patternIndex, int trackIndex})? _songTimelineSelectionAnchor;
  ({int patternIndex, int trackIndex})? get songTimelineSelectionAnchor =>
      _songTimelineSelectionAnchor;

  void setSongTimelineSelectionAnchor(int patternIndex, int trackIndex) {
    _songTimelineSelectionAnchor = (
      patternIndex: patternIndex,
      trackIndex: trackIndex,
    );
    notifyListeners();
  }

  void clearSongTimelineSelectionAnchor() {
    if (_songTimelineSelectionAnchor == null) return;
    _songTimelineSelectionAnchor = null;
    notifyListeners();
  }

  // Box-selection clipboard (column-aware — only the selected columns are pasted).
  List<TrackerCell>? _boxClipboard;
  List<CellColumn>? _boxClipboardColumns;
  bool get hasBoxClipboard =>
      _boxClipboard != null &&
      _boxClipboard!.isNotEmpty &&
      _boxClipboardColumns != null &&
      _boxClipboardColumns!.isNotEmpty;

  // Playback carry state, per track. One record per pattern track.
  List<_TrackCarry> _trackCarry = const [];
  int _carryPatternIndex = -1;
  // Set by _triggerCurrentRow() when _trackCarry was just (re)created this
  // call, so the send-routing baseline for every track gets re-emitted.
  bool _sendRoutingCarryWasReset = false;
  // When true, suppresses the automatic carry reset that normally happens
  // at row 0. Set only while _buildScheduledRows() is building a seamless
  // loop-pass continuation, so tracks holding/ringing a note across the
  // loop boundary keep their real instrument/FX state instead of being
  // reset to defaults.
  bool _suppressCarryResetAtRowZero = false;

  // BPM FX (tempo nudge) running state. Tracks the "live" tempo as modified
  // by BPM FX commands encountered while stepping through a pattern.
  // Always resets to the pattern's own snapshot BPM at row 0 or when the
  // pattern being played changes — deliberately NOT gated by
  // _suppressCarryResetAtRowZero, since tempo must reset every loop pass
  // even when note carry continues across the loop boundary.
  double _bpmFxEffective = 120.0;
  int _bpmFxPatternIndex = -1;

  // SWN FX (swing override) running state. Mirrors _bpmFxEffective: resets
  // to the pattern's own snapshot swing amount at row 0 or when the pattern
  // being played changes, unconditionally (not gated by
  // _suppressCarryResetAtRowZero).
  double _swnFxEffective = 0.0;
  int _swnFxPatternIndex = -1;

  bool isPlaying = false;
  bool isRecording = false;
  bool _loopPlaybackEnabled = false;
  bool _followPlayhead = false;
  int playheadRow = 0;

  /// When true, all tracks are visible side-by-side showing only
  /// NOTE + INST columns. When false, only the current track is
  /// visible (full columns) via swipe-paging.
  PatternViewMode viewMode = PatternViewMode.normal;

  /// True when a multi-track grid layout is active (collapsed OR drum).
  bool get collapsedView => viewMode != PatternViewMode.normal;

  /// True when the ultra-compact drum pill layout is active.
  bool get drumView => viewMode == PatternViewMode.drum;

  // ── Getters ──────────────────────────────────────────────────────────────

  int get currentPatternIndex => _currentPatternIndex;
  int get currentTrackIndex => _currentTrackIndex;
  int get currentInstrumentIndex => _currentInstrumentIndex;
  int get currentArrangementSlotIndex => _currentArrangementSlotIndex;
  int get playheadArrangementSlot => _playheadArrangementSlot;
  int? get queuedArrangementSlot => _queuedArrangementSlot;
  bool get playbackFollowsSong => _playbackFollowsSong;
  bool get loopPlaybackEnabled => _loopPlaybackEnabled;
  bool get followPlayhead => _followPlayhead;
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
  bool get masterLimiterEnabled => _masterLimiterEnabled;
  bool get stabilityModeEnabled => _stabilityModeEnabled;
  int get songStateVersion => _songStateVersion;
  bool get hasUnsavedChanges => _songStateVersion != _lastSavedSongStateVersion;
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

    final slot = _previewSamplerSlot.clamp(0, instruments.length - 1);
    final sampler = instruments[slot].sampler;
    final mode = sampler.loopMode;

    final elapsedMs = DateTime.now().difference(started).inMilliseconds;
    final d = _previewDurationMs;

    // Map playhead across full sample region (start → end)
    final playStart = sampler.start.clamp(0.0, 1.0);
    final playEnd = sampler.end.clamp(playStart + 0.001, 1.0);
    final playSize = playEnd - playStart;

    if (mode == SamplerLoopMode.off) {
      // Non-looping: simple linear playhead
      final normalizedTime = (elapsedMs / d).clamp(0.0, 1.0);
      return (playStart + normalizedTime * playSize).clamp(0.0, 1.0);
    }

    // Looping enabled
    final loopStart = sampler.loopStart.clamp(0.0, 1.0);
    final loopEnd = sampler.loopEnd.clamp(loopStart + 0.001, 1.0);
    final loopSize = loopEnd - loopStart;

    // Time to reach loopStart from playStart
    final preLoopSize = loopStart - playStart;
    final preLoopDurationMs = (d * (preLoopSize / playSize)).toInt();

    if (elapsedMs < preLoopDurationMs) {
      // Still in pre-loop region
      final normalizedPreLoop = elapsedMs / preLoopDurationMs;
      return (playStart + normalizedPreLoop * preLoopSize).clamp(0.0, 1.0);
    }

    // In loop region
    final posInLoop = (elapsedMs - preLoopDurationMs) % (d - preLoopDurationMs);
    final loopDurationMs = d - preLoopDurationMs;

    if (loopDurationMs <= 0) return loopStart;

    final normalizedPosInLoop = posInLoop / loopDurationMs;

    if (mode == SamplerLoopMode.pingPong) {
      // Ping-pong: 0.0->1.0->0.0 pattern
      final cycleDuration = loopDurationMs / 2.0;
      final cyclePos = posInLoop / cycleDuration;
      final bounceNorm = cyclePos >= 1.0
          ? 1.0 - (cyclePos - 1.0).clamp(0.0, 1.0)
          : cyclePos.clamp(0.0, 1.0);
      return (loopStart + bounceNorm * loopSize).clamp(0.0, 1.0);
    } else {
      // Forward: 0.0->1.0 pattern
      return (loopStart + normalizedPosInLoop * loopSize).clamp(0.0, 1.0);
    }
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

  /// Returns the last instrument explicitly written in this pattern session,
  /// or null if the user has never set an instrument in this pattern.
  int? get explicitLastInstrument =>
      _patternLastValues[_currentPatternIndex]?.instrument;

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
    _selectedColumn = null;
    _clampSelectionToPattern();
    _restartPlayheadTimerIfNeeded();
    notifyListeners();
  }

  /// Move focus to the pattern immediately before/after the current one
  /// (delta -1 or +1). Used by Pattern view to let the user scroll past the
  /// top/bottom row edge into the neighbouring pattern, the same way
  /// side-scrolling moves between tracks. Stays within
  /// [0, kMaxSongPatterns - 1] and lazily creates the target slot if it
  /// hasn't been touched yet. Keeps the current track selected (unlike
  /// [selectPattern], which resets to track 0) so the scroll feels
  /// continuous.
  void goToAdjacentPattern(int delta) {
    final newIndex = (_currentPatternIndex + delta).clamp(
      0,
      kMaxSongPatterns - 1,
    );
    if (newIndex == _currentPatternIndex) return;
    _ensurePatternSlot(newIndex);
    _currentPatternIndex = newIndex;
    _currentArrangementSlotIndex = newIndex;
    selectedCell = null;
    _selectedRowStart = null;
    _selectedRowEnd = null;
    _selectedColumn = null;
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
      await _loadNativePatternPlaybackQueue(
        startRow: playheadRow,
        endRow: _playbackEndRow,
      );
      if (isPlaying && !_playbackFollowsSong) {
        await AudioEngine.instance.start();
      }
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
    _selectedColumn = null;
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
    // Clear undo/redo/clipboard for fresh song — don't carry over from the
    // previous song or an old load state.
    // NOTE: _patternUndo Expando is final and holds stale pattern references,
    // but those old patterns are no longer in the song, so it's harmless.
    _songUndo._undo.clear();
    _songUndo._redo.clear();
    _trackRangeClipboard = null;
    clearSongTimelineSelectionAnchor();
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
        case 'EQ-5':
          // EQ-5 is a UI-only 5-knob view over the native 3-band EQ engine
          // (see mixer_screen.dart onMasterInsertTap/onInsertSlotTap) — it
          // shares typeCode 7 and only bass/presence/air map to the 3 bands.
          final typeCode = 7;
          final wet = d('wet', 1.0);
          double toNorm(double db) => (db / 12.0).clamp(-1.0, 1.0);
          final lowGain = toNorm(d('bass', 0.0));
          final midGain = toNorm(d('presence', 0.0));
          final highGain = toNorm(d('air', 0.0));
          const lowFreq = 0.07;
          const midFreq = 0.436;
          const midQ = 0.091;
          const highFreq = 0.862;
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
              lowGain,
              lowFreq,
              midGain,
              midFreq,
              midQ,
              highGain,
              highFreq,
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
              lowGain,
              lowFreq,
              midGain,
              midFreq,
              midQ,
              highGain,
              highFreq,
            );
          }
        case 'FLANGER':
          final typeCode = 9;
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
            await AudioEngine.instance.setMasterFlangerParams(
              slot,
              d('rate', 0.3),
              d('depth', 0.22),
              d('delay', 0.2),
              d('feedback', 0.0),
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
              d('dry', 1.0),
              wet,
            );
            await AudioEngine.instance.setTrackFlangerParams(
              trackIdx,
              slot,
              d('rate', 0.3),
              d('depth', 0.22),
              d('delay', 0.2),
              d('feedback', 0.0),
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
        case 'SIDECHAIN':
          final typeCode = 10;
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
            await AudioEngine.instance.setMasterSidechainParams(
              slot,
              i('sourceTrack', -1),
              d('threshold', 0.3),
              d('duck', 0.7),
              d('attack', 0.05),
              d('release', 0.3),
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
            await AudioEngine.instance.setTrackSidechainParams(
              trackIdx,
              slot,
              i('sourceTrack', -1),
              d('threshold', 0.3),
              d('duck', 0.7),
              d('attack', 0.05),
              d('release', 0.3),
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
    queue.addAll([0, 1, muteValue, 0]);
    // Master volume is pushed via the direct float path (setMasterVolumeLinear)
    // because it can exceed unity and would otherwise be clipped by the 0..99
    // mixer-command transport.
    AudioEngine.instance.setMasterVolumeLinear(song.masterVolume);
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

  /// Build the static full-reroute send array (mixer-screen "send channel"
  /// knob only). SN1/SN2/SN3 no longer affect this — they drive a separate,
  /// row-accurate percentage aux-send instead (see sendRoutingCommandData).
  List<int> _buildStaticSendRouting() {
    final tracks = currentPattern.tracks;
    return List.generate(tracks.length, (i) => tracks[i].sendChannel);
  }

  // ── Cell selection ───────────────────────────────────────────────────────

  void selectCell(int row, CellColumn column) {
    final pos = CellPosition(row, column);
    selectedCell = (selectedCell == pos) ? null : pos;
    _selectedRowStart = null;
    _selectedRowEnd = null;
    _boxSelection = null;
    _isBoxSelecting = false;
    _selectedColumn = null;
    notifyListeners();
  }

  void clearSelection() {
    selectedCell = null;
    _selectedRowStart = null;
    _selectedRowEnd = null;
    _boxSelection = null;
    _isBoxSelecting = false;
    _selectedColumn = null;
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
    _selectedColumn = null;

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
    _selectedColumn = null;
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

    _pushPatternUndo('move rows');
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
    _pushPatternUndo('cut row');
    copyRow(row);
    deleteRow(row);
    clearRowSelection();
  }

  // ── Cell editing ─────────────────────────────────────────────────────────

  /// Increment the value in a cell's column by [delta] (positive = higher).
  void nudgeCell(int row, CellColumn column, int delta) {
    _pushPatternUndo('nudge cell');
    final track = currentTrack;
    final current = track.readColumnValue(row, column) ?? 0;
    final clamped = (current + delta).clamp(
      track.minValue(column),
      track.maxValue(column, row: row),
    );
    track.writeColumnValue(row, column, clamped);

    // Auto-fill note with C-4 if instrument is entered and note is empty
    if (column == CellColumn.instrument && clamped > 0) {
      if (track.cells[row].note.isEmpty) {
        track.setNote(row, NoteValue.fromScrollIndex(49)); // C-4
      }
    }

    // Remember the last value set
    if (column == CellColumn.note) {
      // Note nudging is handled via setNote, but handle it here for completeness
      final cell = track.cells[row];
      if (cell.note.isNote) {
        updateLastNote(cell.note.display);
      }
    } else if (column == CellColumn.instrument) {
      updateLastInstrument(clamped);
    } else if (column == CellColumn.fx0cmd ||
        column == CellColumn.fx1cmd ||
        column == CellColumn.fx2cmd) {
      updateLastFxCommand(clamped);
    } else if (column == CellColumn.fx0val ||
        column == CellColumn.fx1val ||
        column == CellColumn.fx2val) {
      updateLastFxValue(clamped);
    }
    notifyListeners();
  }

  void setNote(int row, NoteValue note) {
    _pushPatternUndo('set note');
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
    final inst = track.cells[row].instrument;
    return (inst != null && inst > 0)
        ? inst
        : _defaultInstrumentForRow(track, row);
  }

  /// Resets a cell column to its default value (always writes a value).
  void resetColumnToDefault(int row, CellColumn column) {
    _pushPatternUndo('reset column');
    final track = currentTrack;
    switch (column) {
      case CellColumn.note:
        track.setNote(row, NoteValue.fromScrollIndex(49)); // C-4
        break;
      case CellColumn.instrument:
        track.cells[row].instrument = null; // clear to empty
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
    _pushPatternUndo('insert value');
    final track = currentTrack;
    switch (column) {
      case CellColumn.note:
        // Use the last note if available, otherwise default to C4
        final noteDisplay = lastNote;
        final noteValue = _parseNoteDisplay(noteDisplay);
        track.setNote(row, noteValue);
      case CellColumn.instrument:
        // Use the last instrument value (same behaviour as note recall).
        track.writeColumnValue(row, column, lastInstrument);
        // Auto-fill note with C-4 if instrument is entered and note is empty
        if (lastInstrument > 0 && track.cells[row].note.isEmpty) {
          track.setNote(row, NoteValue.fromScrollIndex(49)); // C-4
        }
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

    const noteNames = [
      'C',
      'C#',
      'D',
      'D#',
      'E',
      'F',
      'F#',
      'G',
      'G#',
      'A',
      'A#',
      'B',
    ];
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
    _pushPatternUndo('clear column');
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
    _pushPatternUndo('clear cell');
    currentPattern.tracks[_currentTrackIndex].cells[row] = TrackerCell.empty();
    notifyListeners();
  }

  /// Clear a cell in any track (used for drum mode in collapsed view).
  void clearCellInTrack(int row, int trackIndex) {
    if (trackIndex < 0 || trackIndex >= currentPattern.tracks.length) return;
    _pushPatternUndo('clear cell');
    currentPattern.tracks[trackIndex].cells[row] = TrackerCell.empty();
    notifyListeners();
  }

  /// Cycle drum velocity state and set volume accordingly.
  /// Cycles: default (vol=null) → accent (vol=99) → half (vol=50) → default
  void cycleDrumVelocity(int row, int trackIndex) {
    if (trackIndex < 0 || trackIndex >= currentPattern.tracks.length) return;
    if (row < 0 || row >= currentPattern.tracks[trackIndex].cells.length) {
      return;
    }
    _pushPatternUndo('drum velocity');
    final cell = currentPattern.tracks[trackIndex].cells[row];
    final nextVelocity = switch (cell.drumVelocity) {
      DrumVelocity.default_ => DrumVelocity.accent,
      DrumVelocity.accent => DrumVelocity.half,
      DrumVelocity.half => DrumVelocity.default_,
    };
    cell.drumVelocity = nextVelocity;
    cell.volume = switch (nextVelocity) {
      DrumVelocity.default_ => null,
      DrumVelocity.accent => 99,
      DrumVelocity.half => 50,
    };
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
    _pushPatternUndo('envelope gamma');
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
    _pushPatternUndo('delete envelope');
    currentPattern.fxEnvelopes.remove(run);
    notifyListeners();
  }

  void copyRow(int row) {
    _rowClipboard = [currentTrack.cells[row].copy()];
    notifyListeners();
  }

  void pasteRow(int row) {
    if (_rowClipboard == null || _rowClipboard!.isEmpty) return;
    _pushPatternUndo('paste row');
    // Paste at the specified row, using first row from clipboard
    currentTrack.cells[row] = _rowClipboard!.first.copy();
    // Select the pasted row
    _selectedRowStart = row;
    _selectedRowEnd = row;
    notifyListeners();
  }

  void deleteRow(int row) {
    _pushPatternUndo('delete row');
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
    _pushPatternUndo('cut rows');
    copyRows(startRow, endRow);
    deleteRows(startRow, endRow);
    clearRowSelection();
  }

  /// Delete multiple rows (inclusive range) by clearing them to empty.
  void deleteRows(int startRow, int endRow) {
    if (startRow < 0 || endRow >= rowCount) return;
    _pushPatternUndo('delete rows');
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

    _pushPatternUndo('paste rows');
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

    _pushPatternUndo('duplicate rows');
    copyRows(startRow, endRow);
    pasteRows(insertRow);
  }

  // ── Song-view track clipboard ─────────────────────────────────────────────

  /// Move a track's cells directly from one pattern/track to another,
  /// without touching the shared row clipboard. Used by the Song-view
  /// drag-and-drop feature so dragging a track never clobbers whatever the
  /// user has already staged via explicit COPY/CUT.
  void moveTrackFullTo(
    int srcPatternIndex,
    int srcTrackIndex,
    int dstPatternIndex,
    int dstTrackIndex,
  ) {
    if (srcPatternIndex < 0 || srcPatternIndex >= song.patterns.length) return;
    if (dstPatternIndex < 0 || dstPatternIndex >= song.patterns.length) return;
    final srcPat = song.patterns[srcPatternIndex];
    final dstPat = song.patterns[dstPatternIndex];
    if (srcTrackIndex < 0 || srcTrackIndex >= srcPat.tracks.length) return;
    if (dstTrackIndex < 0 || dstTrackIndex >= dstPat.tracks.length) return;
    _pushSongUndo('move track');
    final srcCells = srcPat.tracks[srcTrackIndex].cells;
    final dstCells = dstPat.tracks[dstTrackIndex].cells;
    final count = srcCells.length.clamp(0, dstCells.length);
    for (int i = 0; i < count; i++) {
      dstCells[i] = srcCells[i].copy();
    }
    notifyListeners();
  }

  /// Copy every cell in a specific track (by pattern/track index) to the
  /// shared row clipboard. Compatible with pattern-view paste.
  void copyTrackFull(int patternIndex, int trackIndex) {
    if (patternIndex < 0 || patternIndex >= song.patterns.length) return;
    final pat = song.patterns[patternIndex];
    if (trackIndex < 0 || trackIndex >= pat.tracks.length) return;
    _rowClipboard = pat.tracks[trackIndex].cells.map((c) => c.copy()).toList();
    notifyListeners();
  }

  /// Cut a track: copy all cells then clear them.
  /// Recorded on the song-level undo stack (visible via the Song screen's
  /// undo/redo buttons) since this is a Song-view action that can span
  /// multiple patterns.
  void cutTrackFull(int patternIndex, int trackIndex) {
    if (patternIndex < 0 || patternIndex >= song.patterns.length) return;
    final pat = song.patterns[patternIndex];
    if (trackIndex < 0 || trackIndex >= pat.tracks.length) return;
    _pushSongUndo('cut track');
    final track = pat.tracks[trackIndex];
    _rowClipboard = track.cells.map((c) => c.copy()).toList();
    for (int r = 0; r < track.cells.length; r++) {
      track.cells[r] = TrackerCell.empty();
    }
    notifyListeners();
  }

  /// Paste the shared row clipboard into a specific track starting at row 0.
  void pasteTrackFull(int patternIndex, int trackIndex) {
    if (_rowClipboard == null || _rowClipboard!.isEmpty) return;
    if (patternIndex < 0 || patternIndex >= song.patterns.length) return;
    final pat = song.patterns[patternIndex];
    if (trackIndex < 0 || trackIndex >= pat.tracks.length) return;
    _pushSongUndo('paste track');
    final cells = pat.tracks[trackIndex].cells;
    final count = _rowClipboard!.length.clamp(0, cells.length);
    for (int i = 0; i < count; i++) {
      cells[i] = _rowClipboard![i].copy();
    }
    notifyListeners();
  }

  /// Clear every cell in a specific track.
  void deleteTrackFull(int patternIndex, int trackIndex) {
    if (patternIndex < 0 || patternIndex >= song.patterns.length) return;
    final pat = song.patterns[patternIndex];
    if (trackIndex < 0 || trackIndex >= pat.tracks.length) return;
    _pushSongUndo('delete track');
    final track = pat.tracks[trackIndex];
    for (int r = 0; r < track.cells.length; r++) {
      track.cells[r] = TrackerCell.empty();
    }
    notifyListeners();
  }

  /// Check if a track has any non-empty cells.
  bool isTrackEmpty(int patternIndex, int trackIndex) {
    if (patternIndex < 0 || patternIndex >= song.patterns.length) return true;
    final pat = song.patterns[patternIndex];
    if (trackIndex < 0 || trackIndex >= pat.tracks.length) return true;
    final track = pat.tracks[trackIndex];
    return track.cells.every((cell) => cell.isEmpty);
  }

  /// Swap the contents of two tracks in the song.
  /// Both tracks must be in valid patterns. Recorded on the song-level undo
  /// stack (a single snapshot of the full arrangement covers both patterns,
  /// whether they're the same pattern or two different ones).
  void swapTracks(int srcPattern, int srcTrack, int dstPattern, int dstTrack) {
    if (srcPattern < 0 || srcPattern >= song.patterns.length) return;
    if (dstPattern < 0 || dstPattern >= song.patterns.length) return;
    final srcPat = song.patterns[srcPattern];
    final dstPat = song.patterns[dstPattern];
    if (srcTrack < 0 || srcTrack >= srcPat.tracks.length) return;
    if (dstTrack < 0 || dstTrack >= dstPat.tracks.length) return;

    _pushSongUndo('swap tracks');

    final srcCells = srcPat.tracks[srcTrack].cells;
    final dstCells = dstPat.tracks[dstTrack].cells;

    // Swap cell contents
    for (int i = 0; i < srcCells.length && i < dstCells.length; i++) {
      final temp = srcCells[i];
      srcCells[i] = dstCells[i];
      dstCells[i] = temp;
    }

    notifyListeners();
  }

  // ── Song-view rectangular range operations ────────────────────────────────

  /// Normalize [p0,p1] × [t0,t1] into a top-left / bottom-right rectangle and
  /// clamp it to the currently existing pattern/track counts. Returns null if
  /// the resulting rectangle is empty (no real cells to touch).
  ({int pTop, int tLeft, int patternCount, int trackCount})? _normalizeRange(
    int p0,
    int t0,
    int p1,
    int t1,
  ) {
    final pMin = p0 < p1 ? p0 : p1;
    final pMax = p0 < p1 ? p1 : p0;
    final tMin = t0 < t1 ? t0 : t1;
    final tMax = t0 < t1 ? t1 : t0;
    if (pMin >= song.patterns.length) return null;
    final pLast = pMax.clamp(0, song.patterns.length - 1);
    // Track count is the same across every pattern (kMaxTracks), but be safe.
    final laneCount = song.patterns[pMin].tracks.length;
    if (laneCount == 0 || tMin >= laneCount) return null;
    final tLast = tMax.clamp(0, laneCount - 1);
    final ph = pLast - pMin + 1;
    final tw = tLast - tMin + 1;
    if (ph <= 0 || tw <= 0) return null;
    return (
      pTop: pMin,
      tLeft: tMin,
      patternCount: ph,
      trackCount: tw,
    );
  }

  /// Copy a rectangular range of tracks into the song range clipboard.
  /// Does NOT touch the single-track [_rowClipboard]; the two clipboards are
  /// completely independent so nothing the user staged in pattern-view gets
  /// clobbered here.
  void copyTrackRange(int p0, int t0, int p1, int t1) {
    final r = _normalizeRange(p0, t0, p1, t1);
    if (r == null) return;
    final data = <List<List<TrackerCell>>>[];
    for (int dp = 0; dp < r.patternCount; dp++) {
      final rowCols = <List<TrackerCell>>[];
      final pat = song.patterns[r.pTop + dp];
      for (int dt = 0; dt < r.trackCount; dt++) {
        final trackIdx = r.tLeft + dt;
        if (trackIdx < pat.tracks.length) {
          rowCols.add(pat.tracks[trackIdx].cells.map((c) => c.copy()).toList());
        } else {
          rowCols.add(const []);
        }
      }
      data.add(rowCols);
    }
    _trackRangeClipboard = _TrackRangeClipboard(
      patternCount: r.patternCount,
      trackCount: r.trackCount,
      data: data,
    );
    notifyListeners();
  }

  /// Cut a rectangular range = copy + clear the source cells.
  void cutTrackRange(int p0, int t0, int p1, int t1) {
    final r = _normalizeRange(p0, t0, p1, t1);
    if (r == null) return;
    _pushSongUndo('cut range');
    // Copy first (doesn't push undo — silent).
    copyTrackRange(p0, t0, p1, t1);
    _clearRange(r.pTop, r.tLeft, r.patternCount, r.trackCount);
    notifyListeners();
  }

  /// Clear (empty out) every cell in a rectangular range.
  void deleteTrackRange(int p0, int t0, int p1, int t1) {
    final r = _normalizeRange(p0, t0, p1, t1);
    if (r == null) return;
    _pushSongUndo('delete range');
    _clearRange(r.pTop, r.tLeft, r.patternCount, r.trackCount);
    notifyListeners();
  }

  void _clearRange(int pTop, int tLeft, int patternCount, int trackCount) {
    for (int dp = 0; dp < patternCount; dp++) {
      final p = pTop + dp;
      if (p >= song.patterns.length) break;
      final pat = song.patterns[p];
      for (int dt = 0; dt < trackCount; dt++) {
        final t = tLeft + dt;
        if (t >= pat.tracks.length) break;
        final cells = pat.tracks[t].cells;
        for (int i = 0; i < cells.length; i++) {
          cells[i] = TrackerCell.empty();
        }
      }
    }
  }

  /// Returns true if every cell in the given rectangular range (sized by the
  /// range clipboard) is empty. If a range slot references a pattern that
  /// doesn't exist yet, it counts as empty (it'll be created on paste).
  bool isTrackRangeEmpty(
    int pTop,
    int tLeft,
    int patternCount,
    int trackCount,
  ) {
    for (int dp = 0; dp < patternCount; dp++) {
      final p = pTop + dp;
      if (p >= song.patterns.length) continue;
      final pat = song.patterns[p];
      for (int dt = 0; dt < trackCount; dt++) {
        final t = tLeft + dt;
        if (t < 0 || t >= pat.tracks.length) continue;
        for (final cell in pat.tracks[t].cells) {
          if (!cell.isEmpty) return false;
        }
      }
    }
    return true;
  }

  /// Paste the range clipboard so its top-left lands at (pTop, tLeft).
  /// Target rows/tracks outside the arrangement are silently truncated.
  /// Any target pattern that doesn't exist yet is created on demand so the
  /// user can paste into an empty song slot the same way single-track paste
  /// already does.
  void pasteTrackRange(int pTop, int tLeft) {
    final clip = _trackRangeClipboard;
    if (clip == null) return;
    _pushSongUndo('paste range');
    _writeRangeFromClipboard(clip, pTop, tLeft, swap: false);
    notifyListeners();
  }

  /// Swap-paste: writes clipboard data into the target range AND captures
  /// what was there into the clipboard, letting the user "carry" the
  /// previous contents to another spot with another paste.
  void pasteTrackRangeSwap(int pTop, int tLeft) {
    final clip = _trackRangeClipboard;
    if (clip == null) return;
    _pushSongUndo('swap range');
    _writeRangeFromClipboard(clip, pTop, tLeft, swap: true);
    notifyListeners();
  }

  void _writeRangeFromClipboard(
    _TrackRangeClipboard clip,
    int pTop,
    int tLeft, {
    required bool swap,
  }) {
    // For swap: capture the pre-existing target cells into a fresh clipboard.
    final swapped = <List<List<TrackerCell>>>[];
    for (int dp = 0; dp < clip.patternCount; dp++) {
      final targetP = pTop + dp;
      // Auto-create empty slot patterns so paste into an unused song slot
      // "just works", matching pasteTrackFull's contract.
      if (targetP >= song.patterns.length) {
        if (targetP >= kMaxSongPatterns) break;
        createPatternAt(targetP);
      }
      final pat = song.patterns[targetP];
      final rowCols = <List<TrackerCell>>[];
      for (int dt = 0; dt < clip.trackCount; dt++) {
        final targetT = tLeft + dt;
        if (targetT < 0 || targetT >= pat.tracks.length) {
          rowCols.add(const []);
          continue;
        }
        final dstCells = pat.tracks[targetT].cells;
        if (swap) {
          rowCols.add(dstCells.map((c) => c.copy()).toList());
        }
        final srcCells = clip.data[dp][dt];
        final n = srcCells.length < dstCells.length
            ? srcCells.length
            : dstCells.length;
        for (int i = 0; i < n; i++) {
          dstCells[i] = srcCells[i].copy();
        }
      }
      if (swap) swapped.add(rowCols);
    }
    if (swap) {
      _trackRangeClipboard = _TrackRangeClipboard(
        patternCount: clip.patternCount,
        trackCount: clip.trackCount,
        data: swapped,
      );
    }
  }

  // ── Row randomisers ───────────────────────────────────────────────────────

  /// SHUF: Shuffle whole cells between rows that already have an actual note.
  /// Empty rows, hold rows, and note-off rows stay in place.
  void shuffleSelectedRows() {
    final range = selectedRowRange;
    if (range == null) return;
    _pushPatternUndo('shuffle');
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
    _pushPatternUndo('scatter');
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

  // Humanize baselines — captured the first time HUV/HUT is used on a given
  // selection so repeated taps re-roll from the original values/layout
  // instead of compounding on top of the last tap's result. A new selection
  // (different track or row range) resets the baseline automatically.
  int? _huvBaselineTrack;
  (int, int)? _huvBaselineRange;
  List<int?>? _huvBaselineVolumes;

  int? _hutBaselineTrack;
  (int, int)? _hutBaselineRange;
  List<TrackerCell>? _hutBaselineCells;

  /// Rolls a random timing offset in [-range, range], excluding 0 (a no-op —
  /// every humanized note should actually move) and -1 (which maps to DEL
  /// value 99 via 100+offset, a value the audio engine can't trigger due to
  /// an exact-row-boundary edge case in queueDelaysLocked).
  int _rollTimingOffset(math.Random rnd, int range) {
    int offset;
    do {
      offset = rnd.nextInt(range * 2 + 1) - range;
    } while (offset == 0 || offset == -1);
    return offset;
  }

  /// HUV: Humanize volume. Every note row in the selection gets its volume
  /// nudged by a random amount between -25 and +25, clamped to 0-99. The
  /// original volumes are snapshotted on first use per selection so repeated
  /// taps re-roll from the original values rather than drifting further
  /// away with each tap. Selection is intentionally left active so HUT can
  /// be applied next.
  void humanizeVolume() {
    final range = selectedRowRange;
    if (range == null) return;
    _pushPatternUndo('humanize volume');
    final cells = currentTrack.cells;
    final rnd = math.Random();

    final isNewSelection =
        _huvBaselineTrack != currentTrackIndex || _huvBaselineRange != range;
    if (isNewSelection) {
      _huvBaselineTrack = currentTrackIndex;
      _huvBaselineRange = range;
      _huvBaselineVolumes = [
        for (int r = range.$1; r <= range.$2; r++) cells[r].volume,
      ];
    }
    final baseline = _huvBaselineVolumes!;

    for (int r = range.$1; r <= range.$2; r++) {
      if (!cells[r].note.isNote) continue;
      final base = baseline[r - range.$1] ?? 80;
      final offset = rnd.nextInt(51) - 25; // -25..+25
      cells[r].volume = (base + offset).clamp(0, 99);
    }
    notifyListeners();
  }

  /// Finds an existing DEL slot on [cell], or the first empty slot, to reuse
  /// for a humanize timing shift. Returns null if no DEL slot exists and all
  /// slots are already occupied by other commands (no room).
  int? _findOrCreateDelSlot(TrackerCell cell) {
    for (int i = 0; i < cell.fxSlots.length; i++) {
      if (cell.fxSlots[i].command == kFxDEL) return i;
    }
    for (int i = 0; i < cell.fxSlots.length; i++) {
      if (cell.fxSlots[i].command == null) return i;
    }
    return null;
  }

  /// HUT: Humanize timing. Every note row in the selection is shifted
  /// randomly by -25..+25 (percent of a row), never landing on 0 (a no-op)
  /// or a value that maps to the unplayable DEL 99. Positive offsets delay
  /// the note in place via DEL. Negative offsets move the note to the
  /// previous row and set DEL near the end of that row (75-98), simulating
  /// an early trigger. If the previous row already has a note, or has no
  /// free FX slot for DEL, falls back to a late-only shift on the original
  /// row. The original layout is snapshotted on first use per selection so
  /// repeated taps restore it before re-rolling, instead of ratcheting notes
  /// permanently toward row 0. Selection is intentionally left active so HUV
  /// can be applied next.
  void humanizeTiming() {
    final range = selectedRowRange;
    if (range == null) return;
    _pushPatternUndo('humanize timing');
    final cells = currentTrack.cells;
    final rnd = math.Random();

    final isNewSelection =
        _hutBaselineTrack != currentTrackIndex || _hutBaselineRange != range;
    if (isNewSelection) {
      _hutBaselineTrack = currentTrackIndex;
      _hutBaselineRange = range;
      _hutBaselineCells = [
        for (int r = range.$1; r <= range.$2; r++) cells[r].copy(),
      ];
    } else {
      // Restore the original layout before re-rolling so repeated taps
      // don't ratchet notes permanently toward row 0.
      for (int r = range.$1; r <= range.$2; r++) {
        cells[r] = _hutBaselineCells![r - range.$1].copy();
      }
    }

    // Phase 1: evaluate against the original (pre-mutation) state.
    final lateShifts = <int, int>{}; // row -> delValue
    final earlyShifts = <int, ({int destRow, int delValue})>{}; // srcRow -> ...

    for (int r = range.$1; r <= range.$2; r++) {
      if (!cells[r].note.isNote) continue;
      final offset = _rollTimingOffset(rnd, 25); // -25..+25, never 0 or -1

      if (offset > 0) {
        lateShifts[r] = offset;
        continue;
      }

      final destRow = r - 1;
      final canMoveEarly =
          destRow >= 0 &&
          !cells[destRow].note.isNote &&
          _findOrCreateDelSlot(cells[destRow]) != null;
      if (canMoveEarly) {
        earlyShifts[r] = (destRow: destRow, delValue: 100 + offset);
      } else {
        lateShifts[r] = offset.abs(); // fallback to late-only
      }
    }

    // Phase 2: apply.
    for (final entry in earlyShifts.entries) {
      final srcRow = entry.key;
      final destRow = entry.value.destRow;
      final delValue = entry.value.delValue;
      final src = cells[srcRow];
      final dest = cells[destRow];

      dest.note = src.note;
      dest.instrument = src.instrument;
      dest.volume = src.volume;
      src.note = NoteValue.empty;
      src.instrument = null;
      src.volume = null;

      final slot = _findOrCreateDelSlot(dest)!;
      dest.fxSlots[slot].command = kFxDEL;
      dest.fxSlots[slot].value = delValue;
    }
    for (final entry in lateShifts.entries) {
      final row = entry.key;
      final delValue = entry.value;
      final cell = cells[row];
      final slot = _findOrCreateDelSlot(cell);
      if (slot == null) continue; // no room — skip this note's timing shift
      cell.fxSlots[slot].command = kFxDEL;
      cell.fxSlots[slot].value = delValue;
    }

    notifyListeners();
  }

  /// RAND: Note positions stay fixed; pitch changes to a random MIDI value
  /// within the min–max range of notes already in the selection.
  void randomizePitchInSelection() {
    final range = selectedRowRange;
    if (range == null) return;
    _pushPatternUndo('randomize pitch');
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
  /// Shared row-range transpose logic used by both the multi-row-selection
  /// transpose buttons and the whole-column transpose buttons.
  void _transposeRows(int startRow, int endRow, int delta) {
    final cells = currentTrack.cells;
    for (int r = startRow; r <= endRow; r++) {
      if (!cells[r].note.isNote) continue;
      final newScroll = (cells[r].note.scrollIndex + delta).clamp(1, 120);
      cells[r].note = NoteValue.fromScrollIndex(newScroll);
    }
  }

  void transposeSelectionBySemitones(int delta) {
    final range = selectedRowRange;
    if (range == null) return;
    _pushPatternUndo('transpose');
    _transposeRows(range.$1, range.$2, delta);
    notifyListeners();
  }

  /// Transposes every note in the current track's NOTE column by [delta]
  /// semitones. Used by the whole-column NOTE menu (header tap selects the
  /// entire column). Reuses the same skip-non-note/clamp logic as
  /// [transposeSelectionBySemitones], just applied to every row.
  void transposeColumnBySemitones(int delta) {
    _pushPatternUndo('transpose column');
    _transposeRows(0, currentTrack.cells.length - 1, delta);
    notifyListeners();
  }

  /// Nudges every non-empty value in [column] across the whole current
  /// track by [delta], clamped to the column's normal range. Empty cells
  /// are left untouched — mirrors [nudgeCell], which only ever operates on
  /// a value that's already present. Used by the whole-column IN/VOL menus.
  ///
  /// VOL is a special case: any row with a real note shows an implied
  /// default of 80 even when the cell itself is still null (see
  /// [cellDisplay]'s volume fallback) — nudge that implied value into a
  /// real one instead of skipping the row.
  void nudgeColumn(CellColumn column, int delta) {
    _pushPatternUndo('nudge column');
    final track = currentTrack;
    final minV = track.minValue(column);
    for (int r = 0; r < track.cells.length; r++) {
      var current = track.readColumnValue(r, column);
      if (current == null) {
        if (column == CellColumn.volume && track.cells[r].note.isNote) {
          current = 80;
        } else {
          continue;
        }
      }
      final maxV = track.maxValue(column, row: r); // Pass row for command-aware clamping
      final clamped = (current + delta).clamp(minV, maxV);
      track.writeColumnValue(r, column, clamped);
    }
    notifyListeners();
  }

  void deleteBoxSelection() {
    final sel = _boxSelection;
    if (sel == null) return;
    _pushPatternUndo('delete selection');
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

  /// Copy the box selection into the box clipboard. The selected column range
  /// is remembered so paste always writes back to the same column types.
  void copyBoxSelection() {
    final sel = _boxSelection;
    if (sel == null) return;
    final track = currentPattern.tracks[sel.trackIndex];
    _boxClipboard = [
      for (int row = sel.minRow; row <= sel.maxRow; row++)
        track.cells[row].copy(),
    ];
    _boxClipboardColumns = CellColumn.values
        .where(
          (c) => c.index >= sel.minColumnIndex && c.index <= sel.maxColumnIndex,
        )
        .toList();
    _boxSelection = null;
    _isBoxSelecting = false;
    notifyListeners();
  }

  /// Cut the box selection: copies to box clipboard then clears the source cells.
  void cutBoxSelection() {
    final sel = _boxSelection;
    if (sel == null) return;
    _pushPatternUndo('cut selection');
    final track = currentPattern.tracks[sel.trackIndex];
    _boxClipboard = [
      for (int row = sel.minRow; row <= sel.maxRow; row++)
        track.cells[row].copy(),
    ];
    _boxClipboardColumns = CellColumn.values
        .where(
          (c) => c.index >= sel.minColumnIndex && c.index <= sel.maxColumnIndex,
        )
        .toList();
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

  /// Paste the box clipboard into the current track starting at [targetRow].
  /// Only the columns that were selected at copy time are written; all other
  /// columns in the target rows are left untouched.
  /// Rows that would fall beyond the pattern end are silently truncated.
  void pasteBoxSelection(int targetRow) {
    final clipboard = _boxClipboard;
    final columns = _boxClipboardColumns;
    if (clipboard == null ||
        clipboard.isEmpty ||
        columns == null ||
        columns.isEmpty) {
      return;
    }
    if (targetRow < 0 || targetRow >= rowCount) return;
    _pushPatternUndo('paste selection');
    final track = currentTrack;
    final pasteRowCount = clipboard.length.clamp(0, rowCount - targetRow);
    for (int i = 0; i < pasteRowCount; i++) {
      final src = clipboard[i];
      final dstRow = targetRow + i;
      for (final col in columns) {
        _writeColumnFromCell(track, dstRow, col, src);
      }
    }
    _selectedRowStart = targetRow;
    _selectedRowEnd = targetRow + pasteRowCount - 1;
    clearBoxSelection();
    notifyListeners();
  }

  /// Writes a single column value from [src] into the cell at [row] in [track].
  void _writeColumnFromCell(
    TrackModel track,
    int row,
    CellColumn column,
    TrackerCell src,
  ) {
    switch (column) {
      case CellColumn.note:
        track.cells[row].note = src.note;
        break;
      case CellColumn.instrument:
        track.cells[row].instrument = src.instrument;
        break;
      case CellColumn.volume:
        track.cells[row].volume = src.volume;
        break;
      case CellColumn.fx0cmd:
        track.cells[row].fxSlots[0].command = src.fxSlots[0].command;
        break;
      case CellColumn.fx0val:
        track.cells[row].fxSlots[0].value = src.fxSlots[0].value;
        break;
      case CellColumn.fx1cmd:
        track.cells[row].fxSlots[1].command = src.fxSlots[1].command;
        break;
      case CellColumn.fx1val:
        track.cells[row].fxSlots[1].value = src.fxSlots[1].value;
        break;
      case CellColumn.fx2cmd:
        track.cells[row].fxSlots[2].command = src.fxSlots[2].command;
        break;
      case CellColumn.fx2val:
        track.cells[row].fxSlots[2].value = src.fxSlots[2].value;
        break;
    }
  }

  // ── Track collapse ────────────────────────────────────────────────────────

  /// Cycle the pattern editor view: normal → collapsed → drum → normal.
  void cyclePatternViewMode() {
    viewMode = switch (viewMode) {
      PatternViewMode.normal => PatternViewMode.collapsed,
      PatternViewMode.collapsed => PatternViewMode.drum,
      PatternViewMode.drum => PatternViewMode.normal,
    };
    if (collapsedView) {
      _boxSelection = null;
      _isBoxSelecting = false;
    }
    notifyListeners();
  }

  // ── Song pattern management ──────────────────────────────────────────────

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
    _pushSongUndo('duplicate pattern');
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

  void mergePatternWithNext(int index) {
    if (!canMergePatternWithNext(index)) return;
    _pushSongUndo('merge patterns');
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

  /// Fill the patterns list with empty patterns, if needed, so that a real
  /// pattern object exists at [index]. Every one of the 99 song slots is
  /// always "active" (empty or with data) — this just backs that slot with
  /// a real list entry so it can be read, written, or swapped like any
  /// other. It never changes selection/playhead state.
  void _ensurePatternSlot(int index) {
    while (song.patterns.length <= index) {
      final pattern = song.createEmptyPattern();
      _copyProjectMixerStateToPattern(pattern);
      _copyProjectSendRoutingToPattern(pattern);
      song.patterns.add(pattern);
    }
  }

  void movePatternUp(int index) {
    if (index <= 0 || index >= kMaxSongPatterns) return;
    final newIndex = index - 1;
    _ensurePatternSlot(index);
    _pushSongUndo('move up');
    final temp = song.patterns[newIndex];
    song.patterns[newIndex] = song.patterns[index];
    song.patterns[index] = temp;
    _currentPatternIndex = newIndex;
    _currentArrangementSlotIndex = newIndex;
    notifyListeners();
  }

  void movePatternDown(int index) {
    if (index < 0 || index >= kMaxSongPatterns - 1) return;
    final newIndex = index + 1;
    _ensurePatternSlot(newIndex);
    _pushSongUndo('move down');
    final temp = song.patterns[newIndex];
    song.patterns[newIndex] = song.patterns[index];
    song.patterns[index] = temp;
    _currentPatternIndex = newIndex;
    _currentArrangementSlotIndex = newIndex;
    notifyListeners();
  }

  /// Move pattern [sourceIndex] to [targetIndex] by reordering other patterns.
  /// Patterns between source and target shift to fill the gap. The moved
  /// pattern (its name and data, whatever it is — even if empty) travels
  /// with it untouched; only its position changes. This is a plain list
  /// reorder — no renaming, no new identities, ever.
  void movePatternTo(int sourceIndex, int targetIndex) {
    if (sourceIndex == targetIndex) return;
    if (sourceIndex < 0 || sourceIndex >= song.patterns.length) return;
    if (targetIndex < 0 || targetIndex >= kMaxSongPatterns) return;
    _pushSongUndo('move pattern to slot');

    // Ensure target slot exists
    _ensurePatternSlot(targetIndex);

    // Remove source pattern
    final pat = song.patterns.removeAt(sourceIndex);

    // After removal, insert at target index. This works for both directions:
    // - Moving down: target shifts up to (targetIndex-1), inserting at targetIndex puts source after it
    // - Moving up: target unchanged at targetIndex, inserting there puts source before it
    song.patterns.insert(targetIndex, pat);

    _currentPatternIndex = targetIndex;
    _currentArrangementSlotIndex = targetIndex;
    notifyListeners();
  }

  /// Swap patterns at [index1] and [index2]. Names travel with their data —
  /// no renaming — since a swap is purely a position exchange, not a
  /// creation of new pattern identities.
  void swapPatterns(int index1, int index2) {
    if (index1 == index2) return;
    if (index1 < 0 || index1 >= kMaxSongPatterns) return;
    if (index2 < 0 || index2 >= kMaxSongPatterns) return;
    _ensurePatternSlot(index1 > index2 ? index1 : index2);
    _pushSongUndo('swap patterns');

    final temp = song.patterns[index1];
    song.patterns[index1] = song.patterns[index2];
    song.patterns[index2] = temp;

    _currentPatternIndex = index2;
    _currentArrangementSlotIndex = index2;
    notifyListeners();
  }

  /// Focus pattern slot [index], backing it with a real (empty) pattern
  /// object first if it hasn't been touched yet. Every one of the 99 song
  /// slots is always either empty or has data — there is no separate
  /// "create" action for the user; this just lazily backs the slot.
  void createPatternAt(int index) {
    if (index < 0 || index >= kMaxSongPatterns) return;
    _ensurePatternSlot(index);
    _currentPatternIndex = index;
    _currentArrangementSlotIndex = index;
    notifyListeners();
  }

  /// Clears pattern [index]'s data, turning it into an empty pattern in
  /// place. The slot itself is never removed — other patterns keep their
  /// indices, and the arrangement length never shrinks.
  void removePattern(int index) {
    if (index < 0 || index >= song.patterns.length) return;
    _pushSongUndo('delete pattern');
    final oldName = song.patterns[index].name;
    final empty = song.createEmptyPattern().copyWithName(oldName);
    _copyProjectMixerStateToPattern(empty);
    _copyProjectSendRoutingToPattern(empty);
    song.patterns[index] = empty;
    _currentPatternIndex = _currentPatternIndex.clamp(
      0,
      song.patterns.length - 1,
    );
    _currentArrangementSlotIndex = _currentArrangementSlotIndex.clamp(
      0,
      song.patterns.length - 1,
    );
    notifyListeners();
  }

  /// Insert a brand-new empty pattern at slot [index]+1, shifting the DATA
  /// held by [index]+1 through slot 98 down by one position each.
  ///
  /// Slot numbers (1–99) are permanent — they are positions in the fixed
  /// arrangement grid and never move, get renamed, or get renumbered. Only
  /// the pattern data each slot holds moves. This is why the shift below
  /// assigns into existing slots in place rather than calling
  /// `List.insert`/`removeAt`, which would grow/shrink the list itself —
  /// the arrangement is always exactly [kMaxSongPatterns] slots.
  ///
  /// After shifting, all affected patterns are renamed so their internal
  /// names (PAT 01, PAT 02, etc.) always match their slot positions.
  ///
  /// Returns false (no mutation) if [index] is out of range, or if slot 99
  /// already holds real (non-empty) data — shifting would push it off the
  /// end of the arrangement and destroy it, so this refuses rather than
  /// silently losing a pattern.
  bool insertEmptyPatternAfter(int index) {
    if (index < 0 || index >= song.patterns.length) return false;
    // Back every slot through the last one with a real object so the shift
    // loop below can move data through all of them — this only lazily
    // fills already-existing (but not yet touched) slots; it never adds
    // slots beyond the fixed 99-slot arrangement.
    _ensurePatternSlot(kMaxSongPatterns - 1);
    if (!song.patterns[kMaxSongPatterns - 1].isEmpty) return false;
    _pushSongUndo('insert pattern');
    // Shift data from index+1..98 down to index+2..99.
    for (int i = kMaxSongPatterns - 1; i > index + 1; i--) {
      song.patterns[i] = song.patterns[i - 1];
    }
    // Create empty pattern at the insertion point.
    final pattern = song.createEmptyPattern();
    _copyProjectMixerStateToPattern(pattern);
    _copyProjectSendRoutingToPattern(pattern);
    song.patterns[index + 1] = pattern;
    // Rename all shifted patterns (index+1..99) to match their new slot positions.
    // This ensures pattern internal names (PAT 01, PAT 02, ...) always equal
    // their slot numbers, never drift out of sync with where the data actually lives.
    for (int i = index + 1; i < kMaxSongPatterns; i++) {
      final newName = 'PAT ${(i + 1).toString().padLeft(2, '0')}';
      song.patterns[i] = song.patterns[i].copyWithName(newName);
    }
    _currentPatternIndex = (index + 1).clamp(0, song.patterns.length - 1);
    _currentArrangementSlotIndex = _currentPatternIndex;
    notifyListeners();
    return true;
  }

  /// Duplicate the pattern at [index], inserting the copy immediately after
  /// it — same slot-shifting mechanics as [insertEmptyPatternAfter] (data
  /// shifts in place within the fixed 99-slot arrangement, slot numbers
  /// never move).
  ///
  /// The only difference from manually inserting an empty row and then
  /// copy/pasting the source row's cells onto it: this also carries over
  /// the pattern-level settings (BPM, beats, swing, lines-per-beat, beat
  /// overrides, FX envelopes) from the source pattern, since those live on
  /// the pattern object rather than in individual cells.
  ///
  /// Returns false (no mutation) under the same conditions as
  /// [insertEmptyPatternAfter]: out-of-range [index], or slot 99 already
  /// holding real data (shifting would destroy it).
  bool duplicatePatternAfter(int index) {
    if (index < 0 || index >= song.patterns.length) return false;
    _ensurePatternSlot(kMaxSongPatterns - 1);
    if (!song.patterns[kMaxSongPatterns - 1].isEmpty) return false;
    final source = song.patterns[index];
    _pushSongUndo('duplicate pattern');
    // Shift data from index+1..98 down to index+2..99.
    for (int i = kMaxSongPatterns - 1; i > index + 1; i--) {
      song.patterns[i] = song.patterns[i - 1];
    }
    // Deep-copy the source pattern (cells + BPM/beats/swing/lpb/overrides/
    // fx envelopes) into the newly opened slot, named to match its position.
    final destName = 'PAT ${(index + 2).toString().padLeft(2, '0')}';
    song.patterns[index + 1] = source.copyWithName(destName);
    // Rename all shifted patterns (index+2..99) to match their new slot positions.
    for (int i = index + 2; i < kMaxSongPatterns; i++) {
      final newName = 'PAT ${(i + 1).toString().padLeft(2, '0')}';
      song.patterns[i] = song.patterns[i].copyWithName(newName);
    }
    _currentPatternIndex = (index + 1).clamp(0, song.patterns.length - 1);
    _currentArrangementSlotIndex = _currentPatternIndex;
    notifyListeners();
    return true;
  }

  double get masterVolume => song.masterVolume;
  bool get masterMute => song.masterMute;

  void setMasterVolume(double value) {
    // Master can be driven above unity (up to +6 dB) so users can intentionally
    // push the safety limiter for makeup-style gain. Uses the direct float
    // setter so the value isn't quantized to the 0..99 mixer-command grid.
    song.masterVolume = value.clamp(0.0, kMaxMasterVolume);
    AudioEngine.instance.setMasterVolumeLinear(song.masterVolume);
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
    // Empty patterns are non-playable separators — can't jump playback there.
    if (song.patterns[patternIndex].isEmpty) return;
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
    // Drum synth encodes the DRUM PIECE selector here (0=kick, 1=snare,
    // 2=hat, 3=tom, 4=crash) — same convention Sampler uses above.
    if (ins.type == InstrumentType.drumSynth) return ins.drum.piece.index;
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
    if (ins.type == InstrumentType.drumSynth) return 3;
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
        _norm01ToAudio255(sp.hpCutoff), // cutoff  → sampler HP cutoff
        _norm01ToAudio255(sp.hpResonance), // resonance → sampler HP resonance
        // Filter is OFF if in complete bypass state (hpCutoff=0, lpCutoff=1)
        sp.isFilterBypassed ? 0 : 1,
        _norm01ToAudio255(sp.lpCutoff), // filterAtk → sampler LP cutoff
        _norm01ToAudio255(sp.lpResonance), // filterDec → sampler LP resonance
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
        _norm01ToAudio255(sp.loopStart), // loopStart (sampler loop region)
        _norm01ToAudio255(sp.loopEnd), // loopEnd (sampler loop region)
        // ── Sampler LFO (note-synced, BPM-relative) ──────────────────────
        sp.isLfoActive ? sp.lfoWave.index : 0, // LFO waveform (0=off)
        sp.lfoRateIndex, // LFO cycle-length division index
        sp.lfoTargetMask, // LFO target bitmask: 1=vol,2=pitch,4=hp,8=lp
        _norm01ToAudio255(sp.lfoDepth), // LFO depth 0..255
        sp.lfoMode.index, // LFO anchor mode: 0=center,1=up,2=down
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
        _norm01ToAudio255(kp.filterEnvAmt), // famt
        _norm01ToAudio255(kp.ampAttack), // atk
        _norm01ToAudio255(kp.ampDecay), // dec
        _norm01ToAudio255(kp.ampSustain), // sus
        _norm01ToAudio255(kp.ampRelease), // rel
        0, // glide (unused)
        _norm01ToAudio255(kp.volume), // instVol
        _norm01ToAudio255(kp.filterCutoff), // lfoRate reused as filter cutoff
        _norm01ToAudio255(
          kp.filterResonance,
        ), // lfoDepth reused as filter resonance
        kp.filterMode.index2, // lfoTarget reused as filter mode (0/1/2)
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
        0, // loopStart padding (sampler-only, unused for Karplus)
        0, // loopEnd padding (sampler-only, unused for Karplus)
        0, // LFO waveform padding (sampler-only)
        0, // LFO rate index padding (sampler-only)
        0, // LFO target mask padding (sampler-only)
        0, // LFO depth padding (sampler-only)
        0, // LFO mode padding (sampler-only)
      ];
    }
    if (ins.type == InstrumentType.drumSynth) {
      final dp = ins.drum;
      return <int>[
        _norm01ToAudio255(dp.pitch),
        _norm01ToAudio255(dp.pitchDecay),
        _norm01ToAudio255(dp.tone),
        _norm01ToAudio255(dp.cutoff),
        _norm01ToAudio255(dp.resonance),
        _norm01ToAudio255(dp.decay),
        _norm01ToAudio255(dp.punch),
        _norm01ToAudio255(dp.drive),
        0,
        0,
        0,
        0,
        0,
        0,
        _norm01ToAudio255(dp.volume),
        0,
        0,
        0,
        0,
        0,
        // OSC fields — not applicable for Drum Synth, use safe defaults
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
        0, // loopStart padding (sampler-only, unused for Drum Synth)
        0, // loopEnd padding (sampler-only, unused for Drum Synth)
        0, // LFO waveform padding (sampler-only)
        0, // LFO rate index padding (sampler-only)
        0, // LFO target mask padding (sampler-only)
        0, // LFO depth padding (sampler-only)
        0, // LFO mode padding (sampler-only)
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
      0, // loopStart padding (sampler-only, unused for synth)
      0, // loopEnd padding (sampler-only, unused for synth)
      0, // LFO waveform padding (sampler-only)
      0, // LFO rate index padding (sampler-only)
      0, // LFO target mask padding (sampler-only)
      0, // LFO depth padding (sampler-only)
      0, // LFO mode padding (sampler-only)
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
    if (t >= _trackCarry.length) return waveCmd;
    final carry = _trackCarry[t].instrumentParams;
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
          case 8:
            synthParams[1] = _ui99ToAudio255(rawVal); // HP cutoff
          case 9:
            synthParams[2] = _ui99ToAudio255(rawVal); // HP resonance
          case 10:
            synthParams[4] = _ui99ToAudio255(rawVal); // LP cutoff
          case 11:
            synthParams[5] = _ui99ToAudio255(rawVal); // LP resonance
          case 12:
            synthParams[37] = _ui99ToAudio255(rawVal); // loop start
          case 13:
            synthParams[38] = _ui99ToAudio255(rawVal); // loop end
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
          case 9:
            synthParams[14] = _ui99ToAudio255(rawVal); // volume
          case 10:
            synthParams[15] = _ui99ToAudio255(rawVal); // filter cutoff
          case 11:
            synthParams[16] = _ui99ToAudio255(rawVal); // filter resonance
          case 12:
            synthParams[17] = rawVal.clamp(0, 2); // filter mode (direct)
          case 13:
            synthParams[8] = _ui99ToAudio255(rawVal); // filter env amt
          case 14:
            synthParams[9] = _ui99ToAudio255(rawVal); // amp attack
          case 15:
            synthParams[10] = _ui99ToAudio255(rawVal); // amp decay
          case 16:
            synthParams[11] = _ui99ToAudio255(rawVal); // amp sustain
          case 17:
            synthParams[12] = _ui99ToAudio255(rawVal); // amp release
        }
      } else if (instrumentType == InstrumentType.drumSynth) {
        switch (paramIdx) {
          case 1:
            synthParams[0] = _ui99ToAudio255(rawVal); // pitch
          case 2:
            synthParams[1] = _ui99ToAudio255(rawVal); // pitch decay
          case 3:
            synthParams[2] = _ui99ToAudio255(rawVal); // tone
          case 4:
            synthParams[3] = _ui99ToAudio255(rawVal); // cutoff
          case 5:
            synthParams[4] = _ui99ToAudio255(rawVal); // resonance
          case 6:
            synthParams[5] = _ui99ToAudio255(rawVal); // decay
          case 7:
            synthParams[6] = _ui99ToAudio255(rawVal); // punch
          case 8:
            synthParams[7] = _ui99ToAudio255(rawVal); // drive
          case 9:
            synthParams[14] = _ui99ToAudio255(rawVal); // volume
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
          case 14:
            synthParams[22] = rawVal.clamp(
              0,
              5,
            ); // osc2Wave (direct enum index)
          case 15:
            synthParams[23] = _ui99ToAudio255(rawVal); // osc2Detune
          case 16:
            synthParams[24] = _ui99ToAudio255(rawVal); // osc2Gain
          case 17:
            synthParams[29] = _ui99ToAudio255(rawVal); // osc2FmDepth
          case 18:
            synthParams[26] = rawVal.clamp(
              0,
              5,
            ); // osc3Wave (direct enum index)
          case 19:
            synthParams[27] = _ui99ToAudio255(rawVal); // osc3Detune
          case 20:
            synthParams[28] = _ui99ToAudio255(rawVal); // osc3Gain
          case 21:
            synthParams[30] = _ui99ToAudio255(rawVal); // osc3FmDepth
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
    _trackCarry = const [];
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

    // Honour row selection as start / loop boundary for pattern playback.
    final selRange = selectedRowRange;
    if (selRange != null) {
      playheadRow = selRange.$1;
      _playbackStartRow = selRange.$1;
      _playbackEndRow = selRange.$2;
    } else {
      _playbackStartRow = playheadRow;
      _playbackEndRow = rowCount - 1;
    }
    await _loadNativePatternPlaybackQueue(
      startRow: _playbackStartRow,
      endRow: _playbackEndRow,
    );
    await AudioEngine.instance.start();
    _startNativePatternPlayheadPoller();
    notifyListeners();
  }

  void toggleFollowPlayhead() {
    _followPlayhead = !_followPlayhead;
    notifyListeners();
  }

  void setLoopPlaybackEnabled(bool enabled) {
    if (_loopPlaybackEnabled == enabled) return;
    _loopPlaybackEnabled = enabled;
    if (isPlaying && !_playbackFollowsSong) {
      // Sync the native looping flag immediately so the engine stops/continues
      // at the current pass boundary without waiting for the next poll.
      unawaited(AudioEngine.instance.setQueuedPlaybackLooping(enabled));
      if (!enabled) _nextPassScheduled = false;
    }
    notifyListeners();
  }

  /// Finds the start slot of the cluster containing [slotIdx].
  /// A cluster is a contiguous block of non-empty patterns separated by empty patterns.
  /// Returns the slot index of the first pattern in the cluster.
  int _findClusterStartSlot(int slotIdx) {
    if (song.patterns.isEmpty) return 0;
    slotIdx = slotIdx.clamp(0, song.patterns.length - 1);

    // Scan backwards to find the first empty pattern (cluster boundary).
    for (int i = slotIdx - 1; i >= 0; i--) {
      if (song.patterns[i].isEmpty) {
        // Found boundary; cluster starts at i+1
        return i + 1;
      }
    }

    // No empty pattern found above; cluster starts at 0
    return 0;
  }

  Future<void> _restartSongFromBeginningForLoop({
    int clusterStartSlot = 0,
  }) async {
    if (!isPlaying || !_playbackFollowsSong || song.patterns.isEmpty) return;

    // Clamp to valid range
    clusterStartSlot = clusterStartSlot.clamp(0, song.patterns.length - 1);

    _queuedArrangementSlot = null;
    _playheadArrangementSlot = clusterStartSlot;
    _currentArrangementSlotIndex = clusterStartSlot;
    _syncCurrentPatternToSongPlayhead();
    playheadRow = 0;
    _songRowMap = [];
    _songFlatRowIndex = 0;
    _resetInstrumentCarry();
    _captureStartStates();
    await _loadNativeSongPlaybackQueue(
      startSlot: clusterStartSlot,
      startRow: 0,
    );
    if (!isPlaying) return;
    await AudioEngine.instance.start();
    notifyListeners();
  }

  /// Stops the transport (sequencer). By default this fully silences all
  /// voices immediately (explicit user Stop). Pass [keepVoicesRinging] when
  /// stopping because playback simply reached its natural end (non-looped
  /// pattern or song) so that any notes still sounding keep ringing across
  /// the boundary instead of being cut off with a click — the user can end
  /// them with an explicit OFF command if desired.
  void stop({bool keepVoicesRinging = false}) {
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
    if (keepVoicesRinging) {
      AudioEngine.instance.stopTransportSoft();
    } else {
      AudioEngine.instance.stop();
    }
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

  /// Renders the current pattern (or current row selection if one exists) to
  /// a stereo WAV file in the project samples folder, then loads it into the
  /// first empty instrument slot as a sampler.
  ///
  /// Respects whatever is currently soloed/muted — the output is exactly
  /// what the engine would play if you pressed Play right now.
  ///
  /// Returns null on success, or a human-readable error string on failure.
  Future<String?> freezePatternToSampler() async {
    if (isPlaying) return 'Stop playback before freezing';
    if (song.patterns.isEmpty) return 'No pattern to freeze';

    final nextEmpty = instruments.indexWhere(
      (ins) => ins.type == InstrumentType.empty,
    );
    if (nextEmpty < 0) return 'No empty instrument slots available';

    // Honour selection; fall back to the full pattern.
    final selRange = selectedRowRange;
    final startRow = selRange?.$1 ?? 0;
    final endRow = selRange?.$2 ?? (rowCount - 1);

    // Save and override playback state for the capture pass.
    final wasFollowing = _playbackFollowsSong;
    final wasLooping = _loopPlaybackEnabled;
    _playbackFollowsSong = false;
    _loopPlaybackEnabled = false;
    _playbackStartRow = startRow;
    _playbackEndRow = endRow;
    playheadRow = startRow;

    await AudioEngine.instance.startExportTap();

    _exportCompleter = Completer<void>();
    final done = _exportCompleter!.future;

    _resetInstrumentCarry();
    _captureStartStates();
    isPlaying = true;
    await _loadNativePatternPlaybackQueue(startRow: startRow, endRow: endRow);
    await AudioEngine.instance.start();
    _startNativePatternPlayheadPoller();
    notifyListeners();

    // The pattern poller calls stop() at end-of-pass; stop() completes the future.
    await done;

    final tap = await AudioEngine.instance.stopExportTap();

    // Restore playback preferences.
    _playbackFollowsSong = wasFollowing;
    _loopPlaybackEnabled = wasLooping;

    if (tap.samples.isEmpty) return 'No audio captured';

    final wavBytes = WavEncoder.encodeWav(
      samples: tap.samples,
      sampleRate: tap.sampleRate,
      numChannels: 2,
    );

    // Build a unique filename based on the pattern name.
    final rawName = currentPattern.name.trim();
    final stem = _sanitizeFileStem(
      rawName.isNotEmpty ? rawName : 'pattern${_currentPatternIndex + 1}',
    );
    final lib = await _songSamplesDir();
    int n = 1;
    String candidate;
    do {
      candidate = n == 1 ? '${stem}_freeze.wav' : '${stem}_freeze_$n.wav';
      n++;
    } while (File('${lib.path}/$candidate').existsSync());

    final outPath = '${lib.path}/$candidate';
    await File(outPath).writeAsBytes(wavBytes, flush: true);

    // Configure the destination instrument slot.
    final destIns = instruments[nextEmpty];
    destIns.type = InstrumentType.sampler;
    destIns.sampler
      ..samplePath = outPath
      ..sampleName = candidate
      ..pitch = 0
      ..volume = 1.0
      ..loopMode = SamplerLoopMode.off
      ..start = 0.0
      ..end = 1.0
      ..attack = 0.0
      ..release = 0.05;

    await AudioEngine.instance.setSamplerSample(nextEmpty, outPath);

    selectInstrument(nextEmpty);
    notifyListeners();
    return null; // success
  }

  void toggleRecord() {
    isRecording = !isRecording;
    notifyListeners();
  }

  void setBpm(double value) {
    _pushPatternUndo('bpm');
    final clamped = value.round().clamp(20, 300);
    currentPattern.bpm = clamped.toDouble();
    _restartPlayheadTimerIfNeeded();
    notifyListeners();
  }

  void setBeats(int value) {
    final minBeats = _minimumBeatsForExistingData();
    final clamped = value.clamp(minBeats, 99);
    _pushPatternUndo('beats');
    currentPattern.beats = clamped;
    currentPattern.syncTrackLengths();
    _clampSelectionToPattern();
    _restartPlayheadTimerIfNeeded();
    notifyListeners();
  }

  void setLinesPerBeat(int value) {
    if (!canChangePatternLength) return;
    _pushPatternUndo('lpb');
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
    _pushPatternUndo('beat length');
    currentPattern.setBeatLineOverride(beat, lines);
    currentPattern.syncTrackLengths();
    _clampSelectionToPattern();
    _restartPlayheadTimerIfNeeded();
    notifyListeners();
  }

  /// Swing for the current pattern (0.0 = straight, 1.0–99.0 = percentage).
  double get currentPatternSwing => currentPattern.swing;

  void setPatternSwing(double value) {
    final clamped = value.clamp(0.0, 99.0);
    if (clamped == currentPattern.swing) return;
    _pushPatternUndo('swing');
    currentPattern.swing = clamped;
    _restartPlayheadTimerIfNeeded();
    notifyListeners();
  }

  /// Copy the current pattern's BPM to all other patterns.
  void copyCurrentBpmToAllPatterns() {
    final bpmToCopy = currentPattern.bpm ?? 120.0;
    for (final pattern in song.patterns) {
      pattern.bpm = bpmToCopy;
    }
    _restartPlayheadTimerIfNeeded();
    notifyListeners();
  }

  /// Copy the current pattern's Swing to all other patterns.
  void copyCurrentSwingToAllPatterns() {
    final swingToCopy = currentPattern.swing;
    for (final pattern in song.patterns) {
      pattern.swing = swingToCopy;
    }
    _restartPlayheadTimerIfNeeded();
    notifyListeners();
  }

  // ── Pattern undo / redo / clear / reset ───────────────────────────────────

  /// True when the current pattern has at least one undoable edit on its stack.
  bool get canUndoPattern => _patternUndo[currentPattern]?.canUndo ?? false;
  bool get canRedoPattern => _patternUndo[currentPattern]?.canRedo ?? false;
  String? get undoPatternLabel => _patternUndo[currentPattern]?.undoLabel;
  String? get redoPatternLabel => _patternUndo[currentPattern]?.redoLabel;

  /// Snapshot the current pattern BEFORE a mutation, coalescing nested calls
  /// inside one user gesture into a single history entry. No-op while a
  /// mutation is already in progress (resets on next microtask).
  void _pushPatternUndo(String label) => _pushUndoFor(currentPattern, label);

  void _pushUndoFor(PatternModel p, String label) {
    if (_patternMutationInProgress) return;
    _patternMutationInProgress = true;
    scheduleMicrotask(() => _patternMutationInProgress = false);
    final stack = _patternUndo[p] ??= _PatternUndoStack();
    stack.pushUndo(jsonEncode(p.toJson()), label);
  }

  /// Restore musical content (cells, beats, lpb, beat overrides, fx envelopes,
  /// bpm) from a previously-captured JSON snapshot. Mixer fields and track
  /// metadata stay untouched on purpose — undoing a note edit should not flip
  /// a solo button you toggled in between.
  void _restorePatternFromJson(PatternModel target, String json) {
    final j = jsonDecode(json) as Map<String, dynamic>;
    final loaded = PatternModel.fromJson(j);
    target.bpm = loaded.bpm;
    target.beats = loaded.beats;
    target.linesPerBeat = loaded.linesPerBeat;
    target.beatLineOverrides
      ..clear()
      ..addAll(loaded.beatLineOverrides);
    target.fxEnvelopes
      ..clear()
      ..addAll(loaded.fxEnvelopes);
    // Replace cells on each existing track (do NOT touch mixer fields).
    final n = math.min(target.tracks.length, loaded.tracks.length);
    for (int t = 0; t < n; t++) {
      target.tracks[t].cells
        ..clear()
        ..addAll(loaded.tracks[t].cells);
    }
    target.syncTrackLengths();
  }

  /// Undo the most recent edit on the current pattern. Safe to call when the
  /// stack is empty.
  void undoCurrentPattern() {
    final p = currentPattern;
    final stack = _patternUndo[p];
    if (stack == null || !stack.canUndo) return;
    final currentJson = jsonEncode(p.toJson());
    final entry = stack.popUndoSwap(currentJson);
    if (entry == null) return;
    _restorePatternFromJson(p, entry.json);
    _clampSelectionToPattern();
    _restartPlayheadTimerIfNeeded();
    notifyListeners();
  }

  /// Redo the most recently undone edit on the current pattern.
  void redoCurrentPattern() {
    final p = currentPattern;
    final stack = _patternUndo[p];
    if (stack == null || !stack.canRedo) return;
    final currentJson = jsonEncode(p.toJson());
    final entry = stack.popRedoSwap(currentJson);
    if (entry == null) return;
    _restorePatternFromJson(p, entry.json);
    _clampSelectionToPattern();
    _restartPlayheadTimerIfNeeded();
    notifyListeners();
  }

  // ── Song arrangement undo / redo ──────────────────────────────────────────

  bool get canUndoSong => _songUndo.canUndo;
  bool get canRedoSong => _songUndo.canRedo;
  String? get undoSongLabel => _songUndo.undoLabel;
  String? get redoSongLabel => _songUndo.redoLabel;

  /// Serialize the current arrangement to JSON: the patterns list plus the
  /// insert-FX rack (params + slot occupancy + effect names). The rack is
  /// included because full-track paste/swap/move can change it, and an
  /// undo/redo of those operations needs to restore it along with the data.
  String _songArrangementJson() => jsonEncode({
    'patterns': song.patterns.map((p) => p.toJson()).toList(),
    'inserts': _insertSnapshot,
    'trackInsertOccupied': _trackInsertOccupied,
    'trackInsertEffectNames': _trackInsertEffectNames,
  });

  /// Snapshot the arrangement BEFORE a mutation. Pass [label] for the action.
  /// No-op if a compound operation is already in progress.
  void _pushSongUndo(String label) {
    if (_songMutationInProgress) return;
    _songUndo.pushUndo(_songArrangementJson(), label);
  }

  /// Replace song.patterns and the insert-FX rack with the state encoded in
  /// [json], clamp indices, and re-sync the native engine's insert slots
  /// (cleared first, since the restored rack may have fewer/more active
  /// effects than what's currently loaded).
  void _restoreArrangementFromJson(String json) {
    final raw = jsonDecode(json) as Map<String, dynamic>;
    final patternsRaw = raw['patterns'] as List<dynamic>;
    song.patterns = patternsRaw
        .map((j) => PatternModel.fromJson(j as Map<String, dynamic>))
        .toList();
    if (song.patterns.isEmpty) song.patterns = [PatternModel(name: 'PAT 01')];
    _currentPatternIndex = _currentPatternIndex.clamp(
      0,
      song.patterns.length - 1,
    );
    _currentArrangementSlotIndex = _currentArrangementSlotIndex.clamp(
      0,
      song.patterns.length - 1,
    );

    _insertSnapshot = (raw['inserts'] as Map<String, dynamic>?) ?? {};
    _trackInsertOccupied
      ..clear()
      ..addAll(
        ((raw['trackInsertOccupied'] as List<dynamic>?) ?? []).map(
          (row) => (row as List<dynamic>).map((b) => b as bool).toList(),
        ),
      );
    _trackInsertEffectNames
      ..clear()
      ..addAll(
        ((raw['trackInsertEffectNames'] as List<dynamic>?) ?? []).map(
          (row) => (row as List<dynamic>).map((n) => n as String?).toList(),
        ),
      );
    unawaited(
      _clearInsertEffectsInEngine().then((_) => _applyInsertSnapshotToEngine()),
    );
  }

  /// Undo the most recent arrangement mutation (add/remove/move/duplicate…).
  void undoSong() {
    if (!_songUndo.canUndo) return;
    final entry = _songUndo.popUndoSwap(_songArrangementJson());
    if (entry == null) return;
    _restoreArrangementFromJson(entry.json);
    // Mixer fields (volume/pan/mute/solo/send) may have changed as part of
    // the restored arrangement (e.g. full-track swap/move) — re-sync the
    // native audio engine so live playback matches immediately.
    _queueCurrentMixerSnapshotToEngine();
    notifyListeners();
  }

  /// Redo the most recently undone arrangement mutation.
  void redoSong() {
    if (!_songUndo.canRedo) return;
    final entry = _songUndo.popRedoSwap(_songArrangementJson());
    if (entry == null) return;
    _restoreArrangementFromJson(entry.json);
    _queueCurrentMixerSnapshotToEngine();
    notifyListeners();
  }

  /// Wipe every cell on every track in the current pattern. Leaves beats /
  /// LPB / per-beat overrides / mixer settings / fx envelopes alone.
  void clearCurrentPatternCells() {
    _pushPatternUndo('clear pattern');
    final p = currentPattern;
    for (final t in p.tracks) {
      for (int r = 0; r < t.cells.length; r++) {
        t.cells[r] = TrackerCell.empty();
      }
    }
    _clampSelectionToPattern();
    notifyListeners();
  }

  /// Wipe cells AND reset bpm / beats / lpb / per-beat overrides / fx
  /// envelopes to defaults. Mixer settings on the tracks stay untouched.
  void resetCurrentPatternToDefaults() {
    _pushPatternUndo('reset pattern');
    final p = currentPattern;
    p.bpm = 120.0;
    p.beats = kDefaultBeats;
    p.linesPerBeat = kDefaultLinesPerBeat;
    p.beatLineOverrides
      ..clear()
      ..addAll(List<int?>.filled(kDefaultBeats, null, growable: true));
    p.fxEnvelopes.clear();
    p.syncTrackLengths();
    for (final t in p.tracks) {
      for (int r = 0; r < t.cells.length; r++) {
        t.cells[r] = TrackerCell.empty();
      }
    }
    _clampSelectionToPattern();
    _restartPlayheadTimerIfNeeded();
    notifyListeners();
  }

  /// Duration of one line for a specific row, respecting per-beat overrides.
  /// Uses [bpm] rather than reading pattern.bpm directly so BPM FX tempo
  /// nudges (see _bpmFxEffective) can override the pattern's base tempo for
  /// this row without mutating the stored pattern snapshot.
  Duration _lineDurationForPatternRow(PatternModel pattern, int row, double bpm) {
    final beat = pattern.beatForRow(row);
    final lpbForBeat = pattern.linesForBeat(beat);
    final microsPerLine = (60000000 / (bpm * lpbForBeat))
        .round()
        .clamp(1000, 60000000);
    return Duration(microseconds: microsPerLine);
  }


  /// Builds the scheduled row list for the current pattern from [startRow].
  /// Pure Dart computation — no channel calls and no song mutation, so we
  /// just save/restore the playhead + carry state instead of deep-cloning the
  /// whole song on every loop boundary (was ~5–20 ms of GC pressure per pass).
  List<_ScheduledPlaybackRow> _buildScheduledRows({
    int startRow = 0,
    int? endRow,
    // When true, and the existing carry state already matches the current
    // pattern, this build continues from the live carry state instead of
    // resetting it — used when pre-building the next loop pass so notes
    // held/ringing across the loop boundary aren't corrupted back to
    // default-instrument data on a hold row at the top of the range.
    bool continueCarry = false,
  }) {
    final originalPlayheadRow = playheadRow;
    final pattern = song.patterns[_currentPatternIndex];
    final safeStart = startRow.clamp(0, pattern.rowCount - 1);
    final safeEnd = (endRow ?? pattern.rowCount - 1).clamp(
      safeStart,
      pattern.rowCount - 1,
    );
    final scheduledRows = <_ScheduledPlaybackRow>[];

    final canContinueCarry = continueCarry &&
        _carryPatternIndex == _currentPatternIndex &&
        _trackCarry.length == pattern.tracks.length;
    if (canContinueCarry) {
      _suppressCarryResetAtRowZero = true;
    } else {
      _resetInstrumentCarry();
      // Dry-run rows before the range so instrument carry state is correct.
      for (int row = 0; row < safeStart; row++) {
        playheadRow = row;
        _triggerCurrentRow();
      }
    }
    // Schedule exactly the requested range (no wrapping).
    for (int row = safeStart; row <= safeEnd; row++) {
      playheadRow = row;
      scheduledRows.add(_triggerCurrentRow());
    }

    playheadRow = originalPlayheadRow;
    if (canContinueCarry) {
      _suppressCarryResetAtRowZero = false;
    } else {
      _resetInstrumentCarry();
    }
    return scheduledRows;
  }

  Future<void> _loadNativePatternPlaybackQueue({
    required int startRow,
    int? endRow,
  }) async {
    final scheduledRows = _buildScheduledRows(
      startRow: startRow,
      endRow: endRow,
    );
    _nextPassScheduled = false;
    // Update send routing based on carry state from row building.
    final sendRouting = _buildStaticSendRouting();
    await AudioEngine.instance.setSendRouting(sendRouting);
    await AudioEngine.instance.enqueueAllPlaybackRows(
      loop: _loopPlaybackEnabled,
      rows: scheduledRows
          .map(
            (r) => {
              'lineSamples': r.lineSamples,
              'rowData': r.rowData,
              'immediateKillMask': r.immediateKillMask,
              'retrigData': r.retrigData,
              'arpData': r.arpData,
              'delayData': r.delayData,
              'killData': r.killData,
              'sliceCommandData': r.sliceCommandData,
              'mixerCommandData': r.mixerCommandData,
              'insertFxCommandData': r.insertFxCommandData,
              'pitchRampData': r.pitchRampData,
              'sendRoutingCommandData': r.sendRoutingCommandData,
            },
          )
          .toList(),
    );
  }

  /// Pre-builds the next loop pass from the live pattern and loads it into
  /// the C++ pending buffer. At the next native loop boundary the engine
  /// swaps it in atomically — zero gap, edits picked up every pass.
  Future<void> _scheduleNextLoopPass() async {
    final rows = _buildScheduledRows(
      startRow: _playbackStartRow,
      endRow: _playbackEndRow,
      continueCarry: true,
    );
    // Update send routing based on carry state from row building.
    final sendRouting = _buildStaticSendRouting();
    await AudioEngine.instance.setSendRouting(sendRouting);
    await AudioEngine.instance.scheduleNextLoopRows(
      rows
          .map(
            (r) => {
              'lineSamples': r.lineSamples,
              'rowData': r.rowData,
              'immediateKillMask': r.immediateKillMask,
              'retrigData': r.retrigData,
              'arpData': r.arpData,
              'delayData': r.delayData,
              'killData': r.killData,
              'sliceCommandData': r.sliceCommandData,
              'mixerCommandData': r.mixerCommandData,
              'insertFxCommandData': r.insertFxCommandData,
              'pitchRampData': r.pitchRampData,
              'sendRoutingCommandData': r.sendRoutingCommandData,
            },
          )
          .toList(),
    );
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
      // Track position within the locked-in playback range.
      final selLen = _playbackEndRow - _playbackStartRow + 1;
      final relPos = playheadRow - _playbackStartRow;
      final newRelRaw = relPos + advanced;
      final didLoop = newRelRaw >= selLen;
      playheadRow = _playbackStartRow + (newRelRaw % selLen);
      if (didLoop) {
        if (!_loopPlaybackEnabled) {
          // Pattern reached its natural end with looping off — halt the
          // sequencer but let any currently-sounding notes ring out rather
          // than cutting them off abruptly.
          stop(keepVoicesRinging: true);
          return;
        }
        // Loop happened: the C++ engine already swapped in the pending pass
        // (or replayed old rows if no pending pass was ready). Reset the flag
        // so we pre-build and schedule the *next* pass immediately.
        _nextPassScheduled = false;
      }
      // Pre-build the next pass when we are 2 rows from the end of the
      // current pass — enough lead time for the single channel call to
      // complete before the native loop boundary.
      // Guard: skip for ranges of ≤ 2 rows (timing too tight; engine re-uses
      // its buffer until the next scheduled pass lands).
      if (_loopPlaybackEnabled &&
          !_nextPassScheduled &&
          selLen > 2 &&
          playheadRow >= _playbackEndRow - 1) {
        _nextPassScheduled = true;
        unawaited(_scheduleNextLoopPass());
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

    final originalPlayheadRow = playheadRow;
    final originalPlayheadSlot = _playheadArrangementSlot;

    final rowMap = <({int arrangementSlot, int rowWithinSlot})>[];
    final scheduledRows = <_ScheduledPlaybackRow>[];

    // No song clone needed — _triggerCurrentRow is pure w.r.t. song data.
    _resetInstrumentCarry();

    // Build carry state by simulating rows before the start position.
    for (
      int slotIdx = 0;
      slotIdx < startSlot && slotIdx < song.patterns.length;
      slotIdx++
    ) {
      final pat = song.patterns[slotIdx];
      if (pat.isEmpty) break;
      for (int row = 0; row < pat.rowCount; row++) {
        _playheadArrangementSlot = slotIdx;
        playheadRow = row;
        _triggerCurrentRow();
      }
    }
    if (startSlot < song.patterns.length) {
      final pat = song.patterns[startSlot];
      final safeStart = startRow.clamp(0, pat.rowCount - 1);
      for (int row = 0; row < safeStart; row++) {
        _playheadArrangementSlot = startSlot;
        playheadRow = row;
        _triggerCurrentRow();
      }
    }

    // Enqueue rows from (startSlot, startRow) to end of song.
    for (int slotIdx = startSlot; slotIdx < song.patterns.length; slotIdx++) {
      final pat = song.patterns[slotIdx];
      // Empty patterns are non-playable separators — never play through
      // one, even if it's the requested start slot.
      if (pat.isEmpty) break;
      final firstRow = (slotIdx == startSlot)
          ? startRow.clamp(0, pat.rowCount - 1)
          : 0;
      for (int row = firstRow; row < pat.rowCount; row++) {
        _playheadArrangementSlot = slotIdx;
        playheadRow = row;
        rowMap.add((arrangementSlot: slotIdx, rowWithinSlot: row));
        scheduledRows.add(_triggerCurrentRow());
      }
      if (slotIdx + 1 >= song.patterns.length ||
          song.patterns[slotIdx + 1].isEmpty) {
        break;
      }
    }

    // Restore state.
    playheadRow = originalPlayheadRow;
    _playheadArrangementSlot = originalPlayheadSlot;
    // Capture send routing from carry state before it's wiped below.
    final sendRouting = _buildStaticSendRouting();
    _resetInstrumentCarry();

    await AudioEngine.instance.setSendRouting(sendRouting);
    // Upload to native — all rows in one channel call to avoid per-row
    // Dart→Kotlin→JNI overhead that caused multi-second play latency.
    await AudioEngine.instance.enqueueAllPlaybackRows(
      loop: false,
      rows: scheduledRows
          .map(
            (r) => {
              'lineSamples': r.lineSamples,
              'rowData': r.rowData,
              'immediateKillMask': r.immediateKillMask,
              'retrigData': r.retrigData,
              'arpData': r.arpData,
              'delayData': r.delayData,
              'killData': r.killData,
              'sliceCommandData': r.sliceCommandData,
              'mixerCommandData': r.mixerCommandData,
              'insertFxCommandData': r.insertFxCommandData,
              'pitchRampData': r.pitchRampData,
              'sendRoutingCommandData': r.sendRoutingCommandData,
            },
          )
          .toList(),
    );

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

      // Song exhausted (end of the current cluster — the queue only ever
      // covers one cluster since it stops at the first empty pattern).
      if (_songFlatRowIndex >= _songRowMap.length) {
        // A queued cross-cluster jump takes priority over looping/stopping —
        // this is how performance-mode jumps between clusters get applied.
        final queuedAtEnd = _queuedArrangementSlot;
        if (queuedAtEnd != null) {
          _queuedArrangementSlot = null;
          await _rebuildNativeSongQueueFromSlot(queuedAtEnd);
          return; // _rebuildNativeSongQueueFromSlot calls notifyListeners
        }
        if (_loopPlaybackEnabled) {
          // Loop back to the start of the current cluster (bounded by empty patterns)
          final clusterStart = _findClusterStartSlot(_playheadArrangementSlot);
          await _restartSongFromBeginningForLoop(
            clusterStartSlot: clusterStart,
          );
          return;
        }
        // Song/cluster reached its natural end with looping off — halt the
        // sequencer but let any currently-sounding notes ring out rather
        // than cutting them off abruptly.
        stop(keepVoicesRinging: true);
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
      _loadNativePatternPlaybackQueue(
        startRow: playheadRow,
        endRow: _playbackEndRow,
      ).then((_) {
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
    _sendRoutingCarryWasReset = false;

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
        _trackCarry.length != pattern.tracks.length ||
        (playheadRow == 0 && !_suppressCarryResetAtRowZero)) {
      _carryPatternIndex = patternIdx;
      _trackCarry = List<_TrackCarry>.generate(
        pattern.tracks.length,
        (_) => _TrackCarry(),
      );
      _sendRoutingCarryWasReset = true;
    }

    // BPM FX: reset the running effective tempo to this pattern's own
    // snapshot BPM whenever we (re)enter the pattern at row 0, or when the
    // pattern being played has changed. Unconditional on purpose — tempo
    // must snap back every loop pass even when note carry is preserved.
    if (_bpmFxPatternIndex != patternIdx || playheadRow == 0) {
      _bpmFxPatternIndex = patternIdx;
      _bpmFxEffective = pattern.bpm ?? 120.0;
    }

    // SWN FX: same reset policy as BPM FX above, but for pattern swing.
    if (_swnFxPatternIndex != patternIdx || playheadRow == 0) {
      _swnFxPatternIndex = patternIdx;
      _swnFxEffective = pattern.swing;
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
    // Pending aux-send changes from SN1/SN2/SN3: [trackIdx, destChannel, percent, ...]
    // destChannel 0 = no send. This is a PARALLEL percentage send — the track's
    // normal output (to master, or its own static reroute) is unaffected;
    // this just adds an extra `percent`% copy into the destination channel's
    // bus. Row-accurate — applied at row start on the native side.
    final List<int> sendRoutingCommandQueue = [];
    if (_sendRoutingCarryWasReset) {
      for (int i = 0; i < pattern.tracks.length; i++) {
        sendRoutingCommandQueue.add(i);
        sendRoutingCommandQueue.add(0);
        sendRoutingCommandQueue.add(0);
      }
    }
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
    // BPM FX is a pattern-global effect (not per-track). Only the first
    // track (lowest index) carrying it on this row takes effect.
    bool bpmFxAppliedThisRow = false;
    // SWN FX: same pattern-global, first-track-wins policy as BPM FX.
    bool swnFxAppliedThisRow = false;
    for (int t = 0; t < pattern.tracks.length; t++) {
      final track = pattern.tracks[t];
      var currentSlot = _trackCarry[t].instrument;
      int noteCmd = -1;
      int volCmd = (_trackCarry.length > t && _trackCarry[t].volFx != null)
          ? _trackCarry[t].volFx!
          : (track.mixerVolume.clamp(0.0, 1.0) * 255).round();
      int panCmd = (_trackCarry.length > t && _trackCarry[t].panFx != null)
          ? _trackCarry[t].panFx!
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
      double? vibSpeedNorm = _trackCarry.length > t
          ? _trackCarry[t].vibSpeed
          : null;
      double? vibDepthNorm = _trackCarry.length > t
          ? _trackCarry[t].vibDepth
          : null;
      double? treSpeedNorm = _trackCarry.length > t
          ? _trackCarry[t].treSpeed
          : null;
      double? treDepthNorm = _trackCarry.length > t
          ? _trackCarry[t].treDepth
          : null;
      int? treMode = _trackCarry.length > t ? _trackCarry[t].treMode : null;
      int retrigVolumeMode = 0;
      int retrigNotesPerLine = 0;
      int arpInterval1 = -1;
      int arpInterval2 = -1;
      int arcMode = 0; // 1-3=linear, 4-6=bidirectional, 7-9=random
      int arcOctaveLayers = 0;
      int arcNotesPerLine = 0;
      int? chancePct;
      // SLU/SLD: set when slide FX is found on a note row this tick.
      ({int endNote, int totalLines})? pendingSlide;

      if (playheadRow < track.cells.length) {
        final cell = track.cells[playheadRow];

        if (cell.instrument != null && cell.instrument! > 0) {
          // Explicit instrument 01-99: switch slot and update carry.
          currentSlot = (cell.instrument! - 1).clamp(0, instruments.length - 1);
          _trackCarry[t].instrument = currentSlot;
          waveCmd = _waveCodeForInstrumentSlot(currentSlot);
          instrumentTypeCmd = _instrumentTypeCodeForSlot(currentSlot);
          synthParams = _synthParamsForInstrumentSlot(currentSlot);
        }
        // instrument == null or 0 ('00'): carry forward last slot.
        // '00' is reserved for future use.

        final note = cell.note;
        if (note.isOff) {
          noteCmd = -2;
        } else if (note.isNote &&
            cell.instrument != null &&
            cell.instrument! > 0) {
          // Explicit instrument (01-99): full note trigger.
          noteCmd = note.midiNote;
        } else if (note.isNote && cell.instrument == 0) {
          // IN = '00': pitch-change only — no retrigger, glide is respected.
          noteCmd = pitchOnlyNoteCmd(note.midiNote);
        }

        if (noteCmd == -2) {
          // Note-off clears per-note FX carries for this track.
          _trackCarry[t].vibSpeed = null;
          _trackCarry[t].vibDepth = null;
          _trackCarry[t].volFx = null;
          _trackCarry[t].panFx = null;
          _trackCarry[t].treSpeed = null;
          _trackCarry[t].treDepth = null;
          _trackCarry[t].treMode = null;
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
          _trackCarry[t].volume = volCmd;
        }

        for (final fx in cell.fxSlots) {
          if (fx.command == kFxPAN && fx.value != null) {
            panCmd = ui99ToAudio255(fx.value!.clamp(0, 99));
            _trackCarry[t].panFx = panCmd;
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
          if (fx.command == kFxBPM && fx.value != null && !bpmFxAppliedThisRow) {
            // BPM FX is pattern-global: only the first track carrying it on
            // this row applies. Value 00 resets to the pattern's own base
            // BPM. 01-50 = +1..+50, 51-99 = -49..-1 (stacks onto whatever
            // tempo is currently in effect this playthrough).
            bpmFxAppliedThisRow = true;
            final bpmXy = fx.value!.clamp(0, 99);
            if (bpmXy == 0) {
              _bpmFxEffective = pattern.bpm ?? 120.0;
            } else if (bpmXy <= 50) {
              _bpmFxEffective += bpmXy;
            } else {
              _bpmFxEffective -= (100 - bpmXy);
            }
            _bpmFxEffective = _bpmFxEffective.clamp(20.0, 300.0);
          }
          if (fx.command == kFxSWN && fx.value != null && !swnFxAppliedThisRow) {
            // SWN FX is pattern-global: only the first track carrying it on
            // this row applies. Directly overrides the pattern's swing
            // amount (00-99) for this row onward, until reset at pattern
            // start / loop start.
            swnFxAppliedThisRow = true;
            _swnFxEffective = fx.value!.clamp(0, 99).toDouble();
          }
          if (fx.command == kFxRAN && fx.value != null) {
            ranChancePct = fx.value!.clamp(0, 99);
          }
          if (fx.command == kFxREV) {
            samplerReverse = true;
          }
          if (fx.command == kFxVOL && fx.value != null) {
            volCmd = ui99ToAudio255(fx.value!.clamp(0, 99));
            _trackCarry[t].volFx = volCmd;
          }
          if (fx.command == kFxVIB && fx.value != null) {
            // XY: X = speed (tens digit, 0-9), Y = depth (ones digit, 0-9).
            final xy = fx.value!.clamp(0, 99);
            final x = xy ~/ 10; // speed digit
            final y = xy % 10; // depth digit
            vibSpeedNorm = x / 9.0;
            vibDepthNorm = y / 9.0;
            // Carry VIB so it persists on subsequent hold rows.
            _trackCarry[t].vibSpeed = vibSpeedNorm;
            _trackCarry[t].vibDepth = vibDepthNorm;
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
            _trackCarry[t].treSpeed = treSpeedNorm;
            _trackCarry[t].treDepth = treDepthNorm;
            _trackCarry[t].treMode = treMode;
          }
          // SN1/SN2/SN3: parallel aux-send percentage to channel 14/15/16,
          // with carry persistence. Value 00 resets the send (percent 0),
          // 01-99 sets the send percentage. The track's normal output keeps
          // playing unaffected — this only adds an extra percentage copy.
          if (fx.command == kFxSN1 || fx.command == kFxSN2 || fx.command == kFxSN3) {
            if (fx.value == 0) {
              // Reset send: clear carry values
              _trackCarry[t].sendChannel = null;
              _trackCarry[t].sendPercent = null;
              sendRoutingCommandQueue.add(t);
              sendRoutingCommandQueue.add(0);
              sendRoutingCommandQueue.add(0);
            } else if (fx.value != null && fx.value! > 0) {
              // Activate send with percentage
              if (fx.command == kFxSN1) {
                _trackCarry[t].sendChannel = 14; // channel 14 for SN1
              } else if (fx.command == kFxSN2) {
                _trackCarry[t].sendChannel = 15; // channel 15 for SN2
              } else {
                _trackCarry[t].sendChannel = 16; // channel 16 for SN3
              }
              _trackCarry[t].sendPercent = fx.value!.clamp(1, 99);
              sendRoutingCommandQueue.add(t);
              sendRoutingCommandQueue.add(_trackCarry[t].sendChannel!);
              sendRoutingCommandQueue.add(_trackCarry[t].sendPercent!);
            }
          }
          if (fx.command == kFxRET) {
            final value = (fx.value ?? 0).clamp(0, 99);
            retrigVolumeMode = (value ~/ 10).clamp(0, 9);
            retrigNotesPerLine = (value % 10).clamp(0, 9);
          }
          if (fx.command == kFxARP && fx.value != null && fx.value! > 0) {
            // Hex nibbles: X=high nibble, Y=low nibble. Each 0-F semitones.
            // 0=unison, 1=m2, 2=M2, 3=m3, 4=M3, 5=P4, 6=tritone,
            // 7=P5, 8=m6, 9=M6, A=m7, B=M7, C=octave, etc.
            arpInterval1 = fx.value! >> 4;
            arpInterval2 = fx.value! & 0x0F;
          }
          if (fx.command == kFxARC && fx.value != null) {
            arcMode = (fx.value! ~/ 10).clamp(1, 9);
            arcOctaveLayers = ((arcMode - 1) % 3) + 1; // 1-9 → 1,2,3,1,2,3,1,2,3 octaves
            arcNotesPerLine = (fx.value! % 10).clamp(0, 9);
          }
          // SLU/SLD XY: X (tens) = lines to slide over, Y (ones) = semitones.
          // Works on note rows and on hold rows that have an active carry note.
          if ((fx.command == kFxSLU || fx.command == kFxSLD) &&
              fx.value != null) {
            final slideBase = noteCmd >= 0
                ? noteCmd
                : (_trackCarry.length > t ? _trackCarry[t].note : null);
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
            while (_trackCarry.length <= t) {
              _trackCarry.add(_TrackCarry());
            }
            if (idx == 0) {
              // P00: reset — clear all overrides for this track.
              _trackCarry[t].instrumentParams.clear();
            } else if (fx.value != null) {
              final val = fx.value!.clamp(0, 99);
              _trackCarry[t].instrumentParams[idx] = val;
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
        _trackCarry[t].note = noteCmd;
        _trackCarry[t].volume = volCmd;
      } else if (noteCmd == -2) {
        _trackCarry[t].note = null;
        _trackCarry[t].volume = null;
        // Clear send carry on note-off (===)
        _trackCarry[t].sendChannel = null;
        _trackCarry[t].sendPercent = null;
        sendRoutingCommandQueue.add(t);
        sendRoutingCommandQueue.add(0);
        sendRoutingCommandQueue.add(0);
      }

      final retBaseNote = _trackCarry[t].note;
      final retBaseVolume = _trackCarry[t].volume ?? volCmd;
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
            : (_trackCarry.length > t
                  ? (_trackCarry[t].note ?? pendingSlide.endNote)
                  : pendingSlide.endNote);
        if (t < _trackCarry.length) {
          _trackCarry[t].slide = (
            startNote: startNote,
            endNote: pendingSlide.endNote,
            totalLines: pendingSlide.totalLines,
            linesElapsed: 0,
          );
        }
      } else if (noteCmd == -2 || noteCmd >= 0) {
        // Note-off or new note without slide: cancel any active slide.
        if (t < _trackCarry.length) _trackCarry[t].slide = null;
      } else if (noteCmd == -1 &&
          t < _trackCarry.length &&
          _trackCarry[t].slide != null &&
          !isMixerMuted) {
        // Hold row with active slide.
        final slide = _trackCarry[t].slide!;
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
        _trackCarry[t].slide = nextElapsed >= slide.totalLines
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
      final midNoteArp =
          arpInterval1 >= 0 &&
          noteCmd == -1 &&
          _trackCarry.length > t &&
          _trackCarry[t].note != null &&
          !isMixerMuted;
      if (arpInterval1 >= 0 && (noteCmd >= 0 || midNoteArp)) {
        // New note or mid-note hold row with ARP: (re)start the carry.
        final baseNote = noteCmd >= 0 ? noteCmd : _trackCarry[t].note!;
        final layers = arcOctaveLayers > 0 ? arcOctaveLayers : 1;
        final modeType = arcMode <= 3 ? 1 : (arcMode <= 6 ? 2 : 3); // 1=linear, 2=bidirectional, 3=random
        final cycle = <int>[];
        
        for (int oct = 0; oct < layers; oct++) {
          final offset = 12 * oct;
          final base = (baseNote + offset).clamp(0, 127);
          final int1 = (baseNote + arpInterval1 + offset).clamp(0, 127);
          final int2 = (baseNote + arpInterval2 + offset).clamp(0, 127);
          
          if (modeType == 1) {
            // Linear: play notes forward
            cycle.addAll([base, int1, int2]);
          } else if (modeType == 2) {
            // Bidirectional: forward + backward with peak repeat
            cycle.addAll([base, int1, int2, int2, int1, base]);
          } else {
            // Random: shuffle the three notes for this octave
            final notes = [base, int1, int2];
            // Seeded shuffle for deterministic "random" feel
            notes.shuffle(rng);
            cycle.addAll(notes);
          }
        }
        final notesPerLine = arcNotesPerLine > 0
            ? arcNotesPerLine
            : cycle.length;
        _trackCarry[t].arp = (
          cycle: List<int>.unmodifiable(cycle),
          notesPerLine: notesPerLine,
          phase: 0,
        );
        pendingArp[t] = _trackCarry[t].arp!;
        if (midNoteArp) {
          // Fire the first ARP pitch immediately as a pitch-only update.
          noteCmd = pitchOnlyNoteCmd(cycle[0]);
        }
      } else if (noteCmd == -2 || noteCmd >= 0) {
        // Note-off or new note without ARP: clear carry.
        _trackCarry[t].arp = null;
      } else if (noteCmd == -1 && _trackCarry[t].arp != null && !isMixerMuted) {
        // Held empty line with active carry: continue the ARP phase instead of
        // restarting from the first note.
        final carry = _trackCarry[t].arp!;
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
        // Only attenuation is baked into the per-note vol byte; gain >1.0 is
        // applied solely by the native master-gain stage so it isn't doubled.
        final atten = song.masterVolume < 1.0 ? song.masterVolume : 1.0;
        finalVol = (volCmd * atten).round().clamp(0, 255);
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
    final int baseLineSamples =
        (_lineDurationForPatternRow(pattern, playheadRow, _bpmFxEffective)
                .inMicroseconds *
            kSampleRate) ~/
        1000000;

    // Apply per-pattern swing: odd-indexed lines within a beat (0-based
    // positions 1, 3, 5 … i.e. the 2nd, 4th, 6th lines) are pushed later by
    // swingDelta samples; the preceding even-indexed line grows by the same
    // amount so beat boundaries never drift.
    // patSwing comes from _swnFxEffective rather than pattern.swing directly
    // so an SWN FX command can override it for this playthrough; it is
    // reset back to the pattern's own snapshot swing at pattern start/loop.
    final int lineSamples;
    final double patSwing = _swnFxEffective;
    if (patSwing > 0.0) {
      final int posInBeat = pattern.rowWithinBeat(playheadRow);
      final int swingDelta = (patSwing / 100.0 * baseLineSamples).round();
      if (posInBeat % 2 == 0) {
        // Even-indexed (1st, 3rd… lines): grows longer
        lineSamples = baseLineSamples + swingDelta;
      } else {
        // Odd-indexed (2nd, 4th… lines): compensates by being shorter
        lineSamples = (baseLineSamples - swingDelta).clamp(1, baseLineSamples);
      }
    } else {
      lineSamples = baseLineSamples;
    }

    if (pendingArp.isNotEmpty) {
      pendingArp.forEach((trackIdx, cfg) {
        for (int step = 1; step < cfg.notesPerLine; step++) {
          final int midi = cfg.cycle[(cfg.phase + step) % cfg.cycle.length];
          arpQueue.addAll([step, cfg.notesPerLine, trackIdx, midi]);
        }
        final carry = _trackCarry[trackIdx].arp;
        if (carry != null) {
          _trackCarry[trackIdx].arp = (
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
      sendRoutingCommandData: List<int>.unmodifiable(sendRoutingCommandQueue),
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

    final instNum = (cell.instrument != null && cell.instrument! > 0)
        ? cell.instrument!
        : _defaultInstrumentForRow(track, row);
    final slot = (instNum - 1).clamp(0, instruments.length - 1);

    final waveCmd = _waveCodeForInstrumentSlot(slot);
    final instrumentTypeCmd = _instrumentTypeCodeForSlot(slot);
    var synthParams = _synthParamsForInstrumentSlot(slot);
    final previewVoice = _previewVoiceIndexForInstrumentSlot(slot);

    // If this is a sampler and the note is in C-0..G#0, preview the
    // corresponding slice (1..9) instead of playing the full sample pitched.
    if (instruments[slot].type == InstrumentType.sampler && note.isNote) {
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
    _synthPreviewStopTimer = Timer.periodic(const Duration(milliseconds: 50), (
      _,
    ) async {
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
    });
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

  Future<String?> previewCurrentDrumOneShot({
    int midiNote = 60,
    int durationMs = 420,
  }) async {
    try {
      if (isPlaying) {
        return 'Stop playback before Drum Synth preview';
      }

      final slot = currentInstrumentIndex.clamp(0, instruments.length - 1);
      final ins = instruments[slot];
      if (ins.type != InstrumentType.drumSynth) {
        return 'Current instrument is not Drum Synth';
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

    final slot =
        (_previewSamplerSlot >= 0
                ? _previewSamplerSlot
                : currentInstrumentIndex)
            .clamp(0, instruments.length - 1);
    final sampler = instruments[slot].sampler;
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

    // Clear UI state immediately so playhead stops animating.
    _previewStartedAt = null;
    _previewRegionStartNorm = null;
    _previewRegionEndNorm = null;
    _previewSamplerSlot = -1;
    notifyListeners();

    // Send note-off — for looping samples this triggers the C++ release fade.
    await AudioEngine.instance.setRowData(noteOff);

    // For looping samples, wait for the release envelope to finish naturally.
    // The C++ DSP zeros the voice itself — no killVoices needed (that would click).
    if (sampler.loopMode != SamplerLoopMode.off) {
      final releaseMs = (sampler.release * 1200).toInt().clamp(20, 2000);
      await Future.delayed(Duration(milliseconds: releaseMs));
      await _setPreviewDryBypass(previewVoice, false);
    } else {
      // Non-looping: hard-stop any lingering reverb tails immediately.
      await AudioEngine.instance.killVoices(
        List<int>.filled(_audioVoiceCount, 1),
      );
      await _setPreviewDryBypass(previewVoice, false);
    }
    // Do NOT stop the output stream here — stopping it causes an Android
    // hardware route change that produces a transient burst in the next
    // mic capture. The output stream stays open but silent.
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

      // Master safety limiter: defaults to enabled. Push the saved value to
      // the native engine so its runtime state matches the persisted setting.
      _masterLimiterEnabled = j['masterLimiterEnabled'] as bool? ?? true;
      unawaited(
        AudioEngine.instance.setMasterLimiterEnabled(_masterLimiterEnabled),
      );

      // Stability Mode: defaults to disabled. Push the saved value so the
      // native buffer margin matches the persisted setting on every launch.
      _stabilityModeEnabled = j['stabilityModeEnabled'] as bool? ?? false;
      unawaited(
        AudioEngine.instance.setStabilityMode(_stabilityModeEnabled),
      );

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
        'masterLimiterEnabled': _masterLimiterEnabled,
        'stabilityModeEnabled': _stabilityModeEnabled,
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

  /// Toggle the always-on master safety limiter. Setting persists across
  /// sessions; the native engine is updated immediately.
  Future<void> setMasterLimiterEnabled(bool enabled) async {
    if (_masterLimiterEnabled == enabled) return;
    _masterLimiterEnabled = enabled;
    await AudioEngine.instance.setMasterLimiterEnabled(enabled);
    _notifyListenersSafe();
    await _saveAppSettings();
  }

  /// Toggle Stability Mode (extra Oboe output-buffer margin for CPU-heavy
  /// conditions such as screen recording). Setting persists across sessions.
  Future<void> setStabilityMode(bool enabled) async {
    if (_stabilityModeEnabled == enabled) return;
    _stabilityModeEnabled = enabled;
    await AudioEngine.instance.setStabilityMode(enabled);
    _notifyListenersSafe();
    await _saveAppSettings();
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
      await _projectStorageChannel
          .invokeMethod<String>('writeProjectBinaryFile', {
            'treeUri': _projectRootTreeUri,
            'folderName': folderName,
            'fileName': fileName,
            'bytes': bytes,
          });
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
      bytes = raw is Uint8List
          ? raw
          : Uint8List.fromList(List<int>.from(raw as List));
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
          !srcPath.contains('/') && !srcPath.contains(Platform.pathSeparator);
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

      // Keep the full cache path in memory so the waveform display can read
      // the file immediately.  The bare filename is stored in sampleName and
      // will be written to the JSON payload by saveSong() so that the project
      // can be reloaded via SAF even after the local cache is cleared.
      ins.sampler.samplePath = cachePath;
      ins.sampler.sampleName = candidate;
      await AudioEngine.instance.setSamplerSample(i, cachePath);
    }
  }

  /// Resolves a raw samplePath from JSON to a usable local filesystem path.
  /// Bare filenames are SAF-relative (or filesystem-relative in non-SAF mode).
  Future<String?> _resolveSamplePath(String? rawPath, String songName) async {
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
    if (File(rawPath).existsSync()) return rawPath;

    // Fallback: if the file is no longer at its stored absolute path (e.g.
    // the project root was moved, or a symlink was resolved differently),
    // try looking it up by filename inside the current song's samples dir.
    final sep = Platform.pathSeparator;
    final fileName = rawPath.split(sep).last;
    if (fileName.isNotEmpty &&
        !fileName.contains('/') &&
        !fileName.contains(sep)) {
      if (_usesProjectTreeStorage) {
        final slug = _slugify(songName);
        final folderName = slug.isEmpty ? 'untitled' : slug;
        return _readSafSample(folderName, fileName);
      } else {
        final dir = await _songSamplesDir(songName);
        final fallback = '${dir.path}/$fileName';
        if (File(fallback).existsSync()) return fallback;
      }
    }
    return null;
  }

  void renameSong(String name) {
    song.name = name;
    _notifyListenersSafe();
  }

  /// Save current song then reset to a blank new song with the specified name.
  Future<bool> newSongWithName(String name) async {
    final saved = await saveSong();
    await _clearInsertEffectsInEngine();
    song = SongModel(name: name);
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
    _lastSavedSongStateVersion = _songStateVersion;
    _notifyListenersSafe();
    return saved;
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
    _lastSavedSongStateVersion = _songStateVersion;
    _notifyListenersSafe();
    return saved;
  }

  /// Save to disk using song.name as the filename. Overwrites existing.
  Future<bool> saveSong() async {
    try {
      // Keep app-managed local copies of used sampler files for this song.
      await _persistSamplerAssetsForSong();
      // For SAF projects, samplePath is kept as the full local cache path
      // in memory (so waveform display works), but the JSON must store only
      // the bare filename so the file can be re-read from SAF on reload.
      final instrumentsJson = instruments.map((ins) {
        final j = ins.toJson();
        if (_usesProjectTreeStorage &&
            ins.type == InstrumentType.sampler &&
            ins.sampler.sampleName != null &&
            ins.sampler.sampleName!.isNotEmpty) {
          final sampler = Map<String, dynamic>.from(
            j['sampler'] as Map<String, dynamic>? ?? {},
          );
          sampler['samplePath'] = ins.sampler.sampleName;
          j['sampler'] = sampler;
        }
        return j;
      }).toList();
      final payload = jsonEncode({
        'song': song.toJson(),
        'instruments': instrumentsJson,
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
        if (ok == true) {
          _lastSavedSongStateVersion = _songStateVersion;
          unawaited(_saveAppSettings());
        }
        return ok == true;
      }

      await (await _songFile(song.name)).writeAsString(payload);
      _lastSavedSongStateVersion = _songStateVersion;
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

  /// Check if a song with the given name already exists (case-insensitive).
  Future<bool> songNameExists(String name) async {
    final names = await listSavedSongs();
    final lowerName = name.trim().toLowerCase();
    return names.any((n) => n.toLowerCase() == lowerName);
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
            final ok = await AudioEngine.instance.setSamplerSample(i, resolved);
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
      _queueCurrentMixerSnapshotToEngine();

      _currentPatternIndex = 0;
      _currentTrackIndex = 0;
      _currentInstrumentIndex = 0;
      _currentArrangementSlotIndex = 0;
      selectedCell = null;
      _selectedRowStart = null;
      _selectedRowEnd = null;
      _songStateVersion++;
      _lastSavedSongStateVersion = _songStateVersion;
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
