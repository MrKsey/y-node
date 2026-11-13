import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/exit_link.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'exit_link_dialog.dart';
import 'exit_qr_screen.dart';
import 'status_ui.dart';
import 'widgets.dart';

/// The list of exit nodes: add, edit, reorder, select, register and check.
class ExitProfilesScreen extends StatefulWidget {
  const ExitProfilesScreen({super.key});

  @override
  State<ExitProfilesScreen> createState() => _ExitProfilesScreenState();
}

class _ExitProfilesScreenState extends State<ExitProfilesScreen> {
  String? _registering;
  bool _scanning = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = state.l10n;
    final settings = state.settings;
    final status = state.exitStatus;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('exitProfilesTitle')),
        actions: [
          IconButton(
            tooltip: l10n.t('exitScanQr'),
            onPressed: _scanning ? null : () => _scan(state),
            icon: const Icon(Icons.qr_code_scanner_rounded),
          ),
          IconButton(
            tooltip: l10n.t('exitImportLink'),
            onPressed: _scanning ? null : () => _importLink(state),
            icon: const Icon(Icons.link_rounded),
          ),
          IconButton(
            tooltip: l10n.t('exitAddManually'),
            onPressed: () => _add(state),
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (state.exitChangesPending) ...[
            Card(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                child: Row(
                  children: [
                    const Icon(Icons.sync_problem_rounded),
                    const SizedBox(width: 12),
                    Expanded(child: Text(l10n.t('exitReconnectHint'))),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _applyChanges,
                      child: Text(l10n.t('reconnectNow')),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          SectionCard(
            title: l10n.t('exitNode'),
            children: [
              SwitchListTile(
                value: settings.exitEnabled,
                onChanged: settings.exitProfiles.isEmpty
                    ? null
                    : (value) => state.setExitEnabled(value),
                title: Text(l10n.t('exitNode')),
                subtitle: Text(
                  ExitStatusUi.label(
                    ExitStatusUi.stateOf(
                      enabled: settings.exitEnabled,
                      profileCount: settings.exitProfiles.length,
                      snapshot: state.snapshot,
                      status: status,
                      fallbackDirect: settings.exitFallbackDirect,
                    ),
                    l10n,
                  ),
                ),
                secondary: const Icon(Icons.vpn_lock_rounded),
              ),
            ],
          ),
          SectionCard(
            title: l10n.t('exitProfilesTitle'),
            subtitle: l10n.t('exitProfilesHint'),
            children: [
              if (settings.exitProfiles.isEmpty)
                EmptyHint(
                  icon: Icons.dns_outlined,
                  title: l10n.t('exitStateNoProfile'),
                  body: l10n.t('exitCardNoProfileHint'),
                  action: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () => _scan(state),
                        icon: const Icon(Icons.qr_code_scanner_rounded),
                        label: Text(l10n.t('exitScanQr')),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _importLink(state),
                        icon: const Icon(Icons.link_rounded),
                        label: Text(l10n.t('exitImportLink')),
                      ),
                    ],
                  ),
                )
              else
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: settings.exitProfiles.length,
                  onReorderItem: state.reorderExitProfiles,
                  itemBuilder: (context, index) {
                    final profile = settings.exitProfiles[index];
                    final health = _healthOf(status, profile.id);
                    return _ExitRow(
                      key: ValueKey(profile.id),
                      index: index,
                      profile: profile,
                      active:
                          profile.id == (settings.exitActiveProfile?.id ?? ''),
                      health: health,
                      registering: _registering == profile.id,
                      onSetActive: () => state.setExitActive(profile.id),
                      onEdit: () => _edit(state, profile),
                      onRegister: () => _register(state, profile),
                      onRemove: () => _remove(state, profile),
                    );
                  },
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => _scan(state),
                      icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                      label: Text(l10n.t('exitScanQr')),
                    ),
                    IconButton(
                      tooltip: l10n.t('exitImportLink'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _importLink(state),
                      icon: const Icon(Icons.link_rounded, size: 18),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed:
                          state.checkingExit || !state.snapshot.isConnected
                          ? null
                          : () => _check(state),
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
          ),
          SectionCard(
            title: l10n.t('settingsTitle'),
            children: [
              SwitchListTile(
                value: settings.exitFallbackDirect,
                onChanged: state.setExitFallbackDirect,
                title: Text(l10n.t('exitFallbackDirect')),
                subtitle: Text(l10n.t('exitFallbackHint')),
                secondary: const Icon(Icons.alt_route_rounded),
              ),
              SwitchListTile(
                value: settings.exitLocalDns,
                onChanged: state.setExitLocalDns,
                title: Text(l10n.t('exitLocalDns')),
                subtitle: Text(l10n.t('exitLocalDnsHint')),
                secondary: const Icon(Icons.lan_outlined),
              ),
              // The resolver of the exit node is a Yggdrasil DNS server the
              // server publishes for its clients. The switch puts it into the
              // DNS list; the list then locks the entry instead of offering a
              // remove button, because this switch owns it. The switch can be
              // turned on before the exit reports a resolver: the entry is
              // added as soon as the status API carries one.
              SwitchListTile(
                value: settings.exitDnsEnabled,
                onChanged: state.setExitDns,
                title: Text(l10n.t('exitDnsNode')),
                subtitle: Text(
                  state.exitDnsProfile == null
                      ? l10n.t('exitDnsNodeUnavailable')
                      : l10n.t('exitDnsNodeHint'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                secondary: const Icon(Icons.dns_rounded),
              ),
              SwitchListTile(
                value: settings.exitUdp,
                onChanged: (value) => _setUdp(state, value),
                title: Text(l10n.t('exitUdp')),
                subtitle: Text(l10n.t('exitUdpHint')),
                secondary: const Icon(Icons.swap_vert_rounded),
              ),
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(l10n.t('exitDnsTitle')),
                subtitle: Text(
                  settings.exitDnsServers.join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.edit_rounded, size: 18),
                onTap: () => _editDns(state, exitDns: true),
              ),
              ListTile(
                leading: const Icon(Icons.router_outlined),
                title: Text(l10n.t('exitLocalDnsTitle')),
                subtitle: Text(
                  settings.exitLocalDnsServers.isEmpty
                      ? l10n.t('exitDnsSystem')
                      : settings.exitLocalDnsServers.join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.edit_rounded, size: 18),
                onTap: () => _editDns(state, exitDns: false),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static ExitProfileStatus? _healthOf(ExitStatus status, String id) {
    for (final profile in status.profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  Future<void> _applyChanges() async {
    final state = context.read<AppState>();
    final l10n = state.l10n;
    final ok = await state.reconnect();
    if (!mounted) return;
    showSnack(
      context,
      ok ? l10n.t('reconnectDone') : l10n.t('reconnectFailed'),
    );
  }

  /// The relay is opened when the tunnel starts, so the switch restarts it
  /// instead of leaving the old UDP mode in place until the next connect.
  Future<void> _setUdp(AppState state, bool value) async {
    final l10n = state.l10n;
    final wasConnected = state.snapshot.isConnected;
    final ok = await state.setExitUdp(value);
    if (!mounted || !wasConnected) return;
    showSnack(
      context,
      ok
          ? l10n.t('reconnectDone')
          : l10n.t(state.lastError ?? 'reconnectFailed'),
    );
  }

  Future<void> _scan(AppState state) async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final invite = await scanExitInvite(context);
      if (invite == null || !mounted) return;
      await _acceptInvite(state, invite);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// The same invite as the QR code, typed or pasted instead of scanned.
  Future<void> _importLink(AppState state) async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final invite = await showExitLinkDialog(context);
      if (invite == null || !mounted) return;
      await _acceptInvite(state, invite);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _acceptInvite(AppState state, ExitInvite invite) async {
    final l10n = state.l10n;
    await state.addExitProfile(invite.profile);
    if (invite.invite.isEmpty) {
      // A link for a client the exit already allows: there is nothing to
      // redeem. The node is authorised by its Yggdrasil address, so the data
      // path works at once and the profile stays a plain SOCKS5 one until a
      // token is added.
      if (mounted) showSnack(context, l10n.t('exitSocksOnlySaved'));
    } else if (!state.snapshot.isConnected) {
      if (mounted) showSnack(context, l10n.t('exitNeedTunnel'));
      return;
    } else {
      await _register(state, invite.profile, invite: invite.invite);
      if (!mounted) return;
    }
    if (!mounted) return;
    // The first profile switches the exit on by itself, so the question would
    // only ask about something that already happened.
    if (state.settings.exitEnabled) return;
    final enable = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.t('exitUseNode')),
        content: Text(l10n.tf('exitUseNodeBody', [invite.profile.title])),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.t('exitNotNow')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.t('exitEnable')),
          ),
        ],
      ),
    );
    if (enable == true && mounted) {
      await state.setExitEnabled(true);
    }
  }

  Future<void> _add(AppState state) async {
    final profile = await showDialog<ExitProfile>(
      context: context,
      builder: (_) => const _ExitProfileDialog(),
    );
    if (profile == null) return;
    await state.addExitProfile(profile);
    if (!mounted) return;
    final l10n = state.l10n;
    final invite = profile.invite.trim();
    if (invite.isEmpty) {
      showSnack(context, l10n.t('exitSaved'));
      return;
    }
    // The invite is the only thing the server needs besides the source
    // address, so a manual entry redeems it at once. Otherwise the profile
    // stays unregistered until the user finds "Retry registration".
    if (!state.snapshot.isConnected) {
      showSnack(context, l10n.t('exitNeedTunnel'));
      return;
    }
    await _register(state, profile, invite: invite);
  }

  Future<void> _edit(AppState state, ExitProfile profile) async {
    final result = await showDialog<ExitProfile>(
      context: context,
      builder: (_) => _ExitProfileDialog(initial: profile),
    );
    if (result == null) return;
    if (result.id == profile.id) {
      await state.updateExitProfile(result);
    } else {
      await state.removeExitProfile(profile.id);
      await state.addExitProfile(result);
    }
    if (!mounted) return;
    // A profile that was a plain SOCKS5 proxy becomes a full one when an
    // invite is added: redeem it now, exactly like a freshly scanned code.
    final invite = result.invite.trim();
    if (invite.isNotEmpty && invite != profile.invite.trim()) {
      await _register(state, result, invite: invite);
      return;
    }
    showSnack(context, state.l10n.t('exitSaved'));
  }

  Future<void> _register(
    AppState state,
    ExitProfile profile, {
    String? invite,
  }) async {
    final l10n = state.l10n;
    final token = (invite ?? profile.invite).trim();
    if (token.isEmpty) {
      showSnack(context, l10n.t('exitInviteMissing'));
      return;
    }
    if (!state.snapshot.isConnected) {
      showSnack(context, l10n.t('exitNeedTunnel'));
      return;
    }
    setState(() => _registering = profile.id);
    try {
      final result = await state.registerExit(profile, token);
      if (!mounted) return;
      if (result.ok) {
        showSnack(
          context,
          l10n.tf('exitRegistered', [
            result.exitName.isEmpty ? profile.title : result.exitName,
          ]),
        );
      } else {
        showSnack(
          context,
          l10n.tf('exitRegisterFailed', [
            result.message.isEmpty ? result.error : result.message,
          ]),
        );
      }
    } finally {
      if (mounted) setState(() => _registering = null);
    }
  }

  Future<void> _remove(AppState state, ExitProfile profile) async {
    final l10n = state.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.t('exitRemoveTitle')),
        content: Text(l10n.tf('exitRemoveBody', [profile.title])),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.t('delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await state.removeExitProfile(profile.id);
    if (!mounted) return;
    showSnack(context, l10n.t('exitRemoved'));
  }

  Future<void> _check(AppState state) async {
    final result = await state.checkExitProfiles();
    if (!mounted) return;
    showSnack(
      context,
      state.l10n.t(result == null ? 'exitCheckFailed' : 'exitChecked'),
    );
  }

  /// Edits one resolver list. The exit list is used for public names and goes
  /// through the exit; the local list is used for names like router.lan and is
  /// queried directly, empty meaning "whatever the real network provides".
  Future<void> _editDns(AppState state, {required bool exitDns}) async {
    final l10n = state.l10n;
    final current = exitDns
        ? state.settings.exitDnsServers
        : state.settings.exitLocalDnsServers;
    final controller = TextEditingController(text: current.join(', '));
    String? error;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocalState) => AlertDialog(
          title: Text(l10n.t(exitDns ? 'exitDnsTitle' : 'exitLocalDnsTitle')),
          content: SizedBox(
            width: 360,
            child: TextField(
              controller: controller,
              autofocus: true,
              autocorrect: false,
              minLines: 1,
              maxLines: 3,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                labelText: l10n.t('dnsServers'),
                hintText: exitDns ? '1.1.1.1, 9.9.9.9' : '192.168.1.1',
                helperText: l10n.t(
                  exitDns ? 'exitDnsHint' : 'exitLocalDnsServersHint',
                ),
                helperMaxLines: 3,
                errorText: error == null ? null : l10n.t(error!),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.t('cancel')),
            ),
            FilledButton(
              onPressed: () async {
                final servers = controller.text
                    .split(RegExp(r'[\s,;]+'))
                    .map((item) => item.trim())
                    .where((item) => item.isNotEmpty)
                    .toList();
                final invalid = servers.any(
                  (item) => InternetAddress.tryParse(item) == null,
                );
                if (invalid || (exitDns && servers.isEmpty)) {
                  setLocalState(() => error = 'exitDnsInvalid');
                  return;
                }
                if (exitDns) {
                  await state.setExitDnsServers(servers);
                } else {
                  await state.setExitLocalDnsServers(servers);
                }
                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                if (mounted) showSnack(context, l10n.t('exitDnsSaved'));
              },
              child: Text(l10n.t('save')),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }
}

class _ExitRow extends StatelessWidget {
  const _ExitRow({
    super.key,
    required this.index,
    required this.profile,
    required this.active,
    required this.health,
    required this.registering,
    required this.onSetActive,
    required this.onEdit,
    required this.onRegister,
    required this.onRemove,
  });

  final int index;
  final ExitProfile profile;
  final bool active;
  final ExitProfileStatus? health;
  final bool registering;
  final VoidCallback onSetActive;
  final VoidCallback onEdit;
  final VoidCallback onRegister;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.read<AppState>().l10n;
    final state = health?.state ?? 'unknown';
    final color = switch (state) {
      'online' => Colors.green,
      'denied' => Colors.red,
      'unreachable' => Colors.orange,
      _ => theme.colorScheme.outline,
    };
    final stateLabel = switch (state) {
      'online' => l10n.t('exitProfileOnline'),
      'denied' => l10n.t('exitProfileDenied'),
      'unreachable' => l10n.t('exitProfileUnreachable'),
      _ => l10n.t('exitProfileUnknown'),
    };
    final latency = health?.latencyMs ?? 0;
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      leading: IconButton(
        tooltip: l10n.t('exitSetActive'),
        onPressed: active ? null : onSetActive,
        icon: Icon(
          active
              ? Icons.radio_button_checked_rounded
              : Icons.radio_button_unchecked_rounded,
          color: active ? theme.colorScheme.primary : null,
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              profile.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (active)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: StatusPill(
                label: l10n.t('exitActive'),
                color: theme.colorScheme.primary,
              ),
            ),
          if (profile.socksOnly)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: StatusPill(
                label: l10n.t('exitSocksOnlyShort'),
                color: theme.colorScheme.tertiary,
              ),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${profile.address}:${profile.socksPort}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
          if (profile.peer.isNotEmpty) ...[
            const SizedBox(height: 2),
            Row(
              children: [
                Icon(
                  Icons.lan_rounded,
                  size: 12,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    shortUri(profile.peer),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (profile.hasDns) ...[
            const SizedBox(height: 2),
            Row(
              children: [
                Icon(
                  Icons.dns_rounded,
                  size: 12,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    l10n.tf('exitDnsAdvertised', [profile.dnsServer]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 2),
          Row(
            children: [
              Icon(Icons.circle, size: 8, color: color),
              const SizedBox(width: 6),
              Text(
                latency > 0
                    ? '$stateLabel · ${latency.toStringAsFixed(0)} ms'
                    : stateLabel,
                style: theme.textTheme.labelSmall?.copyWith(color: color),
              ),
              if (registering) ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
          if (health?.ipv6Available == false) ...[
            const SizedBox(height: 2),
            Row(
              children: [
                const Icon(
                  Icons.language_rounded,
                  size: 12,
                  color: Colors.orange,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    l10n.t(
                      health!.ipv6Broken
                          ? 'exitIpv6BrokenShort'
                          : 'exitIpv6NoneShort',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.orange,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'edit':
                  onEdit();
                case 'register':
                  onRegister();
                case 'remove':
                  onRemove();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'edit', child: Text(l10n.t('edit'))),
              if (profile.invite.trim().isNotEmpty)
                PopupMenuItem(
                  value: 'register',
                  child: Text(l10n.t('exitRetryRegistration')),
                ),
              PopupMenuItem(value: 'remove', child: Text(l10n.t('delete'))),
            ],
          ),
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.drag_handle_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExitProfileDialog extends StatefulWidget {
  const _ExitProfileDialog({this.initial});

  final ExitProfile? initial;

  @override
  State<_ExitProfileDialog> createState() => _ExitProfileDialogState();
}

class _ExitProfileDialogState extends State<_ExitProfileDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _address;
  late final TextEditingController _socks;
  late final TextEditingController _api;
  late final TextEditingController _invite;
  late final TextEditingController _peer;
  late final TextEditingController _token;
  bool _showToken = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? '');
    _address = TextEditingController(text: initial?.address ?? '');
    _socks = TextEditingController(text: '${initial?.socksPort ?? 1080}');
    _api = TextEditingController(text: '${initial?.apiPort ?? 1080}');
    _invite = TextEditingController(text: initial?.invite ?? '');
    _peer = TextEditingController(text: initial?.peer ?? '');
    _token = TextEditingController(text: initial?.token ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _socks.dispose();
    _api.dispose();
    _invite.dispose();
    _peer.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.read<AppState>().l10n;
    return AlertDialog(
      title: Text(
        widget.initial == null ? l10n.t('exitAddManually') : l10n.t('edit'),
      ),
      content: SizedBox(
        width: 360,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // The mode is derived from the fields below, so the banner
                // explains what an empty invite and token mean instead of
                // hiding them behind a switch the user has to find.
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    l10n.t('exitSocksOnlyFormHint'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 18),
                TextFormField(
                  controller: _name,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l10n.t('exitName'),
                    helperText: l10n.t('exitNameHint'),
                  ),
                ),
                const SizedBox(height: 18),
                TextFormField(
                  controller: _address,
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l10n.t('exitAddress'),
                    hintText: l10n.t('exitAddressHint'),
                  ),
                  validator: (value) {
                    if (!ExitInvite.isYggdrasilAddress(value ?? '')) {
                      return l10n.t('exitInvalidAddress');
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _socks,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: l10n.t('exitSocksPort'),
                        ),
                        validator: (value) => _validPort(value)
                            ? null
                            : l10n.t('exitInvalidPort'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _api,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: l10n.t('exitApiPort'),
                          helperText: l10n.t('exitApiPortHint'),
                        ),
                        validator: (value) => _validApiPort(value)
                            ? null
                            : l10n.t('exitInvalidPort'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                TextFormField(
                  controller: _invite,
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l10n.t('exitInvite'),
                    helperText: l10n.t('exitInviteHint'),
                  ),
                ),
                const SizedBox(height: 18),
                TextFormField(
                  controller: _token,
                  autocorrect: false,
                  enableSuggestions: false,
                  obscureText: !_showToken,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l10n.t('exitToken'),
                    helperText: l10n.t('exitTokenHint'),
                    suffixIcon: IconButton(
                      tooltip: l10n.t(
                        _showToken ? 'exitTokenHide' : 'exitTokenShow',
                      ),
                      onPressed: () => setState(() => _showToken = !_showToken),
                      icon: Icon(
                        _showToken
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                TextFormField(
                  controller: _peer,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: l10n.t('exitPeer'),
                    hintText: l10n.t('exitPeerHint'),
                    helperText: l10n.t('exitPeerHelper'),
                  ),
                  validator: (value) {
                    final peer = (value ?? '').trim();
                    if (peer.isEmpty || ExitInvite.isUsablePeer(peer)) {
                      return null;
                    }
                    return l10n.t('exitPeerInvalid');
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.t('cancel')),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.t('save'))),
      ],
    );
  }

  static bool _validPort(String? value) {
    final port = int.tryParse(value?.trim() ?? '');
    return port != null && port >= 1 && port <= 65535;
  }

  /// The API port may be 0: it then shares the SOCKS5 port and is served under
  /// `/v1/...` on the same listener.
  static bool _validApiPort(String? value) {
    final port = int.tryParse(value?.trim() ?? '');
    return port != null && port >= 0 && port <= 65535;
  }

  void _submit() {
    if (!(_form.currentState?.validate() ?? false)) return;
    final address = _address.text.trim();
    final socks = int.parse(_socks.text.trim());
    final name = _name.text.trim();
    var api = int.parse(_api.text.trim());
    if (api == 0) api = socks;
    Navigator.of(context).pop(
      ExitProfile(
        id: widget.initial?.id ?? '$address:$socks',
        name: name.isEmpty ? address : name,
        address: address,
        socksPort: socks,
        apiPort: api,
        invite: _invite.text.trim(),
        peer: _peer.text.trim(),
        token: _token.text.trim(),
        // The resolver comes from the invite and has no field of its own, so
        // an edit has to carry it over instead of dropping it.
        dnsAddress: widget.initial?.dnsAddress ?? '',
        dnsPort: widget.initial?.dnsPort ?? 53,
      ),
    );
  }
}
