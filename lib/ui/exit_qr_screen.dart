import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../data/exit_link.dart';
import '../state/app_state.dart';

/// Scans the QR code printed by `ygg-exit invite`.
///
/// The screen pops with the parsed [ExitInvite] or with null when the user
/// closes it. A code that is not a Y-Node exit link is ignored with a short
/// hint, so the camera stays open for the right one.
class ExitQrScreen extends StatefulWidget {
  const ExitQrScreen({super.key});

  @override
  State<ExitQrScreen> createState() => _ExitQrScreenState();
}

class _ExitQrScreenState extends State<ExitQrScreen> {
  bool _handled = false;
  bool _invalidShown = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.watch<AppState>().l10n;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(l10n.t('exitQrTitle')),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            onDetect: (capture) {
              if (_handled) return;
              for (final barcode in capture.barcodes) {
                final raw = barcode.rawValue;
                if (raw == null) continue;
                final invite = ExitInvite.parse(raw);
                if (invite != null) {
                  _handled = true;
                  Navigator.of(context).pop(invite);
                  return;
                }
              }
              if (!_invalidShown) {
                _invalidShown = true;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.t('exitQrInvalid'))),
                );
                Future<void>.delayed(const Duration(seconds: 3), () {
                  if (mounted) _invalidShown = false;
                });
              }
            },
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              minimum: const EdgeInsets.all(24),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  l10n.t('exitQrHint'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the scanner and returns the parsed invite, if any.
Future<ExitInvite?> scanExitInvite(BuildContext context) {
  return Navigator.of(
    context,
  ).push<ExitInvite>(MaterialPageRoute(builder: (_) => const ExitQrScreen()));
}
