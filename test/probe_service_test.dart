import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:y_node/data/models.dart';
import 'package:y_node/data/peers_source.dart';
import 'package:y_node/data/probe_service.dart';

void main() {
  group('ProbeService order', () {
    PeerCandidate peer(String host, String country) => PeerCandidate(
      uri: 'tls://$host:1',
      host: host,
      port: 1,
      country: country,
      city: '',
      scheme: 'tls',
    );

    test('a round probes the home country first, then the TCP time', () {
      final candidates = [
        peer('msk', 'russia'),
        peer('vvo', 'russia'),
        peer('hel', 'finland'),
        peer('fra', 'germany'),
      ];
      final queue = ProbeService.probeQueue(candidates, {
        'msk': 6,
        'vvo': 171,
        'hel': 19,
        'fra': 47,
      }, 'russia');
      expect(
        [for (final item in queue) item.host],
        ['msk', 'vvo', 'hel', 'fra'],
      );
    });

    test('a country without peers falls back to the nearest servers', () {
      final candidates = [
        peer('fra', 'germany'),
        peer('hel', 'finland'),
        peer('msk', 'russia'),
      ];
      final queue = ProbeService.probeQueue(candidates, {
        'fra': 47,
        'hel': 19,
        'msk': 6,
      }, 'spain');
      expect([for (final item in queue) item.host], ['msk', 'hel', 'fra']);
    });

    test('the fastest answer leads even when it is in another country', () {
      final rows = [
        ProbeResult(uri: 'tls://vvo:1', up: true, latencyMs: 171),
        ProbeResult(uri: 'tls://msk:1', up: true, latencyMs: 6),
        ProbeResult(uri: 'tls://hel:1', up: true, latencyMs: 19),
      ];
      ProbeService.sortByLatency(rows);
      expect([for (final row in rows) row.latencyMs], [6, 19, 171]);
    });
  });

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
