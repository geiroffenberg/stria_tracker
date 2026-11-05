import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stria/audio/audio_engine.dart';
import 'package:stria/models/cell.dart';
import 'package:stria/models/instrument_model.dart';
import 'package:stria/models/note_value.dart';
import 'package:stria/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.example.tracker/audio');
  final calls = <MethodCall>[];
  late AppState state;

  setUp(() async {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    await AudioEngine.instance.initialize();
    state = AppState();
    state.setActiveTabIndex(1);
  });

  tearDown(() {
    state.stop();
    state.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<List<Map>> playbackRows() async {
    await state.play();
    final queued = calls.singleWhere(
      (call) => call.method == 'enqueueAllPlaybackRows',
    );
    return ((queued.arguments as Map)['rows'] as List).cast<Map>();
  }

  test('empty slots do not trigger notes or delayed/repeated notes', () async {
    final cells = state.currentTrack.cells;
    for (var row = 0; row < 3; row++) {
      cells[row].note = NoteValue.fromScrollIndex(49);
      cells[row].instrument = row == 0 ? 1 : 99;
    }
    cells[1].fxSlots[0].command = kFxDEL;
    cells[1].fxSlots[0].value = 50;
    cells[2].fxSlots[0].command = kFxRET;
    cells[2].fxSlots[0].value = 4;
    final rows = await playbackRows();
    for (final row in rows.take(3)) {
      final data = row['rowData'] as List;
      expect(data[0], -2);
      expect(data[4], 4); // Native empty-instrument code.
      expect(row['delayData'], isEmpty);
      expect(row['retrigData'], isEmpty);
    }
  });

  test('empty cell audition never starts the audio engine', () async {
    final cell = state.currentTrack.cells[0];
    cell.note = NoteValue.fromScrollIndex(49);
    cell.instrument = 99;
    calls.clear();
    await state.previewCellNoteOneShot(0);
    expect(calls, isEmpty);
  });

  test('switching to empty clears carried RET, ARP and slide notes', () async {
    state.instruments[0].type = InstrumentType.simpleSynth;
    final cells = state.currentTrack.cells;
    cells[0].note = NoteValue.fromScrollIndex(49);
    cells[0].instrument = 1;
    cells[0].fxSlots[0].command = kFxARP;
    cells[0].fxSlots[0].value = 0x37;
    cells[1].instrument = 99;
    cells[1].fxSlots[0].command = kFxRET;
    cells[1].fxSlots[0].value = 4;
    cells[1].fxSlots[1].command = kFxSLU;
    cells[1].fxSlots[1].value = 24;
    cells[2].fxSlots[0].command = kFxRET;
    cells[2].fxSlots[0].value = 4;
    final rows = await playbackRows();
    expect(rows[0]['arpData'], isNotEmpty);
    for (final row in rows.skip(1).take(2)) {
      expect((row['rowData'] as List)[0], -2);
      expect(row['retrigData'], isEmpty);
      expect(row['arpData'], isEmpty);
      expect(row['pitchRampData'], isEmpty);
    }
  });

  test('random instrument selection respects empty slots', () async {
    final cell = state.currentTrack.cells[0];
    cell.note = NoteValue.fromScrollIndex(49);
    cell.instrument = 99;
    cell.fxSlots[0].command = kFxRNI;
    cell.fxSlots[0].value = 99;
    final rows = await playbackRows();
    expect((rows[0]['rowData'] as List)[0], -2);
    expect((rows[0]['rowData'] as List)[4], 4);
  });

  test('valid synth, pitch-only and note-off packets are preserved', () async {
    state.instruments[0].type = InstrumentType.simpleSynth;
    final cells = state.currentTrack.cells;
    cells[0].note = NoteValue.fromScrollIndex(49);
    cells[0].instrument = 1;
    cells[1].note = NoteValue.fromScrollIndex(53);
    cells[1].instrument = 0;
    cells[2].note = NoteValue.off;
    final rows = await playbackRows();
    expect((rows[0]['rowData'] as List)[0], cells[0].note.midiNote);
    expect((rows[0]['rowData'] as List)[4], 0);
    expect((rows[1]['rowData'] as List)[0], -1000 - cells[1].note.midiNote);
    expect((rows[2]['rowData'] as List)[0], -2);
  });
}
