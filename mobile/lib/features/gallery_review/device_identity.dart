import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

/// App-private persistence survives updates/sign-out, but not uninstall or clear data.
/// SQLite serializes first use by foreground/background isolates.
String loadInstallationId(String path) {
  final db = sqlite3.open(path);
  try {
    db.execute('PRAGMA busy_timeout=5000');
    db.execute('CREATE TABLE IF NOT EXISTS identity (id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL)');
    db.execute('INSERT OR IGNORE INTO identity(id,value) VALUES(1,?)', [const Uuid().v4()]);
    return db.select('SELECT value FROM identity WHERE id=1').single['value'] as String;
  } finally {
    db.close();
  }
}

String reviewDeviceIdentity(String androidId, String packageName, String accountId) =>
    sha256.convert(utf8.encode(jsonEncode(['gallery-review-device-v1', androidId, packageName, accountId]))).toString();
