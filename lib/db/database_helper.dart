import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
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
    return openDatabase(path); // 既に存在していれば開くだけ
  }

  // 初期化処理：初回起動時のDBコピーやテーブル作成などを行う
  static Future<void> initDatabase() async {
    final path = await _getDbPath();

    // DBが存在しない場合、assets/empty_ecd.db をコピー
    if (!await File(path).exists()) {
      final data = await rootBundle.load('assets/empty_ecd.db'); // アセット読み込み
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      await File(path).writeAsBytes(bytes, flush: true); // 書き込み
    }

    // データベースを開いて、テーブルがなければ作成
    final db = await openDatabase(path);

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

    // 収集された鍵（他者の公開鍵など）を格納するテーブル
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ecd_keys (
        key_ecd BLOB NOT NULL,
        lat INTEGER NOT NULL,
        lon INTEGER NOT NULL,
        ts INTEGER NOT NULL
      )
    ''');
  }

  // デバッグ用：収集鍵のダミーデータを挿入
  static Future<void> insertDummyCollected() async {
    final db = await getDatabase();
    await db.insert('ecd_keys', {
      'key_ecd': List<int>.generate(17, (i) => i), // 0〜16の疑似鍵データ
      'lat': 12345678,
      'lon': 87654321,
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000, // UNIX時間（秒）
    });
  }

  // デバッグ用：生成鍵のダミーデータを挿入
  static Future<void> insertDummyGenerated() async {
    final db = await getDatabase();
    await db.insert('generated_keys', {
      'seckey_ecd': List<int>.generate(17, (i) => 100 + i), // 擬似秘密鍵
      'pubkey_ecd': List<int>.generate(16, (i) => 200 - i), // 擬似公開鍵
      'generate_time': DateTime.now().millisecondsSinceEpoch, // 生成時刻
      'expire_time': DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch, // 30日後が期限
    });
  }
}
