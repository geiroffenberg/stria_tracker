import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'audio/audio_engine.dart';
import 'screens/main_screen.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';

const String _kPaletteKey = 'tracker_palette';

/// Global navigatorKey to access the navigator state from anywhere
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Global notifier — any widget can listen to palette changes and rebuild.
final ValueNotifier<TrackerPalette> paletteNotifier =
    ValueNotifier<TrackerPalette>(kPaletteBlue);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Force portrait orientation
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // Restore saved palette
  final prefs = await SharedPreferences.getInstance();
  final savedName = prefs.getString(_kPaletteKey);
  if (savedName != null) {
    final saved = kAllPalettes.where((p) => p.name == savedName).firstOrNull;
    if (saved != null) {
      applyPalette(saved);
      paletteNotifier.value = saved;
    }
  }

  // Initialise Oboe (non-fatal if native side is unavailable)
  await AudioEngine.instance.initialize();

  // Request storage permission early so sample files on external storage
  // can be loaded when a project is opened (Android revokes this on reinstall).
  if (Platform.isAndroid) {
    // Android 13+ uses READ_MEDIA_AUDIO; older versions use READ_EXTERNAL_STORAGE.
    final audioOk = await Permission.audio.request();
    if (!audioOk.isGranted) {
      await Permission.storage.request();
    }
  }

  runApp(const TrackerApp());
}

/// Switch palette globally, persist choice, and trigger a full rebuild.
Future<void> switchPalette(TrackerPalette p) async {
  applyPalette(p);
  paletteNotifier.value = p;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kPaletteKey, p.name);
}

class TrackerApp extends StatefulWidget {
  const TrackerApp({super.key});

  @override
  State<TrackerApp> createState() => _TrackerAppState();
}

class _TrackerAppState extends State<TrackerApp> with WidgetsBindingObserver {
  final _appState = AppState();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    paletteNotifier.addListener(_onPaletteChanged);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (_appState.hasUnsavedChanges) {
        _showUnsavedChangesDialog();
      } else {
        unawaited(_appState.autosaveOnFocusLost());
      }
    }
  }

  void _showUnsavedChangesDialog() {
    // Only show dialog if there's a navigator available
    final navContext = navigatorKey.currentContext;
    if (navContext == null) {
      // Fallback: just auto-save if we can't show a dialog
      unawaited(_appState.autosaveOnFocusLost());
      return;
    }

    showDialog<bool>(
      context: navContext,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Unsaved Changes'),
        content: const Text(
          'You have unsaved changes. Would you like to save them before closing?',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context, false);
              // Close the app
              if (Platform.isAndroid) {
                SystemNavigator.pop();
              }
            },
            child: const Text('Discard'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context, true);
              // Save the song
              await _appState.saveSong();
              // Close the app
              if (Platform.isAndroid) {
                SystemNavigator.pop();
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _onPaletteChanged() => setState(() {});

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    paletteNotifier.removeListener(_onPaletteChanged);
    AudioEngine.instance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      state: _appState,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        title:        'Tracker',
        debugShowCheckedModeBanner: false,
        theme:        buildAppTheme(),
        builder: (context, child) {
          return SafeArea(
            top: false,    // Let status bar overlay if you want
            bottom: true,  // CRITICAL: Force safe margin above nav bar
            child: child ?? const SizedBox(),
          );
        },
        home:         const MainScreen(),
      ),
    );
  }
}
