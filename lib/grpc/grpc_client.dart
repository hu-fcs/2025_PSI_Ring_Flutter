// lib/grpc/grpc_client.dart

import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:grpc/grpc.dart';

import '../proto/generated/grpc.pbgrpc.dart';
import '../ffi/native_key_service.dart';
import '../key_management_service.dart';
import '../db/database_helper.dart';

/// ===============================================================
/// PSI の結果（共通集合 + 顔見知り判定）
/// ===============================================================
class PsiResult {
  final bool isFamiliar;
  final int psiKeyCount;
  final List<String> commonKeys;
  final int ringSize;
  final int psiTimeMs;
  final int ringSigTimeMs;
  final int totalTimeMs;

  PsiResult({
    required this.isFamiliar,
    required this.psiKeyCount,
    required this.commonKeys,
    required this.ringSize,
    required this.psiTimeMs,
    required this.ringSigTimeMs,
    required this.totalTimeMs,
  });
}

/// ===============================================================
///                    ECC-PSI クライアント
/// ===============================================================
class GrpcClient {
  ClientChannel? _channel;
  GrpcServiceClient? _stub;

  final NativeKeyService _keyService = NativeKeyService();
  final KeyManagementService _kms = KeyManagementService();

  late final Future<void> _ready;
  bool get isConnected => _stub != null;

  GrpcClient() {
    _ready = _initialize();
  }

  Future<void> _initialize() async {
    print('[CLIENT] === クライアント初期化開始 ===');
    print('[CLIENT] === クライアント初期化完了 ===');
  }

  Future<void> _ensureReady() async => await _ready;

  // ===============================================================
  // gRPC 接続
  // ===============================================================
  Future<void> connect(String host, int port) async {
    await _ensureReady();

    print('\n[CLIENT] === gRPC 接続開始 ===');
    print('[CLIENT] 接続先: $host:$port');

    try {
      await disconnect();

      _channel = ClientChannel(
        host,
        port: port,
        options: ChannelOptions(
          credentials: ChannelCredentials.insecure(),
          idleTimeout: const Duration(seconds: 30),
        ),
      );

      _stub = GrpcServiceClient(_channel!);
      print('[CLIENT] ✅ サーバへの接続成功');
    } catch (e) {
      print('[CLIENT] ❌ 接続失敗: $e');
      rethrow;
    }
  }

  Future<void> disconnect() async {
    try {
      await _channel?.shutdown();
    } catch (_) {}
    _channel = null;
    _stub = null;
  }

  // ===============================================================
  //               PSI + リング署名 フロー（全体）
  // ===============================================================
  Future<PsiResult> executePsi() async {
    await _ensureReady();
    final stub = _stub;
    if (stub == null) throw StateError('[CLIENT] ❌ サーバ未接続');

    // ★ 全体時間計測開始
    final totalSw = Stopwatch()..start();

    print('\n[CLIENT] === PSI フロー開始 ===');

    // ------------------------------------------------------------
    // Phase1: 鍵読み込み
    // ------------------------------------------------------------
    print('[CLIENT] === Phase1: 鍵読み込み 開始 ===');

    final generated = await _kms.getAllGeneratedPublicKeys();
    final collected = await _kms.getAllCollectedPublicKeys();
    final myKeys = [...generated, ...collected];

    print('[CLIENT] 🔑 BLE鍵読み込み: generated=${generated.length}, collected=${collected.length}, total=${myKeys.length}');

    if (myKeys.isEmpty) {
      print('[CLIENT] ⚠ BLE鍵なし → PSI中止');
      totalSw.stop();
      return PsiResult(
        isFamiliar: false,
        commonKeys: [],
        psiKeyCount: 0,
        ringSize: 0,
        psiTimeMs: 0,
        ringSigTimeMs: 0,
        totalTimeMs: totalSw.elapsedMilliseconds,
      );
    }

    print('[CLIENT] === Phase1: 鍵読み込み 終了 ===');

    // ============================================================
    // PSI 時間計測 開始（Phase2〜5）
    // ============================================================
    final psiSw = Stopwatch()..start();

    // ------------------------------------------------------------
    // Phase2: bQ 計算
    // ------------------------------------------------------------
    print('\n[CLIENT] === Phase2: bQ 計算 開始 ===');

    final mySecret = _keyService.generateRandomSecret();
    final myEncKeys = _keyService.encryptSet(myKeys, mySecret);

    print('[CLIENT] 🔒 bQ 計算完了 (${myEncKeys.length} 件)');
    print('[CLIENT] === Phase2: bQ 計算 終了 ===');

    // ------------------------------------------------------------
    // Phase3: ExchangeKeys
    // ------------------------------------------------------------
    print('\n[CLIENT] === Phase3: ExchangeKeys 開始 ===');

    final resp = await stub.exchangeKeys(
      KeyExchangeReq()..encKeys.addAll(myEncKeys),
      options: CallOptions(compression: GzipCodec()),
    );

    final serverEncKeys =
    resp.serverEncKeys.map((e) => Uint8List.fromList(e)).toList();
    final abQ =
    resp.clientReencKeys.map((e) => Uint8List.fromList(e)).toList();

    print('[CLIENT] 📥 受信: aP=${serverEncKeys.length}, abQ=${abQ.length}');
    print('[CLIENT] === Phase3: ExchangeKeys 終了 ===');

    // ------------------------------------------------------------
    // Phase4: abP 計算
    // ------------------------------------------------------------
    print('\n[CLIENT] === Phase4: abP 計算 開始 ===');

    final abP = _keyService.encryptSet(serverEncKeys, mySecret);

    print('[CLIENT] 🔒 abP 計算完了 (${abP.length} 件)');
    print('[CLIENT] === Phase4: abP 計算 終了 ===');

    // ------------------------------------------------------------
    // Phase5: PSI 共通集合
    // ------------------------------------------------------------
    print('\n[CLIENT] === Phase5: PSI 共通集合抽出 開始 ===');

    final clientCommon = _keyService.intersect(myKeys, abQ, abP);

    await stub.finalizePsi(
      ClientFinalReq()..clientReencServerKeys.addAll(abP),
      options: CallOptions(compression: GzipCodec()),
    );

    psiSw.stop();
    final psiTimeMs = psiSw.elapsedMilliseconds;

    print('[CLIENT] 🎯 PSI 共通集合 = ${clientCommon.length} 件');
    print('[CLIENT] ⏱ PSI処理時間 = ${psiTimeMs} ms');
    print('[CLIENT] === Phase5: PSI 共通集合抽出 終了 ===');

    // ------------------------------------------------------------
    // Phase6: PSI 顔見知り判定
    // ------------------------------------------------------------
    final commonHex = clientCommon.map(_hex).toList();
    final myGenHex = generated.map(_hex).toSet();

    final familiarByPsi =
        commonHex.toSet().intersection(myGenHex).isNotEmpty;

    print('[CLIENT] 👤 PSIベースの顔見知り判定 = $familiarByPsi');

    // ------------------------------------------------------------
    // Phase7: リング署名フェーズ（時間計測）
    // ------------------------------------------------------------
    bool ringOk = false;
    int ringSize = 0;
    int ringSigTimeMs = 0;

    if (familiarByPsi && clientCommon.length >= 2) {
      final sw = Stopwatch()..start();

      final result = await _runRingSignaturePhase(
        stub: stub,
        intersection: clientCommon,
      );

      sw.stop();

      ringOk = result.$1;
      ringSize = result.$2;
      ringSigTimeMs = sw.elapsedMilliseconds;

      print('[CLIENT] ⏱ リング署名・検証時間 = ${ringSigTimeMs} ms');
    } else {
      print('[CLIENT] ⚠ PSI条件不足のためリング署名フェーズは実施しません');
    }

    // ★ 全体時間計測終了
    totalSw.stop();
    final totalTimeMs = totalSw.elapsedMilliseconds;

    // ------------------------------------------------------------
    // 最終結果
    // ------------------------------------------------------------
    final result = PsiResult(
      isFamiliar: familiarByPsi && ringOk,
      commonKeys: commonHex,
      psiKeyCount: myKeys.length + serverEncKeys.length,
      ringSize: ringSize,
      psiTimeMs: psiTimeMs,
      ringSigTimeMs: ringSigTimeMs,
      totalTimeMs: totalTimeMs,
    );

    print('[CLIENT] ⭐ 最終判定 isFamiliar=${result.isFamiliar}');
    print('[CLIENT] ⏱ 全体処理時間 = ${totalTimeMs} ms');
    print('-----------------------------------------------');

    return result;
  }

  // ===============================================================
  // 共通集合から署名者鍵を選ぶ
  // ===============================================================
  Future<KeyPair?> _selectSignerKeyFromIntersection(
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
      final expire = row['expire_time'] as int? ?? 0;
      final sec = row['seckey_ecd'] as Uint8List?;
      final p = row['pubkey_ecd'] as Uint8List?;

      if (sec != null && p != null) {
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

  // ===============================================================
  // リング署名フェーズ（結果 + リングサイズ）
  // ===============================================================
  Future<(bool, int)> _runRingSignaturePhase({
    required GrpcServiceClient stub,
    required List<Uint8List> intersection,
  }) async {
    print('[CLIENT] === Phase7: リング署名フェーズ開始 ===');

    final signerKey = await _selectSignerKeyFromIntersection(intersection);
    if (signerKey == null) return (false, 0);

    final db = await DatabaseHelper.getDatabase();
    final rows = await db.query(
      'generated_keys',
      columns: ['generate_time'],
      where: 'pubkey_ecd = ?',
      whereArgs: [signerKey.publicKey],
      limit: 1,
    );

    if (rows.isEmpty) return (false, 0);

    final generateTimeMs = rows.first['generate_time'] as int;

    final filteredRing =
    await _kms.filterKeysBySameSlot(intersection, generateTimeMs);

    if (filteredRing.length < 2) return (false, filteredRing.length);

    filteredRing.sort(_compare);

    final challengeC = _keyService.generateRandomSecret();
    final resp = await stub.exchangeChallenges(
      ClientChallenge()..challengeC = challengeC,
    );

    final challengeS = Uint8List.fromList(resp.challengeS);

    final msgForServer = _hex(challengeS);
    final msgForClient = _hex(challengeC);

    final sigForServer =
    _createRingSignature(msgForServer, signerKey.privateKey, filteredRing);
    if (sigForServer == null) return (false, filteredRing.length);

    final sigResp = await stub.exchangeRingSignatures(
      RingSignatureReq()..signatureForServer = sigForServer,
    );

    final sigFromServer = Uint8List.fromList(sigResp.signatureForClient);

    final ok =
    _verifyRingSignature(msgForClient, sigFromServer, filteredRing);

    print('[CLIENT] === Phase7: 完了（署名検証結果=$ok） ===');

    return (ok, filteredRing.length);
  }

  // ===============================================================
  // 署名生成
  // ===============================================================
  Uint8List? _createRingSignature(
      String msgHex, Uint8List privKey, List<Uint8List> ring) {
    final msgPtr = msgHex.toNativeUtf8().cast<Char>();

    final privPtr = calloc<Uint8>(privKey.length)
      ..asTypedList(privKey.length).setAll(0, privKey);

    const pubLen = 33;
    final ringPtr = calloc<Uint8>(pubLen * ring.length);

    final view = ringPtr.asTypedList(pubLen * ring.length);
    int offset = 0;
    for (final k in ring) {
      view.setAll(offset, k);
      offset += k.length;
    }

    final sigPtr = calloc<Uint8>((1 + ring.length) * 32);

    final rc = _keyService.createRingSignature(
      msgPtr,
      msgHex.length,
      privPtr,
      ringPtr,
      ring.length,
      sigPtr,
    );

    calloc.free(msgPtr);
    calloc.free(privPtr);
    calloc.free(ringPtr);

    if (rc != 1) {
      calloc.free(sigPtr);
      return null;
    }

    final result =
    Uint8List.fromList(sigPtr.asTypedList((1 + ring.length) * 32));

    calloc.free(sigPtr);
    return result;
  }

  // ===============================================================
  // 署名検証
  // ===============================================================
  bool _verifyRingSignature(
      String msgHex, Uint8List sig, List<Uint8List> ring) {
    final msgPtr = msgHex.toNativeUtf8().cast<Char>();

    const pubLen = 33;
    final ringPtr = calloc<Uint8>(pubLen * ring.length);
    final view = ringPtr.asTypedList(pubLen * ring.length);

    int offset = 0;
    for (final k in ring) {
      view.setAll(offset, k);
      offset += k.length;
    }

    final sigPtr = calloc<Uint8>(sig.length)
      ..asTypedList(sig.length).setAll(0, sig);

    final rc = _keyService.verifyRingSignature(
      msgPtr,
      msgHex.length,
      sigPtr,
      ringPtr,
      ring.length,
    );

    calloc.free(msgPtr);
    calloc.free(sigPtr);
    calloc.free(ringPtr);

    return rc == 1;
  }

  // ===============================================================
  // Util
  // ===============================================================
  String _hex(Uint8List b) =>
      b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

  int _compare(Uint8List a, Uint8List b) {
    for (int i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }
}
