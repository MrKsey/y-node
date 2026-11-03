import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../data/geo.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'widgets.dart';

/// First run: what the app is, the identity of this node and the first three
/// peers.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_page >= 2) {
      _finish();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _back() {
    _controller.previousPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _finish() async {
    final state = context.read<AppState>();
    await state.setOnboarded();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = state.l10n;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('appName')),
        actions: [TextButton(onPressed: _finish, child: Text(l10n.t('skip')))],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (index) => setState(() => _page = index),
                children: [
                  _WelcomePage(l10n: l10n),
                  _IdentityPage(state: state, l10n: l10n),
                  _PeersPage(state: state, l10n: l10n, onSkip: _finish),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var index = 0; index < 3; index++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: index == _page ? 22 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: index == _page
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Row(
                children: [
                  if (_page > 0)
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _back,
                        child: Text(l10n.t('back')),
                      ),
                    ),
                  if (_page > 0) const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _next,
                      child: Text(
                        _page >= 2
                            ? l10n.t('onboardingFinish')
                            : l10n.t('next'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({
    required this.icon,
    required this.title,
    required this.body,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      children: [
        Center(
          child: Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.tealSoft, AppColors.tealDeep],
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.teal.withValues(alpha: 0.28),
                  blurRadius: 26,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Icon(icon, size: 44, color: Colors.white),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          body,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 24),
        child,
      ],
    );
  }
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage({required this.l10n});

  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    return _Page(
      icon: Icons.hub_rounded,
      title: l10n.t('onboardingWelcomeTitle'),
      body: l10n.t('onboardingWelcomeBody'),
      child: Card(
        child: Column(
          children: [
            for (final entry in [
              (Icons.lock_outline_rounded, l10n.t('splitDescription')),
              (Icons.dns_outlined, l10n.t('dnsHint')),
              (Icons.battery_charging_full_rounded, l10n.t('energySavingHint')),
            ])
              ListTile(
                leading: Icon(entry.$1, size: 20),
                title: Text(
                  entry.$2,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _IdentityPage extends StatelessWidget {
  const _IdentityPage({required this.state, required this.l10n});

  final AppState state;
  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    final identity = state.identity;
    return _Page(
      icon: Icons.fingerprint_rounded,
      title: l10n.t('onboardingIdentityTitle'),
      body: l10n.t('onboardingIdentityBody'),
      child: identity == null
          ? const Center(child: CircularProgressIndicator())
          : Card(
              child: Column(
                children: [
                  InfoRow(
                    label: l10n.t('yggAddress'),
                    value: identity.address,
                    monospace: true,
                  ),
                  InfoRow(
                    label: l10n.t('yourKey'),
                    value: identity.publicKey,
                    monospace: true,
                  ),
                ],
              ),
            ),
    );
  }
}

class _PeersPage extends StatelessWidget {
  const _PeersPage({
    required this.state,
    required this.l10n,
    required this.onSkip,
  });

  final AppState state;
  final L10n l10n;
  final VoidCallback onSkip;

  String get _phase {
    final progress = state.probeProgress;
    if (progress == null) return l10n.t('onboardingSearching');
    return switch (progress.phase) {
      'preparing' => l10n.t('probePreparing'),
      'downloading' => l10n.t('probeDownloading'),
      'tcp' => l10n.t('probeTcp'),
      'ygg' => l10n.t('probeYgg'),
      _ => l10n.t('onboardingSearching'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasPeers = state.peers.isNotEmpty;

    return _Page(
      icon: Icons.radar_rounded,
      title: l10n.t('onboardingPeersTitle'),
      body: l10n.t('onboardingPeersBody'),
      child: Column(
        children: [
          if (state.detectedCity.isNotEmpty || state.countrySlug.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FlagBadge(flag: countryFlag(state.countrySlug), size: 26),
                  const SizedBox(width: 8),
                  Text(
                    [
                      if (state.detectedCity.isNotEmpty) state.detectedCity,
                      if (state.countrySlug.isNotEmpty)
                        countryName(state.countrySlug),
                    ].join(', '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          if (state.probing) ...[
            LinearProgressIndicator(
              value:
                  state.probeProgress?.phase == 'ygg' &&
                      (state.probeProgress?.total ?? 0) > 0
                  ? state.probeProgress!.fraction
                  : null,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
            const SizedBox(height: 12),
            Text(_phase, style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(
              l10n.tf('onboardingFound', [state.probeAlive.length]),
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.online,
                fontWeight: FontWeight.w600,
              ),
            ),
          ] else if (hasPeers)
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(
                      Icons.check_circle_rounded,
                      color: AppColors.online,
                    ),
                    title: Text(
                      l10n.tf('peerCountLabel', [state.publicPeerCount]),
                    ),
                    subtitle: Text(
                      l10n.t('peerAdded'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  for (final peer in state.peers)
                    ListTile(
                      leading: FlagBadge(
                        flag: countryFlag(peer.country),
                        size: 28,
                      ),
                      title: Text(
                        peer.city.isEmpty
                            ? countryName(peer.country)
                            : peer.city,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text(
                        countryName(peer.country),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            )
          else
            FilledButton.icon(
              onPressed: () => state.probePeers(),
              icon: const Icon(Icons.search_rounded),
              label: Text(l10n.t('findPeers')),
            ),
          if (!state.probing && state.probeAlive.isNotEmpty && !hasPeers) ...[
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () => state.addBestPeers(),
              icon: const Icon(Icons.auto_awesome_rounded, size: 18),
              label: Text(l10n.tf('addBestN', [state.settings.peerCount])),
            ),
          ],
          if (!state.probing && !hasPeers) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: onSkip,
              child: Text(l10n.t('onboardingSkipPeers')),
            ),
          ],
        ],
      ),
    );
  }
}
