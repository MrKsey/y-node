import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../data/geo.dart';
import '../data/models.dart';
import '../data/peers_source.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'status_ui.dart';
import 'widgets.dart';

/// The whole public-peer list: every transport, filtered by country, protocol
/// and port, with a measured Yggdrasil latency per peer.
class PeerCatalogScreen extends StatefulWidget {
  const PeerCatalogScreen({super.key});

  @override
  State<PeerCatalogScreen> createState() => _PeerCatalogScreenState();
}

class _PeerCatalogScreenState extends State<PeerCatalogScreen> {
  String _country = '';
  String _scheme = '';
  bool _only443 = false;

  /// Probing the whole catalogue would take minutes, so the button tests the
  /// part the user is looking at.
  static const int _testLimit = 25;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    if (state.candidates.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) state.loadCandidates();
      });
    }
  }

  List<PeerCandidate> _filtered(AppState state) {
    return [
      for (final peer in state.candidates)
        if ((_country.isEmpty || peer.country == _country) &&
            (_scheme.isEmpty || peer.scheme == _scheme) &&
            (!_only443 || peer.port == 443))
          peer,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = state.l10n;
    final theme = Theme.of(context);
    final filtered = _filtered(state);
    final results = {
      for (final result in state.probeResults) result.uri: result,
    };
    final added = {for (final peer in state.peers) peer.uri};
    final addedHosts = {
      for (final peer in state.peers) Uri.tryParse(peer.uri)?.host ?? '',
    };
    final countries = _countries(state.candidates);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('peerCatalog'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              l10n.t('peerCatalogHint'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownButton<String>(
                  value: _country,
                  isDense: true,
                  items: [
                    DropdownMenuItem(
                      value: '',
                      child: Text(l10n.t('allCountries')),
                    ),
                    for (final country in countries)
                      DropdownMenuItem(
                        value: country.slug,
                        child: Text(
                          '${countryFlag(country.slug)} '
                          '${_countryName(country.slug)} '
                          '(${country.count})',
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() => _country = value ?? ''),
                ),
                DropdownButton<String>(
                  value: _scheme,
                  isDense: true,
                  items: [
                    DropdownMenuItem(
                      value: '',
                      child: Text(l10n.t('allSchemes')),
                    ),
                    for (final scheme in kPeerSchemes)
                      DropdownMenuItem(value: scheme, child: Text(scheme)),
                  ],
                  onChanged: (value) => setState(() => _scheme = value ?? ''),
                ),
                FilterChip(
                  label: Text(l10n.t('onlyPort443')),
                  selected: _only443,
                  onSelected: (value) => setState(() => _only443 = value),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.tf('catalogCount', [filtered.length]),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l10n.t('catalogSortHint'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.75,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // The button keeps its size and its icon while the test runs: it
                // is disabled instead of being replaced by a shorter label.
                FilledButton.tonalIcon(
                  onPressed: filtered.isEmpty || state.probing
                      ? null
                      : () => state.probeUris([
                          for (final peer in filtered.take(_testLimit))
                            peer.uri,
                        ]),
                  icon: state.probing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.speed_rounded, size: 18),
                  label: Text(
                    state.probing
                        ? l10n.t('testingVisible')
                        : l10n.t('testVisible'),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
            child: state.probing
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LinearProgressIndicator(
                        value: state.probeProgress?.fraction,
                        minHeight: 3,
                        borderRadius: BorderRadius.circular(2),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.tf('testingProgress', [
                                state.probeProgress?.tested ?? 0,
                                state.probeProgress?.total ?? 0,
                              ]),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.secondary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            '${state.probeProgress?.alive ?? 0} '
                            '${l10n.t('probeAlive')}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: AppColors.online,
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: state.cancelProbe,
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            child: Text(l10n.t('cancel')),
                          ),
                        ],
                      ),
                    ],
                  )
                : Text(
                    l10n.tf('testVisibleCount', [
                      filtered.length < _testLimit
                          ? filtered.length
                          : _testLimit,
                      filtered.length,
                    ]),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
          ),
          Expanded(
            child: state.loadingPeers
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 12),
                        Text(l10n.t('catalogLoading')),
                      ],
                    ),
                  )
                : filtered.isEmpty
                ? EmptyHint(
                    icon: Icons.public_off_rounded,
                    title: l10n.t('catalogEmpty'),
                    body: l10n.t('peerCatalogHint'),
                    action: FilledButton.tonalIcon(
                      onPressed: state.loadCandidates,
                      icon: const Icon(Icons.download_rounded),
                      label: Text(l10n.t('catalogLoad')),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final peer = filtered[index];
                      final result = results[peer.uri];
                      final isAdded =
                          added.contains(peer.uri) ||
                          addedHosts.contains(peer.host);
                      return _CatalogRow(
                        peer: peer,
                        result: result,
                        added: isAdded,
                        testing: state.probingUris.contains(peer.uri),
                        l10n: l10n,
                        onTest: () => state.probeUris([peer.uri]),
                        onAdd: () => _add(context, state, peer.uri),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  static String _countryName(String slug) {
    final name = countryName(slug);
    return name.isEmpty ? slug.toUpperCase() : name;
  }

  static List<({String slug, int count})> _countries(
    List<PeerCandidate> peers,
  ) {
    final counts = <String, int>{};
    for (final peer in peers) {
      if (peer.country.isEmpty) continue;
      counts[peer.country] = (counts[peer.country] ?? 0) + 1;
    }
    final list = [
      for (final entry in counts.entries) (slug: entry.key, count: entry.value),
    ];
    list.sort((a, b) => _countryName(a.slug).compareTo(_countryName(b.slug)));
    return list;
  }

  static Future<void> _add(
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

class _CatalogRow extends StatelessWidget {
  const _CatalogRow({
    required this.peer,
    required this.result,
    required this.added,
    required this.testing,
    required this.l10n,
    required this.onTest,
    required this.onAdd,
  });

  final PeerCandidate peer;
  final ProbeResult? result;
  final bool added;

  /// True while this exact peer is being measured.
  final bool testing;
  final L10n l10n;
  final VoidCallback onTest;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final place = [
      if (peer.city.isNotEmpty) peer.city,
      if (peer.country.isNotEmpty) countryName(peer.country),
    ].join(', ');
    final up = result?.up ?? false;
    final latency = result?.latencyMs ?? 0;
    // A catalog entry is never "connected": the probe only proves it answers.
    // Green is reserved for a live tunnel link, teal for a reachable node and
    // red for one that failed the handshake.
    final color = result == null
        ? theme.colorScheme.onSurfaceVariant
        : up
        ? VpnStatusUi.peerColorOf(PeerState.online)
        : VpnStatusUi.peerColorOf(PeerState.offline);
    final latencyText = testing
        ? l10n.t('peerTesting')
        : result == null
        ? l10n.t('notTested')
        : up
        ? formatLatency(latency)
        : l10n.t('probeFailed');

    return Container(
      decoration: testing
          ? BoxDecoration(
              color: theme.colorScheme.secondary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      child: ListTile(
        onTap: added || testing ? null : onTest,
        leading: FlagBadge(flag: countryFlag(peer.country)),
        title: Text(
          place.isEmpty ? peer.host : place,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              shortUri(peer.uri),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${peer.scheme}:${peer.port}',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                if (peer.port == 443) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.verified_user_outlined,
                    size: 12,
                    color: AppColors.teal,
                  ),
                ],
              ],
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
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (testing) ...[
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.8),
                      ),
                      const SizedBox(width: 5),
                    ],
                    Text(
                      latencyText,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: testing ? theme.colorScheme.secondary : color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                if (!testing &&
                    result?.tcpRttMs != null &&
                    result!.tcpRttMs > 0)
                  Text(
                    'TCP ${formatLatency(result!.tcpRttMs)}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            IconButton(
              tooltip: added ? l10n.t('alreadyAdded') : l10n.t('addToTunnel'),
              onPressed: added ? null : onAdd,
              icon: Icon(
                added
                    ? Icons.check_circle_rounded
                    : Icons.add_circle_outline_rounded,
                size: 22,
                color: added ? AppColors.online : theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
