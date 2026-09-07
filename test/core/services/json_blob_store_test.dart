import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/business_data.dart';
import 'package:Kelivo/core/database/business_preferences.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/models/quick_phrase.dart';
import 'package:Kelivo/core/services/quick_phrase_store.dart';

void main() {
  late AppDatabase database;
  late BusinessRepository repository;
  late BusinessPreferences preferences;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    repository = BusinessRepository(database);
    preferences = BusinessPreferences(repository);
    await database.customSelect('SELECT 1;').getSingle();
  });

  tearDown(() => database.close());

  group('serialized read-modify-write', () {
    test('concurrent quick phrase writes keep every record', () async {
      final store = QuickPhraseStore(preferences);
      await Future.wait([
        for (var index = 0; index < 10; index++)
          store.add(
            QuickPhrase(
              id: 'phrase-$index',
              title: 'title-$index',
              content: 'content-$index',
            ),
          ),
      ]);

      final all = await store.getAll();
      expect(all, hasLength(10));
      expect(
        all.map((phrase) => phrase.id).toSet(),
        containsAll([for (var index = 0; index < 10; index++) 'phrase-$index']),
      );
    });
  });

  group('corrupted blob', () {
    Future<void> seedCorruptRow(
      BusinessEntityKind kind, {
      String? assistantId,
    }) {
      return repository.upsertEntity(
        kind,
        BusinessEntityValue(
          id: 'corrupt',
          sortOrder: 0,
          payload: assistantId == null
              ? '{"id":123,"title":"broken"}'
              : '{"id":"not-an-int","assistantId":"$assistantId","content":"x"}',
          assistantId: assistantId,
        ),
      );
    }

    test(
      'quick phrase store refuses writes and preserves stored rows',
      () async {
        await seedCorruptRow(BusinessEntityKind.quickPhrase);
        final store = QuickPhraseStore(preferences);

        await expectLater(store.getAll(), throwsStateError);
        await expectLater(
          store.add(
            const QuickPhrase(id: 'new', title: 'title', content: 'content'),
          ),
          throwsStateError,
        );
        await expectLater(store.delete('corrupt'), throwsStateError);

        final rows = await repository.readEntities(
          BusinessEntityKind.quickPhrase,
        );
        expect(rows, hasLength(1));
        expect(rows.single.id, 'corrupt');
      },
    );

    test(
      'synchronizeEntities refuses to delete rows with undecodable payloads',
      () async {
        await repository.replaceEntities(BusinessEntityKind.quickPhrase, [
          const BusinessEntityValue(
            id: 'kept',
            sortOrder: 0,
            payload: '{"id":"kept"}',
          ),
        ]);
        await database.customStatement(
          'INSERT INTO quick_phrase_rows '
          '(id, sort_order, payload, updated_at) VALUES (?, ?, ?, ?);',
          <Object?>['broken', 1, 'not json', 0],
        );

        await expectLater(
          repository.synchronizeEntities(BusinessEntityKind.quickPhrase, [
            const BusinessEntityValue(
              id: 'kept',
              sortOrder: 0,
              payload: '{"id":"kept"}',
            ),
          ]),
          throwsStateError,
        );

        final rows = await repository.readEntities(
          BusinessEntityKind.quickPhrase,
        );
        expect(
          rows.map((row) => row.id),
          containsAll(<String>['kept', 'broken']),
        );
      },
    );
  });
}
