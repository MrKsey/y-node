import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The answer of an address echo service.
class PublicIpResult {
  const PublicIpResult({
    this.ok = false,
    this.ip = '',
    this.via = '',
    this.ms = 0,
    this.error = '',
  });

  final bool ok;
  final String ip;

  /// `direct` for the real network, `exit` for the traffic the exit carries.
  final String via;

  /// The round-trip of the check, in milliseconds.
  final double ms;

  /// A short code the UI translates: `exit_off`, `tunnel_off`, `timeout`,
  /// `no_ip`, `failed`.
  final String error;

  factory PublicIpResult.fromJson(Map<String, dynamic> json) => PublicIpResult(
    ok: (json['ok'] as bool?) ?? false,
    ip: (json['ip'] as String?) ?? '',
    via: (json['via'] as String?) ?? '',
    ms: (json['ms'] as num?)?.toDouble() ?? 0,
    error: (json['error'] as String?) ?? '',
  );

  static PublicIpResult? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) return null;
      return PublicIpResult.fromJson(value);
    } catch (_) {
      return null;
    }
  }
}

/// The echo service the app asks. It is addressed by its literal IP on
/// purpose: the exit path cannot resolve names, and the page is one line.
const String publicIpTraceUrl = 'https://1.1.1.1/cdn-cgi/trace';

/// Reads the `ip=` line of the Cloudflare trace page.
String? parseTraceIp(String body) {
  for (final line in body.split('\n')) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('ip=')) continue;
    final value = trimmed.substring('ip='.length).trim();
    if (value.isEmpty || InternetAddress.tryParse(value) == null) return null;
    return value;
  }
  return null;
}

/// Asks the echo service what it sees without the tunnel.
///
/// The app is always excluded from its own VPN (see `buildTunnel` in
/// `YggVpnService`), so a plain socket leaves the phone on the real network
/// even while the tunnel is up: that is exactly the "without the tunnel"
/// answer.
Future<PublicIpResult> fetchDirectIp({
  Duration timeout = const Duration(seconds: 8),
}) async {
  final started = DateTime.now();
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client
        .getUrl(Uri.parse(publicIpTraceUrl))
        .timeout(timeout);
    request.headers.set(HttpHeaders.userAgentHeader, 'Y-Node');
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      return const PublicIpResult(via: 'direct', error: 'failed');
    }
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    final ip = parseTraceIp(body);
    if (ip == null) return const PublicIpResult(via: 'direct', error: 'no_ip');
    return PublicIpResult(
      ok: true,
      ip: ip,
      via: 'direct',
      ms: DateTime.now().difference(started).inMilliseconds.toDouble(),
    );
  } on TimeoutException {
    return const PublicIpResult(via: 'direct', error: 'timeout');
  } catch (_) {
    return const PublicIpResult(via: 'direct', error: 'failed');
  } finally {
    client.close(force: true);
  }
}
