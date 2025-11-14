import 'dart:io';
// import 'package:flutter/services.dart' show rootBundle; // 削除 (rootBundleを使わないため)
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

// このクラスはローカルDB（SQLite）へのアクセスを提供するヘルパークラス
class DatabaseHelper {
  // DBファイルの保存パスを取得
  static Future<String> _getDbPath() async {
    final dbPath = await getDatabasesPath(); // 端末上のSQLite保存場所
    return join(dbPath, 'my_ecd.db'); // ファイル名と結合してフルパスを返す
  }

  // データベースを開いてインスタンスを返す
  static Future<Database> getDatabase() async {
    final path = await _getDbPath();
    // openDatabase は、ファイルが存在しない場合、
    // 自動的に作成してから開くため、これだけでOK
    return openDatabase(path);
  }

  // 初期化処理：テーブル作成などを行う
  static Future<void> initDatabase() async {
    final path = await _getDbPath();

    // データベースを開く (この時点でファイルがなければ新規作成される)
    final db = await openDatabase(path);

    // 存在しない場合のみテーブルを作成する (IF NOT EXISTS)

    // 生成された鍵（自前で生成したECD鍵）を格納するテーブル
    await db.execute('''
      CREATE TABLE IF NOT EXISTS generated_keys (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        seckey_ecd BLOB,
        pubkey_ecd BLOB,
        generate_time INTEGER,
        expire_time INTEGER
      )
    ''');

    // 収集された鍵のテーブル (UNIQUE 制約付き)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ecd_keys (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        key_ecd BLOB NOT NULL UNIQUE,
        lat INTEGER NOT NULL,
        lon INTEGER NOT NULL,
        ts INTEGER NOT NULL
      )
    ''');
  }

  Future<int> getTotalKeyCount() async {
    final db = await getDatabase();
    final generated = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM generated_keys'),
    ) ?? 0;

    final collected = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM ecd_keys'),
    ) ?? 0;

    return generated + collected;
  }

}