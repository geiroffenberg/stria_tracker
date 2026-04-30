import 'note_value.dart';

/// One FX slot: command byte + value byte. Both nullable (empty = not set).
class FxSlot {
  int? command; // 0x00–0xFF, null = empty
  int? value;   // 0x00–0xFF, null = empty

  FxSlot({this.command, this.value});

  FxSlot copyWith({int? Function()? command, int? Function()? value}) => FxSlot(
        command: command != null ? command() : this.command,
        value:   value   != null ? value()   : this.value,
      );

  /// 2-char hex display, or '--' if empty.
  static String hexDisplay(int? v) =>
      v == null ? '--' : v.toRadixString(16).toUpperCase().padLeft(2, '0');
}

/// One row in a track: note + instrument + volume + pan + 3 FX slots.
class TrackerCell {
  NoteValue note;
  int? instrument; // 0x00–0xFF, null = empty
  int? volume;     // 0x00–0xFF, null = empty (FF = max)
  int? pan;        // 0x00–0xFF, null = empty (80 = centre)
  List<FxSlot> fxSlots; // always length 3

  TrackerCell({
    NoteValue? note,
    this.instrument,
    this.volume,
    this.pan,
    List<FxSlot>? fxSlots,
  })  : note = note ?? NoteValue.empty,
        fxSlots = fxSlots ?? List.generate(3, (_) => FxSlot());

  static TrackerCell empty() => TrackerCell();

  TrackerCell copy() => TrackerCell(
        note: note,
        instrument: instrument,
        volume: volume,
        pan: pan,
        fxSlots: fxSlots
            .map((f) => FxSlot(command: f.command, value: f.value))
            .toList(),
      );
}

/// Column indices used throughout the UI.
enum CellColumn {
  note,        // 0
  instrument,  // 1
  volume,      // 2
  pan,         // 3
  fx0cmd,      // 4
  fx0val,      // 5
  fx1cmd,      // 6
  fx1val,      // 7
  fx2cmd,      // 8
  fx2val,      // 9
}

extension CellColumnLabel on CellColumn {
  String get header {
    switch (this) {
      case CellColumn.note:       return 'NOTE';
      case CellColumn.instrument: return 'IN';
      case CellColumn.volume:     return 'VL';
      case CellColumn.pan:        return 'PN';
      case CellColumn.fx0cmd:     return 'F1';
      case CellColumn.fx0val:     return 'V1';
      case CellColumn.fx1cmd:     return 'F2';
      case CellColumn.fx1val:     return 'V2';
      case CellColumn.fx2cmd:     return 'F3';
      case CellColumn.fx2val:     return 'V3';
    }
  }

  bool get isNote       => this == CellColumn.note;
  bool get isInstrument => this == CellColumn.instrument;
}
