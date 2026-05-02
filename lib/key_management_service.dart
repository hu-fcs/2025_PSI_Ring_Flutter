import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'db/database_helper.dart';
import 'native_key_service.dart';

/// 1スロット分のニックネーム（圧縮公開鍵）情報
class SlotNickname {
  /// このニックネームが有効になるスロットの開始時刻
  final DateTime slotStart;

  /// 1スロットの長さ（例: 10分）
  final Duration slotDuration;

  /// 33バイトの圧縮公開鍵（BLEニックネーム本体）
  final Uint8List pubkey33;

  const SlotNickname({
    required this.slotStart,
    required this.slotDuration,
    required this.pubkey33,
  });
}

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
      print("🔑 マスターキーを新規生成 (via FFI): ${mk.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}");
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

  /// 将来分のニックネーム（圧縮公開鍵）リストを生成する
  ///
  /// [period] : どこまで先を生成するか（例: 1日 or 7日）
  /// [slot]   : 1スロットの長さ（デフォルトは10分）
  Future<List<SlotNickname>> generateFutureNicknameList({
    required Duration period,
    Duration slot = const Duration(minutes: 10),
  }) async {
    // 1. マスターキーを確保（なければ生成）
    final masterKey = await _ensureMasterKey();
    if (masterKey == null) {
      throw StateError('Master key not available');
    }

    // 2. 現在時刻とスロット長（ミリ秒）を計算
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final slotMs = slot.inMilliseconds;
    if (slotMs <= 0) {
      throw ArgumentError('slot duration must be > 0');
    }

    // 3. 「いま属しているスロットの開始時刻」に丸める
    final currentSlotStartMs = (nowMs ~/ slotMs) * slotMs;

    // 4. 何スロット分生成するかを計算（切り上げ）
    final totalMs = period.inMilliseconds;
    final slotCount = (totalMs / slotMs).ceil();
    if (slotCount <= 0) {
      return const [];
    }

    final List<SlotNickname> result = [];

    // 5. 各スロットごとに公開鍵を生成
    for (var i = 0; i < slotCount; i++) {
      final slotStartMs = currentSlotStartMs + i * slotMs;

      // 既存のネイティブ関数で「マスターキー＋スロット時刻」から鍵ペアを導出
      final keyPair = _nativeKeyService.deriveNewKeyPair(
        masterKey,
        slotStartMs,
        slotMs,
      );

      // 何らかの理由で生成に失敗したらスキップ
      if (keyPair == null) {
        continue;
      }

      result.add(
        SlotNickname(
          slotStart: DateTime.fromMillisecondsSinceEpoch(slotStartMs),
          slotDuration: slot,
          pubkey33: Uint8List.fromList(keyPair.publicKey),
        ),
      );
    }

    return result;
  }

  /// DBから最新の生成済み鍵ペアを取得する
  Future<KeyPair?> getLatestKeyPair() async {
    final db = await DatabaseHelper.getDatabase();
    // 有効期限が最新の鍵を取得する
    final results = await db.query(
      'generated_keys',
      orderBy: 'expire_time DESC',
      limit: 1,
    );

    if (results.isNotEmpty) {
      final row = results.first;
      final seckey = row['seckey_ecd'] as Uint8List?;
      final pubkey = row['pubkey_ecd'] as Uint8List?;
      if (seckey != null && pubkey != null) {
        return KeyPair(seckey, pubkey);
      }
    }
    // 鍵がない場合は、アドバタイズ用の鍵を生成してそれを返す
    print("最新の鍵ペアがDBにないため、新規生成を試みます。");
    final pubkey = await getPublicKeyForAdvertise();
    if (pubkey != null) {
      // 再度DBから取得
      return getLatestKeyPair();
    }
    return null;
  }

  /// DBから生成済みのすべての公開鍵を取得する
  Future<List<Uint8List>> getAllGeneratedPublicKeys() async {
    final db = await DatabaseHelper.getDatabase();
    final results = await db.query('generated_keys', columns: ['pubkey_ecd']);
    return results.map((row) => row['pubkey_ecd'] as Uint8List).toList();
  }

  /// DBから収集済みのすべての公開鍵を取得する
  Future<List<Uint8List>> getAllCollectedPublicKeys() async {
    final db = await DatabaseHelper.getDatabase();
    final results = await db.query('ecd_keys', columns: ['key_ecd']);
    return results.map((row) => row['key_ecd'] as Uint8List).toList();
  }

  // --- ★ここまで新しいメソッド★ ---

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

  Future<String?> getMasterKeyHexString() async {
    // Base64文字列で保存されているマスターキーを取得
    final base64Value = await _secureStorage.read(key: _masterKeyAlias);
    if (base64Value == null) return null;

    // Base64 → バイト列
    final bytes = base64.decode(base64Value);

    // バイト列 → HEX文字列（1バイト=2文字）
    final hexString = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return hexString;
  }

  Future<void> deleteMasterKey() {
    print("🔑 マスターキーを削除します。");
    return _secureStorage.delete(key: _masterKeyAlias);
  }
}
