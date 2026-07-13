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

  /// 2-digit hex display for FX values (00–FF), or '--' if empty.
  static String fxValueDisplay(int? v) =>
      v == null ? '--' : v.clamp(0, 255).toRadixString(16).toUpperCase().padLeft(2, '0');
}

/// Fixed command ID → 3-letter display name.
/// IDs are stable: inserting a new entry never shifts any existing command.
/// Mixer (32–194), insert FX (kFxInsertStart–kFxInsertEnd), and Pxx params
/// (kFxPParamStart–kFxPParamEnd) are resolved by their own helpers first.
/// To add a new FX command: pick an unused ID above 206 and add it here.
const Map<int, String> kFxCommandNames = {
  // ── Classic FX (0–9) ─────────────────────────────────────────────────
   0: 'ARP', //  arpeggio
   1: 'CHA', //  chance
   2: 'DEL', //  delay
   3: 'KIL', //  kill note
   4: 'PAN', //  stereo pan
   5: 'RAN', //  randomise
   6: 'RET', //  retrigger
   7: 'REV', //  reverse
   8: 'VIB', //  vibrato
   9: 'VOL', //  volume ramp
  // ── Instrument synth FX (10–15) ──────────────────────────────────────
  10: 'A01',  11: 'A02',  12: 'A03',  13: 'A04',  14: 'A05',  15: 'A06',
  // ── Instrument sample FX (16–21) ─────────────────────────────────────
  16: 'S01',  17: 'S02',  18: 'S03',  19: 'S04',  20: 'S05',  21: 'S06',
  // ── Sample slice select (22–31) ──────────────────────────────────────
  22: 'SL0',  23: 'SL1',  24: 'SL2',  25: 'SL3',  26: 'SL4',
  27: 'SL5',  28: 'SL6',  29: 'SL7',  30: 'SL8',  31: 'SL9',
  // ── Mixer (32–194) — handled by isMixerValueCommand / mixerValueName ─
  // (no entries here; adding them would be unreachable)
  // ── Arp config / slice command (203–204) ─────────────────────────────
  203: 'ARC', // arp config: X=octave layers, Y=notes per line
  204: 'SLC', // slice command: X=mode (0=slice,1=thru), Y=slice index
  // ── New classic FX — add below; IDs never shift existing entries ──────
  205: 'SLU', // slide up:   X=lines, Y=semitones
  206: 'SLD', // slide down: X=lines, Y=semitones
  207: 'TRE', // tremolo: XY speed+depth, sine wave volume LFO
  208: 'GAT', // gate: XY speed+depth, square wave volume LFO
};

/// Fixed command ID → full description string. Same key space as kFxCommandNames.
/// Mixer and insert FX descriptions come from their own helper functions.
const Map<int, String> kFxCommandDescriptions = {
   0: 'Arpeggio — XY: X=1st interval, Y=2nd interval (1-9 = semitones above root)',
   1: 'Chance — 00=never play, 99=always play, 50=50% chance',
   2: 'Delay — 00=line start, 99=line end (note-on offset within row)',
   3: 'Kill — cut note at % through row (00=immediate, 99=end of row)',
   4: 'Pan — set stereo position (00=left, 50=centre, 99=right)',
   5: 'Random slice — 00=off, 01-99=chance % to pick a random active slice',
   6: 'Retrigger — XY: X=volume curve, Y=retrigs per line',
   7: 'Reverse — play sample/slice backwards',
   8: 'Vibrato — XY: X=speed (0-9), Y=depth (0-9), pitch LFO',
   9: 'Volume — set level for this row only (00=silent, 99=full)',
  10: 'Synth FX A01 (reserved)',
  11: 'Synth FX A02 (reserved)',
  12: 'Synth FX A03 (reserved)',
  13: 'Synth FX A04 (reserved)',
  14: 'Synth FX A05 (reserved)',
  15: 'Synth FX A06 (reserved)',
  16: 'Sample FX S01 (reserved)',
  17: 'Sample FX S02 (reserved)',
  18: 'Sample FX S03 (reserved)',
  19: 'Sample FX S04 (reserved)',
  20: 'Sample FX S05 (reserved)',
  21: 'Sample FX S06 (reserved)',
  22: 'Select Slice 0 (sample start)',
  23: 'Select Slice 1',
  24: 'Select Slice 2',
  25: 'Select Slice 3',
  26: 'Select Slice 4',
  27: 'Select Slice 5',
  28: 'Select Slice 6',
  29: 'Select Slice 7',
  30: 'Select Slice 8',
  31: 'Select Slice 9',
  // Mixer (32–194) descriptions → mixerValueDescription(cmd)
  203: 'Arp config XY (X=octave layers, Y=notes/line, Y0=full cycle)',
  204: 'Slice command — XY: X=mode (0=slice, 1=thru), Y=slice (1-9)',
  205: 'Slide Up — XY: X=lines to slide over (1-9), Y=semitones up (1-9)',
  206: 'Slide Down — XY: X=lines to slide over (1-9), Y=semitones down (1-9)',
  207: 'Tremolo — XY: X=speed (0-9), Y=depth (0-9), sine wave volume LFO',
  208: 'Gate — XY: X=speed (0-9), Y=depth (0-9), square wave volume gate',
  // ── Add new FX descriptions below ────────────────────────────────────
};

/// FX command ID constants — match the keys in kFxCommandNames / kFxCommandDescriptions.
/// These are the stable integers stored in pattern data. Never renumber them.
const int kFxARP =   0;
const int kFxCHA =   1;
const int kFxDEL =   2;
const int kFxKIL =   3;
const int kFxPAN =   4;
const int kFxRAN =   5;
const int kFxRET =   6;
const int kFxREV =   7;
const int kFxVIB =   8;
const int kFxVOL =   9;
// Instrument FX: A-series (10–15), S-series (16–21)
// Slice select: SL0 (22) … SL9 (31)
const int kFxSL0 =  22;
const int kFxSL9 =  31;
// Mixer (32–194) handled by isMixerValueCommand / mixerValueName
const int kFxARC = 203; // arp config
const int kFxSLC = 204; // slice command
const int kFxSLU = 205; // slide up:   X=lines, Y=semitones
const int kFxSLD = 206; // slide down: X=lines, Y=semitones
const int kFxTRE = 207; // tremolo: XY speed+depth, sine wave volume LFO
const int kFxGAT = 208; // gate: XY speed+depth, square wave volume LFO
// → To add a new FX: pick an ID > 208, add to kFxCommandNames + kFxCommandDescriptions
const int kFxInsertStart = 340;
const int kFxInsertEnd = 399; // 6 slots × 10 functions (0–9) = 60 commands

// Instrument parameter automation (Pxx).
// P00 = reset to snapshot. P01–P99 = per-type param slots.
// Sampler:  P01=start, P02=end, P03=pitch, P04=volume, P05=attack, P06=release, P07=loop
//           P12=loopStart, P13=loopEnd
// Synth:    P01=volume, P02=attack, P03=decay, P04=sustain, P05=release,
//           P06=cutoff, P07=resonance, P08=drive, P09=detune, P10=glide,
//           P11=lfoRate, P12=lfoDepth, P13=waveform
const int kFxPParamStart = 240; // P00
const int kFxPParamEnd = 339; // P99

bool isPParamCommand(int? cmd) =>
    cmd != null && cmd >= kFxPParamStart && cmd <= kFxPParamEnd;

bool isMixerValueCommand(int? cmd) => cmd != null && cmd >= 32 && cmd <= 194;

String _mixerChannelCode(int channel) {
  if (channel <= 9) return '$channel';
  final letter = String.fromCharCode('A'.codeUnitAt(0) + (channel - 10));
  return letter;
}

String mixerValueName(int cmd) {
  if (cmd == 194) return 'M00';
  if (cmd == 32) return 'M01';
  if (cmd == 33) return 'M02';
  final offset = cmd - 34;
  if (offset < 0) {
    return cmd.toRadixString(16).toUpperCase().padLeft(3, '0');
  }
  final channel = (offset ~/ 10) + 1;
  final slot = (offset % 10) + 1;
  if (channel < 1 || channel > 16) {
    return cmd.toRadixString(16).toUpperCase().padLeft(3, '0');
  }
  final slotCode = slot == 10 ? '0' : '$slot';
  return 'M${_mixerChannelCode(channel)}$slotCode';
}

String mixerValueDescription(int cmd) {
  if (cmd == 194) return 'Master reset — re-apply current mixer snapshot';
  if (cmd == 32) return 'Master mute (00=off, >00=on)';
  if (cmd == 33) return 'Master volume (00-99)';
  final offset = cmd - 34;
  final channel = (offset ~/ 10) + 1;
  final slot = (offset % 10) + 1;
  if (channel < 1 || channel > 16) return '';
  switch (slot) {
    case 1:
      return 'Channel $channel pan (00=left, 50=centre, 99=right)';
    case 2:
      return 'Channel $channel mute (00=off, >00=on)';
    case 3:
      return 'Channel $channel solo (00=off, >00=on)';
    case 4:
      return 'Channel $channel volume (00-99)';
    case 10:
      return 'Channel $channel reset — re-apply current mixer snapshot';
    default:
      return 'Channel $channel reserved ${mixerValueName(cmd)}';
  }
}

String mixerValueShortLabel(int cmd) {
  if (cmd == 194) return 'RESET';
  if (cmd == 32) return 'MUTE';
  if (cmd == 33) return 'VOL';

  final offset = cmd - 34;
  final slot = (offset % 10) + 1;
  switch (slot) {
    case 1:
      return 'PAN';
    case 2:
      return 'MUTE';
    case 3:
      return 'SOLO';
    case 4:
      return 'VOL';
    case 10:
      return 'RESET';
    default:
      return 'RES';
  }
}

/// Returns 0 for P00, 1 for P01, …, 99 for P99.  -1 if not a Pxx command.
int pParamIndex(int? cmd) =>
    (cmd != null && isPParamCommand(cmd)) ? cmd - kFxPParamStart : -1;

String fxInsertFunctionName(int function) {
  switch (function) {
    case 0:
      return 'reset';
    case 1:
      return 'bypass';
    case 2:
      return 'mode / toggle';
    case 3:
      return 'main param';
    case 4:
      return 'secondary param';
    case 5:
      return 'third param';
    case 6:
      return 'dry mix';
    case 7:
      return 'wet mix';
    case 8:
      return 'extra param D';
    case 9:
      return 'extra param E';
    default:
      return 'unknown';
  }
}

String fxInsertFunctionNameForEffect(String? effectName, int function) {
  final fx = (effectName ?? '').toUpperCase();
  switch (function) {
    case 0:
      return 'Reset to snapshot';
    case 1:
      return 'Bypass on/off';
    case 6:
      return 'Dry mix';
    case 7:
      return 'Wet mix';
  }
  switch (fx) {
    case 'REVERB':
      switch (function) {
        case 2:
          return 'Freeze';
        case 3:
          return 'Room size';
        case 4:
          return 'Damp';
        case 5:
          return 'Width';
      }
      break;
    case 'DELAY':
      switch (function) {
        case 2:
          return 'Sync';
        case 3:
          return 'Timing';
        case 4:
          return 'Feedback';
        case 5:
          return 'High-pass cutoff';
      }
      break;
    case 'FILTER':
      switch (function) {
        case 2:
          return 'Mode (LP/HP/BP)';
        case 3:
          return 'Cutoff';
        case 4:
          return 'Resonance';
      }
      break;
    case 'DISTORTION':
      switch (function) {
        case 2:
          return 'Type';
        case 3:
          return 'Drive';
        case 4:
          return 'Tone';
      }
      break;
    case 'BITCRUSHER':
      switch (function) {
        case 3:
          return 'Bit depth';
        case 4:
          return 'Sample rate';
      }
      break;
    case 'LIMITER':
      switch (function) {
        case 3:
          return 'Input gain';
      }
      break;
    case 'CHORUS':
      switch (function) {
        case 2:
          return 'Stereo mode';
        case 3:
          return 'Rate';
        case 4:
          return 'Depth';
        case 5:
          return 'Delay';
      }
      break;
    case 'EQ':
      switch (function) {
        case 3:
          return 'Low gain';
        case 4:
          return 'Mid gain';
        case 5:
          return 'High gain';
      }
      break;
    case 'COMPRESSOR':
      switch (function) {
        case 2:
          return 'Knee';
        case 3:
          return 'Threshold';
        case 4:
          return 'Ratio';
        case 5:
          return 'Makeup gain';
      }
      break;
  }
  return fxInsertFunctionName(function);
}

String fxInsertFunctionHintForEffect(String? effectName, int function) {
  final name = fxInsertFunctionNameForEffect(effectName, function);
  switch (function) {
    case 0:
      return '$name - trigger command (value ignored; use 00)';
    case 1:
      return '$name - 00=off, 01-99=on';
    case 2:
      return '$name - mode/select (00-99)';
    case 3:
    case 4:
    case 5:
    case 6:
    case 7:
    case 8:
    case 9:
      return '$name - 00-99 amount';
    default:
      return '$name - 00-99';
  }
}

String fxInsertFunctionShortLabelForEffect(String? effectName, int function) {
  final fx = (effectName ?? '').toUpperCase();
  switch (function) {
    case 0:
      return 'RESET';
    case 1:
      return 'BYP';
    case 6:
      return 'DRY';
    case 7:
      return 'WET';
  }

  switch (fx) {
    case 'REVERB':
      switch (function) {
        case 2:
          return 'FREEZE';
        case 3:
          return 'ROOM';
        case 4:
          return 'DAMP';
        case 5:
          return 'WIDTH';
      }
      break;
    case 'DELAY':
      switch (function) {
        case 2:
          return 'SYNC';
        case 3:
          return 'TIME';
        case 4:
          return 'FDBK';
        case 5:
          return 'HP';
      }
      break;
    case 'FILTER':
      switch (function) {
        case 2:
          return 'MODE';
        case 3:
          return 'CUTOFF';
        case 4:
          return 'RESO';
      }
      break;
    case 'DISTORTION':
      switch (function) {
        case 2:
          return 'TYPE';
        case 3:
          return 'DRIVE';
        case 4:
          return 'TONE';
      }
      break;
    case 'BITCRUSHER':
      switch (function) {
        case 3:
          return 'BITS';
        case 4:
          return 'RATE';
      }
      break;
    case 'LIMITER':
      if (function == 3) return 'PUSH';
      break;
    case 'CHORUS':
      switch (function) {
        case 2:
          return 'STEREO';
        case 3:
          return 'RATE';
        case 4:
          return 'DEPTH';
        case 5:
          return 'DELAY';
      }
      break;
    case 'EQ':
      switch (function) {
        case 3:
          return 'LOW';
        case 4:
          return 'MID';
        case 5:
          return 'HIGH';
      }
      break;
    case 'COMPRESSOR':
      switch (function) {
        case 2:
          return 'KNEE';
        case 3:
          return 'THRESH';
        case 4:
          return 'RATIO';
        case 5:
          return 'MAKEUP';
      }
      break;
  }

  return fxInsertFunctionName(function).toUpperCase();
}

bool fxInsertFunctionIsUsedForEffect(String? effectName, int function) {
  // Common insert controls available for all effects.
  if (function == 0 || function == 1 || function == 6 || function == 7) {
    return true;
  }

  final fx = (effectName ?? '').toUpperCase();
  switch (fx) {
    case 'REVERB':
    case 'DELAY':
    case 'CHORUS':
    case 'COMPRESSOR':
      return function >= 2 && function <= 5;
    case 'FILTER':
    case 'DISTORTION':
    case 'BITCRUSHER':
    case 'EQ':
      return function >= 3 && function <= 4;
    case 'LIMITER':
      return function == 3;
    default:
      // Unknown effect: keep full function set visible for safety.
      return function >= 0 && function <= 9;
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
  if (isMixerValueCommand(cmd)) {
    return mixerValueName(cmd);
  }
  if (isInsertFxCommand(cmd)) {
    return 'F${fxInsertSlotFromCommand(cmd)}${fxInsertFunctionFromCommand(cmd)}';
  }
  if (isPParamCommand(cmd)) {
    return 'P${pParamIndex(cmd).toString().padLeft(2, '0')}';
  }
  return kFxCommandNames[cmd] ??
      cmd.toRadixString(16).toUpperCase().padLeft(3, '0');
}

/// Returns the description for an FX command.
String fxCommandDescription(int? cmd) {
  if (cmd == null) return '';
  if (isMixerValueCommand(cmd)) {
    return mixerValueDescription(cmd);
  }
  if (isInsertFxCommand(cmd)) {
    final slot = fxInsertSlotFromCommand(cmd);
    final function = fxInsertFunctionFromCommand(cmd);
    return 'Own-channel insert slot $slot — F$slot$function = ${fxInsertFunctionName(function)}';
  }
  if (isPParamCommand(cmd)) {
    final idx = pParamIndex(cmd);
    if (idx == 0) {
      return 'P00 — reset instrument params to original slider values';
    }
    return 'P${idx.toString().padLeft(2, '0')} — instrument param (meaning set by instrument type in IN cell)';
  }
  return kFxCommandDescriptions[cmd] ?? '';
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
