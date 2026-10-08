import 'app_database.dart';

/// Device state stays in SQLite at runtime, but must not travel in a backup.
final class BackupPortability {
  BackupPortability._();

  /// Only call on a temporary database, never the live database. This also
  /// handles backups whose raw SQLite payload still has device-only rows.
  static Future<void> sanitizeDatabase(AppDatabase database) async {
    // Erase removed payloads from SQLite cells as well as its logical rows.
    await database.customStatement('PRAGMA secure_delete = ON;');
    await database.customStatement(
      "DELETE FROM extension_entity_rows WHERE kind IN ('composerDraft', 'composerNewEntry', 'composerShareReceipt', 'composerPrivateFile');",
    );
  }
}
