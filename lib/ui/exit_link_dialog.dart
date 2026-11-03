import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/exit_link.dart';
import '../state/app_state.dart';
import 'widgets.dart';

/// Imports an exit invite from a link instead of a QR code.
///
/// The server prints the same string as the QR code, so a link copied from the
/// terminal, a chat or a file is enough. The field accepts a pasted value, and
/// the clipboard is read once when the dialog opens so a copied link is already
/// there. Returns the parsed invite, or null when the user cancels.
Future<ExitInvite?> showExitLinkDialog(BuildContext context) {
  return showDialog<ExitInvite>(
    context: context,
    builder: (_) => const _ExitLinkDialog(),
  );
}

class _ExitLinkDialog extends StatefulWidget {
  const _ExitLinkDialog();

  @override
  State<_ExitLinkDialog> createState() => _ExitLinkDialogState();
}

class _ExitLinkDialogState extends State<_ExitLinkDialog> {
  final _form = GlobalKey<FormState>();
  final _link = TextEditingController();
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    // A link copied from the server output is the usual way in: offer it at
    // once instead of making the user tap Paste for something already there.
    _readClipboard(announce: false);
  }

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  /// Fills the field from the clipboard. With [announce] the dialog reports an
  /// empty clipboard or a value that is not an invite, because the user asked
  /// for it explicitly; the silent call on open only fills a valid link.
  Future<void> _readClipboard({required bool announce}) async {
    if (_reading) return;
    setState(() => _reading = true);
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = (data?.text ?? '').trim();
      if (!mounted) return;
      final l10n = context.read<AppState>().l10n;
      if (text.isEmpty) {
        if (announce) showSnack(context, l10n.t('exitPasteEmpty'));
        return;
      }
      if (ExitInvite.parsePasted(text) == null) {
        if (announce) showSnack(context, l10n.t('exitLinkInvalid'));
        return;
      }
      setState(() => _link.text = text);
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  void _submit() {
    if (!(_form.currentState?.validate() ?? false)) return;
    final invite = ExitInvite.parsePasted(_link.text);
    if (invite == null) return;
    Navigator.of(context).pop(invite);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.read<AppState>().l10n;
    return AlertDialog(
      title: Text(l10n.t('exitLinkTitle')),
      content: SizedBox(
        width: 360,
        child: Form(
          key: _form,
          child: TextFormField(
            controller: _link,
            autofocus: true,
            autocorrect: false,
            minLines: 1,
            maxLines: 4,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: l10n.t('exitLinkField'),
              hintText: l10n.t('exitLinkHint'),
              helperText: l10n.t('exitLinkHelper'),
              helperMaxLines: 3,
              suffixIcon: IconButton(
                tooltip: l10n.t('exitPaste'),
                onPressed: _reading
                    ? null
                    : () => _readClipboard(announce: true),
                icon: const Icon(Icons.content_paste_rounded),
              ),
            ),
            validator: (value) {
              final text = (value ?? '').trim();
              if (text.isEmpty) return l10n.t('exitLinkEmpty');
              if (ExitInvite.parsePasted(text) == null) {
                return l10n.t('exitLinkInvalid');
              }
              return null;
            },
            onFieldSubmitted: (_) => _submit(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.t('cancel')),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.t('import'))),
      ],
    );
  }
}
