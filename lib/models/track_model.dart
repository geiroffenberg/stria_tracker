import 'cell.dart';
import 'note_value.dart';

const int kDefaultRowsPerPattern = 64;
const int kMaxTracks      = 16;
const int kDefaultTracks  = 16;
const int kFxSlots        = 3;

class TrackModel {
  String name;
  bool collapsed;
  List<TrackerCell> cells;

  TrackModel({
    required this.name,
    this.collapsed = false,
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
    cells[row].instrument = value;
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
      case CellColumn.pan:
        return cell.pan;
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
        cells[row].instrument = v;
        break;
      case CellColumn.volume:
        cells[row].volume = v;
        break;
      case CellColumn.pan:
        cells[row].pan = v;
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
    return 255; // all other fields are 0–255
  }

  /// Min value for clamping scroll input.
  int minValue(CellColumn column) => 0;
}
