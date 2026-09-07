import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;

/// A [SelectionArea] that keeps keyboard focus while it owns a selection.
///
/// `SelectionArea` routes Cmd/Ctrl+C through its own `Actions` entry, which
/// only fires while its focus node holds primary focus. A chat page has many
/// selectable regions and a text field that also wants focus, so a region can
/// end up painting a highlight it cannot copy: the selection is visible, the
/// shortcut goes somewhere else, and nothing lands on the clipboard.
///
/// Taking focus whenever the selection becomes non-empty ties the two
/// together — whichever region the user is actually selecting in is the one
/// the copy shortcut reaches.
class CopyableSelectionArea extends StatefulWidget {
  const CopyableSelectionArea({super.key, required this.child});

  final Widget child;

  @override
  State<CopyableSelectionArea> createState() => _CopyableSelectionAreaState();
}

class _CopyableSelectionAreaState extends State<CopyableSelectionArea> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'CopyableSelectionArea');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _handleSelectionChanged(SelectedContent? content) {
    // An empty selection means the user cleared it or started elsewhere;
    // grabbing focus then would steal it from the input field for nothing.
    if (content == null || content.plainText.isEmpty) return;
    if (!_focusNode.hasFocus) _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      focusNode: _focusNode,
      onSelectionChanged: _handleSelectionChanged,
      child: widget.child,
    );
  }
}
