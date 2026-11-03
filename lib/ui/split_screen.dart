import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/native.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'widgets.dart';

/// Split tunnelling: which apps are allowed into Yggdrasil.
///
/// Everything not selected keeps using the normal network, which is the whole
/// point of the feature for a mesh network: the browser reaches in-network sites
/// while the rest of the phone stays on the clearnet.
class SplitScreen extends StatefulWidget {
  const SplitScreen({super.key});

  @override
  State<SplitScreen> createState() => _SplitScreenState();
}

class _SplitScreenState extends State<SplitScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool _showSystem = false;
  bool _started = false;

  /// The filtered, sorted app list and the inputs it was built from. Rebuilding
  /// it on every notification from the tunnel state was wasted work: the list
  /// only changes when the query, the filter, the installed apps or the
  /// selection change.
  Object? _appsKey;
  List<InstalledApp> _appsCache = const [];

  bool _applying = false;

  /// Browsers the quick pick knows about. Samsung Internet is the default on
  /// Samsung phones, so it has to be here.
  static const List<String> _browsers = [
    'com.android.chrome',
    'com.sec.android.app.sbrowser',
    'com.sec.android.app.sbrowser.beta',
    'org.mozilla.firefox',
    'com.yandex.browser',
    'com.brave.browser',
    'com.microsoft.emmx',
    'com.opera.browser',
    'com.opera.mini.native',
    'com.duckduckgo.mobile.android',
    'com.kiwibrowser.browser',
    'org.chromium.chrome',
    'com.google.android.apps.chrome',
  ];

  /// Messengers the quick pick knows about.
  static const List<String> _messengers = [
    'com.whatsapp',
    'com.whatsapp.w4b',
    'org.telegram.messenger',
    'org.telegram.messenger.web',
    'org.telegram.plus',
    'com.viber.voip',
    'org.thoughtcrime.securesms',
    'ch.threema.app',
    'com.facebook.orca',
    'com.vk.im',
    'com.icq.mobile.client',
    'im.vector.app',
    'chat.simplex.app',
    'network.loki.messenger',
    'com.wire',
    'jp.naver.line.android',
    'com.discord',
    'com.google.android.apps.messaging',
    'com.samsung.android.messaging',
    'com.android.mms',
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.read<AppState>();
    if (_started) return;
    _started = true;
    state.loadInstalledApps();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// The apps to show, filtered and ordered: selected ones first, then by name.
  /// The result is cached until one of the inputs changes, so a status tick
  /// from the tunnel does not re-sort the whole package list.
  List<InstalledApp> _visibleApps(AppState state) {
    final selected = state.settings.splitApps;
    final key = Object.hash(
      _query,
      _showSystem,
      identityHashCode(state.installedApps),
      Object.hashAll(selected),
    );
    if (_appsKey == key) return _appsCache;
    final selectedSet = selected.toSet();
    final apps = state.installedApps.where((app) {
      if (!_showSystem && app.system) return false;
      if (_query.isEmpty) return true;
      final needle = _query.toLowerCase();
      return app.label.toLowerCase().contains(needle) ||
          app.packageName.toLowerCase().contains(needle);
    }).toList();
    // Selected apps stay on top: the list is a working set, and the apps the
    // user already routed into the tunnel are the ones they look for.
    apps.sort((a, b) {
      final aSelected = selectedSet.contains(a.packageName) ? 0 : 1;
      final bSelected = selectedSet.contains(b.packageName) ? 0 : 1;
      if (aSelected != bSelected) return aSelected - bSelected;
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
    _appsKey = key;
    _appsCache = apps;
    return apps;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = state.l10n;
    final theme = Theme.of(context);
    final apps = _visibleApps(state);
    final settings = state.settings;
    final selected = settings.splitApps.toSet();
    // The configuration the service is really running with. It is updated when
    // a connect finishes, so enabling split tunnelling while the tunnel is down
    // and then connecting no longer leaves a stale "not applied" warning.
    final changed = state.splitChangesPending;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('splitTitle'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
                child: Column(
                  children: [
                    SwitchListTile(
                      value: settings.splitEnabled,
                      onChanged: _applying
                          ? null
                          : (value) => _setEnabled(state, value),
                      title: Text(l10n.t('splitEnabled')),
                      subtitle: Text(
                        l10n.t('splitDescription'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    // The state row belongs to the running tunnel, not to the
                    // switch: with split tunnelling turned off it is the only
                    // sign that the live tunnel still uses the old app list.
                    if (state.isConnected || _applying)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  _applying
                                      ? Icons.sync_rounded
                                      : changed
                                      ? Icons.info_outline_rounded
                                      : Icons.check_circle_outline_rounded,
                                  size: 16,
                                  color: _applying || changed
                                      ? theme.colorScheme.secondary
                                      : theme.colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _applying
                                        ? l10n.t('reconnectingNow')
                                        : changed
                                        ? l10n.t('splitChangesPending')
                                        : l10n.t('splitApplied'),
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                              ],
                            ),
                            if (changed || _applying) ...[
                              const SizedBox(height: 8),
                              FilledButton.tonalIcon(
                                onPressed: changed && !_applying
                                    ? () => _reconnect(state)
                                    : null,
                                icon: _applying
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.refresh_rounded,
                                        size: 18,
                                      ),
                                label: Text(
                                  _applying
                                      ? l10n.t('reconnectingNow')
                                      : l10n.t('reconnectNow'),
                                ),
                              ),
                            ],
                            if (_applying) ...[
                              const SizedBox(height: 8),
                              const LinearProgressIndicator(minHeight: 2),
                            ],
                          ],
                        ),
                      ),
                    if (settings.splitEnabled) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Row(
                          children: [
                            Chip(
                              visualDensity: VisualDensity.compact,
                              avatar: const Icon(
                                Icons.lock_outline_rounded,
                                size: 16,
                              ),
                              label: Text(
                                selected.length == 1
                                    ? l10n.t('splitSelectedCountOne')
                                    : l10n.tf('splitSelectedCount', [
                                        selected.length,
                                      ]),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (selected.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                          child: Text(
                            l10n.t('splitAllApps'),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      _Presets(
                        onBrowsers: () => _applyPreset(state, _browsers),
                        onMessengers: () => _applyPreset(state, _messengers),
                        onClear: () => state.setSplitApps(const []),
                        l10n: l10n,
                      ),
                    ] else
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(
                          l10n.t('splitOffHint'),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    onChanged: (value) => setState(() => _query = value),
                    decoration: InputDecoration(
                      hintText: l10n.t('splitSearch'),
                      prefixIcon: const Icon(Icons.search_rounded),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: Text(l10n.t('splitSystemApps')),
                  selected: _showSystem,
                  onSelected: (value) => setState(() => _showSystem = value),
                ),
              ],
            ),
          ),
          Expanded(
            child: state.loadingApps
                ? const Center(child: CircularProgressIndicator())
                : apps.isEmpty
                ? EmptyHint(
                    icon: Icons.apps_outlined,
                    title: l10n.t('splitNoApps'),
                    // The first listing can fail while the system is busy (or
                    // while the app is still starting): let the user ask again
                    // instead of leaving a dead screen.
                    action: OutlinedButton.icon(
                      onPressed: () => state.loadInstalledApps(force: true),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(l10n.t('retry')),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: apps.length,
                    itemBuilder: (context, index) {
                      final app = apps[index];
                      final checked = selected.contains(app.packageName);
                      return CheckboxListTile(
                        value: checked,
                        onChanged: settings.splitEnabled
                            ? (value) => _toggle(state, app, value == true)
                            : null,
                        title: Text(
                          app.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          app.packageName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        secondary: _AppIcon(packageName: app.packageName),
                        controlAffinity: ListTileControlAffinity.trailing,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggle(AppState state, InstalledApp app, bool value) async {
    final current = [...state.settings.splitApps];
    if (value) {
      if (!current.contains(app.packageName)) current.add(app.packageName);
    } else {
      current.remove(app.packageName);
    }
    await state.setSplitApps(current);
  }

  /// Turns split tunnelling on or off. Android reads the allow list only when
  /// the VPN interface is created, so a live tunnel keeps the old list until it
  /// is restarted; the user is asked first because the traffic stops for a
  /// moment.
  Future<void> _setEnabled(AppState state, bool value) async {
    if (state.settings.splitEnabled == value) return;
    final live = state.isRunning || state.connecting;
    if (live && !await _confirmRestart(state)) return;
    if (!mounted) return;
    await state.saveSettings(state.settings.copyWith(splitEnabled: value));
    if (!mounted) return;
    if (live) await _reconnect(state);
  }

  Future<bool> _confirmRestart(AppState state) async {
    final l10n = state.l10n;
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.t('splitRestartTitle')),
        content: Text(l10n.t('splitRestartBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.t('splitRestartAction')),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  /// Restarts the tunnel so the service picks up the new app list. The button
  /// stays disabled until the tunnel is really back up with the new list.
  Future<void> _reconnect(AppState state) async {
    final l10n = state.l10n;
    setState(() => _applying = true);
    final ok = await state.reconnect();
    if (!mounted) return;
    setState(() => _applying = false);
    showSnack(
      context,
      ok
          ? l10n.t('reconnectDone')
          : l10n.t(state.lastError ?? 'reconnectFailed'),
    );
  }

  Future<void> _applyPreset(AppState state, List<String> packages) async {
    final installed = {for (final app in state.installedApps) app.packageName};
    final current = {...state.settings.splitApps};
    for (final package in packages) {
      if (installed.contains(package)) current.add(package);
    }
    await state.setSplitApps(current.toList());
  }
}

class _Presets extends StatelessWidget {
  const _Presets({
    required this.onBrowsers,
    required this.onMessengers,
    required this.onClear,
    required this.l10n,
  });

  final VoidCallback onBrowsers;
  final VoidCallback onMessengers;
  final VoidCallback onClear;
  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    // Three equal columns: the labels stay inside the card on a narrow screen
    // instead of running off the right edge as the old chip row did.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: _PresetButton(
              icon: Icons.public_rounded,
              label: l10n.t('splitPresetBrowsers'),
              onPressed: onBrowsers,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _PresetButton(
              icon: Icons.forum_rounded,
              label: l10n.t('splitPresetMessengers'),
              onPressed: onMessengers,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _PresetButton(
              icon: Icons.clear_all_rounded,
              label: l10n.t('splitPresetClear'),
              onPressed: onClear,
            ),
          ),
        ],
      ),
    );
  }
}

/// One quick-pick action: an icon above its label, so three of them fit the
/// width of the card without clipping.
class _PresetButton extends StatelessWidget {
  const _PresetButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        minimumSize: const Size(0, 56),
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

/// Application icon, fetched once per package and cached for the session.
class _AppIcon extends StatefulWidget {
  const _AppIcon({required this.packageName});

  final String packageName;

  /// Decoded icons, shared by every row: the list is rebuilt often and reading
  /// the same bitmap from the package manager again would be wasteful.
  static final Map<String, Uint8List?> _cache = {};

  @override
  State<_AppIcon> createState() => _AppIconState();
}

class _AppIconState extends State<_AppIcon> {
  /// Started once per row, not on every build. A new future per build meant a
  /// new platform call for every icon that was still loading.
  Future<Uint8List?>? _future;

  @override
  void initState() {
    super.initState();
    if (!_AppIcon._cache.containsKey(widget.packageName)) {
      _future = Native.appIcon(widget.packageName).then((bytes) {
        _AppIcon._cache[widget.packageName] = bytes;
        return bytes;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fallback = Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(
        Icons.android_rounded,
        size: 20,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );

    if (_AppIcon._cache.containsKey(widget.packageName)) {
      final bytes = _AppIcon._cache[widget.packageName];
      if (bytes == null) return fallback;
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(
          bytes,
          width: 40,
          height: 40,
          gaplessPlayback: true,
        ),
      );
    }

    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) return fallback;
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            bytes,
            width: 40,
            height: 40,
            gaplessPlayback: true,
          ),
        );
      },
    );
  }
}
