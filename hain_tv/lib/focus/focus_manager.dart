import 'package:flutter/material.dart';

class TvFocusManager extends ChangeNotifier {
  final FocusNode pageFocusNode = FocusNode();

  void requestFocusToFirst(BuildContext context) {
    final scope = FocusScope.of(context);
    if (scope.focusedChild != null) return;

    final firstNode = scope.traversalDescendants.firstWhere(
      (node) => node.canRequestFocus,
      orElse: () => FocusNode(),
    );
    if (firstNode != scope) {
      firstNode.requestFocus();
    }
  }

  void unfocus(BuildContext context) {
    FocusScope.of(context).unfocus();
  }

  @override
  void dispose() {
    pageFocusNode.dispose();
    super.dispose();
  }
}
