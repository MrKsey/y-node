import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'address_book_screen.dart';
import 'home_screen.dart';
import 'peers_screen.dart';
import 'settings_screen.dart';
import 'split_screen.dart';

/// The five-tab shell of the app.
///
/// The tabs are kept alive with an [IndexedStack] so that a running probe or a
/// scrolled address book is not thrown away when the user switches away.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // The service may have replaced peers while the app was in the background.
      context.read<AppState>().refreshFromStore();
    }
  }

  void _go(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    // The shell itself never changes with the tunnel: watching AppState here
    // rebuilt all five tabs on every traffic tick, which is what made the
    // scrolling stutter while the tunnel was up.
    final l10n = L10n.instance;

    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          // TickerMode mutes the animations of the tabs that are not on
          // screen: the flow animation in the hero must not keep the engine
          // busy while the user is scrolling through Settings.
          TickerMode(
            enabled: _index == 0,
            child: HomeScreen(onOpenPeers: () => _go(1)),
          ),
          TickerMode(
            enabled: _index == 1,
            child: PeersScreen(onOpenSettings: () => _go(4)),
          ),
          TickerMode(enabled: _index == 2, child: const AddressBookScreen()),
          TickerMode(enabled: _index == 3, child: const SplitScreen()),
          TickerMode(enabled: _index == 4, child: const SettingsScreen()),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _go,
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.shield_outlined),
            selectedIcon: const Icon(Icons.shield_rounded),
            label: l10n.t('navHome'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.hub_outlined),
            selectedIcon: const Icon(Icons.hub_rounded),
            label: l10n.t('navPeers'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.book_outlined),
            selectedIcon: const Icon(Icons.book_rounded),
            label: l10n.t('navBook'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.apps_outlined),
            selectedIcon: const Icon(Icons.apps_rounded),
            label: l10n.t('navSplit'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.tune_outlined),
            selectedIcon: const Icon(Icons.tune_rounded),
            label: l10n.t('navSettings'),
          ),
        ],
      ),
    );
  }
}
