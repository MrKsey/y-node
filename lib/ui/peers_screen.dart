import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../data/geo.dart';
import '../data/models.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'peer_catalog_screen.dart';
import 'status_ui.dart';
import 'widgets.dart';

/// Peers: the active set, the replacement pool and the latency test that fills
/// both of them.
class PeersScreen extends StatelessWidget {
  const PeersScreen({super.key, required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = state.l10n;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('peersTitle')),
        actions: [
          IconButton(
            tooltip: l10n.t('settingsTitle'),
            onPressed: onOpenSettings,
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          // The catalogue is the way into the full public list, so it comes
          // before the quick probe: it is what most users look for first.
          SectionCard(
            title: l10n.t('peerCatalog'),
            subtitle: l10n.t('peerCatalogHint'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const PeerCatalogScreen(),
                          ),
                        ),
                        icon: const Icon(Icons.public_rounded, size: 18),
                        label: Text(l10n.t('browseAllPeers')),
                      ),
                    ),
                  ],
                ),
              ),
              if (state.candidates.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      l10n.tf('catalogCount', [state.candidates.length]),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _ProbeCard(state: state, l10n: l10n),
          if (state.probeAlive.isNotEmpty) ...[
            const SizedBox(height: 8),
            _ResultsCard(state: state, l10n: l10n),
          ],
          const SizedBox(height: 8),
          SectionCard(
            title: l10n.t('activePeers'),
            subtitle: l10n.tf('peerCountLabel', [state.publicPeerCount]),
            children: [
              if (state.peers.isEmpty)
                EmptyHint(
                  icon: Icons.hub_outlined,
                  title: l10n.t('noActivePeers'),
                  body: l10n.t('peersEmptyHint'),
                )
              else
                for (final peer in state.peers)
                  _PeerTile(
                    peer: peer,
                    status: state.statusByUri[peer.uri],
                    l10n: l10n,
                    titleOverride: _exitTitle(state, peer),
                    onRemove: peer.pinned
                        ? null
                        : () => state.removePeer(peer.uri),
                    removeTooltip: l10n.t('removePeer'),
                  ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _showAddDialog(context, state),
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: Text(l10n.t('addManually')),
                      ),
                    ),
                    if (state.peers.any((peer) => !peer.pinned)) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: l10n.t('clear'),
                        onPressed: () => _confirmClear(context, state),
                        icon: const Icon(Icons.delete_sweep_outlined),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SectionCard(
            title: l10n.t('replacementPool'),
            subtitle: l10n.t('poolHint'),
            children: [
              if (state.pool.isEmpty)
                EmptyHint(
                  icon: Icons.layers_outlined,
                  title: l10n.t('poolEmpty'),
                  body: l10n.t('poolHint'),
                )
              else
                for (final peer in state.pool)
                  _PeerTile(
                    peer: peer,
                    status: state.statusByUri[peer.uri],
                    l10n: l10n,
                    action: IconButton(
                      tooltip: l10n.t('remove'),
                      onPressed: () => state.removePeer(peer.uri),
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
                  ),
            ],
          ),
        ],
      ),
    );
  }

  static String? _exitTitle(AppState state, PeerEntry peer) {
    if (!peer.pinned) return null;
    for (final profile in state.settings.exitProfiles) {
      if (profile.peer == peer.uri) return profile.title;
    }
    return null;
  }

  static Future<void> _showAddDialog(
    BuildContext context,
    AppState state,
  ) async {
    final l10n = state.l10n;
    final controller = TextEditingController();
    String? error;

    final added = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocalState) => AlertDialog(
          title: Text(l10n.t('addManually')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: l10n.t('peerUri'),
                  hintText: l10n.t('peerUriHint'),
                  errorText: error == null ? null : l10n.t(error!),
                ),
                onSubmitted: (_) => _submit(
                  dialogContext,
                  state,
                  controller.text,
                  (message) => setLocalState(() => error = message),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.t('cancel')),
            ),
            FilledButton(
              onPressed: () => _submit(
                dialogContext,
                state,
                controller.text,
                (message) => setLocalState(() => error = message),
              ),
              child: Text(l10n.t('add')),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (added == true && context.mounted) {
      showSnack(context, state.takePeerNotice() ?? l10n.t('peerAdded'));
    }
  }

  static Future<void> _submit(
    BuildContext context,
    AppState state,
    String value,
    void Function(String?) setError,
  ) async {
    final failure = await state.addPeer(value);
    if (failure != null) {
      setError(failure);
      return;
    }
    if (context.mounted) Navigator.of(context).pop(true);
  }

  static Future<void> _confirmClear(
    BuildContext context,
    AppState state,
  ) async {
    final l10n = state.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.t('clear')),
        content: Text(l10n.t('peersClearBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.t('clear')),
          ),
        ],
      ),
    );
    if (confirmed == true) await state.clearPeers();
  }
}

class _ProbeCard extends StatelessWidget {
  const _ProbeCard({required this.state, required this.l10n});

  final AppState state;
  final L10n l10n;

  String get _phaseLabel => VpnStatusUi.probePhase(state.probeProgress, l10n);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = state.probeProgress;
    final determinate =
        progress != null && progress.phase == 'ygg' && progress.total > 0;

    return SectionCard(
      title: l10n.t('findPeersTitle'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (state.detectedCity.isNotEmpty || state.countrySlug.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _pickCountry(context),
                    child: Row(
                      children: [
                        FlagBadge(
                          flag: countryFlag(state.countrySlug),
                          size: 30,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.t('detectedLocation'),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              Text(
                                [
                                  if (state.detectedCity.isNotEmpty)
                                    state.detectedCity,
                                  if (state.countrySlug.isNotEmpty)
                                    countryName(state.countrySlug),
                                ].join(', '),
                                style: theme.textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.edit_outlined,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              if (state.probing) ...[
                LinearProgressIndicator(
                  value: determinate ? progress.fraction : null,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _phaseLabel,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (progress != null && progress.alive > 0)
                      Text(
                        '${progress.alive} ${l10n.t('probeAlive')}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.online,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: state.cancelProbe,
                    child: Text(l10n.t('cancel')),
                  ),
                ),
              ] else ...[
                FilledButton.icon(
                  onPressed: () => state.probePeers(),
                  icon: const Icon(Icons.radar_rounded),
                  label: Text(l10n.t('findPeers')),
                ),
                const SizedBox(height: 8),
                Text(
                  formatAgo(state.peersUpdatedAt, l10n),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _pickCountry(BuildContext context) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        builder: (sheetContext, controller) => ListView(
          controller: controller,
          children: [
            ListTile(
              leading: const Icon(Icons.my_location_rounded),
              title: Text(l10n.t('autoDetect')),
              onTap: () => Navigator.of(sheetContext).pop(''),
            ),
            const Divider(),
            for (final country in kCountries)
              ListTile(
                leading: FlagBadge(flag: country.flag, size: 30),
                title: Text(country.name),
                trailing: state.countrySlug == country.slug
                    ? const Icon(Icons.check_rounded, size: 18)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(country.slug),
              ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    await state.setCountry(selected);
  }
}

class _ResultsCard extends StatelessWidget {
  const _ResultsCard({required this.state, required this.l10n});

  final AppState state;
  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final alive = state.probeAlive;
    // The tunnel keeps the configured number of links, so the button replaces
    // the slowest of them instead of appending more.
    final target = state.settings.peerCount;

    return SectionCard(
      title: l10n.t('probeResults'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Icon(
                Icons.check_circle_rounded,
                size: 16,
                color: AppColors.online,
              ),
              const SizedBox(width: 6),
              Text(
                '${alive.length} ${l10n.t('probeAlive')}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.online,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        for (final result in alive.take(8))
          _PeerTile(
            peer: result.toPeer(),
            status: state.statusByUri[result.uri],
            l10n: l10n,
            subtitleOverride: shortUri(result.uri),
            action: IconButton(
              tooltip: l10n.t('add'),
              onPressed: () => _addOne(context, state, result.uri),
              icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: FilledButton.tonalIcon(
            onPressed: () async {
              final changed = await state.applyBestPeers();
              if (!context.mounted) return;
              showSnack(
                context,
                changed == 0
                    ? l10n.t('peerSetUnchanged')
                    : l10n.tf('peerSetUpdated', [state.settings.peerCount]),
              );
            },
            icon: const Icon(Icons.auto_awesome_rounded, size: 18),
            label: Text(l10n.tf('addBestN', [target])),
          ),
        ),
      ],
    );
  }

  static Future<void> _addOne(
    BuildContext context,
    AppState state,
    String uri,
  ) async {
    final l10n = state.l10n;
    final failure = await state.addPeer(uri);
    if (!context.mounted) return;
    if (failure != null) {
      showSnack(context, l10n.t(failure));
      return;
    }
    showSnack(context, state.takePeerNotice() ?? l10n.t('peerAdded'));
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({
    required this.peer,
    required this.status,
    required this.l10n,
    this.onRemove,
    this.removeTooltip,
    this.action,
    this.subtitleOverride,
    this.titleOverride,
  });

  final PeerEntry peer;
  final PeerStatus? status;
  final L10n l10n;
  final VoidCallback? onRemove;
  final String? removeTooltip;

  /// A button shown after the latency column, without hiding the latency.
  final Widget? action;
  final String? subtitleOverride;

  /// The exit node name for a pinned peer, instead of its bare host.
  final String? titleOverride;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pinned = peer.pinned;
    final up = status?.up ?? false;
    final latency = status?.latencyMs ?? peer.latencyMs;
    final peerState = VpnStatusUi.peerState(
      up: up,
      latencyMs: latency,
      // Red is for a peer the node reported an error for, not for one that is
      // still handshaking.
      knownDead:
          status != null && !up && (status?.lastError.isNotEmpty ?? false),
    );
    final color = VpnStatusUi.peerColorOf(peerState);
    final place = [
      if (peer.city.isNotEmpty) peer.city,
      if (peer.country.isNotEmpty) countryName(peer.country),
    ].join(', ');

    return ListTile(
      leading: pinned
          ? Tooltip(
              message: l10n.t('peerPinnedHint'),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  FlagBadge(flag: countryFlag(peer.country)),
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
              ),
            )
          : FlagBadge(flag: countryFlag(peer.country)),
      title: Text(
        titleOverride ?? (place.isEmpty ? uriHost(peer.uri) : place),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Row(
        children: [
          if (pinned) ...[
            StatusPill(
              label: l10n.t('peerExitNode'),
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              subtitleOverride ?? shortUri(peer.uri),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
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
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    VpnStatusUi.peerLabel(peerState, l10n),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (onRemove != null && !pinned)
            IconButton(
              tooltip: removeTooltip,
              onPressed: onRemove,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          if (pinned)
            Tooltip(
              message: l10n.t('peerPinnedHint'),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Icon(
                  Icons.lock_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ?action,
        ],
      ),
    );
  }
}
