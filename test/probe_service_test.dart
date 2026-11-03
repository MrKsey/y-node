import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:y_node/data/probe_service.dart';

void main() {
  group('TcpRttProbe', () {
    late ServerSocket server;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) => socket.destroy());
    });

    tearDown(() async {
      await server.close();
    });

    test('measures a reachable port', () async {
      const probe = TcpRttProbe();
      final rtt = await probe.measure(
        InternetAddress.loopbackIPv4.address,
        server.port,
      );
      expect(rtt, isNotNull);
      expect(rtt!, greaterThanOrEqualTo(0));
    });

    test('returns null for a closed port', () async {
      const probe = TcpRttProbe();
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      final rtt = await probe.measure(
        InternetAddress.loopbackIPv4.address,
        port,
        timeout: const Duration(milliseconds: 400),
      );
      expect(rtt, isNull);
    });

    test('skips QUIC targets and duplicate hosts', () async {
      const probe = TcpRttProbe();
      final results = await probe.measureAll([
        (
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
          scheme: 'tcp',
        ),
        (
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
          scheme: 'tls',
        ),
        (host: 'quic.example', port: 443, scheme: 'quic'),
      ], timeout: const Duration(milliseconds: 400));
      expect(results.keys, [InternetAddress.loopbackIPv4.address]);
    });

    test('stops early when cancelled', () async {
      const probe = TcpRttProbe();
      final results = await probe.measureAll([
        (host: '192.0.2.1', port: 443, scheme: 'tcp'),
        (host: '192.0.2.2', port: 443, scheme: 'tcp'),
      ], isCancelled: () => true);
      expect(results, isEmpty);
    });
  });
}
