import 'package:flutter/material.dart';

import '../../icons/lucide_adapter.dart';

/// Small info glyph next to a settings row, explaining the row on tap.
///
/// Tap rather than hover: the same rows appear on touch, where a hover-only
/// tooltip would never be reachable.
class SettingTipIcon extends StatefulWidget {
  const SettingTipIcon({super.key, required this.message});

  final String message;

  @override
  State<SettingTipIcon> createState() => _SettingTipIconState();
}

class _SettingTipIconState extends State<SettingTipIcon> {
  final _tooltipKey = GlobalKey<TooltipState>();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      key: _tooltipKey,
      message: widget.message,
      triggerMode: TooltipTriggerMode.tap,
      waitDuration: const Duration(milliseconds: 250),
      showDuration: const Duration(seconds: 8),
      preferBelow: true,
      constraints: const BoxConstraints(maxWidth: 280),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => _tooltipKey.currentState?.ensureTooltipVisible(),
        child: SizedBox(
          width: 28,
          height: 28,
          child: Center(
            child: Icon(
              Lucide.BadgeInfo,
              size: 16,
              color: cs.onSurface.withValues(alpha: 0.45),
              semanticLabel: widget.message,
            ),
          ),
        ),
      ),
    );
  }
}
