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

      // ★ 初回作成時のみテーブル作成される
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
        seckey_ecd BLOB,
        pubkey_ecd BLOB,
        generate_time INTEGER,
        expire_time INTEGER
      )
    ''');

    // 収集鍵（UNIQUE）
    await db.execute('''
      CREATE TABLE ecd_keys (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        key_ecd BLOB NOT NULL UNIQUE,
        lat INTEGER NOT NULL,
        lon INTEGER NOT NULL,
        ts INTEGER NOT NULL
      )
    ''');
  }

  // ----------------------------
  // 収集鍵が存在するかチェック
  // ----------------------------
  static Future<bool> existsCollectedKey(Uint8List key33) async {
    final db = await getDatabase();
    final count = Sqflite.firstIntValue(await db.rawQuery(
      "SELECT COUNT(*) FROM ecd_keys WHERE key_ecd = ?",
      [key33],
    ));
    return (count ?? 0) > 0;
  }

  // ----------------------------
  // 新規収集鍵 INSERT（存在しない場合のみ）
  // ----------------------------
  static Future<bool> insertCollectedKeyIfAbsent({
    required Uint8List pubkey33,
    required int tms,
    required int latE6,
    required int lonE6,
  }) async {
    final db = await getDatabase();

    final exists = Sqflite.firstIntValue(await db.rawQuery(
      "SELECT COUNT(*) FROM ecd_keys WHERE key_ecd = ?",
      [pubkey33],
    ));

    if ((exists ?? 0) > 0) return false;

    await db.insert(
      'ecd_keys',
      {
        'key_ecd': pubkey33,
        'ts': tms ~/ 1000,
        'lat': latE6,
        'lon': lonE6,
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
    final generated = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM generated_keys',
    )) ?? 0;

    final collected = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM ecd_keys',
    )) ?? 0;

    return generated + collected;
  }
}
