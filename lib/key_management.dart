import 'dart:async' show StreamController, Timer;
import 'dart:math';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:convert/convert.dart' show hex; // hex.decode(Uint8List)のため
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sqflite/sqflite.dart';
import 'ffi/native_key_service.dart';
import 'db/database_helper.dart';

const int pubKeyCompressedLen = 33;
const int privateKeyLen = 32;

/// Flutter 側で扱う鍵ペア。
/// 実アプリやこのアプリでは圧縮形式の公開鍵を使うが，package:cryptography は圧縮形式の公開鍵に対応していないので注意．
/// 圧縮形式については，openssl ec コマンドの -conv_form compressed オプションの説明を参照．
/* native_key_service.dartに移動
class NicknameKeyPair {
  final Uint8List privateKey; // 32バイト
  final Uint8List publicKey;  // 33バイト（圧縮）
  NicknameKeyPair(this.privateKey, this.publicKey);
}
 */

/// ダミーのKeyManagementService
class KeyManagementService {
  // Singleton
  static final KeyManagementService _instance = KeyManagementService._internal();
  factory KeyManagementService() => _instance;
  KeyManagementService._internal();

  static const int nicknameBytes = 33; // 圧縮形式の公開鍵の長さ

  NicknameKeyPair _currentLocalKeyPair = NicknameKeyPair(Uint8List(32), Uint8List(33));
  NicknameKeyPair get currentLocalKeyPair => _currentLocalKeyPair;
  int _slotNumber = 0;
  DateTime _currentKeyExpirationTime = DateTime.now();
  DateTime get currentKeyExpirationTime => _currentKeyExpirationTime;
  Timer? _currentKeyExpirationTimer;

  bool _running = false;
  bool get isRunning => _running;

  static const _masterKeyAlias = 'app_master_key';
  final _secureStorage = const FlutterSecureStorage(
    // iOSで画面オフの状態でアクセスできるようにするためのfirst_unlock
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock));
  final _nativeKeyService = NativeKeyService();

  /// 時刻スロット幅
  /// 既定は 10 分。DebugPage 等から変更できる。
  Duration _slot = Duration(minutes: 10); // minutes: 1); or seconds: 20);
  Duration get slot => _slot;
  set slot(Duration newSlot) { _slot = newSlot; } // デバッグ用

  /// リング署名の対象期間（同一スロット/同日/全期間）
  RingSignatureRange ringRange = RingSignatureRange.slot;

  final _rand = Random();

  /// 鍵ペア（ニックネーム）の更新をセントラル・ペリフェラル・UIに通知するためのストリームコントローラ．
  final StreamController<void> _keyUpdatedController =
  StreamController<void>.broadcast();
  Stream<void> get onKeyUpdated => _keyUpdatedController.stream;

  /// 初期化
  Future<void> init() async {
    await _ensureMasterKey();
  }

  Future<Uint8List?> _ensureMasterKey() async {
    late final String? stored;
    try {
      stored = await _secureStorage.read(key: _masterKeyAlias);
      // ToDo: _secureStorage.read()でUnhandled Exceptionが起こるとアプリケーションが表示されない．再現方法がわからない．
      // PlatformException(Exception encountered, read, javax.crypto.IllegalBlockSizeException: error:1e00007b:Cipher functions:OPENSSL_internal:WRONG_FINAL_BLOCK_LENGTH
    } catch (e) {
      if (kDebugMode) {
        debugPrint('ERROR KMS: master key read $e');
      }
    }
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
    ).onError((e, st) async { //
      if (kDebugMode) debugPrint('_ensureMasterKey: write failed.  retry after deleteing $e $st');
      await _secureStorage.delete(key: _masterKeyAlias);
      await _secureStorage.write(
          key: _masterKeyAlias,
          value: base64Encode(mk));
    });

    if (kDebugMode) {
      debugPrint('KMS: master key generated');
    }
    return mk;
  }

  /// 破棄
  Future<void> dispose() async {
    await _keyUpdatedController.close();
    _currentKeyExpirationTimer?.cancel();
  }

  bool _forPeripheral = false;
  bool _forCentral = false;

  /// 鍵ペアの更新を開始する．ペリフェラルかセントラルのどちらかが呼び出す．
  Future<void> start({bool byPeripheral = false, bool byCentral = false}) async {
    if (byPeripheral) _forPeripheral = true;
    if (byCentral) _forCentral = true;
    if (!_running) {
      _running = true;
      await _updateCurrentKeyPair();
    }
  }

  /// 鍵ペアの更新を停止する．停止している間は，currentLocalKeyPairは更新されない．
  Future<void> stop({bool byPeripheral = false, bool byCentral = false}) async {
    if (byPeripheral) _forPeripheral = false;
    if (byCentral) _forCentral = false;
    if (_forPeripheral || _forCentral) return; // どちらかがまだ
    _running = false;
    _keyUpdatedController.add(null);
    _currentKeyExpirationTimer?.cancel();
    _currentKeyExpirationTimer = null;
  }

  /// currentLocalKeyPairを生成する．
  ///
  /// cryptography パッケージで boringSSL と同じ方法で生成できなかったので，
  /// マスターキーは使わないで，ダミーの秘密鍵と公開鍵（ニックネーム）を返す．
  /// 将来のニックネームは予測できない．
  Future<void> _updateCurrentKeyPair() async {
    if (!_running) return;

    final masterKey = await _ensureMasterKey();
    if (masterKey == null) {
      throw StateError('Failed to obtain master key in KeyManagementService.');
    }

    // 時刻スロットの開始時刻 slotStartTime と失効時刻
    // 失効時刻は次のスロットの間からランダムに選ぶ．
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final slotMs = slot.inMilliseconds;
    _slotNumber = nowMs ~/ slotMs;
    final slotStartTime = DateTime.fromMillisecondsSinceEpoch(
        (nowMs ~/ slotMs) * slotMs);
    // 鍵の失効時刻が他の端末と同じだとBLE通信が衝突するので，ランダムに選ぶ．
    _currentKeyExpirationTime =
        slotStartTime.add(_slot * (1 + _rand.nextDouble()));

    // スロットに対応する鍵対を導出する
    final keyPair = _nativeKeyService.deriveNewKeyPair(masterKey, nowMs, slotMs);
    if (keyPair == null) {
      throw StateError('Failed to obtain new key pair in KeyManagementService.');
    }
    _currentLocalKeyPair = keyPair;

    // 位置情報は後付けのため，まず NULL でデータベースに保存する
    final db = await DatabaseHelper.getDatabase();
    await db.insert('generated_keys', {
      'seckey_ecd': keyPair.privateKey,
      'pubkey_ecd': keyPair.publicKey,
      'lat': null,
      'lon': null,
      'generate_time': now.millisecondsSinceEpoch,
      'expire_time': _currentKeyExpirationTime.millisecondsSinceEpoch,
    });

    _attachLocationAsync(pubkey33: keyPair.publicKey);

    final duration = _currentKeyExpirationTime.difference(DateTime.now());
    _currentKeyExpirationTimer = Timer(duration, () async {
      await _updateCurrentKeyPair();
      if (kDebugMode) {
        debugPrint('${DateTime.now()}'
            ' KeyManagementService _updateCurrentKeyPair by timer #$_slotNumber'
            ' expires at $_currentKeyExpirationTime');
      }
    });
    if (kDebugMode) {
      debugPrint('${DateTime.now()}'
          ' KeyManagementService _updateCurrentKeyPair #$_slotNumber'
          ' expires at $_currentKeyExpirationTime');
    }

    _keyUpdatedController.add(null);
  }

  /// リモートの公開鍵（ニックネーム）を受信したときに，データベースに保存する．
  Future<bool> insertCollectedPubKeyIfAbsent({
      required Uint8List pubkey33,
      required DateTime exchangedAt}) async {
    if (!_isValidCompressedPubkey33(pubkey33)) {
      throw StateError('Invalid compressed public key for insert.');
    }
    final Database db = await DatabaseHelper.getDatabase();

    final values = <String, Object?>{
      'pubkey_ecd': pubkey33,
      'receive_time': exchangedAt.millisecondsSinceEpoch,
    };

    try {
      final rowId = await db.insert(
        'collected_keys',
        values,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

      final inserted = rowId > 0;
      if (inserted) {
        _keyUpdatedController.add(null);
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

  /// generated_keysテーブルに位置情報を後付けする（generated_keys のみ）
  void _attachLocationAsync({required Uint8List pubkey33}) {
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

        _keyUpdatedController.add(null);
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint('KMS: attach location failed: $e');
          debugPrint('$st');
        }
      }
    }();
  }

  bool _isValidCompressedPubkey33(Uint8List key33) {
    if (key33.length != 33) return false;
    final p = key33[0];
    return (p == 0x02 || p == 0x03);
  }

  /// PSIで使う
  Future<List<Uint8List>> getAllGeneratedPublicKeys() async {
    final db = await DatabaseHelper.getDatabase();
    final rows = await db.query('generated_keys', columns: ['pubkey_ecd']);
    return rows.map((row) => row['pubkey_ecd'] as Uint8List).toList();
  }

  /// PSIで使う
  Future<List<Uint8List>> getAllCollectedPublicKeys() async {
    final db = await DatabaseHelper.getDatabase();
    final rows = await db.query('collected_keys', columns: ['pubkey_ecd']);
    return rows.map((row) => row['pubkey_ecd'] as Uint8List).toList();
  }

  /// PSIで使う．鍵の時刻取得
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

  /// PSIで使う
  Iterable<List<Uint8List>> _chunkPubkeys(List<Uint8List> pubkeys,
      {int chunkSize = 450}) sync* {
    if (pubkeys.isEmpty) return;
    for (int i = 0; i < pubkeys.length; i += chunkSize) {
      final end = (i + chunkSize < pubkeys.length) ? i + chunkSize : pubkeys.length;
      yield pubkeys.sublist(i, end);
    }
  }

  /// PSIで使う
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

        result[base64Encode(pub)] = _GeneratedRow(
          sec: sec,
          pub: pub,
          expire: expire,
          generate: gen,
        );
      }
    }

    return result;
  }

  /// PSIで使う
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
        result[base64Encode(pub)] = ts;
      }
    }

    return result;
  }

  /// PSIで使う
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

  /// PSIで使う．署名者鍵選択（交差集合内で最も新しいもの）
  Future<NicknameKeyPair?> selectSignerKeyFromIntersection(
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
    return NicknameKeyPair(bestSec, bestPub);
  }

  /// PSIで使う．リング対象のフィルタリング
  Future<List<Uint8List>> filterKeysBySameSlot(
      List<Uint8List> intersection,
      int signerGenerateTimeMs,
      ) async {
    final result = <Uint8List>[];

    final range = ringRange;

    final slotMs = slot.inMilliseconds;
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
      final ts = tsMap[base64Encode(pub)];
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

  /// DebugPage 用
  NicknameKeyPair? generateDummyKeyPair() {
    final rnd = Random.secure();
    final dummyMasterkey =
    Uint8List.fromList(List<int>.generate(32, (_) => rnd.nextInt(256)));
    final ts = DateTime.now().millisecondsSinceEpoch;
    return _nativeKeyService.deriveNewKeyPair(dummyMasterkey, ts, slot.inMilliseconds);
  }

  /// 将来ニックネームの交換で使う
  /// 将来分のニックネーム（圧縮公開鍵）リストを生成する
  ///
  /// [firstSlotStartIn]   : 最初のニックネームの開始時刻（丸め処理があるので現在時刻でよい)
  /// [period] : どこまで先を生成するか（例: 1日 or 7日）
  ///
  /// [nicknameList]と[firstSlotStartMs]を返します．
  /// [nicknameList] : ニックネーム（公開鍵）のリスト
  /// [firstSlotStart] : ニックネームの開始時刻（ミリ秒）を返す
  Future<(List<Uint8List>, DateTime)> generateFutureNicknameList({
    required DateTime firstSlotStartIn,
    required Duration period,
  }) async {
    // 1. マスターキーを確保（なければ生成）
    final masterKey = await _ensureMasterKey();
    if (masterKey == null) {
      throw StateError('Master key not available');
    }

    // 2. 現在時刻とスロット長（ミリ秒）を計算
    final nowMs = firstSlotStartIn.millisecondsSinceEpoch;

    // 3. 「いま属しているスロットの開始時刻」に丸める
    final slotMs = slot.inMilliseconds;
    final firstSlotStartMs = (nowMs ~/ slotMs) * slotMs;
    final firstSlotStart = DateTime.fromMillisecondsSinceEpoch(firstSlotStartMs);

    // 4. 何スロット分生成するかを計算（切り上げ）
    final totalMs = period.inMilliseconds;
    final slotCount = (totalMs / slotMs).ceil();
    if (slotCount <= 0) {
      return (<Uint8List>[], firstSlotStart);
    }

    final List<Uint8List> nicknameList = [];

    // 5. 各スロットごとに公開鍵を生成
    var slotStartMs = firstSlotStartMs;
    for (var i = 0; i < slotCount; i++) {
      // 既存のネイティブ関数で「マスターキー＋スロット時刻」から鍵ペアを導出
      final keyPair = _nativeKeyService.deriveNewKeyPair(
        masterKey,
        slotStartMs,
        slotMs,
      );
      slotStartMs += slotMs;

      // 何らかの理由で生成に失敗したらスキップ
      if (keyPair == null) {
        continue;
      }

      nicknameList.add(keyPair.publicKey);
    }

    return (nicknameList, firstSlotStart);
  }

  /// DebugPage 用
  Future<String?> getMasterKeyBase64() {
    return _secureStorage.read(key: _masterKeyAlias);
  }

  /// DebugPage 用
  Future<void> deleteMasterKey() async {
    if (kDebugMode) {
      debugPrint('KMS: delete master key');
    }
    return _secureStorage.delete(key: _masterKeyAlias);
  }
}

/// PSIで使う
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

extension NicknameUint8List on Uint8List {
  /// 33バイトのニックネームを16進表現の文字列にして，4バイトごとに_アンダースコアで区切る．主にデバッグ用
  // KeyManagementServiceのnickname2string()の置き換え
  String hexStr({int len = 0}) {
    if (len == 0) len = this.length;
    final hexString = hex.encode(this.sublist(0, len));
    final joined = RegExp(
      r'.{1,8}(?=(?:.{8})*$)',
    ).allMatches(hexString).map((m) => m.group(0)).join('_');
    if (len < this.length) {
      return '$joined...(${this.length})';
    } else {
      return joined;
    }
  }
}
