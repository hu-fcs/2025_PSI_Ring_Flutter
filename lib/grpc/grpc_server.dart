// lib/grpc/grpc_server.dart
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:grpc/grpc.dart';

import '../proto/generated/grpc.pbgrpc.dart';
import '../ffi/native_key_service.dart';
import '../key_management_service.dart';
import 'grpc_client.dart'; // PsiResult

/// ===============================================================
///  ECC-PSI サーバ
///  - PSI 完了 → onPsiFinished
///  - リング署名認証成功 → onRingAuthenticated（★ 新追加）
/// ===============================================================
class GrpcServiceImpl extends GrpcServiceBase {
  final NativeKeyService _keyService = NativeKeyService();
  final KeyManagementService _kms = KeyManagementService();

  late final Future<void> _ready;

  // PSI 用
  late Uint8List _mySecret;          // 秘密スカラー a
  List<Uint8List> _myKeys = [];      // P（generated + collected）
  List<Uint8List> _myEncKeys = [];   // aP

  // 自分が「生成した」鍵のみ HEX で保持（顔見知り判定用）
  List<String> _myGeneratedKeysHex = [];

  // クライアント集合 Q に対する abQ
  List<Uint8List> _serverAbQ = [];

  // PSI の共通集合（リング署名フェーズで使用）
  List<Uint8List> _lastIntersection = [];

  // リング署名フェーズ用チャレンジ
  Uint8List? _lastChallengeC;
  Uint8List? _lastChallengeS;

  // PSI 完了イベント（共通集合 + PSI ベースでの判定）
  final StreamController<PsiResult> _psiEventController =
  StreamController<PsiResult>.broadcast();
  Stream<PsiResult> get onPsiFinished => _psiEventController.stream;

  // 🔵 新規：リング署名認証成功イベント
  final StreamController<PsiResult> _ringAuthController =
  StreamController<PsiResult>.broadcast();
  Stream<PsiResult> get onRingAuthenticated =>
      _ringAuthController.stream;

  GrpcServiceImpl() {
    _ready = _initialize();

    _kms.onKeyUpdated.listen((_) async {
      print('[SERVER] 🔔 BLE keys changed → reloading PSI keys...');
      await _reloadKeys();
      print('[SERVER] 🔄 PSI keyset updated.');
    });
  }

  // --------------------------------------------------------------
  Future<void> _initialize() async {
    print('[SERVER] === Initializing PSI Server ===');

    _mySecret = _keyService.generateRandomSecret();
    await _reloadKeys();

    print('[SERVER] === PSI Server Ready ===');
  }

  Future<void> _reloadKeys() async {
    final generated = await _kms.getAllGeneratedPublicKeys();
    final collected = await _kms.getAllCollectedPublicKeys();

    _myGeneratedKeysHex =
        generated.map((e) => _hex(e)).toList(growable: false);

    _myKeys = [...generated, ...collected];

    print('[SERVER] Loaded ${_myKeys.length} BLE keys.');

    _myEncKeys = _keyService.encryptSet(_myKeys, _mySecret);
    print('[SERVER] 🔒 Recomputed server aP keys.');
  }

  Future<void> _ensureReady() async => await _ready;

  // --------------------------------------------------------------
  @override
  Future<KeyExchangeResp> exchangeKeys(
      ServiceCall call, KeyExchangeReq request) async {
    await _ensureReady();

    print('\n[SERVER] === exchangeKeys() called ===');

    await _reloadKeys();

    final bQ = request.encKeys.map(Uint8List.fromList).toList();
    print('[SERVER] 📥 Received ${bQ.length} bQ keys.');

    _serverAbQ = _keyService.encryptSet(bQ, _mySecret);
    print('[SERVER] 🔒 Computed abQ keys.');

    final resp = KeyExchangeResp()
      ..serverEncKeys.addAll(_myEncKeys)
      ..clientReencKeys.addAll(_serverAbQ);

    print('[SERVER] 📤 Sent aP and abQ.');
    return resp;
  }

  // --------------------------------------------------------------
  @override
  Future<PsiDone> finalizePsi(
      ServiceCall call, ClientFinalReq request) async {
    await _ensureReady();

    print('\n[SERVER] === finalizePsi() called ===');

    final clientAbP =
    request.clientReencServerKeys.map(Uint8List.fromList).toList();

    print('[SERVER] 📥 Received ${clientAbP.length} abP keys.');

    final intersected = _computeServerIntersection(
      serverAbQ: _serverAbQ,
      clientAbP: clientAbP,
      originalKeys: _myKeys,
    );
    _lastIntersection = intersected;

    print('[SERVER] 🎯 PSI intersection = ${intersected.length} items.');

    final commonHex = intersected.map(_hex).toList(growable: false);
    final familiar =
        commonHex.toSet().intersection(_myGeneratedKeysHex.toSet()).isNotEmpty;

    print('[SERVER] 👤 Familiar by PSI? → $familiar');

    // 🔵 注意：これは “PSI のみ” の速報値。UI では使わない。
    _psiEventController.add(
      PsiResult(
        commonKeys: commonHex,
        isFamiliar: familiar, // リング前なので不完全
      ),
    );

    _lastChallengeC = null;
    _lastChallengeS = null;

    return PsiDone();
  }

  // --------------------------------------------------------------
  @override
  Future<ServerChallenge> exchangeChallenges(
      ServiceCall call, ClientChallenge request) async {
    await _ensureReady();

    print('\n[SERVER] === exchangeChallenges() called ===');

    if (_lastIntersection.isEmpty) {
      throw GrpcError.failedPrecondition(
          'PSI not completed or no intersection.');
    }

    final challengeC = Uint8List.fromList(request.challengeC);
    final challengeS = _keyService.generateRandomSecret();

    _lastChallengeC = challengeC;
    _lastChallengeS = challengeS;

    print('[SERVER]   challenge_C = ${_hex(challengeC)}');
    print('[SERVER]   challenge_S = ${_hex(challengeS)}');

    return ServerChallenge()..challengeS = challengeS;
  }

  // --------------------------------------------------------------
  @override
  Future<RingSignatureResp> exchangeRingSignatures(
      ServiceCall call, RingSignatureReq request) async {
    await _ensureReady();

    print('\n[SERVER] === exchangeRingSignatures() called ===');

    if (_lastIntersection.isEmpty ||
        _lastChallengeC == null ||
        _lastChallengeS == null) {
      throw GrpcError.failedPrecondition(
          'Ring phase state missing. Run PSI + ExchangeChallenges first.');
    }

    final ringPubKeys = [..._lastIntersection]..sort(_compareUint8List);
    final ringSize = ringPubKeys.length;

    if (ringSize < 2) {
      throw GrpcError.failedPrecondition('Ring size must be >= 2.');
    }

    final latestKeyPair = await _kms.getLatestKeyPair();
    if (latestKeyPair == null) {
      throw GrpcError.failedPrecondition('No server keypair available.');
    }

    final challengeC = _lastChallengeC!;
    final challengeS = _lastChallengeS!;
    final msgForServer = _hex(challengeS);
    final msgForClient = _hex(challengeC);

    // ----------------------------------------------------------
    // (1) クライアント署名検証
    // ----------------------------------------------------------
    final clientSig = Uint8List.fromList(request.signatureForServer);

    const pubLen = 33;
    final ringKeysPtr = calloc<Uint8>(pubLen * ringSize);
    final ringView = ringKeysPtr.asTypedList(pubLen * ringSize);

    int offset = 0;
    for (final key in ringPubKeys) {
      ringView.setAll(offset, key);
      offset += key.length;
    }

    final msgVerifyPtr = msgForServer.toNativeUtf8().cast<Char>();
    final sigPtr = calloc<Uint8>(clientSig.length)
      ..asTypedList(clientSig.length).setAll(0, clientSig);

    final verifyRc = _keyService.verifyRingSignature(
      msgVerifyPtr,
      msgForServer.length,
      sigPtr,
      ringKeysPtr,
      ringSize,
    );

    calloc.free(msgVerifyPtr);
    calloc.free(sigPtr);
    calloc.free(ringKeysPtr);

    if (verifyRc != 1) {
      print('[SERVER] ❌ Client ring signature invalid.');
      throw GrpcError.unauthenticated('Invalid ring signature.');
    }

    print('[SERVER] ✅ Client ring signature verified.');

    // ----------------------------------------------------------
    // (2) サーバ署名生成
    // ----------------------------------------------------------
    final msgPtr2 = msgForClient.toNativeUtf8().cast<Char>();

    final privPtr = calloc<Uint8>(latestKeyPair.privateKey.length)
      ..asTypedList(latestKeyPair.privateKey.length)
          .setAll(0, latestKeyPair.privateKey);

    final ringKeysPtr2 = calloc<Uint8>(pubLen * ringSize);
    final ringView2 = ringKeysPtr2.asTypedList(pubLen * ringSize);

    offset = 0;
    for (final key in ringPubKeys) {
      ringView2.setAll(offset, key);
      offset += key.length;
    }

    final sigOutPtr = calloc<Uint8>((1 + ringSize) * 32);

    final rc2 = _keyService.createRingSignature(
      msgPtr2,
      msgForClient.length,
      privPtr,
      ringKeysPtr2,
      ringSize,
      sigOutPtr,
    );

    calloc.free(msgPtr2);
    calloc.free(privPtr);
    calloc.free(ringKeysPtr2);

    if (rc2 != 1) {
      calloc.free(sigOutPtr);
      throw GrpcError.internal('Server ring signature creation failed.');
    }

    final serverSignature =
    Uint8List.fromList(sigOutPtr.asTypedList((1 + ringSize) * 32));

    calloc.free(sigOutPtr);

    print('[SERVER] ✅ Server ring signature created. len=${serverSignature.length}');

    // ----------------------------------------------------------
    // 🔵 (3) 最終認証成功イベントを UI に通知
    // ----------------------------------------------------------
    _ringAuthController.add(
      PsiResult(
        commonKeys: _lastIntersection.map(_hex).toList(),
        isFamiliar: true, // リング署名まで成功したので顔見知り確定
      ),
    );

    // 1 回使い切り
    _lastChallengeC = null;
    _lastChallengeS = null;

    return RingSignatureResp()..signatureForClient = serverSignature;
  }

  // --------------------------------------------------------------
  List<Uint8List> _computeServerIntersection({
    required List<Uint8List> serverAbQ,
    required List<Uint8List> clientAbP,
    required List<Uint8List> originalKeys,
  }) {
    final abQSet = <String>{};
    for (final q in serverAbQ) {
      abQSet.add(_hex(q));
    }

    final result = <Uint8List>[];

    final len = (clientAbP.length < originalKeys.length)
        ? clientAbP.length
        : originalKeys.length;

    for (int i = 0; i < len; i++) {
      if (abQSet.contains(_hex(clientAbP[i]))) {
        result.add(originalKeys[i]);
      }
    }

    return result;
  }

  String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  int _compareUint8List(Uint8List a, Uint8List b) {
    final m = a.length < b.length ? a.length : b.length;
    for (int i = 0; i < m; i++) {
      final d = a[i] - b[i];
      if (d != 0) return d;
    }
    return a.length - b.length;
  }
}

/// ===============================================================
/// gRPC Server 管理
/// ===============================================================
class PsiGrpcServer {
  Server? _server;
  int? _port;

  late GrpcServiceImpl service;

  bool get isRunning => _server != null;

  Future<int> start({int port = 50051}) async {
    if (_server != null) return _port!;

    service = GrpcServiceImpl();
    await service._ready;

    final server = Server.create(
      services: [service],
      interceptors: const [],
      codecRegistry: CodecRegistry(codecs: [GzipCodec(), IdentityCodec()]),
    );

    await server.serve(
      address: InternetAddress.anyIPv4,
      port: port,
    );

    _server = server;
    _port = server.port;

    print('[gRPC Server] Listening on 0.0.0.0:${_port}');
    return _port!;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _port = null;

    if (s != null) {
      await s.shutdown();
      print('[gRPC Server] stopped');
    }
  }
}
