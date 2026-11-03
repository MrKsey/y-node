import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:http/http.dart' as http;

import 'geo.dart';

/// The transports Yggdrasil can dial.
const List<String> kPeerSchemes = ['tls', 'tcp', 'wss', 'ws', 'quic'];

/// True when [uri] looks like something the node can actually connect to.
bool isValidPeerUri(String uri) {
  final parsed = Uri.tryParse(uri.trim());
  if (parsed == null) return false;
  if (!kPeerSchemes.contains(parsed.scheme)) return false;
  if (parsed.host.isEmpty) return false;
  if (parsed.host.contains(' ')) return false;
  return parsed.hasPort && parsed.port > 0 && parsed.port <= 65535;
}

/// One peer host, already reduced to the connection string we will use.
class PeerCandidate {
  const PeerCandidate({
    required this.uri,
    required this.host,
    required this.country,
    required this.city,
    this.scheme = '',
    this.port = 0,
  });

  final String uri;
  final String host;

  /// Country slug, as used by the directory names of the public peer list.
  final String country;
  final String city;
  final String scheme;
  final int port;

  String get displayHost => host.isEmpty ? uri : host;

  Map<String, dynamic> toJson() => {
    'uri': uri,
    'host': host,
    'country': country,
    'city': city,
    'scheme': scheme,
    'port': port,
  };

  factory PeerCandidate.fromJson(Map<String, dynamic> json) => PeerCandidate(
    uri: (json['uri'] as String?) ?? '',
    host: (json['host'] as String?) ?? '',
    country: (json['country'] as String?) ?? '',
    city: (json['city'] as String?) ?? '',
    scheme: (json['scheme'] as String?) ?? '',
    port: (json['port'] as num?)?.toInt() ?? 0,
  );

  static List<PeerCandidate> listFromJson(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(PeerCandidate.fromJson)
          .where((item) => item.uri.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static String listToJson(List<PeerCandidate> items) =>
      jsonEncode([for (final item in items) item.toJson()]);
}

/// Reads and writes the offline copy of the public peer list.
typedef PeerCacheReader = Future<String?> Function();
typedef PeerCacheWriter = Future<void> Function(String);

/// The result of loading the public peer list.
class PeersResult {
  const PeersResult({
    required this.peers,
    this.fromNetwork = false,
    this.error,
  });

  final List<PeerCandidate> peers;
  final bool fromNetwork;
  final String? error;

  bool get isEmpty => peers.isEmpty;
}

/// Loads and parses `yggdrasil-network/public-peers`.
///
/// The list is a GitHub repository of markdown files, one per country, grouped
/// into continent directories. Each file has `### City` headings followed by
/// bullet lists that end in backticked connection strings. We keep one entry per
/// host so that the ranking does not end up with three transports of the same
/// server in its top three.
class PeersSource {
  PeersSource({
    http.Client? client,
    AssetBundle? assets,
    this.readCache,
    this.writeCache,
  }) : _client = client ?? http.Client(),
       _assets = assets ?? rootBundle;

  final http.Client _client;
  final AssetBundle _assets;
  final PeerCacheReader? readCache;
  final PeerCacheWriter? writeCache;

  static const String zipUrl =
      'https://codeload.github.com/yggdrasil-network/public-peers/zip/refs/heads/master';
  static const String assetPath = 'assets/data/public-peers.zip';

  static const Duration _timeout = Duration(seconds: 25);

  /// Schemes we can actually speak, most useful first.
  ///
  /// TLS comes first because port 443 traffic is the least likely to be
  /// filtered; QUIC goes last because carriers drop UDP far more often than TCP.
  static const List<String> _schemeOrder = kPeerSchemes;

  /// Seed peers used when neither the network nor the bundled snapshot works.
  static const List<String> _seed = [
    'tls://box.paulll.cc:13338',
    'tcp://yggno.de:18226',
    'quic://novosibirsk.mie.foundation:9952',
  ];

  Future<PeersResult> load({
    bool allowDownload = true,
    bool allTransports = false,
  }) async {
    if (allowDownload) {
      final fresh = await download();
      if (fresh != null && fresh.isNotEmpty) {
        return PeersResult(
          peers: allTransports ? fresh : onePerHost(fresh),
          fromNetwork: true,
        );
      }
    }

    // The source is unreachable: the last list that was downloaded still gives
    // the probe something to test instead of falling back to the seeds.
    final cached = await _readCached();
    if (cached.isNotEmpty) {
      return PeersResult(
        peers: allTransports ? cached : onePerHost(cached),
        error: 'the public list is unreachable, the offline copy is used',
      );
    }

    try {
      final data = await _assets.load(assetPath);
      final peers = parseZip(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        onePerHost: !allTransports,
      );
      if (peers.isNotEmpty) {
        return PeersResult(
          peers: peers,
          error: allowDownload
              ? 'network unavailable, bundled snapshot used'
              : null,
        );
      }
    } catch (_) {
      // Fall through to the seeds.
    }

    return PeersResult(
      peers: [
        for (final uri in _seed)
          PeerCandidate(
            uri: uri,
            host: _hostOf(uri),
            country: '',
            city: '',
            scheme: _schemeOf(uri),
            port: _portOf(uri),
          ),
      ],
      error: 'peer list unavailable, using built-in seeds',
    );
  }

  /// Downloads the repository archive and stores it as the offline copy. Null
  /// when the network or the archive is not usable.
  Future<List<PeerCandidate>?> download() async {
    try {
      final response = await _client
          .get(Uri.parse(zipUrl), headers: const {'Accept': 'application/zip'})
          .timeout(_timeout);
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return null;
      final peers = parseZip(response.bodyBytes, onePerHost: false);
      if (peers.isEmpty) return null;
      await _storeCache(peers);
      return peers;
    } catch (_) {
      return null;
    }
  }

  Future<List<PeerCandidate>> _readCached() async {
    final reader = readCache;
    if (reader == null) return const [];
    try {
      return PeerCandidate.listFromJson(await reader());
    } catch (_) {
      return const [];
    }
  }

  /// Writes the list only when it actually changed: the probe runs often and
  /// the archive is large enough for a pointless write to be noticeable.
  Future<void> _storeCache(List<PeerCandidate> peers) async {
    final writer = writeCache;
    if (writer == null) return;
    final json = PeerCandidate.listToJson(peers);
    try {
      final stored = await readCache?.call();
      if (stored == json) return;
      await writer(json);
    } catch (_) {
      // The cache is an optimisation, never a reason to fail a probe.
    }
  }

  /// Parses the repository archive. With [onePerHost] the list keeps the single
  /// best transport of each server, which is what the probe wants; the peer
  /// browser asks for every transport so quic, ws and wss entries are visible
  /// too.
  static List<PeerCandidate> parseZip(
    List<int> bytes, {
    bool onePerHost = true,
  }) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: false);
    } catch (_) {
      return const [];
    }

    final all = <PeerCandidate>[];
    for (final file in archive.files) {
      if (!file.isFile) continue;
      // The archive may use either separator.
      final name = file.name.replaceAll(String.fromCharCode(92), '/');
      if (!name.toLowerCase().endsWith('.md')) continue;
      final segments = name
          .split('/')
          .where((part) => part.isNotEmpty)
          .toList();
      // Expect at least `<root>/<continent>/<country>.md`.
      if (segments.length < 3) continue;
      final continent = segments[segments.length - 2].toLowerCase();
      if (continent == 'other') continue;
      final slug = segments.last
          .substring(0, segments.last.length - 3)
          .toLowerCase();
      if (slug.isEmpty || slug == 'readme') continue;

      final text = utf8.decode(file.content as List<int>, allowMalformed: true);
      all.addAll(parseMarkdown(text, country: slug));
    }

    final seen = <String>{};
    final unique = [
      for (final candidate in all)
        if (seen.add(candidate.uri)) candidate,
    ];
    return onePerHost ? PeersSource.onePerHost(unique) : unique;
  }

  /// Keeps the single best transport of every server, in first-seen order.
  static List<PeerCandidate> onePerHost(List<PeerCandidate> peers) {
    final best = <String, PeerCandidate>{};
    final order = <String>[];
    for (final candidate in peers) {
      final key = candidate.host;
      final existing = best[key];
      if (existing == null) {
        best[key] = candidate;
        order.add(key);
      } else if (_rank(candidate) < _rank(existing)) {
        best[key] = candidate;
      }
    }
    return [for (final key in order) best[key]!];
  }

  /// Parses a single country file.

  static List<PeerCandidate> parseMarkdown(String text, {String country = ''}) {
    final result = <PeerCandidate>[];
    var city = '';
    final uriPattern = RegExp(r'`((?:tcp|tls|quic|ws|wss)://[^`\s]+)`');

    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.trimRight();
      if (line.startsWith('#')) {
        final level = line.indexOf(RegExp(r'[^#]'));
        final title = line.replaceFirst(RegExp(r'^#+\s*'), '').trim();
        if (level >= 2) {
          city = _cleanCity(title);
        }
        continue;
      }
      for (final match in uriPattern.allMatches(line)) {
        final uri = match.group(1)!.trim();
        if (!_isPlausible(uri)) continue;
        result.add(
          PeerCandidate(
            uri: uri,
            host: _hostOf(uri),
            country: country,
            city: city,
            scheme: _schemeOf(uri),
            port: _portOf(uri),
          ),
        );
      }
    }
    return result;
  }

  /// Headings sometimes carry a note after a comma or a dash: keep the front.
  static String _cleanCity(String title) {
    var value = title;
    for (final separator in [',', ' - ', ' (', '/']) {
      final index = value.indexOf(separator);
      if (index > 0) value = value.substring(0, index);
    }
    return value.trim();
  }

  static bool _isPlausible(String uri) => isValidPeerUri(uri);

  /// Lower is better.
  static int _rank(PeerCandidate candidate) {
    final schemeIndex = _schemeOrder.indexOf(candidate.scheme);
    final schemeScore = schemeIndex < 0 ? _schemeOrder.length : schemeIndex;
    // A well-known port is a hint that the operator expects firewalls to pass it.
    final portScore = switch (candidate.port) {
      443 => 0,
      80 => 1,
      _ => 2,
    };
    return schemeScore * 4 + portScore;
  }

  static String _schemeOf(String uri) {
    final index = uri.indexOf('://');
    return index <= 0 ? '' : uri.substring(0, index).toLowerCase();
  }

  static String _hostOf(String uri) {
    final parsed = Uri.tryParse(uri);
    if (parsed == null || parsed.host.isEmpty) return uri;
    return parsed.host.toLowerCase();
  }

  static int _portOf(String uri) {
    final parsed = Uri.tryParse(uri);
    if (parsed == null || !parsed.hasPort) return 0;
    return parsed.port;
  }

  /// Ranks candidates by how close they are, then by country, then by name.
  static List<PeerCandidate> rankByDistance(
    List<PeerCandidate> peers, {
    double? lat,
    double? lon,
    String? countrySlug,
  }) {
    final sorted = [...peers];
    double distanceOf(PeerCandidate peer) {
      if (lat == null || lon == null) return 0;
      final country = countryBySlug(peer.country);
      if (country == null) return 20000;
      return distanceKm(lat, lon, country.lat, country.lon);
    }

    sorted.sort((a, b) {
      if (countrySlug != null && countrySlug.isNotEmpty) {
        final aHome = a.country == countrySlug ? 0 : 1;
        final bHome = b.country == countrySlug ? 0 : 1;
        if (aHome != bHome) return aHome - bHome;
      }
      final delta = distanceOf(a) - distanceOf(b);
      if (delta.abs() > 1) return delta < 0 ? -1 : 1;
      final byCountry = a.country.compareTo(b.country);
      if (byCountry != 0) return byCountry;
      return a.uri.compareTo(b.uri);
    });
    return sorted;
  }
}
