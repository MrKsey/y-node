import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:y_node/data/models.dart';
import 'package:y_node/state/app_state.dart';
import 'package:y_node/ui/home_screen.dart';

void _noop() {}

/// The tunnel screen must keep showing live bytes: they moved to a separate
/// notifier to stop rebuilding every tab, but the two numbers still have to
/// follow it.
void main() {
  testWidgets('the home counters follow the traffic notifier', (tester) async {
    final state = AppState();
    state.settings = const AppSettings(dnsMode: DnsMode.system);
    state.snapshot = const VpnSnapshot(
      status: 'connected',
      nodeAddress: '200::1',
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: HomeScreen(onOpenPeers: _noop)),
      ),
    );
    await tester.pump();

    expect(find.text('0 B'), findsNWidgets(2));

    state.traffic.value = const TrafficCounters(rx: 2048, tx: 1024);
    await tester.pump();

    expect(find.text('2.0 KB'), findsOneWidget);
    expect(find.text('1.0 KB'), findsOneWidget);

    // The hero pulse repeats while the tunnel is up; unmount it so the test
    // does not end with an active ticker.
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('the uptime clock ticks without switching tabs', (tester) async {
    final state = AppState();
    state.settings = const AppSettings(dnsMode: DnsMode.system);
    state.snapshot = VpnSnapshot(
      status: 'connected',
      nodeAddress: '200::1',
      // A peer has to be up, otherwise the hero still shows the "waiting for
      // the first peer" stage instead of the uptime line.
      peersUp: 1,
      peersTotal: 1,
      connectedAt: DateTime.now().millisecondsSinceEpoch - 5000,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: HomeScreen(onOpenPeers: _noop)),
      ),
    );
    await tester.pump();

    String clock() => tester
        .widgetList<Text>(find.textContaining('Connected for'))
        .first
        .data!;
    final first = clock();

    // Real time has to pass: the clock reads DateTime.now(), which the fake
    // test clock does not move. The periodic timer itself lives in the fake
    // zone, so one pump after the wait fires it and the rebuild reads the new
    // wall clock. This is exactly the case the bug was in — the timer was
    // never started on the first build, so the text never changed.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1200)),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(clock(), isNot(first));

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
