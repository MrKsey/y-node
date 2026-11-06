import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/update_service.dart';
import '../l10n/strings.dart';
import 'widgets.dart';

/// Shows the "new version available" dialog. When the user accepts, the release
/// page is opened in the browser, where the APK can be downloaded. The app does
/// not install updates itself: Android requires the user to confirm the package
/// installation, and the browser handles that flow.
Future<void> showUpdatePrompt(
  BuildContext context,
  UpdateInfo info,
  L10n l10n,
) async {
  final accepted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.t('updateAvailableTitle')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.tf('updateAvailableBody', [info.version])),
          if (info.notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              info.notes,
              maxLines: 8,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.t('updateLater')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(l10n.t('updateOpenRelease')),
        ),
      ],
    ),
  );
  if (accepted != true || !context.mounted) return;
  await openReleasePage(context, info, l10n);
}

/// Opens the release page in the device browser.
Future<void> openReleasePage(
  BuildContext context,
  UpdateInfo info,
  L10n l10n,
) async {
  final opened = await launchUrl(
    Uri.parse(info.releaseUrl),
    mode: LaunchMode.externalApplication,
  );
  if (!opened && context.mounted) {
    showSnack(context, l10n.t('linkFailed'));
  }
}
