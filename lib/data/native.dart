import 'dart:convert';

import 'package:flutter/services.dart';

import 'ip_check.dart';
import 'models.dart';

/// The bridge to the Android side.
///
/// Everything the tunnel needs lives in the service; this class only sends
/// commands and reads the shared state back. All methods are safe to call when
/// the native side is missing (unit tests, desktop), in which case they return a
/// neutral value instead of throwing.
class Native {
  const Native._();

  static const MethodChannel _vpn = MethodChannel('com.yggnode.app/vpn');
  static const MethodChannel _storage = MethodChannel(
    'com.yggnode.app/storage',
  );
  static const EventChannel _status = EventChannel('com.yggnode.app/status');

  // ------------------------------------------------------------------
  // VPN
  // ------------------------------------------------------------------

  static Future<bool> prepare() async {
    try {
      // The system dialog waits for the user; a lost activity result must not
      // leave the Connect button spinning forever.
      final granted = await _vpn
          .invokeMethod<bool>('prepare')
          .timeout(const Duration(minutes: 3), onTimeout: () => false);
      return granted ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Asks the service to bring the tunnel up. Returns false when Android did
  /// not accept the command: a foreground service started from the background
  /// is refused on Android 12+, and the UI must not wait for a state that will
  /// never arrive.
  static Future<bool> connect() async {
    try {
      final accepted = await _vpn
          .invokeMethod<bool>('connect')
          .timeout(const Duration(seconds: 20), onTimeout: () => false);
      return accepted ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // Tests and desktop have no Android side.
      return true;
    }
  }

  /// Asks the service to drop the tunnel.
  static Future<bool> disconnect() async {
    try {
      final accepted = await _vpn
          .invokeMethod<bool>('disconnect')
          .timeout(const Duration(seconds: 20), onTimeout: () => false);
      return accepted ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return true;
    }
  }

  /// Reads the current service state, or null when the channel did not answer
  /// in time. Null is not "disconnected": treating a slow reply as a dropped
  /// tunnel made the UI restart a live link.
  static Future<VpnSnapshot?> getState() async {
    try {
      final map = await _vpn
          .invokeMapMethod<dynamic, dynamic>('getState')
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
      if (map == null) return null;
      return VpnSnapshot.fromMap(map);
    } catch (_) {
      return null;
    }
  }

  static Future<void> applyPeers(List<PeerEntry> peers, List<PeerEntry> pool) =>
      _guard(
        () => _vpn
            .invokeMethod('applyPeers', {
              'peers': PeerEntry.listToJson(peers),
              'pool': PeerEntry.listToJson(pool),
            })
            .timeout(const Duration(seconds: 10), onTimeout: () => null),
      );

  /// Asks the service to re-read the live peer state right away.
  static Future<void> refreshPeers() => _guard(
    () => _vpn
        .invokeMethod('refreshPeers')
        .timeout(const Duration(seconds: 5), onTimeout: () => null),
  );

  /// Checks the DNS servers through the running node.
  static Future<List<DnsCheck>> checkDns(List<String> servers) async {
    if (servers.isEmpty) return const [];
    try {
      final raw = await _vpn
          .invokeMethod<String>('checkDns', {'servers': servers})
          .timeout(const Duration(seconds: 30), onTimeout: () => null);
      return decodeDnsChecks(raw);
    } catch (_) {
      return const [];
    }
  }

  /// Fetches a Yggdrasil page with the node itself. The app process is outside
  /// the VPN, so an ordinary HTTP client cannot reach the network.
  static Future<FetchResult> fetchUrl(
    String url, {
    int timeoutMs = 20000,
  }) async {
    try {
      final raw = await _vpn
          .invokeMethod<String>('fetchUrl', {
            'url': url,
            'timeoutMs': timeoutMs,
          })
          .timeout(
            Duration(milliseconds: timeoutMs + 8000),
            onTimeout: () => null,
          );
      return decodeFetchResult(raw);
    } catch (_) {
      return const FetchResult(error: 'request failed');
    }
  }

  /// Runs one probe round. Each URI is dialled by a temporary Yggdrasil node and
  /// the result carries the protocol latency for the ones that completed the
  /// handshake.
  static Future<List<ProbeResult>> probe(
    List<String> uris, {
    int timeoutMs = 8000,
  }) async {
    if (uris.isEmpty) return const [];
    try {
      final raw = await _vpn
          .invokeMethod<String>('probePeers', {
            'uris': uris,
            'timeoutMs': timeoutMs,
          })
          .timeout(
            Duration(milliseconds: timeoutMs + 15000),
            onTimeout: () => null,
          );
      return decodeProbeResults(raw);
    } catch (_) {
      return const [];
    }
  }

  /// Parses the probe JSON. Exposed so it can be tested without a device.
  static List<ProbeResult> decodeProbeResults(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    return decodeProbeJson(raw);
  }

  /// The exit state and profile health as reported by the Go bridge.
  static Future<ExitStatus?> exitStatus() async {
    try {
      final raw = await _vpn
          .invokeMethod<String>('exitStatus')
          .timeout(const Duration(seconds: 5), onTimeout: () => null);
      return ExitStatus.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  /// Asks every exit profile's status API whether this node is allowed.
  static Future<ExitStatus?> checkExitProfiles({int timeoutMs = 8000}) async {
    try {
      final raw = await _vpn
          .invokeMethod<String>('checkExit', {'timeoutMs': timeoutMs})
          .timeout(
            Duration(milliseconds: timeoutMs + 10000),
            onTimeout: () => null,
          );
      return ExitStatus.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  /// Checks the UDP relay of the active exit: a DNS query through the exit and
  /// a QUIC handshake to the resolved address.
  static Future<UdpProbeResult?> testExitUdp({int timeoutMs = 15000}) async {
    try {
      final raw = await _vpn
          .invokeMethod<String>('testExitUdp', {'timeoutMs': timeoutMs})
          .timeout(
            Duration(milliseconds: timeoutMs + 10000),
            onTimeout: () => null,
          );
      return UdpProbeResult.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  /// Checks IPv6 through the active exit: an HTTPS request to a literal IPv6
  /// address and an AAAA query over the UDP relay.
  static Future<Ipv6ProbeResult?> testExitIpv6({int timeoutMs = 15000}) async {
    try {
      final raw = await _vpn
          .invokeMethod<String>('testExitIpv6', {'timeoutMs': timeoutMs})
          .timeout(
            Duration(milliseconds: timeoutMs + 10000),
            onTimeout: () => null,
          );
      return Ipv6ProbeResult.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  /// Rebuilds the forwarder with the exit configuration currently stored in the
  /// shared preferences. Used after a profile is added or edited.
  static Future<bool> applyExitConfig() async {
    try {
      return await _vpn
              .invokeMethod<bool>('applyExitConfig')
              .timeout(const Duration(seconds: 15), onTimeout: () => false) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// The address a remote service sees through the running exit node. The
  /// answer is the address the exit sends the traffic from, not the client's
  /// Yggdrasil address.
  static Future<PublicIpResult?> exitPublicIp({int timeoutMs = 12000}) async {
    try {
      final raw = await _vpn
          .invokeMethod<String>('publicIp', {
            'via': 'exit',
            'timeoutMs': timeoutMs,
          })
          .timeout(
            Duration(milliseconds: timeoutMs + 8000),
            onTimeout: () => null,
          );
      return PublicIpResult.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  /// Redeems an invite token on an exit node through the running tunnel.
  static Future<ExitRegistration?> registerExit({
    required String profileId,
    required String invite,
  }) async {
    try {
      final raw = await _vpn
          .invokeMethod<String>('registerExit', {
            'profileId': profileId,
            'invite': invite,
          })
          .timeout(const Duration(seconds: 30), onTimeout: () => null);
      return ExitRegistration.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  static Future<Identity?> generateIdentity() async {
    try {
      final raw = await _vpn
          .invokeMethod<String>('generateIdentity')
          .timeout(const Duration(seconds: 30), onTimeout: () => null);
      if (raw == null) return null;
      return decodeIdentity(raw);
    } catch (_) {
      return null;
    }
  }

  static Future<String> getLog() async {
    try {
      return await _vpn
              .invokeMethod<String>('getLog')
              .timeout(const Duration(seconds: 10), onTimeout: () => '') ??
          '';
    } catch (_) {
      return '';
    }
  }

  static Future<void> clearLog() => _guard(
    () => _vpn
        .invokeMethod('clearLog')
        .timeout(const Duration(seconds: 10), onTimeout: () => null),
  );

  static Future<String> logPath() async {
    try {
      return await _vpn.invokeMethod<String>('logPath') ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<int> logSize() async {
    try {
      return await _vpn.invokeMethod<int>('logSize') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> setLogging(bool enabled) =>
      _guard(() => _vpn.invokeMethod('setLogging', {'enabled': enabled}));

  static Future<List<InstalledApp>> listApps() async {
    try {
      final list = await _vpn
          .invokeListMethod<dynamic>('listApps')
          .timeout(const Duration(seconds: 30), onTimeout: () => null);
      if (list == null) return const [];
      return list
          .whereType<Map<dynamic, dynamic>>()
          .map(InstalledApp.fromMap)
          .where((app) => app.packageName.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<Uint8List?> appIcon(String packageName) async {
    try {
      return await _vpn
          .invokeMethod<Uint8List>('appIcon', {'package': packageName})
          .timeout(const Duration(seconds: 10), onTimeout: () => null);
    } catch (_) {
      return null;
    }
  }

  /// The app Android would open for a web link, or an empty string. The system
  /// is the only reliable source: the user may have picked any browser.
  static Future<String> defaultBrowser() async {
    try {
      return await _vpn
              .invokeMethod<String>('defaultBrowser')
              .timeout(const Duration(seconds: 5), onTimeout: () => '') ??
          '';
    } catch (_) {
      return '';
    }
  }

  static Future<bool> isBatteryExempt() async {
    try {
      return await _vpn
              .invokeMethod<bool>('isBatteryExempt')
              .timeout(const Duration(seconds: 5), onTimeout: () => null) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestBatteryExemption() =>
      _guard(() => _vpn.invokeMethod('requestBatteryExemption'));

  /// Opens the system list where the exemption can be removed by hand.
  static Future<void> openBatteryOptimizationList() =>
      _guard(() => _vpn.invokeMethod('openBatteryOptimizationList'));

  static Future<bool> hasNotificationPermission() async {
    try {
      return await _vpn
              .invokeMethod<bool>('hasNotificationPermission')
              .timeout(const Duration(seconds: 5), onTimeout: () => null) ??
          true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> requestNotifications() =>
      _guard(() => _vpn.invokeMethod('requestNotifications'));

  static Future<void> openAppSettings() =>
      _guard(() => _vpn.invokeMethod('openAppSettings'));

  static Future<String> yggVersion() async {
    try {
      return await _vpn
              .invokeMethod<String>('yggVersion')
              .timeout(const Duration(seconds: 10), onTimeout: () => '') ??
          '';
    } catch (_) {
      return '';
    }
  }

  static Future<String> appVersion() async {
    try {
      return await _vpn
              .invokeMethod<String>('appVersion')
              .timeout(const Duration(seconds: 5), onTimeout: () => '') ??
          '';
    } catch (_) {
      return '';
    }
  }

  static Stream<VpnSnapshot> statusStream() => _status
      .receiveBroadcastStream()
      .map((event) => VpnSnapshot.fromMap(event as Map<dynamic, dynamic>));

  // ------------------------------------------------------------------
  // Storage
  // ------------------------------------------------------------------

  static Future<String?> read(String key) async {
    try {
      return await _storage
          .invokeMethod<String>('get', {'key': key})
          .timeout(const Duration(seconds: 10), onTimeout: () => null);
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String key, String value) => _guard(
    () => _storage
        .invokeMethod('put', {'key': key, 'value': value})
        .timeout(const Duration(seconds: 10), onTimeout: () => null),
  );

  static Future<void> delete(String key) => _guard(
    () => _storage
        .invokeMethod('remove', {'key': key})
        .timeout(const Duration(seconds: 10), onTimeout: () => null),
  );

  static Future<Map<String, String>> readAll() async {
    try {
      final map = await _storage
          .invokeMapMethod<String, String>('all')
          .timeout(const Duration(seconds: 10), onTimeout: () => null);
      return map ?? const {};
    } catch (_) {
      return const {};
    }
  }

  static Future<void> _guard(Future<dynamic> Function() action) async {
    try {
      await action();
    } on PlatformException {
      // The service reports its own errors through the state stream; a failed
      // command here must not crash the UI.
    } on MissingPluginException {
      // Running without the Android side (tests, desktop).
    }
  }
}

/// Parses the probe JSON returned by the native side. Exposed as a plain
/// function so it can be unit tested without a device.
List<ProbeResult> decodeProbeJson(String raw) {
  if (raw.trim().isEmpty) return const [];
  try {
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .whereType<Map<String, dynamic>>()
        .map(ProbeResult.fromJson)
        .where((result) => result.uri.isNotEmpty)
        .toList();
  } catch (_) {
    return const [];
  }
}

/// Parses the DNS check JSON. Exposed for the unit tests.
List<DnsCheck> decodeDnsChecks(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  try {
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .whereType<Map<String, dynamic>>()
        .map(DnsCheck.fromJson)
        .where((check) => check.server.isNotEmpty)
        .toList();
  } catch (_) {
    return const [];
  }
}

/// Parses the page JSON. Exposed for the unit tests.
FetchResult decodeFetchResult(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return const FetchResult(error: 'empty response');
  }
  try {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return FetchResult.fromJson(map);
  } catch (_) {
    return const FetchResult(error: 'bad response');
  }
}

/// Parses the identity JSON returned by the native side.
Identity? decodeIdentity(String raw) {
  if (raw.trim().isEmpty) return null;
  try {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final identity = Identity.fromJson(map);
    return identity.isValid ? identity : null;
  } catch (_) {
    return null;
  }
}
