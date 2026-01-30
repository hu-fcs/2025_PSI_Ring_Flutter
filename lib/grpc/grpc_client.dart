// lib/grpc/grpc_client.dart

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:grpc/grpc.dart';

import '../proto/generated/grpc.pbgrpc.dart';
import '../ffi/native_key_service.dart';
import '../key_management_service.dart';
import 'grpc_common.dart';

/// ===============================================================
///                    ECC-PSI クライアント
/// ===============================================================
class GrpcClient {
  ClientChannel? _channel;
  GrpcServiceClient? _stub;

  final NativeKeyService _keyService = NativeKeyService();
  final KeyManagementService _kms = KeyManagementService();
  final GrpcCommon _grpcCommon = GrpcCommon();

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
        options: _grpcCommon.buildClientOptions(
          idleTimeout: const Duration(seconds: 30),
        ),
      );

      _stub = GrpcServiceClient(_channel!);
      print('[CLIENT] ✅ サーバへの接続成功');
    } catch (e, st) {
      print('[CLIENT] ❌ 接続失敗: $e');
      print(st);
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

    final totalSw = Stopwatch()..start();

    print('\n[CLIENT] === PSI フロー開始 ===');

    // ------------------------------------------------------------
    // Phase1: 鍵読み込み（SQLite）
    // ------------------------------------------------------------
    final dbSw = Stopwatch()..start();
    final generated = await _kms.getAllGeneratedPublicKeys();
    final collected = await _kms.getAllCollectedPublicKeys();
    dbSw.stop();

    final myKeys = [...generated, ...collected];

    // クライアント側集合サイズ（|S_A|）
    final saKeyCount = myKeys.length;

    if (myKeys.isEmpty) {
      totalSw.stop();
      return PsiResult(
        isFamiliar: false,
        saKeyCount: 0,
        sbKeyCount: 0,
        commonKeys: const [],
        ringSize: 0,
        dbLoadTimeMs: dbSw.elapsedMilliseconds,
        psiTimeMs: 0,
        ringSigTimeMs: 0,
        totalTimeMs: totalSw.elapsedMilliseconds,
      );
    }

    // ------------------------------------------------------------
    // Phase2-5: PSI 計測
    // ------------------------------------------------------------
    final psiSw = Stopwatch()..start();

    // Phase2: bQ 計算
    final mySecret = _keyService.generateRandomSecret();
    final myEncKeys = _keyService.encryptSet(myKeys, mySecret);

    // Phase3: ExchangeKeys
    final resp = await stub.exchangeKeys(
      KeyExchangeReq()..encKeys.addAll(myEncKeys),
    );

    final serverEncKeys =
    resp.serverEncKeys.map((e) => Uint8List.fromList(e)).toList();
    final abQ =
    resp.clientReencKeys.map((e) => Uint8List.fromList(e)).toList();

    // サーバ側集合サイズ（|S_B|）※サーバが投入した鍵数と一致
    final sbKeyCount = serverEncKeys.length;

    // Phase4: abP 計算
    final abP = _keyService.encryptSet(serverEncKeys, mySecret);

    // Phase5: PSI 共通集合
    final clientCommon = _keyService.intersect(myKeys, abQ, abP);

    await stub.finalizePsi(
      ClientFinalReq()..clientReencServerKeys.addAll(abP),
    );

    psiSw.stop();
    final psiTimeMs = psiSw.elapsedMilliseconds;

    // ------------------------------------------------------------
    // Phase6: PSI 顔見知り判定
    // ------------------------------------------------------------
    final commonHex = clientCommon.map(GrpcCommon.bytesToHex).toList();
    final myGenHex = generated.map(GrpcCommon.bytesToHex).toSet();
    final familiarByPsi = commonHex.toSet().intersection(myGenHex).isNotEmpty;

    // ------------------------------------------------------------
    // Phase7: リング署名（計測）
    // ------------------------------------------------------------
    bool ringOk = false;
    int ringSize = 0;
    int ringSigTimeMs = 0;

    if (familiarByPsi && clientCommon.length >= 2) {
      final ringSw = Stopwatch()..start();

      final result = await _runRingSignaturePhase(
        stub: stub,
        intersection: clientCommon,
      );

      ringSw.stop();
      ringOk = result.$1;
      ringSize = result.$2;
      ringSigTimeMs = ringSw.elapsedMilliseconds;
    }

    totalSw.stop();

    return PsiResult(
      isFamiliar: familiarByPsi && ringOk,
      saKeyCount: saKeyCount,
      sbKeyCount: sbKeyCount,
      commonKeys: commonHex,
      ringSize: ringSize,
      dbLoadTimeMs: dbSw.elapsedMilliseconds,
      psiTimeMs: psiTimeMs,
      ringSigTimeMs: ringSigTimeMs,
      totalTimeMs: totalSw.elapsedMilliseconds,
    );
  }


  // ===============================================================
  // リング署名フェーズ（結果 + リングサイズ）
  // ===============================================================
  Future<(bool, int)> _runRingSignaturePhase({
    required GrpcServiceClient stub,
    required List<Uint8List> intersection,
  }) async {
    final signerKey = await _kms.selectSignerKeyFromIntersection(intersection);
    if (signerKey == null) return (false, 0);

    final generateTimeMs =
    await _kms.getTimestampForKey(signerKey.publicKey);
    if (generateTimeMs == null) return (false, 0);

    final filteredRing =
    await _kms.filterKeysBySameSlot(intersection, generateTimeMs);

    if (filteredRing.length < 2) return (false, filteredRing.length);

    filteredRing.sort(GrpcCommon.comparePubKey);

    final challengeC = _keyService.generateRandomSecret();
    final resp = await stub.exchangeChallenges(
      ClientChallenge()..challengeC = challengeC,
    );

    final challengeS = Uint8List.fromList(resp.challengeS);

    final msgForServer = GrpcCommon.bytesToHex(challengeS);
    final msgForClient = GrpcCommon.bytesToHex(challengeC);

    final sigForServer =
    _createRingSignature(msgForServer, signerKey.privateKey, filteredRing);
    if (sigForServer == null) return (false, filteredRing.length);

    final sigResp = await stub.exchangeRingSignatures(
      RingSignatureReq()..signatureForServer = sigForServer,
    );

    final sigFromServer = Uint8List.fromList(sigResp.signatureForClient);
    final ok = _verifyRingSignature(msgForClient, sigFromServer, filteredRing);

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
}
