import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../data/geo.dart';
import '../data/models.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'exit_card.dart';
import 'ip_balloon.dart';
import 'status_ui.dart';
import 'widgets.dart';

/// The tunnel screen: the state of the link, its numbers and the peers carrying
/// it.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.onOpenPeers});

  final VoidCallback onOpenPeers;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = state.l10n;
    final snapshot = state.snapshot;
    final statusColor = VpnStatusUi.color(snapshot);
    final connected = snapshot.isConnected;
    final subnet = snapshot.subnet.isNotEmpty
        ? snapshot.subnet
        : (state.identity?.subnet ?? '');
    // The exit link is not one of the peers the user configured, so the
    // counters on this screen only describe the public ones.
    final publicPeers = state.publicPeerStats;
    final exitName = (state.exitStatus.active?.name.isNotEmpty ?? false)
        ? state.exitStatus.active!.name
        : (state.settings.exitActiveProfile?.title ?? '');
    PeerEntry? exitPeer;
    for (final peer in state.peers) {
      if (peer.pinned) {
        exitPeer = peer;
        break;
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.t('appName')),
            Text(
              l10n.t('appTagline'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: const [_BatteryBadge()],
      ),
      body: RefreshIndicator(
        onRefresh: state.refreshFromStore,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _Hero(
              statusColor: statusColor,
              statusLabel: VpnStatusUi.label(snapshot, l10n),
              connected: connected,
              busy: snapshot.isBusy || state.connecting,
              establishing: state.establishing,
              stageText: _stageText(l10n, state),
              peersUp: publicPeers.up,
              peersTotal: publicPeers.total,
              connectedAt: snapshot.connectedAt,
              onToggle: state.toggle,
              exitName: exitName,
              exitCountry: exitPeer?.country ?? '',
              exitOn: state.settings.exitActive,
              exitInUse: state.exitInUse,
              onIpRequest: (anchor, viaExit) => showIpBalloon(
                context: context,
                anchorContext: anchor,
                viaExit: viaExit,
                load: () => state.publicIp(viaExit: viaExit),
              ),
              errorText: state.lastError != null
                  ? l10n.t(state.lastError!)
                  : snapshot.error,
            ),
            const SizedBox(height: 16),
            _StatsCard(
              latencyMs: snapshot.latencyMs,
              traffic: state.traffic,
              healthCheckSec: state.settings.healthCheckSec,
              onLatencyInfo: () => _showLatencyInfo(
                context,
                l10n,
                state.settings.healthCheckSec,
              ),
            ),
            const SizedBox(height: 8),
            SectionCard(
              title: l10n.t('activePeers'),
              subtitle: publicPeers.total > 0
                  ? connected
                        ? l10n.tf('peersConnected', [
                            publicPeers.up,
                            publicPeers.total,
                          ])
                        : l10n.tf('peerCountLabel', [publicPeers.total])
                  : null,
              children: [
                if (state.peers.isEmpty)
                  state.probing
                      ? _FindPeersProgress(state: state, l10n: l10n)
                      : EmptyHint(
                          icon: Icons.hub_outlined,
                          title: l10n.t('noPeersYet'),
                          body: l10n.t('findPeersHint'),
                          action: FilledButton.tonalIcon(
                            onPressed: () => _findPeers(context, state),
                            icon: const Icon(Icons.search_rounded),
                            label: Text(l10n.t('findPeers')),
                          ),
                        )
                else
                  for (final peer in state.peers)
                    _PeerRow(
                      peer: peer,
                      status: state.statusByUri[peer.uri],
                      highlight: peer.pinned && state.exitInUse,
                      onTap: () => _showPeerDetails(
                        context,
                        peer,
                        state.statusByUri[peer.uri],
                        state.peerErrorFor(peer.uri),
                        l10n,
                      ),
                    ),
                if (state.peers.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                    child: Row(
                      children: [
                        TextButton.icon(
                          onPressed: onOpenPeers,
                          icon: const Icon(Icons.tune_rounded, size: 18),
                          label: Text(l10n.t('peersTitle')),
                        ),
                        const Spacer(),
                        if (connected)
                          Tooltip(
                            message: l10n.t('refreshPeersHint'),
                            child: TextButton.icon(
                              onPressed: () async {
                                await state.refreshPeers();
                                if (context.mounted) {
                                  showSnack(context, l10n.t('peersRefreshed'));
                                }
                              },
                              icon: const Icon(Icons.refresh_rounded, size: 18),
                              label: Text(l10n.t('refreshPeers')),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ExitNodeCard(state: state),
            if (state.identity != null) ...[
              const SizedBox(height: 8),
              SectionCard(
                title: l10n.t('yourAddress'),
                children: [
                  ScrollableInfoRow(
                    label: l10n.t('yggAddress'),
                    value: state.identity!.address,
                    copyHint: l10n.t('copy'),
                    onTap: () async {
                      await Clipboard.setData(
                        ClipboardData(text: state.identity!.address),
                      );
                      if (context.mounted) {
                        showSnack(context, l10n.t('addressCopied'));
                      }
                    },
                  ),
                  if (subnet.isNotEmpty)
                    ScrollableInfoRow(
                      label: l10n.t('subnet'),
                      value: subnet,
                      copyHint: l10n.t('copy'),
                      onTap: () async {
                        await Clipboard.setData(ClipboardData(text: subnet));
                        if (context.mounted) {
                          showSnack(context, l10n.t('addressCopied'));
                        }
                      },
                    ),
                  InfoRow(
                    label: l10n.t('yourKey'),
                    value: _shortKey(state.identity!.publicKey),
                    monospace: true,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The line under the power button while the link is coming up. The service
  /// reports a stage; when it has none yet the status itself is the best guess.
  static String _stageText(L10n l10n, AppState state) {
    final snapshot = state.snapshot;
    if (snapshot.status == 'disconnecting') {
      return l10n.t('statusDisconnecting');
    }
    // The very first tap of Connect goes through the Android permission dialog
    // before the service reports anything, so the local flag is the only thing
    // the user can be shown for a moment.
    if (state.connecting && snapshot.isDisconnected) {
      return l10n.t('stagePreparing');
    }
    switch (snapshot.stage) {
      case 'starting':
        return l10n.t('stageStarting');
      case 'tunnel':
        return l10n.t('stageTunnel');
      case 'network':
        return l10n.t('stageNetwork');
      case 'peers':
        final public = state.publicPeerStats;
        return l10n.tf('stagePeers', [public.up, public.total]);
    }
    if (snapshot.status == 'reconnecting') return l10n.t('stageNetwork');
    if (snapshot.isConnected && snapshot.peersUp == 0) {
      return l10n.t('stageWaiting');
    }
    if (snapshot.status == 'connecting') return l10n.t('stageStarting');
    return l10n.t('stageReady');
  }

  /// Runs the discovery from the Tunnel tab: the probe fills the list and the
  /// best nodes are added right away, without sending the user to Peers.
  static Future<void> _findPeers(BuildContext context, AppState state) async {
    final l10n = state.l10n;
    final ok = await state.findAndAddPeers();
    if (!context.mounted) return;
    showSnack(
      context,
      ok ? l10n.t('findPeersDone') : l10n.t(state.lastError ?? 'probeNothing'),
    );
  }

  static String _shortKey(String key) {
    if (key.length <= 20) return key;
    return '${key.substring(0, 10)}…${key.substring(key.length - 6)}';
  }

  /// Keeps the exit badge on one line next to the status pill.
  static String _shortExitName(String name) {
    final trimmed = name.trim();
    if (trimmed.length <= 22) return trimmed;
    return '${trimmed.substring(0, 21)}…';
  }
}

Future<void> _showLatencyInfo(
  BuildContext context,
  L10n l10n,
  int intervalSec,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.t('latency')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.t('latencyHint')),
          const SizedBox(height: 12),
          Text(
            l10n.tf('latencyRefresh', [intervalSec]),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.t('close')),
        ),
      ],
    ),
  );
}

String _shortKey(String key) {
  if (key.length <= 20) return key;
  return '${key.substring(0, 10)}…${key.substring(key.length - 6)}';
}

/// The detail sheet of one link: everything `yggdrasilctl getpeers` reports.
Future<void> _showPeerDetails(
  BuildContext context,
  PeerEntry peer,
  PeerStatus? status,
  PeerErrorRecord? rememberedError,
  L10n l10n,
) {
  final parsed = Uri.tryParse(peer.uri);
  final scheme = parsed?.scheme ?? '';
  final port = parsed != null && parsed.hasPort ? '${parsed.port}' : '—';
  final place = [
    if (peer.city.isNotEmpty) peer.city,
    if (peer.country.isNotEmpty) countryName(peer.country),
  ].join(', ');
  final currentError = status?.lastError ?? '';
  final statusError = status?.lastErrorWas ?? '';
  final useStatusError = currentError.isEmpty && statusError.isNotEmpty;
  final inactiveError = currentError.isNotEmpty
      ? ''
      : useStatusError
      ? statusError
      : rememberedError?.message ?? '';
  final inactiveAt = useStatusError
      ? status?.lastErrorWasUnix ?? 0
      : rememberedError?.lastSeenUnix ?? 0;
  final inactiveWhen = inactiveAt > 0
      ? formatDateTime(DateTime.fromMillisecondsSinceEpoch(inactiveAt * 1000))
      : null;
  final errorValue = currentError.isNotEmpty
      ? '$currentError · ${l10n.t('peerErrorCurrent')}'
      : inactiveError.isNotEmpty
      ? inactiveWhen == null
            ? '$inactiveError · ${l10n.t('peerErrorInactive')}'
            : '$inactiveError · ${l10n.t('peerErrorInactive')} · '
                  '${l10n.tf('peerErrorLastSeen', [inactiveWhen])}'
      : l10n.t('peerNoErrors');

  return showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: Row(
          children: [
            FlagBadge(flag: countryFlag(peer.country), size: 30),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    place.isEmpty ? uriHost(peer.uri) : place,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  Text(
                    l10n.t('peerDetails'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 340,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                InfoRow(
                  label: l10n.t('peerUri'),
                  value: peer.uri,
                  monospace: true,
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: peer.uri));
                    if (context.mounted) {
                      showSnack(context, l10n.t('addressCopied'));
                    }
                  },
                ),
                InfoRow(
                  label: l10n.t('peerScheme'),
                  value: scheme.isEmpty ? '—' : scheme,
                ),
                InfoRow(label: l10n.t('peerPort'), value: port),
                InfoRow(
                  label: l10n.t('peerDirection'),
                  value: status == null
                      ? '—'
                      : l10n.t(status.inbound ? 'peerInbound' : 'peerOutbound'),
                ),
                InfoRow(
                  label: l10n.t('latency'),
                  value: formatLatency(status?.latencyMs ?? peer.latencyMs),
                ),
                InfoRow(
                  label: l10n.t('peerCost'),
                  value: status == null ? '—' : '${status.cost}',
                ),
                InfoRow(
                  label: l10n.t('peerYggAddress'),
                  value: status == null || status.ip.isEmpty ? '—' : status.ip,
                  monospace: true,
                ),
                InfoRow(
                  label: l10n.t('peerKey'),
                  value: status == null || status.key.isEmpty
                      ? '—'
                      : _shortKey(status.key),
                  monospace: true,
                ),
                InfoRow(
                  label: l10n.t('peerUptime'),
                  value: status == null
                      ? '—'
                      : formatDuration(status.uptimeSeconds.round(), l10n),
                ),
                InfoRow(
                  label: l10n.t('peerTraffic'),
                  value: status == null
                      ? '—'
                      : '↓ ${formatBytes(status.rxBytes)} · '
                            '↑ ${formatBytes(status.txBytes)}',
                ),
                InfoRow(
                  label: l10n.t('peerLastError'),
                  // One row instead of two: the message and the moment it was
                  // reported belong together, and a bare timestamp says nothing
                  // without the error it refers to. A recovered link keeps its
                  // last error, marked as inactive with the time it was seen.
                  value: errorValue,
                  valueColor: currentError.isNotEmpty
                      ? AppColors.offline
                      : inactiveError.isNotEmpty
                      ? theme.colorScheme.onSurfaceVariant
                      : null,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: peer.uri));
              if (context.mounted) {
                showSnack(context, l10n.t('addressCopied'));
              }
            },
            child: Text(l10n.t('copy')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.t('close')),
          ),
        ],
      );
    },
  );
}

class _Hero extends StatefulWidget {
  const _Hero({
    required this.statusColor,
    required this.statusLabel,
    required this.connected,
    required this.busy,
    required this.establishing,
    required this.stageText,
    required this.peersUp,
    required this.peersTotal,
    required this.connectedAt,
    required this.onToggle,
    required this.exitName,
    required this.exitCountry,
    required this.exitOn,
    required this.exitInUse,
    required this.onIpRequest,
    this.errorText,
  });

  final Color statusColor;
  final String statusLabel;
  final bool connected;
  final bool busy;
  final bool establishing;
  final String stageText;
  final int peersUp;
  final int peersTotal;
  final int connectedAt;
  final VoidCallback onToggle;
  final String? errorText;

  /// The name of the exit node, empty when no profile is selected.
  final String exitName;

  /// The country of the exit server, empty until the lookup answers.
  final String exitCountry;

  /// The exit node is switched on in the settings.
  final bool exitOn;

  /// The tunnel is up and public traffic really goes through the exit.
  final bool exitInUse;

  /// Opens the address balloon: the phone's own address or the one the exit
  /// sends the traffic from. The first argument is the widget to point at.
  final void Function(BuildContext anchor, bool viaExit) onIpRequest;

  @override
  State<_Hero> createState() => _HeroState();
}

class _HeroState extends State<_Hero> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _Hero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.establishing != widget.establishing ||
        oldWidget.busy != widget.busy ||
        oldWidget.connected != widget.connected) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    // The ring pulses while the link comes up; the flow dots keep running for
    // as long as the tunnel carries traffic.
    final run = widget.establishing || widget.busy || widget.connected;
    if (run) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final active = widget.establishing || widget.busy;
    final linkUp = widget.connected || active;
    final exitLit = widget.exitOn && linkUp;
    final exitLabel = widget.exitName.isEmpty
        ? l10n.t('exitNode')
        : HomeScreen._shortExitName(widget.exitName);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          children: [
            StatusPill(label: widget.statusLabel, color: widget.statusColor),
            const SizedBox(height: 4),
            // The link is drawn as a path: the phone on the left, the exit
            // node on the right, and the power button in the middle. While the
            // tunnel comes up the dots run from Me towards the exit, and once
            // it is up they keep running to show where the traffic goes.
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _HeroEntity(
                  label: l10n.t('heroMe'),
                  icon: Icons.person_rounded,
                  color: widget.statusColor,
                  active: linkUp,
                  hint: l10n.t('ipTapHint'),
                  onTap: (anchor) => widget.onIpRequest(anchor, false),
                ),
                Expanded(
                  child: _FlowLink(
                    animation: _pulse,
                    color: widget.statusColor,
                    on: linkUp,
                  ),
                ),
                // A fixed box holds the button and its pulse ring: the ring
                // grows outwards inside it, so nothing around it ever moves.
                SizedBox(
                  width: 134,
                  height: 141,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // The ring is only mounted while the link is coming up:
                      // a connected tunnel must not rebuild it every frame.
                      if (active)
                        AnimatedBuilder(
                          animation: _pulse,
                          builder: (context, child) {
                            final t = _pulse.value;
                            return Opacity(
                              opacity: (1 - t) * 0.5,
                              child: Transform.scale(
                                scale: 1 + 0.16 * t,
                                child: Container(
                                  width: 112,
                                  height: 112,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: widget.statusColor,
                                      width: 2,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      PowerButton(
                        connected: widget.connected,
                        busy: widget.busy,
                        onPressed: widget.onToggle,
                        tooltip: widget.connected
                            ? l10n.t('disconnect')
                            : l10n.t('connect'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _FlowLink(
                    animation: _pulse,
                    color: theme.colorScheme.primary,
                    on: exitLit,
                    phase: 0.35,
                  ),
                ),
                _HeroEntity(
                  label: exitLabel,
                  flag: countryFlag(widget.exitCountry),
                  icon: Icons.vpn_lock_rounded,
                  color: theme.colorScheme.primary,
                  active: exitLit,
                  locked: widget.exitInUse,
                  hint: l10n.t('ipTapHint'),
                  onTap: (anchor) => widget.onIpRequest(anchor, true),
                ),
              ],
            ),
            const SizedBox(height: 2),
            // The same reservation for the line under the button: the status,
            // the progress bar and the uptime all live in one fixed block.
            SizedBox(
              height: 70,
              child: Align(
                alignment: Alignment.topCenter,
                child: active
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            height: 38,
                            child: Center(
                              child: Text(
                                widget.stageText,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          SizedBox(
                            width: 168,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: const LinearProgressIndicator(
                                minHeight: 3,
                              ),
                            ),
                          ),
                          if (widget.peersTotal > 0) ...[
                            const SizedBox(height: 6),
                            Text(
                              l10n.tf('peersConnected', [
                                widget.peersUp,
                                widget.peersTotal,
                              ]),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.connected
                                ? l10n.t('disconnect')
                                : l10n.t('connect'),
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (widget.connected)
                            _Uptime(connectedAt: widget.connectedAt),
                        ],
                      ),
              ),
            ),
            if (widget.errorText != null && widget.errorText!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.offline.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  widget.errorText!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.offline,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The "connected for" clock.
///
/// It owns its one-second timer so the tick repaints this single line instead
/// of the whole hero card. The timer is stopped while the tab is off screen:
/// [TickerMode] already mutes animations there, and a hidden clock has no one
/// to update.
class _Uptime extends StatefulWidget {
  const _Uptime({required this.connectedAt});

  final int connectedAt;

  @override
  State<_Uptime> createState() => _UptimeState();
}

class _UptimeState extends State<_Uptime> {
  Timer? _timer;
  bool _visible = true;

  /// Whether [didChangeDependencies] has run at least once. Without this flag
  /// the first call saw the same visibility as the field default and returned
  /// without ever starting the timer: the clock only began to tick after the
  /// user switched tabs and came back.
  bool _resolved = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (_resolved && visible == _visible) return;
    _resolved = true;
    _visible = visible;
    _sync();
  }

  @override
  void didUpdateWidget(covariant _Uptime oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connectedAt != widget.connectedAt) _sync();
  }

  void _sync() {
    _timer?.cancel();
    _timer = null;
    if (!_visible || widget.connectedAt <= 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final uptime = widget.connectedAt > 0
        ? ((DateTime.now().millisecondsSinceEpoch - widget.connectedAt) ~/ 1000)
              .clamp(0, 1 << 31)
        : 0;
    if (uptime <= 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.timer_outlined,
            size: 15,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            l10n.tf('connectedFor', [formatClock(uptime)]),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// One end of the hero link: the phone on the left, the exit node on the right.
class _HeroEntity extends StatelessWidget {
  const _HeroEntity({
    required this.label,
    required this.color,
    required this.active,
    this.icon,
    this.flag = '',
    this.locked = false,
    this.hint = '',
    this.onTap,
  });

  final String label;
  final Color color;
  final bool active;
  final IconData? icon;

  /// The country flag of the node, shown instead of the icon when known.
  final String flag;

  /// The exit node public traffic goes through right now.
  final bool locked;

  /// What a tap does, for a screen reader.
  final String hint;

  /// Called with the widget's own context, which the address balloon uses as
  /// its anchor.
  final void Function(BuildContext anchor)? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final idle = theme.colorScheme.onSurfaceVariant;
    return SizedBox(
      width: 58,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The label hangs below the circle; this spacer keeps the circle
          // itself on the centre line of the row, level with the button.
          const SizedBox(height: 18),
          // The circle is the tap target of the address balloon: the whole
          // entity is the anchor, so the balloon points at the icon the user
          // pressed rather than at the card.
          Semantics(
            button: onTap != null,
            hint: hint.isEmpty ? null : hint,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap == null ? null : () => onTap!(context),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: 46,
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: active
                          ? color.withValues(alpha: 0.14)
                          : theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.6),
                      border: Border.all(
                        color: active
                            ? color.withValues(alpha: 0.55)
                            : Colors.transparent,
                        width: 1.5,
                      ),
                    ),
                    child: flag.isNotEmpty
                        ? Text(flag, style: const TextStyle(fontSize: 21))
                        : Icon(
                            icon ?? Icons.circle,
                            size: 21,
                            color: active ? color : idle,
                          ),
                  ),
                  if (locked)
                    Positioned(
                      right: -1,
                      bottom: -1,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: theme.colorScheme.surface,
                            width: 1.5,
                          ),
                        ),
                        child: Icon(
                          Icons.lock_rounded,
                          size: 8,
                          color: theme.colorScheme.onPrimary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10,
              height: 1.2,
              color: active ? theme.colorScheme.onSurface : idle,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// The animated line between an entity and the power button: a dashed path
/// with dots running along it while traffic flows.
class _FlowLink extends StatelessWidget {
  const _FlowLink({
    required this.animation,
    required this.color,
    required this.on,
    this.phase = 0,
  });

  final Animation<double> animation;
  final Color color;
  final bool on;

  /// Shifts the dots of the second link so the two halves do not move in step.
  final double phase;

  @override
  Widget build(BuildContext context) {
    Widget paint(double t) => CustomPaint(
      size: Size.infinite,
      painter: _FlowPainter(t: t, color: color, flow: on),
    );

    return SizedBox(
      height: 22,
      child: RepaintBoundary(
        // A still line must not repaint with the controller, so the animation
        // is only listened to while the link is actually carrying traffic.
        child: on
            ? AnimatedBuilder(
                animation: animation,
                builder: (context, _) => paint((animation.value + phase) % 1.0),
              )
            : paint(0),
      ),
    );
  }
}

class _FlowPainter extends CustomPainter {
  _FlowPainter({required this.t, required this.color, required this.flow});

  final double t;
  final Color color;
  final bool flow;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final y = size.height / 2;
    final line = Paint()
      ..color = color.withValues(alpha: flow ? 0.45 : 0.7)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    const dash = 3.0;
    const gap = 4.0;
    for (var x = 0.0; x < size.width; x += dash + gap) {
      final end = x + dash > size.width ? size.width : x + dash;
      canvas.drawLine(Offset(x, y), Offset(end, y), line);
    }
    if (!flow) return;
    final dot = Paint()..color = color;
    final halo = Paint()..color = color.withValues(alpha: 0.18);
    for (var i = 0; i < 2; i++) {
      final x = size.width * ((t + i * 0.5) % 1.0);
      canvas.drawCircle(Offset(x, y), 4.5, halo);
      canvas.drawCircle(Offset(x, y), 2.2, dot);
    }
  }

  @override
  bool shouldRepaint(covariant _FlowPainter old) =>
      old.t != t || old.color != color || old.flow != flow;
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({
    required this.latencyMs,
    required this.traffic,
    required this.healthCheckSec,
    required this.onLatencyInfo,
  });

  final double latencyMs;

  /// The live byte counters. They tick every second, so only the two number
  /// blocks listen to them instead of the whole tab.
  final ValueListenable<TrafficCounters> traffic;
  final int healthCheckSec;
  final VoidCallback onLatencyInfo;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: ValueListenableBuilder<TrafficCounters>(
                    valueListenable: traffic,
                    builder: (context, value, _) {
                      return StatBlock(
                        icon: Icons.download_rounded,
                        label: l10n.t('trafficDown'),
                        value: formatBytes(value.rx),
                      );
                    },
                  ),
                ),
                Expanded(
                  child: InkWell(
                    onTap: onLatencyInfo,
                    borderRadius: BorderRadius.circular(12),
                    child: StatBlock(
                      icon: Icons.speed_rounded,
                      label: l10n.t('latency'),
                      value: formatLatency(latencyMs),
                    ),
                  ),
                ),
                Expanded(
                  child: ValueListenableBuilder<TrafficCounters>(
                    valueListenable: traffic,
                    builder: (context, value, _) => StatBlock(
                      icon: Icons.upload_rounded,
                      label: l10n.t('trafficUp'),
                      value: formatBytes(value.tx),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            InkWell(
              onTap: onLatencyInfo,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            l10n.t('latencyShort'),
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.tf('latencyRefresh', [healthCheckSec]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.7,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "exemption granted" badge in the app bar.
///
/// It is a separate widget on purpose: the tunnel screen rebuilds once a second
/// while traffic flows, and the badge only has to change when the exemption
/// itself changes.
class _BatteryBadge extends StatelessWidget {
  const _BatteryBadge();

  @override
  Widget build(BuildContext context) {
    final exempt = context.select<AppState, bool>((s) => s.batteryExempt);
    if (!exempt) return const SizedBox.shrink();
    return Tooltip(
      message: L10n.of(context).t('batteryGranted'),
      child: const Padding(
        padding: EdgeInsets.only(right: 12),
        child: Icon(Icons.battery_charging_full_rounded, size: 20),
      ),
    );
  }
}

class _PeerRow extends StatelessWidget {
  const _PeerRow({
    required this.peer,
    required this.status,
    required this.onTap,
    this.highlight = false,
  });

  final PeerEntry peer;
  final PeerStatus? status;
  final VoidCallback onTap;

  /// The exit link that public traffic actually goes through right now.
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final up = status?.up ?? false;
    final latency = status?.latencyMs ?? peer.latencyMs;
    final peerState = VpnStatusUi.peerState(
      up: up,
      latencyMs: latency,
      // A peer without a live link is only red when the node reported an error
      // for it; a handshake in progress stays amber.
      knownDead:
          status != null && !up && (status?.lastError.isNotEmpty ?? false),
    );
    final color = VpnStatusUi.peerColorOf(peerState);
    final flag = countryFlag(peer.country);
    final place = [
      if (peer.city.isNotEmpty) peer.city,
      if (peer.country.isNotEmpty) countryName(peer.country),
    ].join(', ');
    final pinned = peer.pinned;

    return ListTile(
      onTap: onTap,
      // A pinned row is the exit node: the flag still shows where the server
      // is, and a small lock on the badge marks it while it is in use.
      tileColor: highlight
          ? theme.colorScheme.primary.withValues(alpha: 0.07)
          : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      leading: pinned && highlight
          ? Stack(
              clipBehavior: Clip.none,
              children: [
                FlagBadge(flag: flag),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: theme.colorScheme.surface,
                        width: 1.5,
                      ),
                    ),
                    child: Icon(
                      Icons.lock_rounded,
                      size: 9,
                      color: theme.colorScheme.onPrimary,
                    ),
                  ),
                ),
              ],
            )
          : FlagBadge(flag: flag),
      title: Row(
        children: [
          Flexible(
            child: Text(
              place.isEmpty ? uriHost(peer.uri) : place,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (pinned) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                l10n.t('peerExitNode'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        shortUri(peer.uri),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            formatLatency(latency),
            style: theme.textTheme.labelLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            VpnStatusUi.peerLabel(peerState, l10n),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The inline progress of a discovery started from the empty Active peers card.
class _FindPeersProgress extends StatelessWidget {
  const _FindPeersProgress({required this.state, required this.l10n});

  final AppState state;
  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = state.probeProgress;
    final determinate =
        progress != null && progress.phase == 'ygg' && progress.total > 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      child: Column(
        children: [
          const Icon(Icons.radar_rounded, size: 40),
          const SizedBox(height: 12),
          Text(
            l10n.t('findPeersTitle'),
            textAlign: TextAlign.center,
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          Text(
            VpnStatusUi.probePhase(progress, l10n),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: determinate ? progress.fraction : null,
              minHeight: 5,
            ),
          ),
          if (progress != null && progress.alive > 0) ...[
            const SizedBox(height: 8),
            Text(
              '${progress.alive} ${l10n.t('probeAlive')}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.online,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 6),
          TextButton(
            onPressed: state.cancelProbe,
            child: Text(l10n.t('cancel')),
          ),
        ],
      ),
    );
  }
}
