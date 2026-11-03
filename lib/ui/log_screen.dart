import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../data/native.dart';
import '../state/app_state.dart';
import 'widgets.dart';

/// The connection log: everything the Kotlin service and the Go node write.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  String _text = '';
  String _path = '';
  int _size = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final results = await Future.wait([
      Native.getLog(),
      Native.logPath(),
      Native.logSize(),
    ]);
    if (!mounted) return;
    setState(() {
      _text = results[0] as String;
      _path = results[1] as String;
      _size = results[2] as int;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = state.l10n;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('logTitle')),
        actions: [
          IconButton(
            tooltip: l10n.t('copy'),
            onPressed: _text.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: _text));
                    if (context.mounted) {
                      showSnack(context, l10n.t('logCopied'));
                    }
                  },
            icon: const Icon(Icons.copy_all_rounded),
          ),
          IconButton(
            tooltip: l10n.t('clearLog'),
            onPressed: () async {
              await Native.clearLog();
              await _reload();
              if (context.mounted) showSnack(context, l10n.t('logCleared'));
            },
            icon: const Icon(Icons.delete_outline_rounded),
          ),
          IconButton(
            tooltip: l10n.t('refresh'),
            onPressed: _reload,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: _text.isEmpty
                      ? EmptyHint(
                          icon: Icons.article_outlined,
                          title: l10n.t('logEmpty'),
                        )
                      : Container(
                          width: double.infinity,
                          margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerLowest,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                          child: SingleChildScrollView(
                            reverse: true,
                            child: SelectableText(
                              _text,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                                height: 1.35,
                              ),
                            ),
                          ),
                        ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Text(
                          '${l10n.t('logSize')}: ${formatBytes(_size)}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
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
