import 'dart:io';

import '../../../utils/app_directories.dart';

/// One memory file as the index sees it: its name plus the first non-empty
/// line, which by convention is a Markdown heading describing the topic.
typedef MemoryFileSummary = ({
  String name,
  String summary,
  int bytes,
  DateTime modifiedAt,
});

/// A single grep hit: the file, the 1-based line number, and the line itself.
typedef MemoryMatch = ({String name, int line, String text});

/// Plain-Markdown memory: one `.md` file per topic under `<appData>/memory`.
///
/// There is no index, no embedding, and no database row — search is a literal
/// scan of file contents, so what the model reads is exactly what is on disk
/// and a user editing a file by hand changes what the model sees.
class MemoryFileStore {
  MemoryFileStore(this.directory);

  final Directory directory;

  /// Opens the store at `<appData>/memory`, creating the directory if needed.
  static Future<MemoryFileStore> open() async {
    final dir = await AppDirectories.getMemoryDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return MemoryFileStore(dir);
  }

  /// Longest file a memory may be. Past this the model should split the topic
  /// rather than grow one unreadable file.
  static const int maxFileBytes = 64 * 1024;

  /// Default cap on grep hits so one broad query cannot flood the context.
  static const int defaultMaxMatches = 50;

  /// Normalizes [raw] into a safe bare filename ending in `.md`.
  ///
  /// Returns null when nothing usable survives. Path separators, `..`, and
  /// leading dots are rejected outright rather than escaped: a memory file
  /// never legitimately points outside the memory directory.
  static String? normalizeName(String raw) {
    var name = raw.trim().toLowerCase();
    if (name.isEmpty) return null;
    if (name.contains('/') || name.contains(r'\')) return null;
    if (name == '.' || name == '..' || name.startsWith('.')) return null;
    if (name.endsWith('.md')) name = name.substring(0, name.length - 3);
    name = name.replaceAll(RegExp(r'[^a-z0-9._-]+'), '-');
    name = name.replaceAll(RegExp(r'-{2,}'), '-');
    name = name.replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
    if (name.isEmpty) return null;
    if (name.length > 64) name = name.substring(0, 64);
    return '$name.md';
  }

  File _fileFor(String name) => File('${directory.path}/$name');

  /// Every memory file, newest first.
  Future<List<MemoryFileSummary>> list() async {
    if (!await directory.exists()) return const <MemoryFileSummary>[];
    final out = <MemoryFileSummary>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.endsWith('.md')) continue;
      final stat = await entity.stat();
      out.add((
        name: name,
        summary: _summarize(await _readSafely(entity)),
        bytes: stat.size,
        modifiedAt: stat.modified,
      ));
    }
    out.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return out;
  }

  Future<String?> read(String rawName) async {
    final name = normalizeName(rawName);
    if (name == null) return null;
    final file = _fileFor(name);
    if (!await file.exists()) return null;
    return _readSafely(file);
  }

  /// Creates or replaces a memory file. Returns the stored name.
  ///
  /// Throws [ArgumentError] on an unusable name and [RangeError] when the
  /// content exceeds [maxFileBytes] — both are model errors worth reporting
  /// back as a tool failure rather than silently truncating.
  Future<String> write(String rawName, String content) async {
    final name = normalizeName(rawName);
    if (name == null) throw ArgumentError.value(rawName, 'name');
    if (content.length > maxFileBytes) {
      throw RangeError.value(content.length, 'content');
    }
    if (!await directory.exists()) await directory.create(recursive: true);
    await _fileFor(name).writeAsString(content, flush: true);
    return name;
  }

  Future<bool> delete(String rawName) async {
    final name = normalizeName(rawName);
    if (name == null) return false;
    final file = _fileFor(name);
    if (!await file.exists()) return false;
    await file.delete();
    return true;
  }

  /// Case-insensitive grep for [query] across every memory file.
  ///
  /// [query] is matched literally, not as a regular expression: the model
  /// searches for words it remembers writing, and an unescaped `(` from a
  /// natural-language query would otherwise throw instead of finding nothing.
  Future<List<MemoryMatch>> search(
    String query, {
    int maxMatches = defaultMaxMatches,
  }) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const <MemoryMatch>[];
    final out = <MemoryMatch>[];
    for (final summary in await list()) {
      final content = await _readSafely(_fileFor(summary.name));
      final lines = content.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].toLowerCase().contains(needle)) continue;
        out.add((name: summary.name, line: i + 1, text: lines[i].trim()));
        if (out.length >= maxMatches) return out;
      }
    }
    return out;
  }

  /// Total bytes on disk, for the storage-usage screen.
  Future<int> totalBytes() async {
    var total = 0;
    for (final summary in await list()) {
      total += summary.bytes;
    }
    return total;
  }

  static Future<String> _readSafely(File file) async {
    try {
      return await file.readAsString();
    } on FileSystemException {
      return '';
    }
  }

  /// First non-empty line, stripped of Markdown heading marks.
  static String _summarize(String content) {
    for (final line in content.split('\n')) {
      final trimmed = line.trim().replaceAll(RegExp(r'^#+\s*'), '');
      if (trimmed.isNotEmpty) {
        return trimmed.length > 120 ? '${trimmed.substring(0, 120)}…' : trimmed;
      }
    }
    return '';
  }
}
