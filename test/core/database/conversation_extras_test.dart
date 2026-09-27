import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/core/models/conversation_prompt_settings.dart';

void main() {
  late AppDatabase database;
  late ChatDatabaseRepository repository;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    repository = ChatDatabaseRepository(database);
    await repository.ensureReady();
  });

  tearDown(() => repository.close());

  test('putConversation round-trips extras', () async {
    final conversation = Conversation(
      id: 'c1',
      title: 'Chat',
      extras: const {'prompt.system': 'Be brief.', 'count': 2, 'flag': true},
    );
    await repository.putConversation(conversation);
    final loaded = await repository.getConversation('c1');
    expect(loaded, isNotNull);
    expect(loaded!.extras['prompt.system'], 'Be brief.');
    expect(loaded.extras['count'], 2);
    expect(loaded.extras['flag'], isTrue);
  });

  test('malformed extras_json becomes an empty map', () async {
    await repository.putConversation(Conversation(id: 'c2', title: 'Chat'));
    await database.customStatement(
      "UPDATE conversation_rows SET extras_json = 'not-json' WHERE id = 'c2';",
    );
    final loaded = await repository.getConversation('c2');
    expect(loaded!.extras, isEmpty);
  });

  test(
    'updateConversationExtras writes atomically and bumps updatedAt',
    () async {
      final createdAt = DateTime.utc(2026, 9, 1);
      await repository.putConversation(
        Conversation(
          id: 'c3',
          title: 'Chat',
          createdAt: createdAt,
          updatedAt: createdAt,
          extras: const {'keep': true},
        ),
      );

      await repository.updateConversationExtras('c3', (current) {
        return const ConversationPromptSettings(
          systemPrompt: 'Be brief.',
        ).applyTo(current);
      });

      final afterSet = await repository.getConversation('c3');
      expect(afterSet!.extras['keep'], isTrue);
      expect(
        afterSet.extras[ConversationPromptSettings.systemPromptKey],
        'Be brief.',
      );
      expect(afterSet.updatedAt.isAfter(createdAt), isTrue);

      final setUpdatedAt = afterSet.updatedAt;
      await repository.updateConversationExtras('c3', (current) {
        return Map<String, dynamic>.from(current);
      });
      final unchanged = await repository.getConversation('c3');
      expect(unchanged!.updatedAt, setUpdatedAt);

      await repository.updateConversationExtras('c3', (current) {
        return const ConversationPromptSettings().applyTo(current);
      });
      final cleared = await repository.getConversation('c3');
      expect(
        cleared!.extras.containsKey(ConversationPromptSettings.systemPromptKey),
        isFalse,
      );
      expect(cleared.extras['keep'], isTrue);
      expect(cleared.updatedAt.isAfter(setUpdatedAt), isTrue);
    },
  );

  test('duplicateConversation keeps extras', () async {
    await repository.putConversation(
      Conversation(
        id: 'source',
        title: 'Chat',
        extras: const {'prompt.system': 'Be brief.'},
      ),
    );
    final duplicate = await repository.duplicateConversation('source');
    expect(duplicate, isNotNull);
    expect(duplicate!.extras['prompt.system'], 'Be brief.');
    expect(duplicate.id, isNot('source'));
  });
}
