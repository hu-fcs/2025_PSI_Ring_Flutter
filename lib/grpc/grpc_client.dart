// lib/grpc/grpc_client.dart

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:grpc/grpc.dart';

import '../proto/generated/grpc.pbgrpc.dart';
import '../ffi/native_key_service.dart';
import '../key_management.dart';
import 'grpc_common.dart';

/// gRPC クライアント（PSI + リング署名）。
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
    if (kDebugMode) {
      debugPrint('[CLIENT] init');
    }
  }

  Future<void> _ensureReady() async => _ready;

  // ----- Connection -----

  Future<void> connect(String host, int port) async {
    await _ensureReady();

    if (kDebugMode) {
      debugPrint('[CLIENT] connect: $host:$port');
    }

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

      if (kDebugMode) {
        debugPrint('[CLIENT] connected');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[CLIENT] connect failed: $e');
        debugPrint('$st');
      }
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

  // ----- PSI + Ring signature -----

  Future<PsiResult> executePsi() async {
    await _ensureReady();
    final stub = _stub;
    if (stub == null) throw StateError('[CLIENT] not connected');

    final totalSw = Stopwatch()..start();

    // 1) 鍵読み込み（生成鍵 + 収集鍵）
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

    // 2) PSI
    final psiSw = Stopwatch()..start();

    // bQ 計算
    final mySecret = _keyService.generateRandomSecret();
    final myEncKeys = _keyService.encryptSet(myKeys, mySecret);

    // サーバと暗号化集合を交換
    final resp = await stub.exchangeKeys(
      KeyExchangeReq()..encKeys.addAll(myEncKeys),
    );

    final serverEncKeys =
    resp.serverEncKeys.map((e) => Uint8List.fromList(e)).toList();
    final abQ =
    resp.clientReencKeys.map((e) => Uint8List.fromList(e)).toList();

    // サーバ側集合サイズ（|S_B|）
    final sbKeyCount = serverEncKeys.length;

    // abP 計算
    final abP = _keyService.encryptSet(serverEncKeys, mySecret);

    // 共通集合（クライアント側復元）
    final clientCommon = _keyService.intersect(myKeys, abQ, abP);

    await stub.finalizePsi(
      ClientFinalReq()..clientReencServerKeys.addAll(abP),
    );

    psiSw.stop();
    final psiTimeMs = psiSw.elapsedMilliseconds;

    // 3) PSI による顔見知り判定（共通集合に自端末の生成鍵が含まれるか）
    final commonHex = clientCommon.map(GrpcCommon.bytesToHex).toList();
    final myGenHex = generated.map(GrpcCommon.bytesToHex).toSet();
    final familiarByPsi = commonHex.toSet().intersection(myGenHex).isNotEmpty;

    // 4) リング署名（必要時のみ）
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

  // ----- Ring signature phase -----

  Future<(bool, int)> _runRingSignaturePhase({
    required GrpcServiceClient stub,
    required List<Uint8List> intersection,
  }) async {
    final signerKey = await _kms.selectSignerKeyFromIntersection(intersection);
    if (signerKey == null) return (false, 0);

    final generateTimeMs = await _kms.getTimestampForKey(signerKey.publicKey);
    if (generateTimeMs == null) return (false, 0);

    // 同一時刻スロット内の鍵に限定してリングを構成する
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

  // ----- Signature -----

  Uint8List? _createRingSignature(
      String msgHex,
      Uint8List privKey,
      List<Uint8List> ring,
      ) {
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

  bool _verifyRingSignature(
      String msgHex,
      Uint8List sig,
      List<Uint8List> ring,
      ) {
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
