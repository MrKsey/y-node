import 'dart:io';

import 'models.dart';
import 'peers_source.dart';

/// A parsed `yggnode://exit` link from the server QR code.
class ExitInvite {
  const ExitInvite({required this.profile, required this.invite});

  final ExitProfile profile;
  final String invite;

  /// Parses the link printed by `ygg-exit invite`:
  ///
  ///     yggnode://exit?v=1&a=<address>&p=1080&api=1081&n=<name>&i=<token>
  ///                 &peer=wss://<host>:<port>/ygg?key=<public key>
  ///
  /// Returns null for anything else, including an address outside 200::/7.
  /// The `peer` part is optional: an outbound-only server does not advertise
  /// one, and the exit is then reached through the rest of the mesh.
  static ExitInvite? parse(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'yggnode' || uri.host != 'exit') {
      return null;
    }
    final query = uri.queryParameters;
    final address = (query['a'] ?? '').trim();
    if (!isYggdrasilAddress(address)) return null;
    final invite = (query['i'] ?? '').trim();
    if (invite.isEmpty) return null;
    final socks = int.tryParse(query['p'] ?? '') ?? 1080;
    var api = int.tryParse(query['api'] ?? '') ?? 1081;
    // api=0 means the server serves /v1/... on the SOCKS5 listener.
    if (api == 0) api = socks;
    if (socks < 1 || socks > 65535 || api < 1 || api > 65535) return null;
    final name = (query['n'] ?? '').trim();
    final peer = (query['peer'] ?? '').trim();
    return ExitInvite(
      profile: ExitProfile(
        id: '$address:$socks',
        name: name.isEmpty ? address : name,
        address: address,
        socksPort: socks,
        apiPort: api,
        invite: invite,
        peer: isUsablePeer(peer) ? peer : '',
      ),
      invite: invite,
    );
  }

  /// Parses a link pasted by hand.
  ///
  /// Chat apps and terminals wrap long links, so line breaks and tabs inside
  /// the value are dropped before parsing: a link that arrived as two lines
  /// still works. Ordinary spaces are kept, because a value such as a node
  /// name may contain them.
  static ExitInvite? parsePasted(String raw) {
    final value = raw.replaceAll(RegExp(r'[\r\n	]+'), '').trim();
    return parse(value);
  }

  /// True when [value] can be dialled as a peer of the local node. A peer
  /// inside 200::/7 is rejected by the Go bridge: Yggdrasil peers are reached
  /// over a real transport, not over the tunnel itself.
  static bool isUsablePeer(String value) {
    if (!isValidPeerUri(value)) return false;
    final host = Uri.tryParse(value)?.host ?? '';
    return !isYggdrasilAddress(host);
  }

  /// True when [value] is an IPv6 address inside Yggdrasil's 200::/7.
  static bool isYggdrasilAddress(String value) {
    final address = InternetAddress.tryParse(value.trim());
    if (address == null || address.type != InternetAddressType.IPv6) {
      return false;
    }
    final raw = address.rawAddress;
    if (raw.length != 16) return false;
    return (raw[0] & 0xFE) == 0x02;
  }
}
