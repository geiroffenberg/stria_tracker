import 'package:flutter/material.dart';
import '../models/cell.dart';

// ── Palette definition ────────────────────────────────────────────────────────

/// All colours used by the app, grouped into a single swappable palette.
class TrackerPalette {
  const TrackerPalette({
    required this.name,
    required this.previewColor,
    this.brightness = Brightness.dark,
    // Backgrounds
    required this.bgColor,
    required this.bgBeat,
    required this.bgBar,
    required this.bgSelected,
    required this.bgPlayhead,
    required this.bgHeader,
    required this.bgTrackHeader,
    required this.bgTopNav,
    // Text / cell colours
    required this.colNote,
    required this.colInst,
    required this.colVol,
    required this.colPan,
    required this.colFxCmd,
    required this.colFxVal,
    required this.colEmpty,
    required this.colRowNum,
    required this.colHeader,
    // UI colours
    required this.colAccent,
    required this.colActive,
    required this.colInactive,
    required this.colSelection,
    required this.colPlayBtn,
    // Complement (used for FX sliders, effect sliders — opposite hue to accent)
    required this.colComplement,
  });

  final String name;
  final Color previewColor; // swatch shown in picker
  final Brightness brightness;

  final Color bgColor;
  final Color bgBeat;
  final Color bgBar;
  final Color bgSelected;
  final Color bgPlayhead;
  final Color bgHeader;
  final Color bgTrackHeader;
  final Color bgTopNav;

  final Color colNote;
  final Color colInst;
  final Color colVol;
  final Color colPan;
  final Color colFxCmd;
  final Color colFxVal;
  final Color colEmpty;
  final Color colRowNum;
  final Color colHeader;

  final Color colAccent;
  final Color colActive;
  final Color colInactive;
  final Color colSelection;
  final Color colPlayBtn;
  final Color colComplement;
}

// ── Built-in palettes ─────────────────────────────────────────────────────────

const TrackerPalette kPaletteBlue = TrackerPalette(
  name: 'Blue',
  previewColor: Color(0xFF66FFFF),
  bgColor: Color(0xFF010810),
  bgBeat: Color(0xFF0A1220),
  bgBar: Color(0xFF111D30),
  bgSelected: Color(0xFF001840),
  bgPlayhead: Color(0xFF002E7A),
  bgHeader: Color(0xFF0A1220),
  bgTrackHeader: Color(0xFF0D1828),
  bgTopNav: Color(0xFF0C1628),
  colNote: Color(0xFF55CCFF),
  colInst: Color(0xFF44AAFF),
  colVol: Color(0xFF33BBDD),
  colPan: Color(0xFF33BBDD),
  colFxCmd: Color(0xFF8899FF),
  colFxVal: Color(0xFFAABBFF),
  colEmpty: Color(0xFF4A6585),
  colRowNum: Color(0xFF7090B0),
  colHeader: Color(0xFF9BBBD8),
  colAccent: Color(0xFF66FFFF),
  colActive: Color(0xFF66B2FF),
  colInactive: Color(0xFF587090),
  colSelection: Color(0xFF44DD88),
  colPlayBtn: Color(0xFF4DA6FF),
  colComplement: Color(0xFFFFAA33),
);

const TrackerPalette kPaletteGreen = TrackerPalette(
  name: 'Green',
  previewColor: Color(0xFF55FF99),
  bgColor: Color(0xFF010101),
  bgBeat: Color(0xFF001A0A),
  bgBar: Color(0xFF002E14),
  bgSelected: Color(0xFF002010),
  bgPlayhead: Color(0xFF003A1C),
  bgHeader: Color(0xFF0A0A0A),
  bgTrackHeader: Color(0xFF0D0D0D),
  bgTopNav: Color(0xFF0C0C0C),
  colNote: Color(0xFF55FF99),
  colInst: Color(0xFF44DD77),
  colVol: Color(0xFF33BB66),
  colPan: Color(0xFF33BB66),
  colFxCmd: Color(0xFF88FF99),
  colFxVal: Color(0xFFAAFFBB),
  colEmpty: Color(0xFF3D6050),
  colRowNum: Color(0xFF5A8A6A),
  colHeader: Color(0xFF90C8A8),
  colAccent: Color(0xFF55FF99),
  colActive: Color(0xFF44CC77),
  colInactive: Color(0xFF446858),
  colSelection: Color(0xFFFFDD44),
  colPlayBtn: Color(0xFF44DD77),
  colComplement: Color(0xFFFF44AA),
);

const TrackerPalette kPaletteRed = TrackerPalette(
  name: 'Red',
  previewColor: Color(0xFFFF6688),
  bgColor: Color(0xFF010101),
  bgBeat: Color(0xFF1A000C),
  bgBar: Color(0xFF2E0016),
  bgSelected: Color(0xFF300008),
  bgPlayhead: Color(0xFF500012),
  bgHeader: Color(0xFF0A0A0A),
  bgTrackHeader: Color(0xFF0D0D0D),
  bgTopNav: Color(0xFF0C0C0C),
  colNote: Color(0xFFFF6688),
  colInst: Color(0xFFFF4466),
  colVol: Color(0xFFDD3355),
  colPan: Color(0xFFDD3355),
  colFxCmd: Color(0xFFFF8899),
  colFxVal: Color(0xFFFFAABB),
  colEmpty: Color(0xFF6A3040),
  colRowNum: Color(0xFF9A5864),
  colHeader: Color(0xFFCC9098),
  colAccent: Color(0xFFFF6688),
  colActive: Color(0xFFFF4466),
  colInactive: Color(0xFF7A3A4A),
  colSelection: Color(0xFF44FFDD),
  colPlayBtn: Color(0xFFFF5577),
  colComplement: Color(0xFF44FFDD),
);

const TrackerPalette kPalettePurple = TrackerPalette(
  name: 'Purple',
  previewColor: Color(0xFFBB66FF),
  bgColor: Color(0xFF010101),
  bgBeat: Color(0xFF0E001A),
  bgBar: Color(0xFF1A002E),
  bgSelected: Color(0xFF1A0038),
  bgPlayhead: Color(0xFF2E0060),
  bgHeader: Color(0xFF0A0A0A),
  bgTrackHeader: Color(0xFF0D0D0D),
  bgTopNav: Color(0xFF0C0C0C),
  colNote: Color(0xFFBB66FF),
  colInst: Color(0xFF9944EE),
  colVol: Color(0xFF8833CC),
  colPan: Color(0xFF8833CC),
  colFxCmd: Color(0xFFCC99FF),
  colFxVal: Color(0xFFDDBBFF),
  colEmpty: Color(0xFF524075),
  colRowNum: Color(0xFF8860A8),
  colHeader: Color(0xFFBB99D8),
  colAccent: Color(0xFFBB66FF),
  colActive: Color(0xFF9944EE),
  colInactive: Color(0xFF5A4075),
  colSelection: Color(0xFF88FF44),
  colPlayBtn: Color(0xFFAA55EE),
  colComplement: Color(0xFF88FF44),
);

const TrackerPalette kPaletteAmber = TrackerPalette(
  name: 'Amber',
  previewColor: Color(0xFFFFCC44),
  bgColor: Color(0xFF010101),
  bgBeat: Color(0xFF1A0D00),
  bgBar: Color(0xFF2E1800),
  bgSelected: Color(0xFF2A1400),
  bgPlayhead: Color(0xFF452200),
  bgHeader: Color(0xFF0A0A0A),
  bgTrackHeader: Color(0xFF0D0D0D),
  bgTopNav: Color(0xFF0C0C0C),
  colNote: Color(0xFFFFCC44),
  colInst: Color(0xFFFFAA22),
  colVol: Color(0xFFDD9911),
  colPan: Color(0xFFDD9911),
  colFxCmd: Color(0xFFFFDD88),
  colFxVal: Color(0xFFFFEEAA),
  colEmpty: Color(0xFF6A5028),
  colRowNum: Color(0xFF9A7540),
  colHeader: Color(0xFFCC9A58),
  colAccent: Color(0xFFFFCC44),
  colActive: Color(0xFFFFAA22),
  colInactive: Color(0xFF756030),
  colSelection: Color(0xFF44AAFF),
  colPlayBtn: Color(0xFFFFBB33),
  colComplement: Color(0xFF6644FF),
);

const TrackerPalette kPaletteRainbow = TrackerPalette(
  name: 'Rainbow',
  previewColor: Color.fromARGB(255, 102, 156, 255),
  bgColor: Color(0xFF07070F),
  bgBeat: Color.fromARGB(255, 43, 36, 0),
  bgBar: Color.fromARGB(255, 43, 36, 0),
  bgSelected: Color(0xFF1A0A1F),
  bgPlayhead: Color.fromARGB(255, 0, 95, 5),
  bgHeader: Color(0xFF0B0B0B),
  bgTrackHeader: Color(0xFF0E0E0E),
  bgTopNav: Color(0xFF0C0C0C),
  colNote: Color.fromARGB(255, 30, 83, 255),
  colInst: Color.fromARGB(255, 202, 108, 19),
  colVol: Color.fromARGB(255, 2, 253, 35),
  colPan: Color(0xFF8AFF66),
  colFxCmd: Color(0xFF66E0FF),
  colFxVal: Color(0xFF6B66FF),
  colEmpty: Color(0xFF574F5F),
  colRowNum: Color(0xFF9E88A8),
  colHeader: Color.fromARGB(255, 240, 224, 4),
  colAccent: Color.fromARGB(255, 3, 255, 3),
  colActive: Color.fromARGB(255, 102, 199, 255),
  colInactive: Color(0xFF6E6E6E),
  colSelection: Color(0xFF66FFCC),
  colPlayBtn: Color(0xFF66FF88),
  colComplement: Color(0xFF44AADD),
);

const TrackerPalette kPaletteSunset = TrackerPalette(
  name: 'Sunset',
  previewColor: Color(0xFFFF7043),
  bgColor: Color(0xFF0F0508),
  bgBeat: Color(0xFF1F0A10),
  bgBar: Color(0xFF2E0F14),
  bgSelected: Color(0xFF3A1020),
  bgPlayhead: Color(0xFF4A1428),
  bgHeader: Color(0xFF120608),
  bgTrackHeader: Color(0xFF150709),
  bgTopNav: Color(0xFF130607),
  colNote: Color(0xFFFF7043),
  colInst: Color(0xFFFFB74D),
  colVol: Color(0xFFFF5C8A),
  colPan: Color(0xFFFF5C8A),
  colFxCmd: Color(0xFFBA68C8),
  colFxVal: Color(0xFFD8A0E0),
  colEmpty: Color(0xFF6B4048),
  colRowNum: Color(0xFFA9707C),
  colHeader: Color(0xFFFFD3A6),
  colAccent: Color(0xFFFFD54F),
  colActive: Color(0xFFFF8A65),
  colInactive: Color(0xFF7A4A50),
  colSelection: Color(0xFF4FC3F7),
  colPlayBtn: Color(0xFFFFCA28),
  colComplement: Color(0xFF29B6F6),
);

const TrackerPalette kPaletteOcean = TrackerPalette(
  name: 'Ocean',
  previewColor: Color(0xFF1DE9B6),
  bgColor: Color(0xFF01100E),
  bgBeat: Color(0xFF042420),
  bgBar: Color(0xFF063530),
  bgSelected: Color(0xFF0A2A2E),
  bgPlayhead: Color(0xFF0F4A42),
  bgHeader: Color(0xFF031512),
  bgTrackHeader: Color(0xFF041815),
  bgTopNav: Color(0xFF031412),
  colNote: Color(0xFF1DE9B6),
  colInst: Color(0xFFFF7F50),
  colVol: Color(0xFFFFD54F),
  colPan: Color(0xFFFFD54F),
  colFxCmd: Color(0xFFBA68C8),
  colFxVal: Color(0xFFE1BEE7),
  colEmpty: Color(0xFF2E5A54),
  colRowNum: Color(0xFF5FA89C),
  colHeader: Color(0xFFB2EBE0),
  colAccent: Color(0xFF00E5A0),
  colActive: Color(0xFFFF8A65),
  colInactive: Color(0xFF3A6660),
  colSelection: Color(0xFFFFEE58),
  colPlayBtn: Color(0xFF1DE9B6),
  colComplement: Color(0xFFFF7F50),
);

const TrackerPalette kPaletteCandy = TrackerPalette(
  name: 'Candy',
  previewColor: Color(0xFFFF6EC7),
  bgColor: Color(0xFF0B0512),
  bgBeat: Color(0xFF190A26),
  bgBar: Color(0xFF241035),
  bgSelected: Color(0xFF2A1040),
  bgPlayhead: Color(0xFF3A1555),
  bgHeader: Color(0xFF0E0616),
  bgTrackHeader: Color(0xFF110818),
  bgTopNav: Color(0xFF0F0716),
  colNote: Color(0xFFFF6EC7),
  colInst: Color(0xFF9C7CFF),
  colVol: Color(0xFF40E0FF),
  colPan: Color(0xFF40E0FF),
  colFxCmd: Color(0xFFFFE066),
  colFxVal: Color(0xFFFFF3B0),
  colEmpty: Color(0xFF5A4570),
  colRowNum: Color(0xFF9880B0),
  colHeader: Color(0xFFE0B8FF),
  colAccent: Color(0xFFFF6EC7),
  colActive: Color(0xFFB388FF),
  colInactive: Color(0xFF5E4A70),
  colSelection: Color(0xFF66FF99),
  colPlayBtn: Color(0xFFFF8AD8),
  colComplement: Color(0xFF66FF99),
);

const TrackerPalette kPaletteForest = TrackerPalette(
  name: 'Forest',
  previewColor: Color(0xFF9CCC65),
  bgColor: Color(0xFF060A03),
  bgBeat: Color(0xFF0E1808),
  bgBar: Color(0xFF16260C),
  bgSelected: Color(0xFF142008),
  bgPlayhead: Color(0xFF203810),
  bgHeader: Color(0xFF080D04),
  bgTrackHeader: Color(0xFF0A1005),
  bgTopNav: Color(0xFF090E04),
  colNote: Color(0xFF9CCC65),
  colInst: Color(0xFF66BB6A),
  colVol: Color(0xFFD4B06A),
  colPan: Color(0xFFD4B06A),
  colFxCmd: Color(0xFFFFA726),
  colFxVal: Color(0xFFFFCC80),
  colEmpty: Color(0xFF3E4A32),
  colRowNum: Color(0xFF7A9060),
  colHeader: Color(0xFFC5E1A5),
  colAccent: Color(0xFFAEEA00),
  colActive: Color(0xFF8BC34A),
  colInactive: Color(0xFF4A5A3A),
  colSelection: Color(0xFFFF7043),
  colPlayBtn: Color(0xFF9CCC65),
  colComplement: Color(0xFFE57373),
);

const TrackerPalette kPaletteNeon = TrackerPalette(
  name: 'Neon',
  previewColor: Color(0xFFFF2E88),
  bgColor: Color(0xFF04040A),
  bgBeat: Color(0xFF0A0A16),
  bgBar: Color(0xFF10102A),
  bgSelected: Color(0xFF1A0A2A),
  bgPlayhead: Color(0xFF2A0A3A),
  bgHeader: Color(0xFF06060E),
  bgTrackHeader: Color(0xFF080810),
  bgTopNav: Color(0xFF07070E),
  colNote: Color(0xFFFF2E88),
  colInst: Color(0xFF00E5FF),
  colVol: Color(0xFFFFEE00),
  colPan: Color(0xFFFFEE00),
  colFxCmd: Color(0xFF9C6BFF),
  colFxVal: Color(0xFFCBB0FF),
  colEmpty: Color(0xFF423A55),
  colRowNum: Color(0xFF8878A8),
  colHeader: Color(0xFFE0E0FF),
  colAccent: Color(0xFF39FF14),
  colActive: Color(0xFF00E5FF),
  colInactive: Color(0xFF4A4468),
  colSelection: Color(0xFFFF6600),
  colPlayBtn: Color(0xFF39FF14),
  colComplement: Color(0xFFFFEE00),
);

const TrackerPalette kPaletteAutumn = TrackerPalette(
  name: 'Autumn',
  previewColor: Color(0xFFE85D30),
  bgColor: Color(0xFF0A0503),
  bgBeat: Color(0xFF1A0D06),
  bgBar: Color(0xFF2A1608),
  bgSelected: Color(0xFF2A1004),
  bgPlayhead: Color(0xFF401A08),
  bgHeader: Color(0xFF0C0704),
  bgTrackHeader: Color(0xFF0F0805),
  bgTopNav: Color(0xFF0D0704),
  colNote: Color(0xFFE85D30),
  colInst: Color(0xFFC1440E),
  colVol: Color(0xFFD4A017),
  colPan: Color(0xFFD4A017),
  colFxCmd: Color(0xFFB5794A),
  colFxVal: Color(0xFFDDB68C),
  colEmpty: Color(0xFF5A4030),
  colRowNum: Color(0xFF9A7050),
  colHeader: Color(0xFFE8C39E),
  colAccent: Color(0xFFFFB627),
  colActive: Color(0xFFE85D30),
  colInactive: Color(0xFF6A5040),
  colSelection: Color(0xFF4FC3F7),
  colPlayBtn: Color(0xFFFFB627),
  colComplement: Color(0xFF4FC3F7),
);

const TrackerPalette kPaletteBaby = TrackerPalette(
  name: 'Baby',
  previewColor: Color(0xFFFFB6E1),
  bgColor: Color(0xFF0A0B12),
  bgBeat: Color(0xFF0F131E),
  bgBar: Color(0xFF161D2A),
  bgSelected: Color(0xFF1A1F32),
  bgPlayhead: Color(0xFF2A3348),
  bgHeader: Color(0xFF0C0D14),
  bgTrackHeader: Color(0xFF0F1017),
  bgTopNav: Color(0xFF0E0F16),
  colNote: Color(0xFFFFB6E1),
  colInst: Color(0xFFFF9ED4),
  colVol: Color(0xFF87CEEB),
  colPan: Color(0xFF87CEEB),
  colFxCmd: Color(0xFFB4D7FF),
  colFxVal: Color(0xFFDDE7FF),
  colEmpty: Color(0xFF5A5E7A),
  colRowNum: Color(0xFF8A90B8),
  colHeader: Color(0xFFC4B0E0),
  colAccent: Color(0xFFFFB6E1),
  colActive: Color(0xFFE091D4),
  colInactive: Color(0xFF6A7090),
  colSelection: Color(0xFFFFFFFF),
  colPlayBtn: Color(0xFFFF9ED4),
  colComplement: Color(0xFF87CEEB),
);

const TrackerPalette kPaletteMono = TrackerPalette(
  name: 'Mono',
  previewColor: Color(0xFFDDDDDD),
  bgColor: Color(0xFF010101),
  bgBeat: Color(0xFF141414),
  bgBar: Color(0xFF222222),
  bgSelected: Color(0xFF252525),
  bgPlayhead: Color(0xFF383838),
  bgHeader: Color(0xFF0A0A0A),
  bgTrackHeader: Color(0xFF0D0D0D),
  bgTopNav: Color(0xFF0C0C0C),
  colNote: Color(0xFFDDDDDD),
  colInst: Color(0xFFBBBBBB),
  colVol: Color(0xFF999999),
  colPan: Color(0xFF999999),
  colFxCmd: Color(0xFFCCCCCC),
  colFxVal: Color(0xFFE0E0E0),
  colEmpty: Color(0xFF525252),
  colRowNum: Color(0xFF787878),
  colHeader: Color(0xFFAAAAAA),
  colAccent: Color(0xFFEEEEEE),
  colActive: Color(0xFFCCCCCC),
  colInactive: Color(0xFF585858),
  colSelection: Color(0xFFFFFFFF),
  colPlayBtn: Color(0xFFCCCCCC),
  colComplement: Color(0xFFAAAAAA),
);

const TrackerPalette kPaletteLight = TrackerPalette(
  name: 'Paper',
  previewColor: Color.fromARGB(255, 252, 251, 251),
  brightness: Brightness.light,
  bgColor: Color(0xFFFFFFFF),
  bgBeat: Color(0xFFF4F4F4),
  bgBar: Color(0xFFE8E8E8),
  bgSelected: Color(0xFFD0E4F8),
  bgPlayhead: Color(0xFFB4CFF0),
  bgHeader: Color(0xFFF8F8F8),
  bgTrackHeader: Color(0xFFF0F0F0),
  bgTopNav: Color(0xFFEAEAEA),
  colNote: Color(0xFF0A0A0A),
  colInst: Color(0xFF1A3A7A),
  colVol: Color(0xFF1A5A1A),
  colPan: Color(0xFF1A5A1A),
  colFxCmd: Color(0xFF7A1A1A),
  colFxVal: Color(0xFF9A3030),
  colEmpty: Color(0xFFBBBBBB),
  colRowNum: Color(0xFF888888),
  colHeader: Color(0xFF222222),
  colAccent: Color(0xFF0A0A0A),
  colActive: Color(0xFF1A4488),
  colInactive: Color(0xFFAAAAAA),
  colSelection: Color(0xFF1A6AFF),
  colPlayBtn: Color(0xFF1A4488),
  colComplement: Color(0xFFAA3300),
);

const TrackerPalette kPaletteLight2 = TrackerPalette(
  name: 'Paper 2',
  previewColor: Color.fromARGB(255, 255, 249, 215),
  brightness: Brightness.light,
  bgColor: Color.fromARGB(255, 255, 249, 215),
  bgBeat: Color.fromARGB(255, 255, 249, 215),
  bgBar: Color.fromARGB(255, 255, 249, 215),
  bgSelected: Color.fromARGB(255, 255, 249, 215),
  bgPlayhead: Color(0xFFB4CFF0),
  bgHeader: Color.fromARGB(255, 255, 249, 215),
  bgTrackHeader: Color.fromARGB(255, 255, 249, 215),
  bgTopNav: Color.fromARGB(255, 255, 249, 215),
  colNote: Color(0xFF0A0A0A),
  colInst: Color(0xFF1A3A7A),
  colVol: Color(0xFF1A5A1A),
  colPan: Color(0xFF1A5A1A),
  colFxCmd: Color(0xFF7A1A1A),
  colFxVal: Color(0xFF9A3030),
  colEmpty: Color(0xFFBBBBBB),
  colRowNum: Color(0xFF888888),
  colHeader: Color(0xFF222222),
  colAccent: Color(0xFF0A0A0A),
  colActive: Color(0xFF1A4488),
  colInactive: Color(0xFFAAAAAA),
  colSelection: Color(0xFF1A6AFF),
  colPlayBtn: Color(0xFF1A4488),
  colComplement: Color(0xFFAA3300),
);

/// All available palettes in display order.
const List<TrackerPalette> kAllPalettes = [
  kPaletteBlue,
  kPaletteGreen,
  kPaletteRed,
  kPalettePurple,
  kPaletteAmber,
  kPaletteRainbow,
  kPaletteSunset,
  kPaletteOcean,
  kPaletteCandy,
  kPaletteForest,
  kPaletteNeon,
  kPaletteAutumn,
  kPaletteBaby,
  kPaletteMono,
  kPaletteLight,
  kPaletteLight2,
];

// ── Active palette — set once at startup, updated by palette picker ───────────

/// The currently active palette. Read by all kCol* / kBg* getters below.
TrackerPalette _palette = kPaletteBlue;

TrackerPalette get currentPalette => _palette;

void applyPalette(TrackerPalette p) {
  _palette = p;
}

// ── Colour getters — same names as before, zero widget changes needed ─────────

Color get kBgColor => _palette.bgColor;
Color get kBgBeat => _palette.bgBeat;
Color get kBgBar => _palette.bgBar;
Color get kBgSelected => _palette.bgSelected;
Color get kBgPlayhead => _palette.bgPlayhead;
Color get kBgHeader => _palette.bgHeader;
Color get kBgTrackHeader => _palette.bgTrackHeader;
Color get kBgTopNav => _palette.bgTopNav;

Color get kColNote => _palette.colNote;
Color get kColInst => _palette.colInst;
Color get kColVol => _palette.colVol;
Color get kColPan => _palette.colPan;
Color get kColFxCmd => _palette.colFxCmd;
Color get kColFxVal => _palette.colFxVal;
Color get kColEmpty => Color.lerp(_palette.colEmpty, _palette.colHeader, 0.3)!;
Color get kColRowNum => _palette.colRowNum;
Color get kColHeader =>
    Color.lerp(_palette.colHeader, _palette.colAccent, 0.18)!;

Color get kColAccent => _palette.colAccent;
Color get kColActive => _palette.colActive;
Color get kColInactive =>
    Color.lerp(_palette.colInactive, _palette.colHeader, 0.48)!;
Color get kColSelection => _palette.colSelection;
Color get kColPlayBtn => _palette.colPlayBtn;
Color get kColComplement => _palette.colComplement;

// These stay fixed — red for stop/rec is a universal convention.
const Color kColStopBtn = Color(0xFFFF6666);
const Color kColRecBtn = Color(0xFFFF4444);

// ── Typography ────────────────────────────────────────────────────────────────

const String kFontMono = 'monospace';
const double kFontSize = 17.0;
const double kRowHeight = 32.0;

const TextStyle kStyleBase = TextStyle(
  fontFamily: kFontMono,
  fontSize: kFontSize,
  height: 1.0,
  letterSpacing: 0.5,
);

// Styles are now getters so they always reflect the active palette.
TextStyle get kStyleNote =>
    kStyleBase.copyWith(color: kColNote, fontWeight: FontWeight.w700);
TextStyle get kStyleInst => kStyleBase.copyWith(color: kColInst);
TextStyle get kStyleVol => kStyleBase.copyWith(color: kColVol);
TextStyle get kStylePan => kStyleBase.copyWith(color: kColPan);
TextStyle get kStyleFxCmd => kStyleBase.copyWith(color: kColFxCmd);
TextStyle get kStyleFxVal => kStyleBase.copyWith(color: kColFxVal);
TextStyle get kStyleEmpty => kStyleBase.copyWith(color: kColEmpty);
TextStyle get kStyleRowNum =>
    kStyleBase.copyWith(color: kColRowNum, fontSize: 14);
TextStyle get kStyleHeader =>
    kStyleBase.copyWith(color: kColHeader, fontSize: 12);
TextStyle get kStyleLabel => kStyleBase.copyWith(
  color: kColAccent,
  fontSize: 15,
  fontWeight: FontWeight.w600,
);

// ── Empty row opacity ────────────────────────────────────────────────────────

const double kEmptyRowOpacity = 0.28;

// ── Column pixel widths ───────────────────────────────────────────────────────

const double kWRow = 36.0;
const double kWNote = 46.0;
const double kWInst = 30.0;
const double kWVol = 30.0;
const double kWPan = 30.0;
const double kWFxCmd = 48.0;
const double kWFxVal = 31.0;
const double kWGap = 4.0;

// ── Helpers ───────────────────────────────────────────────────────────────────

Color columnColor(CellColumn col) {
  switch (col) {
    case CellColumn.note:
      return kColNote;
    case CellColumn.instrument:
      return kColInst;
    case CellColumn.volume:
      return kColVol;
    case CellColumn.fx0cmd:
    case CellColumn.fx1cmd:
    case CellColumn.fx2cmd:
      return kColFxCmd;
    case CellColumn.fx0val:
    case CellColumn.fx1val:
    case CellColumn.fx2val:
      return kColFxVal;
  }
}

TextStyle columnStyle(CellColumn col) =>
    kStyleBase.copyWith(color: columnColor(col));

Color rowBgColor(int row, bool isSelected, bool isPlayhead, int linesPerBeat) {
  if (isPlayhead) return kBgPlayhead;
  if (linesPerBeat > 0 && row % (linesPerBeat * 4) == 0) return kBgBar;
  if (linesPerBeat > 0 && row % linesPerBeat == 0) return kBgBeat;
  return kBgColor;
}

ThemeData buildAppTheme() {
  final isLight = _palette.brightness == Brightness.light;
  final scheme = isLight
      ? ColorScheme.light(
          primary: kColAccent,
          secondary: kColNote,
          surface: kBgColor,
        )
      : ColorScheme.dark(
          primary: kColAccent,
          secondary: kColNote,
          surface: kBgColor,
        );
  return ThemeData(
    brightness: _palette.brightness,
    scaffoldBackgroundColor: kBgColor,
    colorScheme: scheme,
    fontFamily: kFontMono,
    appBarTheme: AppBarTheme(
      backgroundColor: kBgTrackHeader,
      foregroundColor: kColAccent,
      elevation: 0,
      titleTextStyle: TextStyle(
        fontFamily: kFontMono,
        fontSize: 16,
        color: kColAccent,
        letterSpacing: 2,
      ),
    ),
    dividerColor: _palette.bgBar,
    iconTheme: IconThemeData(color: kColAccent, size: 24),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: kColAccent),
    ),
  );
}
