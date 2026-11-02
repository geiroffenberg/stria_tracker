import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stria/audio/audio_engine.dart';
import 'package:stria/models/cell.dart';
import 'package:stria/screens/mixer_screen.dart';
import 'package:stria/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.example.tracker/audio');
  final calls = <MethodCall>[];

  setUp(() async {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getMeterValues') {
            return List<double>.filled(34, 0.0);
          }
          return null;
        });
    await AudioEngine.instance.initialize();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'Flanger exposes every implemented parameter and no unused functions',
    () {
      expect(
        [
          for (var f = 0; f < 10; f++)
            if (fxInsertFunctionIsUsedForEffect('FLANGER', f)) f,
        ],
        [0, 1, 2, 3, 4, 5, 6, 7, 8],
      );
      expect(fxInsertFunctionNameForEffect('FLANGER', 8), 'Feedback');
      expect(fxInsertFunctionShortLabelForEffect('FLANGER', 8), 'FDBK');
      expect(fxInsertFunctionHintForEffect('FLANGER', 8), contains('-95%'));
      expect(fxInsertFunctionNameForEffect('FLANGER', 2), 'Stereo mode');
    },
  );

  test('EQ-5 exposes all five gain controls', () {
    const names = {
      3: 'Bass',
      4: 'Presence',
      5: 'Air',
      8: 'Warmth',
      9: 'Clarity',
    };
    for (final entry in names.entries) {
      expect(fxInsertFunctionIsUsedForEffect('EQ-5', entry.key), isTrue);
      expect(
        fxInsertFunctionNameForEffect('EQ-5', entry.key),
        '${entry.value} gain',
      );
      expect(
        fxInsertFunctionHintForEffect('EQ-5', entry.key),
        contains('-10 dB'),
      );
    }
    expect(fxInsertFunctionIsUsedForEffect('EQ-5', 2), isFalse);
  });

  test('Clipper preserves its legacy identifier and pattern command', () {
    expect(insertEffectDisplayName('LIMITER'), 'CLIPPER');
    expect(fxInsertFunctionIsUsedForEffect('LIMITER', 3), isTrue);
    expect(fxInsertFunctionNameForEffect('LIMITER', 3), 'Input gain');
    expect(insertEffectDisplayName('EQ'), 'EQ');
  });

  test('EQ-5 sends all gains through the track and master bridge', () async {
    await AudioEngine.instance.setTrackEq5Params(2, 4, 1, 2, 3, 4, 5);
    await AudioEngine.instance.setMasterEq5Params(4, -1, -2, -3, -4, -5);
    for (final onMaster in [false, true]) {
      final call = calls.lastWhere(
        (c) =>
            c.method == (onMaster ? 'setMasterEqParams' : 'setTrackEqParams'),
      );
      final args = call.arguments as Map;
      final sign = onMaster ? -1 : 1;
      expect(args['slotIdx'], 4);
      if (!onMaster) expect(args['trackIdx'], 2);
      expect(args['lowGain'], sign * 1 / 12);
      expect(args['warmthGain'], sign * 2 / 12);
      expect(args['midGain'], sign * 3 / 12);
      expect(args['clarityGain'], sign * 4 / 12);
      expect(args['highGain'], sign * 5 / 12);
    }
  });

  test('song reload restores five-band DSP and legacy Clipper on both buses', () async {
    final directory = await Directory.systemTemp.createTemp('stria-insert-');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => directory.path);
    final state = AppState();
    try {
      final slots = [
        {
          'type': 'EQ-5', 'bass': 1.0, 'warmth': 2.0, 'presence': 3.0,
          'clarity': 4.0, 'air': 5.0, 'dry': 0.0, 'wet': 1.0,
        },
        {'type': 'LIMITER', 'gain': 0.25, 'dry': 0.0, 'wet': 1.0},
      ];
      state.setInsertSnapshot({'master': slots, 'tracks': [slots]});
      expect(await state.saveSong(), isTrue);
      calls.clear();
      expect(await state.loadSongByName(state.song.name), isTrue);
      for (final onMaster in [false, true]) {
        final effectCall = calls.firstWhere((call) =>
            call.method == (onMaster ? 'setMasterInsertEffect' : 'setTrackInsertEffect')
            && (call.arguments as Map)['effectType'] == 11);
        expect((effectCall.arguments as Map)['slotIdx'], 0);
        final params = calls.lastWhere((call) =>
            call.method == (onMaster ? 'setMasterEqParams' : 'setTrackEqParams'))
            .arguments as Map;
        expect(params['warmthGain'], 2 / 12);
        expect(params['clarityGain'], 4 / 12);
        final clip = calls.lastWhere((call) =>
            call.method == (onMaster ? 'setMasterLimiterParams' : 'setTrackLimiterParams'))
            .arguments as Map;
        expect(clip['gain'], 0.25);
      }
      expect(state.trackInsertEffectName(0, 0), 'EQ-5');
      expect(state.trackInsertEffectName(0, 1), 'LIMITER');
    } finally {
      state.dispose();
      // Flush the settings write started by save/load before removing its directory.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(paths, null);
      await directory.delete(recursive: true);
    }
  });

  for (final onMaster in [false, true]) {
    testWidgets('EQ-5 ${onMaster ? "master" : "track"} editing and snapshot', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = AppState();
      addTearDown(state.dispose);
      final eq = <String, dynamic>{
        'type': 'EQ-5',
        'bass': 1.0,
        'warmth': 2.0,
        'presence': 3.0,
        'clarity': 4.0,
        'air': 5.0,
        'dry': 0.0,
        'wet': 1.0,
      };
      final clipper = <String, dynamic>{'type': 'LIMITER', 'gain': 0.25};
      state.setInsertSnapshot({
        'master': onMaster ? [eq, clipper] : [],
        'tracks': onMaster
            ? []
            : [
                [eq, clipper],
              ],
      });
      if (!onMaster) {
        state.setTrackInsertEffectName(0, 0, 'EQ-5');
        state.setTrackInsertEffectName(0, 1, 'LIMITER');
      }
      await tester.pumpWidget(
        MaterialApp(
          home: AppStateScope(
            state: state,
            child: const Scaffold(body: MixerScreen()),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('CLIPPER'), findsOneWidget);
      expect(find.text('LIMITER'), findsNothing);
      await tester.tap(find.text('EQ-5'));
      await tester.pumpAndSettle();
      expect(find.text('BASS (120Hz)'), findsOneWidget);
      expect(find.text('AIR (8kHz)'), findsOneWidget);
      final sliders = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(Slider),
      );
      expect(sliders, findsNWidgets(7));
      expect(tester.widget<Slider>(sliders.at(1)).value, 0.6);
      expect(tester.widget<Slider>(sliders.at(3)).value, 0.7);
      tester.widget<Slider>(sliders.at(1)).onChanged!(0.9);
      await tester.pump();
      tester.widget<Slider>(sliders.at(3)).onChanged!(0.2);
      await tester.pump();
      final args =
          calls
                  .lastWhere(
                    (c) =>
                        c.method ==
                        (onMaster ? 'setMasterEqParams' : 'setTrackEqParams'),
                  )
                  .arguments
              as Map;
      expect(args['warmthGain'], closeTo(8 / 12, 1e-10));
      expect(args['clarityGain'], closeTo(-6 / 12, 1e-10));
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await tester.pumpAndSettle();
      final snapshot = state.insertSnapshot;
      final saved = onMaster
          ? (snapshot['master'] as List)[0] as Map
          : ((snapshot['tracks'] as List)[0] as List)[0] as Map;
      expect(saved['warmth'], closeTo(8, 1e-10));
      expect(saved['clarity'], closeTo(-6, 1e-10));
      final savedClipper = onMaster
          ? (snapshot['master'] as List)[1] as Map
          : ((snapshot['tracks'] as List)[0] as List)[1] as Map;
      expect(savedClipper['type'], 'LIMITER');
      expect(savedClipper['gain'], 0.25);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
