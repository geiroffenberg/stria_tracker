import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stria/audio/audio_engine.dart';
import 'package:stria/models/cell.dart';
import 'package:stria/models/instrument_model.dart';
import 'package:stria/models/note_value.dart';
import 'package:stria/models/pattern_model.dart';
import 'package:stria/models/song_model.dart';
import 'package:stria/models/song_plan_step.dart';
import 'package:stria/screens/song_plan_screen.dart';
import 'package:stria/screens/song_screen.dart';
import 'package:stria/screens/pattern_screen.dart';
import 'package:stria/screens/mixer_screen.dart';
import 'package:stria/widgets/collapsed_tracks_widget.dart';
import 'package:stria/state/app_state.dart';
import 'package:stria/theme/app_theme.dart';

PatternModel pattern(int note, {int lines = 16}) {
  final result = PatternModel(name: 'Music', beats: 1, linesPerBeat: lines);
  for (var i = 0; i < lines; i++) {
    result.tracks[0].cells[i]
      ..note = NoteValue.fromScrollIndex(note + i)
      ..instrument = 1;
  }
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const audio = MethodChannel('com.example.tracker/audio');
  final calls = <MethodCall>[];
  var advances = 0;
  var running = true;
  var underrun = false;
  var legacyAdvances = 0;
  Completer<void>? uploadGate;
  late AppState state;

  List<Map<String, dynamic>> rowsFor(String method) =>
      ((calls.lastWhere((call) => call.method == method).arguments
                  as Map)['rows']
              as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();

  setUp(() async {
    calls.clear();
    advances = 0;
    legacyAdvances = 0;
    running = true;
    underrun = false;
    uploadGate = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audio, (call) async {
          calls.add(call);
          if (call.method == 'consumeSongPlanPlaybackStatus') {
            final result = [advances, running ? 1 : 0, underrun ? 1 : 0];
            advances = 0;
            return result;
          }
          if (call.method == 'consumePendingRowAdvances') {
            final result = legacyAdvances;
            legacyAdvances = 0;
            return result;
          }
          if (call.method == 'scheduleNextLoopRows' && uploadGate != null) {
            await uploadGate!.future;
          }
          return null;
        });
    await AudioEngine.instance.initialize();
    state = AppState();
    state.instruments[0].type = InstrumentType.simpleSynth;
  });

  tearDown(() async {
    state.stop();
    state.dispose();
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audio, null);
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
    await tester.pump();
  }

  Finder cell(int step, int column) => find.byKey(
    ValueKey('song-plan-cell-${step.toString().padLeft(2, '0')}-$column'),
  );

  Color? background(WidgetTester tester, int step) =>
      (tester
                  .widget<Container>(
                    find.byKey(
                      ValueKey(
                        'song-plan-step-${step.toString().padLeft(2, '0')}',
                      ),
                    ),
                  )
                  .decoration!
              as BoxDecoration)
          .color;

  test('old songs default OFF and saving retains the mode', () {
    final legacy = SongModel.initial().toJson()..remove('songPlanEnabled');
    expect(SongModel.fromJson(legacy).songPlanEnabled, isFalse);
    state.setSongPlanEnabled(true);
    expect(state.hasUnsavedChanges, isTrue);
    expect(SongModel.fromJson(state.song.toJson()).songPlanEnabled, isTrue);
    state.undoSong();
    expect(state.song.songPlanEnabled, isFalse);
    state.redoSong();
    expect(state.song.songPlanEnabled, isTrue);
  });

  testWidgets(
    'Song track indicators follow executing plan mutes without changing live state',
    (tester) async {
      state.song.patterns = [pattern(40, lines: 2)];
      state.setSongPlanStep(0, SongPlanStep(patternIndex: 0, muteMask: 1));
      state.setSongPlanStep(1, SongPlanStep(patternIndex: 0, muteMask: 0x8000));
      state.toggleTrackMixerMute(2);
      state.toggleTrackMixerSolo(0);
      state.setSongPlanEnabled(true);
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
      String? status(int track) => tester
          .widget<Text>(find.byKey(ValueKey('song-track-status-$track')))
          .data;
      expect(status(0), 'S');
      expect(status(2), 'M');
      expect(status(15), '16');
      expect(state.isTrackEffectivelyMuted(0), isFalse);
      await state.playSongPlan();
      await tester.pump();
      expect(status(0), 'M'); // Plan mute wins over live solo.
      expect(status(2), 'M');
      expect(status(15), '16'); // Prepared later steps do not affect display.
      expect(state.song.patterns.first.tracks[0].mixerMute, isFalse);
      advances = 2;
      await tester.pump(const Duration(milliseconds: 32));
      await tester.pump();
      expect(state.selectedSongPlanStep, 0);
      expect(state.playingSongPlanStep, 1);
      expect(status(0), 'S');
      expect(status(15), 'M');
      await tester.longPress(
        find.byKey(const ValueKey('song-track-status-15')),
      );
      await tester.pump();
      expect(status(0), '1');
      expect(status(2), '3');
      expect(status(15), 'M'); // Live reset does not erase plan settings.
      expect(state.song.planStepAt(1).muteMask, 0x8000);
      state.toggleTrackMixerMute(2);
      state.stop();
      await tester.pump();
      expect(status(2), 'M');
      expect(status(15), '16');
      expect(state.isTrackEffectivelyMuted(15), isFalse);
      state.setSongPlanEnabled(false);
      await state.play();
      await tester.pump();
      expect(status(0), '1');
      expect(status(15), '16');
      expect(status(2), 'M');
      state.stop();
      state.setSongPlanEnabled(true);
      state.setActiveTabIndex(1);
      await state.play();
      await tester.pump();
      expect(state.playingSongPlan, isFalse);
      expect(status(0), '1');
      expect(status(15), '16');
      state.stop();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Pattern, collapsed and Mixer displays include plan mutes only while playing',
    (tester) async {
      state.song.patterns = [pattern(40, lines: 2)];
      state.setSongPlanStep(0, SongPlanStep(patternIndex: 0, muteMask: 1));
      state.setSongPlanEnabled(true);
      await state.playSongPlan();
      Future<void> display(Widget screen) async {
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
              home: Scaffold(body: screen),
            ),
          ),
        );
        await tester.pump();
      }

      await display(const PatternScreen());
      expect(find.text('M'), findsOneWidget);
      await display(const CollapsedTracksWidget());
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('collapsed-track-status-0')),
            )
            .data,
        'M',
      );
      await display(const MixerScreen());
      expect(
        tester.widget<Text>(find.text('M').at(1)).style!.color,
        kColRecBtn,
      );
      state.stop();
      await tester.pump();
      expect(
        tester.widget<Text>(find.text('M').at(1)).style!.color,
        kMixerLabelColor,
      );
      expect(state.song.patterns.first.tracks[0].mixerMute, isFalse);
      await display(const CollapsedTracksWidget());
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('collapsed-track-status-0')),
            )
            .data,
        'T01',
      );
      await display(const PatternScreen());
      expect(find.text('M'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'iterator follows steps, partial lines, repeats, then loops from 01',
    () {
      state.song.patterns = [pattern(40), pattern(60)];
      state.setSongPlanStep(
        0,
        SongPlanStep(patternIndex: 1, startLine: 4, endLine: 6, repeats: 2),
      );
      state.setSongPlanStep(
        1,
        SongPlanStep(patternIndex: 0, startLine: 2, endLine: 3),
      );
      final positions = state.song.songPlanPositions(1).take(12).toList();
      expect(positions.take(2).map((p) => p.stepIndex), [1, 1]);
      expect(positions.take(2).map((p) => p.line), [2, 3]);
      expect(positions[1].planEnd, isTrue);
      expect(positions[2].stepIndex, 0);
      expect(positions.skip(2).take(6).map((p) => p.line), [4, 5, 6, 4, 5, 6]);
      expect(positions.skip(2).take(6).map((p) => p.pass), [1, 1, 1, 2, 2, 2]);
      expect(positions.where((p) => p.planEnd).length, 2);
    },
  );

  test(
    'count repeats the whole pattern group before advancing one plan step',
    () {
      state.song.patterns = [pattern(40, lines: 4), pattern(60, lines: 3)];
      state.setSongPlanStep(
        0,
        SongPlanStep(
          patternIndex: 0,
          count: 2,
          startLine: 2,
          endLine: 4,
          repeats: 2,
        ),
      );
      state.setSongPlanStep(1, SongPlanStep(patternIndex: 0, endLine: 1));
      final positions = state.song.songPlanPositions(0).take(12).toList();
      expect(positions.map((p) => p.patternIndex), [
        0,
        0,
        0,
        1,
        1,
        0,
        0,
        0,
        1,
        1,
        0,
        0,
      ]);
      expect(positions.take(10).map((p) => p.line), [
        2,
        3,
        4,
        2,
        3,
        2,
        3,
        4,
        2,
        3,
      ]);
      expect(positions.take(10).map((p) => p.pass), [
        1,
        1,
        1,
        1,
        1,
        2,
        2,
        2,
        2,
        2,
      ]);
      expect(positions.take(10).every((p) => p.stepIndex == 0), isTrue);
      expect(positions[10].stepIndex, 1);
      expect(positions[10].planEnd, isTrue);
      expect(positions[11].stepIndex, 0);
    },
  );

  test('automatic end follows each counted pattern length', () {
    state.song.patterns = [pattern(40, lines: 2), pattern(60, lines: 4)];
    state.setSongPlanStep(0, SongPlanStep(patternIndex: 0, count: 2));
    final positions = state.song.songPlanPositions(0).take(6).toList();
    expect(positions.map((p) => p.line), [1, 2, 1, 2, 3, 4]);
    expect(positions.map((p) => p.patternIndex), [0, 0, 1, 1, 1, 1]);
  });

  test(
    'empty pattern inside count ends the run before repeats or later steps',
    () {
      state.song.patterns = [
        pattern(40, lines: 2),
        PatternModel(name: 'Empty'),
        pattern(60),
      ];
      state.setSongPlanStep(
        0,
        SongPlanStep(patternIndex: 0, count: 3, repeats: 4),
      );
      final positions = state.song.songPlanPositions(0).take(5).toList();
      expect(state.song.validateSongPlan(0), 1);
      expect(positions.map((p) => p.patternIndex), [0, 0, 0, 0, 0]);
      expect(positions.map((p) => p.planEnd), [
        false,
        true,
        false,
        true,
        false,
      ]);
      expect(positions.every((p) => p.pass == 1), isTrue);
      state.song.patterns = [pattern(40, lines: 2)];
      expect(state.song.validateSongPlan(0), 1);
    },
  );

  test(
    'invalid start in a later counted pattern fails before audio starts',
    () async {
      state.song.patterns = [pattern(40, lines: 8), pattern(60, lines: 2)];
      state.setSongPlanStep(
        0,
        SongPlanStep(patternIndex: 0, count: 2, startLine: 3),
      );
      state.setSongPlanEnabled(true);
      expect(state.song.hasValidPlanRange(state.song.planStepAt(0)), isFalse);
      await expectLater(state.play(), throwsStateError);
      expect(calls.where((c) => c.method == 'start'), isEmpty);
    },
  );

  testWidgets('COUNT edits validate slot limits and ranges across the group', (
    tester,
  ) async {
    state.song.patterns = [pattern(40, lines: 8), pattern(60, lines: 2)];
    await show(tester);
    await tester.tap(cell(1, 5));
    await tester.pumpAndSettle();
    final countField = find.byKey(const ValueKey('song-plan-edit-Count'));
    final startField = find.byKey(const ValueKey('song-plan-edit-Start line'));
    await tester.enterText(countField, '100');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a number from 1 to 99.'), findsOneWidget);
    await tester.enterText(countField, '2');
    await tester.enterText(startField, '3');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(
      find.text('Start exceeds a pattern length in this group.'),
      findsOneWidget,
    );
    await tester.enterText(startField, '1');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(state.song.planStepAt(0).count, 2);
    expect(tester.widget<Text>(cell(1, 5)).data, '2');
    state.undoSong();
    expect(state.song.planStepAt(0).count, 1);
    state.redoSong();
    expect(state.song.planStepAt(0).count, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'counted playback follows patterns while keeping the same step highlight',
    (tester) async {
      state.song.patterns = [pattern(40, lines: 2), pattern(60, lines: 2)];
      state.setSongPlanStep(
        0,
        SongPlanStep(patternIndex: 0, count: 2, repeats: 2),
      );
      state.setSongPlanEnabled(true);
      await show(tester);
      await tester.tap(find.text('PLAY'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      final queued = rowsFor('enqueueAllPlaybackRows');
      expect(queued.take(8).map((r) => (r['rowData'] as List)[0]), [
        51,
        52,
        71,
        72,
        51,
        52,
        71,
        72,
      ]);
      advances = 2;
      await tester.pump(const Duration(milliseconds: 32));
      await tester.pump();
      expect(state.playheadArrangementSlot, 1);
      expect(state.playingSongPlanStep, 0);
      expect(state.playingSongPlanPass, 1);
      expect(background(tester, 1), kBgPlayhead);
      advances = 2;
      await tester.pump(const Duration(milliseconds: 32));
      await tester.pump();
      expect(state.playheadArrangementSlot, 0);
      expect(state.playingSongPlanPass, 2);
      advances = 4;
      await tester.pump(const Duration(milliseconds: 32));
      await tester.pump();
      expect(state.playingSongPlanStep, 1);
      expect(background(tester, 2), kBgPlayhead);
      await tester.tap(find.text('STOP'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'partial-pattern queue keeps prefix instrument and tempo carry',
    () async {
      final music = pattern(40);
      for (final cell in music.tracks[0].cells.skip(1)) {
        cell.instrument = null;
      }
      music.tracks[0].cells[0].fxSlots[0]
        ..command = kFxBPM
        ..value = 20;
      state.song.patterns = [music];
      state.setSongPlanStep(
        0,
        SongPlanStep(patternIndex: 0, startLine: 4, endLine: 6, repeats: 2),
      );
      state.setSongPlanEnabled(true);
      await state.play();
      final queued = rowsFor('enqueueAllPlaybackRows');
      expect(
        (queued[0]['rowData'] as List)[0],
        -1054,
      ); // Carried pitch-only MIDI 54.
      expect(queued.take(6).map((r) => (r['rowData'] as List)[0]), [
        -1054,
        -1055,
        -1056,
        -1054,
        -1055,
        -1056,
      ]);
      expect((queued[0]['rowData'] as List)[4], isNot(4)); // Not an empty slot.
      expect(queued[0]['lineSamples'], 1285);
      final flags =
          calls.firstWhere((c) => c.method == 'configureSongPlanRows').arguments
              as Map;
      expect((flags['passStartFlags'] as List).take(6), [1, 0, 0, 1, 0, 0]);
      expect((flags['endFlags'] as List).take(6), [0, 0, 0, 0, 0, 1]);
    },
  );

  test(
    'queued masks follow counted groups, repeats and step changes without changing live mutes',
    () async {
      state.song.patterns = [pattern(40, lines: 2), pattern(60, lines: 2)];
      state.song.patterns[0].tracks[2].mixerMute = true;
      state.song.patterns[0].tracks[3].mixerSolo = true;
      state.setSongPlanStep(
        0,
        SongPlanStep(
          patternIndex: 0,
          count: 2,
          repeats: 2,
          startLine: 2,
          muteMask: 0x8001,
        ),
      );
      state.setSongPlanStep(1, SongPlanStep(patternIndex: 0, endLine: 1));
      state.setSongPlanEnabled(true);
      await state.play();
      final flags =
          calls.firstWhere((c) => c.method == 'configureSongPlanRows').arguments
              as Map;
      expect((flags['muteMasks'] as List).take(5), [
        0x8001,
        0x8001,
        0x8001,
        0x8001,
        0,
      ]);
      expect(
        (flags['muteMasks'] as List).length,
        rowsFor('enqueueAllPlaybackRows').length,
      );
      final pending =
          calls.lastWhere((c) => c.method == 'configureSongPlanRows').arguments
              as Map;
      expect(
        (pending['muteMasks'] as List).length,
        rowsFor('scheduleNextLoopRows').length,
      );
      expect(state.song.patterns[0].tracks[0].mixerMute, isFalse);
      expect(state.song.patterns[0].tracks[2].mixerMute, isTrue);
      expect(state.song.patterns[0].tracks[3].mixerSolo, isTrue);
      expect(() => state.toggleSongPlanTrackMute(1), throwsStateError);
      state.stop();
      expect(state.song.patterns[0].tracks[2].mixerMute, isTrue);
      expect(state.song.patterns[0].tracks[3].mixerSolo, isTrue);
      expect(
        calls.where((c) => c.method == 'clearQueuedPlaybackRows'),
        isNotEmpty,
      );
    },
  );

  testWidgets(
    'mute row follows selection and playback and toggles only while stopped',
    (tester) async {
      state.song.patterns = [pattern(40, lines: 2)];
      state.setSongPlanStep(1, SongPlanStep(patternIndex: 0, muteMask: 2));
      state.setSongPlanEnabled(true);
      await show(tester);
      final trackOne = find.byKey(const ValueKey('song-plan-mute-0'));
      final trackTwo = find.byKey(const ValueKey('song-plan-mute-1'));
      String? text(Finder track) => tester
          .widget<Text>(find.descendant(of: track, matching: find.byType(Text)))
          .data;
      expect(text(trackOne), '1');
      await tester.tap(trackOne);
      await tester.pump();
      expect(text(trackOne), 'M');
      expect(state.song.planStepAt(0).muteMask, 1);
      await tester.tap(trackOne);
      await tester.pump();
      expect(text(trackOne), '1');
      await tester.tap(cell(2, 0));
      await tester.pump();
      expect(find.text('STEP 02 MUTES'), findsOneWidget);
      expect(text(trackTwo), 'M');
      await tester.tap(cell(1, 0));
      await tester.pump();
      await tester.tap(find.text('PLAY'));
      await tester.pump();
      advances = 2;
      await tester.pump(const Duration(milliseconds: 32));
      await tester.pump();
      expect(find.text('STEP 02 MUTES'), findsOneWidget);
      expect(text(trackTwo), 'M');
      await tester.tap(trackTwo);
      await tester.pump();
      expect(state.song.planStepAt(1).muteMask, 2);
      await tester.tap(find.text('STOP'));
      await tester.pump();
      expect(find.text('STEP 01 MUTES'), findsOneWidget);
      expect(text(trackTwo), '2');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('narrow mute row scrolls to track 16 without overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await show(tester);
    final lastTrack = find.byKey(const ValueKey('song-plan-mute-15'));
    final muteScroll = find.ancestor(
      of: lastTrack,
      matching: find.byType(SingleChildScrollView),
    );
    await tester.drag(muteScroll, const Offset(-400, 0));
    await tester.pumpAndSettle();
    await tester.tap(lastTrack);
    await tester.pump();
    expect(state.song.planStepAt(0).muteMask, 0x8000);
    expect(tester.takeException(), isNull);
  });

  test(
    '999 repeats remain bounded and chance is evaluated per occurrence',
    () async {
      final music = pattern(49, lines: 1);
      music.tracks[0].cells[0].fxSlots[0]
        ..command = kFxCHA
        ..value = 25;
      state.song.patterns = [music];
      state.setSongPlanStep(0, SongPlanStep(patternIndex: 0, repeats: 999));
      state.setSongPlanEnabled(true);
      await state.play();
      final first = rowsFor('enqueueAllPlaybackRows');
      final next = rowsFor('scheduleNextLoopRows');
      expect(first.length, inInclusiveRange(64, 256));
      expect(next.length, inInclusiveRange(64, 256));
      final notes = [
        ...first,
        ...next,
      ].map((r) => (r['rowData'] as List)[0]).toSet();
      expect(notes, containsAll([-1, 60]));
      expect(calls.where((c) => c.method == 'start').length, 1);
    },
  );

  test(
    'same-pattern repeats preserve carried notes for top-line retriggers',
    () async {
      final music = PatternModel(name: 'Carry', beats: 1, linesPerBeat: 2);
      music.tracks[0].cells[0].fxSlots[0]
        ..command = kFxRET
        ..value = 4;
      music.tracks[0].cells[1]
        ..note = NoteValue.fromScrollIndex(49)
        ..instrument = 1;
      state.song.patterns = [music];
      state.setSongPlanStep(0, SongPlanStep(patternIndex: 0, repeats: 2));
      state.setSongPlanEnabled(true);
      await state.play();
      final queued = rowsFor('enqueueAllPlaybackRows');
      expect(queued[0]['retrigData'], isEmpty);
      expect(queued[2]['retrigData'], isNotEmpty);
    },
  );

  test('empty and invalid starting steps fail before starting audio', () async {
    state.setSongPlanEnabled(true);
    await expectLater(state.play(), throwsStateError);
    expect(state.isPlaying, isFalse);
    expect(calls.where((c) => c.method == 'start'), isEmpty);
    state.song.patterns = [pattern(49, lines: 4)];
    state.setSongPlanStep(0, SongPlanStep(patternIndex: 0, startLine: 5));
    await expectLater(state.play(), throwsStateError);
    expect(state.isPlaying, isFalse);
    expect(calls.where((c) => c.method == 'start'), isEmpty);
  });

  test(
    'plan OFF retains native island looping and cross-island jumps',
    () async {
      state.song.patterns = [
        pattern(40),
        pattern(50),
        PatternModel(name: 'Separator'),
        pattern(60),
      ];
      state.setSongPlanStep(
        0,
        SongPlanStep(patternIndex: 3, repeats: 64, muteMask: 0xffff),
      );
      state.setLoopPlaybackEnabled(true);
      await state.play();
      expect(state.playingSongPlan, isFalse);
      expect(rowsFor('enqueueAllPlaybackRows').length, 32);
      state.queueSongPatternJump(3);
      await Future<void>.delayed(Duration.zero);
      expect(rowsFor('scheduleNextLoopRows').length, 16);
      expect(calls.where((c) => c.method == 'configureSongPlanRows'), isEmpty);
    },
  );

  test('song export refuses to silently ignore an enabled plan', () async {
    state.setSongPlanEnabled(true);
    await expectLater(state.exportSongToWav(), throwsStateError);
    await expectLater(state.exportSongStems(), throwsStateError);
  });

  testWidgets('STEP selects without editing; another cell selects and edits', (
    tester,
  ) async {
    state.song.patterns = [pattern(40), pattern(60)];
    await show(tester);
    expect(background(tester, 1), kBgSelected);
    await tester.tap(cell(2, 0));
    await tester.pump();
    expect(state.selectedSongPlanStep, 1);
    expect(background(tester, 2), kBgSelected);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(cell(1, 4));
    await tester.pump();
    expect(state.selectedSongPlanStep, 0);
    expect(find.text('Edit step 01'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('ON starts selected step and ignores all live jumps and edits', (
    tester,
  ) async {
    state.song.patterns = [pattern(40), pattern(60)];
    state.setSongPlanStep(0, SongPlanStep(patternIndex: 0, repeats: 2));
    state.setSongPlanStep(
      1,
      SongPlanStep(patternIndex: 0, startLine: 4, endLine: 6),
    );
    state.selectSongPattern(1);
    state.selectSongPlanStep(1);
    await show(tester);
    await tester.tap(find.text('OFF'));
    await tester.pump();
    expect(state.song.songPlanEnabled, isTrue);
    await tester.tap(find.text('PLAY'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(state.playingSongPlanStep, 1);
    expect(state.playheadArrangementSlot, 0);
    expect(state.playheadRow, 3);
    expect(background(tester, 1), kBgBeat);
    expect(background(tester, 2), kBgPlayhead);
    state.selectSongPattern(1);
    state.queueSongPatternJump(1);
    await tester.tap(cell(1, 0));
    await tester.tap(cell(1, 4));
    await tester.tap(find.text('ON'));
    await tester.pump();
    expect(state.selectedSongPlanStep, 1);
    expect(state.playheadArrangementSlot, 0);
    expect(state.song.songPlanEnabled, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    expect(() => state.setSongPlanEnabled(false), throwsStateError);
    expect(
      () => state.setSongPlanStep(0, SongPlanStep(patternIndex: 0)),
      throwsStateError,
    );
    state.undoSong();
    expect(state.song.songPlanEnabled, isTrue);
    await tester.tap(find.text('STOP'));
    await tester.pump();
    expect(background(tester, 2), kBgSelected);
    expect(tester.takeException(), isNull);
  });

  testWidgets('actual step and pass advance even when patterns are identical', (
    tester,
  ) async {
    state.song.patterns = [pattern(40)];
    state.setSongPlanStep(
      0,
      SongPlanStep(patternIndex: 0, startLine: 4, endLine: 6, repeats: 2),
    );
    state.setSongPlanStep(
      1,
      SongPlanStep(patternIndex: 0, startLine: 2, endLine: 3),
    );
    state.setSongPlanEnabled(true);
    await show(tester);
    await tester.tap(find.text('PLAY'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(background(tester, 1), kBgPlayhead);
    expect(background(tester, 2), kBgColor);
    advances = 3;
    await tester.pump(const Duration(milliseconds: 32));
    await tester.pump();
    expect(state.playingSongPlanPass, 2);
    expect(state.playheadRow, 3);
    advances = 3;
    await tester.pump(const Duration(milliseconds: 32));
    await tester.pump();
    expect(state.playingSongPlanStep, 1);
    expect(state.playheadRow, 1);
    expect(background(tester, 1), kBgBeat);
    expect(background(tester, 2), kBgPlayhead);
    running = false;
    advances = 2;
    await tester.pump(const Duration(milliseconds: 32));
    await tester.pump();
    expect(state.isPlaying, isFalse);
    expect(calls.any((c) => c.method == 'stopTransportSoft'), isTrue);
    expect(background(tester, 1), kBgSelected);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'loop restarts at step 01 and can be switched off while playing',
    (tester) async {
      state.song.patterns = [pattern(40), pattern(60)];
      state.setSongPlanStep(0, SongPlanStep(patternIndex: 0, endLine: 2));
      state.setSongPlanStep(1, SongPlanStep(patternIndex: 1, endLine: 2));
      state.selectSongPlanStep(1);
      state.setSongPlanEnabled(true);
      state.setLoopPlaybackEnabled(true);
      await show(tester);
      await state.play();
      advances = 2;
      await tester.pump(const Duration(milliseconds: 32));
      await tester.pump();
      expect(state.playingSongPlanStep, 0);
      expect(state.playheadArrangementSlot, 0);
      await tester.tap(find.text('LOOP'));
      await tester.pump();
      expect(state.loopPlaybackEnabled, isFalse);
      final loopCall = calls.lastWhere(
        (c) => c.method == 'setQueuedPlaybackLooping',
      );
      expect((loopCall.arguments as Map)['loop'], isFalse);
      await tester.tap(find.text('STOP'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('crossing a batch uploads another without restarting audio', (
    tester,
  ) async {
    state.song.patterns = [pattern(40)];
    state.setSongPlanStep(0, SongPlanStep(patternIndex: 0, repeats: 999));
    state.setSongPlanEnabled(true);
    await show(tester);
    await state.play();
    final count = rowsFor('enqueueAllPlaybackRows').length;
    advances = count;
    await tester.pump(const Duration(milliseconds: 32));
    await tester.pump();
    expect(state.isPlaying, isTrue);
    expect(state.playingSongPlanPass, count ~/ 16 + 1);
    expect(calls.where((c) => c.method == 'scheduleNextLoopRows').length, 2);
    expect(calls.where((c) => c.method == 'start').length, 1);
    await tester.tap(find.text('STOP'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('native underrun stops explicitly and notifies the user', (
    tester,
  ) async {
    state.song.patterns = [pattern(40)];
    state.setSongPlanEnabled(true);
    await show(tester);
    await state.play();
    underrun = true;
    running = false;
    await tester.pump(const Duration(milliseconds: 32));
    await tester.pump();
    expect(state.isPlaying, isFalse);
    expect(
      find.textContaining('next audio batch was not ready'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Stop during initial preparation cancels the pending start', (
    tester,
  ) async {
    state.song.patterns = [pattern(40)];
    state.setSongPlanEnabled(true);
    uploadGate = Completer<void>();
    await show(tester);
    await tester.tap(find.text('PLAY'));
    await tester.pump();
    expect(state.songPlanStarting, isTrue);
    await tester.tap(find.text('STOP'));
    uploadGate!.complete();
    await tester.pump();
    await tester.pump();
    expect(state.isPlaying, isFalse);
    expect(state.songPlanStarting, isFalse);
    expect(calls.where((c) => c.method == 'start'), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
