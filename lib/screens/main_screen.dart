import 'package:flutter/material.dart';
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

  @override
  Widget build(BuildContext context) {
    AppStateScope.of(context); // subscribe to app state

    return Scaffold(
      backgroundColor: kBgColor,
      body: NotificationListener<OpenPatternTrackNotification>(
        onNotification: (notification) {
          if (_tabIndex != 1) {
            setState(() => _tabIndex = 1);
          }
          AppStateScope.of(context).setPlaybackFollowsSong(false);
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
              const TransportBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopNav() {
    final state = AppStateScope.of(context);
    return Container(
      height: 52,
      decoration: const BoxDecoration(
        color: kBgTopNav,
        border: Border(
          bottom: BorderSide(color: Color(0xFF226666), width: 1),
        ),
      ),
      child: Row(
        children: List.generate(_tabs.length, (i) {
          final active = i == _tabIndex;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() => _tabIndex = i);
                state.setPlaybackFollowsSong(i == 0);
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
