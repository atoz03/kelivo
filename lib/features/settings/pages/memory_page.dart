import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/memory_provider.dart';
import '../../../core/services/memory/memory_file_store.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';

/// Mobile route for the Markdown memory directory.
class MemoryPage extends StatelessWidget {
  const MemoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Lucide.ArrowLeft, size: 22, color: cs.onSurface),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.memoryPageTitle),
      ),
      body: const SafeArea(
        child: MemoryContent(padding: EdgeInsets.fromLTRB(16, 8, 16, 24)),
      ),
    );
  }
}

/// The memory file list, shared by the mobile page and the desktop pane.
class MemoryContent extends StatefulWidget {
  const MemoryContent({super.key, this.padding = EdgeInsets.zero});

  final EdgeInsets padding;

  @override
  State<MemoryContent> createState() => _MemoryContentState();
}

class _MemoryContentState extends State<MemoryContent> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<MemoryProvider>().initialize();
    });
  }

  Future<void> _openEditor({MemoryFileSummary? file}) async {
    final provider = context.read<MemoryProvider>();
    final l10n = AppLocalizations.of(context)!;
    final existing = file == null ? '' : (await provider.read(file.name) ?? '');
    if (!mounted) return;

    final result = await showDialog<({String name, String content})>(
      context: context,
      builder: (_) => _MemoryEditorDialog(
        initialName: file?.name ?? '',
        initialContent: existing,
        isNew: file == null,
      ),
    );
    if (result == null || !mounted) return;

    try {
      final stored = await provider.write(result.name, result.content);
      // A rename writes a new file; drop the old one so it is a move, not a copy.
      if (file != null && file.name != stored) await provider.delete(file.name);
    } on RangeError {
      if (mounted) showAppSnackBar(context, message: l10n.memoryPageTooLarge);
    } on ArgumentError {
      if (mounted) {
        showAppSnackBar(context, message: l10n.memoryPageInvalidName);
      }
    }
  }

  Future<void> _confirmDelete(MemoryFileSummary file) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.memoryPageDeleteTitle),
        content: Text(l10n.memoryPageDeleteMessage(file.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.memoryPageCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.memoryPageDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<MemoryProvider>().delete(file.name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.watch<MemoryProvider>();
    final files = provider.files;

    return ListView(
      padding: widget.padding,
      children: [
        SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.memoryPageHowItWorksTitle,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: AppFontWeights.semibold,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.memoryPageHowItWorksBody,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: cs.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.memoryPageFilesTitle,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: AppFontWeights.medium,
                  color: cs.onSurface.withValues(alpha: 0.9),
                ),
              ),
            ),
            IconButton(
              tooltip: l10n.memoryPageNew,
              icon: Icon(Lucide.Plus, size: 18, color: cs.primary),
              onPressed: () => _openEditor(),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (files.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Lucide.Brain,
                    size: 52,
                    color: cs.onSurface.withValues(alpha: 0.26),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.memoryPageEmpty,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: cs.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          for (final file in files) ...[
            _MemoryFileCard(
              file: file,
              onTap: () => _openEditor(file: file),
              onDelete: () => _confirmDelete(file),
            ),
            const SizedBox(height: 10),
          ],
      ],
    );
  }
}

class _MemoryFileCard extends StatelessWidget {
  const _MemoryFileCard({
    required this.file,
    required this.onTap,
    required this.onDelete,
  });

  final MemoryFileSummary file;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return SectionCard(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.name,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: AppFontWeights.medium,
                      color: cs.onSurface,
                    ),
                  ),
                  if (file.summary.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      file.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.65),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: l10n.memoryPageDelete,
              icon: Icon(Lucide.Trash2, size: 18, color: cs.error),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _MemoryEditorDialog extends StatefulWidget {
  const _MemoryEditorDialog({
    required this.initialName,
    required this.initialContent,
    required this.isNew,
  });

  final String initialName;
  final String initialContent;
  final bool isNew;

  @override
  State<_MemoryEditorDialog> createState() => _MemoryEditorDialogState();
}

class _MemoryEditorDialogState extends State<_MemoryEditorDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );
  late final TextEditingController _content = TextEditingController(
    text: widget.initialContent,
  );

  @override
  void dispose() {
    _name.dispose();
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(widget.isNew ? l10n.memoryPageNew : l10n.memoryPageEdit),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IosFormTextField(
              label: l10n.memoryPageNameLabel,
              controller: _name,
              hintText: l10n.memoryPageNameHint,
            ),
            const SizedBox(height: 12),
            IosFormTextField(
              label: l10n.memoryPageContentLabel,
              controller: _content,
              hintText: l10n.memoryPageContentHint,
              maxLines: 12,
              minLines: 8,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.memoryPageCancel),
        ),
        TextButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            Navigator.of(context).pop((name: name, content: _content.text));
          },
          child: Text(l10n.memoryPageSave),
        ),
      ],
    );
  }
}
