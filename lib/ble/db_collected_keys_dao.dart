// lib/ble/db_collected_keys_dao.dart
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import '../db/database_helper.dart'; // ← あなたの構成に合わせて修正済み

/// 収集した公開鍵を格納する DAO
///
/// - テーブル名: collected_keys
/// - カラム:
///   - id: 自動採番
///   - device_id: 広告主識別子 (BLE の device.id)
///   - received_at_ms: 受信時刻 (UNIX ms)
///   - pubkey33: 圧縮公開鍵 (33B)
class CollectedKeysDao {
  CollectedKeysDao._();
  static final instance = CollectedKeysDao._();

  /// スキーマ確認・作成
  Future<void> ensureSchema() async {
    final Database db = await DatabaseHelper.getDatabase();
    await db.execute('''
      CREATE TABLE IF NOT EXISTS collected_keys(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device_id TEXT,
        received_at_ms INTEGER,
        pubkey33 BLOB
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_collected_device_time ON collected_keys(device_id, received_at_ms)'
    );
  }

  /// 公開鍵を保存する
  Future<void> insertKey({
    required String deviceId,
    required int receivedAtMs,
    required Uint8List pubkey33,
  }) async {
    await ensureSchema();
    final Database db = await DatabaseHelper.getDatabase();
    await db.insert(
      'collected_keys',
      {
        'device_id': deviceId,
        'received_at_ms': receivedAtMs,
        'pubkey33': pubkey33,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// 最近の公開鍵を取得（デバッグ・表示用）
  Future<List<Map<String, dynamic>>> listRecent({int limit = 100}) async {
    final Database db = await DatabaseHelper.getDatabase();
    return db.query(
      'collected_keys',
      orderBy: 'received_at_ms DESC',
      limit: limit,
    );
  }

  /// すべて削除（デバッグ用途）
  Future<void> clearAll() async {
    final Database db = await DatabaseHelper.getDatabase();
    await db.delete('collected_keys');
  }
}
