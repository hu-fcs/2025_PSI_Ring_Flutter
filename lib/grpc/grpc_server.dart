// lib/grpc/grpc_server.dart
// ★ 修正版（共通集合の中から最新鍵で署名）

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

    _kms.onKeyUpdated.listen((_) async {
      print('[SERVER] 🔔 BLE鍵の更新を検知 → 再ロードを実行します');
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

    print('[SERVER] 🔑 BLE鍵読み込み: generated=${generated.length}, collected=${collected.length}');

    print('[SERVER] 🔒 aP の再計算...');
    _myEncKeys = _keyService.encryptSet(_myKeys, _mySecret);
    print('[SERVER] 🔒 aP 計算完了');
  }

  Future<void> _ensureReady() async => await _ready;

  // ===============================================================
  // 共通集合から署名者の鍵を選択（最新 expire_time を採用）
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

      if (sec == null || p == null) continue;

      if (bestExpire == null || expire! > bestExpire) {
        bestExpire = expire;
        bestSec = sec;
        bestPub = p;
      }
    }

    if (bestSec == null || bestPub == null) {
      print('[SERVER] ❌ 共通集合内にサーバ側の generated_key がありません');
      return null;
    }

    print('[SERVER] 🔑 サーバ署名者鍵を選択 (expire_time=$bestExpire)');
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
    print('[SERVER] 📥 bQ = ${bQ.length}');

    _serverAbQ = _keyService.encryptSet(bQ, _mySecret);
    print('[SERVER] 🔒 abQ 計算完了');

    return KeyExchangeResp()
      ..serverEncKeys.addAll(_myEncKeys)
      ..clientReencKeys.addAll(_serverAbQ);
  }

  // ===============================================================
  // Phase 2: FinalizePsi
  // ===============================================================
  @override
  Future<PsiDone> finalizePsi(
      ServiceCall call, ClientFinalReq request) async {
    await _ensureReady();

    print('\n[SERVER] === Phase2: FinalizePsi ===');

    final clientAbP =
    request.clientReencServerKeys.map(Uint8List.fromList).toList();

    final intersected = _computeIntersection(clientAbP);
    _lastIntersection = intersected;

    print('[SERVER] 🎯 PSI 共通集合 = ${intersected.length}');

    final commonHex = intersected.map(_hex).toList();
    final familiar =
        commonHex.toSet().intersection(_myGeneratedKeysHex.toSet()).isNotEmpty;

    _psiEventController.add(
      PsiResult(commonKeys: commonHex, isFamiliar: familiar),
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
      ServiceCall call, ClientChallenge request) async {
    await _ensureReady();

    if (_lastIntersection.isEmpty) {
      throw GrpcError.failedPrecondition('PSI intersection empty');
    }

    _lastChallengeC = Uint8List.fromList(request.challengeC);
    _lastChallengeS = _keyService.generateRandomSecret();

    // サーバ署名生成（非同期）
    _serverSignatureFuture = _computeServerSignatureAsync();

    return ServerChallenge()..challengeS = _lastChallengeS!;
  }

  // ===============================================================
  // サーバ署名生成（共通集合内の最新鍵で行う）
  // ===============================================================
  Future<Uint8List> _computeServerSignatureAsync() async {
    print('[SERVER] ✍️ サーバ署名生成開始');

    final ring = [..._lastIntersection]..sort(_compare);

    // ★ 共通集合から署名者鍵を選ぶ（重要）
    final signer = await _selectSignerKeyFromIntersection(_lastIntersection);
    if (signer == null) {
      throw GrpcError.failedPrecondition('No signer key in intersection');
    }

    final msgHex = _hex(_lastChallengeC!);
    const pubLen = 33;

    final msgPtr = msgHex.toNativeUtf8().cast<Char>();

    final ringPtr = calloc<Uint8>(pubLen * ring.length);
    final ringList = ringPtr.asTypedList(pubLen * ring.length);

    int offset = 0;
    for (final pk in ring) {
      ringList.setAll(offset, pk);
      offset += pk.length;
    }

    final privPtr = calloc<Uint8>(signer.privateKey.length)
      ..asTypedList(signer.privateKey.length)
          .setAll(0, signer.privateKey);

    final sigOut = calloc<Uint8>((1 + ring.length) * 32);

    final rc = _keyService.createRingSignature(
      msgPtr,
      msgHex.length,
      privPtr,
      ringPtr,
      ring.length,
      sigOut,
    );

    calloc.free(msgPtr);
    calloc.free(privPtr);
    calloc.free(ringPtr);

    if (rc != 1) {
      calloc.free(sigOut);
      throw GrpcError.internal('Signature generation failed');
    }

    final sig =
    Uint8List.fromList(sigOut.asTypedList((1 + ring.length) * 32));
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

    final clientSig = Uint8List.fromList(request.signatureForServer);

    if (_serverSignatureFuture == null) {
      throw GrpcError.failedPrecondition('Server signature not started');
    }

    final sigForClient = await _serverSignatureFuture!;
    unawaited(_verifyClientSignatureLater(clientSig));

    return RingSignatureResp()..signatureForClient = sigForClient;
  }

  // ===============================================================
  // クライアント署名を非同期検証
  // ===============================================================
  Future<void> _verifyClientSignatureLater(Uint8List sig) async {
    final ring = [..._lastIntersection]..sort(_compare);

    final msgHex = _hex(_lastChallengeS!);

    const pubLen = 33;

    final ringPtr = calloc<Uint8>(pubLen * ring.length);
    final ringList = ringPtr.asTypedList(pubLen * ring.length);

    int offset = 0;
    for (final k in ring) {
      ringList.setAll(offset, k);
      offset += k.length;
    }

    final sigPtr = calloc<Uint8>(sig.length)
      ..asTypedList(sig.length).setAll(0, sig);

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
      print('[SERVER] 🎉 クライアント署名 → 正当');
      _ringAuthController.add(
        PsiResult(
          commonKeys: _lastIntersection.map(_hex).toList(),
          isFamiliar: true,
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
    final out = <Uint8List>[];

    final len = clientAbP.length < _myKeys.length
        ? clientAbP.length
        : _myKeys.length;

    for (int i = 0; i < len; i++) {
      if (abQSet.contains(_hex(clientAbP[i]))) {
        out.add(_myKeys[i]);
      }
    }
    return out;
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
