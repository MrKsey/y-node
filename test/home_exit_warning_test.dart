import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:y_node/data/models.dart';
import 'package:y_node/state/app_state.dart';
import 'package:y_node/ui/home_screen.dart';

/// The exit end of the hero link is the icon with the country flag. A used-up
/// quota or an operator suspension must be visible there, not only inside the
/// exit card further down the screen.
void main() {
  const profile = ExitProfile(
    id: 'exit-1',
    name: 'Test exit',
    address: '200::1',
  );

  AppState stateWith(ExitProfileStatus profileStatus) {
    final state = AppState();
    state.settings = const AppSettings(
      exitEnabled: true,
      exitProfiles: [profile],
    );
    state.snapshot = VpnSnapshot(
      status: 'connected',
      exit: ExitStatus(
        enabled: true,
        state: 'online',
        activeId: 'exit-1',
        profiles: [profileStatus],
        udp: const ExitUdpStatus(enabled: true, state: 'idle'),
        updatedAt: 1,
      ),
    );
    return state;
  }

  Future<void> pumpHome(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: HomeScreen(onOpenPeers: _noop)),
      ),
    );
    await tester.pump();
  }

  testWidgets('an exhausted quota warns on the exit icon', (tester) async {
    await pumpHome(
      tester,
      stateWith(
        const ExitProfileStatus(
          id: 'exit-1',
          name: 'Test exit',
          address: '200::1',
          quota: ExitQuota(
            dailyBytes: 5000000000,
            dayUsed: 5000000000,
            exhausted: true,
            reason: 'daily quota exhausted',
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.priority_high_rounded), findsOneWidget);
  });

  testWidgets('a suspension warns on the exit icon', (tester) async {
    await pumpHome(
      tester,
      stateWith(
        const ExitProfileStatus(
          id: 'exit-1',
          name: 'Test exit',
          address: '200::1',
          suspended: true,
        ),
      ),
    );

    expect(find.byIcon(Icons.priority_high_rounded), findsOneWidget);
  });

  testWidgets('a healthy exit has no warning badge', (tester) async {
    await pumpHome(
      tester,
      stateWith(
        const ExitProfileStatus(
          id: 'exit-1',
          name: 'Test exit',
          address: '200::1',
        ),
      ),
    );

    expect(find.byIcon(Icons.priority_high_rounded), findsNothing);
  });

  /// With several configured nodes only the selected one is the exit the
  /// tunnel uses: its flag is on the hero link and only its row carries the
  /// lock. The other node is a stored profile, not a failover target.
  testWidgets('the flag and the lock follow the selected node', (tester) async {
    const first = ExitProfile(
      id: 'exit-1',
      name: 'First exit',
      address: '200::1',
      peer: 'tls://203.0.113.10:13338?key=a',
    );
    const second = ExitProfile(
      id: 'exit-2',
      name: 'Second exit',
      address: '200::2',
      peer: 'tls://203.0.113.11:13338?key=b',
    );
    final state = AppState();
    state.settings = const AppSettings(
      exitEnabled: true,
      exitProfiles: [first, second],
      exitActiveId: 'exit-2',
    );
    state.peers = const [
      PeerEntry(
        uri: 'tls://203.0.113.10:13338?key=a',
        pinned: true,
        country: 'finland',
      ),
      PeerEntry(
        uri: 'tls://203.0.113.11:13338?key=b',
        pinned: true,
        country: 'germany',
      ),
    ];
    state.snapshot = VpnSnapshot(
      status: 'connected',
      exit: const ExitStatus(
        enabled: true,
        state: 'online',
        activeId: 'exit-2',
        profiles: [
          ExitProfileStatus(id: 'exit-1', name: 'First exit'),
          ExitProfileStatus(id: 'exit-2', name: 'Second exit'),
        ],
        udp: ExitUdpStatus(enabled: true, state: 'idle'),
        updatedAt: 1,
      ),
    );

    await pumpHome(tester, state);

    // The German flag is drawn twice: on the hero link and in the row of the
    // selected node. The Finnish one only belongs to the stored profile.
    expect(find.text('🇩🇪'), findsNWidgets(2));
    expect(find.text('🇫🇮'), findsOneWidget);
    // One lock on the hero icon and one on the row of the selected node.
    expect(find.byIcon(Icons.lock_rounded), findsNWidgets(2));
  });
}

void _noop() {}
