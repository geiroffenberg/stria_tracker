import 'note_value.dart';

/// One FX slot: command byte + value byte. Both nullable (empty = not set).
class FxSlot {
  int? command; // 0x00–0xFF, null = empty
  int? value; // 0x00–0xFF, null = empty

  FxSlot({this.command, this.value});

  FxSlot copyWith({int? Function()? command, int? Function()? value}) => FxSlot(
    command: command != null ? command() : this.command,
    value: value != null ? value() : this.value,
  );

  Map<String, dynamic> toJson() => {'cmd': command, 'val': value};

  factory FxSlot.fromJson(Map<String, dynamic> j) =>
      FxSlot(command: j['cmd'] as int?, value: j['val'] as int?);

  /// 2-char hex display, or '--' if empty.
  static String hexDisplay(int? v) =>
      v == null ? '--' : v.toRadixString(16).toUpperCase().padLeft(2, '0');

  /// 2-digit decimal display for FX values (00–99), always shows 00 if empty.
  /// 2-digit decimal display for FX values (00–99), or '--' if empty.
  static String fxValueDisplay(int? v) =>
      v == null ? '--' : (v % 100).toString().padLeft(2, '0');
}

/// 3-letter display names for FX command bytes.
/// Index 0 = first real command; null/out-of-range = '---'.
const List<String> kFxCommandNames = [
  'ARP', // 00 – arpeggio
  'CHA', // 01 – chance
  'DEL', // 02 – delay
  'KIL', // 03 – kill note
  'PAN', // 04 – stereo pan
  'RAN', // 05 – randomise
  'RET', // 06 – retrigger
  'REV', // 07 – reverse
  'VIB', // 08 – vibrato
  'VOL', // 09 – volume ramp
  // Instrument synth FX (Axx)
  'A01',
  'A02',
  'A03',
  'A04',
  'A05',
  'A06',
  // Instrument sample FX (Sxx)
  'S01',
  'S02',
  'S03',
  'S04',
  'S05',
  'S06',
  // Sample slicer select FX (SLx)
  'SL0',
  'SL1',
  'SL2',
  'SL3',
  'SL4',
  'SL5',
  'SL6',
  'SL7',
  'SL8',
  'SL9',
  // Mixer channel-strip FX (Mxx)
  'M01',
  'M02',
  'M03',
  'M04',
  // Master insert routing (numeric)
  '101',
  '201',
  '301',
  '401',
  '501',
  '601',
  '701',
  '801',
  '901',
];

const List<String> kFxCommandDescriptions = [
  'Fast arpeggio',
  'Random note chance',
  'Repeat with delay',
  'Kill note early',
  'Stereo pan sweep',
  'Randomize pitch',
  'Retrigger pattern',
  'Play sample backwards',
  'Add vibrato modulation',
  'Ramp volume over time',
  'Synth FX A01 (reserved)',
  'Synth FX A02 (reserved)',
  'Synth FX A03 (reserved)',
  'Synth FX A04 (reserved)',
  'Synth FX A05 (reserved)',
  'Synth FX A06 (reserved)',
  'Sample FX S01 (reserved)',
  'Sample FX S02 (reserved)',
  'Sample FX S03 (reserved)',
  'Sample FX S04 (reserved)',
  'Sample FX S05 (reserved)',
  'Sample FX S06 (reserved)',
  'Select Slice 0 (sample start)',
  'Select Slice 1',
  'Select Slice 2',
  'Select Slice 3',
  'Select Slice 4',
  'Select Slice 5',
  'Select Slice 6',
  'Select Slice 7',
  'Select Slice 8',
  'Select Slice 9',
  'Mixer volume (00-99)',
  'Mixer pan (00-99)',
  'Mixer mute (00=off, >00=on)',
  'Mixer solo (00=off, >00=on)',
  'Insert 1 param 01 (reserved)',
  'Insert 2 param 01 (reserved)',
  'Insert 3 param 01 (reserved)',
  'Insert 4 param 01 (reserved)',
  'Insert 5 param 01 (reserved)',
  'Insert 6 param 01 (reserved)',
  'Insert 7 param 01 (reserved)',
  'Insert 8 param 01 (reserved)',
  'Insert 9 param 01 (reserved)',
];

/// FX command byte constants (indices into kFxCommandNames).
const int kFxARP = 0;
const int kFxCHA = 1;
const int kFxDEL = 2;
const int kFxKIL = 3;
const int kFxPAN = 4;
const int kFxRAN = 5;
const int kFxRET = 6;
const int kFxREV = 7;
const int kFxVIB = 8;
const int kFxVOL = 9;
const int kFxSL0 = 22;
const int kFxSL9 = 31;

/// Returns the 3-letter FX command name, or '---' if null/unknown.
String fxCommandName(int? cmd) {
  if (cmd == null) return '---';
  if (cmd < kFxCommandNames.length) return kFxCommandNames[cmd];
  return cmd.toRadixString(16).toUpperCase().padLeft(3, '0');
}

/// Returns the description for an FX command.
String fxCommandDescription(int? cmd) {
  if (cmd == null) return '';
  if (cmd >= 0 && cmd < kFxCommandDescriptions.length) {
    return kFxCommandDescriptions[cmd];
  }
  return '';
}

/// One row in a track: note + instrument + volume + pan + 3 FX slots.
class TrackerCell {
  NoteValue note;
  int? instrument; // 0x00–0xFF, null = empty
  int? volume; // 0x00–0xFF, null = empty (FF = max)
  int? pan; // 0x00–0xFF, null = empty (80 = centre)
  List<FxSlot> fxSlots; // always length 3

  TrackerCell({
    NoteValue? note,
    this.instrument,
    this.volume,
    this.pan,
    List<FxSlot>? fxSlots,
  }) : note = note ?? NoteValue.empty,
       fxSlots = fxSlots ?? List.generate(3, (_) => FxSlot());

  static TrackerCell empty() => TrackerCell();

  bool get isEmpty =>
      note.isEmpty &&
      instrument == null &&
      volume == null &&
      fxSlots.every((slot) => slot.command == null && slot.value == null);

  TrackerCell copy() => TrackerCell(
    note: note,
    instrument: instrument,
    volume: volume,
    pan: pan,
    fxSlots: fxSlots
        .map((f) => FxSlot(command: f.command, value: f.value))
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'note': note.scrollIndex,
    'inst': instrument,
    'vol': volume,
    'pan': pan,
    'fx': fxSlots.map((f) => f.toJson()).toList(),
  };

  factory TrackerCell.fromJson(Map<String, dynamic> j) => TrackerCell(
    note: NoteValue.fromScrollIndex((j['note'] as int?) ?? 0),
    instrument: j['inst'] as int?,
    volume: j['vol'] as int?,
    pan: j['pan'] as int?,
    fxSlots:
        (j['fx'] as List<dynamic>?)
            ?.map((e) => FxSlot.fromJson(e as Map<String, dynamic>))
            .toList() ??
        List.generate(3, (_) => FxSlot()),
  );
}

/// Column indices used throughout the UI.
enum CellColumn {
  note, // 0
  instrument, // 1
  volume, // 2
  fx0cmd, // 3
  fx0val, // 4
  fx1cmd, // 5
  fx1val, // 6
  fx2cmd, // 7
  fx2val, // 8
}

extension CellColumnLabel on CellColumn {
  String get header {
    switch (this) {
      case CellColumn.note:
        return 'NOTE';
      case CellColumn.instrument:
        return 'IN';
      case CellColumn.volume:
        return 'VL';
      case CellColumn.fx0cmd:
        return 'FX1';
      case CellColumn.fx0val:
        return '';
      case CellColumn.fx1cmd:
        return 'FX2';
      case CellColumn.fx1val:
        return '';
      case CellColumn.fx2cmd:
        return 'FX3';
      case CellColumn.fx2val:
        return '';
    }
  }

  bool get isNote => this == CellColumn.note;
  bool get isInstrument => this == CellColumn.instrument;
}
