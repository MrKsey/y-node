import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:y_node/data/probe_service.dart';
import 'package:y_node/state/app_state.dart';
import 'package:y_node/ui/onboarding_screen.dart';

/// The first-run peer search used to read the final list, which is filled only
/// when the round ends: the label said "Live nodes found: 0" for the whole
/// search even after peers had answered. The count must follow the round, and a
/// round that has not reached the protocol yet must not claim a zero.
void main() {
  Future<void> pumpPeersPage(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: OnboardingScreen()),
      ),
    );
    for (var page = 0; page < 2; page++) {
      await tester.drag(find.byType(PageView), const Offset(-500, 0));
      // A fixed pump instead of pumpAndSettle: the identity page keeps a
      // spinner running while the test has no identity to show.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  testWidgets('the search counts the answers of the running round', (
    tester,
  ) async {
    final state = AppState()
      ..probing = true
      ..probeProgress = const ProbeProgress(
        phase: 'ygg',
        tested: 10,
        total: 40,
        alive: 3,
      );
    expect(state.probeAlive, isEmpty);

    await pumpPeersPage(tester, state);

    expect(find.text('Live nodes found: 3'), findsOneWidget);
  });

  testWidgets('a round without an answer yet does not show a zero', (
    tester,
  ) async {
    final state = AppState()
      ..probing = true
      ..probeProgress = const ProbeProgress(
        phase: 'tcp',
        tested: 0,
        total: 160,
        alive: 0,
      );

    await pumpPeersPage(tester, state);

    expect(find.text('Live nodes found: 0'), findsNothing);
  });
}
