import 'dart:convert';

import 'memory_file_store.dart';

/// Declarations and dispatch for the Markdown memory tools.
///
/// Tool descriptions are a model contract, so they live here as English
/// constants rather than in the ARB files — the UI language must not change
/// what the model is told a tool does.
abstract final class MemoryTools {
  MemoryTools._();

  static const String memorySearch = 'memory_search';
  static const String memoryRead = 'memory_read';
  static const String memoryWrite = 'memory_write';
  static const String memoryDelete = 'memory_delete';

  static const Set<String> allToolNames = {
    memorySearch,
    memoryRead,
    memoryWrite,
    memoryDelete,
  };

  /// Tools that change what is on disk.
  static const Set<String> writeToolNames = {memoryWrite, memoryDelete};

  /// Every definition, ungated — for the tool-schema settings editor.
  static List<Map<String, dynamic>> catalogDefinitions() => [
    _searchDef(),
    _readDef(),
    _writeDef(),
    _deleteDef(),
  ];

  /// The definitions to send for one request.
  ///
  /// [allowWrites] is false in temporary conversations, where a read stays
  /// useful but a write would outlive the conversation the user asked to be
  /// throwaway.
  static List<Map<String, dynamic>> buildDefinitions({
    required bool enableMemory,
    bool allowWrites = true,
  }) {
    if (!enableMemory) return const <Map<String, dynamic>>[];
    return [
      _searchDef(),
      _readDef(),
      if (allowWrites) ...[_writeDef(), _deleteDef()],
    ];
  }

  static Map<String, dynamic> _fn(
    String name,
    String description,
    Map<String, dynamic> properties,
    List<String> required,
  ) => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': {
        'type': 'object',
        'properties': properties,
        'required': required,
      },
    },
  };

  static Map<String, dynamic> _searchDef() => _fn(
    memorySearch,
    'Search your memory files for a literal, case-insensitive string. '
    'Returns matching lines with their file name and line number. Use this '
    'before answering anything that may depend on what you already know '
    'about the user.',
    {
      'query': {
        'type': 'string',
        'description': 'Text to look for, matched literally.',
      },
    },
    ['query'],
  );

  static Map<String, dynamic> _readDef() => _fn(
    memoryRead,
    'Read one memory file in full. Use the file names listed in your system '
    'prompt or returned by memory_search.',
    {
      'file': {
        'type': 'string',
        'description': 'File name, e.g. "preferences.md".',
      },
    },
    ['file'],
  );

  static Map<String, dynamic> _writeDef() => _fn(
    memoryWrite,
    'Create or replace a memory file. Write durable facts worth recalling in '
    'later conversations — preferences, ongoing projects, stable context — '
    'not transcripts. Keep one topic per file and start the file with a '
    'Markdown heading. This replaces the whole file, so read it first and '
    'include everything you want to keep.',
    {
      'file': {
        'type': 'string',
        'description':
            'File name, e.g. "preferences.md". Lowercase, no directories.',
      },
      'content': {'type': 'string', 'description': 'Full Markdown content.'},
    },
    ['file', 'content'],
  );

  static Map<String, dynamic> _deleteDef() => _fn(
    memoryDelete,
    'Delete a memory file that is no longer true or useful.',
    {
      'file': {'type': 'string', 'description': 'File name to delete.'},
    },
    ['file'],
  );

  /// Runs [name] against [store]. Returns null when [name] is not a memory
  /// tool, so the caller can keep looking.
  ///
  /// [onMutated] fires after a write or delete so open memory UI reloads.
  static Future<String?> handle({
    required String name,
    required Map<String, dynamic> args,
    required MemoryFileStore store,
    Future<void> Function()? onMutated,
  }) async {
    if (!allToolNames.contains(name)) return null;
    try {
      final result = await _dispatch(name, args, store);
      if (writeToolNames.contains(name)) await onMutated?.call();
      return result;
    } catch (e) {
      return jsonEncode({'ok': false, 'error': e.toString()});
    }
  }

  static Future<String> _dispatch(
    String name,
    Map<String, dynamic> args,
    MemoryFileStore store,
  ) async {
    switch (name) {
      case memorySearch:
        final matches = await store.search((args['query'] ?? '').toString());
        return jsonEncode({
          'ok': true,
          'matches': [
            for (final m in matches)
              {'file': m.name, 'line': m.line, 'text': m.text},
          ],
        });

      case memoryRead:
        final file = (args['file'] ?? '').toString();
        final content = await store.read(file);
        if (content == null) {
          return jsonEncode({'ok': false, 'error': 'not_found', 'file': file});
        }
        return jsonEncode({'ok': true, 'file': file, 'content': content});

      case memoryWrite:
        final stored = await store.write(
          (args['file'] ?? '').toString(),
          (args['content'] ?? '').toString(),
        );
        return jsonEncode({'ok': true, 'file': stored});

      case memoryDelete:
        final file = (args['file'] ?? '').toString();
        final removed = await store.delete(file);
        return jsonEncode({
          'ok': removed,
          'file': file,
          if (!removed) 'error': 'not_found',
        });

      default:
        throw StateError(name);
    }
  }

  /// The block appended to the system prompt when memory is enabled.
  ///
  /// Listing every file name and its heading is what makes grep usable: the
  /// model can only search for a topic it knows exists.
  static String buildSystemBlock(List<MemoryFileSummary> files) {
    final buffer = StringBuffer('## Memory\n\n');
    if (files.isEmpty) {
      buffer.write(
        'Your memory is empty. When you learn something durable about the '
        'user — a preference, an ongoing project, stable context — save it '
        'with memory_write.',
      );
      return buffer.toString();
    }
    buffer.write(
      'Markdown files you have saved. Use memory_search to grep them and '
      'memory_read to open one. Keep them current with memory_write.\n\n',
    );
    for (final file in files) {
      buffer.write(
        file.summary.isEmpty
            ? '- ${file.name}\n'
            : '- ${file.name} — ${file.summary}\n',
      );
    }
    return buffer.toString().trimRight();
  }
}
