import 'package:flutter/foundation.dart';

import '../services/memory/memory_file_store.dart';

/// UI-facing view of the Markdown memory directory.
///
/// Holds only the index (file name + heading); bodies are read on demand so
/// opening the settings page never loads every memory into RAM.
class MemoryProvider extends ChangeNotifier {
  MemoryProvider();

  /// Injects a store rooted somewhere other than the app data directory.
  MemoryProvider.withStore(this._store);

  MemoryFileStore? _store;
  List<MemoryFileSummary> _files = const <MemoryFileSummary>[];
  bool _loaded = false;
  Future<void>? _loading;

  List<MemoryFileSummary> get files => List.unmodifiable(_files);
  bool get isLoaded => _loaded;

  /// The backing store, opened on first use.
  Future<MemoryFileStore> get store async =>
      _store ??= await MemoryFileStore.open();

  Future<void> initialize() {
    if (_loaded) return Future<void>.value();
    return _loading ??= refresh().whenComplete(() => _loading = null);
  }

  Future<void> refresh() async {
    try {
      _files = await (await store).list();
    } catch (e) {
      debugPrint('MemoryProvider.refresh failed: $e');
      _files = const <MemoryFileSummary>[];
    }
    _loaded = true;
    notifyListeners();
  }

  Future<String?> read(String name) async => (await store).read(name);

  Future<String> write(String name, String content) async {
    final stored = await (await store).write(name, content);
    await refresh();
    return stored;
  }

  Future<bool> delete(String name) async {
    final removed = await (await store).delete(name);
    if (removed) await refresh();
    return removed;
  }
}
