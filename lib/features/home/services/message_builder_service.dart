import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../../../core/database/chat_database_repository.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/message_part.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/memory_provider.dart';
import '../../../core/services/memory/memory_tools.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/chat/document_text_extractor.dart';
import '../../../utils/mcp_structured_image.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../../core/services/chat/prompt_transformer.dart';
import '../../../core/services/logging/context_log_models.dart';
import '../../../core/services/logging/context_logger.dart';
import '../../../core/services/search/search_tool_service.dart';
import '../../../core/services/api/builtin_tools.dart';
import '../../../core/services/api/providers/claude/claude_container.dart';
import '../../../core/services/api/providers/claude/claude_history.dart';
import '../../../core/services/api/providers/google/gemini_thought_signature.dart';
import '../../../core/models/assistant_regex.dart';
import '../../../core/utils/multimodal_input_utils.dart';
import '../../../utils/assistant_regex.dart';
import '../../../utils/markdown_media_sanitizer.dart';
import 'ocr_service.dart';

/// Service for building API messages from conversation state.
///
/// This service handles:
/// - Building API messages list from chat history
/// - Processing user messages (documents, OCR, templates)
/// - Injecting system prompts
/// - Injecting memory and recent chats context
/// - Injecting search prompts
/// - Injecting instruction prompts
/// - Applying context limits
/// - Inlining local images for model context
class MessageBuilderService {
  static const String internalMediaPathsKey = multimodalInternalMediaPathsKey;
  static const String internalRevisionIdKey = multimodalInternalRevisionIdKey;

  MessageBuilderService({
    required this.chatService,
    required this.contextProvider,
    this.chatRepository,
    this.ocrHandler,
    this.ocrPrefetch,
    this.providerArtifactLookup,
  });

  final ChatService chatService;

  /// Optional override for `promptContent` freeze and §7.6 injection.
  /// When null, falls back to [ChatService.chatRepositoryOrNull].
  final ChatDatabaseRepository? chatRepository;

  ChatDatabaseRepository? get _repo =>
      chatRepository ?? chatService.chatRepositoryOrNull;

  /// Build context (used for accessing providers via context.read)
  final BuildContext contextProvider;

  /// OCR handler for processing images (optional, injected from home_page)
  final Future<String?> Function(
    List<String> imagePaths, {
    String? revisionId,
    OcrPrepareSession? session,
    String? requestId,
  })?
  ocrHandler;

  /// Optional batch prefetch of persisted OCR before per-message processing.
  final Future<OcrPrepareSession> Function({
    required List<String> revisionIds,
    required List<String> imagePaths,
  })?
  ocrPrefetch;

  /// OCR text wrapper function
  String Function(String ocrText)? ocrTextWrapper;

  /// Provider state stored against an assistant message (a container id, a
  /// Gemini thought signature), by kind. It rides along under an internal key
  /// the provider strips.
  final String? Function(ChatMessage message, String kind)?
  providerArtifactLookup;

  /// Cache for document text extraction to avoid re-reading files on every message
  /// Keyed by path, validated with (modified + size) to avoid stale reuse.
  final Map<String, _DocTextCacheEntry> _docTextCache =
      <String, _DocTextCacheEntry>{};

  /// Collapse message versions to show only selected version per group.
  List<ChatMessage> collapseVersions(
    List<ChatMessage> items,
    Map<String, int> versionSelections,
  ) {
    final Map<String, List<ChatMessage>> byGroup =
        <String, List<ChatMessage>>{};
    final List<String> order = <String>[];

    for (final m in items) {
      final gid = (m.groupId ?? m.id);
      final list = byGroup.putIfAbsent(gid, () {
        order.add(gid);
        return <ChatMessage>[];
      });
      list.add(m);
    }

    // Sort each group by version
    for (final e in byGroup.entries) {
      e.value.sort((a, b) => a.version.compareTo(b.version));
    }

    // Select the appropriate version from each group
    final out = <ChatMessage>[];
    for (final gid in order) {
      final vers = byGroup[gid]!;
      final sel = versionSelections[gid];
      ChatMessage? selected;
      if (sel != null) {
        for (final candidate in vers) {
          if (candidate.version == sel) {
            selected = candidate;
            break;
          }
        }
      }
      out.add(selected ?? vers.last);
    }

    return out;
  }

  /// Build API messages list from current conversation state.
  ///
  /// Applies truncation and version collapsing. Attachments come from parts.
  List<Map<String, dynamic>> buildApiMessages({
    required List<ChatMessage> messages,
    required Map<String, int> versionSelections,
    required Conversation? currentConversation,
    bool includeToolMessages = false,
  }) {
    final tIndex = currentConversation?.truncateIndex ?? -1;
    final List<ChatMessage> sourceAll =
        (tIndex >= 0 && tIndex <= messages.length)
        ? messages.sublist(tIndex)
        : List.of(messages);
    final List<ChatMessage> source = collapseVersions(
      sourceAll,
      versionSelections,
    );

    final out = <Map<String, dynamic>>[];

    for (final m in source) {
      String? assistantReasoningContent;
      dynamic reasoningDetails;
      if (m.role == 'assistant') {
        assistantReasoningContent = _reasoningContentForToolContinuation(m);
        reasoningDetails = _reasoningDetailsForApi(m);
      }
      if (includeToolMessages && m.role == 'assistant') {
        final events = chatService.getToolEvents(m.id);
        if (events.isNotEmpty) {
          // Tool-call history is only valid once every call has a result.
          final hasPendingToolEvent = events.any((e) => e['content'] == null);
          if (!hasPendingToolEvent) {
            final calls = <Map<String, dynamic>>[];
            final toolMessages = <Map<String, dynamic>>[];

            for (int i = 0; i < events.length; i++) {
              final e = events[i];
              final name = (e['name'] ?? '').toString().trim();
              if (name.isEmpty) continue;
              final rawId = (e['id'] ?? '').toString().trim();
              final id = rawId.isNotEmpty
                  ? rawId
                  : 'call_${m.id.substring(0, m.id.length < 8 ? m.id.length : 8)}_$i';

              Map<String, dynamic> args = const <String, dynamic>{};
              final a = e['arguments'];
              if (a is Map) {
                args = a.map((k, v) => MapEntry(k.toString(), v));
              }
              String argumentsJson = '{}';
              try {
                argumentsJson = jsonEncode(args);
              } catch (_) {}

              calls.add({
                'id': id,
                'type': 'function',
                'function': {'name': name, 'arguments': argumentsJson},
                if (e['metadata'] is Map)
                  'metadata': (e['metadata'] as Map).cast<String, dynamic>(),
              });

              final c = e['content'];
              toolMessages.add({
                'role': 'tool',
                'name': name,
                'tool_call_id': id,
                'content': toolResultContentForModel(c?.toString()),
                if (e['metadata'] is Map)
                  'metadata': (e['metadata'] as Map).cast<String, dynamic>(),
              });
            }

            if (calls.isNotEmpty) {
              final assistantToolMessage = <String, dynamic>{
                'role': 'assistant',
                'content': '\n\n',
                'tool_calls': calls,
              };
              final turn = providerArtifactLookup?.call(
                m,
                claudeTurnArtifactKind,
              );
              if (turn != null && turn.isNotEmpty) {
                assistantToolMessage[multimodalInternalClaudeTurnKey] = turn;
              }
              // Also here: a turn that ran code and then said nothing has no
              // final message below to carry the container.
              final container = providerArtifactLookup?.call(
                m,
                claudeContainerArtifactKind,
              );
              if (container != null && container.isNotEmpty) {
                assistantToolMessage[multimodalInternalClaudeContainerKey] =
                    container;
              }
              if (assistantReasoningContent?.isNotEmpty == true) {
                assistantToolMessage['reasoning_content'] =
                    assistantReasoningContent;
              }
              // The persisted reasoning_details belong to the final round of
              // this message; attaching them to this synthetic pre-tool
              // assistant message as well would replay the same reasoning
              // twice, which OpenRouter/Anthropic reject. Only the final
              // assistant message below carries them.
              if (ContextLogger.enabled) {
                ContextSegmentTags.replaceWithSingle(
                  assistantToolMessage,
                  source: ContextSource.toolCall,
                  length: (assistantToolMessage['content'] ?? '')
                      .toString()
                      .length,
                );
                for (final toolMessage in toolMessages) {
                  ContextSegmentTags.replaceWithSingle(
                    toolMessage,
                    source: ContextSource.toolResult,
                    length: (toolMessage['content'] ?? '').toString().length,
                  );
                }
              }
              out.add(assistantToolMessage);
              out.addAll(toolMessages);
            }
          }
        }
      }

      final content = m.content;
      final mediaRefs = mediaRefsFromParts(m);
      // Pure-attachment turns have empty text content but still must be sent.
      // Document FileParts are omitted from mediaRefs (they travel via
      // document extraction), so also keep messages that still have a usable
      // ImagePart/FilePart for processUserMessagesForApi to inject text.
      if (content.isEmpty &&
          mediaRefs.isEmpty &&
          !_hasUsableAttachmentPart(m)) {
        continue;
      }
      final role = m.role == 'assistant' ? 'assistant' : 'user';
      final message = <String, dynamic>{'role': role, 'content': content};
      if (role == 'user') {
        message[internalRevisionIdKey] = m.id;
      } else {
        final container = providerArtifactLookup?.call(
          m,
          claudeContainerArtifactKind,
        );
        if (container != null && container.isNotEmpty) {
          message[multimodalInternalClaudeContainerKey] = container;
        }
        final signature = providerArtifactLookup?.call(
          m,
          geminiThoughtSignatureArtifactKind,
        );
        if (signature != null && signature.isNotEmpty) {
          message[multimodalInternalGeminiThoughtSignatureKey] = signature;
        }
      }
      if (mediaRefs.isNotEmpty) {
        message[internalMediaPathsKey] = mediaRefs;
      }
      if (role == 'user') {
        final documentRefs = documentRefsFromParts(m);
        if (documentRefs.isNotEmpty) {
          message[multimodalInternalDocumentPathsKey] = documentRefs;
        }
      }
      if (assistantReasoningContent?.isNotEmpty == true) {
        message['reasoning_content'] = assistantReasoningContent;
      }
      if (reasoningDetails != null) {
        message['reasoning_details'] = reasoningDetails;
      }
      if (ContextLogger.enabled) {
        ContextSegmentTags.replaceWithSingle(
          message,
          source: ContextSource.chatHistory,
          length: content.length,
        );
      }
      out.add(message);
    }

    return out;
  }

  /// Collect structured `_kelivo_media_paths` entries from image/file parts.
  ///
  /// Skips unavailable parts. Document (non-media) FileParts are omitted — they
  /// travel through document extraction, or as [documentRefsFromParts] for a
  /// provider that takes the file itself.
  static List<Map<String, dynamic>> mediaRefsFromParts(ChatMessage message) {
    final refs = <Map<String, dynamic>>[];
    for (final part in message.parts) {
      if (part is ImagePart) {
        if (part.unavailable) continue;
        final uri = part.uri.trim();
        if (uri.isEmpty) continue;
        refs.add(encodeInternalMediaRef(uri: uri, mime: part.mime));
      } else if (part is FilePart) {
        if (part.unavailable) continue;
        final uri = part.uri.trim();
        if (uri.isEmpty) continue;
        final effectiveMime = resolveMediaAttachmentMime(
          explicitMime: part.mime ?? '',
          fileName: part.name,
          path: uri,
        );
        if (!(isImageMime(effectiveMime) ||
            isAudioMime(effectiveMime) ||
            isVideoMime(effectiveMime))) {
          continue;
        }
        // Prefer resolved media mime over stale generics like
        // application/octet-stream stored on the part.
        refs.add(
          encodeInternalMediaRef(
            uri: uri,
            mime: effectiveMime.isEmpty ? null : effectiveMime,
          ),
        );
      }
    }
    return refs;
  }

  /// Collect `_kelivo_document_paths` entries: the FileParts that
  /// [mediaRefsFromParts] leaves out.
  static List<Map<String, dynamic>> documentRefsFromParts(ChatMessage message) {
    final refs = <Map<String, dynamic>>[];
    for (final part in message.parts) {
      if (part is! FilePart || part.unavailable) continue;
      final uri = part.uri.trim();
      if (uri.isEmpty) continue;
      final mime = resolveMediaAttachmentMime(
        explicitMime: part.mime ?? '',
        fileName: part.name,
        path: uri,
      );
      if (isImageMime(mime) || isAudioMime(mime) || isVideoMime(mime)) {
        continue;
      }
      refs.add(
        encodeInternalDocumentRef((uri: uri, name: part.name, mime: mime)),
      );
    }
    return refs;
  }

  /// True when the message still has a non-unavailable image/file attachment
  /// that should survive into API preparation even without media refs.
  static bool _hasUsableAttachmentPart(ChatMessage message) {
    for (final part in message.parts) {
      if (part is ImagePart && !part.unavailable) {
        if (part.uri.trim().isNotEmpty) return true;
      } else if (part is FilePart && !part.unavailable) {
        if (part.uri.trim().isNotEmpty) return true;
      }
    }
    return false;
  }

  /// Remove internal keys before provider requests.
  void stripInternalRevisionIds(List<Map<String, dynamic>> apiMessages) {
    for (final message in apiMessages) {
      message.remove(internalRevisionIdKey);
      message.remove(kelivoContextSegmentsKey);
    }
  }

  ChatMessage? _latestPersistedMessage(ChatMessage message) {
    final persisted = chatService.getMessages(message.conversationId);
    for (final candidate in persisted) {
      if (candidate.id == message.id) return candidate;
    }
    return null;
  }

  String _reasoningContentForToolContinuation(ChatMessage message) {
    String pick(ChatMessage candidate) {
      final direct = (candidate.reasoningText ?? '').trim();
      if (direct.isNotEmpty) return direct;

      final raw = (candidate.reasoningSegmentsJson ?? '').trim();
      if (raw.isEmpty) return '';
      try {
        final decoded = jsonDecode(raw);
        final segmentsRaw = switch (decoded) {
          Map<String, dynamic> map => map['segments'],
          List<dynamic> list => list,
          _ => null,
        };
        if (segmentsRaw is! List) return '';
        final parts = <String>[];
        for (final item in segmentsRaw) {
          if (item is! Map) continue;
          final text = (item['text'] ?? '').toString().trim();
          if (text.isNotEmpty) parts.add(text);
        }
        return parts.join('\n').trim();
      } catch (_) {
        return '';
      }
    }

    final fromMessage = pick(message);
    if (fromMessage.isNotEmpty) return fromMessage;

    final persisted = _latestPersistedMessage(message);
    if (persisted == null) return '';
    return pick(persisted);
  }

  /// Extract persisted vendor reasoning details (OpenRouter-style
  /// `reasoning_details`, may carry thinking signatures) so they can be
  /// echoed back to the provider on later turns.
  dynamic _reasoningDetailsForApi(ChatMessage message) {
    dynamic pick(ChatMessage candidate) {
      final raw = (candidate.reasoningSegmentsJson ?? '').trim();
      if (raw.isEmpty) return null;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) return null;
        final details = decoded['reasoningDetails'];
        if (details is List && details.isNotEmpty) return details;
      } catch (_) {}
      return null;
    }

    final fromMessage = pick(message);
    if (fromMessage != null) return fromMessage;

    final persisted = _latestPersistedMessage(message);
    if (persisted == null) return null;
    return pick(persisted);
  }

  /// Parse attachments from structured [ChatMessage.parts].
  ///
  /// Parts-only contract for API request building. Content-marker decode is
  /// not performed here — migration owns that via the legacy decoder.
  ChatInputData parseInputFromMessage(
    ChatMessage message, {
    bool includeMediaFilePathsAsImages = true,
  }) {
    final images = <String>[];
    final docs = <DocumentAttachment>[];
    final textParts = <String>[];
    for (final part in message.parts) {
      if (part is TextPart) {
        textParts.add(part.text);
      } else if (part is ImagePart) {
        // Unavailable parts stay in persisted history for UI placeholders but
        // must not enter API media paths.
        if (part.unavailable) continue;
        final uri = part.uri.trim();
        if (uri.isNotEmpty) images.add(uri);
      } else if (part is FilePart) {
        if (part.unavailable) continue;
        final doc = DocumentAttachment(
          path: part.uri,
          fileName: part.name,
          mime: part.mime ?? '',
        );
        docs.add(doc);
        final effectiveMime = _effectiveAttachmentMime(doc);
        if (includeMediaFilePathsAsImages &&
            (isImageMime(effectiveMime) ||
                isVideoMime(effectiveMime) ||
                isAudioMime(effectiveMime)) &&
            part.uri.trim().isNotEmpty) {
          images.add(part.uri.trim());
        }
      }
    }
    return ChatInputData(
      text: textParts.join().trim(),
      imagePaths: images,
      documents: docs,
    );
  }

  /// Build [ChatInputData] from an API map when no [ChatMessage] is available.
  ///
  /// Uses content text plus [internalMediaPathsKey] only — no marker decode.
  ChatInputData parseInputFromApiMap(
    Map<String, dynamic> message, {
    bool includeMediaFilePathsAsImages = true,
  }) {
    final text = (message['content'] ?? '').toString();
    final mediaRefs = parseInternalMediaRefs(message[internalMediaPathsKey]);
    final mediaPaths = [for (final ref in mediaRefs) ref.uri];
    if (!includeMediaFilePathsAsImages) {
      return ChatInputData(text: text.trim(), imagePaths: mediaPaths);
    }
    final images = <String>[];
    final docs = <DocumentAttachment>[];
    for (final ref in mediaRefs) {
      final path = ref.uri;
      final mime = (ref.mime != null && ref.mime!.trim().isNotEmpty)
          ? ref.mime!.trim()
          : inferMediaMimeFromSource(path);
      if (isAudioMime(mime) || isVideoMime(mime)) {
        final name = path.split(RegExp(r'[\\/]')).last;
        docs.add(
          DocumentAttachment(
            path: path,
            fileName: name.isEmpty ? 'file' : name,
            mime: mime,
          ),
        );
        images.add(path);
      } else {
        images.add(path);
      }
    }
    return ChatInputData(
      text: text.trim(),
      imagePaths: images,
      documents: docs,
    );
  }

  String _effectiveAttachmentMime(DocumentAttachment attachment) {
    return resolveDocumentAttachmentMime(attachment);
  }

  /// True when [apiMessages] still carries attachments that
  /// [processUserMessagesForApi] may have to extract or OCR.
  ///
  /// Deliberately a superset: a frozen prompt can still turn the work into a
  /// no-op. A false result, however, guarantees there is no file work at all —
  /// the remaining cost (frozen prompt reads, memory injection, templating) is
  /// not file parsing and must never raise the parsing indicator.
  bool hasPendingAttachmentWork(
    List<Map<String, dynamic>> apiMessages,
    SettingsProvider settings, {
    Conversation? conversation,
    List<ChatMessage>? sourceMessages,
    bool sandboxDataFiles = false,
  }) {
    final bool ocrActive =
        settings.ocrEnabled &&
        settings.ocrModelProvider != null &&
        settings.ocrModelId != null &&
        ocrHandler != null;

    for (final message in apiMessages) {
      if (message['role'] != 'user') continue;
      // WorldBook lore also uses role=user; only persisted input carries a
      // revision id and can hold attachments.
      final revisionId = (message[internalRevisionIdKey] ?? '')
          .toString()
          .trim();
      if (revisionId.isEmpty) continue;
      final chatMessage = _resolveChatMessage(
        revisionId: revisionId,
        conversation: conversation,
        sourceMessages: sourceMessages,
      );
      final parsed = chatMessage != null
          ? parseInputFromMessage(chatMessage)
          : parseInputFromApiMap(message);

      final mediaPaths = <String>{};
      for (final document in parsed.documents) {
        final mime = _effectiveAttachmentMime(document);
        if (isVideoMime(mime) || isAudioMime(mime)) {
          final path = document.path.trim();
          if (path.isNotEmpty) mediaPaths.add(path);
          continue;
        }
        if (sandboxDataFiles &&
            isSandboxDataFile(fileName: document.fileName, mime: mime)) {
          continue;
        }
        // A document that still needs text extraction.
        return true;
      }
      if (!ocrActive) continue;
      for (final rawPath in parsed.imagePaths) {
        final path = rawPath.trim();
        if (path.isEmpty || mediaPaths.contains(path)) continue;
        // An image OCR still has to read.
        return true;
      }
    }
    return false;
  }

  /// Process user messages in apiMessages: prefer frozen `promptContent`, else
  /// assemble (docs/OCR → memory prefix → template → time) and freeze (§8).
  ///
  /// With [sandboxDataFiles], data files (see [isSandboxDataFile]) are left
  /// out of the prompt for the provider to hand to its sandbox, and a message
  /// carrying one is not frozen: the frozen prompt is provider-neutral, and a
  /// later regeneration on a provider without a sandbox needs the text back.
  ///
  /// Returns the image paths from the last user message (for API call).
  Future<List<String>> processUserMessagesForApi(
    List<Map<String, dynamic>> apiMessages,
    SettingsProvider settings,
    Assistant? assistant, {
    Conversation? conversation,
    List<ChatMessage>? sourceMessages,
    bool sandboxDataFiles = false,
  }) async {
    final bool ocrActive =
        settings.ocrEnabled &&
        settings.ocrModelProvider != null &&
        settings.ocrModelId != null;

    List<String>? lastUserImagePaths;

    // Only real persisted user messages carry an internal revision ID.
    // WorldBook lore may also use role=user and must not be treated as chat input.
    bool isPersistedUserMessage(Map<String, dynamic> message) {
      if (message['role'] != 'user') return false;
      return (message[internalRevisionIdKey] ?? '')
          .toString()
          .trim()
          .isNotEmpty;
    }

    // Find last real user message index (skip injected lore).
    int lastUserIdx = -1;
    for (int i = apiMessages.length - 1; i >= 0; i--) {
      if (isPersistedUserMessage(apiMessages[i])) {
        lastUserIdx = i;
        break;
      }
    }

    final persistedRevisionIds = <String>[
      for (final message in apiMessages)
        if (isPersistedUserMessage(message))
          (message[internalRevisionIdKey] ?? '').toString().trim(),
    ];
    final frozenPrompts = _repo == null
        ? null
        : await _repo!.getMessagePrompts(persistedRevisionIds);

    // Prefetch OCR only for messages that still need generation (no freeze yet).
    OcrPrepareSession? ocrSession;
    if (ocrActive && ocrPrefetch != null) {
      final revisionIds = <String>[];
      final allImagePaths = <String>{};
      for (final message in apiMessages) {
        if (!isPersistedUserMessage(message)) continue;
        final revisionId = (message[internalRevisionIdKey] ?? '')
            .toString()
            .trim();
        if (frozenPrompts?.containsKey(revisionId) ?? false) continue;
        final revisionForParse = revisionId;
        final chatForParse = _resolveChatMessage(
          revisionId: revisionForParse,
          conversation: conversation,
          sourceMessages: sourceMessages,
        );
        final parsedUser = chatForParse != null
            ? parseInputFromMessage(chatForParse)
            : parseInputFromApiMap(message);
        final videoPaths = <String>{
          for (final d in parsedUser.documents)
            if (isVideoMime(_effectiveAttachmentMime(d))) d.path.trim(),
        }..removeWhere((p) => p.isEmpty);
        final audioPaths = <String>{
          for (final d in parsedUser.documents)
            if (isAudioMime(_effectiveAttachmentMime(d))) d.path.trim(),
        }..removeWhere((p) => p.isEmpty);
        final ocrTargets = parsedUser.imagePaths
            .map((p) => p.trim())
            .where(
              (p) =>
                  p.isNotEmpty &&
                  !videoPaths.contains(p) &&
                  !audioPaths.contains(p),
            )
            .toSet();
        if (ocrTargets.isEmpty) continue;
        if (revisionId.isNotEmpty) revisionIds.add(revisionId);
        allImagePaths.addAll(ocrTargets);
      }
      if (allImagePaths.isNotEmpty) {
        try {
          ocrSession = await ocrPrefetch!(
            revisionIds: revisionIds,
            imagePaths: allImagePaths.toList(growable: false),
          );
        } catch (_) {
          ocrSession = null;
        }
      }
    }

    Future<String?> readDocument(DocumentAttachment d) async {
      // Resolve once so cache key and extractor share the same absolute path.
      // null means rejected (UNC/SMB) — never fall back to the raw path.
      final resolvedPath = SandboxPathResolver.resolveForIo(d.path);
      if (resolvedPath == null) return null;
      // Use file stat to detect content changes without hashing.
      FileStat? stat;
      try {
        stat = await File(resolvedPath).stat();
      } catch (_) {
        stat = null;
      }
      if (stat != null) {
        final cached = _docTextCache[resolvedPath];
        if (cached != null &&
            cached.modifiedMs == stat.modified.millisecondsSinceEpoch &&
            cached.size == stat.size) {
          return cached.text;
        }
      }
      try {
        final text = await DocumentTextExtractor.extractResolved(
          path: resolvedPath,
          mime: d.mime,
        );
        // Cache only when stat is available; otherwise avoid staleness.
        if (stat != null) {
          _docTextCache[resolvedPath] = _DocTextCacheEntry(
            text: text,
            modifiedMs: stat.modified.millisecondsSinceEpoch,
            size: stat.size,
          );
        }
        return text;
      } catch (_) {
        if (stat != null) {
          _docTextCache[resolvedPath] = _DocTextCacheEntry(
            text: null,
            modifiedMs: stat.modified.millisecondsSinceEpoch,
            size: stat.size,
          );
        }
        return null;
      }
    }

    for (int i = 0; i < apiMessages.length; i++) {
      if (!isPersistedUserMessage(apiMessages[i])) continue;
      final revisionId = (apiMessages[i][internalRevisionIdKey] ?? '')
          .toString()
          .trim();
      final chatMessageForParts = _resolveChatMessage(
        revisionId: revisionId,
        conversation: conversation,
        sourceMessages: sourceMessages,
      );
      final parsedUser = chatMessageForParts != null
          ? parseInputFromMessage(chatMessageForParts)
          : parseInputFromApiMap(apiMessages[i]);
      final videoPaths = <String>{
        for (final d in parsedUser.documents)
          if (isVideoMime(_effectiveAttachmentMime(d))) d.path.trim(),
      }..removeWhere((p) => p.isEmpty);
      final audioPaths = <String>{
        for (final d in parsedUser.documents)
          if (isAudioMime(_effectiveAttachmentMime(d))) d.path.trim(),
      }..removeWhere((p) => p.isEmpty);

      final mimeByPath = <String, String>{};
      if (chatMessageForParts != null) {
        for (final part in chatMessageForParts.parts) {
          if (part is ImagePart) {
            if (part.unavailable) continue;
            final uri = part.uri.trim();
            if (uri.isEmpty) continue;
            // Prefer resolved media mime over stale generics like
            // application/octet-stream stored on the part.
            final fileName = uri.split(RegExp(r'[\\/]')).last;
            final effectiveMime = resolveMediaAttachmentMime(
              explicitMime: part.mime ?? '',
              fileName: fileName.isEmpty ? uri : fileName,
              path: uri,
            );
            if (effectiveMime.isNotEmpty) mimeByPath[uri] = effectiveMime;
          } else if (part is FilePart) {
            if (part.unavailable) continue;
            final uri = part.uri.trim();
            if (uri.isEmpty) continue;
            final effectiveMime = _effectiveAttachmentMime(
              DocumentAttachment(
                path: uri,
                fileName: part.name,
                mime: part.mime ?? '',
              ),
            );
            if (effectiveMime.isNotEmpty) mimeByPath[uri] = effectiveMime;
          }
        }
      } else {
        for (final ref in parseInternalMediaRefs(
          apiMessages[i][internalMediaPathsKey],
        )) {
          final uri = ref.uri.trim();
          if (uri.isEmpty) continue;
          final fileName = uri.split(RegExp(r'[\\/]')).last;
          final effectiveMime = resolveMediaAttachmentMime(
            explicitMime: ref.mime ?? '',
            fileName: fileName.isEmpty ? uri : fileName,
            path: uri,
          );
          if (effectiveMime.isNotEmpty) mimeByPath[uri] = effectiveMime;
        }
        for (final d in parsedUser.documents) {
          final path = d.path.trim();
          final mime = _effectiveAttachmentMime(d);
          if (path.isNotEmpty && mime.isNotEmpty) {
            mimeByPath.putIfAbsent(path, () => mime);
          }
        }
      }

      final messageMediaPaths = <Map<String, dynamic>>[];
      final seenPaths = <String>{};
      for (final rawPath in parsedUser.imagePaths) {
        final path = rawPath.trim();
        if (path.isEmpty || !seenPaths.add(path)) continue;
        if (ocrActive &&
            !videoPaths.contains(path) &&
            !audioPaths.contains(path)) {
          continue;
        }
        final mime = mimeByPath[path];
        messageMediaPaths.add(encodeInternalMediaRef(uri: path, mime: mime));
      }
      if (messageMediaPaths.isEmpty) {
        apiMessages[i].remove(internalMediaPathsKey);
      } else {
        apiMessages[i][internalMediaPathsKey] = messageMediaPaths;
      }

      // Capture image paths from last user message (from parts).
      if (i == lastUserIdx &&
          lastUserImagePaths == null &&
          parsedUser.imagePaths.isNotEmpty) {
        lastUserImagePaths = List<String>.of(parsedUser.imagePaths);
      }

      // Prefer frozen promptContent — never recompute (§8.3).
      final existing = frozenPrompts?[revisionId];
      if (existing != null) {
        apiMessages[i]['content'] = existing.payload;
        if (ContextLogger.enabled) {
          ContextSegmentTags.replaceWithSingle(
            apiMessages[i],
            source: ContextSource.chatHistory,
            length: existing.payload.length,
          );
        }
        continue;
      }

      // Apply replace-only regexes at send-time on user text.
      final replacedUserText = applyAssistantRegexes(
        parsedUser.text,
        assistant: assistant,
        scope: AssistantRegexScope.user,
        target: AssistantRegexTransformTarget.send,
      );

      // Attachments travel via internalMediaPathsKey / lastUserImagePaths —
      // never re-embed legacy attachment markers into content.
      final cleanedUser = replacedUserText.trim();

      final filePrompts = StringBuffer();
      var leftToSandbox = false;
      for (final d in parsedUser.documents) {
        final effectiveMime = _effectiveAttachmentMime(d);
        if (isVideoMime(effectiveMime) || isAudioMime(effectiveMime)) {
          continue;
        }
        if (sandboxDataFiles &&
            isSandboxDataFile(fileName: d.fileName, mime: effectiveMime)) {
          leftToSandbox = true;
          continue;
        }
        final text = await readDocument(d);
        if (text == null || text.trim().isEmpty) continue;
        filePrompts.writeln('## user sent a file: ${d.fileName}');
        filePrompts.writeln('<content>');
        filePrompts.writeln('```');
        filePrompts.writeln(text);
        filePrompts.writeln('```');
        filePrompts.writeln('</content>');
        filePrompts.writeln();
      }

      String merged = (filePrompts.toString() + cleanedUser).trim();
      var canFreezePrompt = !leftToSandbox;

      if (ocrActive && ocrHandler != null) {
        final ocrTargets = parsedUser.imagePaths
            .map((p) => p.trim())
            .where(
              (p) =>
                  p.isNotEmpty &&
                  !videoPaths.contains(p) &&
                  !audioPaths.contains(p),
            )
            .toSet()
            .toList();
        if (ocrTargets.isNotEmpty) {
          final ocrText = await ocrHandler!(
            ocrTargets,
            revisionId: revisionId.isEmpty ? null : revisionId,
            session: ocrSession,
            requestId: conversation?.id,
          );
          if (ocrText == null) {
            canFreezePrompt = false;
          } else if (ocrText.trim().isNotEmpty) {
            final wrapped = ocrTextWrapper != null
                ? ocrTextWrapper!(ocrText)
                : _defaultWrapOcrBlock(ocrText);
            merged = (wrapped + merged).trim();
          }
        }
      }

      final processedBody = merged.isEmpty ? cleanedUser : merged;
      final chatMessage = _resolveChatMessage(
        revisionId: revisionId,
        conversation: conversation,
        sourceMessages: sourceMessages,
      );

      if (conversation != null && chatMessage != null) {
        apiMessages[i]['content'] = await resolvePromptContent(
          message: chatMessage,
          processedUserBody: processedBody,
          assistant: assistant,
          conversation: conversation,
          settings: settings,
          apiMessages: apiMessages,
          readFrozenPrompt: false,
          freezePrompt: canFreezePrompt,
        );
      } else {
        // No conversation or no matching stored message: nothing to freeze
        // against, so render the template directly.
        final templ =
            (assistant?.messageTemplate ?? '{{ message }}').trim().isEmpty
            ? '{{ message }}'
            : (assistant?.messageTemplate ?? '{{ message }}');
        final now = chatMessage?.timestamp ?? DateTime.now();
        var content = PromptTransformer.applyMessageTemplate(
          templ,
          role: 'user',
          message: processedBody,
          now: now,
        );
        if (assistant?.appendCurrentTimeToUserMessage == true) {
          content =
              '$content\n\n${PromptTransformer.formatCurrentTimeTag(now)}';
        }
        apiMessages[i]['content'] = content;
      }
    }

    return lastUserImagePaths ?? <String>[];
  }

  /// The stored message behind an api payload, or null when it cannot be
  /// found.
  ///
  /// [sourceMessages] is the list this request's api payloads were built from
  /// and is checked first. `ChatService.getMessages` only serves conversations
  /// already in its cache, so on a freshly created conversation it returns
  /// nothing and the new message would silently skip memory injection and
  /// freezing — then pick both up a turn later, rewriting history and losing
  /// the prompt cache.
  ///
  /// A synthesized stand-in would have to invent a timestamp, and freezing that
  /// would bake the wrong `{{ time }}` into the prompt forever, so a genuine
  /// miss returns null and stays on the unfrozen render path.
  ChatMessage? _resolveChatMessage({
    required String revisionId,
    required Conversation? conversation,
    required List<ChatMessage>? sourceMessages,
  }) {
    if (revisionId.isEmpty) return null;
    // Prefer the request's source messages even when Conversation is absent —
    // otherwise structured ImagePart/FilePart attachments are dropped and the
    // caller silently falls back to content-only parsing.
    if (sourceMessages != null) {
      for (final candidate in sourceMessages) {
        if (candidate.id == revisionId) return candidate;
      }
    }
    if (conversation == null) return null;
    for (final candidate in chatService.getMessages(conversation.id)) {
      if (candidate.id == revisionId) return candidate;
    }
    return null;
  }

  /// §8.3 immutability contract: return frozen payload or assemble + freeze.
  Future<String> resolvePromptContent({
    required ChatMessage message,
    required String processedUserBody,
    required Assistant? assistant,
    required Conversation conversation,
    required SettingsProvider settings,
    required List<Map<String, dynamic>> apiMessages,
    bool readFrozenPrompt = true,
    bool freezePrompt = true,
  }) async {
    final repo = _repo;
    final persist =
        repo != null &&
        !chatService.isTemporaryConversation(message.conversationId);
    if (persist && readFrozenPrompt) {
      final existing = await repo.getMessagePrompt(message.id);
      if (existing != null) return existing.payload;
    }

    final templ = (assistant?.messageTemplate ?? '{{ message }}').trim().isEmpty
        ? '{{ message }}'
        : (assistant!.messageTemplate);
    final templated = PromptTransformer.applyMessageTemplate(
      templ,
      role: 'user',
      message: processedUserBody,
      now: message.timestamp,
    );
    final timeSuffix = (assistant?.appendCurrentTimeToUserMessage ?? false)
        ? '\n\n${PromptTransformer.formatCurrentTimeTag(message.timestamp)}'
        : '';
    final finalContent = '$templated$timeSuffix';

    if (ContextLogger.enabled) {
      for (final apiMessage in apiMessages) {
        if ((apiMessage[internalRevisionIdKey] ?? '').toString() !=
            message.id) {
          continue;
        }
        ContextSegmentTags.replaceWithSingle(
          apiMessage,
          source: ContextSource.chatHistory,
          length: finalContent.length,
        );
        break;
      }
    }

    // Temporary drafts never land in message_rows; freezing would violate the
    // message_prompt_rows FK. Assemble in-memory only for those.
    if (persist && freezePrompt) {
      await repo.freezeMessagePrompt(
        revisionId: message.id,
        conversationId: message.conversationId,
        payload: finalContent,
      );
    }

    return finalContent;
  }

  /// Default OCR text wrapper
  String _defaultWrapOcrBlock(String ocrText) {
    final buf = StringBuffer();
    buf.writeln(
      "The image_file_ocr tag contains a description of an image that the user uploaded to you, not the user's prompt.",
    );
    buf.writeln('<image_file_ocr>');
    buf.writeln(ocrText.trim());
    buf.writeln('</image_file_ocr>');
    buf.writeln();
    return buf.toString();
  }

  /// Inject system prompt into apiMessages.
  void injectSystemPrompt(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant,
    String modelId,
  ) {
    if ((assistant?.systemPrompt.trim().isNotEmpty ?? false)) {
      final vars = PromptTransformer.buildPlaceholders(
        context: contextProvider,
        assistant: assistant!,
        modelId: modelId,
        modelName: modelId,
        userNickname: contextProvider.read<UserProvider>().name,
      );
      final sys = PromptTransformer.replacePlaceholders(
        assistant.systemPrompt,
        vars,
      );
      final sysMessage = <String, dynamic>{'role': 'system', 'content': sys};
      if (ContextLogger.enabled) {
        ContextSegmentTags.replaceWithSingle(
          sysMessage,
          source: ContextSource.systemPrompt,
          length: sys.length,
        );
      }
      apiMessages.insert(0, sysMessage);
    }
  }

  /// Append the memory index to the system message.
  ///
  /// Only the index — file names and their headings — is injected. The bodies
  /// stay on disk behind `memory_search` / `memory_read`, so enabling memory
  /// costs a handful of tokens rather than the whole corpus, and the model
  /// pulls in what a given turn actually needs.
  Future<void> injectMemory(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant,
  ) async {
    try {
      if (assistant?.enableMemory != true) return;
      final memory = contextProvider.read<MemoryProvider>();
      await memory.initialize();
      _appendToSystemMessage(
        apiMessages,
        MemoryTools.buildSystemBlock(memory.files),
        source: ContextSource.memory,
      );
    } catch (_) {}
  }

  /// Inject search tool usage prompt into apiMessages.
  void injectSearchPrompt(
    List<Map<String, dynamic>> apiMessages,
    SettingsProvider settings,
    Assistant? assistant,
    bool hasBuiltInSearch,
  ) {
    if (assistant?.searchEnabled == true && !hasBuiltInSearch) {
      final prompt = SearchToolService.getSystemPrompt();
      _appendToSystemMessage(
        apiMessages,
        prompt,
        source: ContextSource.searchPrompt,
      );
    }
  }

  /// Helper to append content to the system message (or create one if missing).
  void _appendToSystemMessage(
    List<Map<String, dynamic>> apiMessages,
    String content, {
    ContextSource? source,
  }) {
    if (apiMessages.isNotEmpty && apiMessages.first['role'] == 'system') {
      apiMessages[0]['content'] =
          '${(apiMessages[0]['content'] ?? '') as String}\n\n$content';
      if (ContextLogger.enabled && source != null) {
        ContextSegmentTags.append(
          apiMessages[0],
          source: source,
          length: 2 + content.length,
        );
      }
    } else {
      final message = <String, dynamic>{'role': 'system', 'content': content};
      if (ContextLogger.enabled && source != null) {
        ContextSegmentTags.append(
          message,
          source: source,
          length: content.length,
        );
      }
      apiMessages.insert(0, message);
    }
  }

  /// Apply context message limit based on assistant settings.
  void applyContextLimit(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant,
  ) {
    if ((assistant?.limitContextMessages ?? false) &&
        (assistant?.contextMessageSize ?? 0) > 0) {
      final int keep = (assistant!.contextMessageSize).clamp(
        Assistant.minContextMessageSize,
        Assistant.maxContextMessageSize,
      );
      int startIdx = 0;
      if (apiMessages.isNotEmpty && apiMessages.first['role'] == 'system') {
        startIdx = 1;
      }
      final tail = apiMessages.sublist(startIdx);
      if (tail.length > keep) {
        final trimmed = tail.sublist(tail.length - keep);
        apiMessages
          ..removeRange(startIdx, apiMessages.length)
          ..addAll(trimmed);
      }
      // Context trimming can cut in the middle of a tool-call triplet; avoid sending dangling tool messages.
      while (apiMessages.length > startIdx &&
          (apiMessages[startIdx]['role'] ?? '').toString() == 'tool') {
        apiMessages.removeAt(startIdx);
      }
    }
  }

  /// Convert local Markdown image links to inline base64 for model context.
  Future<void> inlineLocalImages(List<Map<String, dynamic>> apiMessages) async {
    for (int i = 0; i < apiMessages.length; i++) {
      final s = (apiMessages[i]['content'] ?? '').toString();
      if (s.isNotEmpty) {
        apiMessages[i]['content'] =
            await MarkdownMediaSanitizer.inlineLocalImagesToBase64(s);
      }
    }
  }

  /// Check if built-in search is enabled for the given provider/model.
  bool hasBuiltInSearch(
    SettingsProvider settings,
    String providerKey,
    String modelId,
  ) {
    try {
      final cfg = settings.getProviderConfig(providerKey);
      return BuiltInToolsHelper.isBuiltInSearchEnabled(
        cfg: cfg,
        modelId: modelId,
      );
    } catch (_) {
      return false;
    }
  }
}

class _DocTextCacheEntry {
  const _DocTextCacheEntry({
    required this.text,
    required this.modifiedMs,
    required this.size,
  });

  final String? text;
  final int modifiedMs;
  final int size;
}
