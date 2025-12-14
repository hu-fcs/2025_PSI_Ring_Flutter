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
import '../db/database_helper.dart';
import 'grpc_client.dart';

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
      print('[SERVER] 🔔 BLE鍵更新 → PSI鍵セットを再構築します');
      await _reloadKeys();
      print('[SERVER] 🔄 PSI鍵セット更新完了');
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
    _myGeneratedKeysHex = generated.map(_hex).toList();

    print('[SERVER] 🔑 読み込み: generated=${generated.length}, collected=${collected.length}');
    print('[SERVER] 🔒 aP 計算...');
    _myEncKeys = _keyService.encryptSet(_myKeys, _mySecret);
  }

  Future<void> _ensureReady() async => await _ready;

  // ===============================================================
  // 署名者鍵選択（最新 expire_time）
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
      final sec = row['seckey_ecd'] as Uint8List?;
      final p = row['pubkey_ecd'] as Uint8List?;
      final expire = row['expire_time'] as int?;

      if (sec != null && p != null) {
        if (bestExpire == null || expire! > bestExpire) {
          bestExpire = expire;
          bestSec = sec;
          bestPub = p;
        }
      }
    }

    if (bestSec == null || bestPub == null) {
      print('[SERVER] ❌ Server generated_keys から署名者候補が見つからない');
      return null;
    }

    print('[SERVER] 🔑 サーバ署名者鍵選択 (expire_time=$bestExpire)');
    return KeyPair(bestSec, bestPub);
  }

  // ===============================================================
  // Phase 1: ExchangeKeys
  // ===============================================================
  @override
  Future<KeyExchangeResp> exchangeKeys(
      ServiceCall call, KeyExchangeReq request) async {
    await _ensureReady();

    print('\n[SERVER] === Phase1: ExchangeKeys ===');

    final bQ = request.encKeys.map(Uint8List.fromList).toList();
    _serverAbQ = _keyService.encryptSet(bQ, _mySecret);

    return KeyExchangeResp()
      ..serverEncKeys.addAll(_myEncKeys)
      ..clientReencKeys.addAll(_serverAbQ);
  }

  // ===============================================================
  // Phase 2: FinalizePsi
  // ===============================================================
  @override
  Future<PsiDone> finalizePsi(
      ServiceCall call, ClientFinalReq req) async {
    await _ensureReady();

    print('\n[SERVER] === Phase2: FinalizePsi ===');

    final clientAbP =
    req.clientReencServerKeys.map(Uint8List.fromList).toList();

    final intersection = _computeIntersection(clientAbP);
    _lastIntersection = intersection;

    print('[SERVER] 🎯 PSI intersection = ${intersection.length}');

    final commonHex = intersection.map(_hex).toList();
    final familiar =
        commonHex.toSet().intersection(_myGeneratedKeysHex.toSet()).isNotEmpty;

    _psiEventController.add(
      PsiResult(
        isFamiliar: familiar,
        commonKeys: commonHex,
        psiKeyCount: _myKeys.length + _serverAbQ.length,
        ringSize: 0,
        psiTimeMs: 0,
        ringSigTimeMs: 0,
      ),
    );

    _lastChallengeC = null;
    _lastChallengeS = null;

    return PsiDone();
  }

  // ===============================================================
  // Phase 3A: ExchangeChallenges
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

    // 署名生成を非同期実行
    _serverSignatureFuture = _computeServerSignatureAsync();

    return ServerChallenge()..challengeS = _lastChallengeS!;
  }

  // ===============================================================
  // サーバ署名生成（同日フィルタ）
  // ===============================================================
  Future<Uint8List> _computeServerSignatureAsync() async {
    print('[SERVER] ✍️ サーバ署名生成開始');

    final signer = await _selectSignerKeyFromIntersection(_lastIntersection);
    if (signer == null) {
      throw GrpcError.failedPrecondition('No signer key');
    }

    final db = await DatabaseHelper.getDatabase();
    final rows = await db.query(
      'generated_keys',
      columns: ['generate_time'],
      where: 'pubkey_ecd = ?',
      whereArgs: [signer.publicKey],
      limit: 1,
    );

    if (rows.isEmpty) {
      throw GrpcError.failedPrecondition('No generate_time for signer');
    }

    final signerGenerateTimeMs = rows.first['generate_time'] as int;
    print('[SERVER] 🔑 signer generate_time = $signerGenerateTimeMs');

    final filteredRing = await _kms.filterKeysBySameSlot(
      _lastIntersection,
      signerGenerateTimeMs,
    );

    print('[SERVER] 🔍 同日リングサイズ = ${filteredRing.length}');

    if (filteredRing.length < 2) {
      throw GrpcError.failedPrecondition('Ring size too small after filtering');
    }

    filteredRing.sort(_compare);

    final msgHex = _hex(_lastChallengeC!);
    const pubLen = 33;

    final msgPtr = msgHex.toNativeUtf8().cast<Char>();
    final ringPtr = calloc<Uint8>(pubLen * filteredRing.length);
    final ringList = ringPtr.asTypedList(pubLen * filteredRing.length);

    int offset = 0;
    for (final pk in filteredRing) {
      ringList.setAll(offset, pk);
      offset += pk.length;
    }

    final privPtr = calloc<Uint8>(signer.privateKey.length)
      ..asTypedList(signer.privateKey.length).setAll(0, signer.privateKey);

    final sigOut = calloc<Uint8>((1 + filteredRing.length) * 32);

    final rc = _keyService.createRingSignature(
      msgPtr,
      msgHex.length,
      privPtr,
      ringPtr,
      filteredRing.length,
      sigOut,
    );

    calloc.free(msgPtr);
    calloc.free(privPtr);
    calloc.free(ringPtr);

    if (rc != 1) {
      calloc.free(sigOut);
      throw GrpcError.internal('Server signature generation failed');
    }

    final sig =
    Uint8List.fromList(sigOut.asTypedList((1 + filteredRing.length) * 32));
    calloc.free(sigOut);

    print('[SERVER] ✍️ サーバ署名生成完了');
    return sig;
  }

  // ===============================================================
  // Phase 3B: ExchangeRingSignatures
  // ===============================================================
  @override
  Future<RingSignatureResp> exchangeRingSignatures(
      ServiceCall call, RingSignatureReq request) async {
    await _ensureReady();

    final sigFromClient =
    Uint8List.fromList(request.signatureForServer);

    if (_serverSignatureFuture == null) {
      throw GrpcError.failedPrecondition('Signature not ready');
    }

    final sigForClient = await _serverSignatureFuture!;
    unawaited(_verifyClientSignatureLater(sigFromClient));

    return RingSignatureResp()..signatureForClient = sigForClient;
  }

  // ===============================================================
  // クライアント署名検証（同日リング）
  // ===============================================================
  Future<void> _verifyClientSignatureLater(Uint8List clientSig) async {
    print('[SERVER] 🔍 クライアント署名検証開始');

    final signer = await _selectSignerKeyFromIntersection(_lastIntersection);
    if (signer == null) return;

    final db = await DatabaseHelper.getDatabase();
    final rows = await db.query(
      'generated_keys',
      columns: ['generate_time'],
      where: 'pubkey_ecd = ?',
      whereArgs: [signer.publicKey],
      limit: 1,
    );
    if (rows.isEmpty) return;

    final signerGenerateTimeMs = rows.first['generate_time'] as int;

    final filteredRing = await _kms.filterKeysBySameSlot(
      _lastIntersection,
      signerGenerateTimeMs,
    );

    if (filteredRing.length < 2) {
      print('[SERVER] ❌ Filtered ring too small');
      return;
    }

    filteredRing.sort(_compare);

    final msgHex = _hex(_lastChallengeS!);
    const pubLen = 33;

    final ringPtr = calloc<Uint8>(pubLen * filteredRing.length);
    final ringList = ringPtr.asTypedList(pubLen * filteredRing.length);

    int offset = 0;
    for (final k in filteredRing) {
      ringList.setAll(offset, k);
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
      filteredRing.length,
    );

    calloc.free(msgPtr);
    calloc.free(sigPtr);
    calloc.free(ringPtr);

    if (rc == 1) {
      print('[SERVER] 🎉 クライアント署名 → 正当');
      _ringAuthController.add(
        PsiResult(
          isFamiliar: true,
          commonKeys: _lastIntersection.map(_hex).toList(),
          psiKeyCount: _myKeys.length + _serverAbQ.length,
          ringSize: filteredRing.length,
          psiTimeMs: 0,
          ringSigTimeMs: 0,
        ),
      );
    } else {
      print('[SERVER] ❌ クライアント署名 → 不正');
    }

    _lastChallengeC = null;
    _lastChallengeS = null;
    _serverSignatureFuture = null;
  }

  // ===============================================================
  // PSI 共通集合
  // ===============================================================
  List<Uint8List> _computeIntersection(List<Uint8List> clientAbP) {
    final abQSet = _serverAbQ.map(_hex).toSet();
    final result = <Uint8List>[];

    final n = clientAbP.length < _myKeys.length
        ? clientAbP.length
        : _myKeys.length;

    for (int i = 0; i < n; i++) {
      if (abQSet.contains(_hex(clientAbP[i]))) {
        result.add(_myKeys[i]);
      }
    }
    return result;
  }

  // ===============================================================
  // util
  // ===============================================================
  String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  int _compare(Uint8List a, Uint8List b) {
    for (int i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }
}

/// ===============================================================
/// gRPC サーバ管理
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

    final s = Server.create(
      services: [service],
      codecRegistry: CodecRegistry(codecs: [
        GzipCodec(),
        IdentityCodec(),
      ]),
    );

    await s.serve(
      address: InternetAddress.anyIPv4,
      port: port,
    );

    _server = s;
    _port = s.port;

    print('[SERVER] 🚀 gRPCサーバ起動 : $_port');
    return _port!;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _port = null;

    if (s != null) {
      await s.shutdown();
      print('[SERVER] 🛑 gRPCサーバ停止');
    }
  }
}
