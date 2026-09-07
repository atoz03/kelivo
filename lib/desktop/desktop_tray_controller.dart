import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/services/app_exit_flush.dart';
import '../l10n/app_localizations.dart';

/// Desktop tray + window close behaviour controller.
///
/// - Manages system tray icon visibility and context menu
/// - Implements "minimize to tray on close" when enabled in settings
class DesktopTrayController with TrayListener, WindowListener {
  DesktopTrayController._();
  static final DesktopTrayController instance = DesktopTrayController._();

  bool _initialized = false;
  bool _isDesktop = false;
  bool _trayVisible = false;
  bool _showTraySetting = false;
  bool _minimizeToTrayOnClose = false;
  String _localeKey = '';
  bool _contextMenuOpen = false;

  /// Sync tray state from settings & current localization.
  /// Safe to call multiple times; initialization is performed lazily.
  Future<void> syncFromSettings(
    AppLocalizations l10n, {
    required bool showTray,
    required bool minimizeToTrayOnClose,
  }) async {
    if (kIsWeb) return;
    final isDesktop = defaultTargetPlatform == TargetPlatform.macOS;
    if (!isDesktop) return;
    _isDesktop = true;

    if (!_initialized) {
      try {
        await windowManager.ensureInitialized();
      } catch (_) {}
      try {
        trayManager.addListener(this);
      } catch (_) {}
      try {
        windowManager.addListener(this);
      } catch (_) {}
      _initialized = true;
    }

    // Persist latest settings (enforce basic invariant in controller as well).
    _showTraySetting = showTray;
    _minimizeToTrayOnClose = showTray && minimizeToTrayOnClose;

    // Whether to intercept window close.
    final shouldPreventClose = _showTraySetting && _minimizeToTrayOnClose;
    try {
      await windowManager.setPreventClose(shouldPreventClose);
    } catch (_) {}

    // Handle tray icon visibility + localized menu.
    final newLocaleKey = l10n.localeName;
    final localeChanged = newLocaleKey != _localeKey;
    _localeKey = newLocaleKey;

    if (_showTraySetting) {
      if (!_trayVisible || localeChanged) {
        await _ensureTrayIconAndMenu(l10n);
        _trayVisible = true;
      }
    } else {
      if (_trayVisible) {
        try {
          await trayManager.destroy();
        } catch (_) {}
        _trayVisible = false;
      }
    }
  }

  Future<void> _ensureTrayIconAndMenu(AppLocalizations l10n) async {
    if (!_isDesktop) return;

    // A template PNG lets the system adapt the icon to a light/dark menu bar.
    try {
      await trayManager.setIcon('assets/icon_mac.png', isTemplate: true);
    } catch (_) {}

    try {
      await trayManager.setToolTip('Kelivo');
    } catch (_) {}
    try {
      final menu = Menu(
        items: [
          MenuItem(
            label: l10n.desktopTrayMenuShowWindow,
            onClick: (_) async => _showWindow(),
          ),
          MenuItem.separator(),
          MenuItem(
            label: l10n.desktopTrayMenuExit,
            onClick: (_) async => _exitApp(),
          ),
        ],
      );
      await trayManager.setContextMenu(menu);
    } catch (_) {}
  }

  Future<void> _showWindow() async {
    if (!_isDesktop) return;
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  Future<void> _exitApp() async {
    if (!_isDesktop) return;
    try {
      // Drain pending writes before exiting. On macOS/Linux destroy()
      // routes through the engine's exit-request channel (which flushes
      // again — flush handlers are idempotent), but on Windows the
      // destroy() fallback posts WM_QUIT directly and bypasses WM_CLOSE,
      // so without this the fallback exit would skip the flush entirely.
      // The timeout keeps a stuck write queue from hanging tray exit.
      try {
        await AppExitFlush.flushAll().timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
      } catch (_) {}
      // Destroy the window so the process exits cleanly.
      await windowManager.destroy();
    } catch (_) {}
  }

  // ===== TrayListener =====

  @override
  void onTrayIconMouseDown() {
    // Left‑click: bring main window to front.
    if (!_isDesktop) return;
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() async {
    // Right‑click: 弹出托盘菜单。
    // 使用内部标记防止在一次交互周期内重复弹出，
    // 否则在某些 Windows 环境下会看到第二个偏移的菜单。
    if (_contextMenuOpen) {
      return;
    }
    _contextMenuOpen = true;
    try {
      await trayManager.popUpContextMenu();
    } catch (_) {}
    // 无论是点击菜单项还是点击其他地方关闭菜单，
    // popUpContextMenu 都会在菜单关闭后返回，这里统一重置标记。
    _contextMenuOpen = false;
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    // 任一菜单项被点击视为一次菜单交互结束，
    // 额外保险地解除防抖标记（即使 Future 尚未完成）。
    _contextMenuOpen = false;
  }

  // ===== WindowListener =====

  @override
  void onWindowClose() async {
    if (!_isDesktop) return;
    // Only intercept close when user enabled minimize-to-tray.
    final shouldIntercept = _showTraySetting && _minimizeToTrayOnClose;
    if (!shouldIntercept) return;
    try {
      final isPreventClose = await windowManager.isPreventClose();
      if (!isPreventClose) return;
      await windowManager.hide();
    } catch (_) {}
  }
}
