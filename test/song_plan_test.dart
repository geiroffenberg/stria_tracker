import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stria/audio/audio_engine.dart';
import 'package:stria/models/note_value.dart';
import 'package:stria/models/pattern_model.dart';
import 'package:stria/models/song_model.dart';
import 'package:stria/models/song_plan_step.dart';
import 'package:stria/screens/song_plan_screen.dart';
import 'package:stria/screens/song_screen.dart';
import 'package:stria/state/app_state.dart';
import 'package:stria/theme/app_theme.dart';
import 'package:stria/widgets/transport_bar.dart';

PatternModel musicalPattern() {
  final pattern = PatternModel(name: 'Music');
  pattern.tracks.first.cells.first.note = NoteValue.fromScrollIndex(49);
  return pattern;
}

Finder step(int number) =>
    find.byKey(ValueKey('song-plan-step-${number.toString().padLeft(2, '0')}'));

Future<void> showPlan(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    AppStateScope(
      state: state,
      child: MaterialApp(theme: buildAppTheme(), home: const SongPlanScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Color? rowColor(WidgetTester tester, int number) =>
    tester.widget<Text>(planCell(number, 2)).style!.color;

BoxDecoration rowDecoration(WidgetTester tester, int number) =>
    tester.widget<Container>(step(number)).decoration! as BoxDecoration;

Finder planCell(int step, int column) => find.byKey(
  ValueKey('song-plan-cell-${step.toString().padLeft(2, '0')}-$column'),
);

Finder editField(String label) => find.byKey(ValueKey('song-plan-edit-$label'));

void main() {
  const channel = MethodChannel('com.example.tracker/audio');
  final calls = <MethodCall>[];
  var pendingAdvances = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    pendingAdvances = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'consumePendingRowAdvances') {
            final advances = pendingAdvances;
            pendingAdvances = 0;
            return advances;
          }
          if (call.method == 'consumeSongPlanPlaybackStatus') {
            return [0, 1, 0];
          }
          return null;
        });
    await AudioEngine.instance.initialize();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('legacy songs keep the default and custom plans round-trip', () {
    final song = SongModel.initial();
    final legacy = song.toJson();
    expect(legacy.containsKey('songPlan'), isFalse);
    final loaded = SongModel.fromJson(legacy);
    expect(loaded.songPlan, isNull);
    expect(loaded.planStepAt(98), SongPlanStep(patternIndex: 98));

    final plan = List.generate(99, loaded.planStepAt);
    plan[0] = SongPlanStep(
      patternIndex: 2,
      count: 4,
      repeats: 999,
      startLine: 5,
      endLine: 12,
      muteMask: 0x8001,
    );
    loaded.songPlan = plan;
    final restored = SongModel.fromJson(
      jsonDecode(jsonEncode(loaded.toJson())) as Map<String, dynamic>,
    );
    expect(restored.songPlan, orderedEquals(plan));
    expect(restored.planStepAt(1).endLine, isNull);
    expect(SongModel.initial().songPlan, isNull);
    final oldStep = plan[0].toJson()..remove('count');
    expect(SongPlanStep.fromJson(oldStep).count, 1);
    oldStep.remove('muteMask');
    expect(SongPlanStep.fromJson(oldStep).muteMask, 0);
  });

  test('mute toggles cover 16 tracks and preserve all other step fields', () {
    final original = SongPlanStep(
      patternIndex: 2,
      count: 4,
      repeats: 3,
      startLine: 5,
      endLine: 12,
    );
    final muted = original.toggleTrackMute(0).toggleTrackMute(15);
    expect(muted.muteMask, 0x8001);
    expect(muted.isTrackMuted(0), isTrue);
    expect(muted.isTrackMuted(15), isTrue);
    expect(muted.isTrackMuted(1), isFalse);
    expect(muted.toggleTrackMute(0).toggleTrackMute(15), original);
    expect(muted, isNot(original));
    expect({original, muted}, hasLength(2));
    expect(() => original.toggleTrackMute(16), throwsRangeError);
    expect(() => original.isTrackMuted(-1), throwsRangeError);
    expect(
      () => SongPlanStep(patternIndex: 0, muteMask: -1),
      throwsFormatException,
    );
    expect(
      () => SongPlanStep(patternIndex: 0, muteMask: 0x10000),
      throwsFormatException,
    );
  });

  test(
    'mute edits are dirty and undoable without altering live mixer state',
    () {
      final state = AppState();
      addTearDown(state.dispose);
      state.song.patterns.first.tracks[0].mixerMute = true;
      state.song.patterns.first.tracks[1].mixerSolo = true;
      final patterns = jsonEncode(
        state.song.patterns.map((p) => p.toJson()).toList(),
      );
      state.selectSongPlanStep(2);
      state.toggleSongPlanTrackMute(15);
      expect(state.song.planStepAt(2).muteMask, 0x8000);
      expect(state.song.planStepAt(0).muteMask, 0);
      expect(state.hasUnsavedChanges, isTrue);
      state.undoSong();
      expect(state.song.planStepAt(2).muteMask, 0);
      state.redoSong();
      expect(state.song.planStepAt(2).muteMask, 0x8000);
      state.resetSongPlan();
      expect(state.song.planStepAt(2).muteMask, 0);
      state.undoSong();
      expect(state.song.planStepAt(2).muteMask, 0x8000);
      expect(
        jsonEncode(state.song.patterns.map((p) => p.toJson()).toList()),
        patterns,
      );
    },
  );

  test(
    'plan limits reject malformed data instead of silently replacing it',
    () {
      expect(() => SongPlanStep(patternIndex: 99), throwsFormatException);
      expect(() => SongPlanStep(patternIndex: -1), throwsFormatException);
      expect(
        () => SongPlanStep(patternIndex: 0, count: 0),
        throwsFormatException,
      );
      expect(
        () => SongPlanStep(patternIndex: 98, count: 2),
        throwsFormatException,
      );
      expect(SongPlanStep(patternIndex: 0, count: 99).count, 99);
      expect(
        () => SongPlanStep(patternIndex: 0, repeats: 0),
        throwsFormatException,
      );
      expect(
        () => SongPlanStep(patternIndex: 0, repeats: 1000),
        throwsFormatException,
      );
      expect(
        () => SongPlanStep(patternIndex: 0, startLine: 0),
        throwsFormatException,
      );
      expect(
        () => SongPlanStep(patternIndex: 0, startLine: 8, endLine: 4),
        throwsFormatException,
      );
      expect(
        () => SongModel.fromJson({
          ...SongModel.initial().toJson(),
          'songPlan': [],
        }),
        throwsFormatException,
      );
    },
  );

  test('end follows length or caps a fixed limit without discarding it', () {
    final following = SongPlanStep(patternIndex: 0);
    expect(following.effectiveEndLine(16), 16);
    expect(following.effectiveEndLine(32), 32);
    final fixed = SongPlanStep(patternIndex: 0, startLine: 5, endLine: 12);
    expect(fixed.effectiveEndLine(32), 12);
    expect(fixed.effectiveEndLine(8), 8);
    expect(fixed.effectiveEndLine(16), 12);
    expect(fixed.hasValidRange(4), isFalse);
    expect(fixed.startLine, 5);
  });

  test(
    'edits and reset are dirty, undoable, and preserve pattern data',
    () async {
      final state = AppState();
      addTearDown(state.dispose);
      final patterns = jsonEncode(
        state.song.patterns.map((p) => p.toJson()).toList(),
      );
      final originalVersion = state.songStateVersion;
      state.setSongPlanStep(0, SongPlanStep(patternIndex: 0));
      expect(state.songStateVersion, originalVersion);
      expect(state.song.songPlan, isNull);
      final edited = SongPlanStep(patternIndex: 2, repeats: 64);
      state.setSongPlanStep(0, edited);
      calls.clear();
      expect(state.hasUnsavedChanges, isTrue);
      expect(state.undoSongLabel, 'edit song plan');
      state.undoSong();
      expect(state.song.songPlan, isNull);
      state.redoSong();
      expect(state.song.planStepAt(0), edited);
      state.resetSongPlan();
      expect(state.song.songPlan, isNull);
      state.undoSong();
      expect(state.song.planStepAt(0), edited);
      expect(
        jsonEncode(state.song.patterns.map((p) => p.toJson()).toList()),
        patterns,
      );
      expect(calls, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    },
  );

  test('normal project save and reload persist plan and dirty state', () async {
    final directory = await Directory.systemTemp.createTemp('stria-song-plan-');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => directory.path);
    final state = AppState();
    try {
      state.song.name = 'Plan Test';
      state.song.patterns = [musicalPattern(), musicalPattern()];
      final edited = SongPlanStep(
        patternIndex: 0,
        count: 2,
        repeats: 999,
        startLine: 3,
        endLine: 8,
        muteMask: 0x8001,
      );
      state.setSongPlanStep(0, edited);
      state.setSongPlanEnabled(true);
      expect(state.hasUnsavedChanges, isTrue);
      expect(await state.saveSong(), isTrue);
      expect(state.hasUnsavedChanges, isFalse);
      state.resetSongPlan();
      expect(state.hasUnsavedChanges, isTrue);
      await state.play();
      expect(state.playingSongPlan, isTrue);
      expect(await state.loadSongByName('Plan Test'), isTrue);
      expect(state.isPlaying, isFalse);
      expect(state.song.planStepAt(0), edited);
      expect(state.song.songPlanEnabled, isTrue);
      expect(state.hasUnsavedChanges, isFalse);
    } finally {
      state.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(paths, null);
      await directory.delete(recursive: true);
    }
  });

  testWidgets(
    'edit, validate, cancel, and follow end as pattern length changes',
    (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      state.song.patterns = [musicalPattern(), musicalPattern()..beats = 8];
      await showPlan(tester, state);
      await tester.tap(planCell(1, 1));
      await tester.pumpAndSettle();
      await tester.enterText(editField('Pattern'), '2');
      expect(
        tester.widget<TextFormField>(editField('End line')).controller!.text,
        '32',
      );
      await tester.enterText(editField('Start line'), '5');
      await tester.enterText(editField('End line'), '12');
      await tester.enterText(editField('Repeat'), '1000');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a number from 1 to 999.'), findsOneWidget);
      expect(state.song.songPlan, isNull);
      await tester.enterText(editField('Repeat'), '999');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(
        state.song.planStepAt(0),
        SongPlanStep(patternIndex: 1, repeats: 999, startLine: 5, endLine: 12),
      );
      expect(tester.widget<Text>(planCell(1, 1)).data, '02');
      expect(tester.widget<Text>(planCell(1, 3)).data, '12');

      await tester.tap(planCell(1, 1));
      await tester.pumpAndSettle();
      await tester.enterText(editField('Repeat'), '2');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(state.song.planStepAt(0).repeats, 999);

      await tester.tap(planCell(2, 1));
      await tester.pumpAndSettle();
      await tester.enterText(editField('End line'), '99');
      await tester.enterText(editField('Repeat'), '4');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(state.song.planStepAt(1).endLine, isNull);
      state.song.patterns[1].beats = 16;
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(planCell(2, 3)).data, '64');
      expect(tester.widget<Text>(planCell(1, 3)).data, '12');

      state.song.patterns[1].beats = 1;
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(rowColor(tester, 1), kColStopBtn);
      expect(tester.widget<Text>(planCell(1, 2)).data, '5');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('plan OFF keeps highlighting the live Song View position', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(() {
      state.stop();
      state.dispose();
    });
    state.song.patterns = [musicalPattern(), musicalPattern()];
    state.setSongPlanStep(
      0,
      SongPlanStep(patternIndex: 0, count: 2, repeats: 64),
    );
    state.setSongPlanStep(2, SongPlanStep(patternIndex: 0, repeats: 4));
    await showPlan(tester, state);
    await tester.tap(find.text('PLAY'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(state.playheadArrangementSlot, 0);
    expect(rowDecoration(tester, 1).color, kBgPlayhead);
    expect(rowDecoration(tester, 3).color, kBgBeat);
    pendingAdvances = state.song.patterns.first.rowCount;
    await tester.pump(const Duration(milliseconds: 32));
    await tester.pump();
    expect(state.playheadArrangementSlot, 1);
    expect(rowDecoration(tester, 1).color, kBgBeat);
    expect(rowDecoration(tester, 2).color, kBgPlayhead);
    expect(rowDecoration(tester, 3).color, kBgBeat);
    final queued = calls.lastWhere(
      (call) => call.method == 'enqueueAllPlaybackRows',
    );
    expect(
      ((queued.arguments as Map)['rows'] as List).length,
      state.song.patterns.fold<int>(
        0,
        (total, pattern) => total + pattern.rowCount,
      ),
    );
    await tester.tap(find.text('STOP'));
    await tester.pump();
    expect(rowDecoration(tester, 1).color, kBgSelected);
    expect(rowDecoration(tester, 2).color, kBgColor);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing repeats preserves a capped fixed end limit', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    state.song.patterns = [musicalPattern()..beats = 2];
    state.setSongPlanStep(
      0,
      SongPlanStep(patternIndex: 0, endLine: 12, muteMask: 5),
    );
    await showPlan(tester, state);
    expect(tester.widget<Text>(planCell(1, 3)).data, '8');
    await tester.tap(planCell(1, 4));
    await tester.pumpAndSettle();
    await tester.enterText(editField('Repeat'), '4');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(state.song.planStepAt(0).endLine, 12);
    expect(state.song.planStepAt(0).repeats, 4);
    expect(state.song.planStepAt(0).muteMask, 5);
    state.song.patterns[0].beats = 4;
    state.notifyListeners();
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(planCell(1, 3)).data, '12');
    expect(tester.takeException(), isNull);
  });

  testWidgets('reset requires confirmation and can be undone', (tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    final edited = SongPlanStep(patternIndex: 3, repeats: 16);
    state.setSongPlanStep(0, edited);
    await showPlan(tester, state);
    await tester.tap(find.byTooltip('Reset to sequential plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(state.song.planStepAt(0), edited);
    await tester.tap(find.byTooltip('Reset to sequential plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(state.song.songPlan, isNull);
    expect(tester.widget<Text>(planCell(1, 1)).data, '01');
    state.undoSong();
    await tester.pumpAndSettle();
    expect(state.song.planStepAt(0), edited);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Song menu Save writes the plan into the song project', (
    tester,
  ) async {
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('stria-plan-menu-save-'),
    ))!;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => directory.path);
    final state = (await tester.runAsync(() async {
      await File(
        '${directory.path}/app_settings.json',
      ).writeAsString(jsonEncode({'projectRootFolder': directory.path}));
      final state = AppState();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return state;
    }))!;
    try {
      expect(state.hasProjectRootFolder, isTrue);
      state.song.name = 'Saved Plan';
      final edited = SongPlanStep(patternIndex: 4, repeats: 64);
      state.setSongPlanStep(0, edited);
      await showPlan(tester, state);
      expect(find.byTooltip('Save Song'), findsNothing);
      expect(find.byIcon(Icons.save_outlined), findsNothing);
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
      expect(find.byIcon(Icons.restore), findsOneWidget);
      await tester.pumpWidget(
        AppStateScope(
          state: state,
          child: MaterialApp(
            theme: buildAppTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(0.4)),
              child: child!,
            ),
            home: const Scaffold(body: SongScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Song actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save Song'));
        await tester.pumpAndSettle();
        for (var i = 0; i < 100 && state.hasUnsavedChanges; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      });
      await tester.pumpAndSettle();
      expect(state.hasUnsavedChanges, isFalse);
      state.resetSongPlan();
      final loaded = await tester.runAsync(
        () => state.loadSongByName('Saved Plan'),
      );
      expect(loaded, isTrue);
      expect(state.song.planStepAt(0), edited);
      expect(tester.takeException(), isNull);
    } finally {
      state.dispose();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await directory.delete(recursive: true);
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(paths, null);
    }
  });

  testWidgets('empty song shows dimmed row data without changing the project', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    final before = jsonEncode(state.song.toJson());

    await showPlan(tester, state);

    expect(find.text('DEFAULT / SEQUENTIAL'), findsNothing);
    expect(find.textContaining('Loop OFF:'), findsNothing);
    expect(find.textContaining('Read-only preview'), findsNothing);
    expect(find.textContaining('End of song'), findsNothing);
    expect(find.text('NEXT'), findsNothing);
    for (final heading in [
      'STEP',
      'PATTERN',
      'START',
      'END',
      'REPEAT',
      'COUNT',
    ]) {
      expect(find.text(heading), findsOneWidget);
    }
    expect(find.text('SONG'), findsNothing);
    expect(rowColor(tester, 1), kColInactive);
    expect(rowColor(tester, 2), kColInactive);
    expect(tester.widget<Text>(planCell(1, 2)).data, '1');
    expect(tester.widget<Text>(planCell(1, 3)).data, '16');
    expect(tester.widget<Text>(planCell(1, 4)).data, '1');
    expect(tester.widget<Text>(planCell(1, 5)).data, '1');
    expect(jsonEncode(state.song.toJson()), before);
    expect(state.isPlaying, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only empty rows are dimmed and the preview follows edits', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    state.song.patterns = [
      musicalPattern(),
      PatternModel(name: 'Empty'),
      musicalPattern(),
    ];

    await showPlan(tester, state);

    expect(rowColor(tester, 1), kColHeader);
    expect(rowColor(tester, 2), kColInactive);
    expect(rowColor(tester, 3), kColHeader);
    expect(rowColor(tester, 4), kColInactive);

    state.song.patterns[1] = musicalPattern();
    state.notifyListeners();
    await tester.pumpAndSettle();

    expect(rowColor(tester, 2), kColHeader);
    expect(rowColor(tester, 4), kColInactive);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all 99 musical rows display without an end marker', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    state.song.patterns = List.generate(99, (_) => musicalPattern());

    await showPlan(tester, state);
    await tester.scrollUntilVisible(
      step(99),
      500,
      scrollable: find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      ),
    );

    expect(rowColor(tester, 99), kColHeader);
    expect(tester.widget<Text>(planCell(99, 3)).data, '16');
    expect(find.text('End of song - empty song row'), findsNothing);
    expect(find.byType(TransportBar), findsOneWidget);
    expect(find.text('PLAY'), findsOneWidget);
    expect(
      tester.getBottomLeft(find.byType(TransportBar)).dy,
      lessThanOrEqualTo(600),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow screen supports larger text without explanatory text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = AppState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: MaterialApp(
          theme: buildAppTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: const SongPlanScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Loop OFF:'), findsNothing);
    expect(step(1), findsOneWidget);

    state.setLoopPlaybackEnabled(true);
    await tester.pumpAndSettle();

    expect(find.textContaining('Loop ON:'), findsNothing);
    expect(rowColor(tester, 1), kColInactive);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shared transport plays, marks advancing steps, and stops', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(() {
      state.stop();
      state.dispose();
    });
    state.song.patterns = [musicalPattern(), musicalPattern()];
    await showPlan(tester, state);
    expect(rowDecoration(tester, 1).color, kBgSelected);

    await tester.tap(find.text('PLAY'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));

    expect(state.isPlaying, isTrue);
    expect(state.playbackFollowsSong, isTrue);
    expect(calls.any((call) => call.method == 'start'), isTrue);
    expect(find.text('STOP'), findsOneWidget);
    expect(rowDecoration(tester, 1).color, kBgPlayhead);
    expect((rowDecoration(tester, 1).border! as Border).left.color, kColAccent);
    expect(rowDecoration(tester, 2).color, kBgColor);

    pendingAdvances = state.song.patterns.first.rowCount;
    await tester.pump(const Duration(milliseconds: 32));
    await tester.pump();

    expect(state.playheadArrangementSlot, 1);
    expect(rowDecoration(tester, 1).color, kBgBeat);
    expect(rowDecoration(tester, 2).color, kBgPlayhead);

    await tester.tap(find.text('STOP'));
    await tester.pump();

    expect(state.isPlaying, isFalse);
    expect(calls.any((call) => call.method == 'stop'), isTrue);
    expect(find.text('PLAY'), findsOneWidget);
    expect(rowDecoration(tester, 2).color, kBgColor);
    expect(
      (rowDecoration(tester, 2).border! as Border).left.color,
      Colors.transparent,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('pattern-only playback does not mark a song-plan step', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(() {
      state.stop();
      state.dispose();
    });
    state.song.patterns = [musicalPattern()];
    state.setActiveTabIndex(1);
    await state.play();
    await showPlan(tester, state);

    expect(state.isPlaying, isTrue);
    expect(state.playbackFollowsSong, isFalse);
    expect(rowDecoration(tester, 1).color, kBgBeat);
    await tester.tap(find.text('STOP'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Song menu opens the plan and Back returns without mutations', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = AppState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: MaterialApp(
          theme: buildAppTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(0.4)),
            child: child!,
          ),
          home: const Scaffold(body: SongScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = jsonEncode(state.song.toJson());

    await tester.tap(find.byTooltip('Song actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Song Plan'));
    await tester.pumpAndSettle();
    expect(find.byType(SongPlanScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(SongPlanScreen), findsNothing);
    expect(find.byTooltip('Song actions'), findsOneWidget);
    expect(jsonEncode(state.song.toJson()), before);
    expect(state.isPlaying, isFalse);
    expect(tester.takeException(), isNull);
  });
}
