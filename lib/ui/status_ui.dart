import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/models.dart';
import '../data/probe_service.dart';
import '../l10n/strings.dart';

/// Maps the tunnel state to the label and colour the UI shows.
class VpnStatusUi {
  const VpnStatusUi._();

  static String label(VpnSnapshot snapshot, L10n l10n) {
    return switch (snapshot.status) {
      'connected' => l10n.t('statusConnected'),
      'connecting' => l10n.t('statusConnecting'),
      'reconnecting' => l10n.t('statusReconnecting'),
      'disconnecting' => l10n.t('statusDisconnecting'),
      _ => l10n.t('statusDisconnected'),
    };
  }

  static Color color(VpnSnapshot snapshot) {
    return switch (snapshot.status) {
      'connected' => AppColors.online,
      'connecting' || 'reconnecting' => AppColors.pending,
      _ => AppColors.offline,
    };
  }

  /// The state of one peer, from the point of view of the tunnel.
  ///
  /// `connected` is a live link the node holds right now; `online` is a peer
  /// that answered a probe but is not carrying traffic at the moment; `waiting`
  /// means nothing is known yet (a fresh entry or a handshake in progress);
  /// `offline` is reserved for a peer that is known to be down.
  static PeerState peerState({
    required bool up,
    required double latencyMs,
    bool knownDead = false,
  }) {
    if (up) return PeerState.connected;
    if (knownDead) return PeerState.offline;
    if (latencyMs > 0) return PeerState.online;
    return PeerState.waiting;
  }

  /// A stable colour per peer state: green for a live link, teal for a
  /// reachable node, amber while nothing is known, red only for a dead one.
  static Color peerColorOf(PeerState state) {
    return switch (state) {
      PeerState.connected => AppColors.online,
      PeerState.online => AppColors.teal,
      PeerState.waiting => AppColors.pending,
      PeerState.offline => AppColors.offline,
    };
  }

  static String peerLabel(PeerState state, L10n l10n) {
    return switch (state) {
      PeerState.connected => l10n.t('peerConnected'),
      PeerState.online => l10n.t('peerOnline'),
      PeerState.waiting => l10n.t('peerWaiting'),
      PeerState.offline => l10n.t('peerOffline'),
    };
  }

  /// The line that describes what the peer probe is doing right now.
  static String probePhase(ProbeProgress? progress, L10n l10n) {
    if (progress == null) return l10n.t('probing');
    return switch (progress.phase) {
      'preparing' => l10n.t('probePreparing'),
      'downloading' => l10n.t('probeDownloading'),
      'tcp' => l10n.t('probeTcp'),
      'ygg' => l10n.t('probeYgg'),
      _ => l10n.t('probeRanking'),
    };
  }
}

enum PeerState { connected, online, waiting, offline }

/// The states of the Exit node card.
enum ExitUiState {
  off,
  noProfile,
  connecting,
  online,
  degraded,
  fallback,
  denied,
  unreachable,
}

/// Maps the exit configuration and the measured health to the card.
class ExitStatusUi {
  const ExitStatusUi._();

  static ExitUiState stateOf({
    required bool enabled,
    required int profileCount,
    required VpnSnapshot snapshot,
    required ExitStatus status,
    required bool fallbackDirect,
  }) {
    if (!enabled) return ExitUiState.off;
    if (profileCount == 0) return ExitUiState.noProfile;
    if (snapshot.isBusy) return ExitUiState.connecting;
    switch (status.state) {
      case 'online':
        final active = status.active;
        if (active != null &&
            active.state != 'online' &&
            status.profiles.any((profile) => profile.state == 'online')) {
          return ExitUiState.degraded;
        }
        return ExitUiState.online;
      case 'denied':
        // An exhausted traffic quota is reported by the SOCKS reply as "not
        // allowed". The exit still accepts the device, it only refuses new
        // connections until the cap resets, so the card must not flip to
        // "Not allowed" while the quota row already explains the refusal.
        if (status.active?.quotaExhausted ?? false) return ExitUiState.online;
        return ExitUiState.denied;
      case 'unreachable':
        return fallbackDirect ? ExitUiState.fallback : ExitUiState.unreachable;
      case 'unknown':
        if (!snapshot.isConnected) return ExitUiState.off;
        // The tunnel is up but no public connection has exercised the exit
        // yet. Calling it a fallback would be a lie: the node may be fine.
        return ExitUiState.connecting;
      default:
        return ExitUiState.off;
    }
  }

  static String label(ExitUiState state, L10n l10n) => switch (state) {
    ExitUiState.off => l10n.t('exitStateOff'),
    ExitUiState.noProfile => l10n.t('exitStateNoProfile'),
    ExitUiState.connecting => l10n.t('exitStateConnecting'),
    ExitUiState.online => l10n.t('exitStateOnline'),
    ExitUiState.degraded => l10n.t('exitStateDegraded'),
    ExitUiState.fallback => l10n.t('exitStateFallback'),
    ExitUiState.denied => l10n.t('exitStateDenied'),
    ExitUiState.unreachable => l10n.t('exitStateUnreachable'),
  };

  static Color color(ExitUiState state) => switch (state) {
    ExitUiState.online => AppColors.online,
    ExitUiState.connecting => AppColors.pending,
    ExitUiState.degraded || ExitUiState.fallback => AppColors.pending,
    ExitUiState.denied || ExitUiState.unreachable => AppColors.offline,
    _ => AppColors.offline,
  };
}
