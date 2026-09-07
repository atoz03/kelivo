// ignore_for_file: prefer_initializing_formals

import 'dart:io' show Platform, Process;

typedef StdioCommandLookup =
    Future<bool> Function(String command, Map<String, String> environment);
typedef StdioPathReader = Future<String?> Function();

class McpStdioCommandResolver {
  McpStdioCommandResolver({
    bool? isMacOS,
    StdioCommandLookup? commandOnPathExists,
    StdioPathReader? macOSPathReader,
  }) : _isMacOSOverride = isMacOS,
       _commandOnPathExists = commandOnPathExists,
       _macOSPathReader = macOSPathReader;

  final bool? _isMacOSOverride;
  final StdioCommandLookup? _commandOnPathExists;
  final StdioPathReader? _macOSPathReader;

  String? _cachedSystemPath;
  Future<String?>? _systemPathFuture;

  Future<Map<String, String>> resolveEnvironmentWithPath(
    Map<String, String> userEnv,
  ) async {
    final merged = Map<String, String>.from(userEnv);
    if (_environmentValue(merged, 'PATH') != null) return merged;

    final systemPath = await _getSystemPath();
    if (systemPath != null && systemPath.isNotEmpty) {
      merged['PATH'] = systemPath;
    }
    return merged;
  }

  Future<bool> commandExists(
    String command,
    Map<String, String> environment,
  ) async {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return false;
    return _commandOnPathExistsImpl(trimmed, environment);
  }

  /// A GUI macOS app inherits a minimal PATH, so ask launchd for the login
  /// one before giving up on finding the server binary.
  Future<String?> _getSystemPath() {
    final cachedFuture = _systemPathFuture;
    if (cachedFuture != null) return cachedFuture;

    final future = () async {
      if (_cachedSystemPath != null) return _cachedSystemPath;

      if (_isMacOS) {
        final macOSPath = await (_macOSPathReader ?? _readMacOSLaunchPath)();
        if (macOSPath != null && macOSPath.isNotEmpty) {
          _cachedSystemPath = macOSPath;
          return _cachedSystemPath;
        }
      }

      return null;
    }();

    _systemPathFuture = future;
    return future;
  }

  Future<bool> _commandOnPathExistsImpl(
    String command,
    Map<String, String> environment,
  ) async {
    final lookup = _commandOnPathExists;
    if (lookup != null) return lookup(command, environment);

    try {
      final result = await Process.run(
        'which',
        <String>[command],
        environment: environment,
        runInShell: true,
      );
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  bool get _isMacOS => _isMacOSOverride ?? Platform.isMacOS;
}

String mergePathValues(
  Iterable<String?> values, {
  required String separator,
  bool caseSensitive = true,
}) {
  final seen = <String>{};
  final merged = <String>[];

  for (final value in values) {
    if (value == null || value.trim().isEmpty) continue;
    for (final entry in value.split(separator)) {
      final trimmed = entry.trim();
      if (trimmed.isEmpty) continue;
      final key = caseSensitive ? trimmed : trimmed.toLowerCase();
      if (seen.add(key)) merged.add(trimmed);
    }
  }

  return merged.join(separator);
}

String? _environmentValue(Map<String, String> environment, String key) {
  for (final entry in environment.entries) {
    if (entry.key.toLowerCase() == key.toLowerCase()) {
      return entry.value;
    }
  }
  return null;
}

Future<String?> _readMacOSLaunchPath() async {
  try {
    final result = await Process.run('launchctl', <String>['getenv', 'PATH']);
    if (result.exitCode == 0) return (result.stdout as String).trim();
  } catch (_) {}
  return null;
}
