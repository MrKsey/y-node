import 'package:flutter_test/flutter_test.dart';
import 'package:y_node/l10n/strings.dart';

int _placeholders(String value) => '%s'.allMatches(value).length;

void main() {
  final en = L10n.table('en');

  test('the table is not empty', () {
    expect(en, isNotEmpty);
  });

  test('no string is empty', () {
    for (final entry in en.entries) {
      expect(entry.value.trim(), isNotEmpty, reason: entry.key);
    }
  });

  test('every interpolated string has a placeholder', () {
    // Keys that take values through `tf`; the count is asserted so a string
    // that loses its `%s` cannot silently drop the value.
    const interpolated = {
      'connectedFor': 1,
      'latencyRefresh': 1,
      'stagePeers': 2,
      'peersConnected': 2,
      'peerCountRaised': 1,
      'peerSetUpdated': 1,
      'peerCountLabel': 1,
      'addBestN': 1,
      'catalogCount': 1,
      'importCount': 1,
      'importDone': 1,
      'dnsOk': 1,
      'dnsOkTcp': 1,
      'peerErrorLastSeen': 1,
      'donationCopied': 1,
      'updateAvailableBody': 1,
      'updateFailed': 1,
      'updateOpenFor': 1,
      'onboardingFound': 1,
      'splitSelectedCount': 1,
      'exitCardOnlineHint': 2,
      'exitRemoveBody': 1,
      'exitRegistered': 1,
      'exitRegisterFailed': 1,
      'exitLastChecked': 1,
      'exitUdpOnline': 1,
      'exitUdpError': 1,
      'exitUdpTraffic': 4,
      'exitUdpTrafficFull': 4,
      'exitIpv6TestAddress': 1,
      'exitIpv6TestThrough': 1,
    };
    for (final entry in interpolated.entries) {
      expect(
        _placeholders(en[entry.key] ?? ''),
        entry.value,
        reason: 'placeholder count in "${entry.key}"',
      );
    }
  });

  test('tf fills the placeholders in order', () {
    const l10n = L10n();
    final text = l10n.tf('addBestN', [3]);
    expect(text.contains('3'), isTrue);
    expect(text.contains('%s'), isFalse);
  });

  test('a missing key falls back to its own name', () {
    const l10n = L10n();
    expect(l10n.t('definitely-not-a-key'), 'definitely-not-a-key');
  });
}
