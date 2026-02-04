// lib/key_management.dart

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

/// マスターキー管理と，時刻スロットに基づく鍵生成・保存を提供する。
///
/// - マスターキーは Secure Storage に保存する。
/// - 各時刻スロットごとに一時鍵対を導出し，公開鍵を仮名として用いる。
/// - 生成鍵（generated_keys）と収集鍵（collected_keys）を SQLite に保存する。
class KeyManagementService {
  // Singleton
  static final KeyManagementService _instance = KeyManagementService._internal();
  factory KeyManagementService() => _instance;
  KeyManagementService._internal();

  /// リング署名の対象期間（同一スロット/同日/全期間）
  RingSignatureRange ringRange = RingSignatureRange.slot;

  static const _masterKeyAlias = 'app_master_key';
  final _secureStorage = const FlutterSecureStorage();
  final _nativeKeyService = NativeKeyService();

  /// 時刻スロット幅（ミリ秒）
  ///
  /// 既定は 10 分。DebugPage 等から変更できる。
  int slotMs = 10 * 60 * 1000;

  /// 鍵の追加・更新を通知するストリーム（BLE / UI / gRPC で利用）
  final StreamController<void> _keyUpdatedController =
  StreamController<void>.broadcast();

  Stream<void> get onKeyUpdated => _keyUpdatedController.stream;

  void notifyKeyUpdated() {
    if (kDebugMode) {
      debugPrint('KMS: notifyKeyUpdated()');
    }
    _keyUpdatedController.add(null);
  }

  // ----- BLE 向けユーティリティ -----

  bool _isValidCompressedPubkey33(Uint8List key33) {
    if (key33.length != 33) return false;
    final p = key33[0];
    return (p == 0x02 || p == 0x03);
  }

  // ----- 位置情報の後付け（generated_keys のみ） -----

  void _attachLocationAsync({required Uint8List pubkey33}) {
    // 位置情報の取得は非同期で行い，鍵生成や UI をブロックしない
    () async {
      try {
        final serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) return;

        LocationPermission permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          return;
        }

        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 0,
          ),
        );

        final latE6 = (pos.latitude * 1e6).round();
        final lonE6 = (pos.longitude * 1e6).round();

        final db = await DatabaseHelper.getDatabase();
        await db.update(
          'generated_keys',
          {'lat': latE6, 'lon': lonE6},
          where: 'pubkey_ecd = ?',
          whereArgs: [pubkey33],
        );

        notifyKeyUpdated();
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint('KMS: attach location failed: $e');
          debugPrint('$st');
        }
      }
    }();
  }

  // ----- 初期化（マスターキー） -----

  Future<void> init() async {
    await _ensureMasterKey();
  }

  Future<Uint8List?> _ensureMasterKey() async {
    final stored = await _secureStorage.read(key: _masterKeyAlias);
    if (stored != null) {
      if (kDebugMode) {
        debugPrint('KMS: master key loaded');
      }
      return base64Decode(stored);
    }

    final mk = _nativeKeyService.generateMasterKey();
    if (mk == null) {
      if (kDebugMode) {
        debugPrint('KMS: failed to generate master key');
      }
      return null;
    }

    await _secureStorage.write(
      key: _masterKeyAlias,
      value: base64Encode(mk),
    );

    if (kDebugMode) {
      debugPrint('KMS: master key generated');
    }
    return mk;
  }

  // ----- Advertise（仮名公開鍵の取得） -----

  Future<Uint8List?> getPublicKeyForAdvertise() async {
    final masterKey = await _ensureMasterKey();
    if (masterKey == null) return null;

    final now = DateTime.now().millisecondsSinceEpoch;

    // 時刻スロットの開始時刻と失効時刻
    final slotStartTime = (now ~/ slotMs) * slotMs;
    final expireTime = slotStartTime + slotMs;

    final db = await DatabaseHelper.getDatabase();

    // 同一スロットの鍵が存在すれば再利用する
    // 位置情報が未設定の場合のみ，後付けを試みる
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
      if (lat == null || lon == null) {
        _attachLocationAsync(pubkey33: pub);
      }
      return pub;
    }

    // スロットに対応する鍵対を導出する
    final keyPair = _nativeKeyService.deriveNewKeyPair(masterKey, now, slotMs);
    if (keyPair == null) return null;

    // 位置情報は後付けのため，まず NULL で保存する
    await db.insert('generated_keys', {
      'seckey_ecd': keyPair.privateKey,
      'pubkey_ecd': keyPair.publicKey,
      'lat': null,
      'lon': null,
      'generate_time': slotStartTime,
      'expire_time': expireTime,
    });

    _attachLocationAsync(pubkey33: keyPair.publicKey);
    return keyPair.publicKey;
  }

  // ----- BLE 用（圧縮公開鍵の検証つき） -----

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

  // ----- collected_keys: 存在確認（BleScanner 用） -----

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

  // ----- collected_keys: 追加（BleScanner 用） -----

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
      'receive_time': receivedAtMs,
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
        debugPrint('KMS: insertCollectedKeyIfAbsent failed: $e');
        debugPrint('$st');
      }
      return false;
    }
  }

  /// 互換のために残す。内部は insertCollectedKeyIfAbsent を呼ぶ。
  Future<void> insertCollectedBlePublicKey({
    required Uint8List pubkey33,
    required int receivedAtMs,
  }) async {
    await insertCollectedKeyIfAbsent(
      pubkey33: pubkey33,
      receivedAtMs: receivedAtMs,
    );
  }

  // ----- 鍵取得 -----

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

  // ----- 鍵の時刻取得 -----

  Future<int?> getTimestampForKey(Uint8List pub) async {
    final db = await DatabaseHelper.getDatabase();

    final g = await db.query(
      'generated_keys',
      columns: ['generate_time'],
      where: 'pubkey_ecd = ?',
      whereArgs: [pub],
      limit: 1,
    );
    if (g.isNotEmpty) return g.first['generate_time'] as int;

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

  String _k(Uint8List b) => base64Encode(b);

  Iterable<List<Uint8List>> _chunkPubkeys(List<Uint8List> pubkeys,
      {int chunkSize = 450}) sync* {
    if (pubkeys.isEmpty) return;
    for (int i = 0; i < pubkeys.length; i += chunkSize) {
      final end = (i + chunkSize < pubkeys.length) ? i + chunkSize : pubkeys.length;
      yield pubkeys.sublist(i, end);
    }
  }

  Future<Map<String, _GeneratedRow>> _loadGeneratedRowsForPubkeys(
      Database db,
      List<Uint8List> pubkeys,
      ) async {
    final result = <String, _GeneratedRow>{};

    for (final chunk in _chunkPubkeys(pubkeys)) {
      final where = 'pubkey_ecd IN (${List.filled(chunk.length, '?').join(',')})';
      final rows = await db.query(
        'generated_keys',
        columns: ['seckey_ecd', 'pubkey_ecd', 'expire_time', 'generate_time'],
        where: where,
        whereArgs: chunk,
      );

      for (final row in rows) {
        final pub = row['pubkey_ecd'] as Uint8List?;
        if (pub == null) continue;

        final sec = row['seckey_ecd'] as Uint8List?;
        final expire = row['expire_time'] as int?;
        final gen = row['generate_time'] as int?;
        if (sec == null || expire == null || gen == null) continue;

        result[_k(pub)] = _GeneratedRow(
          sec: sec,
          pub: pub,
          expire: expire,
          generate: gen,
        );
      }
    }

    return result;
  }

  Future<Map<String, int>> _loadCollectedTimesForPubkeys(
      Database db,
      List<Uint8List> pubkeys,
      ) async {
    final result = <String, int>{};

    for (final chunk in _chunkPubkeys(pubkeys)) {
      final where = 'pubkey_ecd IN (${List.filled(chunk.length, '?').join(',')})';
      final rows = await db.query(
        'collected_keys',
        columns: ['pubkey_ecd', 'receive_time'],
        where: where,
        whereArgs: chunk,
      );

      for (final row in rows) {
        final pub = row['pubkey_ecd'] as Uint8List?;
        final ts = row['receive_time'] as int?;
        if (pub == null || ts == null) continue;
        result[_k(pub)] = ts;
      }
    }

    return result;
  }

  Future<Map<String, int>> _buildTimestampMap(
      Database db,
      List<Uint8List> intersection,
      ) async {
    final genRows = await _loadGeneratedRowsForPubkeys(db, intersection);
    final collected = await _loadCollectedTimesForPubkeys(db, intersection);

    final ts = <String, int>{};
    for (final e in genRows.entries) {
      ts[e.key] = e.value.generate;
    }
    for (final e in collected.entries) {
      ts.putIfAbsent(e.key, () => e.value);
    }
    return ts;
  }

  // ----- 署名者鍵選択（交差集合内で最も新しいもの） -----

  Future<KeyPair?> selectSignerKeyFromIntersection(
      List<Uint8List> intersection,
      ) async {
    if (intersection.isEmpty) return null;

    final db = await DatabaseHelper.getDatabase();
    final genRows = await _loadGeneratedRowsForPubkeys(db, intersection);

    int? bestExpire;
    Uint8List? bestSec;
    Uint8List? bestPub;

    for (final row in genRows.values) {
      if (bestExpire == null || row.expire > bestExpire) {
        bestExpire = row.expire;
        bestSec = row.sec;
        bestPub = row.pub;
      }
    }

    if (bestSec == null || bestPub == null) return null;
    return KeyPair(bestSec, bestPub);
  }

  // ----- リング対象のフィルタリング -----

  Future<List<Uint8List>> filterKeysBySameSlot(
      List<Uint8List> intersection,
      int signerGenerateTimeMs,
      ) async {
    final result = <Uint8List>[];

    final range = ringRange;

    final targetSlot = signerGenerateTimeMs ~/ slotMs;

    final signerDate = DateTime.fromMillisecondsSinceEpoch(signerGenerateTimeMs);
    final dayStart = DateTime(
      signerDate.year,
      signerDate.month,
      signerDate.day,
    ).millisecondsSinceEpoch;
    final dayEnd = dayStart + const Duration(days: 1).inMilliseconds;

    if (intersection.isEmpty) return result;

    final db = await DatabaseHelper.getDatabase();
    final tsMap = await _buildTimestampMap(db, intersection);

    for (final pub in intersection) {
      final ts = tsMap[_k(pub)];
      if (ts == null) continue;

      switch (range) {
        case RingSignatureRange.slot:
          final slot = ts ~/ slotMs;
          if (slot == targetSlot) result.add(pub);
          break;

        case RingSignatureRange.day:
          if (ts >= dayStart && ts < dayEnd) result.add(pub);
          break;

        case RingSignatureRange.all:
          result.add(pub);
          break;
      }
    }

    return result;
  }

  // ----- DebugPage 用 -----

  KeyPair? generateDummyKeyPair() {
    final rnd = Random.secure();
    final dummyMasterkey =
    Uint8List.fromList(List<int>.generate(32, (_) => rnd.nextInt(256)));
    final ts = DateTime.now().millisecondsSinceEpoch;
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
    if (kDebugMode) {
      debugPrint('KMS: delete master key');
    }
    return _secureStorage.delete(key: _masterKeyAlias);
  }
}

class _GeneratedRow {
  final Uint8List sec;
  final Uint8List pub;
  final int expire;
  final int generate;

  const _GeneratedRow({
    required this.sec,
    required this.pub,
    required this.expire,
    required this.generate,
  });
}

/// リング署名の対象期間
enum RingSignatureRange {
  slot, // 同一時刻スロット
  day, // 同日
  all, // 全期間
}
