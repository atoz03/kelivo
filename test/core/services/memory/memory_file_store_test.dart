import 'dart:io';

import 'package:Kelivo/core/services/memory/memory_file_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late MemoryFileStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('kelivo_memory_store_');
    store = MemoryFileStore(directory);
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  group('normalizeName', () {
    test('adds the .md suffix and lowercases', () {
      expect(MemoryFileStore.normalizeName('Preferences'), 'preferences.md');
      expect(MemoryFileStore.normalizeName('notes.md'), 'notes.md');
    });

    test('replaces runs of unsupported characters with one dash', () {
      expect(
        MemoryFileStore.normalizeName('My Project  Notes!'),
        'my-project-notes.md',
      );
    });

    test('refuses anything that could escape the memory directory', () {
      for (final raw in const ['..', '.', '../etc/passwd', 'a/b', r'a\b']) {
        expect(MemoryFileStore.normalizeName(raw), isNull, reason: raw);
      }
    });

    test('refuses names that normalize to nothing', () {
      expect(MemoryFileStore.normalizeName('   '), isNull);
      expect(MemoryFileStore.normalizeName('---'), isNull);
    });
  });

  test('write, read, and delete round trip', () async {
    final stored = await store.write('Preferences', '# Preferences\n\n- Terse');
    expect(stored, 'preferences.md');
    expect(await store.read('preferences.md'), '# Preferences\n\n- Terse');
    // The name is normalized on read too, so the model may use either form.
    expect(await store.read('Preferences'), '# Preferences\n\n- Terse');

    expect(await store.delete('preferences.md'), isTrue);
    expect(await store.read('preferences.md'), isNull);
    expect(await store.delete('preferences.md'), isFalse);
  });

  test(
    'write refuses an unusable name and content past the size cap',
    () async {
      await expectLater(
        store.write('..', 'nope'),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        store.write('big', 'x' * (MemoryFileStore.maxFileBytes + 1)),
        throwsA(isA<RangeError>()),
      );
    },
  );

  test('list reports the first non-empty line as the summary', () async {
    await store.write('projects', '\n\n# Kelivo\n\nA Flutter chat client.');
    final files = await store.list();
    expect(files, hasLength(1));
    expect(files.single.name, 'projects.md');
    expect(files.single.summary, 'Kelivo');
  });

  test('list ignores non-Markdown files', () async {
    await File('${directory.path}/notes.txt').writeAsString('ignored');
    await store.write('kept', '# Kept');
    expect((await store.list()).map((f) => f.name), ['kept.md']);
  });

  group('search', () {
    setUp(() async {
      await store.write('a', '# A\nlikes strong coffee\nand tea');
      await store.write('b', '# B\nprefers COFFEE in the morning');
    });

    test('is case-insensitive and reports file and line', () async {
      final matches = await store.search('coffee');
      expect(matches.map((m) => m.name).toSet(), {'a.md', 'b.md'});
      final a = matches.firstWhere((m) => m.name == 'a.md');
      expect(a.line, 2);
      expect(a.text, 'likes strong coffee');
    });

    test('matches literally rather than as a regular expression', () async {
      await store.write('c', '# C\ncost is (approximately) five');
      expect(await store.search('(approximately)'), hasLength(1));
      // An unescaped regex metacharacter must find nothing, not throw.
      expect(await store.search('coffee('), isEmpty);
    });

    test('an empty query matches nothing', () async {
      expect(await store.search('   '), isEmpty);
    });

    test('caps the number of hits', () async {
      await store.write('many', List.filled(20, 'needle').join('\n'));
      expect(await store.search('needle', maxMatches: 5), hasLength(5));
    });
  });
}
