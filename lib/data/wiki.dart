import 'dart:async';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:http/http.dart' as http;

import 'models.dart';

/// A DNS server listed on the wiki, with the place it lives in.
class DnsPreset {
  const DnsPreset({
    required this.address,
    this.location = '',
    this.admin = '',
    this.note = '',
    this.deprecated = false,
  });

  final String address;
  final String location;
  final String admin;
  final String note;
  final bool deprecated;

  String get label => location.isEmpty ? address : location;
}

/// Reads the Yggdrasil wiki (a DokuWiki) and turns its tables into things the
/// app can use: the internal DNS servers and the catalogue of in-network web
/// sites for the address book.
///
/// The pages are downloaded when the tunnel is up and parsed from the bundled
/// snapshot otherwise, with the same parser, so the offline copy can never drift
/// away from the live one.
class WikiService {
  WikiService({http.Client? client, AssetBundle? assets})
    : _client = client ?? http.Client(),
      _assets = assets ?? rootBundle;

  final http.Client _client;
  final AssetBundle _assets;

  static const String servicesUrl =
      'https://yggwiki.cc/yggdrasil:sites_and_services:other_network_services?do=export_raw';
  static const String dnsUrl =
      'https://yggwiki.cc/yggdrasil:dns:internal_dns?do=export_raw';

  static const String servicesAsset = 'assets/data/wiki_services.txt';
  static const String dnsAsset = 'assets/data/wiki_dns.txt';

  static const Duration _timeout = Duration(seconds: 20);

  /// Returns the DNS servers from the wiki, best first, deprecated ones last.
  Future<List<DnsPreset>> loadDns({bool allowNetwork = true}) async {
    final raw = await _fetch(dnsUrl, dnsAsset, allowNetwork);
    final presets = parseDns(raw);
    return presets.isEmpty ? defaultDnsPresets : presets;
  }

  /// Returns the web resources of the wiki that live inside Yggdrasil.
  Future<List<Resource>> loadServices({bool allowNetwork = true}) async {
    final raw = await _fetch(servicesUrl, servicesAsset, allowNetwork);
    return parseServices(raw);
  }

  Future<String> _fetch(String url, String asset, bool allowNetwork) async {
    if (allowNetwork) {
      try {
        final response = await _client
            .get(Uri.parse(url), headers: const {'Accept': 'text/plain'})
            .timeout(_timeout);
        if (response.statusCode == 200 && response.body.trim().isNotEmpty) {
          return response.body;
        }
      } catch (_) {
        // Fall back to the snapshot below.
      }
    }
    try {
      return await _assets.loadString(asset);
    } catch (_) {
      return '';
    }
  }

  // ------------------------------------------------------------------
  // DNS
  // ------------------------------------------------------------------

  /// Parses the table on `yggdrasil:dns:internal_dns`.
  ///
  /// Rows look like `| <del>old</del> new | Frankfurt, Germany | [[user:rev|Revertron]] | ALFIS, OpenNIC |`.
  /// The struck-through address is a retired one and is skipped.
  static List<DnsPreset> parseDns(String raw) {
    final result = <DnsPreset>[];
    final seen = <String>{};

    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('|')) continue;
      final cells = _splitRow(trimmed);
      if (cells.isEmpty) continue;

      final addresses = _ipv6In(_stripDeleted(cells[0]));
      if (addresses.isEmpty) continue;

      final preset = DnsPreset(
        address: addresses.first,
        location: _plainText(cells.length > 1 ? cells[1] : ''),
        admin: _plainText(cells.length > 2 ? cells[2] : ''),
        note: _plainText(cells.length > 3 ? cells[3] : ''),
      );
      if (!seen.add(preset.address)) continue;
      result.add(preset);
    }

    return result;
  }

  /// The wiki servers plus three more from the official "Public services" page,
  /// used when even the snapshot is missing.
  static const List<DnsPreset> defaultDnsPresets = [
    DnsPreset(
      address: '308:84:68:55::',
      location: 'Frankfurt, Germany',
      admin: 'Revertron',
      note: 'ALFIS, OpenNIC, AdGuard, Clearnet',
    ),
    DnsPreset(
      address: '308:25:40:bd::',
      location: 'Bratislava, Slovakia',
      admin: 'Revertron',
      note: 'ALFIS, OpenNIC, AdGuard, Clearnet',
    ),
    DnsPreset(
      address: '308:62:45:62::',
      location: 'Amsterdam, Netherlands',
      admin: 'Revertron',
      note: 'ALFIS, OpenNIC, AdGuard, Clearnet',
    ),
    DnsPreset(
      address: '308:c8:48:45::',
      location: 'Buffalo, USA',
      admin: 'Revertron',
      note: 'ALFIS, OpenNIC, AdGuard, Clearnet',
    ),
    DnsPreset(
      address: '215:1e33:6417:d636:c807:6985:4f4e:fda0',
      location: 'Ukraine',
      admin: 'ufm',
      note: 'ALFIS, ClearNet',
    ),
    DnsPreset(
      address: '202:1d4e:724e:de52:8273:e2b5:4988:a9ba',
      location: 'strcat.su',
      admin: '',
      note: 'Non-filtering',
    ),
    DnsPreset(
      address: '300:7c75:d590:c5d8::100',
      location: 'Melbourne, Australia',
      admin: 'evasil',
      note: 'ALFIS, Clearnet, no filters',
    ),
    DnsPreset(
      address: '301:3423:a49b:f4e0::100',
      location: 'Sydney, Australia',
      admin: 'evasil',
      note: 'ALFIS, Clearnet, no filters',
    ),
    DnsPreset(
      address: '202:cbff:6f7f:fa95:c6e9:3768:a96e:d1c8',
      location: 'tilde.horse',
      note: 'ALFIS/meshname DNS resolver',
    ),
  ];

  // ------------------------------------------------------------------
  // Services
  // ------------------------------------------------------------------

  /// Parses the tables on `yggdrasil:sites_and_services:other_network_services`.
  ///
  /// Only rows whose address is an `http(s)://[<ygg address>]` URL are kept: the
  /// address book exists to open in-network sites in a browser, so torrent
  /// trackers, bridge lines and game servers are of no use there.
  static List<Resource> parseServices(String raw) {
    final result = <Resource>[];
    final seen = <String>{};
    var section = '';
    var subsection = '';

    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('====')) {
        final title = _plainText(_headingText(trimmed));
        final level = RegExp(r'^=+').firstMatch(trimmed)?.group(0)?.length ?? 4;
        if (level >= 6) {
          section = title;
          subsection = '';
        } else if (level >= 4) {
          subsection = title;
        }
        continue;
      }
      if (!trimmed.startsWith('|')) continue;

      final cells = _splitRow(trimmed);
      if (cells.isEmpty) continue;

      final url = _httpUrlIn(cells[0]);
      if (url == null) continue;
      if (!seen.add(url)) continue;

      final domain = cells.length > 1 ? _plainText(cells[1]) : '';
      final where = subsection.isNotEmpty ? subsection : section;

      final title = _pickTitle(domain, where, url);
      result.add(
        Resource(
          id: 'wiki:${_slug(url)}',
          title: title,
          url: url,
          description: where.isEmpty ? url : where,
          builtIn: false,
        ),
      );
    }

    return result;
  }

  /// The tables are not consistent — sometimes the second column is a domain,
  /// sometimes the administrator, sometimes a platform — so the title only takes
  /// the domain when it actually looks like one, and otherwise falls back to the
  /// heading of the table, which is always meaningful.
  static String _pickTitle(String domain, String where, String url) {
    final looksLikeDomain =
        domain.contains('.') &&
        !domain.contains(' ') &&
        !domain.startsWith('-');
    if (looksLikeDomain) return domain;
    if (where.isNotEmpty) return where;
    return Uri.tryParse(url)?.host ?? url;
  }

  // ------------------------------------------------------------------
  // DokuWiki helpers
  // ------------------------------------------------------------------

  /// Splits a table row on `|` while keeping `[[link|text]]` intact.
  static List<String> _splitRow(String line) {
    final cells = <String>[];
    final buffer = StringBuffer();
    var depth = 0;
    for (var i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == '[' && i + 1 < line.length && line[i + 1] == '[') {
        depth++;
        buffer.write('[[');
        i++;
        continue;
      }
      if (char == ']' && i + 1 < line.length && line[i + 1] == ']') {
        if (depth > 0) depth--;
        buffer.write(']]');
        i++;
        continue;
      }
      if (char == '|' && depth == 0) {
        cells.add(buffer.toString().trim());
        buffer.clear();
        continue;
      }
      buffer.write(char);
    }
    final tail = buffer.toString().trim();
    if (tail.isNotEmpty) cells.add(tail);
    if (cells.isNotEmpty && cells.first.isEmpty) cells.removeAt(0);
    return cells;
  }

  /// Removes DokuWiki markup and turns `[[target|text]]` into `text`.
  static String _plainText(String value) {
    var text = value;
    text = text.replaceAllMapped(
      RegExp(r'\[\[([^\]|]*)\|([^\]]*)\]\]'),
      (match) =>
          match.group(2)!.trim().isEmpty ? match.group(1)! : match.group(2)!,
    );
    text = text.replaceAllMapped(
      RegExp(r'\[\[([^\]]*)\]\]'),
      (match) => _linkText(match.group(1)!),
    );
    text = text.replaceAll(RegExp(r'<[^>]+>'), '');
    text = text.replaceAll(RegExp(r'^\s*[\^*]+\s*'), '');
    text = text.replaceAll('%%', '');
    text = text.replaceAll(RegExp(r'\s+'), ' ');
    return text.trim();
  }

  static String _headingText(String line) {
    return line.replaceAll(RegExp(r'^=+'), '').replaceAll(RegExp(r'=+$'), '');
  }

  /// The text of a link that has no alias: DokuWiki targets carry a namespace
  /// (`user:ufm`) or a redirect marker (`this>`), and the last segment is what a
  /// reader would see.
  static String _linkText(String target) {
    var text = target.trim();
    if (text.contains('://')) return text;
    final colon = text.lastIndexOf(':');
    if (colon >= 0 && colon < text.length - 1) text = text.substring(colon + 1);
    final arrow = text.lastIndexOf('>');
    if (arrow >= 0 && arrow < text.length - 1) text = text.substring(arrow + 1);
    return text;
  }

  /// Drops `<del>…</del>` spans, which mark retired servers.
  static String _stripDeleted(String value) {
    return value.replaceAll(RegExp(r'<del>.*?</del>', dotAll: true), ' ');
  }

  static final RegExp _ipv6Pattern = RegExp(
    r'(?<![0-9a-fA-F:])([0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{0,4}){2,7})(?![0-9a-fA-F:])',
  );

  static List<String> _ipv6In(String value) {
    return [
      for (final match in _ipv6Pattern.allMatches(value))
        if (_looksLikeYggAddress(match.group(1)!)) match.group(1)!,
    ];
  }

  static final RegExp _httpPattern = RegExp(
    r'https?://(?:\[[0-9a-fA-F:]+\](?::\d+)?(?:/[^\s\|\]\)]*)?|[^\s\|\]\)]+)',
  );

  static String? _httpUrlIn(String cell) {
    final match = _httpPattern.firstMatch(cell);
    if (match == null) return null;
    final url = match.group(0)!;
    final parsed = Uri.tryParse(url);
    if (parsed == null) return null;
    if (!isYggAddress(parsed.host)) return null;
    return url;
  }

  /// True for the `200::/7` range Yggdrasil hands out.
  static bool isYggAddress(String host) {
    final first = host.split(':').first;
    if (first.isEmpty) return false;
    final value = int.tryParse(first, radix: 16);
    if (value == null) return false;
    return value >= 0x200 && value <= 0x3ff;
  }

  static bool _looksLikeYggAddress(String address) {
    if (!address.contains(':')) return false;
    try {
      Uri.parseIPv6Address(address);
    } on FormatException {
      return false;
    }
    return isYggAddress(address);
  }

  static String _slug(String value) {
    return value
        .replaceAll(RegExp(r'^https?://'), '')
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '')
        .toLowerCase();
  }
}
