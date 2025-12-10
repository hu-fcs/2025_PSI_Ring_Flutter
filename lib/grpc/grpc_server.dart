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
///  - PSI 完了 → onPsiFinished（UIには出さない）
///  - リング署名相互認証成功 → onRingAuthenticated
/// ===============================================================
class GrpcServiceImpl extends GrpcServiceBase {
  final NativeKeyService _keyService = NativeKeyService();
  final KeyManagementService _kms = KeyManagementService();

  late final Future<void> _ready;

  // PSI 用
  late Uint8List _mySecret;
  List<Uint8List> _myKeys = [];
  List<Uint8List> _myEncKeys = [];

  List<String> _myGeneratedKeysHex = [];
  List<Uint8List> _serverAbQ = [];
  List<Uint8List> _lastIntersection = [];

  Uint8List? _lastChallengeC;
  Uint8List? _lastChallengeS;

  // サーバ署名の非同期生成 Future
  Future<Uint8List>? _serverSignatureFuture;

  // PSI 完了（速報値）
  final _psiEventController = StreamController<PsiResult>.broadcast();
  Stream<PsiResult> get onPsiFinished => _psiEventController.stream;

  // リング署名認証成功イベント
  final _ringAuthController = StreamController<PsiResult>.broadcast();
  Stream<PsiResult> get onRingAuthenticated =>
      _ringAuthController.stream;

  GrpcServiceImpl() {
    _ready = _initialize();

    _kms.onKeyUpdated.listen((_) async {
      await _reloadKeys();
      print('[SERVER] 🔄 PSI keyset updated.');
    });
  }

  Future<void> _initialize() async {
    _mySecret = _keyService.generateRandomSecret();
    await _reloadKeys();
  }

  Future<void> _reloadKeys() async {
    final generated = await _kms.getAllGeneratedPublicKeys();
    final collected = await _kms.getAllCollectedPublicKeys();

    _myGeneratedKeysHex = generated.map((e) => _hex(e)).toList();
    _myKeys = [...generated, ...collected];
    _myEncKeys = _keyService.encryptSet(_myKeys, _mySecret);

    print('[SERVER] Loaded keys = ${_myKeys.length}');
  }

  Future<void> _ensureReady() async => await _ready;

  // ===========================================================
  // Phase 1 : ExchangeKeys
  // ===========================================================
  @override
  Future<KeyExchangeResp> exchangeKeys(
      ServiceCall call, KeyExchangeReq request) async {
    await _ensureReady();

    final bQ = request.encKeys.map(Uint8List.fromList).toList();
    _serverAbQ = _keyService.encryptSet(bQ, _mySecret);

    return KeyExchangeResp()
      ..serverEncKeys.addAll(_myEncKeys)
      ..clientReencKeys.addAll(_serverAbQ);
  }

  // ===========================================================
  // Phase 2 : FinalizePsi
  // ===========================================================
  @override
  Future<PsiDone> finalizePsi(
      ServiceCall call, ClientFinalReq request) async {
    await _ensureReady();

    final clientAbP =
    request.clientReencServerKeys.map(Uint8List.fromList).toList();

    final intersected = _computeServerIntersection(
      serverAbQ: _serverAbQ,
      clientAbP: clientAbP,
      originalKeys: _myKeys,
    );

    _lastIntersection = intersected;

    // 速報（UIでは使わない）
    final commonHex = intersected.map(_hex).toList();
    final familiar = commonHex.toSet().intersection(
      _myGeneratedKeysHex.toSet(),
    ).isNotEmpty;

    _psiEventController.add(
      PsiResult(commonKeys: commonHex, isFamiliar: familiar),
    );

    _lastChallengeC = null;
    _lastChallengeS = null;

    return PsiDone();
  }

  // ===========================================================
  // Phase 3A : Challenge Exchange
  // ===========================================================
  @override
  Future<ServerChallenge> exchangeChallenges(
      ServiceCall call, ClientChallenge request) async {
    await _ensureReady();

    if (_lastIntersection.isEmpty) {
      throw GrpcError.failedPrecondition(
          'PSI not completed or intersection is empty.');
    }

    _lastChallengeC = Uint8List.fromList(request.challengeC);
    _lastChallengeS = _keyService.generateRandomSecret();

    // ========= 🔥 非同期でリング署名を先に生成開始（完全並列化） ========
    _serverSignatureFuture = _computeServerSignatureAsync();

    return ServerChallenge()..challengeS = _lastChallengeS!;
  }

  /// サーバ署名を非同期生成（挑戦値＋最新秘密鍵）
  Future<Uint8List> _computeServerSignatureAsync() async {
    final challengeC = _lastChallengeC!;
    final msgHex = _hex(challengeC);

    final ringPubKeys = [..._lastIntersection]..sort(_compareUint8List);
    final ringSize = ringPubKeys.length;

    final latestKeyPair = await _kms.getLatestKeyPair();
    if (latestKeyPair == null) {
      throw GrpcError.failedPrecondition('No server keypair.');
    }

    // ========== 実際の署名生成（FFI呼び出し） ==========
    final msgPtr = msgHex.toNativeUtf8().cast<Char>();
    const pubLen = 33;

    final ringKeysPtr = calloc<Uint8>(pubLen * ringSize);
    final ringView = ringKeysPtr.asTypedList(pubLen * ringSize);
    int offset = 0;
    for (final pk in ringPubKeys) {
      ringView.setAll(offset, pk);
      offset += pk.length;
    }

    final privPtr = calloc<Uint8>(latestKeyPair.privateKey.length)
      ..asTypedList(latestKeyPair.privateKey.length)
          .setAll(0, latestKeyPair.privateKey);

    final sigOutPtr = calloc<Uint8>((1 + ringSize) * 32);

    final rc = _keyService.createRingSignature(
      msgPtr,
      msgHex.length,
      privPtr,
      ringKeysPtr,
      ringSize,
      sigOutPtr,
    );

    calloc.free(msgPtr);
    calloc.free(privPtr);
    calloc.free(ringKeysPtr);

    if (rc != 1) {
      calloc.free(sigOutPtr);
      throw GrpcError.internal('Server ring signature failed.');
    }

    final sig = Uint8List.fromList(
      sigOutPtr.asTypedList((1 + ringSize) * 32),
    );

    calloc.free(sigOutPtr);

    print('[SERVER] async signature generated (len=${sig.length})');
    return sig;
  }

  // ===========================================================
  // Phase 3B : RingSignature Exchange（Non-blocking server）
  // ===========================================================
  @override
  Future<RingSignatureResp> exchangeRingSignatures(
      ServiceCall call, RingSignatureReq request) async {
    await _ensureReady();

    final clientSig = Uint8List.fromList(request.signatureForServer);

    if (_serverSignatureFuture == null) {
      throw GrpcError.failedPrecondition(
          'Signature generation not started. Run exchangeChallenges first.');
    }

    // ========== ① まずは署名生成Futureを待つ（検証はまだしない） ==========
    final serverSig = await _serverSignatureFuture!;

    // ========= ② 検証はレスポンス返却後にバックグラウンドで行う =========
    unawaited(_verifyClientSignatureLater(clientSig));

    // ========= ③ signature_for_client を即返す（非待機） =========
    return RingSignatureResp()..signatureForClient = serverSig;
  }

  /// クライアント署名の検証をバックグラウンドで行い、
  /// 成功した場合のみ onRingAuthenticated を発火する
  Future<void> _verifyClientSignatureLater(Uint8List clientSig) async {
    try {
      final challengeS = _lastChallengeS!;
      final msgHex = _hex(challengeS);

      final ringPubKeys = [..._lastIntersection]..sort(_compareUint8List);
      final ringSize = ringPubKeys.length;

      const pubLen = 33;
      final ringKeysPtr = calloc<Uint8>(pubLen * ringSize);
      final ringView = ringKeysPtr.asTypedList(pubLen * ringSize);

      int offset = 0;
      for (final pk in ringPubKeys) {
        ringView.setAll(offset, pk);
        offset += pk.length;
      }

      final sigPtr = calloc<Uint8>(clientSig.length)
        ..asTypedList(clientSig.length).setAll(0, clientSig);

      final msgPtr = msgHex.toNativeUtf8().cast<Char>();

      final rc = _keyService.verifyRingSignature(
        msgPtr,
        msgHex.length,
        sigPtr,
        ringKeysPtr,
        ringSize,
      );

      calloc.free(msgPtr);
      calloc.free(sigPtr);
      calloc.free(ringKeysPtr);

      if (rc == 1) {
        print('[SERVER] 🎉 Client ring signature verified (async)');
        _ringAuthController.add(
          PsiResult(
            commonKeys: _lastIntersection.map(_hex).toList(),
            isFamiliar: true,
          ),
        );
      } else {
        print('[SERVER] ❌ Client ring signature FAILED (async)');
      }
    } catch (e) {
      print('[SERVER] ERROR during async verification: $e');
    } finally {
      _lastChallengeC = null;
      _lastChallengeS = null;
      _serverSignatureFuture = null;
    }
  }

  // ===========================================================
  List<Uint8List> _computeServerIntersection({
    required List<Uint8List> serverAbQ,
    required List<Uint8List> clientAbP,
    required List<Uint8List> originalKeys,
  }) {
    final abQSet = serverAbQ.map(_hex).toSet();

    final result = <Uint8List>[];
    final len = clientAbP.length < originalKeys.length
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

    await server.serve(address: InternetAddress.anyIPv4, port: port);

    _server = server;
    _port = server.port;

    print('[gRPC Server] Listening on 0.0.0.0:${_port}');
    return _port!;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _port = null;
    if (s != null) await s.shutdown();
  }
}
