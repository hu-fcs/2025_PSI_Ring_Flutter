import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'db/database_helper.dart';
import 'native_key_service.dart'; // ★ 新しいサービスをインポート

class KeyManagementService {
  static const _masterKeyAlias = 'app_master_key';
  final _secureStorage = const FlutterSecureStorage();
  Timer? _timer;

  // ★ FFIサービスをインスタンス化
  final _nativeKeyService = NativeKeyService();

  Future<void> init() async {
    final masterKey = await _ensureMasterKey();
    if (masterKey != null) {
      _startPeriodicKeyGeneration(masterKey);
    } else {
      print("🚨 マスターキーの確保に失敗したため、鍵生成を開始できません。");
    }
  }

  // ★ マスターキー生成ロジックをFFI呼び出しに変更
  Future<Uint8List?> _ensureMasterKey() async {
    final stored = await _secureStorage.read(key: _masterKeyAlias);
    if (stored != null) {
      print("🔑 既存のマスターキーを読み込みました。");
      return base64Decode(stored);
    }

    print("⚙️ 新しいマスターキーをFFI経由で生成します...");
    // Cの関数を呼び出して新しいマスターキーを生成
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

  void _startPeriodicKeyGeneration(Uint8List masterKey) {
    print("⏰ 10分毎の定期的な鍵生成を開始します。");
    _generateAndStoreKey(masterKey); // まず初回実行
    _timer = Timer.periodic(
      const Duration(minutes: 10),
          (_) => _generateAndStoreKey(masterKey),
    );
  }

  Future<void> _generateAndStoreKey(Uint8List masterKey) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    await _generateKeyAt(masterKey, timestamp);
  }

  // ★ 鍵導出ロジックをFFI呼び出しに変更
  Future<void> _generateKeyAt(Uint8List masterKey, int timestamp) async {
    print("⚙️ 鍵ペアをFFI経由で導出します (Timestamp: $timestamp)...");

    // Cの関数を呼び出して鍵ペアを導出
    final keyPair = _nativeKeyService.deriveNewKeyPair(masterKey, timestamp);

    if (keyPair == null) {
      print("🚨 FFI経由での鍵生成に失敗しました。");
      return;
    }

    final db = await DatabaseHelper.getDatabase();
    await db.insert('generated_keys', {
      'seckey_ecd': keyPair.privateKey,
      'pubkey_ecd': keyPair.publicKey,
      'generate_time': timestamp,
      'expire_time': timestamp + Duration(days: 30).inMilliseconds,
    });

    print("🔐 鍵生成成功 (via FFI)");
    print("   公開鍵 (Base64): ${base64.encode(keyPair.publicKey)}");
  }

  Future<Uint8List?> prepareCurrentPublicKeyForAdvertise() async {
    final masterKey = await _ensureMasterKey();
    if (masterKey == null) return null;

    final now = DateTime.now().millisecondsSinceEpoch;
    final keyPair = _nativeKeyService.deriveNewKeyPair(masterKey, now);

    if (keyPair != null) {
      print("📦 アドバタイズ用の公開鍵をFFI経由で生成: ${base64.encode(keyPair.publicKey)}");
      return keyPair.publicKey;
    }

    print("🚨 アドバタイズ用の鍵生成に失敗しました。");
    return null;
  }
}