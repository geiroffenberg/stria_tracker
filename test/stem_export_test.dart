import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stria/audio/audio_engine.dart';
import 'package:stria/models/cell.dart';
import 'package:stria/models/instrument_model.dart';
import 'package:stria/models/note_value.dart';
import 'package:stria/models/pattern_model.dart';
import 'package:stria/screens/song_screen.dart';
import 'package:stria/state/app_state.dart';

class _StemUiState extends AppState {
  final completion = Completer<({String path, int count})>();

  @override
  bool get hasProjectRootFolder => true;

  @override
  Future<({String path, int count})> exportSongStems({
    void Function(String message)? onProgress,
  }) {
    onProgress?.call('Rendering 16 stems together…');
    return completion.future;
  }
}

Future<void> _openStemConfirmation(WidgetTester tester, AppState state) async {
  tester.view.physicalSize = const Size(1400, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      // Existing long project-menu labels overflow at the default test scale.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(0.4)),
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
  expect(
    tester.getTopLeft(find.text('Export Stems')).dy,
    greaterThan(tester.getTopLeft(find.text('Export WAV')).dy),
  );
  await tester.tap(find.text('Export Stems'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const audio = MethodChannel('com.example.tracker/audio');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final calls = <MethodCall>[];
  late Directory temporary;
  late Directory cache;
  late AppState state;
  var failRender = false;
  Completer<void>? renderGate;

  setUp(() async {
    calls.clear();
    failRender = false;
    renderGate = null;
    temporary = await Directory.systemTemp.createTemp('stria-stems-test-');
    cache = await Directory('${temporary.path}/cache').create();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          paths,
          (call) async => call.method == 'getTemporaryDirectory'
              ? cache.path
              : temporary.path,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audio, (call) async {
          calls.add(call);
          if (call.method == 'renderStemsOffline') {
            if (renderGate != null) await renderGate!.future;
            if (failRender) {
              throw PlatformException(
                code: 'export_failed',
                message: 'Disk full',
              );
            }
            final args = call.arguments as Map;
            for (final name in (args['fileNames'] as List).cast<String>()) {
              if (name.isNotEmpty) {
                await File(
                  '${args['directory']}/$name',
                ).writeAsBytes([1, 2, 3]);
              }
            }
          }
          return null;
        });
    await AudioEngine.instance.initialize();
    state = AppState();
    state.instruments[0].type = InstrumentType.simpleSynth;
    state.currentPattern.tracks[0].cells[0].instrument = 1;
    state.currentPattern.tracks[0].cells[0].note = NoteValue.fromScrollIndex(
      49,
    );
  });

  tearDown(() async {
    state.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audio, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    await temporary.delete(recursive: true);
  });

  test('exports only master buses without changing song or mixer', () async {
    final tracks = state.currentPattern.tracks;
    tracks[0].sendChannel = 4;
    tracks[1].sendChannel = 4;
    tracks[2].name = '../Lead / unsafe?';
    tracks[2].cells[0].note = NoteValue.fromScrollIndex(49);
    tracks[2].cells[0].instrument = 1;
    tracks[0].mixerMute = true;
    tracks[1].mixerSolo = true;
    tracks[3].mixerMute = true;
    state.song.masterMute = true;
    state.song.masterVolume = 0.1;
    state.playheadRow = 5;
    final before = jsonEncode(state.song.toJson());
    final messages = <String>[];
    final saved = await state.exportSongStems(onProgress: messages.add);
    expect(saved.count, 2);
    final render = calls.singleWhere((c) => c.method == 'renderStemsOffline');
    final names = ((render.arguments as Map)['fileNames'] as List)
        .cast<String>();
    expect(names[0], '');
    expect(names[1], '');
    expect(names[2], 'Track_03_Lead_unsafe.wav');
    expect(names[3], startsWith('Track_04'));
    final queued = calls.singleWhere(
      (c) => c.method == 'enqueueAllPlaybackRows',
    );
    final rows = (queued.arguments as Map)['rows'] as List;
    expect(
      ((rows.first as Map)['rowData'] as List).first,
      greaterThanOrEqualTo(0),
    );
    expect(jsonEncode(state.song.toJson()), before);
    expect(state.playheadRow, 5);
    expect(state.isExportingStems, isFalse);
    expect(Directory(saved.path).listSync().length, 2);
    expect(cache.listSync(), isEmpty);
    expect(messages.first, contains('Rendering 2 stems'));
    expect(messages.last, 'Saving stem 2 of 2…');
    expect(calls.where((c) => c.method == 'renderOffline'), isEmpty);
    final second = await state.exportSongStems();
    expect(second.path, isNot(saved.path));
    expect(Directory(saved.path).existsSync(), isTrue);
  });

  test('native failure restores settings and removes staging files', () async {
    state.currentPattern.tracks[0].mixerMute = true;
    final before = jsonEncode(state.song.toJson());
    failRender = true;
    await expectLater(
      state.exportSongStems(),
      throwsA(isA<PlatformException>()),
    );
    expect(state.isExportingStems, isFalse);
    expect(jsonEncode(state.song.toJson()), before);
    expect(cache.listSync(), isEmpty);
    expect(calls.last.method, 'setSendRouting');
    expect(
      calls.where((c) => c.method == 'clearQueuedPlaybackRows'),
      isNotEmpty,
    );
  });

  test('skips unused tracks and empty buses fed only by unused sources', () async {
    state.currentPattern.tracks[1].sendChannel = 5;
    final saved = await state.exportSongStems();
    expect(saved.count, 1);
    final render = calls.singleWhere((c) => c.method == 'renderStemsOffline');
    final names = ((render.arguments as Map)['fileNames'] as List).cast<String>();
    expect(names[0], startsWith('Track_01'));
    expect(names.skip(1).every((name) => name.isEmpty), isTrue);
  });

  test('keeps quiet data in later patterns but ignores data after song end', () async {
    final later = PatternModel(name: 'Later');
    later.tracks[6].cells[3].note = NoteValue.fromScrollIndex(49);
    later.tracks[6].cells[3].instrument = 1;
    later.tracks[6].cells[3].volume = 0;
    final excluded = PatternModel(name: 'After separator');
    excluded.tracks[8].cells[0].note = NoteValue.fromScrollIndex(49);
    state.song.patterns.addAll([
      later,
      PatternModel(name: 'Separator'),
      excluded,
    ]);
    final saved = await state.exportSongStems();
    expect(saved.count, 2);
    final render = calls.singleWhere((c) => c.method == 'renderStemsOffline');
    final names = ((render.arguments as Map)['fileNames'] as List).cast<String>();
    expect(names[6], startsWith('Track_07'));
    expect(names[8], '');
  });

  for (final (command, destination) in [
    (kFxSN1, 13),
    (kFxSN2, 14),
    (kFxSN3, 15),
  ]) {
    test('keeps an empty parallel return for send $command from a routed source', () async {
      state.currentPattern.tracks[0].sendChannel = 4;
      final later = PatternModel(name: 'Later send');
      later.tracks[0].cells[2].fxSlots[0].command = command;
      later.tracks[0].cells[2].fxSlots[0].value = 1;
      state.song.patterns.add(later);
      final saved = await state.exportSongStems();
      expect(saved.count, 2);
      final render = calls.singleWhere((c) => c.method == 'renderStemsOffline');
      final names = ((render.arguments as Map)['fileNames'] as List).cast<String>();
      expect(names[0], '');
      expect(names[3], startsWith('Track_04'));
      expect(names[destination], isNotEmpty);
      expect(names.where((name) => name.isNotEmpty).length, 2);
    });
  }

  test('disabled parallel sends do not create unused return files', () async {
    final fx = state.currentPattern.tracks[0].cells[0].fxSlots;
    for (var i = 0; i < 3; i++) {
      fx[i].command = [kFxSN1, kFxSN2, kFxSN3][i];
      fx[i].value = i == 0 ? null : 0;
    }
    expect((await state.exportSongStems()).count, 1);
  });

  for (final muted in [false, true]) {
    test(
      'master mute=$muted and gain cannot suppress regular or delayed stem notes',
      () async {
        state.song.masterMute = muted;
        state.song.masterVolume = 0.1;
        final cells = state.currentPattern.tracks[0].cells;
        cells[0].volume = 99;
        cells[1].instrument = 1;
        cells[1].note = NoteValue.fromScrollIndex(50);
        cells[1].volume = 99;
        cells[1].fxSlots[0].command = kFxDEL;
        cells[1].fxSlots[0].value = 50;
        await state.exportSongStems();
        final queued = calls.singleWhere(
          (c) => c.method == 'enqueueAllPlaybackRows',
        );
        final rows = (queued.arguments as Map)['rows'] as List;
        final first = (rows[0] as Map)['rowData'] as List;
        expect(first.take(2), [60, 255]);
        expect(((rows[1] as Map)['rowData'] as List).first, -1);
        expect((rows[1] as Map)['delayData'], [50, 0, 61, 255]);
        expect(state.song.masterMute, muted);
        expect(state.song.masterVolume, 0.1);
      },
    );
  }

  test('storage failure cleans partial output and reports the error', () async {
    // Turn the expected project parent into a file so directory creation fails.
    await File('${temporary.path}/songs').writeAsString('not a directory');
    await expectLater(
      state.exportSongStems(),
      throwsA(isA<FileSystemException>()),
    );
    expect(state.isExportingStems, isFalse);
    expect(cache.listSync(), isEmpty);
  });

  test(
    'rejects playback, empty songs, no outputs and unsupported chains',
    () async {
      state.isPlaying = true;
      await expectLater(state.exportSongStems(), throwsStateError);
      state.isPlaying = false;
      state.currentPattern.tracks[0].cells[0].note = NoteValue.empty;
      state.currentPattern.tracks[0].cells[0].instrument = null;
      await expectLater(state.exportSongStems(), throwsStateError);
      state.currentPattern.tracks[0].cells[0].note = NoteValue.fromScrollIndex(
        49,
      );
      state.currentPattern.tracks[0].cells[0].instrument = 1;
      for (final track in state.currentPattern.tracks) {
        track.sendChannel = 1;
      }
      await expectLater(state.exportSongStems(), throwsStateError);
      state.currentPattern.tracks[0].sendChannel = 2;
      state.currentPattern.tracks[1].sendChannel = 3;
      state.currentPattern.tracks[2].sendChannel = 0;
      await expectLater(state.exportSongStems(), throwsStateError);
      expect(calls.where((c) => c.method == 'renderStemsOffline'), isEmpty);
    },
  );

  test('prevents a second export or playback while rendering', () async {
    renderGate = Completer<void>();
    final pending = state.exportSongStems();
    while (!calls.any((c) => c.method == 'renderStemsOffline')) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(state.isExportingStems, isTrue);
    await expectLater(state.exportSongStems(), throwsStateError);
    await state.play();
    expect(state.isPlaying, isFalse);
    state.stop();
    renderGate!.complete();
    await pending;
    expect(state.isExportingStems, isFalse);
  });

  testWidgets('menu explains stem exclusions and cancel does not export', (
    tester,
  ) async {
    await _openStemConfirmation(tester, state);
    expect(
      find.textContaining(
        'Master effects, master volume and master safety limiter are excluded.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Mute and Solo are ignored.'), findsOneWidget);
    expect(find.textContaining('32-bit float'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'renderStemsOffline'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final fails in [false, true]) {
    testWidgets('progress closes after ${fails ? 'failure' : 'success'}', (
      tester,
    ) async {
      state.dispose();
      final ui = _StemUiState();
      state = ui;
      await _openStemConfirmation(tester, state);
      await tester.tap(find.text('Export'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Exporting Stems'), findsOneWidget);
      expect(find.text('Rendering 16 stems together…'), findsOneWidget);
      final scope = tester.widget<PopScope>(find.byType(PopScope));
      expect(scope.canPop, isFalse);
      if (fails) {
        ui.completion.completeError(
          PlatformException(code: 'export_failed', message: 'Disk full'),
        );
      } else {
        ui.completion.complete((path: '/project/stems_123', count: 16));
      }
      await tester.pumpAndSettle();
      expect(find.text('Exporting Stems'), findsNothing);
      expect(
        find.text(
          fails
              ? 'Stem export failed: Disk full'
              : 'Saved 16 stems: /project/stems_123',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
