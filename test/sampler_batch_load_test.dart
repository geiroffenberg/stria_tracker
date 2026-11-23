import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stria/audio/audio_engine.dart';
import 'package:stria/models/instrument_model.dart';
import 'package:stria/screens/instrument_screen.dart';
import 'package:stria/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const audio = MethodChannel('com.example.tracker/audio');
  const storage = MethodChannel('plugins.flutter.io/path_provider');
  final calls = <MethodCall>[];
  late Directory directory;
  late AppState state;
  String? rejectedPath;
  Completer<bool>? pendingLoad;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('stria-sampler-batch-');
    calls.clear();
    rejectedPath = null;
    pendingLoad = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(storage, (_) async => directory.path);
    messenger.setMockMethodCallHandler(audio, (call) async {
      calls.add(call);
      if (call.method == 'setSamplerSample') {
        if (pendingLoad != null) return pendingLoad!.future;
        return (call.arguments as Map)['path'] != rejectedPath;
      }
      return null;
    });
    await AudioEngine.instance.initialize();
    state = AppState();
    state.setInstrumentType(0, InstrumentType.sampler);
    await state.setDefaultSampleFolder(directory.path);
  });

  tearDown(() async {
    state.dispose();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(audio, null);
    messenger.setMockMethodCallHandler(storage, null);
    await directory.delete(recursive: true);
  });

  Future<String> sample(String name) async {
    final file = File('${directory.path}/$name');
    file.writeAsBytesSync(List<int>.filled(44, 0));
    return file.path;
  }

  List<Map> loads() => calls
      .where((call) => call.method == 'setSamplerSample')
      .map((call) => call.arguments as Map)
      .toList();

  Future<void> openBrowser(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: MaterialApp(
          theme: ThemeData(
            bottomSheetTheme: const BottomSheetThemeData(
              constraints: BoxConstraints(maxWidth: 360),
            ),
          ),
          home: const Scaffold(body: InstrumentScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.folder_open));
    await tester.pumpAndSettle();
  }

  Finder row(String name) =>
      find.ancestor(of: find.text(name), matching: find.byType(ListTile));

  Future<void> check(WidgetTester tester, String name) async {
    await tester.tap(
      find.descendant(of: row(name), matching: find.byType(Checkbox)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('sampler Glide knob changes the saved parameter', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(home: Scaffold(body: InstrumentScreen())),
      ),
    );
    await tester.pumpAndSettle();
    final glide = find.text('GLIDE');
    await tester.ensureVisible(glide);
    await tester.pumpAndSettle();
    await tester.drag(glide, const Offset(0, -30));
    await tester.pumpAndSettle();
    expect(state.currentInstrument.sampler.glide, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  test(
    'single loading preserves parameters and updates only the target',
    () async {
      final path = await sample('kick.wav');
      state.currentInstrument.sampler.volume = 0.4;
      expect(await state.loadSamplerSampleFromPath(path), isNull);
      expect(loads().single, {'slot': 0, 'path': path});
      expect(state.currentInstrument.sampler.sampleName, 'kick.wav');
      expect(state.currentInstrument.sampler.volume, 0.4);
      expect(state.instruments[1].type, InstrumentType.empty);
    },
  );

  test('loader captures its slot before awaiting the engine', () async {
    final path = await sample('kick.wav');
    pendingLoad = Completer<bool>();
    final loading = state.loadSamplerSampleFromPath(path);
    await Future<void>.delayed(Duration.zero);
    state.selectInstrument(3);
    pendingLoad!.complete(true);
    expect(await loading, isNull);
    expect(state.instruments[0].sampler.samplePath, path);
    expect(state.instruments[3].sampler.samplePath, isNull);
    expect(state.currentInstrumentIndex, 3);
  });

  test('batch skips occupied slots, wraps and preserves selection', () async {
    final last = state.instruments.length - 1;
    state.selectInstrument(last);
    state.setInstrumentType(last, InstrumentType.sampler);
    state.setInstrumentType(1, InstrumentType.simpleSynth);
    final paths = [
      await sample('kick.wav'),
      await sample('snare.wav'),
      await sample('hat.wav'),
    ];
    final result = await state.loadSamplerSamplesFromPaths(paths);
    expect(result, (loaded: 3, error: null));
    expect(loads().map((args) => args['slot']), [last, 2, 3]);
    expect(loads().map((args) => args['path']), paths);
    expect(state.instruments[0].type, InstrumentType.sampler);
    expect(state.instruments[0].sampler.samplePath, isNull);
    expect(state.instruments[1].type, InstrumentType.simpleSynth);
    expect(state.currentInstrumentIndex, last);
  });

  test('insufficient capacity does not load anything', () async {
    for (var i = 1; i < state.instruments.length; i++) {
      state.setInstrumentType(i, InstrumentType.simpleSynth);
    }
    final paths = [await sample('kick.wav'), await sample('snare.wav')];
    final result = await state.loadSamplerSamplesFromPaths(paths);
    expect(result.loaded, 0);
    expect(result.error, contains('Nothing loaded'));
    expect(loads(), isEmpty);
    expect(state.currentInstrument.sampler.samplePath, isNull);
  });

  test('a failed file stops the batch without occupying its slot', () async {
    final paths = [
      await sample('kick.wav'),
      await sample('bad.wav'),
      await sample('hat.wav'),
    ];
    rejectedPath = paths[1];
    final result = await state.loadSamplerSamplesFromPaths(paths);
    expect(result.loaded, 1);
    expect(result.error, contains('bad.wav'));
    expect(result.error, contains('Loaded 1 of 3'));
    expect(loads().length, 2);
    expect(state.instruments[0].sampler.samplePath, paths[0]);
    expect(state.instruments[1].type, InstrumentType.empty);
    expect(state.instruments[2].type, InstrumentType.empty);
  });

  test('missing files and invalid slots return explicit errors', () async {
    expect(
      await state.loadSamplerSampleFromPath('${directory.path}/missing.wav'),
      'File not found',
    );
    expect(
      await state.loadSamplerSampleFromPath('unused', slot: -1),
      'Invalid instrument slot',
    );
    expect(
      (await state.loadSamplerSamplesFromPaths([])).error,
      'No samples selected',
    );
    expect(loads(), isEmpty);
  });

  testWidgets('bottom batch action uses list order, not checkbox order', (
    tester,
  ) async {
    final first = await sample('a.wav');
    final second = await sample('b.wav');
    await openBrowser(tester);
    expect(find.textContaining('LOAD SELECTED'), findsNothing);
    await check(tester, 'b.wav');
    await check(tester, 'a.wav');
    final batch = find.text('LOAD SELECTED (2)');
    expect(batch, findsOneWidget);
    expect(
      tester.getCenter(batch).dy,
      greaterThan(tester.getCenter(row('b.wav')).dy),
    );
    await tester.tap(batch);
    await tester.pumpAndSettle();
    expect(loads().map((args) => args['path']), [first, second]);
    expect(loads().map((args) => args['slot']), [0, 1]);
    expect(find.byTooltip('Close sample browser'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('row LOAD ignores checked samples', (tester) async {
    final first = await sample('a.wav');
    await sample('b.wav');
    await openBrowser(tester);
    await check(tester, 'b.wav');
    await tester.tap(
      find.descendant(of: row('a.wav'), matching: find.text('LOAD')),
    );
    await tester.pumpAndSettle();
    expect(loads().single, {'slot': 0, 'path': first});
    expect(state.instruments[1].type, InstrumentType.empty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('changing folders clears selection', (tester) async {
    await sample('a.wav');
    Directory('${directory.path}/subfolder').createSync();
    await openBrowser(tester);
    await check(tester, 'a.wav');
    await tester.tap(find.text('subfolder'));
    await tester.pumpAndSettle();
    expect(find.textContaining('LOAD SELECTED'), findsNothing);
    await tester.tap(find.byTooltip('Close sample browser'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('loading locks browser controls until the batch finishes', (
    tester,
  ) async {
    await sample('a.wav');
    await openBrowser(tester);
    await check(tester, 'a.wav');
    pendingLoad = Completer<bool>();
    await tester.tap(find.text('LOAD SELECTED (1)'));
    await tester.pump();
    expect(find.text('LOADING...'), findsOneWidget);
    expect(
      tester
          .widget<Checkbox>(
            find.descendant(of: row('a.wav'), matching: find.byType(Checkbox)),
          )
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton &&
                  widget.tooltip == 'Close sample browser',
            ),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'LOAD'))
          .onPressed,
      isNull,
    );
    pendingLoad!.complete(true);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close sample browser'), findsNothing);
    expect(loads().length, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('capacity errors keep the browser open without loading', (
    tester,
  ) async {
    await sample('a.wav');
    await sample('b.wav');
    for (var i = 1; i < state.instruments.length; i++) {
      state.setInstrumentType(i, InstrumentType.simpleSynth);
    }
    await openBrowser(tester);
    await check(tester, 'a.wav');
    await check(tester, 'b.wav');
    await tester.tap(find.text('LOAD SELECTED (2)'));
    await tester.pumpAndSettle();
    expect(loads(), isEmpty);
    expect(find.textContaining('Nothing loaded'), findsOneWidget);
    expect(find.byTooltip('Close sample browser'), findsOneWidget);
    await tester.tap(find.byTooltip('Close sample browser'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'partial failure closes the browser and reports the failed file',
    (tester) async {
      final first = await sample('a.wav');
      rejectedPath = await sample('b.wav');
      await openBrowser(tester);
      await check(tester, 'a.wav');
      await check(tester, 'b.wav');
      await tester.tap(find.text('LOAD SELECTED (2)'));
      await tester.pumpAndSettle();
      expect(state.instruments[0].sampler.samplePath, first);
      expect(state.instruments[1].type, InstrumentType.empty);
      expect(find.byTooltip('Close sample browser'), findsNothing);
      expect(
        find.textContaining('Loaded 1 of 2 samples. Stopped at b.wav'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
