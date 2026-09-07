import 'dart:convert';
import 'dart:io';

import 'package:Kelivo/core/services/memory/memory_file_store.dart';
import 'package:Kelivo/core/services/memory/memory_tools.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _decode(String? raw) =>
    jsonDecode(raw!) as Map<String, dynamic>;

void main() {
  late Directory directory;
  late MemoryFileStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('kelivo_memory_tools_');
    store = MemoryFileStore(directory);
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  group('buildDefinitions', () {
    List<String> namesOf(List<Map<String, dynamic>> defs) => [
      for (final def in defs) (def['function'] as Map)['name'] as String,
    ];

    test('is empty when the assistant has memory off', () {
      expect(MemoryTools.buildDefinitions(enableMemory: false), isEmpty);
    });

    test('offers read and write tools when memory is on', () {
      expect(
        namesOf(MemoryTools.buildDefinitions(enableMemory: true)),
        containsAll([
          MemoryTools.memorySearch,
          MemoryTools.memoryRead,
          MemoryTools.memoryWrite,
          MemoryTools.memoryDelete,
        ]),
      );
    });

    test('withholds the writing tools when writes are not allowed', () {
      final names = namesOf(
        MemoryTools.buildDefinitions(enableMemory: true, allowWrites: false),
      );
      expect(names, contains(MemoryTools.memorySearch));
      expect(names, contains(MemoryTools.memoryRead));
      expect(names, isNot(contains(MemoryTools.memoryWrite)));
      expect(names, isNot(contains(MemoryTools.memoryDelete)));
    });
  });

  group('handle', () {
    test('returns null for a tool it does not own', () async {
      expect(
        await MemoryTools.handle(
          name: 'search_web',
          args: const {},
          store: store,
        ),
        isNull,
      );
    });

    test('writes, reads back, searches, and deletes', () async {
      final written = _decode(
        await MemoryTools.handle(
          name: MemoryTools.memoryWrite,
          args: const {'file': 'Preferences', 'content': '# Prefs\nterse'},
          store: store,
        ),
      );
      expect(written['ok'], isTrue);
      expect(written['file'], 'preferences.md');

      final read = _decode(
        await MemoryTools.handle(
          name: MemoryTools.memoryRead,
          args: const {'file': 'preferences.md'},
          store: store,
        ),
      );
      expect(read['content'], '# Prefs\nterse');

      final searched = _decode(
        await MemoryTools.handle(
          name: MemoryTools.memorySearch,
          args: const {'query': 'terse'},
          store: store,
        ),
      );
      expect((searched['matches'] as List).single, {
        'file': 'preferences.md',
        'line': 2,
        'text': 'terse',
      });

      final deleted = _decode(
        await MemoryTools.handle(
          name: MemoryTools.memoryDelete,
          args: const {'file': 'preferences.md'},
          store: store,
        ),
      );
      expect(deleted['ok'], isTrue);
    });

    test('reports a missing file rather than throwing', () async {
      final result = _decode(
        await MemoryTools.handle(
          name: MemoryTools.memoryRead,
          args: const {'file': 'absent.md'},
          store: store,
        ),
      );
      expect(result['ok'], isFalse);
      expect(result['error'], 'not_found');
    });

    test('turns a rejected name into a tool error', () async {
      final result = _decode(
        await MemoryTools.handle(
          name: MemoryTools.memoryWrite,
          args: const {'file': '..', 'content': 'nope'},
          store: store,
        ),
      );
      expect(result['ok'], isFalse);
      expect(result['error'], isNotEmpty);
    });

    test('fires onMutated for writes but not for reads', () async {
      var mutations = 0;
      Future<void> onMutated() async => mutations++;

      await MemoryTools.handle(
        name: MemoryTools.memoryWrite,
        args: const {'file': 'a', 'content': '# A'},
        store: store,
        onMutated: onMutated,
      );
      expect(mutations, 1);

      await MemoryTools.handle(
        name: MemoryTools.memoryRead,
        args: const {'file': 'a.md'},
        store: store,
        onMutated: onMutated,
      );
      expect(mutations, 1);
    });
  });

  group('buildSystemBlock', () {
    test('tells the model how to start when memory is empty', () {
      final block = MemoryTools.buildSystemBlock(const []);
      expect(block, contains('## Memory'));
      expect(block, contains('memory_write'));
    });

    test('lists every file with its heading', () {
      final block = MemoryTools.buildSystemBlock([
        (
          name: 'preferences.md',
          summary: 'Preferences',
          bytes: 10,
          modifiedAt: DateTime.utc(2026),
        ),
        (
          name: 'bare.md',
          summary: '',
          bytes: 0,
          modifiedAt: DateTime.utc(2026),
        ),
      ]);
      expect(block, contains('- preferences.md — Preferences'));
      expect(block, contains('- bare.md'));
      expect(block, contains('memory_search'));
    });
  });
}
