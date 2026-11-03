import 'package:flutter_test/flutter_test.dart';
import 'package:y_node/core/theme.dart';
import 'package:y_node/ui/status_ui.dart';

void main() {
  group('peer states', () {
    test('a live link is connected, not merely online', () {
      expect(
        VpnStatusUi.peerState(up: true, latencyMs: 0),
        PeerState.connected,
      );
      expect(VpnStatusUi.peerColorOf(PeerState.connected), AppColors.online);
    });

    test('a probed peer is online, a fresh one is waiting', () {
      expect(VpnStatusUi.peerState(up: false, latencyMs: 42), PeerState.online);
      expect(VpnStatusUi.peerState(up: false, latencyMs: 0), PeerState.waiting);
    });

    test('red is reserved for a peer known to be dead', () {
      expect(
        VpnStatusUi.peerState(up: false, latencyMs: 0, knownDead: true),
        PeerState.offline,
      );
      expect(VpnStatusUi.peerColorOf(PeerState.offline), AppColors.offline);
      expect(
        VpnStatusUi.peerColorOf(PeerState.online),
        isNot(AppColors.offline),
      );
      expect(
        VpnStatusUi.peerColorOf(PeerState.waiting),
        isNot(AppColors.offline),
      );
    });
  });
}
