import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TvKeyHandler extends StatelessWidget {
  final Widget child;
  final VoidCallback? onBack;
  final VoidCallback? onMenu;
  final VoidCallback? onPlayPause;
  final VoidCallback? onSearch;

  const TvKeyHandler({
    super.key,
    required this.child,
    this.onBack,
    this.onMenu,
    this.onPlayPause,
    this.onSearch,
  });

  bool _isBackKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.goBack;
  }

  bool _isMenuKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.contextMenu;
  }

  bool _isPlayPauseKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause;
  }

  bool _isSearchKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.find;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;

        if (_isBackKey(key)) {
          onBack?.call();
          return KeyEventResult.handled;
        }
        if (_isMenuKey(key)) {
          onMenu?.call();
          return KeyEventResult.handled;
        }
        if (_isPlayPauseKey(key)) {
          onPlayPause?.call();
          return KeyEventResult.handled;
        }
        if (_isSearchKey(key)) {
          onSearch?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}
