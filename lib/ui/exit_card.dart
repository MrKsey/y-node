import 'package:flutter/material.dart';

import '../core/format.dart';
import '../data/models.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'exit_profiles_screen.dart';
import 'status_ui.dart';
import 'widgets.dart';

/// The Exit node card on the tunnel screen.
class ExitNodeCard extends StatelessWidget {
  const ExitNodeCard({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final l10n = state.l10n;
    final theme = Theme.of(context);
    final settings = state.settings;
    final status = state.exitStatus;
    final uiState = ExitStatusUi.stateOf(
      enabled: settings.exitEnabled,
      profileCount: settings.exitProfiles.length,
      snapshot: state.snapshot,
      status: status,
      fallbackDirect: settings.exitFallbackDirect,
    );
    final active = status.active;
    final quota = active?.quota;
    final suspended = active?.suspended ?? false;
    // A suspension does not take the exit offline: the status API still
    // answers, only new connections are refused. The pill names the state; the
    // tunnel screen highlights the exit icon itself.
    final pillColor = suspended ? Colors.orange : ExitStatusUi.color(uiState);
    final activeProfile = settings.exitActiveProfile;
    // Both self-check rows describe the live tunnel: the relay association and
    // the IPv6 path only exist while the data path is running. Without the
    // tunnel they would show stale counters and buttons that cannot work, so
    // the card keeps only the exit switch and the profile controls.
    final live = state.snapshot.isConnected;
    // The profile's pinned peer is the direct link to the exit node. When that
    // link is up the route to the exit never leaves the two nodes.
    final direct =
        activeProfile != null &&
        activeProfile.peer.isNotEmpty &&
        (state.statusByUri[activeProfile.peer]?.up ?? false);
    final detail = switch (uiState) {
      ExitUiState.off => l10n.t('exitCardOffHint'),
      ExitUiState.noProfile => l10n.t('exitCardNoProfileHint'),
      ExitUiState.connecting => l10n.t('exitCardConnectingHint'),
      ExitUiState.online =>
        l10n.tf('exitCardOnlineHint', [
              active?.name.isNotEmpty == true
                  ? active!.name
                  : (settings.exitActiveProfile?.title ?? ''),
              (active?.latencyMs ?? 0).toStringAsFixed(0),
            ]) +
            (direct ? ' · ${l10n.t('exitCardDirect')}' : ''),
      ExitUiState.degraded => l10n.t('exitCardDegradedHint'),
      ExitUiState.fallback => l10n.t('exitCardFallbackHint'),
      ExitUiState.denied => l10n.t('exitCardDeniedHint'),
      ExitUiState.unreachable => l10n.t('exitCardUnreachableHint'),
    };

    return SectionCard(
      title: l10n.t('exitNode'),
      children: [
        ListTile(
          contentPadding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          leading: CircleAvatar(
            backgroundColor: ExitStatusUi.color(uiState)
                .withValues(alpha: 0.14),
            child: Icon(
              Icons.vpn_lock_rounded,
              color: ExitStatusUi.color(uiState),
            ),
          ),
          title: Row(
            children: [
              Text(l10n.t('exitNode')),
              const SizedBox(width: 8),
              StatusPill(
                label: suspended
                    ? l10n.t('exitSuspendedShort')
                    : ExitStatusUi.label(uiState, l10n),
                color: pillColor,
              ),
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(detail),
          ),
          trailing: Switch(
            value: settings.exitEnabled,
            onChanged: settings.exitProfiles.isEmpty
                ? null
                : state.setExitEnabled,
          ),
        ),
        if (live && settings.exitActive && (active?.limited ?? false))
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            leading: const Icon(
              Icons.lock_outline_rounded,
              size: 20,
              color: Colors.orange,
            ),
            title: Text(
              l10n.t('exitApiLimited'),
              style: theme.textTheme.bodyMedium,
            ),
            subtitle: Text(
              l10n.t('exitApiLimitedHint'),
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (live && settings.exitActive && suspended)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            leading: const Icon(
              Icons.pause_circle_outline_rounded,
              size: 20,
              color: Colors.orange,
            ),
            title: Text(
              l10n.t('exitSuspended'),
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.orange),
            ),
            subtitle: Text(
              l10n.t('exitSuspendedHint'),
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (live && settings.exitActive && quota != null && !quota.isUnlimited)
          _QuotaRow(quota: quota, l10n: l10n),
        if (live && settings.exitActive && status.udp.enabled)
          _UdpRow(
            udp: status.udp,
            profile: status.active,
            state: state,
            l10n: l10n,
          ),
        if (live && settings.exitActive)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
            leading: Icon(
              Icons.language_rounded,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            title: Text(
              l10n.t('exitIpv6Title'),
              style: theme.textTheme.bodyMedium,
            ),
            subtitle: Text(
              l10n.t('exitIpv6Hint'),
              style: theme.textTheme.bodySmall,
            ),
            trailing: IconButton(
              tooltip: l10n.t('exitIpv6Test'),
              onPressed: state.testingIpv6 ? null : () => _testIpv6(context),
              icon: state.testingIpv6
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.travel_explore, size: 20),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: () => _open(context),
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: Text(l10n.t('exitManage')),
              ),
              const Spacer(),
              if (state.snapshot.isConnected && settings.exitActive)
                TextButton.icon(
                  onPressed: state.checkingExit ? null : () => _check(context),
                  icon: state.checkingExit
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(
                    state.checkingExit
                        ? l10n.t('exitChecking')
                        : l10n.t('exitCheckNow'),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  void _open(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ExitProfilesScreen()));
  }

  Future<void> _check(BuildContext context) async {
    final l10n = state.l10n;
    final result = await state.checkExitProfiles();
    if (!context.mounted) return;
    showSnack(
      context,
      l10n.t(result == null ? 'exitCheckFailed' : 'exitChecked'),
    );
  }

  Future<void> _testIpv6(BuildContext context) async {
    final l10n = state.l10n;
    final result = await state.testExitIpv6();
    if (!context.mounted) return;
    if (result == null) {
      showSnack(context, l10n.t('exitIpv6TestFailed'));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _Ipv6ProbeDialog(result: result, l10n: l10n),
    );
  }
}

/// The traffic quota and speed limits the exit applies to this client.
class _QuotaRow extends StatelessWidget {
  const _QuotaRow({required this.quota, required this.l10n});

  final ExitQuota quota;
  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final exhausted = quota.exhausted;
    final color = exhausted ? Colors.orange : theme.colorScheme.primary;
    final style = theme.textTheme.bodySmall?.copyWith(color: color);
    final cap = quota.tightestCap;
    final percent = cap == null
        ? null
        : ((cap.used / cap.limit) * 100).clamp(0, 100).round();
    final lines = <Widget>[
      if (quota.monthlyBytes > 0)
        Text(
          l10n.tf('exitQuotaMonth', [
            formatQuotaBytes(quota.monthUsed),
            formatQuotaBytes(quota.monthlyBytes),
          ]),
          style: style,
        ),
      if (quota.dailyBytes > 0)
        Text(
          l10n.tf('exitQuotaDay', [
            formatQuotaBytes(quota.dayUsed),
            formatQuotaBytes(quota.dailyBytes),
          ]),
          style: style,
        ),
      if (quota.hasSpeedLimit)
        Text(
          [
            if (quota.downKbps > 0)
              l10n.tf('exitQuotaDown', [formatBitRate(quota.downKbps)]),
            if (quota.upKbps > 0)
              l10n.tf('exitQuotaUp', [formatBitRate(quota.upKbps)]),
          ].join(' · '),
          style: style,
        ),
      if (exhausted) ...[
        Text(
          _reason(),
          style: theme.textTheme.bodySmall?.copyWith(color: Colors.orange),
        ),
        Text(
          l10n.t('exitQuotaExhaustedHint'),
          style: theme.textTheme.bodySmall,
        ),
      ],
    ];
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      leading: Icon(Icons.data_usage_rounded, size: 20, color: color),
      title: Row(
        children: [
          Text(l10n.t('exitQuotaTitle'), style: theme.textTheme.bodyMedium),
          if (exhausted) ...[
            const SizedBox(width: 8),
            StatusPill(
              label: l10n.t('exitQuotaExhaustedShort'),
              color: Colors.orange,
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: lines,
      ),
      trailing: percent == null ? null : Text('$percent%', style: style),
      isThreeLine: lines.length > 1,
    );
  }

  String _reason() {
    switch (quota.reason) {
      case 'daily quota exhausted':
        return l10n.t('exitQuotaDailyExhausted');
      case 'monthly quota exhausted':
        return l10n.t('exitQuotaMonthlyExhausted');
      default:
        return quota.reason.isEmpty
            ? l10n.t('exitQuotaExhausted')
            : quota.reason;
    }
  }
}

/// One line about the UDP relay of the exit: DNS and QUIC depend on it.
class _UdpRow extends StatelessWidget {
  const _UdpRow({
    required this.udp,
    required this.profile,
    required this.state,
    required this.l10n,
  });

  final ExitUdpStatus udp;
  final ExitProfileStatus? profile;
  final AppState state;
  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (udp.state) {
      'online' => Colors.green,
      'error' => Colors.orange,
      _ => theme.colorScheme.outline,
    };
    final detail = switch (udp.state) {
      'online' => l10n.tf('exitUdpOnline', [
        udp.profileName.isEmpty ? l10n.t('exitUdpTitle') : udp.profileName,
      ]),
      'idle' => l10n.t('exitUdpIdle'),
      'error' => l10n.tf('exitUdpError', [udp.error]),
      _ => l10n.t('exitUdpOff'),
    };
    // The counters are short on purpose: arrows instead of the words "in" and
    // "out", so the line fits a 360 dp screen. The full wording stays in the
    // semantics label for a screen reader, and the tooltip explains the
    // arrows.
    final traffic = udp.datagramsIn + udp.datagramsOut > 0
        ? l10n.tf('exitUdpTraffic', [
            '${udp.datagramsIn}',
            formatBytes(udp.bytesIn),
            '${udp.datagramsOut}',
            formatBytes(udp.bytesOut),
          ])
        : null;
    final trafficSpoken = udp.datagramsIn + udp.datagramsOut > 0
        ? l10n.tf('exitUdpTrafficFull', [
            '${udp.datagramsIn}',
            formatBytes(udp.bytesIn),
            '${udp.datagramsOut}',
            formatBytes(udp.bytesOut),
          ])
        : null;
    final load = profile;
    final counterStyle = theme.textTheme.bodySmall?.copyWith(color: color);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
          leading: Icon(Icons.swap_vert_rounded, size: 20, color: color),
          title: Text(
            l10n.t('exitUdpTitle'),
            style: theme.textTheme.bodyMedium,
          ),
          subtitle: Semantics(
            label: trafficSpoken == null ? detail : '$detail. $trafficSpoken',
            excludeSemantics: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(detail, style: counterStyle),
                if (traffic != null)
                  // Never wraps and never truncates: a wide number shrinks the
                  // line instead of pushing "out" to a third row. The tooltip
                  // explains what the two numbers are.
                  Tooltip(
                    message: l10n.t('exitUdpTrafficHint'),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        traffic,
                        maxLines: 1,
                        softWrap: false,
                        style: counterStyle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          isThreeLine: traffic != null,
          trailing: IconButton(
            tooltip: l10n.t('exitUdpTest'),
            onPressed: state.testingUdp ? null : () => _test(context),
            icon: state.testingUdp
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.science_outlined, size: 20),
          ),
        ),
        if (load != null && load.hitLimit && !load.quotaExhausted)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            leading: const Icon(
              Icons.warning_amber_rounded,
              size: 20,
              color: Colors.orange,
            ),
            title: Text(
              load.maxConns > 0
                  ? l10n.tf('exitUdpLimit', [
                      '${load.refused}',
                      '${load.maxConns}',
                    ])
                  : l10n.tf('exitUdpLimitNoMax', ['${load.refused}']),
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.orange),
            ),
            subtitle: Text(
              l10n.t('exitUdpLimitHint'),
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Future<void> _test(BuildContext context) async {
    final result = await state.testExitUdp();
    if (!context.mounted) return;
    if (result == null) {
      showSnack(context, l10n.t('exitUdpTestFailed'));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _UdpProbeDialog(result: result, l10n: l10n),
    );
  }
}

/// The result of the UDP relay self-check: the DNS query and the QUIC
/// handshake, each with its own error when it failed.
class _UdpProbeDialog extends StatelessWidget {
  const _UdpProbeDialog({required this.result, required this.l10n});

  final UdpProbeResult result;
  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(l10n.t('exitUdpTestTitle')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StageRow(
            label: l10n.t('exitUdpTestUdp'),
            ok: result.udp.ok,
            latencyMs: result.udp.latencyMs,
            detail: result.udp.target,
            error: result.udp.error,
            l10n: l10n,
          ),
          const SizedBox(height: 12),
          _StageRow(
            label: l10n.t('exitUdpTestQuic'),
            ok: result.quic.ok,
            latencyMs: result.quic.latencyMs,
            detail: [
              if (result.quic.version.isNotEmpty) 'h3 ${result.quic.version}',
              if (result.quic.target.isNotEmpty) result.quic.target,
            ].join(' · '),
            error: result.quic.error,
            l10n: l10n,
          ),
          const SizedBox(height: 12),
          Text(
            l10n.tf('exitUdpTestTraffic', [
              '${result.datagramsOut}',
              '${result.datagramsIn}',
            ]),
            style: theme.textTheme.bodySmall,
          ),
          if (result.profile.isNotEmpty)
            Text(
              l10n.tf('exitUdpTestThrough', [result.profile]),
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.t('close')),
        ),
      ],
    );
  }
}

/// The result of the IPv6 self-check: TCP over IPv6 and DNS over IPv6, each
/// with its own error when it failed.
class _Ipv6ProbeDialog extends StatelessWidget {
  const _Ipv6ProbeDialog({required this.result, required this.l10n});

  final Ipv6ProbeResult result;
  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(l10n.t('exitIpv6TestTitle')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StageRow(
            label: l10n.t('exitIpv6TestTcp'),
            ok: result.tcp.ok,
            skipped: result.tcp.skipped,
            latencyMs: result.tcp.latencyMs,
            detail: result.tcp.target,
            error: result.tcp.error,
            l10n: l10n,
          ),
          const SizedBox(height: 12),
          _StageRow(
            label: l10n.t('exitIpv6TestUdp'),
            ok: result.udp.ok,
            skipped: result.udp.skipped,
            latencyMs: result.udp.latencyMs,
            detail: result.udp.target,
            error: result.udp.error,
            l10n: l10n,
          ),
          if (result.tcp.address.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              l10n.tf('exitIpv6TestAddress', [result.tcp.address]),
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (result.profile.isNotEmpty)
            Text(
              l10n.tf('exitIpv6TestThrough', [result.profile]),
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.t('close')),
        ),
      ],
    );
  }
}

class _StageRow extends StatelessWidget {
  const _StageRow({
    required this.label,
    required this.ok,
    required this.latencyMs,
    required this.l10n,
    this.skipped = false,
    this.detail = '',
    this.error = '',
  });

  final String label;
  final bool ok;
  final bool skipped;
  final double latencyMs;

  /// The target and protocol details shown after the latency.
  final String detail;
  final String error;
  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = skipped
        ? theme.colorScheme.outline
        : (ok ? Colors.green : Colors.orange);
    final parts = <String>[];
    if (ok) {
      parts.add(l10n.tf('exitUdpTestOk', [latencyMs.toStringAsFixed(0)]));
      if (detail.isNotEmpty) parts.add(detail);
    } else {
      parts.add(error.isEmpty ? l10n.t('exitUdpTestSkipped') : error);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          skipped
              ? Icons.remove_circle_outline
              : (ok ? Icons.check_circle_rounded : Icons.error_outline_rounded),
          size: 20,
          color: color,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.bodyMedium),
              Text(
                parts.join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
