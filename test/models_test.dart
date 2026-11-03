import 'package:flutter_test/flutter_test.dart';
import 'package:y_node/data/models.dart';

void main() {
  group('AppSettings', () {
    test('survives a JSON round-trip', () {
      const settings = AppSettings(
        peerCount: 4,
        autoReplace: false,
        deadPeerTimeoutSec: 90,
        healthCheckSec: 30,
        dnsMode: DnsMode.custom,
        dnsServers: [
          '308:84:68:55::',
          '215:1e33:6417:d636:c807:6985:4f4e:fda0',
        ],
        mtu: 1400,
        splitEnabled: true,
        splitApps: ['com.android.chrome'],
        energySaving: true,
        logging: false,
        probeTimeoutMs: 6000,
        probeBatch: 4,
      );
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.toJson(), settings.toJson());
    });

    test('defaults match the Kotlin side', () {
      const defaults = AppSettings();
      expect(defaults.peerCount, 3);
      expect(defaults.dnsMode, DnsMode.yggdrasil);
      expect(defaults.dnsServers, AppSettings.defaultDnsServers);
      expect(defaults.dnsServers.length, 2);
      expect(defaults.mtu, 1280);
      expect(defaults.probeBatch, 5);
      expect(defaults.probeTimeoutMs, 8000);
      expect(defaults.exitDnsServers, AppSettings.defaultExitDnsServers);
      expect(defaults.exitLocalDnsServers, isEmpty);
      expect(defaults.exitUdp, isTrue);
    });

    test('exit DNS lists survive a JSON round-trip', () {
      const settings = AppSettings(
        exitDnsServers: ['8.8.8.8', '1.1.1.1'],
        exitLocalDnsServers: ['192.168.1.1'],
      );
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.exitDnsServers, ['8.8.8.8', '1.1.1.1']);
      expect(restored.exitLocalDnsServers, ['192.168.1.1']);
    });

    test('an empty exit DNS list falls back to the defaults', () {
      final restored = AppSettings.fromJson({'exitDnsServers': <String>[]});
      expect(restored.exitDnsServers, AppSettings.defaultExitDnsServers);
    });

    test('system DNS sends no servers to the tunnel', () {
      const settings = AppSettings(dnsMode: DnsMode.system);
      expect(settings.effectiveDns, isEmpty);
    });

    test('effective DNS trims and drops blanks', () {
      const settings = AppSettings(dnsServers: [' 308:84:68:55:: ', '']);
      expect(settings.effectiveDns, ['308:84:68:55::']);
    });
  });

  group('PeerEntry', () {
    test('list JSON round-trips and drops broken entries', () {
      const peers = [
        PeerEntry(
          uri: 'tls://a.example:443',
          country: 'russia',
          city: 'Moscow',
        ),
        PeerEntry(uri: '', country: 'nowhere'),
      ];
      final json = PeerEntry.listToJson(peers);
      final restored = PeerEntry.listFromJson(json);
      expect(restored.length, 1);
      expect(restored.first.uri, 'tls://a.example:443');
      expect(restored.first.city, 'Moscow');
    });

    test('broken JSON yields an empty list', () {
      expect(PeerEntry.listFromJson('{not json'), isEmpty);
      expect(PeerEntry.listFromJson(null), isEmpty);
    });

    test('a pinned exit peer keeps its flag', () {
      const peers = [
        PeerEntry(uri: 'tls://203.0.113.10:13338?key=abcdef', pinned: true),
      ];
      final restored = PeerEntry.listFromJson(PeerEntry.listToJson(peers));
      expect(restored.single.pinned, isTrue);
      expect(restored.single.uri, 'tls://203.0.113.10:13338?key=abcdef');
    });
  });

  group('VpnSnapshot', () {
    test('reads the map the service pushes', () {
      final snapshot = VpnSnapshot.fromMap({
        'status': 'connected',
        'nodeAddress': '200:1234::1',
        'rxBytes': 1024,
        'txBytes': 2048,
        'peersUp': 2,
        'peersTotal': 3,
        'latencyMs': 14.4,
        'peers':
            '[{"uri":"tls://a.example:443","up":true,"latencyMs":14.4,'
            '"cost":7,"lastError":"refused","lastErrorUnix":1700000000}]',
      });
      expect(snapshot.isConnected, isTrue);
      expect(snapshot.nodeAddress, '200:1234::1');
      expect(snapshot.peersUp, 2);
      expect(snapshot.latencyMs, 14.4);
      expect(snapshot.peers.single.up, isTrue);
      expect(snapshot.peers.single.cost, 7);
      expect(snapshot.peers.single.lastError, 'refused');
    });

    test('an empty map is a disconnected tunnel', () {
      final snapshot = VpnSnapshot.fromMap({});
      expect(snapshot.isDisconnected, isTrue);
      expect(snapshot.peers, isEmpty);
    });

    test('a recovered peer keeps the previous error', () {
      final peer = PeerStatus.fromJson({
        'uri': 'tls://a.example:443',
        'up': true,
        'lastErrorWas': 'connection refused',
        'lastErrorWasUnix': 1700000000,
      });
      expect(peer.lastError, isEmpty);
      expect(peer.lastErrorWas, 'connection refused');
      expect(peer.lastErrorWasUnix, 1700000000);
    });
  });

  group('PeerErrorRecord', () {
    test('reads the supervisor map and drops broken entries', () {
      final map = PeerErrorRecord.mapFromJson(
        '{"tls://a.example:443":{"message":"refused","lastSeenUnix":42},'
        '"tls://b.example:443":{"message":""}}',
      );
      expect(map.length, 1);
      expect(map['tls://a.example:443']?.message, 'refused');
      expect(map['tls://a.example:443']?.lastSeenUnix, 42);
      expect(PeerErrorRecord.mapFromJson('not json'), isEmpty);
      expect(PeerErrorRecord.mapFromJson(null), isEmpty);
    });
  });

  group('Resource', () {
    test('list JSON round-trips', () {
      const items = [
        Resource(id: 'a', title: 'A', url: 'http://[200::1]/', builtIn: true),
      ];
      final restored = Resource.listFromJson(Resource.listToJson(items));
      expect(restored.single.title, 'A');
      expect(restored.single.builtIn, isTrue);
    });
  });

  test('decodeIdentity rejects an empty payload', () {
    expect(Identity.fromJson(const {}).isValid, isFalse);
    expect(
      Identity.fromJson(const {'privateKey': 'abc', 'address': '200::1'})
          .isValid,
      isTrue,
    );
  });
}
