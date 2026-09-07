import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'window_size_manager.dart';
import 'dart:async';

/// Handles desktop window initialization and persistence (size/position/maximized).
class DesktopWindowController with WindowListener {
  DesktopWindowController._();
  static final DesktopWindowController instance = DesktopWindowController._();

  final WindowSizeManager _sizeMgr = const WindowSizeManager();
  bool _attached = false;
  // Debounce timers to avoid frequent disk writes during drag/resize
  Timer? _moveDebounce;
  Timer? _resizeDebounce;
  static const _debounceDuration = Duration(milliseconds: 400);

  Future<void> initializeAndShow({String? title}) async {
    if (kIsWeb) return;
    if (!(defaultTargetPlatform == TargetPlatform.macOS)) {
      return;
    }

    await windowManager.ensureInitialized();
    _attachListeners();

    // Let Cocoa autosave restore the last frame instead of setting the size,
    // position, or min/max from Dart — doing so makes the window jump.
    await windowManager.waitUntilReadyToShow(
      WindowOptions(title: title),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  void _attachListeners() {
    if (_attached) return;
    windowManager.addListener(this);
    _attached = true;
  }

  @override
  void onWindowResize() async {
    // Throttle saves while resizing to reduce jank
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(_debounceDuration, () async {
      try {
        final isMax = await windowManager.isMaximized();
        if (!isMax) {
          final s = await windowManager.getSize();
          await _sizeMgr.setSize(s);
        }
      } catch (_) {}
    });
  }

  @override
  void onWindowMove() async {
    // Debounce position persistence during drag to avoid main-isolate IO on every move
    _moveDebounce?.cancel();
    _moveDebounce = Timer(_debounceDuration, () async {
      try {
        final offset = await windowManager.getPosition();
        await _sizeMgr.setPosition(offset);
      } catch (_) {}
    });
  }

  @override
  void onWindowMaximize() async {
    try {
      await _sizeMgr.setWindowMaximized(true);
      // Mark position as origin placeholder to avoid stale restore when maximized.
      await _sizeMgr.setPosition(const Offset(0, 0));
    } catch (_) {}
  }

  @override
  void onWindowUnmaximize() async {
    try {
      await _sizeMgr.setWindowMaximized(false);
      // Capture current position on restore from maximized.
      final offset = await windowManager.getPosition();
      await _sizeMgr.setPosition(offset);
    } catch (_) {}
  }

  // Persist fullscreen transitions similarly to maximize/unmaximize to
  // keep state consistent across platforms and avoid position jumps.
  @override
  void onWindowEnterFullScreen() async {
    try {
      await _sizeMgr.setWindowMaximized(true);
      await _sizeMgr.setPosition(const Offset(0, 0));
    } catch (_) {}
  }

  @override
  void onWindowLeaveFullScreen() async {
    try {
      await _sizeMgr.setWindowMaximized(false);
      final offset = await windowManager.getPosition();
      await _sizeMgr.setPosition(offset);
    } catch (_) {}
  }
}
