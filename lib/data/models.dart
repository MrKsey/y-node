import 'dart:convert';

/// A peer the tunnel should keep connected.
class PeerEntry {
  const PeerEntry({
    required this.uri,
    this.country = '',
    this.city = '',
    this.latencyMs = 0,
    this.tcpRttMs = 0,
    this.pinned = false,
  });

  final String uri;
  final String country;
  final String city;

  /// Latency measured over the Yggdrasil protocol, in milliseconds.
  final double latencyMs;

  /// Plain TCP connect time, used only for the first ranking pass.
  final double tcpRttMs;

  /// A pinned peer belongs to an exit node. The list never drops it on its own:
  /// the supervisor does not replace it and the UI does not offer a remove
  /// button. It disappears only with the exit profile that added it.
  final bool pinned;

  factory PeerEntry.fromJson(Map<String, dynamic> json) => PeerEntry(
    uri: (json['uri'] as String?) ?? '',
    country: (json['country'] as String?) ?? '',
    city: (json['city'] as String?) ?? '',
    latencyMs: (json['latencyMs'] as num?)?.toDouble() ?? 0,
    tcpRttMs: (json['tcpRttMs'] as num?)?.toDouble() ?? 0,
    pinned: (json['pinned'] as bool?) ?? false,
  );

  Map<String, dynamic> toJson() => {
    'uri': uri,
    'country': country,
    'city': city,
    'latencyMs': latencyMs,
    'tcpRttMs': tcpRttMs,
    if (pinned) 'pinned': true,
  };

  PeerEntry copyWith({
    String? uri,
    String? country,
    String? city,
    double? latencyMs,
    double? tcpRttMs,
    bool? pinned,
  }) => PeerEntry(
    uri: uri ?? this.uri,
    country: country ?? this.country,
    city: city ?? this.city,
    latencyMs: latencyMs ?? this.latencyMs,
    tcpRttMs: tcpRttMs ?? this.tcpRttMs,
    pinned: pinned ?? this.pinned,
  );

  static List<PeerEntry> listFromJson(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(PeerEntry.fromJson)
          .where((peer) => peer.uri.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static String listToJson(List<PeerEntry> peers) =>
      jsonEncode(peers.map((peer) => peer.toJson()).toList());
}

/// The live state of a link, as reported by the Yggdrasil node.
class PeerStatus {
  const PeerStatus({
    required this.uri,
    required this.up,
    this.inbound = false,
    this.latencyMs = 0,
    this.ip = '',
    this.key = '',
    this.cost = 0,
    this.lastError = '',
    this.lastErrorUnix = 0,
    this.lastErrorWas = '',
    this.lastErrorWasUnix = 0,
    this.rxBytes = 0,
    this.txBytes = 0,
    this.uptimeSeconds = 0,
  });

  final String uri;
  final bool up;

  /// True when the peer dialled us instead of the other way round.
  final bool inbound;
  final double latencyMs;
  final String ip;
  final String key;

  /// The routing cost the node reported for this link.
  final int cost;

  /// The error the link is reporting right now, empty when it is healthy.
  final String lastError;
  final int lastErrorUnix;

  /// The last error seen on this link before it recovered. The node clears
  /// [lastError] as soon as the peer is back, so the supervisor keeps a copy.
  final String lastErrorWas;
  final int lastErrorWasUnix;
  final int rxBytes;
  final int txBytes;
  final double uptimeSeconds;

  factory PeerStatus.fromJson(Map<String, dynamic> json) => PeerStatus(
    uri: (json['uri'] as String?) ?? '',
    up: (json['up'] as bool?) ?? false,
    inbound: (json['inbound'] as bool?) ?? false,
    latencyMs: (json['latencyMs'] as num?)?.toDouble() ?? 0,
    ip: (json['ip'] as String?) ?? '',
    key: (json['key'] as String?) ?? '',
    cost: (json['cost'] as num?)?.toInt() ?? 0,
    lastError: (json['lastError'] as String?) ?? '',
    lastErrorUnix: (json['lastErrorUnix'] as num?)?.toInt() ?? 0,
    lastErrorWas: (json['lastErrorWas'] as String?) ?? '',
    lastErrorWasUnix: (json['lastErrorWasUnix'] as num?)?.toInt() ?? 0,
    rxBytes: (json['rxBytes'] as num?)?.toInt() ?? 0,
    txBytes: (json['txBytes'] as num?)?.toInt() ?? 0,
    uptimeSeconds: (json['uptimeSeconds'] as num?)?.toDouble() ?? 0,
  );

  static List<PeerStatus> listFromJson(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(PeerStatus.fromJson)
          .where((peer) => peer.uri.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }
}

/// The last error a peer reported, kept after the link recovers.
class PeerErrorRecord {
  const PeerErrorRecord({required this.message, this.lastSeenUnix = 0});

  final String message;
  final int lastSeenUnix;

  factory PeerErrorRecord.fromJson(Map<String, dynamic> json) =>
      PeerErrorRecord(
        message: (json['message'] as String?) ?? '',
        lastSeenUnix: (json['lastSeenUnix'] as num?)?.toInt() ?? 0,
      );

  /// Reads the map the Android supervisor stores under `peer_errors`.
  static Map<String, PeerErrorRecord> mapFromJson(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final out = <String, PeerErrorRecord>{};
      for (final entry in map.entries) {
        final value = entry.value;
        if (value is! Map<String, dynamic>) continue;
        final record = PeerErrorRecord.fromJson(value);
        if (record.message.isEmpty) continue;
        out[entry.key] = record;
      }
      return out;
    } catch (_) {
      return const {};
    }
  }
}

/// The outcome of one Yggdrasil handshake attempt.
class ProbeResult {
  const ProbeResult({
    required this.uri,
    required this.up,
    this.latencyMs = 0,
    this.error = '',
    this.country = '',
    this.city = '',
    this.tcpRttMs = 0,
  });

  final String uri;
  final bool up;
  final double latencyMs;
  final String error;
  final String country;
  final String city;
  final double tcpRttMs;

  factory ProbeResult.fromJson(Map<String, dynamic> json) => ProbeResult(
    uri: (json['uri'] as String?) ?? '',
    up: (json['up'] as bool?) ?? false,
    latencyMs: (json['latencyMs'] as num?)?.toDouble() ?? 0,
    error: (json['error'] as String?) ?? '',
  );

  ProbeResult copyWith({
    String? uri,
    bool? up,
    double? latencyMs,
    String? error,
    String? country,
    String? city,
    double? tcpRttMs,
  }) => ProbeResult(
    uri: uri ?? this.uri,
    up: up ?? this.up,
    latencyMs: latencyMs ?? this.latencyMs,
    error: error ?? this.error,
    country: country ?? this.country,
    city: city ?? this.city,
    tcpRttMs: tcpRttMs ?? this.tcpRttMs,
  );

  PeerEntry toPeer() => PeerEntry(
    uri: uri,
    country: country,
    city: city,
    latencyMs: latencyMs,
    tcpRttMs: tcpRttMs,
  );
}

/// One exit node known to the app. The list order is the failover order.
class ExitProfile {
  const ExitProfile({
    required this.id,
    required this.name,
    required this.address,
    this.socksPort = 1080,
    this.apiPort = 1081,
    this.invite = '',
    this.peer = '',
    this.token = '',
  });

  final String id;
  final String name;
  final String address;
  final int socksPort;
  final int apiPort;

  /// The invite token from the QR code. It is kept so a registration can be
  /// retried after the tunnel was down; it is never sent anywhere else.
  final String invite;

  /// The API credential issued by the exit. Without it the exit answers with
  /// the minimal status, so the counters and limits stay empty. The token is
  /// bound to this node's Yggdrasil address and is never shown in the UI.
  final String token;

  /// The public Yggdrasil peering URI of the exit node, e.g.
  /// `wss://203.0.113.10:443/ygg?key=...` or
  /// `tls://203.0.113.10:13338?key=...`. When present, the app adds it as a
  /// pinned peer so the tunnel reaches the exit directly. Empty for an
  /// outbound-only server.
  final String peer;

  String get title => name.trim().isNotEmpty ? name.trim() : address;

  factory ExitProfile.fromJson(Map<String, dynamic> json) {
    final address = ((json['address'] as String?) ?? '').trim();
    final socks = (json['socksPort'] as num?)?.toInt() ?? 1080;
    return ExitProfile(
      id: ((json['id'] as String?) ?? '').trim().isEmpty
          ? '$address:$socks'
          : (json['id'] as String).trim(),
      name: ((json['name'] as String?) ?? '').trim().isEmpty
          ? address
          : (json['name'] as String).trim(),
      address: address,
      socksPort: socks,
      apiPort: (json['apiPort'] as num?)?.toInt() ?? 1081,
      invite: (json['invite'] as String?) ?? '',
      peer: ((json['peer'] as String?) ?? '').trim(),
      token: ((json['token'] as String?) ?? '').trim(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'socksPort': socksPort,
    'apiPort': apiPort,
    if (invite.isNotEmpty) 'invite': invite,
    if (peer.isNotEmpty) 'peer': peer,
    if (token.isNotEmpty) 'token': token,
  };

  ExitProfile copyWith({
    String? id,
    String? name,
    String? address,
    int? socksPort,
    int? apiPort,
    String? invite,
    String? peer,
    String? token,
  }) => ExitProfile(
    id: id ?? this.id,
    name: name ?? this.name,
    address: address ?? this.address,
    socksPort: socksPort ?? this.socksPort,
    apiPort: apiPort ?? this.apiPort,
    invite: invite ?? this.invite,
    peer: peer ?? this.peer,
    token: token ?? this.token,
  );

  static List<ExitProfile> listFromJson(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(ExitProfile.fromJson)
          .where((profile) => profile.address.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static String listToJson(List<ExitProfile> profiles) =>
      jsonEncode(profiles.map((profile) => profile.toJson()).toList());
}

/// The traffic quota an exit applies to this client. A zero limit means that
/// direction or period is unlimited.
class ExitQuota {
  const ExitQuota({
    this.monthlyBytes = 0,
    this.dailyBytes = 0,
    this.downKbps = 0,
    this.upKbps = 0,
    this.dayUsed = 0,
    this.monthUsed = 0,
    this.exhausted = false,
    this.reason = '',
  });

  final int monthlyBytes;
  final int dailyBytes;
  final int downKbps;
  final int upKbps;
  final int dayUsed;
  final int monthUsed;

  /// True when a traffic cap is used up: the exit refuses new connections
  /// until the day or the month rolls over.
  final bool exhausted;

  /// Why the quota is exhausted, as reported by the exit.
  final String reason;

  bool get hasTrafficCap => monthlyBytes > 0 || dailyBytes > 0;
  bool get hasSpeedLimit => downKbps > 0 || upKbps > 0;
  bool get isUnlimited => !hasTrafficCap && !hasSpeedLimit;

  /// The cap closest to being used up, and how much of it is gone. Null when
  /// the exit sets no traffic cap.
  ({int used, int limit})? get tightestCap {
    ({int used, int limit})? best;
    if (dailyBytes > 0) best = (used: dayUsed, limit: dailyBytes);
    if (monthlyBytes > 0) {
      final monthly = (used: monthUsed, limit: monthlyBytes);
      if (best == null ||
          monthly.used / monthly.limit > best.used / best.limit) {
        best = monthly;
      }
    }
    return best;
  }

  factory ExitQuota.fromJson(Map<String, dynamic> json) => ExitQuota(
    monthlyBytes: (json['monthlyBytes'] as num?)?.toInt() ?? 0,
    dailyBytes: (json['dailyBytes'] as num?)?.toInt() ?? 0,
    downKbps: (json['downKbps'] as num?)?.toInt() ?? 0,
    upKbps: (json['upKbps'] as num?)?.toInt() ?? 0,
    dayUsed: (json['dayUsed'] as num?)?.toInt() ?? 0,
    monthUsed: (json['monthUsed'] as num?)?.toInt() ?? 0,
    exhausted: (json['exhausted'] as bool?) ?? false,
    reason: ((json['reason'] as String?) ?? '').trim(),
  );
}

/// The health of one exit profile, as measured by the Go bridge.
class ExitProfileStatus {
  const ExitProfileStatus({
    required this.id,
    this.name = '',
    this.address = '',
    this.state = 'unknown',
    this.latencyMs = 0,
    this.error = '',
    this.checkedAt = 0,
    this.connections = 0,
    this.refused = 0,
    this.quotaRefused = 0,
    this.maxConns = 0,
    this.udpAssociations = 0,
    this.maxUdpAssociations = 0,
    this.quota,
    this.authenticated = true,
    this.token = '',
  });

  final String id;
  final String name;
  final String address;

  /// `online`, `unreachable`, `denied` or `unknown`.
  final String state;
  final double latencyMs;
  final String error;
  final int checkedAt;

  /// Connections this client has open on the exit right now.
  final int connections;

  /// Connections the exit turned away since it started. A non-zero value is
  /// what "we hit maxConnsPerClient" looks like from the phone.
  final int refused;

  /// The part of [refused] caused by an exhausted traffic quota, not by the
  /// connection limit. The app uses it to name the right reason.
  final int quotaRefused;

  /// The limits the exit reports, 0 when the server is too old to send them.
  final int maxConns;
  final int udpAssociations;
  final int maxUdpAssociations;

  /// The traffic quota of this client, null when the exit does not set one or
  /// is too old to report it.
  final ExitQuota? quota;

  /// False when the exit answered with the minimal status: it requires an API
  /// token this profile does not have (yet). A server from before 1.3 has no
  /// auth at all and always reports the full status.
  final bool authenticated;

  /// A token the bridge learned during this session. The app saves it in the
  /// profile; empty when the profile already has one.
  final String token;

  /// Refusals caused by the connection limit, excluding quota refusals.
  int get limitRefused {
    final value = refused - quotaRefused;
    return value > 0 ? value : 0;
  }

  /// True when the exit refused at least one connection because of its
  /// connection limit. Quota refusals are reported separately.
  bool get hitLimit => limitRefused > 0;

  /// True when a traffic cap is used up, so new connections are refused
  /// because of the quota rather than the connection limit.
  bool get quotaExhausted => quota?.exhausted ?? false;

  /// True when the exit wants a token and the profile has none: the counters
  /// are unavailable rather than zero.
  bool get limited => !authenticated;

  factory ExitProfileStatus.fromJson(Map<String, dynamic> json) =>
      ExitProfileStatus(
        id: (json['id'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        address: (json['address'] as String?) ?? '',
        state: (json['state'] as String?) ?? 'unknown',
        latencyMs: (json['latencyMs'] as num?)?.toDouble() ?? 0,
        error: (json['error'] as String?) ?? '',
        checkedAt: (json['checkedAt'] as num?)?.toInt() ?? 0,
        connections: (json['connections'] as num?)?.toInt() ?? 0,
        refused: (json['refused'] as num?)?.toInt() ?? 0,
        quotaRefused: (json['quotaRefused'] as num?)?.toInt() ?? 0,
        maxConns: (json['maxConns'] as num?)?.toInt() ?? 0,
        udpAssociations: (json['udpAssociations'] as num?)?.toInt() ?? 0,
        maxUdpAssociations: (json['maxUdpAssociations'] as num?)?.toInt() ?? 0,
        quota: json['quota'] is Map<String, dynamic>
            ? ExitQuota.fromJson(json['quota'] as Map<String, dynamic>)
            : null,
        authenticated: (json['authenticated'] as bool?) ?? true,
        token: ((json['token'] as String?) ?? '').trim(),
      );

  ExitProfileStatus copyWith({String? name}) => ExitProfileStatus(
    id: id,
    name: name ?? this.name,
    address: address,
    state: state,
    latencyMs: latencyMs,
    error: error,
    checkedAt: checkedAt,
    connections: connections,
    refused: refused,
    quotaRefused: quotaRefused,
    maxConns: maxConns,
    udpAssociations: udpAssociations,
    maxUdpAssociations: maxUdpAssociations,
    quota: quota,
    authenticated: authenticated,
    token: token,
  );
}

/// The UDP relay the exit carries for this client: DNS and QUIC.
class ExitUdpStatus {
  const ExitUdpStatus({
    this.enabled = false,
    this.state = 'off',
    this.profileId = '',
    this.profileName = '',
    this.datagramsIn = 0,
    this.datagramsOut = 0,
    this.bytesIn = 0,
    this.bytesOut = 0,
    this.error = '',
  });

  final bool enabled;

  /// `off`, `idle`, `online` or `error`.
  final String state;
  final String profileId;
  final String profileName;
  final int datagramsIn;
  final int datagramsOut;
  final int bytesIn;
  final int bytesOut;
  final String error;

  bool get isOnline => state == 'online';

  factory ExitUdpStatus.fromJson(Map<String, dynamic> json) => ExitUdpStatus(
    enabled: (json['enabled'] as bool?) ?? false,
    state: (json['state'] as String?) ?? 'off',
    profileId: (json['profileId'] as String?) ?? '',
    profileName: (json['profileName'] as String?) ?? '',
    datagramsIn: (json['datagramsIn'] as num?)?.toInt() ?? 0,
    datagramsOut: (json['datagramsOut'] as num?)?.toInt() ?? 0,
    bytesIn: (json['bytesIn'] as num?)?.toInt() ?? 0,
    bytesOut: (json['bytesOut'] as num?)?.toInt() ?? 0,
    error: (json['error'] as String?) ?? '',
  );
}

/// One half of the UDP relay check: the DNS query and the QUIC handshake.
class UdpProbeStage {
  const UdpProbeStage({
    this.ok = false,
    this.latencyMs = 0,
    this.target = '',
    this.server = '',
    this.version = '',
    this.error = '',
  });

  final bool ok;
  final double latencyMs;
  final String target;
  final String server;

  /// The QUIC version the server picked, for example `1`.
  final String version;
  final String error;

  factory UdpProbeStage.fromJson(Map<String, dynamic> json) => UdpProbeStage(
    ok: (json['ok'] as bool?) ?? false,
    latencyMs: (json['latencyMs'] as num?)?.toDouble() ?? 0,
    target: (json['target'] as String?) ?? '',
    server: (json['server'] as String?) ?? '',
    version: (json['version'] as String?) ?? '',
    error: (json['error'] as String?) ?? '',
  );
}

/// The answer of the UDP relay self-check.
class UdpProbeResult {
  const UdpProbeResult({
    this.ok = false,
    this.state = 'error',
    this.profile = '',
    this.udp = const UdpProbeStage(),
    this.quic = const UdpProbeStage(),
    this.datagramsIn = 0,
    this.datagramsOut = 0,
    this.durationMs = 0,
    this.error = '',
  });

  final bool ok;

  /// `ok`, `off`, `disabled`, `udp_failed`, `quic_failed` or `error`.
  final String state;
  final String profile;
  final UdpProbeStage udp;
  final UdpProbeStage quic;
  final int datagramsIn;
  final int datagramsOut;
  final int durationMs;
  final String error;

  factory UdpProbeResult.fromJson(Map<String, dynamic> json) => UdpProbeResult(
    ok: (json['ok'] as bool?) ?? false,
    state: (json['state'] as String?) ?? 'error',
    profile: (json['profile'] as String?) ?? '',
    udp: json['udp'] is Map<String, dynamic>
        ? UdpProbeStage.fromJson(json['udp'] as Map<String, dynamic>)
        : const UdpProbeStage(),
    quic: json['quic'] is Map<String, dynamic>
        ? UdpProbeStage.fromJson(json['quic'] as Map<String, dynamic>)
        : const UdpProbeStage(),
    datagramsIn: (json['datagramsIn'] as num?)?.toInt() ?? 0,
    datagramsOut: (json['datagramsOut'] as num?)?.toInt() ?? 0,
    durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
    error: (json['error'] as String?) ?? '',
  );

  static UdpProbeResult? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) return null;
      return UdpProbeResult.fromJson(value);
    } catch (_) {
      return null;
    }
  }
}

/// One half of the IPv6 check: TCP over IPv6 and DNS over IPv6.
class Ipv6ProbeStage {
  const Ipv6ProbeStage({
    this.ok = false,
    this.skipped = false,
    this.latencyMs = 0,
    this.target = '',
    this.address = '',
    this.error = '',
  });

  final bool ok;
  final bool skipped;
  final double latencyMs;
  final String target;

  /// The IPv6 address the exit used for the TCP stage.
  final String address;
  final String error;

  factory Ipv6ProbeStage.fromJson(Map<String, dynamic> json) => Ipv6ProbeStage(
    ok: (json['ok'] as bool?) ?? false,
    skipped: (json['skipped'] as bool?) ?? false,
    latencyMs: (json['latencyMs'] as num?)?.toDouble() ?? 0,
    target: (json['target'] as String?) ?? '',
    address: (json['address'] as String?) ?? '',
    error: (json['error'] as String?) ?? '',
  );
}

/// The answer of the IPv6 self-check.
class Ipv6ProbeResult {
  const Ipv6ProbeResult({
    this.ok = false,
    this.state = 'error',
    this.profile = '',
    this.tcp = const Ipv6ProbeStage(),
    this.udp = const Ipv6ProbeStage(),
    this.durationMs = 0,
    this.error = '',
  });

  final bool ok;

  /// `ok`, `off`, `tcp_failed` or `udp_failed`.
  final String state;
  final String profile;
  final Ipv6ProbeStage tcp;
  final Ipv6ProbeStage udp;
  final int durationMs;
  final String error;

  factory Ipv6ProbeResult.fromJson(Map<String, dynamic> json) =>
      Ipv6ProbeResult(
        ok: (json['ok'] as bool?) ?? false,
        state: (json['state'] as String?) ?? 'error',
        profile: (json['profile'] as String?) ?? '',
        tcp: json['tcp'] is Map<String, dynamic>
            ? Ipv6ProbeStage.fromJson(json['tcp'] as Map<String, dynamic>)
            : const Ipv6ProbeStage(),
        udp: json['udp'] is Map<String, dynamic>
            ? Ipv6ProbeStage.fromJson(json['udp'] as Map<String, dynamic>)
            : const Ipv6ProbeStage(),
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        error: (json['error'] as String?) ?? '',
      );

  static Ipv6ProbeResult? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) return null;
      return Ipv6ProbeResult.fromJson(value);
    } catch (_) {
      return null;
    }
  }
}

/// The aggregate exit state pushed by the service.
class ExitStatus {
  const ExitStatus({
    this.enabled = false,
    this.state = 'off',
    this.activeId = '',
    this.fallbackDirect = false,
    this.profiles = const [],
    this.udp = const ExitUdpStatus(),
    this.updatedAt = 0,
  });

  final bool enabled;

  /// `off`, `no_profile`, `online`, `denied`, `unreachable` or `unknown`.
  final String state;
  final String activeId;
  final bool fallbackDirect;
  final List<ExitProfileStatus> profiles;
  final ExitUdpStatus udp;
  final int updatedAt;

  bool get hasProfile => profiles.isNotEmpty;

  ExitProfileStatus? get active {
    for (final profile in profiles) {
      if (profile.id == activeId) return profile;
    }
    return profiles.isEmpty ? null : profiles.first;
  }

  factory ExitStatus.fromJson(Map<String, dynamic> json) => ExitStatus(
    enabled: (json['enabled'] as bool?) ?? false,
    state: (json['state'] as String?) ?? 'off',
    activeId: (json['activeId'] as String?) ?? '',
    fallbackDirect: (json['fallbackDirect'] as bool?) ?? false,
    profiles: ((json['profiles'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ExitProfileStatus.fromJson)
        .toList(),
    udp: json['udp'] is Map<String, dynamic>
        ? ExitUdpStatus.fromJson(json['udp'] as Map<String, dynamic>)
        : const ExitUdpStatus(),
    updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
  );

  static ExitStatus? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) return null;
      return ExitStatus.fromJson(value);
    } catch (_) {
      return null;
    }
  }
}

/// The answer of the exit registration endpoint.
class ExitRegistration {
  const ExitRegistration({
    this.ok = false,
    this.allowlisted = false,
    this.registered = false,
    this.exitName = '',
    this.error = '',
    this.message = '',
    this.token = '',
  });

  final bool ok;
  final bool allowlisted;
  final bool registered;
  final String exitName;
  final String error;
  final String message;

  /// The API credential issued by the exit. It is stored in the profile and
  /// never shown in the UI; empty for a server from before 1.3.
  final String token;

  factory ExitRegistration.fromJson(Map<String, dynamic> json) =>
      ExitRegistration(
        ok: (json['ok'] as bool?) ?? false,
        allowlisted: (json['allowlisted'] as bool?) ?? false,
        registered: (json['registered'] as bool?) ?? false,
        exitName: (json['exitName'] as String?) ?? '',
        error: (json['error'] as String?) ?? '',
        message: (json['message'] as String?) ?? '',
        token: ((json['token'] as String?) ?? '').trim(),
      );

  static ExitRegistration? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) return null;
      return ExitRegistration.fromJson(value);
    } catch (_) {
      return null;
    }
  }
}

/// A node identity. The private key never leaves the device.
class Identity {
  const Identity({
    required this.privateKey,
    required this.publicKey,
    required this.address,
    this.subnet = '',
  });

  final String privateKey;
  final String publicKey;
  final String address;
  final String subnet;

  factory Identity.fromJson(Map<String, dynamic> json) => Identity(
    privateKey: (json['privateKey'] as String?) ?? '',
    publicKey: (json['publicKey'] as String?) ?? '',
    address: (json['address'] as String?) ?? '',
    subnet: (json['subnet'] as String?) ?? '',
  );

  Map<String, dynamic> toJson() => {
    'privateKey': privateKey,
    'publicKey': publicKey,
    'address': address,
    'subnet': subnet,
  };

  bool get isValid => privateKey.isNotEmpty && address.isNotEmpty;
}

/// An entry of the address book.
class Resource {
  const Resource({
    required this.id,
    required this.title,
    required this.url,
    this.description = '',
    this.builtIn = false,
  });

  final String id;
  final String title;
  final String url;
  final String description;
  final bool builtIn;

  factory Resource.fromJson(Map<String, dynamic> json) => Resource(
    id: (json['id'] as String?) ?? '',
    title: (json['title'] as String?) ?? '',
    url: (json['url'] as String?) ?? '',
    description: (json['description'] as String?) ?? '',
    builtIn: (json['builtIn'] as bool?) ?? false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'url': url,
    'description': description,
    'builtIn': builtIn,
  };

  Resource copyWith({
    String? id,
    String? title,
    String? url,
    String? description,
    bool? builtIn,
  }) => Resource(
    id: id ?? this.id,
    title: title ?? this.title,
    url: url ?? this.url,
    description: description ?? this.description,
    builtIn: builtIn ?? this.builtIn,
  );

  static List<Resource> listFromJson(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(Resource.fromJson)
          .where((item) => item.url.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static String listToJson(List<Resource> items) =>
      jsonEncode(items.map((item) => item.toJson()).toList());
}

/// DNS modes, matching the constants on the Kotlin side.
class DnsMode {
  const DnsMode._();

  static const String yggdrasil = 'yggdrasil';
  static const String system = 'system';
  static const String custom = 'custom';
}

/// The single connection configuration of the app.
class AppSettings {
  const AppSettings({
    this.peerCount = 3,
    this.autoReplace = true,
    this.deadPeerTimeoutSec = 45,
    this.healthCheckSec = 15,
    this.dnsMode = DnsMode.yggdrasil,
    this.dnsServers = const ['308:84:68:55::', '308:25:40:bd::'],
    this.mtu = 1280,
    this.splitEnabled = false,
    this.splitApps = const [],
    this.energySaving = false,
    this.logging = false,
    this.probeTimeoutMs = 8000,
    this.probeBatch = 5,
    this.exitEnabled = false,
    this.exitProfiles = const [],
    this.exitActiveId = '',
    this.exitFallbackDirect = true,
    this.exitLocalDns = true,
    this.exitUdp = true,
    this.exitDnsServers = defaultExitDnsServers,
    this.exitLocalDnsServers = const [],
  });

  final int peerCount;
  final bool autoReplace;
  final int deadPeerTimeoutSec;
  final int healthCheckSec;
  final String dnsMode;
  final List<String> dnsServers;
  final int mtu;
  final bool splitEnabled;
  final List<String> splitApps;
  final bool energySaving;
  final bool logging;
  final int probeTimeoutMs;
  final int probeBatch;
  final bool exitEnabled;
  final List<ExitProfile> exitProfiles;
  final String exitActiveId;
  final bool exitFallbackDirect;
  final bool exitLocalDns;

  /// Carry DNS and QUIC over the exit as well. Turning it off drops public UDP
  /// instead of letting it leave the phone around the exit.
  final bool exitUdp;

  /// Public resolvers the exit queries over TCP. The defaults are the same
  /// servers the server-side split-DNS uses when nothing is configured.
  final List<String> exitDnsServers;

  /// Resolvers for local names. Empty means the DNS servers of the real
  /// network, read from the active link by the Android service.
  final List<String> exitLocalDnsServers;

  /// True when public traffic should be sent through an exit node.
  bool get exitActive => exitEnabled && exitProfiles.isNotEmpty;

  ExitProfile? get exitActiveProfile {
    for (final profile in exitProfiles) {
      if (profile.id == exitActiveId) return profile;
    }
    return exitProfiles.isEmpty ? null : exitProfiles.first;
  }

  /// The servers that actually reach the tunnel, empty for system DNS.
  List<String> get effectiveDns {
    if (dnsMode == DnsMode.system) return const [];
    return dnsServers
        .map((server) => server.trim())
        .where((server) => server.isNotEmpty)
        .toList();
  }

  /// The two servers the app starts with. Two are kept so a single dead resolver
  /// does not take the whole name resolution down.
  static const List<String> defaultDnsServers = [
    '308:84:68:55::',
    '308:25:40:bd::',
  ];

  /// Public resolvers used through the exit node unless the user picks others.
  static const List<String> defaultExitDnsServers = ['1.1.1.1', '9.9.9.9'];

  static List<String> _dnsListFrom(Map<String, dynamic> json) {
    final stored = ((json['dnsServers'] as List<dynamic>?) ?? const [])
        .whereType<String>()
        .where((server) => server.trim().isNotEmpty)
        .toList();
    return stored.isEmpty ? defaultDnsServers : stored;
  }

  static List<String> _serverList(Map<String, dynamic> json, String key) =>
      ((json[key] as List<dynamic>?) ?? const [])
          .whereType<String>()
          .map((server) => server.trim())
          .where((server) => server.isNotEmpty)
          .toList();

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    peerCount: (json['peerCount'] as num?)?.toInt() ?? 3,
    autoReplace: (json['autoReplace'] as bool?) ?? true,
    deadPeerTimeoutSec: (json['deadPeerTimeoutSec'] as num?)?.toInt() ?? 45,
    healthCheckSec: (json['healthCheckSec'] as num?)?.toInt() ?? 15,
    dnsMode: (json['dnsMode'] as String?) ?? DnsMode.yggdrasil,
    dnsServers: _dnsListFrom(json),
    mtu: (json['mtu'] as num?)?.toInt() ?? 1280,
    splitEnabled: (json['splitEnabled'] as bool?) ?? false,
    splitApps: ((json['splitApps'] as List<dynamic>?) ?? const [])
        .whereType<String>()
        .toList(),
    energySaving: (json['energySaving'] as bool?) ?? false,
    logging: (json['logging'] as bool?) ?? false,
    probeTimeoutMs: (json['probeTimeoutMs'] as num?)?.toInt() ?? 8000,
    probeBatch: (json['probeBatch'] as num?)?.toInt() ?? 5,
    exitEnabled: (json['exitEnabled'] as bool?) ?? false,
    exitProfiles: ((json['exitProfiles'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ExitProfile.fromJson)
        .where((profile) => profile.address.isNotEmpty)
        .toList(),
    exitActiveId: (json['exitActiveId'] as String?) ?? '',
    exitFallbackDirect: (json['exitFallbackDirect'] as bool?) ?? true,
    exitLocalDns: (json['exitLocalDns'] as bool?) ?? true,
    exitUdp: (json['exitUdp'] as bool?) ?? true,
    exitDnsServers: _serverList(json, 'exitDnsServers').isEmpty
        ? defaultExitDnsServers
        : _serverList(json, 'exitDnsServers'),
    exitLocalDnsServers: _serverList(json, 'exitLocalDnsServers'),
  );

  Map<String, dynamic> toJson() => {
    'peerCount': peerCount,
    'autoReplace': autoReplace,
    'deadPeerTimeoutSec': deadPeerTimeoutSec,
    'healthCheckSec': healthCheckSec,
    'dnsMode': dnsMode,
    'dnsServers': dnsServers,
    'mtu': mtu,
    'splitEnabled': splitEnabled,
    'splitApps': splitApps,
    'energySaving': energySaving,
    'logging': logging,
    'probeTimeoutMs': probeTimeoutMs,
    'probeBatch': probeBatch,
    'exitEnabled': exitEnabled,
    'exitProfiles': [for (final profile in exitProfiles) profile.toJson()],
    'exitActiveId': exitActiveId,
    'exitFallbackDirect': exitFallbackDirect,
    'exitLocalDns': exitLocalDns,
    'exitUdp': exitUdp,
    'exitDnsServers': exitDnsServers,
    'exitLocalDnsServers': exitLocalDnsServers,
  };

  AppSettings copyWith({
    int? peerCount,
    bool? autoReplace,
    int? deadPeerTimeoutSec,
    int? healthCheckSec,
    String? dnsMode,
    List<String>? dnsServers,
    int? mtu,
    bool? splitEnabled,
    List<String>? splitApps,
    bool? energySaving,
    bool? logging,
    int? probeTimeoutMs,
    int? probeBatch,
    bool? exitEnabled,
    List<ExitProfile>? exitProfiles,
    String? exitActiveId,
    bool? exitFallbackDirect,
    bool? exitLocalDns,
    bool? exitUdp,
    List<String>? exitDnsServers,
    List<String>? exitLocalDnsServers,
  }) => AppSettings(
    peerCount: peerCount ?? this.peerCount,
    autoReplace: autoReplace ?? this.autoReplace,
    deadPeerTimeoutSec: deadPeerTimeoutSec ?? this.deadPeerTimeoutSec,
    healthCheckSec: healthCheckSec ?? this.healthCheckSec,
    dnsMode: dnsMode ?? this.dnsMode,
    dnsServers: dnsServers ?? this.dnsServers,
    mtu: mtu ?? this.mtu,
    splitEnabled: splitEnabled ?? this.splitEnabled,
    splitApps: splitApps ?? this.splitApps,
    energySaving: energySaving ?? this.energySaving,
    logging: logging ?? this.logging,
    probeTimeoutMs: probeTimeoutMs ?? this.probeTimeoutMs,
    probeBatch: probeBatch ?? this.probeBatch,
    exitEnabled: exitEnabled ?? this.exitEnabled,
    exitProfiles: exitProfiles ?? this.exitProfiles,
    exitActiveId: exitActiveId ?? this.exitActiveId,
    exitFallbackDirect: exitFallbackDirect ?? this.exitFallbackDirect,
    exitLocalDns: exitLocalDns ?? this.exitLocalDns,
    exitUdp: exitUdp ?? this.exitUdp,
    exitDnsServers: exitDnsServers ?? this.exitDnsServers,
    exitLocalDnsServers: exitLocalDnsServers ?? this.exitLocalDnsServers,
  );
}

/// The byte counters of the tunnel.
///
/// They move on every stats tick while traffic flows, so they are published on
/// their own notifier: a traffic tick must update the two numbers on the home
/// screen without rebuilding the tabs that do not show them.
class TrafficCounters {
  const TrafficCounters({this.rx = 0, this.tx = 0});

  final int rx;
  final int tx;

  @override
  bool operator ==(Object other) =>
      other is TrafficCounters && other.rx == rx && other.tx == tx;

  @override
  int get hashCode => Object.hash(rx, tx);
}

/// A snapshot of the tunnel state pushed by the service.
class VpnSnapshot {
  const VpnSnapshot({
    this.status = 'disconnected',
    this.stage = '',
    this.error,
    this.nodeAddress = '',
    this.subnet = '',
    this.publicKey = '',
    this.rxBytes = 0,
    this.txBytes = 0,
    this.peersUp = 0,
    this.peersTotal = 0,
    this.latencyMs = 0,
    this.connectedAt = 0,
    this.dns = '',
    this.mtu = 1280,
    this.peers = const [],
    this.exit = const ExitStatus(),
  });

  final String status;

  /// The step the service is on while connecting: `starting`, `tunnel`,
  /// `peers`, `network`, `ready`; empty when there is nothing to report.
  final String stage;
  final String? error;
  final String nodeAddress;
  final String subnet;
  final String publicKey;
  final int rxBytes;
  final int txBytes;
  final int peersUp;
  final int peersTotal;
  final double latencyMs;
  final int connectedAt;
  final String dns;
  final int mtu;
  final List<PeerStatus> peers;
  final ExitStatus exit;

  bool get isConnected => status == 'connected';
  bool get isBusy =>
      status == 'connecting' ||
      status == 'reconnecting' ||
      status == 'disconnecting';
  bool get isDisconnected => status == 'disconnected';

  /// The last decoded peer and exit payloads. The service pushes a snapshot
  /// every second, but the JSON behind these two fields only changes when a
  /// peer or the exit state really moves, so decoding the same string again is
  /// pure work on the UI isolate.
  static String _peersRaw = '';
  static List<PeerStatus> _peersParsed = const [];
  static String _exitRaw = '';
  static ExitStatus _exitParsed = const ExitStatus();

  static List<PeerStatus> _parsePeers(String? raw) {
    final text = raw ?? '';
    if (text == _peersRaw) return _peersParsed;
    final parsed = PeerStatus.listFromJson(text);
    _peersRaw = text;
    _peersParsed = parsed;
    return parsed;
  }

  static ExitStatus _parseExit(String? raw) {
    final text = raw ?? '';
    if (text == _exitRaw) return _exitParsed;
    final parsed = ExitStatus.tryParse(text) ?? const ExitStatus();
    _exitRaw = text;
    _exitParsed = parsed;
    return parsed;
  }

  factory VpnSnapshot.fromMap(Map<dynamic, dynamic> map) => VpnSnapshot(
    status: (map['status'] as String?) ?? 'disconnected',
    stage: (map['stage'] as String?) ?? '',
    error: map['error'] as String?,
    nodeAddress: (map['nodeAddress'] as String?) ?? '',
    subnet: (map['subnet'] as String?) ?? '',
    publicKey: (map['publicKey'] as String?) ?? '',
    rxBytes: (map['rxBytes'] as num?)?.toInt() ?? 0,
    txBytes: (map['txBytes'] as num?)?.toInt() ?? 0,
    peersUp: (map['peersUp'] as num?)?.toInt() ?? 0,
    peersTotal: (map['peersTotal'] as num?)?.toInt() ?? 0,
    latencyMs: (map['latencyMs'] as num?)?.toDouble() ?? 0,
    connectedAt: (map['connectedAt'] as num?)?.toInt() ?? 0,
    dns: (map['dns'] as String?) ?? '',
    mtu: (map['mtu'] as num?)?.toInt() ?? 1280,
    peers: _parsePeers(map['peers'] as String?),
    exit: _parseExit(map['exitStatus'] as String?),
  );
}

/// An installed application, as listed for split tunnelling.
class InstalledApp {
  const InstalledApp({
    required this.packageName,
    required this.label,
    this.system = false,
  });

  final String packageName;
  final String label;
  final bool system;

  factory InstalledApp.fromMap(Map<dynamic, dynamic> map) => InstalledApp(
    packageName: (map['package'] as String?) ?? '',
    label: (map['label'] as String?) ?? '',
    system: (map['system'] as bool?) ?? false,
  );
}

/// The result of one DNS health check, made through the running node.
class DnsCheck {
  const DnsCheck({
    required this.server,
    this.ok = false,
    this.ms = 0,
    this.via = '',
    this.rcode = -1,
    this.error = '',
    this.name = '',
    this.address = '',
  });

  final String server;
  final bool ok;
  final double ms;

  /// `udp` or `tcp`; empty when the server did not answer.
  final String via;
  final int rcode;
  final String error;

  /// The name that was resolved and the address the server returned.
  final String name;
  final String address;

  factory DnsCheck.fromJson(Map<String, dynamic> json) => DnsCheck(
    server: (json['server'] as String?) ?? '',
    ok: (json['ok'] as bool?) ?? false,
    ms: (json['ms'] as num?)?.toDouble() ?? 0,
    via: (json['via'] as String?) ?? '',
    rcode: (json['rcode'] as num?)?.toInt() ?? -1,
    error: (json['error'] as String?) ?? '',
    name: (json['name'] as String?) ?? '',
    address: (json['address'] as String?) ?? '',
  );
}

/// A page fetched through the tunnel, used by the web directory browser.
class FetchResult {
  const FetchResult({this.status = 0, this.body = '', this.error = ''});

  final int status;
  final String body;
  final String error;

  bool get ok => status >= 200 && status < 400 && body.isNotEmpty;

  factory FetchResult.fromJson(Map<String, dynamic> json) => FetchResult(
    status: (json['status'] as num?)?.toInt() ?? 0,
    body: (json['body'] as String?) ?? '',
    error: (json['error'] as String?) ?? '',
  );
}

/// The identity of a peer link without its query string.
///
/// Yggdrasil keeps a configured peer under its scheme, host, port and path and
/// drops the options (`?key=…`, `?priority=…`) from the live link info. A
/// pinned exit peer is configured with the exit node's public key, so its URI
/// never matches the one the node reports; both sides are compared through this
/// key instead.
String peerKeyOf(String uri) {
  final trimmed = uri.trim();
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null || parsed.host.isEmpty) return trimmed;
  final buffer = StringBuffer('${parsed.scheme}://');
  if (parsed.host.contains(':')) {
    buffer.write('[${parsed.host}]');
  } else {
    buffer.write(parsed.host);
  }
  if (parsed.hasPort) buffer.write(':${parsed.port}');
  if (parsed.path.isNotEmpty) buffer.write(parsed.path);
  return buffer.toString();
}
