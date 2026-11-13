import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stria/models/note_value.dart';
import 'package:stria/models/pattern_model.dart';
import 'package:stria/screens/song_plan_screen.dart';
import 'package:stria/screens/song_screen.dart';
import 'package:stria/state/app_state.dart';
import 'package:stria/theme/app_theme.dart';

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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('empty song shows an end marker without changing the project', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    final before = jsonEncode(state.song.toJson());

    await showPlan(tester, state);

    expect(find.text('DEFAULT / SEQUENTIAL'), findsOneWidget);
    expect(find.text('End of song - empty song row'), findsOneWidget);
    expect(
      find.descendant(of: step(1), matching: find.text('END')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: step(1), matching: find.text('ALL')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: step(1), matching: find.text('1')),
      findsOneWidget,
    );
    expect(jsonEncode(state.song.toJson()), before);
    expect(state.isPlaying, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('first gap ends the sequence and later music is dimmed', (
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

    expect(
      find.descendant(of: step(1), matching: find.text('NEXT')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: step(2), matching: find.text('END')),
      findsOneWidget,
    );
    final later = tester.widget<Text>(
      find.descendant(of: step(3), matching: find.text('NEXT')),
    );
    expect(later.style!.color, kColInactive);

    state.song.patterns[1] = musicalPattern();
    state.notifyListeners();
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: step(2), matching: find.text('NEXT')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: step(4), matching: find.text('END')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('all 99 musical rows end at step 99 without an empty marker', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    state.song.patterns = List.generate(99, (_) => musicalPattern());

    await showPlan(tester, state);
    await tester.scrollUntilVisible(
      step(99),
      500,
      scrollable: find.byType(Scrollable),
    );

    expect(
      find.descendant(of: step(99), matching: find.text('END')),
      findsOneWidget,
    );
    expect(find.text('End of song - empty song row'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow screen supports larger text and reflects loop status', (
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
    expect(find.textContaining('Loop OFF:'), findsOneWidget);

    state.setLoopPlaybackEnabled(true);
    await tester.pumpAndSettle();

    expect(find.textContaining('Loop ON:'), findsOneWidget);
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
