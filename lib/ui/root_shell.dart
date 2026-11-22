import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'address_book_screen.dart';
import 'home_screen.dart';
import 'peers_screen.dart';
import 'settings_screen.dart';
import 'split_screen.dart';
import 'update_dialog.dart';

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

  /// The tabs that have been opened at least once. An [IndexedStack] builds
  /// every child, so all five screens used to be laid out on the first frame
  /// and kept alive even if the user never left the tunnel tab. A tab is now
  /// created when it is first opened and then kept, which is what the stack
  /// was for.
  final Set<int> _built = {0};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<AppState>();
      // The "Connect on launch" switch runs after the first frame: the VPN
      // consent dialog needs a window behind it, and a cold start must not
      // wait on the tunnel before the app is on screen.
      unawaited(state.connectOnLaunchIfNeeded());
      _checkForUpdate();
    });
  }

  /// Startup release check. Announces a newer release once per version, and
  /// only when the user turned the automatic check on.
  Future<void> _checkForUpdate() async {
    if (!mounted) return;
    final state = context.read<AppState>();
    final update = await state.checkForUpdateOnStart();
    if (update == null || !mounted) return;
    await state.markUpdateNotified(update);
    if (!mounted) return;
    await showUpdatePrompt(context, update, state.l10n);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final app = context.read<AppState>();
    if (state == AppLifecycleState.resumed) {
      // The service may have replaced peers while the app was in the background.
      app.resumePolling();
      app.refreshFromStore();
      return;
    }
    // The tunnel lives in the service: the window has nothing to poll while it
    // is not on screen.
    app.pausePolling();
  }

  void _go(int index) {
    setState(() {
      _index = index;
      _built.add(index);
    });
  }

  Widget _tab(int index) => switch (index) {
    0 => HomeScreen(onOpenPeers: () => _go(1)),
    1 => PeersScreen(onOpenSettings: () => _go(4)),
    2 => const AddressBookScreen(),
    3 => const SplitScreen(),
    _ => const SettingsScreen(),
  };

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
          for (var i = 0; i < 5; i++)
            // TickerMode mutes the animations of the tabs that are not on
            // screen: the flow animation in the hero must not keep the engine
            // busy while the user is scrolling through Settings.
            TickerMode(
              enabled: _index == i,
              child: _built.contains(i) ? _tab(i) : const SizedBox.shrink(),
            ),
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
