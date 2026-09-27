import 'assistant.dart';

/// Prompt overrides owned by a conversation, persisted in its Drift extras.
class ConversationPromptSettings {
  static const systemPromptKey = 'prompt.system';

  final String systemPrompt;

  const ConversationPromptSettings({this.systemPrompt = ''});

  factory ConversationPromptSettings.fromExtras(Map<String, dynamic> extras) {
    return ConversationPromptSettings(
      systemPrompt: extras[systemPromptKey] is String
          ? extras[systemPromptKey] as String
          : '',
    );
  }

  String effectiveSystemPrompt(Assistant? assistant) =>
      assistant?.allowConversationSystemPrompt == true &&
          systemPrompt.trim().isNotEmpty
      ? systemPrompt
      : assistant?.systemPrompt ?? '';

  Map<String, dynamic> applyTo(Map<String, dynamic> extras) {
    final next = Map<String, dynamic>.from(extras)..remove(systemPromptKey);
    if (systemPrompt.isNotEmpty) next[systemPromptKey] = systemPrompt;
    return next;
  }
}
