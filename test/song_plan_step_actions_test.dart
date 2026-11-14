import 'dart:convert';

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
import 'package:stria/state/app_state.dart';
import 'package:stria/theme/app_theme.dart';

PatternModel music() {
  final pattern = PatternModel(name: 'Music');
  pattern.tracks.first.cells.first.note = NoteValue.fromScrollIndex(49);
  return pattern;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.example.tracker/audio');
  final calls = <MethodCall>[];
  late AppState state;
  final detailed = SongPlanStep(
    patternIndex: 2,
    count: 3,
    repeats: 4,
    startLine: 2,
    endLine: 8,
    muteMask: 0x8001,
  );
  Finder action(String label) =>
      find.byKey(ValueKey('song-plan-action-$label'));
  Finder field(String label) => find.byKey(ValueKey('song-plan-edit-$label'));
  List<SongPlanStep> steps() => List.generate(99, state.song.planStepAt);
  String patterns() =>
      jsonEncode(state.song.patterns.map((p) => p.toJson()).toList());

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'consumeSongPlanPlaybackStatus') return [0, 1, 0];
          return null;
        });
    await AudioEngine.instance.initialize();
    state = AppState();
    state.song.patterns = List.generate(5, (_) => music());
  });

  tearDown(() async {
    state.stop();
    state.dispose();
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const SongPlanScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test(
    'moves swap entire steps, follow selection, and undo/redo atomically',
    () {
      state.setSongPlanStep(1, detailed);
      state.selectSongPlanStep(1);
      final before = steps();
      final beforePatterns = patterns();
      final version = state.songStateVersion;
      calls.clear();
      state.moveSongPlanStep(-1);
      expect(state.selectedSongPlanStep, 0);
      expect(state.song.planStepAt(0), detailed);
      expect(state.song.planStepAt(1), before[0]);
      expect(steps().skip(2), before.skip(2));
      expect(state.songStateVersion, version + 1);
      expect(state.undoSongLabel, 'move song plan step');
      expect(state.hasUnsavedChanges, isTrue);
      state.undoSong();
      expect(steps(), before);
      expect(state.selectedSongPlanStep, 1);
      state.redoSong();
      expect(state.song.planStepAt(0), detailed);
      expect(state.selectedSongPlanStep, 0);
      state.moveSongPlanStep(1);
      expect(steps(), before);
      expect(patterns(), beforePatterns);
      expect(calls, isEmpty);
      expect(SongModel.fromJson(state.song.toJson()).songPlan, steps());
    },
  );

  test(
    'insert shifts without changing references and restores automatic plan on undo',
    () {
      final before = steps();
      final beforePatterns = patterns();
      state.selectSongPlanStep(1);
      state.insertSongPlanStepAfter(detailed);
      expect(state.song.songPlan, hasLength(99));
      expect(state.selectedSongPlanStep, 2);
      expect(steps().take(2), before.take(2));
      expect(state.song.planStepAt(2), detailed);
      expect(steps().skip(3), before.skip(2).take(96));
      expect(state.undoSongLabel, 'insert song plan step');
      state.undoSong();
      expect(state.song.songPlan, isNull);
      expect(state.selectedSongPlanStep, 1);
      state.redoSong();
      expect(state.song.planStepAt(2), detailed);
      expect(state.selectedSongPlanStep, 2);
      expect(patterns(), beforePatterns);
      expect(SongModel.fromJson(state.song.toJson()).songPlan, steps());
    },
  );

  test('insert protects music and custom settings in last row', () {
    state.setSongPlanStep(98, SongPlanStep(patternIndex: 0));
    final before = steps();
    expect(state.songPlanInsertError, contains('step 99'));
    expect(() => state.insertSongPlanStepAfter(detailed), throwsStateError);
    expect(steps(), before);
    state.setSongPlanStep(98, SongPlanStep(patternIndex: 98, muteMask: 1));
    expect(() => state.insertSongPlanStepAfter(detailed), throwsStateError);
    state.setSongPlanStep(
      98,
      SongPlanStep(patternIndex: 98, count: 1, repeats: 2),
    );
    expect(() => state.insertSongPlanStepAfter(detailed), throwsStateError);
    state.setSongPlanStep(98, SongPlanStep(patternIndex: 98));
    expect(state.songPlanInsertError, isNull);
    state.selectSongPlanStep(98);
    expect(() => state.insertSongPlanStepAfter(detailed), throwsStateError);
  });

  test(
    'delete shifts, uses empty tail, preserves patterns, and supports undo/redo',
    () {
      state.setSongPlanStep(2, detailed);
      state.selectSongPlanStep(1);
      final before = steps();
      final beforePatterns = patterns();
      calls.clear();
      state.deleteSongPlanStep();
      expect(state.selectedSongPlanStep, 1);
      expect(state.song.songPlan, hasLength(99));
      expect(state.song.planStepAt(1), detailed);
      expect(steps().take(98), [...before.take(1), ...before.skip(2)]);
      expect(state.song.planStepAt(98), SongPlanStep(patternIndex: 98));
      expect(state.undoSongLabel, 'delete song plan step');
      state.undoSong();
      expect(steps(), before);
      state.redoSong();
      expect(state.song.planStepAt(1), detailed);
      expect(patterns(), beforePatterns);
      expect(calls, isEmpty);
      state.selectSongPlanStep(98);
      state.deleteSongPlanStep();
      expect(state.selectedSongPlanStep, 98);
      expect(state.song.planStepAt(98), SongPlanStep(patternIndex: 98));
    },
  );

  test(
    'delete finds an empty pattern or refuses a completely populated song',
    () {
      state.song.patterns = List.generate(99, (_) => music());
      final before = steps();
      expect(state.songPlanDeleteError, contains('all 99 patterns'));
      expect(() => state.deleteSongPlanStep(), throwsStateError);
      expect(steps(), before);
      expect(state.song.songPlan, isNull);
      state.song.patterns[7] = PatternModel(name: 'Empty');
      state.deleteSongPlanStep();
      expect(state.song.planStepAt(98), SongPlanStep(patternIndex: 7));
      expect(state.songPlanInsertError, isNull);
    },
  );

  test(
    'boundaries and playback guards reject mutations without changing history',
    () {
      expect(() => state.moveSongPlanStep(-1), throwsRangeError);
      expect(() => state.moveSongPlanStep(0), throwsArgumentError);
      state.selectSongPlanStep(98);
      expect(() => state.moveSongPlanStep(1), throwsRangeError);
      state.selectSongPlanStep(0);
      expect(state.song.songPlan, isNull);
      expect(state.canUndoSong, isFalse);
      state.isPlaying = true;
      expect(() => state.moveSongPlanStep(1), throwsStateError);
      expect(() => state.insertSongPlanStepAfter(detailed), throwsStateError);
      expect(() => state.deleteSongPlanStep(), throwsStateError);
      expect(state.song.songPlan, isNull);
      expect(state.canUndoSong, isFalse);
      state.isPlaying = false;
      state.moveSongPlanStep(1);
      state.isPlaying = true;
      expect(state.canUndoSong, isFalse);
      state.undoSong();
      expect(state.song.planStepAt(1).patternIndex, 0);
      state.isPlaying = false;
      state.undoSong();
      state.isPlaying = true;
      expect(state.canRedoSong, isFalse);
    },
  );

  testWidgets(
    'permanent action bar moves selection and leaves long press unused',
    (tester) async {
      await show(tester);
      for (final label in ['UP', 'DOWN', 'INS', 'DEL']) {
        expect(action(label), findsOneWidget);
      }
      expect(tester.widget<GestureDetector>(action('UP')).onTap, isNull);
      await tester.tap(action('DOWN'));
      await tester.pumpAndSettle();
      expect(state.selectedSongPlanStep, 1);
      expect(find.text('STEP 02 MUTES'), findsOneWidget);
      await tester.tap(action('UP'));
      await tester.pumpAndSettle();
      expect(state.selectedSongPlanStep, 0);
      final beforeLongPress = steps();
      final stepCell = find.byKey(const ValueKey('song-plan-cell-02-0'));
      expect(
        tester
            .widget<GestureDetector>(
              find
                  .ancestor(
                    of: stepCell,
                    matching: find.byType(GestureDetector),
                  )
                  .first,
            )
            .onLongPress,
        isNull,
      );
      await tester.longPress(stepCell);
      await tester.pumpAndSettle();
      expect(steps(), beforeLongPress);
      expect(find.byType(AlertDialog), findsNothing);
      state.selectSongPlanStep(98);
      await tester.pumpAndSettle();
      expect(tester.widget<GestureDetector>(action('DOWN')).onTap, isNull);
      expect(tester.widget<GestureDetector>(action('INS')).onTap, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'insert cancel is unchanged; apply inserts edited defaults without copying mutes',
    (tester) async {
      state.setSongPlanStep(0, detailed);
      final before = steps();
      await show(tester);
      await tester.tap(action('INS'));
      await tester.pumpAndSettle();
      expect(find.text('Insert after step 01'), findsOneWidget);
      expect(
        tester.widget<TextFormField>(field('Pattern')).controller!.text,
        '3',
      );
      expect(
        tester.widget<TextFormField>(field('Repeat')).controller!.text,
        '1',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(steps(), before);
      await tester.tap(action('INS'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Repeat'), '7');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(state.selectedSongPlanStep, 1);
      expect(
        state.song.planStepAt(1),
        SongPlanStep(patternIndex: 2, repeats: 7),
      );
      expect(state.song.planStepAt(2), before[1]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'delete confirms and cancels; stale confirmation cannot delete a different step',
    (tester) async {
      await show(tester);
      final before = steps();
      await tester.tap(action('DEL'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(steps(), before);
      await tester.tap(action('DEL'));
      await tester.pumpAndSettle();
      state.selectSongPlanStep(1);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(steps(), before);
      expect(
        find.text('Song or step changed. Reopen the step action.'),
        findsOneWidget,
      );
      await tester.tap(action('DEL'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(state.song.planStepAt(1), before[2]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('bar fits narrow screens and is disabled during playback', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(tester);
    state.setSongPlanEnabled(true);
    await state.playSongPlan();
    await tester.pump();
    for (final label in ['UP', 'DOWN', 'INS', 'DEL']) {
      expect(tester.widget<GestureDetector>(action(label)).onTap, isNull);
    }
    state.stop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
