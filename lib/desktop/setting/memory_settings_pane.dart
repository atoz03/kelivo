import 'package:flutter/material.dart';

import '../../features/settings/pages/memory_page.dart';

/// Desktop right-side pane for the Markdown memory directory.
class DesktopMemorySettingsPane extends StatelessWidget {
  const DesktopMemorySettingsPane({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: MemoryContent(),
        ),
      ),
    );
  }
}
