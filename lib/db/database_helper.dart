import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseHelper {
  static Future<String> _getDbPath() async {
    final dbPath = await getDatabasesPath();
    return join(dbPath, 'my_ecd.db');
  }

  static Future<Database> getDatabase() async {
    final path = await _getDbPath();
    return openDatabase(path);
  }

  static Future<void> initDatabase() async {
    final path = await _getDbPath();

    // 初回コピー（assets/empty_ecd.db から）
    if (!await File(path).exists()) {
      final data = await rootBundle.load('assets/empty_ecd.db');
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      await File(path).writeAsBytes(bytes, flush: true);
    }

    final db = await openDatabase(path);

    // テーブルの作成（必要なら）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS generated_keys (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        seckey_ecd BLOB,
        pubkey_ecd BLOB,
        generate_time INTEGER,
        expire_time INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS ecd_keys (
        key_ecd BLOB NOT NULL,
        lat INTEGER NOT NULL,
        lon INTEGER NOT NULL,
        ts INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> insertDummyCollected() async {
    final db = await getDatabase();
    await db.insert('ecd_keys', {
      'key_ecd': List<int>.generate(17, (i) => i),
      'lat': 12345678,
      'lon': 87654321,
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
  }

  static Future<void> insertDummyGenerated() async {
    final db = await getDatabase();
    await db.insert('generated_keys', {
      'seckey_ecd': List<int>.generate(17, (i) => 100 + i),
      'pubkey_ecd': List<int>.generate(16, (i) => 200 - i),
      'generate_time': DateTime.now().millisecondsSinceEpoch,
      'expire_time': DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch,
    });
  }
}
