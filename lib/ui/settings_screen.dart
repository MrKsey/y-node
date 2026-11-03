import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import '../data/models.dart';
import '../data/native.dart';
import '../data/wiki.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'log_screen.dart';
import 'widgets.dart';

/// The single connection configuration, plus everything around it: DNS, power
/// saving, logs, appearance and the about block.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = state.l10n;
    final settings = state.settings;

    Future<void> save(AppSettings next) => state.saveSettings(next);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('settingsTitle'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
        children: [
          SectionCard(
            title: l10n.t('sectionConnection'),
            children: [
              _SliderTile(
                label: l10n.t('peerCount'),
                hint: l10n.t('peerCountHint'),
                value: settings.peerCount.toDouble(),
                min: 1,
                max: 20,
                divisions: 19,
                display: '${settings.peerCount}',
                onChanged: (value) =>
                    save(settings.copyWith(peerCount: value.round())),
              ),
              const Divider(height: 1),
              SwitchListTile(
                value: settings.autoReplace,
                onChanged: (value) =>
                    save(settings.copyWith(autoReplace: value)),
                title: Text(l10n.t('autoReplace')),
                subtitle: Text(
                  l10n.t('autoReplaceHint'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const Divider(height: 1),
              _SliderTile(
                label: l10n.t('deadTimeout'),
                value: settings.deadPeerTimeoutSec.toDouble(),
                min: 15,
                max: 300,
                divisions: 57,
                display: '${settings.deadPeerTimeoutSec} ${l10n.t('seconds')}',
                onChanged: (value) =>
                    save(settings.copyWith(deadPeerTimeoutSec: value.round())),
              ),
              _SliderTile(
                label: l10n.t('healthCheck'),
                value: settings.healthCheckSec.toDouble(),
                min: 5,
                max: 120,
                divisions: 23,
                display: '${settings.healthCheckSec} ${l10n.t('seconds')}',
                onChanged: (value) =>
                    save(settings.copyWith(healthCheckSec: value.round())),
              ),
            ],
          ),
          SectionCard(
            title: l10n.t('sectionDns'),
            subtitle: l10n.t('dnsHint'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      alignment: Alignment.center,
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: [
                      ButtonSegment(
                        value: DnsMode.yggdrasil,
                        label: Text(
                          l10n.t('dnsYggdrasil'),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      ButtonSegment(
                        value: DnsMode.system,
                        label: Text(
                          l10n.t('dnsSystem'),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                    selected: {
                      settings.dnsMode == DnsMode.system
                          ? DnsMode.system
                          : DnsMode.yggdrasil,
                    },
                    onSelectionChanged: (value) {
                      final mode = value.first;
                      var servers = settings.dnsServers;
                      if (mode == DnsMode.yggdrasil && servers.isEmpty) {
                        servers = AppSettings.defaultDnsServers;
                      }
                      save(
                        settings.copyWith(dnsMode: mode, dnsServers: servers),
                      );
                      // A mode change has to be measured again: the previous
                      // result belonged to the other resolver.
                      state.resetDnsVerification();
                    },
                  ),
                ),
              ),
              if (settings.dnsMode != DnsMode.system) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          state.dnsReady
                              ? l10n.t('dnsAutoHint')
                              : state.isConnected
                              ? l10n.t('dnsWaitingPeers')
                              : l10n.t('dnsNeedTunnel'),
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: state.dnsReady && !state.checkingDns
                            ? () => state.verifyDns(replaceDead: false)
                            : null,
                        icon: state.checkingDns
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.network_check_rounded, size: 18),
                        label: Text(
                          state.checkingDns
                              ? l10n.t('dnsChecking')
                              : l10n.t('dnsCheck'),
                        ),
                      ),
                    ],
                  ),
                ),
                if (state.dnsReplaced.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Text(
                      l10n.tf('dnsReplaced', [state.dnsReplaced.join(', ')]),
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: AppColors.copper),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
                  child: Text(
                    l10n.t('dnsInUse').toUpperCase(),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      letterSpacing: 0.6,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                  ),
                ),
                for (final server in settings.dnsServers)
                  _DnsServerTile(
                    server: server,
                    label: _dnsLabel(state, server),
                    check: state.dnsChecks[server],
                    l10n: l10n,
                    trailing: IconButton(
                      tooltip: l10n.t('remove'),
                      onPressed: () {
                        state.dismissDnsDead(server);
                        save(
                          settings.copyWith(
                            dnsServers: [
                              for (final item in settings.dnsServers)
                                if (item != server) item,
                            ],
                          ),
                        );
                      },
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
                  ),
                if (state.dnsDead.any(
                  (server) => !settings.dnsServers.contains(server),
                )) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
                    child: Text(
                      l10n.t('dnsNotWorkingTitle').toUpperCase(),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        letterSpacing: 0.6,
                        fontWeight: FontWeight.w700,
                        color: AppColors.offline,
                      ),
                    ),
                  ),
                  for (final server in state.dnsDead)
                    if (!settings.dnsServers.contains(server))
                      _DnsServerTile(
                        server: server,
                        label: _dnsLabel(state, server),
                        check: state.dnsChecks[server],
                        l10n: l10n,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: l10n.t('add'),
                              onPressed: () {
                                save(
                                  settings.copyWith(
                                    dnsServers: [
                                      ...settings.dnsServers,
                                      server,
                                    ],
                                  ),
                                );
                                // The tunnel is already up: measure the server
                                // now instead of waiting for the next full run.
                                state.checkDnsServer(server);
                              },
                              icon: const Icon(Icons.add_rounded, size: 20),
                            ),
                            IconButton(
                              tooltip: l10n.t('dnsForget'),
                              onPressed: () => state.dismissDnsDead(server),
                              icon: const Icon(Icons.close_rounded, size: 18),
                            ),
                          ],
                        ),
                      ),
                ],
                if (settings.dnsServers.isEmpty && state.dnsDead.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Text(
                      l10n.t('dnsAllDead'),
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: AppColors.offline),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _addDns(context, state),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: Text(l10n.t('dnsAddServer')),
                        ),
                      ),
                    ],
                  ),
                ),
                if (settings.dnsMode == DnsMode.yggdrasil) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
                    child: Text(
                      l10n.t('dnsAvailable').toUpperCase(),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        letterSpacing: 0.6,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                    ),
                  ),
                  _DnsPresets(
                    presets: state.dnsPresets,
                    selected: settings.dnsServers,
                    hidden: state.dnsDead,
                    checks: state.dnsChecks,
                    l10n: l10n,
                    onAdd: (address) {
                      if (settings.dnsServers.contains(address)) return;
                      save(
                        settings.copyWith(
                          dnsServers: [...settings.dnsServers, address],
                        ),
                      );
                      // A running tunnel picks the new server up in the UI at
                      // once; the check proves whether it actually resolves.
                      state.checkDnsServer(address);
                    },
                  ),
                ],
              ],
            ],
          ),
          SectionCard(
            title: l10n.t('sectionNetwork'),
            children: [
              _SliderTile(
                label: l10n.t('mtu'),
                hint: l10n.t('mtuHint'),
                value: settings.mtu.toDouble().clamp(1280, 1500),
                min: 1280,
                max: 1500,
                divisions: 22,
                display: '${settings.mtu}',
                onChanged: (value) =>
                    save(settings.copyWith(mtu: value.round())),
              ),
            ],
          ),
          SectionCard(
            title: l10n.t('sectionPower'),
            children: [
              SwitchListTile(
                value: settings.energySaving,
                secondary: const Icon(Icons.battery_saver_rounded),
                onChanged: (value) =>
                    save(settings.copyWith(energySaving: value)),
                title: Text(l10n.t('energySaving')),
                subtitle: Text(
                  l10n.t('energySavingHint'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const Divider(height: 1),
              // The exemption is a switch, as in SoftSSTP: turning it on asks
              // Android for the exemption, turning it off opens the system list
              // where the user has to remove it by hand.
              SwitchListTile(
                value: state.batteryExempt,
                secondary: Icon(
                  state.batteryExempt
                      ? Icons.battery_charging_full_rounded
                      : Icons.battery_alert_rounded,
                  color: state.batteryExempt ? AppColors.online : null,
                ),
                title: Text(l10n.t('batteryExemption')),
                subtitle: Text(
                  state.batteryExempt
                      ? l10n.t('batteryOn')
                      : l10n.t('batteryOff'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                onChanged: (value) async {
                  if (value) {
                    await Native.requestBatteryExemption();
                  } else {
                    await Native.openBatteryOptimizationList();
                  }
                  await Future<void>.delayed(const Duration(milliseconds: 800));
                  await state.refreshBattery();
                },
              ),

              if (!state.notificationsAllowed) ...[
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.notifications_off_outlined),
                  title: Text(l10n.t('notifications')),
                  subtitle: Text(
                    l10n.t('notificationsHint'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: TextButton(
                    onPressed: () async {
                      await Native.requestNotifications();
                      await state.refreshBattery();
                    },
                    child: Text(l10n.t('notificationsRequest')),
                  ),
                ),
              ],
            ],
          ),
          SectionCard(
            title: l10n.t('sectionLogs'),
            children: [
              SwitchListTile(
                value: settings.logging,
                onChanged: (value) async {
                  await save(settings.copyWith(logging: value));
                  await Native.setLogging(value);
                },
                title: Text(l10n.t('logging')),
                subtitle: Text(
                  l10n.t('loggingHint'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.article_outlined),
                title: Text(l10n.t('viewLog')),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const LogScreen()),
                ),
              ),
            ],
          ),
          SectionCard(
            title: l10n.t('sectionAppearance'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.t('theme'),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    SegmentedButton<ThemeMode>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(
                          value: ThemeMode.system,
                          label: Text(l10n.t('themeAuto')),
                        ),
                        ButtonSegment(
                          value: ThemeMode.light,
                          label: Text(l10n.t('themeLight')),
                        ),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          label: Text(l10n.t('themeDark')),
                        ),
                      ],
                      selected: {state.themeMode},
                      onSelectionChanged: (value) =>
                          state.setThemeMode(value.first),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SectionCard(
            title: l10n.t('sectionDonate'),
            subtitle: l10n.t('donateHint'),
            children: [
              for (final donation in _donations)
                ListTile(
                  leading: Image.asset(donation.asset, width: 30, height: 30),
                  title: Text(donation.name),
                  subtitle: Text(
                    donation.address,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  trailing: const Icon(Icons.copy_rounded, size: 16),
                  onTap: () async {
                    await Clipboard.setData(
                      ClipboardData(text: donation.address),
                    );
                    if (context.mounted) {
                      showSnack(
                        context,
                        l10n.tf('donationCopied', [donation.name]),
                      );
                    }
                  },
                ),
            ],
          ),
          SectionCard(
            title: l10n.t('sectionAbout'),
            children: [
              InfoRow(
                label: l10n.t('version'),
                value: state.appVersion.isEmpty ? '—' : state.appVersion,
              ),
              InfoRow(
                label: l10n.t('yggVersion'),
                value: state.yggVersion.isEmpty ? '—' : state.yggVersion,
              ),
              InfoRow(
                label: l10n.t('sourceCode'),
                value: l10n.t('yggSourceHint'),
                onTap: () => _openYggdrasilSource(context, l10n),
              ),
              InfoRow(label: l10n.t('license'), value: 'GPL-3.0'),
            ],
          ),
        ],
      ),
    );
  }

  static String? _dnsLabel(AppState state, String address) {
    for (final preset in state.dnsPresets) {
      if (preset.address == address) {
        return [
          preset.location,
          preset.note,
        ].where((part) => part.isNotEmpty).join(' · ');
      }
    }
    return null;
  }

  static Future<void> _openYggdrasilSource(
    BuildContext context,
    L10n l10n,
  ) async {
    final opened = await launchUrl(
      Uri.parse('https://github.com/yggdrasil-network/yggdrasil-go'),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && context.mounted) {
      showSnack(context, l10n.t('linkFailed'));
    }
  }

  Future<void> _addDns(BuildContext context, AppState state) async {
    final l10n = state.l10n;
    final controller = TextEditingController();
    String? error;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocalState) => AlertDialog(
          title: Text(l10n.t('dnsAddServer')),
          content: TextField(
            controller: controller,
            autofocus: true,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: l10n.t('dnsServers'),
              hintText: '308:84:68:55::',
              errorText: error == null ? null : l10n.t(error!),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.t('cancel')),
            ),
            FilledButton(
              onPressed: () async {
                final value = controller.text.trim();
                if (!_validDns(value)) {
                  setLocalState(() => error = 'dnsInvalid');
                  return;
                }
                if (state.settings.dnsServers.contains(value)) {
                  setLocalState(() => error = 'peerAlreadyExists');
                  return;
                }
                await state.saveSettings(
                  state.settings.copyWith(
                    dnsServers: [...state.settings.dnsServers, value],
                  ),
                );
                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                // With the tunnel up the new server is tested right away.
                await state.checkDnsServer(value);
              },
              child: Text(l10n.t('add')),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }

  static bool _validDns(String value) {
    if (!value.contains(':')) return false;
    try {
      Uri.parseIPv6Address(value);
      return true;
    } on FormatException {
      return false;
    }
  }
}

class _Donation {
  const _Donation(this.name, this.address, this.asset);

  final String name;
  final String address;
  final String asset;
}

/// The same four addresses the SoftSSTP donate block shows.
const List<_Donation> _donations = [
  _Donation(
    'Bitcoin',
    'bc1qdf9wryj6tnyyr7ed4dkfv03nn0dxjf27xshfcr',
    'assets/images/bitcoin.png',
  ),
  _Donation(
    'Ethereum',
    '0xE22FAB5337A5506D9e7Ef9D4914De4d963Fbbf88',
    'assets/images/ethereum.png',
  ),
  _Donation(
    'Solana',
    '7XcNM2M9rndFbJdjRtyycxkQXq8dPXEP87toiQX4EZfx',
    'assets/images/solana.png',
  ),
  _Donation(
    'Tron',
    'TCYpTxSmdPNp4fmRwtPGk3HHBf77FypeA',
    'assets/images/tron.png',
  ),
];

/// One DNS server row: address, human description and the result of the last
/// resolution check (the name it resolved and how long it took).
class _DnsServerTile extends StatelessWidget {
  const _DnsServerTile({
    required this.server,
    required this.label,
    required this.check,
    required this.l10n,
    this.trailing,
  });

  final String server;
  final String? label;
  final DnsCheck? check;
  final L10n l10n;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = check != null && !check!.ok;
    final ok = check?.ok ?? false;
    final color = check == null
        ? theme.colorScheme.onSurfaceVariant
        : ok
        ? AppColors.online
        : AppColors.offline;

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      leading: Icon(
        check == null
            ? Icons.dns_outlined
            : ok
            ? Icons.check_circle_rounded
            : Icons.error_outline_rounded,
        size: 20,
        color: color,
      ),
      title: Text(
        server,
        style: TextStyle(
          fontFamily: 'monospace',
          color: failed ? AppColors.offline : null,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null && label!.isNotEmpty)
            Text(label!, style: theme.textTheme.bodySmall),
          if (check != null)
            Text(
              ok
                  ? (check!.via == 'tcp'
                        ? l10n.tf('dnsOkTcp', [check!.ms.round()])
                        : l10n.tf('dnsOk', [check!.ms.round()]))
                  : l10n.t('dnsNotWorking'),
              style: theme.textTheme.labelSmall?.copyWith(color: color),
            ),
          if (ok && check!.address.isNotEmpty)
            Text(
              l10n.tf('dnsAnswer', [check!.name, check!.address]),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
      trailing: trailing,
    );
  }
}

class _DnsPresets extends StatelessWidget {
  const _DnsPresets({
    required this.presets,
    required this.selected,
    required this.hidden,
    required this.checks,
    required this.l10n,
    required this.onAdd,
  });

  final List<DnsPreset> presets;
  final List<String> selected;

  /// Servers shown in the dead block already; they are not repeated here.
  final List<String> hidden;
  final Map<String, DnsCheck> checks;
  final L10n l10n;
  final void Function(String address) onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = presets
        .where(
          (preset) =>
              !preset.deprecated &&
              !selected.contains(preset.address) &&
              !hidden.contains(preset.address),
        )
        .toList();
    if (available.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Text(
          l10n.t('dnsAvailableHint'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final preset in available)
          _DnsServerTile(
            server: preset.address,
            label: [
              preset.location,
              preset.note,
            ].where((part) => part.isNotEmpty).join(' · '),
            check: checks[preset.address],
            l10n: l10n,
            trailing: IconButton(
              tooltip: l10n.t('add'),
              onPressed: () => onAdd(preset.address),
              icon: const Icon(Icons.add_rounded, size: 20),
            ),
          ),
      ],
    );
  }
}

/// A labelled slider that only writes to the store when the drag ends.
class _SliderTile extends StatefulWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
    this.hint,
  });

  final String label;
  final String? hint;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final void Function(double value) onChanged;

  @override
  State<_SliderTile> createState() => _SliderTileState();
}

class _SliderTileState extends State<_SliderTile> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = (_dragging ?? widget.value).clamp(widget.min, widget.max);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(widget.label, style: theme.textTheme.bodyMedium),
              ),
              Text(
                _dragging == null ? widget.display : value.round().toString(),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.secondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          Slider(
            value: value,
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            onChanged: (next) => setState(() => _dragging = next),
            onChangeEnd: (next) {
              setState(() => _dragging = null);
              widget.onChanged(next);
            },
          ),
          if (widget.hint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                widget.hint!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
