import 'dart:typed_data';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseHelper {
  static Database? _db;

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
      // ★ 初回作成時のみテーブル作成
      onCreate: (Database db, int version) async {
        await _createTables(db);
      },
    );

    return _db!;
  }

  // ----------------------------
  // テーブル定義
  // ----------------------------
  static Future<void> _createTables(Database db) async {
    // 生成鍵
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

    // 収集鍵
    await db.execute('''
    CREATE TABLE collected_keys (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pubkey_ecd BLOB NOT NULL UNIQUE,
      receive_time INTEGER NOT NULL
    )
  ''');
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
  // ★ 位置情報は扱わない
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
  // キー合計数（任意）
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