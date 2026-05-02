import 'cell.dart';
import 'note_value.dart';

const int kDefaultRowsPerPattern = 64;
const int kMaxTracks      = 16;
const int kDefaultTracks  = 16;
const int kFxSlots        = 3;

class TrackModel {
  String name;
  bool collapsed;
  double mixerVolume; // 0..1
  double mixerPan; // -1..1
  bool mixerMute;
  bool mixerSolo;
  List<TrackerCell> cells;

  TrackModel({
    required this.name,
    this.collapsed = false,
    this.mixerVolume = 0.8,
    this.mixerPan = 0.0,
    this.mixerMute = false,
    this.mixerSolo = false,
    int rowCount = kDefaultRowsPerPattern,
    List<TrackerCell>? cells,
  }) : cells = cells ?? List.generate(rowCount, (_) => TrackerCell.empty());

  void resizeRows(int rowCount) {
    final target = rowCount.clamp(1, 9801);
    if (cells.length == target) return;
    if (cells.length < target) {
      cells.addAll(List.generate(target - cells.length, (_) => TrackerCell.empty()));
      return;
    }
    cells = cells.sublist(0, target);
  }

  // ── Cell mutation helpers ────────────────────────────────────────────────

  void setNote(int row, NoteValue note) {
    cells[row].note = note;
  }

  void setInstrument(int row, int? value) {
    cells[row].instrument = value?.clamp(1, 99);
  }

  void setVolume(int row, int? value) {
    cells[row].volume = value;
  }

  void setPan(int row, int? value) {
    cells[row].pan = value;
  }

  void setFxCommand(int row, int fxIndex, int? value) {
    cells[row].fxSlots[fxIndex].command = value;
  }

  void setFxValue(int row, int fxIndex, int? value) {
    cells[row].fxSlots[fxIndex].value = value;
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'collapsed': collapsed,
    'mixVol': mixerVolume,
    'mixPan': mixerPan,
    'mixMute': mixerMute,
    'mixSolo': mixerSolo,
    'cells': cells.map((c) => c.toJson()).toList(),
  };

  factory TrackModel.fromJson(Map<String, dynamic> j) => TrackModel(
    name: j['name'] as String,
    collapsed: (j['collapsed'] as bool?) ?? false,
    mixerVolume: ((j['mixVol'] as num?)?.toDouble() ?? 0.8).clamp(0.0, 1.0),
    mixerPan: ((j['mixPan'] as num?)?.toDouble() ?? 0.0).clamp(-1.0, 1.0),
    mixerMute: (j['mixMute'] as bool?) ?? false,
    mixerSolo: (j['mixSolo'] as bool?) ?? false,
    cells: (j['cells'] as List<dynamic>)
        .map((e) => TrackerCell.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  /// Read the current numeric value for [column] at [row].
  /// Returns null when the field is empty.
  int? readColumnValue(int row, CellColumn column) {
    final cell = cells[row];
    switch (column) {
      case CellColumn.note:
        return cell.note.scrollIndex;
      case CellColumn.instrument:
        return cell.instrument;
      case CellColumn.volume:
        return cell.volume;
      case CellColumn.fx0cmd:
        return cell.fxSlots[0].command;
      case CellColumn.fx0val:
        return cell.fxSlots[0].value;
      case CellColumn.fx1cmd:
        return cell.fxSlots[1].command;
      case CellColumn.fx1val:
        return cell.fxSlots[1].value;
      case CellColumn.fx2cmd:
        return cell.fxSlots[2].command;
      case CellColumn.fx2val:
        return cell.fxSlots[2].value;
    }
  }

  /// Write a numeric value for [column] at [row].
  void writeColumnValue(int row, CellColumn column, int? v) {
    switch (column) {
      case CellColumn.note:
        cells[row].note = NoteValue.fromScrollIndex(v ?? 0);
        break;
      case CellColumn.instrument:
        cells[row].instrument = v?.clamp(1, 99);
        break;
      case CellColumn.volume:
        cells[row].volume = v;
        break;
      case CellColumn.fx0cmd:
        cells[row].fxSlots[0].command = v;
        break;
      case CellColumn.fx0val:
        cells[row].fxSlots[0].value = v;
        break;
      case CellColumn.fx1cmd:
        cells[row].fxSlots[1].command = v;
        break;
      case CellColumn.fx1val:
        cells[row].fxSlots[1].value = v;
        break;
      case CellColumn.fx2cmd:
        cells[row].fxSlots[2].command = v;
        break;
      case CellColumn.fx2val:
        cells[row].fxSlots[2].value = v;
        break;
    }
  }

  /// Max value for clamping scroll input.
  int maxValue(CellColumn column) {
    if (column == CellColumn.note) return 121; // 0=empty … 121=OFF
    if (column == CellColumn.instrument ||
        column == CellColumn.volume) {
      return 99;
    }
    return 255; // FX fields are 0–255
  }

  /// Min value for clamping scroll input.
  int minValue(CellColumn column) {
    if (column == CellColumn.instrument) return 1;
    return 0;
  }
}
