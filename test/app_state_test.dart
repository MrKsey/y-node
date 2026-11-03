import 'package:flutter_test/flutter_test.dart';
import 'package:y_node/data/models.dart';
import 'package:y_node/state/app_state.dart';

/// The service pushes a snapshot every second. Only the byte counters move on
/// most of those ticks, and rebuilding every tab for them is what made the
/// scrolling stutter. These tests pin the decision that separates the two.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const peer = PeerStatus(uri: 'tls://peer.example:1', up: true);

  VpnSnapshot snapshot({
    int rx = 0,
    int tx = 0,
    int peersUp = 1,
    List<PeerStatus> peers = const [peer],
  }) => VpnSnapshot(
    status: 'disconnected',
    nodeAddress: '200::1',
    rxBytes: rx,
    txBytes: tx,
    peersUp: peersUp,
    peersTotal: peers.length,
    peers: peers,
  );

  test('a tick that only moves the byte counters does not notify', () {
    final state = AppState();
    var notifications = 0;
    state.addListener(() => notifications++);

    state.applySnapshotForTest(snapshot());
    expect(notifications, 1);

    state.applySnapshotForTest(snapshot(rx: 4096, tx: 1024));
    expect(notifications, 1, reason: 'traffic must not rebuild the tabs');
    expect(state.traffic.value, const TrafficCounters(rx: 4096, tx: 1024));
  });

  test('a real change still notifies even when the counters also move', () {
    final state = AppState();
    var notifications = 0;
    state.addListener(() => notifications++);

    state.applySnapshotForTest(snapshot());
    state.applySnapshotForTest(snapshot(rx: 4096, tx: 1024, peersUp: 0));

    expect(notifications, 2);
    expect(state.traffic.value, const TrafficCounters(rx: 4096, tx: 1024));
  });

  test('the URI map is cached until the snapshot changes', () {
    final state = AppState();
    state.applySnapshotForTest(snapshot());

    final first = state.statusByUri;
    expect(identical(state.statusByUri, first), isTrue);
    expect(first[peer.uri]?.up, isTrue);

    state.applySnapshotForTest(
      snapshot(
        peers: const [PeerStatus(uri: 'tls://peer.example:1', up: false)],
      ),
    );
    expect(identical(state.statusByUri, first), isFalse);
    expect(state.statusByUri[peer.uri]?.up, isFalse);
  });

  test('replacing the peer list invalidates the URI map', () {
    final state = AppState();
    state.applySnapshotForTest(snapshot());
    final first = state.statusByUri;

    state.peers = const [PeerEntry(uri: 'tls://other.example:1')];

    expect(identical(state.statusByUri, first), isFalse);
    // The live status still comes from the snapshot: a configured peer without
    // a link simply has no row of its own.
    expect(state.statusByUri[peer.uri]?.up, isTrue);
    expect(state.statusByUri['tls://other.example:1'], isNull);
  });

  // Android reads the VPN allow list only when the interface is created, so the
  // Apps tab has to tell the user when the running tunnel differs from the
  // settings; the order of the packages is not a change.
  test('split changes are pending until the tunnel is restarted', () {
    final state = AppState();
    expect(state.splitChangesPending, isFalse);

    state.settings = state.settings.copyWith(
      splitEnabled: true,
      splitApps: const ['com.android.chrome', 'org.telegram.messenger'],
    );
    expect(state.splitChangesPending, isTrue);

    state.appliedSplitEnabled = true;
    state.appliedSplitApps = const [
      'org.telegram.messenger',
      'com.android.chrome',
    ];
    expect(state.splitChangesPending, isFalse, reason: 'order must not matter');

    state.appliedSplitApps = const ['com.android.chrome'];
    expect(state.splitChangesPending, isTrue, reason: 'app removed');

    state.appliedSplitApps = const [
      'com.android.chrome',
      'org.telegram.messenger',
      'com.whatsapp',
    ];
    expect(state.splitChangesPending, isTrue, reason: 'app added');

    // Turning the mode off is a change of its own, even with a matching list.
    state.settings = state.settings.copyWith(splitEnabled: false);
    expect(state.splitChangesPending, isTrue);

    state.appliedSplitEnabled = false;
    expect(state.splitChangesPending, isFalse);
  });

  // The link carries the invite, not the API token the exit issued to this
  // node: importing the same server again must keep the token, otherwise the
  // bridge would have to fetch a new one on the next poll.
  test('re-importing an exit profile keeps the issued API token', () async {
    final state = AppState();
    await state.addExitProfile(
      const ExitProfile(
        id: '200::1:1080',
        name: 'first',
        address: '200::1',
        invite: 'invite-1',
        token: 'api-token',
      ),
    );
    await state.addExitProfile(
      const ExitProfile(
        id: '200::1:1080',
        name: 'renamed',
        address: '200::1',
        invite: 'invite-2',
      ),
    );

    final profile = state.settings.exitProfiles.single;
    expect(profile.name, 'renamed');
    expect(profile.invite, 'invite-2');
    expect(profile.token, 'api-token');
  });
}
