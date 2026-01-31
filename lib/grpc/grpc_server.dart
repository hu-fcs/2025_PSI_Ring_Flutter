// lib/grpc/grpc_server.dart

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:grpc/grpc.dart';

import '../proto/generated/grpc.pbgrpc.dart';
import '../ffi/native_key_service.dart';
import '../key_management.dart';
import 'grpc_common.dart';

/// gRPC サーバ実装（PSI + リング署名）。
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

  // 直近セッションの集合サイズ（|S_A|, |S_B|）
  int _lastSaKeyCount = 0; // client keys
  int get _sbKeyCount => _myKeys.length; // server keys

  Uint8List? _lastChallengeC;
  Uint8List? _lastChallengeS;
  Future<Uint8List>? _serverSignatureFuture;

  final _psiEventController = StreamController<PsiResult>.broadcast();
  Stream<PsiResult> get onPsiFinished => _psiEventController.stream;

  final _ringAuthController = StreamController<PsiResult>.broadcast();
  Stream<PsiResult> get onRingAuthenticated => _ringAuthController.stream;

  GrpcServiceImpl() {
    _ready = _initialize();

    // 鍵更新を検知したら PSI 用の鍵セットを再構築する
    _kms.onKeyUpdated.listen((_) async {
      if (kDebugMode) {
        debugPrint('[SERVER] keys updated; reload PSI set');
      }
      await _reloadKeys();
    });
  }

  // ----- Init -----

  Future<void> _initialize() async {
    if (kDebugMode) {
      debugPrint('[SERVER] init');
    }
    _mySecret = _keyService.generateRandomSecret();
    await _reloadKeys();
  }

  Future<void> _reloadKeys() async {
    final generated = await _kms.getAllGeneratedPublicKeys();
    final collected = await _kms.getAllCollectedPublicKeys();

    _myKeys = [...generated, ...collected];
    _myGeneratedKeysHex = generated.map(GrpcCommon.bytesToHex).toList();

    _myEncKeys = _keyService.encryptSet(_myKeys, _mySecret);

    if (kDebugMode) {
      debugPrint(
        '[SERVER] keys loaded: generated=${generated.length}, collected=${collected.length}',
      );
    }
  }

  Future<void> _ensureReady() async => _ready;

  // ----- PSI: exchangeKeys -----

  @override
  Future<KeyExchangeResp> exchangeKeys(
      ServiceCall call,
      KeyExchangeReq request,
      ) async {
    await _ensureReady();

    // クライアント側集合サイズ（|S_A|）
    _lastSaKeyCount = request.encKeys.length;

    final bQ = request.encKeys.map(Uint8List.fromList).toList();
    _serverAbQ = _keyService.encryptSet(bQ, _mySecret);

    return KeyExchangeResp()
      ..serverEncKeys.addAll(_myEncKeys)
      ..clientReencKeys.addAll(_serverAbQ);
  }

  // ----- PSI: finalizePsi -----

  @override
  Future<PsiDone> finalizePsi(
      ServiceCall call,
      ClientFinalReq req,
      ) async {
    await _ensureReady();

    final clientAbP =
    req.clientReencServerKeys.map(Uint8List.fromList).toList();

    final intersection = _computeIntersection(clientAbP);
    _lastIntersection = intersection;

    final commonHex = intersection.map(GrpcCommon.bytesToHex).toList();

    // 共通集合に生成鍵が含まれるかで判定する
    final familiar =
        commonHex.toSet().intersection(_myGeneratedKeysHex.toSet()).isNotEmpty;

    _psiEventController.add(
      PsiResult(
        isFamiliar: familiar,
        saKeyCount: _lastSaKeyCount,
        sbKeyCount: _sbKeyCount,
        commonKeys: commonHex,
        ringSize: 0,
        // サーバ側は UI 通知用のため計測値は保持しない
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

  // ----- Ring signature: exchangeChallenges -----

  @override
  Future<ServerChallenge> exchangeChallenges(
      ServiceCall call,
      ClientChallenge req,
      ) async {
    await _ensureReady();

    if (_lastIntersection.isEmpty) {
      throw GrpcError.failedPrecondition('PSI intersection empty');
    }

    _lastChallengeC = Uint8List.fromList(req.challengeC);
    _lastChallengeS = _keyService.generateRandomSecret();

    _serverSignatureFuture = _computeServerSignatureAsync();

    return ServerChallenge()..challengeS = _lastChallengeS!;
  }

  // ----- Ring signature (server) -----

  Future<Uint8List> _computeServerSignatureAsync() async {
    if (kDebugMode) {
      debugPrint('[SERVER] create ring signature');
    }

    final signer =
    await _kms.selectSignerKeyFromIntersection(_lastIntersection);
    if (signer == null) {
      throw GrpcError.failedPrecondition('No signer key');
    }

    final signerTime = await _kms.getTimestampForKey(signer.publicKey);
    if (signerTime == null) {
      throw GrpcError.failedPrecondition('No signer timestamp');
    }

    // 同一時刻スロット内の鍵に限定してリングを構成する
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

    final sig =
    Uint8List.fromList(sigPtr.asTypedList((1 + ring.length) * 32));
    calloc.free(sigPtr);

    return sig;
  }

  // ----- Ring signature: exchangeRingSignatures -----

  @override
  Future<RingSignatureResp> exchangeRingSignatures(
      ServiceCall call,
      RingSignatureReq request,
      ) async {
    await _ensureReady();

    final sigFromClient = Uint8List.fromList(request.signatureForServer);

    final sigForClient = await _serverSignatureFuture!;
    unawaited(_verifyClientSignatureLater(sigFromClient));

    return RingSignatureResp()..signatureForClient = sigForClient;
  }

  // ----- Ring signature (client verify) -----

  Future<void> _verifyClientSignatureLater(Uint8List clientSig) async {
    final signer =
    await _kms.selectSignerKeyFromIntersection(_lastIntersection);
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

  // ----- Intersection -----

  List<Uint8List> _computeIntersection(List<Uint8List> clientAbP) {
    final abQSet = _serverAbQ.map(GrpcCommon.bytesToHex).toSet();
    final result = <Uint8List>[];

    final n =
    clientAbP.length < _myKeys.length ? clientAbP.length : _myKeys.length;

    for (int i = 0; i < n; i++) {
      if (abQSet.contains(GrpcCommon.bytesToHex(clientAbP[i]))) {
        result.add(_myKeys[i]);
      }
    }
    return result;
  }
}

/// gRPC サーバ管理。
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

    final s = Server.create(
      services: [service],
      codecRegistry: _grpcCommon.codecRegistry,
    );

    await s.serve(
      address: InternetAddress.anyIPv4,
      port: port,
      security: _grpcCommon.buildServerSecurity(),
    );

    _server = s;
    _port = s.port;

    if (kDebugMode) {
      debugPrint('[SERVER] started: $_port');
    }
    return _port!;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _port = null;
    if (s != null) await s.shutdown();
  }
}
