import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:y_node/data/models.dart';
import 'package:y_node/state/app_state.dart';
import 'package:y_node/ui/exit_card.dart';

/// The two self-check rows describe the live tunnel, so they must not appear
/// while it is down: their buttons cannot work then and the counters are gone.
void main() {
  const profile = ExitProfile(
    id: 'exit-1',
    name: 'Test exit',
    address: '200::1',
  );

  const connectedExit = ExitStatus(
    enabled: true,
    state: 'online',
    activeId: 'exit-1',
    profiles: [
      ExitProfileStatus(id: 'exit-1', name: 'Test exit', address: '200::1'),
    ],
    udp: ExitUdpStatus(enabled: true, state: 'idle'),
    updatedAt: 1,
  );

  AppState stateWith(VpnSnapshot snapshot) {
    final state = AppState();
    state.settings = const AppSettings(
      exitEnabled: true,
      exitProfiles: [profile],
    );
    state.snapshot = snapshot;
    return state;
  }

  Future<void> pumpCard(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: ExitNodeCard(state: state)),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the relay and IPv6 rows are hidden while the tunnel is down', (
    tester,
  ) async {
    await pumpCard(
      tester,
      stateWith(const VpnSnapshot(status: 'disconnected')),
    );

    expect(find.text('UDP relay'), findsNothing);
    expect(find.text('IPv6'), findsNothing);
    // The exit switch itself stays: it is a setting, not a live value.
    expect(find.text('Exit node'), findsWidgets);
  });

  testWidgets('both rows appear once the tunnel is up', (tester) async {
    await pumpCard(
      tester,
      stateWith(const VpnSnapshot(status: 'connected', exit: connectedExit)),
    );

    expect(find.text('UDP relay'), findsOneWidget);
    expect(find.text('IPv6'), findsOneWidget);
    expect(
      find.text('Global IPv6 addresses go through the exit node'),
      findsOneWidget,
    );
  });

  testWidgets('a limited status explains the missing API token', (
    tester,
  ) async {
    const limited = ExitStatus(
      enabled: true,
      state: 'online',
      activeId: 'exit-1',
      profiles: [
        ExitProfileStatus(
          id: 'exit-1',
          name: 'Test exit',
          address: '200::1',
          authenticated: false,
        ),
      ],
      udp: ExitUdpStatus(enabled: true, state: 'idle'),
      updatedAt: 1,
    );
    await pumpCard(
      tester,
      stateWith(const VpnSnapshot(status: 'connected', exit: limited)),
    );

    expect(find.text('API access is limited'), findsOneWidget);
  });

  testWidgets('an authenticated status has no API hint', (tester) async {
    await pumpCard(
      tester,
      stateWith(const VpnSnapshot(status: 'connected', exit: connectedExit)),
    );

    expect(find.text('API access is limited'), findsNothing);
  });

  testWidgets('the quota row shows usage and names the real reason', (
    tester,
  ) async {
    const exhausted = ExitStatus(
      enabled: true,
      state: 'online',
      activeId: 'exit-1',
      profiles: [
        ExitProfileStatus(
          id: 'exit-1',
          name: 'Test exit',
          address: '200::1',
          refused: 5,
          quotaRefused: 4,
          maxConns: 128,
          quota: ExitQuota(
            dailyBytes: 5000000000,
            downKbps: 20000,
            upKbps: 5000,
            dayUsed: 5000000000,
            exhausted: true,
            reason: 'daily quota exhausted',
          ),
        ),
      ],
      udp: ExitUdpStatus(enabled: true, state: 'idle'),
      updatedAt: 1,
    );
    await pumpCard(
      tester,
      stateWith(const VpnSnapshot(status: 'connected', exit: exhausted)),
    );

    expect(find.text('Traffic quota'), findsOneWidget);
    expect(find.text('Today 5 GB of 5 GB'), findsOneWidget);
    expect(
      find.text('Download limit 20 Mbit/s · Upload limit 5 Mbit/s'),
      findsOneWidget,
    );
    expect(find.text('The daily traffic quota is exhausted'), findsOneWidget);
    // The refusal counter includes quota refusals, but the card must not call
    // them a connection-limit problem.
    expect(find.textContaining('at its limit of'), findsNothing);
  });

  testWidgets('a suspended client is named and warns at a glance', (
    tester,
  ) async {
    const suspended = ExitStatus(
      enabled: true,
      state: 'online',
      activeId: 'exit-1',
      profiles: [
        ExitProfileStatus(
          id: 'exit-1',
          name: 'Test exit',
          address: '200::1',
          suspended: true,
        ),
      ],
      udp: ExitUdpStatus(enabled: true, state: 'idle'),
      updatedAt: 1,
    );
    await pumpCard(
      tester,
      stateWith(const VpnSnapshot(status: 'connected', exit: suspended)),
    );

    expect(find.text('The operator suspended this client'), findsOneWidget);
    expect(find.text('Suspended'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });
}
