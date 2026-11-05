import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stria/main.dart' show paletteNotifier, switchPalette;
import 'package:stria/screens/song_screen.dart';
import 'package:stria/state/app_state.dart';
import 'package:stria/theme/app_theme.dart';

const additions = [
  kPaletteGraphite,
  kPaletteCobalt,
  kPaletteTerracotta,
  kPaletteAubergine,
  kPaletteMoss,
  kPaletteWine,
  kPaletteEspresso,
  kPaletteGlacier,
  kPalettePorcelain,
  kPaletteLinen,
];

double contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  return (math.max(first, second) + 0.05) / (math.min(first, second) + 0.05);
}

void main() {
  tearDown(() {
    applyPalette(kPaletteBlue);
    paletteNotifier.value = kPaletteBlue;
  });

  test('ten new palettes are appended with unique persisted names', () {
    expect(kAllPalettes.length, 30);
    expect(kAllPalettes.take(20).last, kPalettePaper3);
    expect(kAllPalettes.skip(20), additions);
    expect(kAllPalettes.map((p) => p.name).toSet().length, 30);
    expect(additions.where((p) => p.brightness == Brightness.light).length, 2);
  });

  for (final palette in additions) {
    test('${palette.name} has readable, multicolor tracker columns', () {
      final columns = [
        palette.colNote,
        palette.colInst,
        palette.colVol,
        palette.colPan,
        palette.colFxCmd,
        palette.colFxVal,
      ];
      for (final background in [
        palette.bgColor,
        palette.bgBeat,
        palette.bgBar,
        palette.bgSelected,
        palette.bgPlayhead,
      ]) {
        for (final color in columns) {
          expect(
            contrast(color, background),
            greaterThanOrEqualTo(4.5),
            reason: '${palette.name}: $color on $background',
          );
        }
      }
      final hueFamilies = columns
          .map((color) => (HSLColor.fromColor(color).hue / 60).floor())
          .toSet();
      expect(hueFamilies.length, greaterThanOrEqualTo(4));
      expect(palette.bgColor, isNot(palette.bgBeat));
      expect(palette.bgBeat, isNot(palette.bgBar));
      expect(palette.bgSelected, isNot(palette.bgPlayhead));
      expect(
        ThemeData.estimateBrightnessForColor(palette.bgColor),
        palette.brightness,
      );
    });

    test(
      '${palette.name} applies and persists through existing switching',
      () async {
        SharedPreferences.setMockInitialValues({});
        await switchPalette(palette);
        expect(currentPalette, palette);
        expect(paletteNotifier.value, palette);
        expect(kBgColor, palette.bgColor);
        expect(kColNote, palette.colNote);
        expect(kColInst, palette.colInst);
        expect(kColVol, palette.colVol);
        expect(kColPan, palette.colPan);
        expect(kColFxCmd, palette.colFxCmd);
        expect(kColFxVal, palette.colFxVal);
        expect(kColComplement, palette.colComplement);
        expect(buildAppTheme().brightness, palette.brightness);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('tracker_palette'), palette.name);
      },
    );
  }

  testWidgets('palette picker scrolls to and selects the final new palette', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final state = AppState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          )          .copyWith(textScaler: TextScaler.linear(0.4)),
          child: child!,
        ),
        home: AppStateScope(
          state: state,
          child: const Scaffold(body: SongScreen()),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Song actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Color Palette'));
    await tester.pumpAndSettle();
    expect(find.text('Color Palette'), findsOneWidget);
    await tester.ensureVisible(find.text('Linen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Linen'));
    await tester.pumpAndSettle();
    expect(currentPalette, kPaletteLinen);
    expect(find.text('Color Palette'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
