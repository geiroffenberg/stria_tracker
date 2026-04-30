import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'audio/audio_engine.dart';
import 'screens/main_screen.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Force portrait orientation
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // Initialise Oboe (non-fatal if native side is unavailable)
  await AudioEngine.instance.initialize();

  runApp(const TrackerApp());
}

class TrackerApp extends StatefulWidget {
  const TrackerApp({super.key});

  @override
  State<TrackerApp> createState() => _TrackerAppState();
}

class _TrackerAppState extends State<TrackerApp> {
  final _appState = AppState();

  @override
  void dispose() {
    AudioEngine.instance.dispose();
    _appState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      state: _appState,
      child: MaterialApp(
        title:        'Tracker',
        debugShowCheckedModeBanner: false,
        theme:        buildAppTheme(),
        home:         const MainScreen(),
      ),
    );
  }
}
