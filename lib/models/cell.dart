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
  // Mixer channel-strip FX (32-183): Master (32-33) + 15 channels * 10 slots (34-183)
  'M01', // 32 – master mute
  'M02', // 33 – master volume
  // Channel 1 (34-43): M11-M19 (1-4 implemented, 5-9 reserved)
  'M11', 'M12', 'M13', 'M14', 'M15', 'M16', 'M17', 'M18', 'M19',
  // Channel 2 (44-53)
  'M21', 'M22', 'M23', 'M24', 'M25', 'M26', 'M27', 'M28', 'M29',
  // Channel 3 (54-63)
  'M31', 'M32', 'M33', 'M34', 'M35', 'M36', 'M37', 'M38', 'M39',
  // Channel 4 (64-73)
  'M41', 'M42', 'M43', 'M44', 'M45', 'M46', 'M47', 'M48', 'M49',
  // Channel 5 (74-83)
  'M51', 'M52', 'M53', 'M54', 'M55', 'M56', 'M57', 'M58', 'M59',
  // Channel 6 (84-93)
  'M61', 'M62', 'M63', 'M64', 'M65', 'M66', 'M67', 'M68', 'M69',
  // Channel 7 (94-103)
  'M71', 'M72', 'M73', 'M74', 'M75', 'M76', 'M77', 'M78', 'M79',
  // Channel 8 (104-113)
  'M81', 'M82', 'M83', 'M84', 'M85', 'M86', 'M87', 'M88', 'M89',
  // Channel 9 (114-123)
  'M91', 'M92', 'M93', 'M94', 'M95', 'M96', 'M97', 'M98', 'M99',
  // Channel 10 (124-133)
  'MA1', 'MA2', 'MA3', 'MA4', 'MA5', 'MA6', 'MA7', 'MA8', 'MA9',
  // Channel 11 (134-143)
  'MB1', 'MB2', 'MB3', 'MB4', 'MB5', 'MB6', 'MB7', 'MB8', 'MB9',
  // Channel 12 (144-153)
  'MC1', 'MC2', 'MC3', 'MC4', 'MC5', 'MC6', 'MC7', 'MC8', 'MC9',
  // Channel 13 (154-163)
  'MD1', 'MD2', 'MD3', 'MD4', 'MD5', 'MD6', 'MD7', 'MD8', 'MD9',
  // Channel 14 (164-173)
  'ME1', 'ME2', 'ME3', 'ME4', 'ME5', 'ME6', 'ME7', 'ME8', 'ME9',
  // Channel 15 (174-183)
  'MF1', 'MF2', 'MF3', 'MF4', 'MF5', 'MF6', 'MF7', 'MF8', 'MF9',
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
  'ARC', // octave span + arp speed config
  'SLC', // sample slice command (unified slice player)
];

const List<String> kFxCommandDescriptions = [
  'Arpeggio — XY: X=1st interval, Y=2nd interval (1-9 = semitones above root)',
  'Chance — 00=never play, 99=always play, 50=50% chance',
  'Delay — 00=line start, 99=line end (note-on offset within row)',
  'Kill — cut note at % through row (00=immediate, 99=end of row)',
  'Pan — set stereo position (00=left, 50=centre, 99=right)',
  'Random slice — 00=off, 01-99=chance % to pick a random active slice',
  'Retrigger — XY: X=volume curve, Y=retrigs per line',
  'Reverse — play sample/slice backwards',
  'Vibrato — XY: X=speed (0-9), Y=depth (0-9), pitch LFO',
  'Volume — set level for this row only (00=silent, 99=full)',
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
  // Mixer channel-strip FX (32-183): Master + 15 channels * 10 slots
  'Master mute (00=off, >00=on)',
  'Master volume (00-99)',
  // Channel 1 (34-43): M11-M19
  'Channel 1 pan (00=left, 50=centre, 99=right)',
  'Channel 1 mute (00=off, >00=on)',
  'Channel 1 solo (00=off, >00=on)',
  'Channel 1 volume (00-99)',
  'Channel 1 reserved M15',
  'Channel 1 reserved M16',
  'Channel 1 reserved M17',
  'Channel 1 reserved M18',
  'Channel 1 reserved M19',
  // Channel 2 (44-53): M21-M29
  'Channel 2 pan (00=left, 50=centre, 99=right)',
  'Channel 2 mute (00=off, >00=on)',
  'Channel 2 solo (00=off, >00=on)',
  'Channel 2 volume (00-99)',
  'Channel 2 reserved M25',
  'Channel 2 reserved M26',
  'Channel 2 reserved M27',
  'Channel 2 reserved M28',
  'Channel 2 reserved M29',
  // Channel 3 (54-63): M31-M39
  'Channel 3 pan (00=left, 50=centre, 99=right)',
  'Channel 3 mute (00=off, >00=on)',
  'Channel 3 solo (00=off, >00=on)',
  'Channel 3 volume (00-99)',
  'Channel 3 reserved M35',
  'Channel 3 reserved M36',
  'Channel 3 reserved M37',
  'Channel 3 reserved M38',
  'Channel 3 reserved M39',
  // Channel 4 (64-73): M41-M49
  'Channel 4 pan (00=left, 50=centre, 99=right)',
  'Channel 4 mute (00=off, >00=on)',
  'Channel 4 solo (00=off, >00=on)',
  'Channel 4 volume (00-99)',
  'Channel 4 reserved M45',
  'Channel 4 reserved M46',
  'Channel 4 reserved M47',
  'Channel 4 reserved M48',
  'Channel 4 reserved M49',
  // Channel 5 (74-83): M51-M59
  'Channel 5 pan (00=left, 50=centre, 99=right)',
  'Channel 5 mute (00=off, >00=on)',
  'Channel 5 solo (00=off, >00=on)',
  'Channel 5 volume (00-99)',
  'Channel 5 reserved M55',
  'Channel 5 reserved M56',
  'Channel 5 reserved M57',
  'Channel 5 reserved M58',
  'Channel 5 reserved M59',
  // Channel 6 (84-93): M61-M69
  'Channel 6 pan (00=left, 50=centre, 99=right)',
  'Channel 6 mute (00=off, >00=on)',
  'Channel 6 solo (00=off, >00=on)',
  'Channel 6 volume (00-99)',
  'Channel 6 reserved M65',
  'Channel 6 reserved M66',
  'Channel 6 reserved M67',
  'Channel 6 reserved M68',
  'Channel 6 reserved M69',
  // Channel 7 (94-103): M71-M79
  'Channel 7 pan (00=left, 50=centre, 99=right)',
  'Channel 7 mute (00=off, >00=on)',
  'Channel 7 solo (00=off, >00=on)',
  'Channel 7 volume (00-99)',
  'Channel 7 reserved M75',
  'Channel 7 reserved M76',
  'Channel 7 reserved M77',
  'Channel 7 reserved M78',
  'Channel 7 reserved M79',
  // Channel 8 (104-113): M81-M89
  'Channel 8 pan (00=left, 50=centre, 99=right)',
  'Channel 8 mute (00=off, >00=on)',
  'Channel 8 solo (00=off, >00=on)',
  'Channel 8 volume (00-99)',
  'Channel 8 reserved M85',
  'Channel 8 reserved M86',
  'Channel 8 reserved M87',
  'Channel 8 reserved M88',
  'Channel 8 reserved M89',
  // Channel 9 (114-123): M91-M99
  'Channel 9 pan (00=left, 50=centre, 99=right)',
  'Channel 9 mute (00=off, >00=on)',
  'Channel 9 solo (00=off, >00=on)',
  'Channel 9 volume (00-99)',
  'Channel 9 reserved M95',
  'Channel 9 reserved M96',
  'Channel 9 reserved M97',
  'Channel 9 reserved M98',
  'Channel 9 reserved M99',
  // Channel 10 (124-133): MA1-MA9
  'Channel 10 pan (00=left, 50=centre, 99=right)',
  'Channel 10 mute (00=off, >00=on)',
  'Channel 10 solo (00=off, >00=on)',
  'Channel 10 volume (00-99)',
  'Channel 10 reserved MA5',
  'Channel 10 reserved MA6',
  'Channel 10 reserved MA7',
  'Channel 10 reserved MA8',
  'Channel 10 reserved MA9',
  // Channel 11 (134-143): MB1-MB9
  'Channel 11 pan (00=left, 50=centre, 99=right)',
  'Channel 11 mute (00=off, >00=on)',
  'Channel 11 solo (00=off, >00=on)',
  'Channel 11 volume (00-99)',
  'Channel 11 reserved MB5',
  'Channel 11 reserved MB6',
  'Channel 11 reserved MB7',
  'Channel 11 reserved MB8',
  'Channel 11 reserved MB9',
  // Channel 12 (144-153): MC1-MC9
  'Channel 12 pan (00=left, 50=centre, 99=right)',
  'Channel 12 mute (00=off, >00=on)',
  'Channel 12 solo (00=off, >00=on)',
  'Channel 12 volume (00-99)',
  'Channel 12 reserved MC5',
  'Channel 12 reserved MC6',
  'Channel 12 reserved MC7',
  'Channel 12 reserved MC8',
  'Channel 12 reserved MC9',
  // Channel 13 (154-163): MD1-MD9
  'Channel 13 pan (00=left, 50=centre, 99=right)',
  'Channel 13 mute (00=off, >00=on)',
  'Channel 13 solo (00=off, >00=on)',
  'Channel 13 volume (00-99)',
  'Channel 13 reserved MD5',
  'Channel 13 reserved MD6',
  'Channel 13 reserved MD7',
  'Channel 13 reserved MD8',
  'Channel 13 reserved MD9',
  // Channel 14 (164-173): ME1-ME9
  'Channel 14 pan (00=left, 50=centre, 99=right)',
  'Channel 14 mute (00=off, >00=on)',
  'Channel 14 solo (00=off, >00=on)',
  'Channel 14 volume (00-99)',
  'Channel 14 reserved ME5',
  'Channel 14 reserved ME6',
  'Channel 14 reserved ME7',
  'Channel 14 reserved ME8',
  'Channel 14 reserved ME9',
  // Channel 15 (174-183): MF1-MF9
  'Channel 15 pan (00=left, 50=centre, 99=right)',
  'Channel 15 mute (00=off, >00=on)',
  'Channel 15 solo (00=off, >00=on)',
  'Channel 15 volume (00-99)',
  'Channel 15 reserved MF5',
  'Channel 15 reserved MF6',
  'Channel 15 reserved MF7',
  'Channel 15 reserved MF8',
  'Channel 15 reserved MF9',
  // Master insert routing (184+)
  'Insert 1 param 01 (reserved)',
  'Insert 2 param 01 (reserved)',
  'Insert 3 param 01 (reserved)',
  'Insert 4 param 01 (reserved)',
  'Insert 5 param 01 (reserved)',
  'Insert 6 param 01 (reserved)',
  'Insert 7 param 01 (reserved)',
  'Insert 8 param 01 (reserved)',
  'Insert 9 param 01 (reserved)',
  'Arp config XY (X=octave layers, Y=notes/line, Y0=full cycle)',
  'Slice command — XY: X=mode (0=slice, 1=thru), Y=slice (1-9)',
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
const int kFxARC = 178;
const int kFxSLC = 179;
const int kFxInsertStart = 180;
const int kFxInsertEnd = 239; // 6 slots × 10 functions (0–9) = 60 commands

String fxInsertFunctionName(int function) {
  switch (function) {
    case 0:
      return 'reset — re-applies current slider values to effect';
    case 1:
      return 'bypass (00=active, >00=bypassed)';
    case 2:
      return 'mode / toggle (LP·HP·BP · clip·fold · freeze·free)';
    case 3:
      return 'main param — room size · cutoff · drive · bit depth · push gain (limiter) · rate (chorus) · low gain (EQ) · threshold (cmp)';
    case 4:
      return 'secondary param — damp · resonance · feedback · tone · rate · depth (chorus) · mid gain (EQ) · ratio (cmp)';
    case 5:
      return 'third param — width · hi-pass cutoff · delay (chorus) · high gain (EQ) · makeup (cmp)';
    case 6:
      return 'dry mix (00=no dry, 99=full dry)';
    case 7:
      return 'wet mix (00=no wet, 99=full wet)';
    case 8:
      return 'extra param D';
    case 9:
      return 'extra param E';
    default:
      return 'unknown';
  }
}

bool isInsertFxCommand(int? cmd) =>
    cmd != null && cmd >= kFxInsertStart && cmd <= kFxInsertEnd;

int fxInsertCommand(int slotNumber, int function) {
  final safeSlot = slotNumber.clamp(1, 6);
  final safeFunction = function.clamp(0, 9);
  return kFxInsertStart + ((safeSlot - 1) * 10) + safeFunction;
}

int fxInsertSlotFromCommand(int cmd) => ((cmd - kFxInsertStart) ~/ 10) + 1;

int fxInsertFunctionFromCommand(int cmd) => (cmd - kFxInsertStart) % 10;

/// Returns the 3-letter FX command name, or '---' if null/unknown.
String fxCommandName(int? cmd) {
  if (cmd == null) return '---';
  if (isInsertFxCommand(cmd)) {
    return 'F${fxInsertSlotFromCommand(cmd)}${fxInsertFunctionFromCommand(cmd)}';
  }
  if (cmd < kFxCommandNames.length) return kFxCommandNames[cmd];
  return cmd.toRadixString(16).toUpperCase().padLeft(3, '0');
}

/// Returns the description for an FX command.
String fxCommandDescription(int? cmd) {
  if (cmd == null) return '';
  if (isInsertFxCommand(cmd)) {
    final slot = fxInsertSlotFromCommand(cmd);
    final function = fxInsertFunctionFromCommand(cmd);
    return 'Own-channel insert slot $slot — F$slot$function = ${fxInsertFunctionName(function)}';
  }
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
