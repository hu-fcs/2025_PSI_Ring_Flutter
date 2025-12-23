// lib/key_management_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sqflite/sqflite.dart';

import 'db/database_helper.dart';
import 'ffi/native_key_service.dart';

class KeyManagementService {
  // ================================================================
  //  ★★★★★ Singleton 化（これが最重要）★★★★★
  // ================================================================
  static final KeyManagementService _instance = KeyManagementService._internal();
  factory KeyManagementService() => _instance;
  KeyManagementService._internal();
  RingSignatureRange ringRange = RingSignatureRange.slot;

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
  // BLE向けユーティリティ（依存を外に漏らさないためKMS内に保持）
  // ================================================================
  bool _isValidCompressedPubkey33(Uint8List key33) {
    if (key33.length != 33) return false;
    final p = key33[0];
    return (p == 0x02 || p == 0x03);
  }

  // ================================================================
  // 位置情報（非同期で後付け） ※ generated_keys のみ
  // ================================================================
  void _attachLocationAsync({required Uint8List pubkey33}) {
    // 非同期で実行（鍵生成・UIは一切ブロックしない）
    () async {
      try {
        // ============================
        // ① Location Service 確認
        // ============================
        final serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) {
          if (kDebugMode) {
            print('📍 Location service is disabled');
          }
          return;
        }

        // ============================
        // ② Permission 確認・要求
        // ============================
        LocationPermission permission = await Geolocator.checkPermission();

        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }

        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          if (kDebugMode) {
            print('📍 Location permission denied: $permission');
          }
          return;
        }

        // ============================
        // ③ GPS を「必ず起動」して取得
        // ============================
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 0,
          ),
        );

        final latE6 = (pos.latitude * 1e6).round();
        final lonE6 = (pos.longitude * 1e6).round();

        // ============================
        // ④ DB 更新（generated_keys のみ）
        // ============================
        final db = await DatabaseHelper.getDatabase();
        await db.update(
          'generated_keys',
          {
            'lat': latE6,
            'lon': lonE6,
          },
          where: 'pubkey_ecd = ?',
          whereArgs: [pubkey33],
        );

        if (kDebugMode) {
          print('📍 generated_keys: location updated ($latE6, $lonE6)');
        }

        notifyKeyUpdated();
      } catch (e, st) {
        if (kDebugMode) {
          print('📍 location attach failed: $e');
          print(st);
        }
      }
    }();
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
  // Advertise（公開鍵生成）: 既存
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
    // 位置情報も読み、未設定なら非同期で付与を試みる
    final existing = await db.query(
      'generated_keys',
      columns: const ['pubkey_ecd', 'lat', 'lon'],
      where: 'generate_time = ? AND expire_time > ?',
      whereArgs: [slotStartTime, now],
      limit: 1,
    );

    if (existing.isNotEmpty) {
      final pub = existing.first['pubkey_ecd'] as Uint8List;
      final lat = existing.first['lat'] as int?;
      final lon = existing.first['lon'] as int?;

      // 未設定なら後付けを試みる（ブロックしない）
      if (lat == null || lon == null) {
        _attachLocationAsync(pubkey33: pub);
      }

      return pub;
    }

    // ★ 新規鍵生成も slotMs を利用（ここは瞬時）
    final keyPair = _nativeKeyService.deriveNewKeyPair(masterKey, now, slotMs);
    if (keyPair == null) {
      print("🚨 生成失敗");
      return null;
    }

    // 位置情報は “後付け” なので、まずは NULL でINSERTして即返す
    await db.insert('generated_keys', {
      'seckey_ecd': keyPair.privateKey,
      'pubkey_ecd': keyPair.publicKey,
      'lat': null,
      'lon': null,
      'generate_time': slotStartTime,
      'expire_time': expireTime,
    });

    // 🔥 GPS取得→取得できたらUPDATE（ブロックしない）
    _attachLocationAsync(pubkey33: keyPair.publicKey);

    return keyPair.publicKey;
  }

  // ================================================================
  // ★ BLE Advertise用（旧 KeyAdvertiseRepository を吸収）
  // ================================================================
  Future<Uint8List> getPublicKeyForBleAdvertise() async {
    final Uint8List? pubKey33 = await getPublicKeyForAdvertise();
    if (pubKey33 == null) {
      throw StateError('Failed to obtain public key from KeyManagementService.');
    }
    if (!_isValidCompressedPubkey33(pubKey33)) {
      throw StateError(
        'Invalid compressed public key (expected 33 bytes starting with 0x02/0x03).',
      );
    }
    return pubKey33;
  }

  // ================================================================
  // ★ collected_keys: 存在チェック（BleScanner 用）
  // ================================================================
  Future<bool> hasCollectedKey(Uint8List pubkey33) async {
    if (!_isValidCompressedPubkey33(pubkey33)) return false;

    final db = await DatabaseHelper.getDatabase();
    final rows = await db.query(
      'collected_keys',
      columns: const ['id'],
      where: 'pubkey_ecd = ?',
      whereArgs: [pubkey33],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  // ================================================================
  // ★ collected_keys: なければ insert（BleScanner 用）
  // - collected_keys には lat/lon を入れない（スキーマ準拠）
  // - inserted=true のときだけ notifyKeyUpdated() する
  // ================================================================
  Future<bool> insertCollectedKeyIfAbsent({
    required Uint8List pubkey33,
    required int receivedAtMs,
  }) async {
    if (!_isValidCompressedPubkey33(pubkey33)) {
      throw StateError('Invalid compressed public key for insert.');
    }

    final Database db = await DatabaseHelper.getDatabase();

    final values = <String, Object?>{
      'pubkey_ecd': pubkey33,
      'receive_time': receivedAtMs, // ★ ms で統一
    };

    try {
      final rowId = await db.insert(
        'collected_keys',
        values,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

      final inserted = rowId > 0;
      if (inserted) {
        notifyKeyUpdated();
      }
      return inserted;
    } catch (e, st) {
      if (kDebugMode) {
        print('KMS: ❌ insertCollectedKeyIfAbsent failed: $e');
        print(st);
      }
      return false;
    }
  }

  // ================================================================
  // ★ BLEで収集した鍵の保存（旧 EcdKeysDao を吸収）
  // - 互換のため残す（内部は insertCollectedKeyIfAbsent に統一）
  // ================================================================
  Future<void> insertCollectedBlePublicKey({
    required Uint8List pubkey33,
    required int receivedAtMs,
  }) async {
    await insertCollectedKeyIfAbsent(
      pubkey33: pubkey33,
      receivedAtMs: receivedAtMs,
    );
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
  // ★ 署名者鍵選択（intersection 内・expire_time 最大）
  // ================================================================
  Future<KeyPair?> selectSignerKeyFromIntersection(
      List<Uint8List> intersection) async {
    if (intersection.isEmpty) return null;

    final db = await DatabaseHelper.getDatabase();

    int? bestExpire;
    Uint8List? bestSec;
    Uint8List? bestPub;

    for (final pub in intersection) {
      final rows = await db.query(
        'generated_keys',
        columns: ['seckey_ecd', 'pubkey_ecd', 'expire_time'],
        where: 'pubkey_ecd = ?',
        whereArgs: [pub],
        limit: 1,
      );

      if (rows.isEmpty) continue;

      final row = rows.first;
      final sec = row['seckey_ecd'] as Uint8List?;
      final p = row['pubkey_ecd'] as Uint8List?;
      final expire = row['expire_time'] as int?;

      if (sec != null && p != null && expire != null) {
        if (bestExpire == null || expire > bestExpire) {
          bestExpire = expire;
          bestSec = sec;
          bestPub = p;
        }
      }
    }

    if (bestSec == null || bestPub == null) return null;
    return KeyPair(bestSec, bestPub);
  }

  // ================================================================
  // ★ 同時間帯でフィルタリング
  // ================================================================
  Future<List<Uint8List>> filterKeysBySameSlot(
      List<Uint8List> intersection,
      int signerGenerateTimeMs,
      ) async {
    final result = <Uint8List>[];

    final range = ringRange;

    // 基準値を先に計算
    final targetSlot = signerGenerateTimeMs ~/ slotMs;

    // 1日の開始（ローカル時間）
    final signerDate = DateTime.fromMillisecondsSinceEpoch(signerGenerateTimeMs);
    final dayStart = DateTime(
      signerDate.year,
      signerDate.month,
      signerDate.day,
    ).millisecondsSinceEpoch;
    final dayEnd = dayStart + const Duration(days: 1).inMilliseconds;

    for (final pub in intersection) {
      final ts = await getTimestampForKey(pub);
      if (ts == null) continue;

      switch (range) {
        case RingSignatureRange.slot:
          final slot = ts ~/ slotMs;
          if (slot == targetSlot) {
            result.add(pub);
          }
          break;

        case RingSignatureRange.day:
          if (ts >= dayStart && ts < dayEnd) {
            result.add(pub);
          }
          break;

        case RingSignatureRange.all:
          result.add(pub);
          break;
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

/// リング署名対象期間
enum RingSignatureRange {
  slot, // 現在スロット
  day, // 直近24時間
  all, // 全期間
}
