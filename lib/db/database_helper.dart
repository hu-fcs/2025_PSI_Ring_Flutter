// lib/db/database_helper.dart

import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseHelper {
  static Database? _db;

  // ----- Database -----

  static Future<Database> getDatabase() async {
    if (_db != null) return _db!;

    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'my_ecd.db');

    _db = await openDatabase(
      path,
      version: 2,
      onCreate: (Database db, int version) async {
        await _createTables(db);
        await _createIndexes(db);
      },
      onUpgrade: (Database db, int oldVersion, int newVersion) async {
        if (oldVersion < 2) {
          await _createIndexes(db);
        }
      },
    );

    return _db!;
  }

  // ----- Schema -----

  static Future<void> _createTables(Database db) async {
    // 生成鍵（生成集合に相当）
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

    // 収集鍵（収集集合に相当）
    // pubkey_ecd は重複を許さない
    await db.execute('''
    CREATE TABLE collected_keys (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pubkey_ecd BLOB NOT NULL UNIQUE,
      receive_time INTEGER NOT NULL
    )
  ''');

    // 友達テーブル
    await db.execute('''
      CREATE TABLE IF NOT EXISTS friends (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        label TEXT NOT NULL,         -- ユーザーが付ける名前（例：山田さん）
        note TEXT,                   -- 任意のメモ
        created_at INTEGER NOT NULL  -- 作成時刻 (Unix time, sec)
      )
    ''');

    // 友達ごとの将来ニックネームテーブル
    await db.execute('''
      CREATE TABLE IF NOT EXISTS friend_nicknames (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        friend_id INTEGER NOT NULL,
        pubkey_ecd BLOB NOT NULL,    -- 33バイト圧縮公開鍵
        slot_start INTEGER NOT NULL, -- スロット開始時刻 (sec)
        slot_end INTEGER NOT NULL,   -- スロット終了時刻 (sec)
        UNIQUE(friend_id, pubkey_ecd),
        FOREIGN KEY(friend_id) REFERENCES friends(id) ON DELETE CASCADE
      )
    ''');
  }

  static Future<void> _createIndexes(Database db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_generated_pubkey ON generated_keys(pubkey_ecd)',
    );

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_generated_generate_expire ON generated_keys(generate_time, expire_time)',
    );

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_generated_expire_time ON generated_keys(expire_time)',
    );
  }

  // ----- Debug / Seed -----

  /// assets の dummy_keys.txt から，先頭 count 件の公開鍵を収集鍵として投入する。
  static Future<int> insertCommonDummyKeys({
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

      // 圧縮公開鍵(33B)は 66 hex 文字
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

  // ----- Collected keys -----

  static Future<bool> existsCollectedKey(Uint8List key33) async {
    final db = await getDatabase();
    final count = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT COUNT(*) FROM collected_keys WHERE pubkey_ecd = ?',
        [key33],
      ),
    );
    return (count ?? 0) > 0;
  }

  /// 収集鍵が未登録の場合のみ INSERT する。
  static Future<bool> insertCollectedKeyIfAbsent({
    required Uint8List pubkey33,
    required int tms,
  }) async {
    final db = await getDatabase();

    final exists = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT COUNT(*) FROM collected_keys WHERE pubkey_ecd = ?',
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

  static Future<void> insertCollectedKeysBatch({
    required List<Uint8List> publicKeys,
  }) async {
    final db = await getDatabase();
    final batch = db.batch();
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final pubkey in publicKeys) {
      batch.insert(
        'collected_keys',
        {
          'pubkey_ecd': pubkey,
          'receive_time': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }

    await batch.commit(noResult: true);
  }

  // ----- Stats -----

  Future<int> getTotalKeyCount() async {
    final db = await getDatabase();

    final generated = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM generated_keys'),
    ) ??
        0;

    final collected = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM collected_keys'),
    ) ??
        0;

    return generated + collected;
  }

  // ----- Delete -----

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
