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
}

void _noop() {}
