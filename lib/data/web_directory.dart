import 'models.dart';

/// Parses the Yggdrasil web directory into address-book entries.
///
/// The directory is an HTML table of sites that live inside the network: the
/// address, a human description and the domain names of every site. Only
/// `http(s)` links to Yggdrasil addresses are kept: everything else on the page
/// is navigation, a stylesheet or an out-of-network link.
class WebDirectory {
  const WebDirectory._();

  static List<Resource> parse(String html, {required String baseUrl}) {
    final base = Uri.tryParse(baseUrl);
    if (base == null) return const [];

    final result = <Resource>[];
    final seen = <String>{};

    // The directory is a table: the address, a human description and the domain
    // names of every site. The description is what the list shows first, the
    // address goes under it.
    for (final row in _rowPattern.allMatches(html)) {
      final rowHtml = row.group(1) ?? '';
      final url = _addressIn(rowHtml);
      if (url == null) continue;
      if (!_keep(url, baseUrl)) continue;
      final key = _key(url);
      if (!seen.add(key)) continue;

      final description = _cellText(rowHtml, 'descr');
      final domain = _domainIn(rowHtml);
      final title = description.isNotEmpty
          ? description
          : domain.isNotEmpty
          ? domain
          : _key(url);

      result.add(
        Resource(
          id: 'web:${_slug(url)}',
          title: title,
          url: url,
          description: domain,
        ),
      );
    }

    if (result.isNotEmpty) return result;
    return _parseLinks(html, base: base, baseUrl: baseUrl);
  }

  /// The fallback for a page that is a plain list of links rather than the
  /// directory table: links are kept, headings name the sections.
  static List<Resource> _parseLinks(
    String html, {
    required Uri base,
    required String baseUrl,
  }) {
    final result = <Resource>[];
    final seen = <String>{};
    var section = '';

    final pattern = RegExp(
      r'<(h[1-6])\b[^>]*>(.*?)</\1\s*>|<a\b([^>]*)>(.*?)</a\s*>',
      caseSensitive: false,
      dotAll: true,
    );

    for (final match in pattern.allMatches(html)) {
      final heading = match.group(1);
      if (heading != null) {
        final text = _text(match.group(2) ?? '');
        if (_isSection(text)) section = text;
        continue;
      }

      final attrs = match.group(3) ?? '';
      final href = _href(attrs);
      if (href == null || href.isEmpty) continue;
      if (href.startsWith('#') || href.startsWith('mailto:')) continue;

      final Uri target;
      try {
        target = base.resolve(href);
      } catch (_) {
        continue;
      }
      final url = target.toString();
      // Links back to the directory itself are its navigation: forms, category
      // pages, feeds.
      if (target.host == base.host && target.path.length > 1) continue;
      if (!_keep(url, baseUrl)) continue;
      final key = _key(url);
      if (!seen.add(key)) continue;

      final label = _text(match.group(4) ?? '');
      final title = label.isEmpty || label.startsWith('http')
          ? target.host
          : label.length > 90
          ? '${label.substring(0, 89)}…'
          : label;

      result.add(
        Resource(
          id: 'web:${_slug(url)}',
          title: title,
          url: url,
          description: section,
        ),
      );
    }

    return result;
  }

  /// True for a link that belongs in the book: an `http(s)` site on a Yggdrasil
  /// address, not the directory itself and not one of its assets.
  static bool _keep(String url, String baseUrl) {
    final Uri target;
    try {
      target = Uri.parse(url);
    } catch (_) {
      return false;
    }
    if (target.scheme != 'http' && target.scheme != 'https') return false;
    if (target.host.isEmpty) return false;
    if (!_isYggHost(target.host)) return false;
    if (_isAsset(target.path)) return false;
    return _key(url) != _baseKey(baseUrl);
  }

  static String _key(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  static String _baseKey(String baseUrl) => baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;

  static final RegExp _rowPattern = RegExp(
    r'<tr\b[^>]*>(.*?)</tr\s*>',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _cellPattern = RegExp(
    r'<td\b[^>]*class="([^"]*)"[^>]*>(.*?)</td\s*>',
    caseSensitive: false,
    dotAll: true,
  );

  /// The address of a row: the link in its `addr` cell.
  static String? _addressIn(String rowHtml) {
    for (final cell in _cellPattern.allMatches(rowHtml)) {
      final classes = cell.group(1) ?? '';
      if (!classes.contains('addr')) continue;
      final href = _href(cell.group(2) ?? '');
      if (href == null || href.isEmpty) return null;
      final url = href.trim();
      if (!url.startsWith('http')) return null;
      return url;
    }
    return null;
  }

  /// The text of the first non-empty cell of the given class.
  static String _cellText(String rowHtml, String name) {
    for (final cell in _cellPattern.allMatches(rowHtml)) {
      final classes = (cell.group(1) ?? '').split(' ');
      if (!classes.contains(name)) continue;
      final text = _text(cell.group(2) ?? '');
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  /// The ALFIS domain of a row, which is what a reader recognises the site by.
  static String _domainIn(String rowHtml) => _cellText(rowHtml, 'dname');

  /// A heading is useful as a description only when it names a category, not
  /// when it is the page title or a breadcrumb.
  static bool _isSection(String text) {
    if (text.isEmpty || text.length > 60) return false;
    if (text.contains('//') || text.contains('-->')) return false;
    if (text.toLowerCase().contains('web directory')) return false;
    return true;
  }

  static bool _isAsset(String path) {
    final lower = path.toLowerCase();
    for (final extension in const [
      '.css',
      '.js',
      '.png',
      '.jpg',
      '.jpeg',
      '.gif',
      '.svg',
      '.ico',
      '.woff',
      '.woff2',
      '.ttf',
    ]) {
      if (lower.endsWith(extension)) return true;
    }
    return false;
  }

  static String? _href(String attrs) {
    final quoted = RegExp(
      r'''href\s*=\s*("([^"]*)"|'([^']*)')''',
      caseSensitive: false,
    ).firstMatch(attrs);
    if (quoted != null) {
      return _decodeEntities(quoted.group(2) ?? quoted.group(3) ?? '').trim();
    }
    final bare = RegExp(
      r'href\s*=\s*([^\s>]+)',
      caseSensitive: false,
    ).firstMatch(attrs);
    return bare?.group(1)?.trim();
  }

  /// The `200::/7` range Yggdrasil hands out, as a first-hextet check.
  static bool _isYggHost(String host) {
    final first = host.split(':').first;
    if (first.isEmpty) return false;
    final value = int.tryParse(first, radix: 16);
    if (value == null) return false;
    return value >= 0x200 && value <= 0x3ff;
  }

  /// Removes tags, decodes the entities such a page uses and collapses
  /// whitespace. The table is applied twice because older pages double-encode.
  static String _text(String value) {
    var text = value.replaceAll(RegExp(r'<[^>]*>'), ' ');
    text = _decodeEntities(_decodeEntities(text));
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _decodeEntities(String value) => value
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  static String _slug(String url) {
    return url
        .replaceAll(RegExp(r'^https?://'), '')
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '')
        .toLowerCase();
  }
}
