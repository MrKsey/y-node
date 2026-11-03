import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:y_node/data/peers_source.dart';

const String _russiaSample = '''
# Russia Peers

Add connection strings from the below list to the `Peers: []` section.

### Moscow

* Moscow, home public node, operated by AveryanAlex
  * `tcp://ygg-msk-1.averyan.ru:8363`
  * `tls://ygg-msk-1.averyan.ru:8362`
  * `quic://ygg-msk-1.averyan.ru:8364`

* Moscow, VPS public node, operated by Nikat
  * `tcp://yggno.de:18226`
  * `tls://yggno.de:18227`
  * `tls://45.147.200.202:443`

### Saint Petersburg

* Saint Petersburg, operated by paulll
  * `tls://box.paulll.cc:13338`

### Novosibirsk

  * `quic://novosibirsk.mie.foundation:9952`
''';

void main() {
  group('parseMarkdown', () {
    test('keeps the city of every connection string', () {
      final peers = PeersSource.parseMarkdown(_russiaSample, country: 'russia');
      expect(peers, isNotEmpty);
      final msk = peers.firstWhere(
        (peer) => peer.host == 'ygg-msk-1.averyan.ru',
      );
      expect(msk.city, 'Moscow');
      expect(msk.country, 'russia');
      final spb = peers.firstWhere((peer) => peer.host == 'box.paulll.cc');
      expect(spb.city, 'Saint Petersburg');
      final nsk = peers.firstWhere((peer) => peer.host.contains('novosibirsk'));
      expect(nsk.city, 'Novosibirsk');
    });

    test('reads every transport of a host', () {
      final peers = PeersSource.parseMarkdown(_russiaSample);
      final schemes = peers
          .where((peer) => peer.host == 'ygg-msk-1.averyan.ru')
          .map((peer) => peer.scheme)
          .toList();
      expect(schemes, containsAll(['tcp', 'tls', 'quic']));
    });

    test('ignores malformed connection strings', () {
      final peers = PeersSource.parseMarkdown('''
### Somewhere
  * `tcp://no-port.example.com`
  * `ftp://files.example.com:21`
  * `tls://ok.example.com:443`
''');
      expect(peers.map((peer) => peer.host), ['ok.example.com']);
    });
  });

  group('parseZip', () {
    test('keeps one entry per host and prefers the better transport', () {
      final archive = Archive()
        ..addFile(
          ArchiveFile(
            'public-peers-master/europe/russia.md',
            utf8.encode(_russiaSample).length,
            utf8.encode(_russiaSample),
          ),
        )
        ..addFile(
          ArchiveFile(
            'public-peers-master/other/i2p.md',
            utf8.encode('* `tcp://hidden.i2p:1234`').length,
            utf8.encode('* `tcp://hidden.i2p:1234`'),
          ),
        )
        ..addFile(
          ArchiveFile('public-peers-master/README.md', 5, utf8.encode('# Hi')),
        );
      final bytes = ZipEncoder().encode(archive);

      final peers = PeersSource.parseZip(bytes);
      final hosts = peers.map((peer) => peer.host).toList();
      expect(hosts.toSet().length, hosts.length, reason: 'one entry per host');
      expect(hosts, isNot(contains('hidden.i2p')));

      final msk = peers.firstWhere(
        (peer) => peer.host == 'ygg-msk-1.averyan.ru',
      );
      expect(msk.scheme, 'tls', reason: 'TLS outranks TCP and QUIC');
      expect(msk.country, 'russia');
    });

    test('returns an empty list for garbage', () {
      expect(PeersSource.parseZip([1, 2, 3, 4]), isEmpty);
    });
  });

  group('rankByDistance', () {
    test('puts the nearest country first', () {
      const peers = [
        PeerCandidate(
          uri: 'tls://a.example:443',
          host: 'a.example',
          country: 'united-states',
          city: '',
        ),
        PeerCandidate(
          uri: 'tls://b.example:443',
          host: 'b.example',
          country: 'russia',
          city: '',
        ),
        PeerCandidate(
          uri: 'tls://c.example:443',
          host: 'c.example',
          country: 'finland',
          city: '',
        ),
      ];
      final ranked = PeersSource.rankByDistance(
        peers,
        lat: 55.75,
        lon: 37.61,
        countrySlug: 'russia',
      );
      expect(ranked.first.country, 'russia');
      expect(ranked.last.country, 'united-states');
    });

    test('falls back to alphabetical order without a location', () {
      const peers = [
        PeerCandidate(uri: 'u1', host: 'h1', country: 'sweden', city: ''),
        PeerCandidate(uri: 'u2', host: 'h2', country: 'germany', city: ''),
      ];
      final ranked = PeersSource.rankByDistance(peers);
      expect(ranked.map((peer) => peer.country), ['germany', 'sweden']);
    });
  });

  group('isValidPeerUri', () {
    test('accepts the transports the node speaks', () {
      expect(isValidPeerUri('tcp://yggno.de:18226'), isTrue);
      expect(isValidPeerUri('tls://[2a00:b700::a:279]:443'), isTrue);
      expect(isValidPeerUri('quic://novosibirsk.mie.foundation:9952'), isTrue);
      expect(isValidPeerUri('wss://example.com:443/api'), isTrue);
    });

    test('rejects everything else', () {
      expect(isValidPeerUri(''), isFalse);
      expect(isValidPeerUri('yggno.de:18226'), isFalse);
      expect(isValidPeerUri('tcp://yggno.de'), isFalse);
      expect(isValidPeerUri('ftp://yggno.de:21'), isFalse);
      expect(isValidPeerUri('tcp://:18226'), isFalse);
    });
  });

  test('the bundled snapshot parses into a usable list', () {
    final file = File('assets/data/public-peers.zip');
    expect(file.existsSync(), isTrue, reason: 'run tool/update_snapshots.py');
    final peers = PeersSource.parseZip(file.readAsBytesSync());
    expect(peers.length, greaterThan(100));
    expect(peers.any((peer) => peer.country == 'russia'), isTrue);
    for (final peer in peers) {
      expect(isValidPeerUri(peer.uri), isTrue, reason: peer.uri);
    }
  });

  group('offline cache', () {
    const cached = [
      PeerCandidate(
        uri: 'tls://cached.example:443',
        host: 'cached.example',
        country: 'russia',
        city: 'Moscow',
        scheme: 'tls',
        port: 443,
      ),
      PeerCandidate(
        uri: 'tcp://cached.example:8080',
        host: 'cached.example',
        country: 'russia',
        city: 'Moscow',
        scheme: 'tcp',
        port: 8080,
      ),
    ];

    test('candidates survive a JSON round-trip', () {
      final restored = PeerCandidate.listFromJson(
        PeerCandidate.listToJson(cached),
      );
      expect(restored.length, 2);
      expect(restored.first.uri, 'tls://cached.example:443');
      expect(restored.first.city, 'Moscow');
      expect(restored.first.port, 443);
    });

    test('onePerHost keeps the best transport of a server', () {
      final peers = PeersSource.onePerHost(cached);
      expect(peers.length, 1);
      expect(peers.single.uri, 'tls://cached.example:443');
    });

    test('the stored list is used when the download fails', () async {
      final source = PeersSource(
        client: MockClient((request) async => http.Response('', 500)),
        readCache: () async => PeerCandidate.listToJson(cached),
        writeCache: (_) async {},
      );
      final result = await source.load(allowDownload: true);
      expect(result.fromNetwork, isFalse);
      expect(result.peers.single.uri, 'tls://cached.example:443');
    });

    test('a fresh download replaces the stored list', () async {
      var stored = '';
      final zip = File('assets/data/public-peers.zip').readAsBytesSync();
      final source = PeersSource(
        client: MockClient(
          (request) async => http.Response.bytes(
            zip,
            200,
            headers: const {'content-type': 'application/zip'},
          ),
        ),
        readCache: () async => stored.isEmpty ? null : stored,
        writeCache: (value) async => stored = value,
      );
      final result = await source.load(allowDownload: true);
      expect(result.fromNetwork, isTrue);
      expect(result.peers, isNotEmpty);
      expect(stored, isNotEmpty);
    });
  });
}
