// lib/ble/ecd_keys_dao.dart
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import '../db/database_helper.dart';

/// 既存テーブル ecd_keys に「収集した鍵」を追加するための最小DAO。
/// 期待スキーマ例:
///   ecd_keys(id INTEGER PK AUTOINCREMENT, key_ecd BLOB, ts INTEGER, lat INTEGER, lon INTEGER, ...)
class EcdKeysDao {
  EcdKeysDao._();
  static final instance = EcdKeysDao._();

  /// 33B圧縮公開鍵を ecd_keys に保存する。
  /// - ts: 受信時刻 (Unix ms)。テーブルが秒精度なら切り捨てに調整してください。
  /// - lat/lon: 既存スキーマが NOT NULL の可能性に備えて 0 を投入（不要なら引数や実装から取り除いてOK）
  Future<void> insertCollected({
    required Uint8List pubkey33,
    required int ts,
    int latE6 = 0,
    int lonE6 = 0,
  }) async {
    final Database db = await DatabaseHelper.getDatabase();

    await db.insert(
      'ecd_keys',
      {
        'key_ecd': pubkey33,
        'ts': ts,
        'lat': latE6,
        'lon': lonE6,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }
}
