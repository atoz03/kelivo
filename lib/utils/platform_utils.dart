import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:restart_app/restart_app.dart';

/// Kelivo ships two targets: Android and macOS. "Desktop" therefore means
/// macOS and "mobile" means Android — the getters keep the broader names
/// because that is what the call sites are asking about.
abstract final class PlatformUtils {
  PlatformUtils._();

  static bool get isDesktop => Platform.isMacOS;

  static bool get isMobile => Platform.isAndroid;

  static bool get isDesktopTarget =>
      defaultTargetPlatform == TargetPlatform.macOS;

  static bool get isMobileTarget =>
      defaultTargetPlatform == TargetPlatform.android;

  static bool get isAndroid => Platform.isAndroid;

  static Future<void> restartApp() async {
    final result = await Restart.restartApp(mode: RestartMode.process);
    if (!result.success) {
      throw StateError('restart_app:${result.code ?? 'unknown'}');
    }
  }
}
