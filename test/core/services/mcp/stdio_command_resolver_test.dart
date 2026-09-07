import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/mcp/stdio_command_resolver.dart';

void main() {
  group('mergePathValues', () {
    test('keeps the first occurrence and removes empty entries', () {
      final merged = mergePathValues(<String?>[
        '/usr/local/bin::/usr/bin',
        '/usr/local/bin:/opt/bin',
        null,
      ], separator: ':');

      expect(merged, '/usr/local/bin:/usr/bin:/opt/bin');
    });
  });

  group('McpStdioCommandResolver.resolveEnvironmentWithPath', () {
    test('leaves a user-provided Path key untouched', () async {
      final resolver = McpStdioCommandResolver(
        isMacOS: true,
        macOSPathReader: () async => '/from/launchctl',
      );

      final resolved = await resolver.resolveEnvironmentWithPath(const {
        'Path': '/custom',
      });

      expect(resolved, const {'Path': '/custom'});
    });

    test('uses launchctl PATH on macOS', () async {
      final resolver = McpStdioCommandResolver(
        isMacOS: true,
        macOSPathReader: () async => '/usr/local/bin:/usr/bin',
      );

      final resolved = await resolver.resolveEnvironmentWithPath(const {});

      expect(resolved['PATH'], '/usr/local/bin:/usr/bin');
    });

    test('leaves the environment alone off macOS', () async {
      final resolver = McpStdioCommandResolver(
        isMacOS: false,
        macOSPathReader: () async => '/never/read',
      );

      expect(await resolver.resolveEnvironmentWithPath(const {}), isEmpty);
    });
  });

  group('McpStdioCommandResolver.commandExists', () {
    test('resolves a command against the supplied PATH', () async {
      final resolver = McpStdioCommandResolver(
        isMacOS: true,
        commandOnPathExists: (command, environment) async =>
            command == 'npx' && environment['PATH'] == '/opt/node/bin',
      );

      expect(
        await resolver.commandExists('npx', const {'PATH': '/opt/node/bin'}),
        isTrue,
      );
    });

    test('an empty command never reaches the lookup', () async {
      var lookups = 0;
      final resolver = McpStdioCommandResolver(
        isMacOS: true,
        commandOnPathExists: (_, _) async {
          lookups += 1;
          return true;
        },
      );

      expect(await resolver.commandExists('   ', const {}), isFalse);
      expect(lookups, 0);
    });
  });
}
