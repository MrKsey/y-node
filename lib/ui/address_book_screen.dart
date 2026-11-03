import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../data/native.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'widgets.dart';

/// The address book: in-network sites the user can open in a browser.
///
/// The app itself never carries its own traffic into the tunnel, so these links
/// always leave through an external browser. When split tunnelling is on, the
/// browser has to be one of the selected apps, which is what the helper on each
/// tap is for.
class AddressBookScreen extends StatefulWidget {
  const AddressBookScreen({super.key});

  @override
  State<AddressBookScreen> createState() => _AddressBookScreenState();
}

class _AddressBookScreenState extends State<AddressBookScreen> {
  final TextEditingController _search = TextEditingController();
  final Set<String> _selectedIds = {};
  String _query = '';
  bool _selecting = false;

  /// The filtered book and the inputs it was built from. The tunnel state ticks
  /// while it is up, and filtering the whole book on every tick was wasted.
  Object? _itemsKey;
  List<Resource> _itemsCache = const [];

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Resource> _visibleItems(AppState state) {
    final key = Object.hash(_query, identityHashCode(state.resources));
    if (_itemsKey == key) return _itemsCache;
    final items = state.resources.where((resource) {
      if (_query.isEmpty) return true;
      final needle = _query.toLowerCase();
      return resource.title.toLowerCase().contains(needle) ||
          resource.url.toLowerCase().contains(needle) ||
          resource.description.toLowerCase().contains(needle);
    }).toList();
    _itemsKey = key;
    _itemsCache = items;
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = state.l10n;
    final items = _visibleItems(state);

    return Scaffold(
      appBar: AppBar(
        leading: _selecting
            ? IconButton(
                tooltip: l10n.t('bookSelectCancel'),
                onPressed: () => setState(() {
                  _selecting = false;
                  _selectedIds.clear();
                }),
                icon: const Icon(Icons.close_rounded),
              )
            : null,
        title: _selecting
            ? Text(l10n.tf('bookSelectedCount', [_selectedIds.length]))
            : Text(l10n.t('bookTitle')),
        actions: _selecting
            ? [
                IconButton(
                  tooltip: l10n.t('importSelectAll'),
                  onPressed: items.isEmpty
                      ? null
                      : () => setState(() {
                          if (items.every(
                            (item) => _selectedIds.contains(item.id),
                          )) {
                            _selectedIds.clear();
                          } else {
                            _selectedIds
                              ..clear()
                              ..addAll(items.map((item) => item.id));
                          }
                        }),
                  icon: const Icon(Icons.select_all_rounded),
                ),
                IconButton(
                  tooltip: l10n.t('bookDeleteSelected'),
                  onPressed: _selectedIds.isEmpty
                      ? null
                      : () => _deleteSelected(context),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ]
            : [
                IconButton(
                  tooltip: l10n.t('bookSelect'),
                  onPressed: items.isEmpty
                      ? null
                      : () => setState(() {
                          _selecting = true;
                          _selectedIds.clear();
                        }),
                  icon: const Icon(Icons.checklist_rounded),
                ),
                IconButton(
                  tooltip: l10n.t('browseDirectory'),
                  onPressed: () => _browseDirectory(context),
                  icon: const Icon(Icons.cloud_download_outlined),
                ),
              ],
      ),
      floatingActionButton: _selecting
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _edit(context, null),
              icon: const Icon(Icons.add_rounded),
              label: Text(l10n.t('addResource')),
            ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: l10n.t('bookSearchHint'),
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
              ),
            ),
          ),
          if (items.isNotEmpty && !_selecting && _query.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Row(
                children: [
                  Icon(
                    Icons.drag_indicator_rounded,
                    size: 14,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    l10n.t('bookReorderHint'),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: items.isEmpty
                ? EmptyHint(
                    icon: Icons.book_outlined,
                    title: l10n.t('bookEmpty'),
                    action: FilledButton.tonalIcon(
                      onPressed: () => _browseDirectory(context),
                      icon: const Icon(Icons.cloud_download_outlined, size: 18),
                      label: Text(l10n.t('browseDirectory')),
                    ),
                  )
                : _query.isEmpty && !_selecting
                ? ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                    itemCount: items.length,
                    onReorderItem: (oldIndex, newIndex) =>
                        state.reorderResources(oldIndex, newIndex),
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return Padding(
                        key: ValueKey(item.id),
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _ResourceCard(
                          resource: item,
                          onOpen: () => _open(context, item),
                          onEdit: () => _edit(context, item),
                          onDelete: () => _delete(context, item),
                        ),
                      );
                    },
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) => _ResourceCard(
                      resource: items[index],
                      selecting: _selecting,
                      selected: _selectedIds.contains(items[index].id),
                      onSelect: () => setState(() {
                        if (!_selectedIds.add(items[index].id)) {
                          _selectedIds.remove(items[index].id);
                        }
                      }),
                      onOpen: () => _open(context, items[index]),
                      onEdit: () => _edit(context, items[index]),
                      onDelete: () => _delete(context, items[index]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteSelected(BuildContext context) async {
    final state = context.read<AppState>();
    final l10n = state.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.t('bookDeleteSelected')),
        content: Text(l10n.t('bookDeleteSelectedBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.t('delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final count = await state.deleteResources(_selectedIds);
    if (!context.mounted) return;
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
    showSnack(context, l10n.tf('bookDeletedCount', [count]));
  }

  Future<void> _open(BuildContext context, Resource resource) async {
    final state = context.read<AppState>();
    final l10n = state.l10n;
    final uri = Uri.tryParse(resource.url);
    if (uri == null) return;

    final needsSplit = state.settings.splitEnabled;
    final browser = await _browserPackage(state);
    // An empty allow list means every app goes through the VPN, so the browser
    // is covered there as well.
    final browserCovered =
        !needsSplit ||
        state.settings.splitApps.isEmpty ||
        (browser != null && state.settings.splitApps.contains(browser));

    // The hint is about a browser that is not in the VPN list yet. It is shown
    // once unless the user asked not to see it again.
    if (!browserCovered && !state.browserHintDismissed && context.mounted) {
      var dontShowAgain = false;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setLocalState) => AlertDialog(
            title: Text(l10n.t('browserHint')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  browser == null
                      ? l10n.t('browserNotFound')
                      : l10n.t('addBrowserToSplit'),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: dontShowAgain,
                  onChanged: (value) =>
                      setLocalState(() => dontShowAgain = value ?? false),
                  title: Text(l10n.t('dontShowAgain')),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(l10n.t('cancel')),
              ),
              if (browser != null)
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(l10n.t('addBrowserToSplit')),
                ),
              if (browser == null)
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(l10n.t('ok')),
                ),
            ],
          ),
        ),
      );
      if (dontShowAgain) await state.dismissBrowserHint();
      if (browser != null && proceed == true) {
        await state.setSplitApps([...state.settings.splitApps, browser]);
        // The service reads the allow list only when it starts, so a running
        // tunnel has to be restarted before the browser can reach the network.
        if (state.isConnected) {
          if (context.mounted) showSnack(context, l10n.t('reconnectingNow'));
          final ok = await state.reconnect();
          if (!ok && context.mounted) {
            showSnack(context, l10n.t(state.lastError ?? 'reconnectFailed'));
          }
        }
        if (context.mounted) showSnack(context, l10n.t('browserAdded'));
      }
    }

    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      showSnack(context, l10n.t('errorGeneric'));
    }
  }

  /// The browser Android will actually use for the link.
  ///
  /// The system is asked first: the user may have set Samsung Internet or any
  /// other browser as the default, and only that package decides whether the
  /// page can reach Yggdrasil. A browser that is already routed through the VPN
  /// wins over a guessed one, so the hint never appears for an allowed app.
  static Future<String?> _browserPackage(AppState state) async {
    const candidates = [
      'com.sec.android.app.sbrowser',
      'com.sec.android.app.sbrowser.beta',
      'com.android.chrome',
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
    final resolved = await Native.defaultBrowser();
    // A chooser ("android") is not a browser: fall back to the known list.
    if (resolved.isNotEmpty && resolved != 'android') return resolved;
    // The split list counts as known even before the installed apps have been
    // read, so a browser the user already allowed is never reported as missing.
    final installed = {
      for (final app in state.installedApps) app.packageName,
      ...state.settings.splitApps,
    };
    final selected = state.settings.splitApps.toSet();
    for (final package in candidates) {
      if (installed.contains(package) && selected.contains(package)) {
        return package;
      }
    }
    for (final package in candidates) {
      if (installed.contains(package)) return package;
    }
    return null;
  }

  Future<void> _edit(BuildContext context, Resource? existing) async {
    final state = context.read<AppState>();
    final l10n = state.l10n;
    final title = TextEditingController(text: existing?.title ?? '');
    final url = TextEditingController(text: existing?.url ?? '');
    final description = TextEditingController(
      text: existing?.description ?? '',
    );
    String? error;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocalState) => AlertDialog(
          title: Text(
            existing == null ? l10n.t('addResource') : l10n.t('editResource'),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: l10n.t('resourceTitle'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: l10n.t('resourceUrl'),
                    hintText: 'http://[200::1]/',
                    errorText: error == null ? null : l10n.t(error!),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: description,
                  decoration: InputDecoration(
                    labelText: l10n.t('resourceDescription'),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.t('cancel')),
            ),
            FilledButton(
              onPressed: () async {
                final address = url.text.trim();
                if (!_validUrl(address)) {
                  setLocalState(() => error = 'invalidUrl');
                  return;
                }
                final name = title.text.trim();
                final resource = Resource(
                  id:
                      existing?.id ??
                      'user:${DateTime.now().microsecondsSinceEpoch}',
                  title: name.isEmpty ? address : name,
                  url: address,
                  description: description.text.trim(),
                  builtIn: existing?.builtIn ?? false,
                );
                if (existing == null) {
                  await state.addResource(resource);
                } else {
                  await state.updateResource(resource);
                }
                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
              },
              child: Text(l10n.t('save')),
            ),
          ],
        ),
      ),
    );

    title.dispose();
    url.dispose();
    description.dispose();
  }

  static bool _validUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return false;
    if (!uri.hasScheme) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    return uri.host.isNotEmpty;
  }

  Future<void> _delete(BuildContext context, Resource resource) async {
    final state = context.read<AppState>();
    final l10n = state.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.t('deleteResource')),
        content: Text(resource.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.t('delete')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await state.deleteResource(resource.id);
      if (context.mounted) showSnack(context, l10n.t('resourceDeleted'));
    }
  }

  /// The cloud button reads the Yggdrasil web directory through the node.
  /// Without a tunnel there is nothing to read, so the user is told why.
  Future<void> _browseDirectory(BuildContext context) async {
    final state = context.read<AppState>();
    final l10n = state.l10n;
    if (!state.isConnected) {
      final connect = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.t('needConnectionTitle')),
          content: Text(l10n.t('needConnectionBody')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.t('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.t('connectNow')),
            ),
          ],
        ),
      );
      if (connect == true) await state.connect();
      return;
    }
    // The sheet only picks the entries; the import happens here, after it has
    // closed. Doing the write while the sheet was still on screen made the
    // whole app wait on the platform channel.
    final chosen = await showModalBottomSheet<List<Resource>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const _DirectorySheet(),
      ),
    );
    if (chosen == null || chosen.isEmpty) return;
    final added = await state.importResources(chosen);
    if (!context.mounted) return;
    showSnack(
      context,
      added > 0 ? l10n.tf('importDone', [added]) : l10n.t('importNothing'),
    );
  }
}

class _ResourceCard extends StatelessWidget {
  const _ResourceCard({
    required this.resource,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
    this.selecting = false,
    this.selected = false,
    this.onSelect,
  });

  final Resource resource;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final bool selecting;
  final bool selected;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final ygg = resource.url.contains('[');
    final description = resource.description.trim();
    final showDescription =
        description.isNotEmpty &&
        description != resource.title &&
        description != uriHost(resource.url);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: selecting ? onSelect : onOpen,
        child: Padding(
          padding: EdgeInsets.fromLTRB(selecting ? 4 : 16, 12, 8, 12),
          child: Row(
            children: [
              if (selecting)
                Checkbox(value: selected, onChanged: (_) => onSelect?.call())
              else
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: (ygg ? AppColors.teal : AppColors.copper).withValues(
                      alpha: 0.12,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    ygg ? Icons.lan_rounded : Icons.public_rounded,
                    size: 20,
                    color: ygg ? AppColors.teal : AppColors.copperDeep,
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            resource.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (resource.builtIn)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                l10n.t('builtIn'),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (showDescription) ...[
                      const SizedBox(height: 2),
                      Text(
                        resource.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      resource.url,
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
              if (!selecting)
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert_rounded, size: 20),
                  onSelected: (value) async {
                    switch (value) {
                      case 'open':
                        onOpen();
                      case 'copy':
                        await Clipboard.setData(
                          ClipboardData(text: resource.url),
                        );
                        if (context.mounted) {
                          showSnack(context, l10n.t('copied'));
                        }
                      case 'edit':
                        onEdit();
                      case 'delete':
                        onDelete();
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'open',
                      child: Text(l10n.t('openInBrowser')),
                    ),
                    PopupMenuItem(value: 'copy', child: Text(l10n.t('copy'))),
                    PopupMenuItem(value: 'edit', child: Text(l10n.t('edit'))),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(l10n.t('delete')),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The preview of the web directory: the user picks what to add. Entries that
/// are already in the book never reach this list, so nothing is added twice.
class _DirectorySheet extends StatefulWidget {
  const _DirectorySheet();

  @override
  State<_DirectorySheet> createState() => _DirectorySheetState();
}

class _DirectorySheetState extends State<_DirectorySheet> {
  final Set<String> _selected = {};
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final state = context.read<AppState>();
    if (state.directoryResources.isEmpty && !state.loadingDirectory) {
      state.loadDirectory();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = state.l10n;
    final theme = Theme.of(context);
    // Entries that are already in the book are filtered out here as well, so the
    // list and its counter stay correct right after an import.
    final known = {for (final item in state.resources) item.url};
    final items = [
      for (final item in state.directoryResources)
        if (!known.contains(item.url)) item,
    ];

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.t('browseDirectory'),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        state.loadingDirectory
                            ? l10n.t('directoryLoading')
                            : l10n.tf('importCount', [items.length]),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: items.isEmpty
                      ? null
                      : () => setState(() {
                          if (_selected.length == items.length) {
                            _selected.clear();
                          } else {
                            _selected
                              ..clear()
                              ..addAll(items.map((item) => item.id));
                          }
                        }),
                  child: Text(l10n.t('importSelectAll')),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: state.loadingDirectory
                ? const Center(child: CircularProgressIndicator())
                : items.isEmpty
                ? EmptyHint(
                    icon: Icons.cloud_off_rounded,
                    title: state.lastError == 'directoryEmpty'
                        ? l10n.t('directoryEmpty')
                        : l10n.t('directoryFailed'),
                    body: l10n.t('directoryHint'),
                    action: FilledButton.tonalIcon(
                      onPressed: state.loadDirectory,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(l10n.t('retry')),
                    ),
                  )
                : ListView.builder(
                    controller: controller,
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final checked = _selected.contains(item.id);
                      return CheckboxListTile(
                        value: checked,
                        onChanged: (value) => setState(() {
                          if (value == true) {
                            _selected.add(item.id);
                          } else {
                            _selected.remove(item.id);
                          }
                        }),
                        title: Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          item.url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        secondary: const Icon(Icons.language_rounded),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(l10n.t('cancel')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _selected.isEmpty
                          ? null
                          : () {
                              final chosen = items
                                  .where((item) => _selected.contains(item.id))
                                  .toList();
                              Navigator.of(context).pop(chosen);
                            },
                      child: Text(l10n.t('importApply')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
