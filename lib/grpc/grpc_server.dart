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
import 'grpc_common.dart';

/// ===============================================================
///                     ECC-PSI サーバ
/// ===============================================================
class GrpcServiceImpl extends GrpcServiceBase {
  final NativeKeyService _keyService = NativeKeyService();
  final KeyManagementService _kms = KeyManagementService();

  late final Future<void> _ready;

  // PSI 状態
  late Uint8List _mySecret;
  List<Uint8List> _myKeys = [];
  List<Uint8List> _myEncKeys = [];
  List<String> _myGeneratedKeysHex = [];

  List<Uint8List> _serverAbQ = [];
  List<Uint8List> _lastIntersection = [];

  // ★ 追加：直近セッションの集合サイズ（論文の |S_A|, |S_B| 用）
  int _lastSaKeyCount = 0; // client keys
  int get _sbKeyCount => _myKeys.length; // server keys（常に現在の _myKeys）

  Uint8List? _lastChallengeC;
  Uint8List? _lastChallengeS;
  Future<Uint8List>? _serverSignatureFuture;

  // イベント
  final _psiEventController = StreamController<PsiResult>.broadcast();
  Stream<PsiResult> get onPsiFinished => _psiEventController.stream;

  final _ringAuthController = StreamController<PsiResult>.broadcast();
  Stream<PsiResult> get onRingAuthenticated => _ringAuthController.stream;

  GrpcServiceImpl() {
    _ready = _initialize();

    // BLE鍵更新 → 再ロード
    _kms.onKeyUpdated.listen((_) async {
      print('[SERVER] 🔔 BLE鍵更新 → PSI鍵セット再構築');
      await _reloadKeys();
    });
  }

  // ===============================================================
  // 初期化
  // ===============================================================
  Future<void> _initialize() async {
    print('[SERVER] === サーバ初期化開始 ===');
    _mySecret = _keyService.generateRandomSecret();
    await _reloadKeys();
    print('[SERVER] === サーバ初期化完了 ===');
  }

  Future<void> _reloadKeys() async {
    final generated = await _kms.getAllGeneratedPublicKeys();
    final collected = await _kms.getAllCollectedPublicKeys();

    _myKeys = [...generated, ...collected];
    _myGeneratedKeysHex = generated.map(GrpcCommon.bytesToHex).toList();

    _myEncKeys = _keyService.encryptSet(_myKeys, _mySecret);

    print('[SERVER] 🔑 generated=${generated.length}, collected=${collected.length}');
  }

  Future<void> _ensureReady() async => _ready;

  // ===============================================================
  // Phase1: ExchangeKeys
  // ===============================================================
  @override
  Future<KeyExchangeResp> exchangeKeys(
      ServiceCall call, KeyExchangeReq request) async {
    await _ensureReady();

    print('[SERVER] === Phase1: ExchangeKeys ===');

    // クライアント投入鍵数（|S_A|）を保持
    _lastSaKeyCount = request.encKeys.length;

    final bQ = request.encKeys.map(Uint8List.fromList).toList();
    _serverAbQ = _keyService.encryptSet(bQ, _mySecret);

    return KeyExchangeResp()
      ..serverEncKeys.addAll(_myEncKeys)
      ..clientReencKeys.addAll(_serverAbQ);
  }

  // ===============================================================
  // Phase2: FinalizePsi
  // ===============================================================
  @override
  Future<PsiDone> finalizePsi(ServiceCall call, ClientFinalReq req) async {
    await _ensureReady();

    print('[SERVER] === Phase2: FinalizePsi ===');

    final clientAbP =
    req.clientReencServerKeys.map(Uint8List.fromList).toList();

    final intersection = _computeIntersection(clientAbP);
    _lastIntersection = intersection;

    final commonHex = intersection.map(GrpcCommon.bytesToHex).toList();

    final familiar =
        commonHex.toSet().intersection(_myGeneratedKeysHex.toSet()).isNotEmpty;

    _psiEventController.add(
      PsiResult(
        isFamiliar: familiar,
        saKeyCount: _lastSaKeyCount,
        sbKeyCount: _sbKeyCount,
        commonKeys: commonHex,
        ringSize: 0,
        // サーバ側は UI 通知用なので計測値は 0 埋め（必要なら後で拡張）
        dbLoadTimeMs: 0,
        psiTimeMs: 0,
        ringSigTimeMs: 0,
        totalTimeMs: 0,
      ),
    );

    _lastChallengeC = null;
    _lastChallengeS = null;

    return PsiDone();
  }

  // ===============================================================
  // Phase3A: ExchangeChallenges
  // ===============================================================
  @override
  Future<ServerChallenge> exchangeChallenges(
      ServiceCall call, ClientChallenge req) async {
    await _ensureReady();

    if (_lastIntersection.isEmpty) {
      throw GrpcError.failedPrecondition('PSI intersection empty');
    }

    _lastChallengeC = Uint8List.fromList(req.challengeC);
    _lastChallengeS = _keyService.generateRandomSecret();

    _serverSignatureFuture = _computeServerSignatureAsync();

    return ServerChallenge()..challengeS = _lastChallengeS!;
  }

  // ===============================================================
  // サーバ署名生成
  // ===============================================================
  Future<Uint8List> _computeServerSignatureAsync() async {
    print('[SERVER] ✍️ サーバ署名生成');

    final signer = await _kms.selectSignerKeyFromIntersection(_lastIntersection);
    if (signer == null) {
      throw GrpcError.failedPrecondition('No signer key');
    }

    final signerTime = await _kms.getTimestampForKey(signer.publicKey);
    if (signerTime == null) {
      throw GrpcError.failedPrecondition('No signer timestamp');
    }

    final ring = await _kms.filterKeysBySameSlot(_lastIntersection, signerTime);
    if (ring.length < 2) {
      throw GrpcError.failedPrecondition('Ring too small');
    }

    ring.sort(GrpcCommon.comparePubKey);

    final msgHex = GrpcCommon.bytesToHex(_lastChallengeC!);

    const pubLen = 33;
    final msgPtr = msgHex.toNativeUtf8().cast<Char>();
    final ringPtr = calloc<Uint8>(pubLen * ring.length);
    final ringView = ringPtr.asTypedList(pubLen * ring.length);

    int offset = 0;
    for (final k in ring) {
      ringView.setAll(offset, k);
      offset += k.length;
    }

    final privPtr = calloc<Uint8>(signer.privateKey.length)
      ..asTypedList(signer.privateKey.length).setAll(0, signer.privateKey);

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
      throw GrpcError.internal('Server signature failed');
    }

    final sig = Uint8List.fromList(sigPtr.asTypedList((1 + ring.length) * 32));
    calloc.free(sigPtr);

    return sig;
  }

  // ===============================================================
  // Phase3B: ExchangeRingSignatures
  // ===============================================================
  @override
  Future<RingSignatureResp> exchangeRingSignatures(
      ServiceCall call, RingSignatureReq request) async {
    await _ensureReady();

    final sigFromClient = Uint8List.fromList(request.signatureForServer);

    final sigForClient = await _serverSignatureFuture!;
    unawaited(_verifyClientSignatureLater(sigFromClient));

    return RingSignatureResp()..signatureForClient = sigForClient;
  }

  // ===============================================================
  // クライアント署名検証
  // ===============================================================
  Future<void> _verifyClientSignatureLater(Uint8List clientSig) async {
    final signer = await _kms.selectSignerKeyFromIntersection(_lastIntersection);
    if (signer == null) return;

    final signerTime = await _kms.getTimestampForKey(signer.publicKey);
    if (signerTime == null) return;

    final ring = await _kms.filterKeysBySameSlot(_lastIntersection, signerTime);
    if (ring.length < 2) return;

    ring.sort(GrpcCommon.comparePubKey);

    final msgHex = GrpcCommon.bytesToHex(_lastChallengeS!);

    const pubLen = 33;
    final ringPtr = calloc<Uint8>(pubLen * ring.length);
    final ringView = ringPtr.asTypedList(pubLen * ring.length);

    int offset = 0;
    for (final k in ring) {
      ringView.setAll(offset, k);
      offset += k.length;
    }

    final sigPtr = calloc<Uint8>(clientSig.length)
      ..asTypedList(clientSig.length).setAll(0, clientSig);

    final msgPtr = msgHex.toNativeUtf8().cast<Char>();

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

    if (rc == 1) {
      _ringAuthController.add(
        PsiResult(
          isFamiliar: true,
          saKeyCount: _lastSaKeyCount,
          sbKeyCount: _sbKeyCount,
          commonKeys: _lastIntersection.map(GrpcCommon.bytesToHex).toList(),
          ringSize: ring.length,
          dbLoadTimeMs: 0,
          psiTimeMs: 0,
          ringSigTimeMs: 0,
          totalTimeMs: 0,
        ),
      );
    }

    _lastChallengeC = null;
    _lastChallengeS = null;
    _serverSignatureFuture = null;
  }

  // ===============================================================
  // PSI 共通集合
  // ===============================================================
  List<Uint8List> _computeIntersection(List<Uint8List> clientAbP) {
    final abQSet = _serverAbQ.map(GrpcCommon.bytesToHex).toSet();
    final result = <Uint8List>[];

    final n = clientAbP.length < _myKeys.length ? clientAbP.length : _myKeys.length;

    for (int i = 0; i < n; i++) {
      if (abQSet.contains(GrpcCommon.bytesToHex(clientAbP[i]))) {
        result.add(_myKeys[i]);
      }
    }
    return result;
  }
}

/// ===============================================================
/// gRPC サーバ管理
/// ===============================================================
class PsiGrpcServer {
  Server? _server;
  int? _port;

  late GrpcServiceImpl service;

  final GrpcCommon _grpcCommon = GrpcCommon();

  bool get isRunning => _server != null;

  Future<int> start({int port = 50051}) async {
    if (_server != null) return _port!;

    service = GrpcServiceImpl();
    await service._ready;

    // ★ enableTls に応じて security を構築（OFFなら null）
    final security = _grpcCommon.buildServerSecurity();

    final s = Server.create(
      services: [service],
      codecRegistry: _grpcCommon.codecRegistry,
    );

    await s.serve(
      address: InternetAddress.anyIPv4,
      port: port,
      security: security,
    );

    _server = s;
    _port = s.port;

    print('[SERVER] 🚀 gRPC サーバ起動 : $_port');
    return _port!;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _port = null;
    if (s != null) await s.shutdown();
  }
}
