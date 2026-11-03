import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/ip_check.dart';
import '../l10n/strings.dart';
import 'widgets.dart';

/// Shows a small balloon next to the tapped end of the hero link with the
/// address a remote service sees there.
///
/// The balloon is a dialog route rather than a tooltip: it loads the answer
/// after it appears, and the route gives the back button and a tap outside for
/// free. [anchorContext] is the widget the balloon points at.
Future<void> showIpBalloon({
  required BuildContext context,
  required BuildContext anchorContext,
  required bool viaExit,
  required Future<PublicIpResult> Function() load,
}) {
  final box = anchorContext.findRenderObject() as RenderBox?;
  final anchor = box == null || !box.hasSize
      ? null
      : box.localToGlobal(Offset.zero) & box.size;
  return showDialog<void>(
    context: context,
    barrierColor: Colors.transparent,
    barrierDismissible: true,
    useSafeArea: false,
    builder: (_) => _IpBalloon(anchor: anchor, viaExit: viaExit, load: load),
  );
}

class _IpBalloon extends StatefulWidget {
  const _IpBalloon({
    required this.anchor,
    required this.viaExit,
    required this.load,
  });

  /// The screen rectangle of the tapped entity, null when it cannot be found.
  final Rect? anchor;
  final bool viaExit;
  final Future<PublicIpResult> Function() load;

  @override
  State<_IpBalloon> createState() => _IpBalloonState();
}

class _IpBalloonState extends State<_IpBalloon> {
  PublicIpResult? _result;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final result = await widget.load();
    if (!mounted) return;
    setState(() {
      _result = result;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final media = MediaQuery.of(context);
    const width = 268.0;
    const margin = 12.0;
    final anchor = widget.anchor;
    final centerX = anchor?.center.dx ?? media.size.width / 2;
    final left = (centerX - width / 2).clamp(
      margin,
      (media.size.width - width - margin).clamp(margin, double.infinity),
    );
    final below = anchor == null || anchor.center.dy < media.size.height / 2;
    final accent = widget.viaExit
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface;
    final surface = theme.colorScheme.surfaceContainerHigh;

    final card = Material(
      color: surface,
      elevation: 6,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  widget.viaExit
                      ? Icons.vpn_lock_rounded
                      : Icons.person_rounded,
                  size: 16,
                  color: accent,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.t(widget.viaExit ? 'ipExitTitle' : 'ipDirectTitle'),
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, size: 16),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  tooltip: l10n.t('close'),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _body(context, l10n, theme),
            ),
          ],
        ),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: left,
          width: width,
          top: below ? (anchor?.bottom ?? 0) + 10 : null,
          bottom: below ? null : media.size.height - anchor.top + 10,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (below)
                _BalloonArrow(
                  x: (centerX - left).clamp(18.0, width - 18.0),
                  up: true,
                  color: surface,
                ),
              card,
              if (!below)
                _BalloonArrow(
                  x: (centerX - left).clamp(18.0, width - 18.0),
                  up: false,
                  color: surface,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, L10n l10n, ThemeData theme) {
    if (_loading) {
      return Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            l10n.t('ipChecking'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }
    final result = _result;
    if (result == null || !result.ok) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 16,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorText(l10n, result),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                result.ip,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            IconButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: result.ip));
                if (context.mounted) showSnack(context, l10n.t('ipCopied'));
              },
              icon: const Icon(Icons.copy_rounded, size: 15),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              tooltip: l10n.t('copy'),
            ),
          ],
        ),
        Text(
          l10n.t(widget.viaExit ? 'ipExitHint' : 'ipDirectHint'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  String _errorText(L10n l10n, PublicIpResult? result) {
    return switch (result?.error) {
      'exit_off' => l10n.t('ipExitOff'),
      'tunnel_off' => l10n.t('ipTunnelOff'),
      'timeout' => l10n.t('ipTimeout'),
      _ => l10n.t('ipFailed'),
    };
  }
}

/// The little triangle that ties the card to the icon it points at.
class _BalloonArrow extends StatelessWidget {
  const _BalloonArrow({required this.x, required this.up, required this.color});

  final double x;
  final bool up;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 7,
      width: double.infinity,
      child: CustomPaint(
        painter: _ArrowPainter(x: x, up: up, color: color),
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  const _ArrowPainter({required this.x, required this.up, required this.color});

  final double x;
  final bool up;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (up) {
      path
        ..moveTo(x - 7, size.height)
        ..lineTo(x, 0)
        ..lineTo(x + 7, size.height);
    } else {
      path
        ..moveTo(x - 7, 0)
        ..lineTo(x, size.height)
        ..lineTo(x + 7, 0);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) =>
      old.x != x || old.up != up || old.color != color;
}
