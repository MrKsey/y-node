import '../l10n/strings.dart';

/// Human-readable byte counts: `0 B`, `812 KB`, `14.3 MB`.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// Latency with a sensible number of digits: `14.4 ms`.
String formatLatency(double milliseconds) {
  if (milliseconds <= 0) return '—';
  final digits = milliseconds >= 100 ? 0 : 1;
  return '${milliseconds.toStringAsFixed(digits)} ms';
}

/// `2 h 14 min`, `45 s`.
String formatDuration(int seconds, L10n l) {
  if (seconds <= 0) return '—';
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final rest = seconds % 60;
  final h = l.t('hours');
  final m = l.t('minutes');
  final s = l.t('seconds');
  if (hours > 0) return '$hours $h $minutes $m';
  if (minutes > 0) return '$minutes $m $rest $s';
  return '$rest $s';
}

/// `2 h 14 min 05 s`, used for the uptime next to the connect button.
String formatClock(int seconds) {
  if (seconds < 0) seconds = 0;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final rest = seconds % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  if (hours > 0) return '${two(hours)}:${two(minutes)}:${two(rest)}';
  return '${two(minutes)}:${two(rest)}';
}

/// `27.10.2026 14:32`, local time.
String formatDateTime(DateTime when) {
  final local = when.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// `5 min ago`, `just now`.
String formatAgo(DateTime? when, L10n l) {
  if (when == null) return l.t('unknown');
  final delta = DateTime.now().difference(when);
  if (delta.inSeconds < 45) return l.t('justNow');
  final minutes = '${delta.inMinutes} ${l.t('minutes')} ${l.t('ago')}';
  if (delta.inMinutes < 60) return minutes;
  final hours = '${delta.inHours} ${l.t('hours')} ${l.t('ago')}';
  if (delta.inHours < 24) return hours;
  return '${delta.inDays} ${l.t('days')} ${l.t('ago')}';
}

/// Trims a long peer URI for a one-line subtitle.
String shortUri(String uri, {int max = 44}) {
  if (uri.length <= max) return uri;
  return '${uri.substring(0, max - 1)}…';
}

/// The host part of a peer URI, which is what the user recognises.
String uriHost(String uri) {
  final parsed = Uri.tryParse(uri);
  if (parsed == null || parsed.host.isEmpty) return uri;
  return parsed.host;
}
