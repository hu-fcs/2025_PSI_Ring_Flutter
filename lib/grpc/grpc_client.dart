// lib/grpc/grpc_client.dart
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:grpc/grpc.dart';

import '../proto/generated/grpc.pbgrpc.dart';
import '../ffi/native_key_service.dart';
import '../key_management_service.dart';

/// ===============================================================
/// PSI の結果（共通集合 + 顔見知り判定）
/// ===============================================================
class PsiResult {
  final List<String> commonKeys;
  final bool isFamiliar;

  PsiResult({
    required this.commonKeys,
    required this.isFamiliar,
  });
}

/// ===============================================================
///                     ECC-PSI クライアント
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
    print('[CLIENT] Initializing PSI Client...');
    print('[CLIENT] PSI Client initialization complete.');
  }

  Future<void> _ensureReady() async => await _ready;

  // -------------------------------------------------------------------
  // gRPC Connection
  // -------------------------------------------------------------------
  Future<void> connect(String host, int port) async {
    await _ensureReady();

    print('\n[CLIENT] === connect() called ===');
    print('[CLIENT] Connecting to $host:$port ...');

    try {
      await disconnect();

      _channel = ClientChannel(
        host,
        port: port,
        options: ChannelOptions(
          credentials: ChannelCredentials.insecure(),
          idleTimeout: Duration(seconds: 30),
        ),
      );
      _stub = GrpcServiceClient(_channel!);

      print('[CLIENT] ✅ Connected to server.');
    } catch (e) {
      print('[CLIENT] ❌ Connect ERROR: $e');
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

  // ================================================================
  //                     ECC-PSI（双方向）
  // ================================================================
  Future<PsiResult> executePsi() async {
    await _ensureReady();
    final stub = _stub;
    if (stub == null) throw StateError('[CLIENT] Not connected.');

    print('\n[CLIENT] === PSI Flow Start ===');

    // ------------------------------------------------------------
    // 1. BLE DB から鍵集合を取得
    // ------------------------------------------------------------
    final generated = await _kms.getAllGeneratedPublicKeys();
    final collected = await _kms.getAllCollectedPublicKeys();

    final myKeys = [...generated, ...collected];
    print('[CLIENT] 📦 Loaded ${myKeys.length} BLE keys.');

    if (myKeys.isEmpty) {
      print('[CLIENT] ⚠ No BLE keys found — PSI aborted.');
      return PsiResult(commonKeys: [], isFamiliar: false);
    }

    // ------------------------------------------------------------
    // 2. 秘密スカラー b → bQ
    // ------------------------------------------------------------
    print('[CLIENT] 🔒 Generating client secret "b"...');
    final mySecret = _keyService.generateRandomSecret();
    final myEncKeys = _keyService.encryptSet(myKeys, mySecret);
    print('[CLIENT] 🔑 Created encrypted keys bQ (${myEncKeys.length}).');

    // ------------------------------------------------------------
    // 3. bQ → server へ送信
    // ------------------------------------------------------------
    print('[CLIENT] 📤 Sending bQ to server...');
    final req = KeyExchangeReq()..encKeys.addAll(myEncKeys);

    final resp = await stub.exchangeKeys(
      req,
      options: CallOptions(compression: GzipCodec()),
    );

    final serverEncKeys =
    resp.serverEncKeys.map((e) => Uint8List.fromList(e)).toList();

    final abQ =
    resp.clientReencKeys.map((e) => Uint8List.fromList(e)).toList();

    print('[CLIENT] 📥 Received aP=${serverEncKeys.length}, abQ=${abQ.length}.');

    // ------------------------------------------------------------
    // 4. aP → abP
    // ------------------------------------------------------------
    print('[CLIENT] 🔒 Computing abP = b(aP)...');
    final abP = _keyService.encryptSet(serverEncKeys, mySecret);
    print('[CLIENT] 🔄 Converted aP → abP.');

    // ------------------------------------------------------------
    // 5. Client 側 PSI（共通集合）
    // ------------------------------------------------------------
    print('[CLIENT] 🎯 Extracting PSI intersection (client-side)...');
    final clientCommon = _keyService.intersect(myKeys, abQ, abP);

    print('[CLIENT] 🎯 PSI intersection = ${clientCommon.length} items.');
    for (int i = 0; i < clientCommon.length; i++) {
      print('[CLIENT]   common[$i]: ${_bytesToHex(clientCommon[i])}');
    }

    // ------------------------------------------------------------
    // 6. abP をサーバへ送信（結果なし）
    // ------------------------------------------------------------
    print('[CLIENT] 📤 Sending abP to server (FinalizePsi)...');
    await stub.finalizePsi(
      ClientFinalReq()..clientReencServerKeys.addAll(abP),
      options: CallOptions(compression: GzipCodec()),
    );

    print('[CLIENT] 🔚 finalizePsi completed.');

    // ------------------------------------------------------------
    // 7. 顔見知り判定（PSI）
    // ------------------------------------------------------------
    final commonHex = clientCommon.map(_bytesToHex).toList();

    final myGeneratedHex = generated.map(_bytesToHex).toSet();
    final familiarByPsi =
        commonHex.toSet().intersection(myGeneratedHex).isNotEmpty;

    print('[CLIENT] 👤 Familiar by PSI? → $familiarByPsi');

    // ------------------------------------------------------------
    // 8. リング署名フェーズ
    // ------------------------------------------------------------
    bool ringOk = false;
    if (familiarByPsi && clientCommon.length >= 2) {
      try {
        ringOk = await _runRingSignaturePhase(
          stub: stub,
          intersection: clientCommon,
        );
      } catch (e, st) {
        print('[CLIENT] ❌ Ring signature phase ERROR: $e');
        print(st);
      }
    }

    print('[CLIENT] 🔚 Ring signature result = $ringOk');

    return PsiResult(
      commonKeys: commonHex,
      isFamiliar: familiarByPsi && ringOk,
    );
  }

  // ===============================================================
  // Phase 3: Challenge 交換 + リング署名処理（修正版）
  // ===============================================================
  Future<bool> _runRingSignaturePhase({
    required GrpcServiceClient stub,
    required List<Uint8List> intersection,
  }) async {
    print('\n[CLIENT] === Ring Signature Phase Start ===');

    // ------------------------------------------------------------
    // 1. リング順序（PSI 共通集合をソート）
    // ------------------------------------------------------------
    final ringPubKeys = [...intersection]..sort(_compareUint8List);

    final ringSize = ringPubKeys.length;
    if (ringSize < 2) {
      print('[CLIENT] ⚠ Ring size < 2 → skip.');
      return false;
    }

    // ------------------------------------------------------------
    // 2. 自分の秘密鍵（署名者）を取得
    // ------------------------------------------------------------
    final latestKeyPair = await _kms.getLatestKeyPair();
    if (latestKeyPair == null) {
      print('[CLIENT] ❌ No latest key pair.');
      return false;
    }

    // ------------------------------------------------------------
    // 3. Challenge 交換（クライアント → サーバ）
    // ------------------------------------------------------------
    final challengeC = _keyService.generateRandomSecret();
    final chResp = await stub.exchangeChallenges(
      ClientChallenge()..challengeC = challengeC,
    );

    final challengeS = Uint8List.fromList(chResp.challengeS);

    print('[CLIENT] challenge_C = ${_bytesToHex(challengeC)}');
    print('[CLIENT] challenge_S = ${_bytesToHex(challengeS)}');

    final msgForServer = _bytesToHex(challengeS);
    final msgForClient = _bytesToHex(challengeC);

    // ------------------------------------------------------------
    // 4. 自分 → サーバ のリング署名生成
    // ------------------------------------------------------------
    print('[CLIENT] ✍️ Creating ring signature for server...');

    final msgPtr = msgForServer.toNativeUtf8().cast<Char>();

    final privPtr = calloc<Uint8>(latestKeyPair.privateKey.length)
      ..asTypedList(latestKeyPair.privateKey.length)
          .setAll(0, latestKeyPair.privateKey);

    const pubLen = 33;
    final ringKeysPtr = calloc<Uint8>(pubLen * ringSize);
    final ringView = ringKeysPtr.asTypedList(pubLen * ringSize);

    int offset = 0;
    for (final key in ringPubKeys) {
      ringView.setAll(offset, key);
      offset += key.length;
    }

    final sigOutPtr = calloc<Uint8>((1 + ringSize) * 32);

    Uint8List signatureForServer;
    try {
      final rc = _keyService.createRingSignature(
        msgPtr,
        msgForServer.length,
        privPtr,
        ringKeysPtr,
        ringSize,
        sigOutPtr,
      );

      if (rc != 1) {
        print('[CLIENT] ❌ createRingSignature failed');
        return false;
      }

      signatureForServer =
          Uint8List.fromList(sigOutPtr.asTypedList((1 + ringSize) * 32));

      print('[CLIENT] SignatureForServer OK. len=${signatureForServer.length}');
    } finally {
      calloc.free(msgPtr);
      calloc.free(privPtr);
      calloc.free(ringKeysPtr);
      calloc.free(sigOutPtr);
    }

    // ------------------------------------------------------------
    // 5. 署名送信 → サーバ署名取得
    // ------------------------------------------------------------
    final sigResp = await stub.exchangeRingSignatures(
      RingSignatureReq()..signatureForServer = signatureForServer,
    );

    final sigFromServer = Uint8List.fromList(sigResp.signatureForClient);

    print('[CLIENT] 📥 Received server signature len=${sigFromServer.length}');

    // ------------------------------------------------------------
    // 6. サーバ署名の検証
    // ------------------------------------------------------------
    print('[CLIENT] 🔍 Verifying server signature...');

    final msgVerifyPtr = msgForClient.toNativeUtf8().cast<Char>();

    final ringKeysPtr2 = calloc<Uint8>(pubLen * ringSize);
    final ringView2 = ringKeysPtr2.asTypedList(pubLen * ringSize);

    offset = 0;
    for (final key in ringPubKeys) {
      ringView2.setAll(offset, key);
      offset += key.length;
    }

    final sigPtr = calloc<Uint8>(sigFromServer.length)
      ..asTypedList(sigFromServer.length).setAll(0, sigFromServer);

    try {
      final verifyRc = _keyService.verifyRingSignature(
        msgVerifyPtr,
        msgForClient.length,
        sigPtr,
        ringKeysPtr2,
        ringSize,
      );

      final ok = verifyRc == 1;
      print('[CLIENT] Signature verify → $ok');
      return ok;
    } finally {
      calloc.free(msgVerifyPtr);
      calloc.free(sigPtr);
      calloc.free(ringKeysPtr2);
      print('[CLIENT] === Ring Signature Phase End ===');
    }
  }

  // ===============================================================

  String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  int _compareUint8List(Uint8List a, Uint8List b) {
    final m = a.length < b.length ? a.length : b.length;
    for (int i = 0; i < m; i++) {
      final d = a[i] - b[i];
      if (d != 0) return d;
    }
    return a.length - b.length;
  }
}
