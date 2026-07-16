import 'package:flutter/widgets.dart';
import 'focus_traversal_policy.dart';

class TvFocusGroup extends StatelessWidget {
  final Widget child;

  const TvFocusGroup({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: TvReadingOrderTraversalPolicy(),
      child: child,
    );
  }
}
