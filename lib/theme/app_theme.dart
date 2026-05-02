import 'package:flutter/material.dart';
import '../models/cell.dart';

// ── Colours ──────────────────────────────────────────────────────────────────

const Color kBgColor = Color(0xFF010810); // near-black with blue tint
const Color kBgBeat = Color(0xFF0A1220); // beat-start rows
const Color kBgBar = Color(0xFF111D30); // bar-start rows (every 16)
const Color kBgSelected = Color(0xFF002060);
const Color kBgPlayhead = Color(0xFF003A8C);
const Color kBgHeader = Color(0xFF0A1220);
const Color kBgTrackHeader = Color(0xFF0D1828);
const Color kBgTopNav = Color(0xFF0C1628); // muted navy-blue — separates nav from content

// Text colours — all blue-family
const Color kColNote = Color(0xFF55CCFF); // sky blue
const Color kColInst = Color(0xFF44AAFF); // medium blue
const Color kColVol = Color(0xFF33BBDD); // teal-blue
const Color kColPan = Color(0xFF33BBDD); // teal-blue
const Color kColFxCmd = Color(0xFF8899FF); // blue-violet
const Color kColFxVal = Color(0xFFAABBFF); // light blue-violet

const Color kColEmpty = Color(0xFF2A3F5C); // dim blue-grey
const Color kColRowNum = Color(0xFF4D6B8A); // mid blue-grey
const Color kColHeader = Color(0xFF7A9FBF); // lighter blue-grey

const Color kColAccent = Color(0xFF66FFFF); // bright cyan
const Color kColActive = Color(0xFF66B2FF);
const Color kColInactive = Color(0xFF3A5570); // blue-grey (replaces neutral grey)
const Color kColSelection = Color(0xFF44DD88); // green selection border
const Color kColPlayBtn = Color(0xFF4DA6FF);
const Color kColStopBtn = Color(0xFFFF6666); // keep red — universal stop convention
const Color kColRecBtn = Color(0xFFFF4444); // keep red — universal rec convention

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

TextStyle kStyleNote = kStyleBase.copyWith(
  color: kColNote,
  fontWeight: FontWeight.w700,
);
TextStyle kStyleInst = kStyleBase.copyWith(color: kColInst);
TextStyle kStyleVol = kStyleBase.copyWith(color: kColVol);
TextStyle kStylePan = kStyleBase.copyWith(color: kColPan);
TextStyle kStyleFxCmd = kStyleBase.copyWith(color: kColFxCmd);
TextStyle kStyleFxVal = kStyleBase.copyWith(color: kColFxVal);
TextStyle kStyleEmpty = kStyleBase.copyWith(color: kColEmpty);
TextStyle kStyleRowNum = kStyleBase.copyWith(color: kColRowNum, fontSize: 14);
TextStyle kStyleHeader = kStyleBase.copyWith(color: kColHeader, fontSize: 12);
TextStyle kStyleLabel = kStyleBase.copyWith(
  color: kColAccent,
  fontSize: 15,
  fontWeight: FontWeight.w600,
);

// ── Column pixel widths (expanded view fits ~390dp portrait) ──────────────────

const double kWRow = 36.0; // "63"
const double kWNote = 46.0; // "C#4"
const double kWInst = 30.0; // "FF"
const double kWVol = 30.0;
const double kWPan = 30.0;
const double kWFxCmd = 48.0; // "ARP"
const double kWFxVal = 31.0; // "99" 
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
  return kBgColor;
}

ThemeData buildAppTheme() => ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: kBgColor,
  colorScheme: const ColorScheme.dark(
    primary: kColAccent,
    secondary: kColNote,
    surface: kBgColor,
  ),
  fontFamily: kFontMono,
  appBarTheme: const AppBarTheme(
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
  dividerColor: const Color(0xFF1A2D44),
  iconTheme: const IconThemeData(color: kColAccent, size: 24),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(foregroundColor: kColAccent),
  ),
);
