import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// How much room is left on the volume holding the app's data.
///
/// Answers null wherever the platform does not tell us, and every caller
/// treats null as "proceed": a nearly-full device is worth avoiding, but
/// refusing to ever make a copy because the probe is unavailable would be a
/// worse failure than attempting one that fails cleanly.
final class DeviceStorageProbe {
  const DeviceStorageProbe._();

  static const MethodChannel _channel = MethodChannel('app.device_storage');

  /// Anything outside this range is a misread, not a measurement.
  static const _minimumPlausibleBytes = 0;
  static const _maximumPlausibleBytes = 1 << 50; // 1 PiB

  @visibleForTesting
  static Future<int?> Function()? debugOverride;

  static Future<int?> freeBytes() async {
    final override = debugOverride;
    if (override != null) return override();
    if (kIsWeb) return null;
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final value = await _channel.invokeMethod<Object?>('freeBytes');
      if (value is! int) return null;
      if (value <= _minimumPlausibleBytes) return null;
      if (value >= _maximumPlausibleBytes) return null;
      return value;
    } catch (_) {
      return null;
    }
  }
}
