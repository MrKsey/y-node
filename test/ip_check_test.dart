import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:y_node/data/ip_check.dart';
import 'package:y_node/ui/ip_balloon.dart';

void main() {
  test('the trace page yields the address', () {
    const body = 'fl=1255f34\nh=1.1.1.1\nip=160.20.158.195\nloc=FI\n';
    expect(parseTraceIp(body), '160.20.158.195');
  });

  test('an IPv6 answer is kept as it came', () {
    expect(
      parseTraceIp('ip=2a02:8109:9c3f:ac00:1::1\n'),
      '2a02:8109:9c3f:ac00:1::1',
    );
  });

  test('a page without a valid address yields nothing', () {
    expect(parseTraceIp('<html>blocked</html>'), isNull);
    expect(parseTraceIp('ip=not-an-address'), isNull);
    expect(parseTraceIp('ip=\n'), isNull);
  });

  test('the bridge answer is parsed', () {
    final result = PublicIpResult.tryParse(
      '{"ok":true,"ip":"160.20.158.195","via":"exit","ms":95.5}',
    );
    expect(result, isNotNull);
    expect(result!.ok, isTrue);
    expect(result.ip, '160.20.158.195');
    expect(result.via, 'exit');
    expect(result.ms, 95.5);
    expect(PublicIpResult.tryParse('not json'), isNull);
    expect(PublicIpResult.tryParse(''), isNull);
  });

  testWidgets('the balloon shows the address without the tunnel', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showIpBalloon(
                  context: context,
                  anchorContext: context,
                  viaExit: false,
                  load: () async => const PublicIpResult(
                    ok: true,
                    ip: '203.0.113.7',
                    via: 'direct',
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('203.0.113.7'), findsOneWidget);
    expect(find.text('Without the tunnel'), findsOneWidget);
    expect(find.text('What websites see on the real network'), findsOneWidget);
  });

  testWidgets('the balloon explains that the exit is off', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showIpBalloon(
                  context: context,
                  anchorContext: context,
                  viaExit: true,
                  load: () async =>
                      const PublicIpResult(via: 'exit', error: 'exit_off'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Through the exit'), findsOneWidget);
    expect(find.text('The exit is off'), findsOneWidget);
  });
}
