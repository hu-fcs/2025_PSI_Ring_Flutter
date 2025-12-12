// lib/key_management_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'db/database_helper.dart';
import 'ffi/native_key_service.dart';

class KeyManagementService {
  // ================================================================
  //  ★★★★★ Singleton 化（これが最重要）★★★★★
  // ================================================================
  static final KeyManagementService _instance = KeyManagementService._internal();
  factory KeyManagementService() => _instance;
  KeyManagementService._internal();

  // ================================================================

  static const _masterKeyAlias = 'app_master_key';
  final _secureStorage = const FlutterSecureStorage();
  final _nativeKeyService = NativeKeyService();

  /// 🔥 スロット幅（ms）。DebugPage などから変更可能。
  /// 例：10分 → 10*60*1000、1分 → 60000、1秒 → 1000
  int slotMs = 10 * 60 * 1000;

  /// 🔔 BLE / UI / PSI サーバへ通知するためのストリーム
  final StreamController<void> _keyUpdatedController =
  StreamController<void>.broadcast();

  Stream<void> get onKeyUpdated => _keyUpdatedController.stream;

  void notifyKeyUpdated() {
    print("🔔 KeyManagementService: notifyKeyUpdated()");
    _keyUpdatedController.add(null);
  }

  // ================================================================
  // 初期化（マスターキー生成）
  // ================================================================
  Future<void> init() async {
    await _ensureMasterKey();
  }

  Future<Uint8List?> _ensureMasterKey() async {
    final stored = await _secureStorage.read(key: _masterKeyAlias);
    if (stored != null) {
      print("🔑 既存のマスターキーを読み込みました。");
      return base64Decode(stored);
    }

    print("⚙️ 新しいマスターキーを生成（FFI）...");
    final mk = _nativeKeyService.generateMasterKey();
    if (mk != null) {
      await _secureStorage.write(
        key: _masterKeyAlias,
        value: base64Encode(mk),
      );
      print("🔑 マスターキー新規生成: "
          "${mk.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}");
      return mk;
    }

    print("🚨 マスターキーの生成に失敗しました。");
    return null;
  }

  // ================================================================
  // Advertise（公開鍵生成）
  // ================================================================
  Future<Uint8List?> getPublicKeyForAdvertise() async {
    final masterKey = await _ensureMasterKey();
    if (masterKey == null) {
      print("🚨 マスターキーが無いためキー生成不可");
      return null;
    }

    final now = DateTime.now().millisecondsSinceEpoch;

    // ★ slotMs を一元的に使用
    final slotStartTime = (now ~/ slotMs) * slotMs;
    final expireTime = slotStartTime + slotMs;

    final db = await DatabaseHelper.getDatabase();

    // ★ すでにそのスロットの鍵があるか？
    final existing = await db.query(
      'generated_keys',
      where: 'generate_time = ? AND expire_time > ?',
      whereArgs: [slotStartTime, now],
      limit: 1,
    );

    if (existing.isNotEmpty) {
      return existing.first['pubkey_ecd'] as Uint8List;
    }

    // ★ 新規鍵生成も slotMs を利用
    final keyPair =
    _nativeKeyService.deriveNewKeyPair(masterKey, now, slotMs);
    if (keyPair == null) {
      print("🚨 生成失敗");
      return null;
    }

    await db.insert('generated_keys', {
      'seckey_ecd': keyPair.privateKey,
      'pubkey_ecd': keyPair.publicKey,
      'generate_time': slotStartTime,
      'expire_time': expireTime,
    });

    return keyPair.publicKey;
  }

  // ================================================================
  // 鍵取得系
  // ================================================================
  Future<KeyPair?> getLatestKeyPair() async {
    final db = await DatabaseHelper.getDatabase();
    final rows = await db.query(
      'generated_keys',
      orderBy: 'expire_time DESC',
      limit: 1,
    );

    if (rows.isNotEmpty) {
      final sec = rows.first['seckey_ecd'] as Uint8List?;
      final pub = rows.first['pubkey_ecd'] as Uint8List?;
      if (sec != null && pub != null) return KeyPair(sec, pub);
    }

    // 無ければ生成
    final pub = await getPublicKeyForAdvertise();
    if (pub != null) return getLatestKeyPair();
    return null;
  }

  Future<List<Uint8List>> getAllGeneratedPublicKeys() async {
    final db = await DatabaseHelper.getDatabase();
    final rows = await db.query('generated_keys', columns: ['pubkey_ecd']);
    return rows.map((row) => row['pubkey_ecd'] as Uint8List).toList();
  }

  Future<List<Uint8List>> getAllCollectedPublicKeys() async {
    final db = await DatabaseHelper.getDatabase();
    final rows = await db.query('collected_keys', columns: ['pubkey_ecd']);
    return rows.map((row) => row['pubkey_ecd'] as Uint8List).toList();
  }

  // ================================================================
  // 時刻取得
  // ================================================================
  Future<int?> getTimestampForKey(Uint8List pub) async {
    final db = await DatabaseHelper.getDatabase();

    // 自分の鍵
    final g = await db.query(
      'generated_keys',
      columns: ['generate_time'],
      where: 'pubkey_ecd = ?',
      whereArgs: [pub],
      limit: 1,
    );
    if (g.isNotEmpty) return g.first['generate_time'] as int;

    // 収集鍵
    final c = await db.query(
      'collected_keys',
      columns: ['receive_time'],
      where: 'pubkey_ecd = ?',
      whereArgs: [pub],
      limit: 1,
    );
    if (c.isNotEmpty) return c.first['receive_time'] as int;

    return null;
  }

  // ================================================================
  // ★ 同スロットフィルタリング（slotMs を一元使用）
  // ================================================================
  Future<List<Uint8List>> filterKeysBySameSlot(
      List<Uint8List> intersection, int signerGenerateTimeMs) async {

    final targetSlot = signerGenerateTimeMs ~/ slotMs;
    final result = <Uint8List>[];

    for (final pub in intersection) {
      final ts = await getTimestampForKey(pub);
      if (ts == null) continue;

      final slot = ts ~/ slotMs;
      if (slot == targetSlot) {
        result.add(pub);
      }
    }

    return result;
  }

  // ================================================================
  // DebugPage 用
  // ================================================================
  KeyPair? generateDummyKeyPair() {
    final rnd = Random.secure();
    final dummyMasterkey =
    Uint8List.fromList(List<int>.generate(32, (_) => rnd.nextInt(256)));
    final ts = DateTime.now().millisecondsSinceEpoch;

    // ★ ダミー鍵も現在の slotMs に合わせる
    return _nativeKeyService.deriveNewKeyPair(dummyMasterkey, ts, slotMs);
  }

  Future<String?> getMasterKeyBase64() {
    return _secureStorage.read(key: _masterKeyAlias);
  }

  Future<String?> getMasterKeyHexString() async {
    final base64Value = await _secureStorage.read(key: _masterKeyAlias);
    if (base64Value == null) return null;

    final bytes = base64.decode(base64Value);
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> deleteMasterKey() async {
    print("🗑 マスターキー削除");
    return _secureStorage.delete(key: _masterKeyAlias);
  }
}
