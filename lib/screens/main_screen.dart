import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../main.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/transport_bar.dart';
import 'song_screen.dart';
import 'pattern_screen.dart';
import 'instrument_screen.dart';
import 'mixer_screen.dart';

/// Root scaffold with top navigation tabs and a global bottom transport bar.
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _tabIndex = 1; // start on Pattern view

  static const _tabs = ['SONG', 'PATTERN', 'INST', 'MIXER'];
  static const _kHideBetaWelcome = 'hideBetaWelcome';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowBetaWelcome());
  }

  Future<void> _maybeShowBetaWelcome() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kHideBetaWelcome) == true) return;
    if (!mounted) return;
    await _showBetaWelcomeDialog(prefs);
  }

  Future<void> _showBetaWelcomeDialog(SharedPreferences prefs) async {
    bool dontShowAgain = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1A2A2A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          title: Text(
            'STRIA TRACKER',
            style: kStyleHeader.copyWith(color: kColAccent, fontSize: 15, letterSpacing: 2),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Thanks to all the beta testers who helped get this app onto the Play Store!\n\n'
                'For those who have picked up the app at \$0.99 \u2014 if you want to help shape its development, please post bug reports and feature requests in the STRIA TRACKER Facebook group:',
                style: kStyleBase.copyWith(color: kColHeader, fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 10),
              GestureDetector(
                onTap: () => launchUrl(
                  Uri.parse('https://www.facebook.com/groups/1722797245837728'),
                  mode: LaunchMode.externalApplication,
                ),
                child: Text(
                  'facebook.com/groups/striatracker',
                  style: kStyleBase.copyWith(
                    color: kColAccent,
                    fontSize: 13,
                    decoration: TextDecoration.underline,
                    decorationColor: kColAccent,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Contributors will be added to a thank-you list in a future update, and you\'ll keep the app at \$0.99 forever.',
                style: kStyleBase.copyWith(color: kColHeader, fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 20),
              GestureDetector(
                onTap: () => setDialogState(() => dontShowAgain = !dontShowAgain),
                child: Row(
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: Checkbox(
                        value: dontShowAgain,
                        onChanged: (v) => setDialogState(() => dontShowAgain = v ?? false),
                        activeColor: kColAccent,
                        side: BorderSide(color: kColInactive),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      "Don't show again",
                      style: kStyleBase.copyWith(color: kColInactive, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                if (dontShowAgain) {
                  await prefs.setBool(_kHideBetaWelcome, true);
                }
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: Text(
                'OK',
                style: kStyleHeader.copyWith(color: kColAccent, fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppStateScope.of(context); // subscribe to app state

    return ValueListenableBuilder<TrackerPalette>(
      valueListenable: paletteNotifier,
      builder: (_, _, _) => Scaffold(
        backgroundColor: kBgColor,
        body: NotificationListener<OpenPatternTrackNotification>(
          onNotification: (notification) {
            if (_tabIndex != 1) {
              setState(() => _tabIndex = 1);
            }
            AppStateScope.of(context).setActiveTabIndex(1);
            return true;
          },
          child: SafeArea(
            child: Column(
              children: [
                _buildTopNav(),
                Expanded(
                  child: IndexedStack(
                    index: _tabIndex,
                    children: const [
                      SongScreen(),
                      PatternScreen(),
                      InstrumentScreen(),
                      MixerScreen(),
                    ],
                  ),
                ),
                const Divider(
                  height: 1,
                  thickness: 1,
                  color: Color(0xFF226666),
                ),
                TransportBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// When navigating to the INST tab, jump to the first instrument
  /// explicitly used in the current pattern, if any.
  void _autoSelectFirstInstrument(AppState state) {
    for (final track in state.currentPattern.tracks) {
      for (final cell in track.cells) {
        if (cell.instrument != null) {
          state.selectInstrument(cell.instrument!);
          return;
        }
      }
    }
  }

  Widget _buildTopNav() {
    final state = AppStateScope.of(context);
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: kBgTopNav,
        border: const Border(
          bottom: BorderSide(color: Color(0xFF226666), width: 1),
        ),
      ),
      child: Row(
        children: List.generate(_tabs.length, (i) {
          final active = i == _tabIndex;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                if (i == 2) _autoSelectFirstInstrument(state);
                setState(() => _tabIndex = i);
                state.setActiveTabIndex(i);
              },
              child: Container(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color:  active ? kColAccent : Colors.transparent,
                      width:  2,
                    ),
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  _tabs[i],
                  style: kStyleBase.copyWith(
                    fontSize: 18,
                    letterSpacing: 2,
                    color: active ? kColAccent : kColHeader,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
