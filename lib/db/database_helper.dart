import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:convert/convert.dart';

class DatabaseHelper {
  static Database? _db;

  // ============================
  // ダミー鍵投入数（初回DB作成時）
  // ============================
  static const int kDummyKeyInsertCount = 100;

  // ----------------------------
  // DB インスタンス取得
  // ----------------------------
  static Future<Database> getDatabase() async {
    if (_db != null) return _db!;

    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'my_ecd.db');

    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (Database db, int version) async {
        await _createTables(db);

        // ★ 初回作成時も同じ API を使う
        await insertDummyKeys(
          db: db,
          count: kDummyKeyInsertCount,
        );
      },
    );

    return _db!;
  }

  // ----------------------------
  // テーブル定義
  // ----------------------------
  static Future<void> _createTables(Database db) async {
    await db.execute('''
    CREATE TABLE generated_keys (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      seckey_ecd BLOB NOT NULL,
      pubkey_ecd BLOB NOT NULL,
      lat INTEGER,
      lon INTEGER,
      generate_time INTEGER NOT NULL,
      expire_time INTEGER NOT NULL
    )
  ''');

    await db.execute('''
    CREATE TABLE collected_keys (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pubkey_ecd BLOB NOT NULL UNIQUE,
      receive_time INTEGER NOT NULL
    )
  ''');
  }

  // ============================================================
  // ★ ダミー鍵を assets から先頭 count 件投入（唯一の実装）
  // ============================================================
  static Future<int> insertDummyKeys({
    Database? db,
    required int count,
  }) async {
    final Database database = db ?? await getDatabase();

    if (count <= 0) return 0;

    final text = await rootBundle.loadString('assets/dummy_keys.txt');
    final lines = text.split('\n');

    if (lines.isEmpty) return 0;

    final batch = database.batch();
    final now = DateTime.now().millisecondsSinceEpoch;

    int inserted = 0;

    for (final line in lines) {
      if (inserted >= count) break;

      final key = line.trim();
      if (key.isEmpty) continue;

      // 圧縮公開鍵: 33 bytes = 66 hex chars
      if (key.length != 66) continue;

      batch.insert(
        'collected_keys',
        {
          'pubkey_ecd': Uint8List.fromList(hex.decode(key)),
          'receive_time': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

      inserted++;
    }

    await batch.commit(noResult: true);
    return inserted;
  }

  // ----------------------------
  // 収集鍵が存在するかチェック
  // ----------------------------
  static Future<bool> existsCollectedKey(Uint8List key33) async {
    final db = await getDatabase();
    final count = Sqflite.firstIntValue(
      await db.rawQuery(
        "SELECT COUNT(*) FROM collected_keys WHERE pubkey_ecd = ?",
        [key33],
      ),
    );
    return (count ?? 0) > 0;
  }

  // ----------------------------
  // 新規収集鍵 INSERT（存在しない場合のみ）
  // ----------------------------
  static Future<bool> insertCollectedKeyIfAbsent({
    required Uint8List pubkey33,
    required int tms,
  }) async {
    final db = await getDatabase();

    final exists = Sqflite.firstIntValue(
      await db.rawQuery(
        "SELECT COUNT(*) FROM collected_keys WHERE pubkey_ecd = ?",
        [pubkey33],
      ),
    );

    if ((exists ?? 0) > 0) return false;

    await db.insert(
      'collected_keys',
      {
        'pubkey_ecd': pubkey33,
        'receive_time': tms,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    return true;
  }

  // ----------------------------
  // キー合計数
  // ----------------------------
  Future<int> getTotalKeyCount() async {
    final db = await getDatabase();

    final generated = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM generated_keys'),
    ) ?? 0;

    final collected = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM collected_keys'),
    ) ?? 0;

    return generated + collected;
  }

  // ----------------------------
  // 削除
  // ----------------------------
  static Future<void> deleteKey({
    required KeyTable table,
    required int id,
  }) async {
    final db = await getDatabase();

    final tableName = switch (table) {
      KeyTable.generated => 'generated_keys',
      KeyTable.collected => 'collected_keys',
    };

    await db.delete(
      tableName,
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}

enum KeyTable {
  generated,
  collected,
}
