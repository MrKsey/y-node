import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'geo.dart';

/// Where the user is, as far as GeoIP can tell.
class GeoLocation {
  const GeoLocation({
    required this.countryCode,
    required this.countrySlug,
    required this.city,
    required this.lat,
    required this.lon,
    this.source = '',
  });

  final String countryCode;
  final String countrySlug;
  final String city;
  final double lat;
  final double lon;
  final String source;

  Map<String, dynamic> toJson() => {
    'countryCode': countryCode,
    'countrySlug': countrySlug,
    'city': city,
    'lat': lat,
    'lon': lon,
    'source': source,
  };

  factory GeoLocation.fromJson(Map<String, dynamic> json) => GeoLocation(
    countryCode: (json['countryCode'] as String?) ?? '',
    countrySlug: (json['countrySlug'] as String?) ?? '',
    city: (json['city'] as String?) ?? '',
    lat: (json['lat'] as num?)?.toDouble() ?? 0,
    lon: (json['lon'] as num?)?.toDouble() ?? 0,
    source: (json['source'] as String?) ?? '',
  );
}

/// Resolves the device location so the peer list can be ranked by distance.
///
/// Two providers are tried in order, both without an API key. `ipinfo.io` is
/// HTTPS and answers first; `ip-api.com` is the fallback and only speaks HTTP,
/// which the network security config allows for that host alone.
class GeoIpService {
  GeoIpService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 8);

  /// Addresses already resolved in this session: the exit node is looked up
  /// once, not on every rebuild. A failed lookup is not cached, so the next
  /// call (for example, after the tunnel comes up) can try again.
  final Map<String, GeoLocation> _addressCache = {};

  Future<GeoLocation?> lookup() async {
    final first = await _fromIpInfo();
    if (first != null) return first;
    return _fromIpApi();
  }

  /// Resolves the country of one address instead of the device's own.
  ///
  /// Used for the exit node: the peer link carries the server address, and the
  /// flag in the peer list should show where that server is, not where the
  /// phone happens to be.
  Future<GeoLocation?> lookupAddress(String address) async {
    final value = address.trim();
    if (value.isEmpty) return null;
    final cached = _addressCache[value];
    if (cached != null) return cached;
    final first = await _fromIpInfo(value);
    final result = first ?? await _fromIpApi(value);
    if (result != null) _addressCache[value] = result;
    return result;
  }

  Future<GeoLocation?> _fromIpInfo([String? address]) async {
    try {
      final target = address == null
          ? 'https://ipinfo.io/json'
          : 'https://ipinfo.io/$address/json';
      final response = await _client
          .get(Uri.parse(target), headers: const {'Accept': 'application/json'})
          .timeout(_timeout);
      if (response.statusCode != 200) return null;
      final map = jsonDecode(response.body) as Map<String, dynamic>;
      final code = (map['country'] as String?)?.trim().toUpperCase() ?? '';
      if (code.isEmpty) return null;
      final loc = (map['loc'] as String?) ?? '';
      final parts = loc.split(',');
      final lat = parts.isNotEmpty ? double.tryParse(parts[0]) : null;
      final lon = parts.length > 1 ? double.tryParse(parts[1]) : null;
      final country = countryByCode(code);
      return GeoLocation(
        countryCode: code,
        countrySlug: country?.slug ?? '',
        city: (map['city'] as String?) ?? '',
        lat: lat ?? country?.lat ?? 0,
        lon: lon ?? country?.lon ?? 0,
        source: 'ipinfo.io',
      );
    } catch (_) {
      return null;
    }
  }

  Future<GeoLocation?> _fromIpApi([String? address]) async {
    try {
      final target = address == null
          ? 'http://ip-api.com/json/?fields=status,country,countryCode,city,lat,lon'
          : 'http://ip-api.com/json/$address'
                '?fields=status,country,countryCode,city,lat,lon';
      final response = await _client
          .get(Uri.parse(target), headers: const {'Accept': 'application/json'})
          .timeout(_timeout);
      if (response.statusCode != 200) return null;
      final map = jsonDecode(response.body) as Map<String, dynamic>;
      if ((map['status'] as String?) != 'success') return null;
      final code = (map['countryCode'] as String?)?.trim().toUpperCase() ?? '';
      if (code.isEmpty) return null;
      final country = countryByCode(code);
      return GeoLocation(
        countryCode: code,
        countrySlug: country?.slug ?? '',
        city: (map['city'] as String?) ?? '',
        lat: (map['lat'] as num?)?.toDouble() ?? country?.lat ?? 0,
        lon: (map['lon'] as num?)?.toDouble() ?? country?.lon ?? 0,
        source: 'ip-api.com',
      );
    } catch (_) {
      return null;
    }
  }
}
