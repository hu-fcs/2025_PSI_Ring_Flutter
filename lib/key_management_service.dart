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

  /// 🔔 BLE / UI / PSI サーバへ通知するためのストリーム
  final StreamController<void> _keyUpdatedController =
  StreamController<void>.broadcast();

  /// 鍵更新イベント
  Stream<void> get onKeyUpdated => _keyUpdatedController.stream;

  /// BLEスキャナが新規鍵をDBに保存したら必ず呼ぶ
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
      print("🔑 マスターキー新規生成: ${mk.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}");
      return mk;
    }

    print("🚨 マスターキーの生成に失敗しました。");
    return null;
  }

  // ================================================================
  // Advertise（公開鍵生成）
  // ================================================================
  Future<Uint8List?> getPublicKeyForAdvertise({
    Duration validity = const Duration(minutes: 10),
  }) async {
    final masterKey = await _ensureMasterKey();
    if (masterKey == null) {
      print("🚨 マスターキーが無いためキー生成不可");
      return null;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final slotMillis = validity.inMilliseconds;
    final slotStartTime = (now ~/ slotMillis) * slotMillis;

    final db = await DatabaseHelper.getDatabase();

    // DBに有効な鍵があるか確認
    final existingKeys = await db.query(
      'generated_keys',
      where: 'generate_time = ? AND expire_time > ?',
      whereArgs: [slotStartTime, now],
      limit: 1,
    );

    if (existingKeys.isNotEmpty) {
      return existingKeys.first['pubkey_ecd'] as Uint8List;
    }

    // 新規鍵生成
    final keyPair = _nativeKeyService.deriveNewKeyPair(masterKey, now, slotMillis);
    if (keyPair == null) {
      print("🚨 生成失敗");
      return null;
    }

    final expireTime = slotStartTime + slotMillis;
    await db.insert('generated_keys', {
      'seckey_ecd': keyPair.privateKey,
      'pubkey_ecd': keyPair.publicKey,
      'generate_time': slotStartTime,
      'expire_time': expireTime,
    });

    return keyPair.publicKey;
  }

  // ================================================================
  // 鍵取得系 (PSI / DebugPage 用)
  // ================================================================
  Future<KeyPair?> getLatestKeyPair() async {
    final db = await DatabaseHelper.getDatabase();
    final rows = await db.query('generated_keys', orderBy: 'expire_time DESC', limit: 1);

    if (rows.isNotEmpty) {
      final sec = rows.first['seckey_ecd'] as Uint8List?;
      final pub = rows.first['pubkey_ecd'] as Uint8List?;
      if (sec != null && pub != null) return KeyPair(sec, pub);
    }

    // 無ければ新規生成
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
    final rows = await db.query('ecd_keys', columns: ['key_ecd']);
    return rows.map((row) => row['key_ecd'] as Uint8List).toList();
  }

  // ================================================================
  // DebugPage 用
  // ================================================================
  KeyPair? generateDummyKeyPair() {
    final rnd = Random.secure();
    final dummyMasterkey =
    Uint8List.fromList(List<int>.generate(32, (_) => rnd.nextInt(256)));
    final ts = DateTime.now().millisecondsSinceEpoch;
    const slot = 10 * 60 * 1000;

    return _nativeKeyService.deriveNewKeyPair(dummyMasterkey, ts, slot);
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
