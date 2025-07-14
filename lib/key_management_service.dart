import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'db/database_helper.dart';
import 'native_key_service.dart';

class KeyManagementService {
  static const _masterKeyAlias = 'app_master_key';
  final _secureStorage = const FlutterSecureStorage();
  final _nativeKeyService = NativeKeyService();

  Future<void> init() async {
    await _ensureMasterKey();
  }

  Future<Uint8List?> _ensureMasterKey() async {
    final stored = await _secureStorage.read(key: _masterKeyAlias);
    if (stored != null) {
      print("🔑 既存のマスターキーを読み込みました。");
      return base64Decode(stored);
    }
    print("⚙️ 新しいマスターキーをFFI経由で生成します...");
    final mk = _nativeKeyService.generateMasterKey();
    if (mk != null) {
      await _secureStorage.write(
        key: _masterKeyAlias,
        value: base64Encode(mk),
      );
      print("🔑 マスターキーを新規生成 (via FFI): ${base64.encode(mk)}");
      return mk;
    }
    print("🚨 マスターキーの生成に失敗しました。");
    return null;
  }

  Future<Uint8List?> getPublicKeyForAdvertise({
    Duration validity = const Duration(minutes: 10),
  }) async {
    final masterKey = await _ensureMasterKey();
    if (masterKey == null) {
      print("🚨 マスターキーがないため、公開鍵を取得できません。");
      return null;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final slotMillis = validity.inMilliseconds;
    final slotStartTime = (now ~/ slotMillis) * slotMillis;

    final db = await DatabaseHelper.getDatabase();

    print("🔍 DBから有効な鍵を検索します...");
    final existingKeys = await db.query(
      'generated_keys',
      where: 'generate_time = ? AND expire_time > ?',
      whereArgs: [slotStartTime, now],
      limit: 1,
    );

    if (existingKeys.isNotEmpty) {
      final key = existingKeys.first['pubkey_ecd'] as Uint8List;
      print("✅ 有効な鍵をDBから発見。再利用します。");
      return key;
    }

    print("⚠️ 有効な鍵なし。新しい鍵を生成します...");
    final keyPair = _nativeKeyService.deriveNewKeyPair(masterKey, now, slotMillis);

    if (keyPair == null) {
      print("🚨 FFI経由での鍵生成に失敗しました。");
      return null;
    }

    final expireTime = slotStartTime + slotMillis;

    await db.insert('generated_keys', {
      'seckey_ecd': keyPair.privateKey,
      'pubkey_ecd': keyPair.publicKey,
      'generate_time': slotStartTime,
      'expire_time': expireTime,
    });
    print("💾 新しい鍵を生成し、DBに保存しました。");

    return keyPair.publicKey;
  }

  // --- デバッグ用のメソッド ---

  /// デバッグ用の高品質なダミー鍵ペアを生成して返す
  KeyPair? generateDummyKeyPair() {
    final random = Random.secure();
    final dummyMasterKey = Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
    final randomTimestamp = DateTime.now().subtract(Duration(days: random.nextInt(30))).millisecondsSinceEpoch;
    const slotMillis = 10 * 60 * 1000;

    return _nativeKeyService.deriveNewKeyPair(dummyMasterKey, randomTimestamp, slotMillis);
  }

  Future<String?> getMasterKeyBase64() {
    return _secureStorage.read(key: _masterKeyAlias);
  }

  Future<void> deleteMasterKey() {
    print("🔑 マスターキーを削除します。");
    return _secureStorage.delete(key: _masterKeyAlias);
  }
}
