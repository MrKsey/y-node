import 'dart:convert';

import 'package:http/http.dart' as http;

/// A published GitHub release that is newer than the running build.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.tagName,
    required this.notes,
    required this.releaseUrl,
  });

  /// Version without the leading "v", e.g. "1.4.4".
  final String version;

  /// Raw tag name, e.g. "v1.4.4".
  final String tagName;

  /// Release notes as written on GitHub (may be empty).
  final String notes;

  /// Browser URL of the release page.
  final String releaseUrl;
}

/// Raised when the release check cannot be completed.
class UpdateCheckException implements Exception {
  const UpdateCheckException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Checks the project's GitHub releases for a newer version. The app only
/// reports the release and opens its page in the browser; installing the APK is
/// left to the browser, because Android does not allow a regular app to replace
/// itself without the user's confirmation.
class UpdateService {
  UpdateService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const String repo = 'MrKsey/y-node';
  static const String _latestReleaseUrl =
      'https://api.github.com/repos/$repo/releases/latest';

  static const Duration _timeout = Duration(seconds: 20);

  /// Asks GitHub for the latest release. Returns the update when it is newer
  /// than [currentVersion], null when the build is up to date. Throws
  /// [UpdateCheckException] when the release could not be read.
  Future<UpdateInfo?> checkForUpdate({required String currentVersion}) async {
    final http.Response response;
    try {
      response = await _client
          .get(
            Uri.parse(_latestReleaseUrl),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'Y-Node-Android',
            },
          )
          .timeout(_timeout);
    } catch (e) {
      throw UpdateCheckException('$e');
    }
    if (response.statusCode != 200) {
      throw UpdateCheckException('GitHub returned HTTP ${response.statusCode}');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (e) {
      throw UpdateCheckException('Unexpected release payload: $e');
    }
    if (decoded is! Map) {
      throw const UpdateCheckException('Unexpected release payload');
    }

    final tag = (decoded['tag_name'] as String?)?.trim() ?? '';
    if (tag.isEmpty) {
      throw const UpdateCheckException('The latest release has no tag');
    }
    if (!isNewerVersion(tag, currentVersion)) return null;

    return UpdateInfo(
      version: tag.replaceFirst(RegExp(r'^[vV]'), ''),
      tagName: tag,
      notes: (decoded['body'] as String?)?.trim() ?? '',
      releaseUrl:
          (decoded['html_url'] as String?) ??
          'https://github.com/$repo/releases',
    );
  }

  /// True when [candidate] is a newer version than [current]. Handles a leading
  /// "v", a "+build" suffix and a "-prerelease" suffix.
  static bool isNewerVersion(String candidate, String current) {
    final next = _parseVersion(candidate);
    final now = _parseVersion(current);
    // A development build has no numeric version: any published release wins.
    if (next == null) return false;
    if (now == null) return true;
    return _compare(next, now) > 0;
  }

  static List<int>? _parseVersion(String raw) {
    final cleaned = raw.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final core = cleaned.split('+').first.split('-').first;
    if (core.isEmpty) return null;
    final parts = <int>[];
    for (final part in core.split('.')) {
      final value = int.tryParse(part);
      if (value == null) return null;
      parts.add(value);
    }
    return parts;
  }

  static int _compare(List<int> a, List<int> b) {
    final length = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }
}
