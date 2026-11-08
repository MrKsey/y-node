import 'package:flutter_test/flutter_test.dart';
import 'package:y_node/data/exit_link.dart';
import 'package:y_node/data/models.dart';
import 'package:y_node/l10n/strings.dart';
import 'package:y_node/state/app_state.dart';
import 'package:y_node/ui/status_ui.dart';

void main() {
  test('an exit invite link is parsed', () {
    final invite = ExitInvite.parse(
      'yggnode://exit?v=1&a=202:24ae:c219:8a4a:de94:eae2:b97e:ac87'
      '&p=1080&api=1081&n=Test%20exit&i=token123',
    );
    expect(invite, isNotNull);
    expect(invite!.profile.address, '202:24ae:c219:8a4a:de94:eae2:b97e:ac87');
    expect(invite.profile.name, 'Test exit');
    expect(invite.profile.socksPort, 1080);
    expect(invite.profile.apiPort, 1081);
    expect(invite.invite, 'token123');
  });

  test('an invite outside Yggdrasil is rejected', () {
    expect(ExitInvite.parse('yggnode://exit?a=10.0.0.1&i=token'), isNull);
    expect(
      ExitInvite.parse('yggnode://exit?a=2606:4700:4700::1111&i=token'),
      isNull,
    );
  });

  test('a link without an invite is a plain SOCKS5 profile', () {
    // This is the link an exit shows for a client that is already allowed,
    // for example after the profile was deleted in the app.
    final invite = ExitInvite.parse(
      'yggnode://exit?v=1&a=202:24ae:c219:8a4a:de94:eae2:b97e:ac87&p=1080',
    );
    expect(invite, isNotNull);
    expect(invite!.invite, isEmpty);
    expect(invite.profile.socksOnly, isTrue);
    expect(invite.profile.socksPort, 1080);
    expect(invite.profile.apiPort, 1081);
  });

  test('a profile with a token or an invite is not SOCKS5 only', () {
    const tokenOnly = ExitProfile(
      id: 'a',
      name: 'a',
      address: '202::1',
      token: 'api-token',
    );
    expect(tokenOnly.socksOnly, isFalse);
    const inviteOnly = ExitProfile(
      id: 'b',
      name: 'b',
      address: '202::2',
      invite: 'invite',
    );
    expect(inviteOnly.socksOnly, isFalse);
  });

  test('a pasted invite survives the line breaks of a chat app', () {
    final invite = ExitInvite.parsePasted(
      '  yggnode://exit?v=1&a=202:24ae:c219:8a4a:de94:eae2:b97e:ac87\n'
      '&p=1080&api=1081&n=Test exit&i=token123\n'
      '&peer=tls%3A%2F%2F203.0.113.10%3A13338%3Fkey%3Dabcdef  ',
    );
    expect(invite, isNotNull);
    expect(invite!.profile.address, '202:24ae:c219:8a4a:de94:eae2:b97e:ac87');
    expect(invite.profile.name, 'Test exit');
    expect(invite.invite, 'token123');
    expect(invite.profile.peer, 'tls://203.0.113.10:13338?key=abcdef');
  });

  test('a pasted value that is not an invite is rejected', () {
    expect(ExitInvite.parsePasted('https://example.net/'), isNull);
    expect(ExitInvite.parsePasted(''), isNull);
  });

  test('an invite carries the pinned peer of the exit node', () {
    final invite = ExitInvite.parse(
      'yggnode://exit?v=1&a=202:24ae:c219:8a4a:de94:eae2:b97e:ac87'
      '&p=1080&api=1081&n=Test%20exit&i=token123'
      '&peer=tls%3A%2F%2F203.0.113.10%3A13338%3Fkey%3Dabcdef',
    );
    expect(invite, isNotNull);
    expect(invite!.profile.peer, 'tls://203.0.113.10:13338?key=abcdef');
  });

  test('an invalid peer in an invite is ignored', () {
    final invite = ExitInvite.parse(
      'yggnode://exit?a=202:24ae:c219:8a4a:de94:eae2:b97e:ac87'
      '&i=token123&peer=not-a-peer',
    );
    expect(invite, isNotNull);
    expect(invite!.profile.peer, isEmpty);
  });

  test('a peer key drops the query the node does not report', () {
    expect(
      peerKeyOf('tls://160.20.158.195:13338?key=abcdef'),
      'tls://160.20.158.195:13338',
    );
    expect(
      peerKeyOf('tls://[200::1]:13338?key=abcdef'),
      'tls://[200::1]:13338',
    );
    expect(
      peerKeyOf('wss://example.net:443/api/v2/socket?key=abcdef'),
      'wss://example.net:443/api/v2/socket',
    );
    expect(peerKeyOf('tls://example.net:13338'), 'tls://example.net:13338');
    expect(peerKeyOf('not-a-peer'), 'not-a-peer');
  });

  test('a pinned exit peer matches its live link without the key', () {
    const configured = 'tls://160.20.158.195:13338?key=abcdef';
    const reported = 'tls://160.20.158.195:13338';
    expect(peerKeyOf(configured), peerKeyOf(reported));
  });

  test('exit profiles survive a JSON round-trip', () {
    const profile = ExitProfile(
      id: '202::1:1080',
      name: 'Home',
      address: '202::1',
      invite: 'abc',
      peer: 'tls://203.0.113.10:13338?key=abcdef',
      token: 'api-token',
    );
    final parsed = ExitProfile.listFromJson(ExitProfile.listToJson([profile]));
    expect(parsed, hasLength(1));
    expect(parsed.first.id, profile.id);
    expect(parsed.first.invite, 'abc');
    expect(parsed.first.peer, 'tls://203.0.113.10:13338?key=abcdef');
    expect(parsed.first.token, 'api-token');
  });

  test('a profile without a token stays compatible', () {
    const profile = ExitProfile(
      id: '202::1:1080',
      name: 'Home',
      address: '202::1',
    );
    final parsed = ExitProfile.listFromJson(ExitProfile.listToJson([profile]));
    expect(parsed.single.token, isEmpty);
  });

  test('registration carries the API token', () {
    final result = ExitRegistration.tryParse(
      '{"ok":true,"allowlisted":true,"registered":true,"exitName":"Fin-exit",'
      '"token":"api-token"}',
    );
    expect(result, isNotNull);
    expect(result!.ok, isTrue);
    expect(result.token, 'api-token');
  });

  test('a registration from a pre-1.3 exit has no token', () {
    final result = ExitRegistration.tryParse(
      '{"ok":true,"allowlisted":true,"registered":true,"exitName":"Old"}',
    );
    expect(result!.token, isEmpty);
  });

  test('a profile status reports the limited API answer', () {
    final status = ExitProfileStatus.fromJson({
      'id': 'a',
      'authenticated': false,
    });
    expect(status.authenticated, isFalse);
    expect(status.limited, isTrue);
    // A pre-1.3 exit has no field at all: it always sends the full status.
    final old = ExitProfileStatus.fromJson({'id': 'b'});
    expect(old.authenticated, isTrue);
    expect(old.limited, isFalse);
  });

  test('a learned token is read from the profile status', () {
    final status = ExitProfileStatus.fromJson({
      'id': 'a',
      'authenticated': true,
      'token': 'learned',
    });
    expect(status.token, 'learned');
  });

  test('AppSettings keeps the exit configuration', () {
    const settings = AppSettings(
      exitEnabled: true,
      exitProfiles: [
        ExitProfile(id: '202::1:1080', name: 'a', address: '202::1'),
        ExitProfile(id: '202::2:1080', name: 'b', address: '202::2'),
      ],
      exitActiveId: '202::2:1080',
      exitFallbackDirect: false,
      exitLocalDns: false,
      exitUdp: false,
    );
    final parsed = AppSettings.fromJson(settings.toJson());
    expect(parsed.exitEnabled, isTrue);
    expect(parsed.exitProfiles, hasLength(2));
    expect(parsed.exitActiveId, '202::2:1080');
    expect(parsed.exitFallbackDirect, isFalse);
    expect(parsed.exitLocalDns, isFalse);
    expect(parsed.exitUdp, isFalse);
    expect(parsed.exitActiveProfile?.name, 'b');
  });

  test('the exit status is read from the bridge JSON', () {
    final status = ExitStatus.tryParse(
      '{"enabled":true,"state":"online","activeId":"202::1:1080",'
      '"profiles":[{"id":"202::1:1080","name":"a","state":"online",'
      '"latencyMs":12.5}],'
      '"udp":{"enabled":true,"state":"online","profileId":"202::1:1080",'
      '"profileName":"a",'
      '"datagramsIn":3,"datagramsOut":2,"bytesIn":120,"bytesOut":80}}',
    );
    expect(status, isNotNull);
    expect(status!.state, 'online');
    expect(status.active?.latencyMs, 12.5);
    expect(status.udp.enabled, isTrue);
    expect(status.udp.isOnline, isTrue);
    expect(status.udp.profileId, '202::1:1080');
    expect(status.udp.datagramsIn, 3);
    expect(status.udp.bytesOut, 80);
  });

  test('an exit status without a UDP block stays compatible', () {
    final status = ExitStatus.tryParse('{"enabled":true,"state":"online"}');
    expect(status, isNotNull);
    expect(status!.udp.enabled, isFalse);
    expect(status.udp.state, 'off');
  });

  test('the exit status carries the load and refusal counters', () {
    final status = ExitStatus.tryParse(
      '{"enabled":true,"state":"online","activeId":"202::1:1080",'
      '"profiles":[{"id":"202::1:1080","name":"a","state":"online",'
      '"connections":27,"refused":3,"maxConns":128,'
      '"udpAssociations":1,"maxUdpAssociations":64}]}',
    );
    expect(status, isNotNull);
    final active = status!.active;
    expect(active, isNotNull);
    expect(active!.connections, 27);
    expect(active.refused, 3);
    expect(active.maxConns, 128);
    expect(active.udpAssociations, 1);
    expect(active.maxUdpAssociations, 64);
    expect(active.hitLimit, isTrue);
  });

  test('an exit status without load counters stays compatible', () {
    final status = ExitStatus.tryParse(
      '{"enabled":true,"activeId":"202::1:1080",'
      '"profiles":[{"id":"202::1:1080","state":"online"}]}',
    );
    final active = status!.active!;
    expect(active.refused, 0);
    expect(active.maxConns, 0);
    expect(active.hitLimit, isFalse);
    expect(active.quota, isNull);
  });

  test('the exit status carries its own IPv6 state', () {
    final status = ExitStatus.tryParse(
      '{"enabled":true,"activeId":"a","profiles":[{"id":"a",'
      '"state":"online","ipv6Available":false,"ipv6State":"broken"}]}',
    );
    final active = status!.active!;
    expect(active.ipv6Available, isFalse);
    expect(active.ipv6Broken, isTrue);
    expect(active.ipv6Missing, isFalse);
    // An old exit does not send the field: the app must not claim a state it
    // does not know.
    final old = ExitStatus.tryParse(
      '{"enabled":true,"activeId":"a","profiles":[{"id":"a"}]}',
    );
    expect(old!.active!.ipv6Available, isNull);
    expect(old.active!.ipv6Broken, isFalse);
  });

  test('the exit status carries the quota and separates its refusals', () {
    final status = ExitStatus.tryParse(
      '{"enabled":true,"state":"online","activeId":"202::1:1080",'
      '"profiles":[{"id":"202::1:1080","name":"a","state":"online",'
      '"connections":2,"refused":5,"quotaRefused":4,"maxConns":128,'
      '"quota":{"monthlyBytes":100000000000,"dailyBytes":5000000000,'
      '"downKbps":20000,"upKbps":5000,"dayUsed":5000000000,'
      '"monthUsed":12000000000,"exhausted":true,'
      '"reason":"daily quota exhausted"}}]}',
    );
    final active = status!.active!;
    expect(active.quota, isNotNull);
    expect(active.quota!.monthlyBytes, 100000000000);
    expect(active.quota!.dailyBytes, 5000000000);
    expect(active.quota!.downKbps, 20000);
    expect(active.quota!.dayUsed, 5000000000);
    expect(active.quota!.exhausted, isTrue);
    expect(active.quotaRefused, 4);
    expect(active.limitRefused, 1);
    expect(active.hitLimit, isTrue);
    expect(active.quotaExhausted, isTrue);
  });

  test('quota refusals alone are not a connection limit', () {
    final status = ExitStatus.tryParse(
      '{"enabled":true,"activeId":"202::1:1080",'
      '"profiles":[{"id":"202::1:1080","state":"online",'
      '"refused":3,"quotaRefused":3,'
      '"quota":{"monthlyBytes":1000000000,"monthUsed":1000000000,'
      '"exhausted":true,"reason":"monthly quota exhausted"}}]}',
    );
    final active = status!.active!;
    expect(active.hitLimit, isFalse);
    expect(active.limitRefused, 0);
    expect(active.quotaExhausted, isTrue);
  });

  test('the exit status reports an operator suspension', () {
    final status = ExitStatus.tryParse(
      '{"enabled":true,"state":"online","activeId":"202::1:1080",'
      '"profiles":[{"id":"202::1:1080","name":"a","state":"online",'
      '"suspended":true,"allowlisted":true}]}',
    );
    expect(status, isNotNull);
    expect(status!.active?.suspended, isTrue);
    // An old exit does not send the field at all.
    final old = ExitStatus.tryParse(
      '{"enabled":true,"activeId":"a","profiles":[{"id":"a"}]}',
    );
    expect(old!.active?.suspended, isFalse);
  });

  test('a suspended refusal is not a connection limit', () {
    // The exit refused the client because the operator suspended it, not
    // because a connection limit was reached. The server counts that part
    // separately and sends limitRefused: 0.
    final status = ExitStatus.tryParse(
      '{"enabled":true,"state":"online","activeId":"202::1:1080",'
      '"profiles":[{"id":"202::1:1080","state":"online",'
      '"refused":2,"suspendedRefused":2,"limitRefused":0}]}',
    );
    final active = status!.active!;
    expect(active.refused, 2);
    expect(active.limitRefused, 0);
    expect(active.hitLimit, isFalse);
  });

  test('a reported limit refusal wins over the old subtraction', () {
    final status = ExitStatus.tryParse(
      '{"enabled":true,"state":"online","activeId":"202::1:1080",'
      '"profiles":[{"id":"202::1:1080","state":"online",'
      '"refused":5,"quotaRefused":4,"suspendedRefused":0,'
      '"limitRefused":1,"maxConns":256}]}',
    );
    final active = status!.active!;
    expect(active.limitRefused, 1);
    expect(active.hitLimit, isTrue);
  });

  test('the UDP check result is read from the bridge JSON', () {
    final result = UdpProbeResult.tryParse(
      '{"ok":true,"state":"ok","profile":"Fin-exit",'
      '"profileId":"202::1:1080",'
      '"udp":{"ok":true,"latencyMs":41.5,"target":"cloudflare.com",'
      '"server":"1.1.1.1:53"},'
      '"quic":{"ok":true,"latencyMs":118.2,'
      '"target":"104.18.26.14:443","version":"1"},'
      '"datagramsIn":2,"datagramsOut":3,"durationMs":220}',
    );
    expect(result, isNotNull);
    expect(result!.ok, isTrue);
    expect(result.profile, 'Fin-exit');
    expect(result.profileId, '202::1:1080');
    expect(result.udp.ok, isTrue);
    expect(result.udp.latencyMs, 41.5);
    expect(result.quic.version, '1');
    expect(result.datagramsOut, 3);
  });

  test('a failed UDP check keeps the error of the failing stage', () {
    final result = UdpProbeResult.tryParse(
      '{"ok":false,"state":"udp_failed","error":"no answer",'
      '"udp":{"ok":false,"error":"no answer"},'
      '"quic":{"ok":false,"error":"skipped"}}',
    );
    expect(result, isNotNull);
    expect(result!.state, 'udp_failed');
    expect(result.udp.ok, isFalse);
    expect(result.udp.error, 'no answer');
    expect(result.quic.error, 'skipped');
  });

  test('the UDP counters are compact enough not to wrap', () {
    const l10n = L10n();
    final text = l10n.tf('exitUdpTraffic', [
      '28600',
      '30.1 MB',
      '6162',
      '1.5 MB',
    ]);
    // The long wording "28600 (30.1 MB) datagrams in · …" wrapped in the
    // middle of "out" on a 360 dp screen; the arrows keep the line short.
    expect(text.contains('datagram'), isFalse);
    expect(text, startsWith('↓'));
    expect(text.contains('↑'), isTrue);
    expect(text, contains('30.1 MB'));
    // The full wording is kept for the screen reader.
    final spoken = l10n.tf('exitUdpTrafficFull', ['1', '1 B', '2', '2 B']);
    expect(spoken, contains('datagrams in'));
    expect(spoken, contains('datagrams out'));
  });

  test('the IPv6 check result is read from the bridge JSON', () {
    final result = Ipv6ProbeResult.tryParse(
      '{"ok":true,"state":"ok","profile":"Fin-exit",'
      '"profileId":"202::1:1080",'
      '"tcp":{"ok":true,"latencyMs":92.4,'
      '"target":"[2606:4700:4700::1111]:443",'
      '"address":"2a01:ecc0:5000:329::2"},'
      '"udp":{"ok":true,"latencyMs":31.0,'
      '"target":"[2606:4700:4700::1111]:53"},'
      '"durationMs":180}',
    );
    expect(result, isNotNull);
    expect(result!.ok, isTrue);
    expect(result.state, 'ok');
    expect(result.profile, 'Fin-exit');
    expect(result.profileId, '202::1:1080');
    expect(result.tcp.ok, isTrue);
    expect(result.tcp.address, '2a01:ecc0:5000:329::2');
    expect(result.udp.ok, isTrue);
  });

  test('a failed IPv6 check keeps the failing stage and the skipped one', () {
    final result = Ipv6ProbeResult.tryParse(
      '{"ok":false,"state":"tcp_failed","error":"the destination network is '
      'unreachable","tcp":{"ok":false,"error":"the destination network is '
      'unreachable"},"udp":{"skipped":true,"error":"skipped: TCP over IPv6 '
      'did not work"}}',
    );
    expect(result, isNotNull);
    expect(result!.ok, isFalse);
    expect(result.state, 'tcp_failed');
    expect(result.tcp.ok, isFalse);
    expect(result.udp.skipped, isTrue);
    expect(result.udp.error, contains('skipped'));
  });

  test('the card state follows the measured exit health', () {
    const connected = VpnSnapshot(status: 'connected');
    const disabled = ExitStatus();
    expect(
      ExitStatusUi.stateOf(
        enabled: false,
        profileCount: 0,
        snapshot: connected,
        status: disabled,
        fallbackDirect: true,
      ),
      ExitUiState.off,
    );
    expect(
      ExitStatusUi.stateOf(
        enabled: true,
        profileCount: 0,
        snapshot: connected,
        status: disabled,
        fallbackDirect: true,
      ),
      ExitUiState.noProfile,
    );
    expect(
      ExitStatusUi.stateOf(
        enabled: true,
        profileCount: 1,
        snapshot: connected,
        status: const ExitStatus(
          enabled: true,
          state: 'online',
          profiles: [ExitProfileStatus(id: 'a', state: 'online')],
        ),
        fallbackDirect: true,
      ),
      ExitUiState.online,
    );
    expect(
      ExitStatusUi.stateOf(
        enabled: true,
        profileCount: 1,
        snapshot: connected,
        status: const ExitStatus(enabled: true, state: 'unreachable'),
        fallbackDirect: true,
      ),
      ExitUiState.fallback,
    );
    expect(
      ExitStatusUi.stateOf(
        enabled: true,
        profileCount: 1,
        snapshot: connected,
        status: const ExitStatus(enabled: true, state: 'denied'),
        fallbackDirect: true,
      ),
      ExitUiState.denied,
    );
    expect(ExitStatusUi.label(ExitUiState.online, const L10n()), 'Online');
  });

  group('the exit switch follows the profile list', () {
    const first = ExitProfile(id: 'a', name: 'a', address: '200::1');
    const second = ExitProfile(id: 'b', name: 'b', address: '200::2');

    test('adding the first node turns the exit on', () {
      expect(AppState.exitEnabledAfter(const [], const [first], false), isTrue);
    });

    test('adding a node to a non-empty list keeps the switch as it is', () {
      expect(
        AppState.exitEnabledAfter(const [first], const [first, second], true),
        isTrue,
      );
      expect(
        AppState.exitEnabledAfter(const [first], const [first, second], false),
        isFalse,
        reason: 'a user who turned the exit off must stay off',
      );
    });

    test('removing the last node turns the exit off', () {
      expect(AppState.exitEnabledAfter(const [first], const [], true), isFalse);
    });

    test('removing one of several nodes keeps the switch', () {
      expect(
        AppState.exitEnabledAfter(const [first, second], const [second], true),
        isTrue,
      );
    });
  });
}
