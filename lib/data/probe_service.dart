import 'dart:async';
import 'dart:io';

import 'models.dart';
import 'native.dart';
import 'peers_source.dart';

/// How far a probe run has got, for the progress bar on the peer screen.
class ProbeProgress {
  const ProbeProgress({
    required this.phase,
    required this.tested,
    required this.total,
    required this.alive,
  });

  /// `tcp` while measuring connect times, `ygg` while dialling the protocol.
  final String phase;
  final int tested;
  final int total;
  final int alive;

  double get fraction => total <= 0 ? 0 : (tested / total).clamp(0, 1);
}

/// The outcome of one full probe run.
class ProbeSession {
  const ProbeSession({
    required this.alive,
    required this.dead,
    required this.cancelled,
    this.totalCandidates = 0,
  });

  final List<ProbeResult> alive;
  final List<ProbeResult> dead;
  final bool cancelled;
  final int totalCandidates;

  bool get isEmpty => alive.isEmpty;
}

/// Measures the real Yggdrasil latency of public peers.
///
/// A full list has several hundred hosts and a protocol handshake costs a
/// second or two even for a dead peer, so the run is done in two passes:
///
/// 1. a cheap TCP connect to every host, which orders the list by something
///    close to network distance and throws out the obviously dead;
/// 2. Yggdrasil handshakes in batches of five, most promising first, stopping as
///    soon as enough peers are alive. The user gets a usable list in a couple of
///    seconds instead of waiting for the whole catalogue.
class ProbeService {
  ProbeService({TcpRttProbe? tcpProbe}) : _tcpProbe = tcpProbe ?? TcpRttProbe();

  final TcpRttProbe _tcpProbe;

  static const int defaultTargetAlive = 12;

  Future<ProbeSession> run(
    List<PeerCandidate> candidates, {
    int batch = 5,
    int timeoutMs = 8000,
    int targetAlive = defaultTargetAlive,
    void Function(ProbeProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (candidates.isEmpty) {
      return const ProbeSession(alive: [], dead: [], cancelled: false);
    }

    bool cancelled() => isCancelled?.call() ?? false;

    onProgress?.call(
      ProbeProgress(
        phase: 'tcp',
        tested: 0,
        total: candidates.length,
        alive: 0,
      ),
    );

    final rtts = await _tcpProbe.measureAll(
      [
        for (final candidate in candidates)
          (
            host: candidate.host,
            port: candidate.port,
            scheme: candidate.scheme,
          ),
      ],
      concurrency: 32,
      timeout: const Duration(milliseconds: 2500),
      isCancelled: cancelled,
    );

    if (cancelled()) {
      return ProbeSession(
        alive: const [],
        dead: const [],
        cancelled: true,
        totalCandidates: candidates.length,
      );
    }

    final ordered = [...candidates];
    ordered.sort((a, b) {
      final aRtt = rtts[a.host] ?? double.infinity;
      final bRtt = rtts[b.host] ?? double.infinity;
      if (aRtt != bRtt) return aRtt.compareTo(bRtt);
      return a.uri.compareTo(b.uri);
    });

    final alive = <ProbeResult>[];
    final dead = <ProbeResult>[];
    var tested = 0;

    for (var start = 0; start < ordered.length; start += batch) {
      if (cancelled()) {
        return ProbeSession(
          alive: alive,
          dead: dead,
          cancelled: true,
          totalCandidates: candidates.length,
        );
      }
      if (alive.length >= targetAlive) break;

      final slice = ordered.skip(start).take(batch).toList();
      final uris = [for (final candidate in slice) candidate.uri];
      final results = await Native.probe(uris, timeoutMs: timeoutMs);

      final byUri = {for (final result in results) result.uri: result};
      for (final candidate in slice) {
        final result = byUri[candidate.uri];
        final enriched = (result ?? ProbeResult(uri: candidate.uri, up: false))
            .copyWith(
              country: candidate.country,
              city: candidate.city,
              tcpRttMs: rtts[candidate.host] ?? 0,
            );
        if (enriched.up && enriched.latencyMs > 0) {
          alive.add(enriched);
        } else {
          dead.add(enriched);
        }
        tested++;
      }

      onProgress?.call(
        ProbeProgress(
          phase: 'ygg',
          tested: tested,
          total: ordered.length,
          alive: alive.length,
        ),
      );
    }

    alive.sort((a, b) => a.latencyMs.compareTo(b.latencyMs));
    return ProbeSession(
      alive: alive,
      dead: dead,
      cancelled: false,
      totalCandidates: candidates.length,
    );
  }
}

/// Measures plain TCP connect time. Used only to order the Yggdrasil pass, never
/// to decide that a peer is dead: QUIC peers do not listen on TCP at all.
class TcpRttProbe {
  const TcpRttProbe();

  Future<Map<String, double>> measureAll(
    List<({String host, int port, String scheme})> targets, {
    int concurrency = 32,
    Duration timeout = const Duration(milliseconds: 2500),
    bool Function()? isCancelled,
  }) async {
    final results = <String, double>{};
    final pending = <({String host, int port, String scheme})>[];
    final seen = <String>{};
    for (final target in targets) {
      if (target.host.isEmpty || target.port <= 0) continue;
      if (target.scheme == 'quic') continue;
      if (!seen.add(target.host)) continue;
      pending.add(target);
    }

    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        if (isCancelled?.call() ?? false) return;
        final index = cursor++;
        if (index >= pending.length) return;
        final target = pending[index];
        final rtt = await measure(target.host, target.port, timeout: timeout);
        if (rtt != null) results[target.host] = rtt;
      }
    }

    final workers = <Future<void>>[
      for (var i = 0; i < concurrency && i < pending.length; i++) worker(),
    ];
    await Future.wait(workers);
    return results;
  }

  Future<double?> measure(
    String host,
    int port, {
    Duration timeout = const Duration(milliseconds: 2500),
  }) async {
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      stopwatch.stop();
      return stopwatch.elapsedMicroseconds / 1000.0;
    } catch (_) {
      return null;
    } finally {
      try {
        socket?.destroy();
      } catch (_) {
        // Nothing to do, the socket is already gone.
      }
    }
  }
}
