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
import 'grpc_client.dart';

/// ===============================================================
///                     ECC-PSI サーバ
///  - PSI 完了通知 → onPsiFinished
///  - リング署名相互認証成功 → onRingAuthenticated
/// ===============================================================
class GrpcServiceImpl extends GrpcServiceBase {
  final NativeKeyService _keyService = NativeKeyService();
  final KeyManagementService _kms = KeyManagementService();

  late final Future<void> _ready;

  // PSI の内部状態
  late Uint8List _mySecret;
  List<Uint8List> _myKeys = [];
  List<Uint8List> _myEncKeys = [];
  List<String> _myGeneratedKeysHex = [];

  List<Uint8List> _serverAbQ = [];
  List<Uint8List> _lastIntersection = [];

  Uint8List? _lastChallengeC;
  Uint8List? _lastChallengeS;
  Future<Uint8List>? _serverSignatureFuture;

  // PSI 終了イベント
  final _psiEventController = StreamController<PsiResult>.broadcast();
  Stream<PsiResult> get onPsiFinished => _psiEventController.stream;

  // リング署名認証成功イベント
  final _ringAuthController = StreamController<PsiResult>.broadcast();
  Stream<PsiResult> get onRingAuthenticated =>
      _ringAuthController.stream;

  GrpcServiceImpl() {
    _ready = _initialize();

    _kms.onKeyUpdated.listen((_) async {
      print('[SERVER] 🔔 BLE鍵の更新を検知 → 再ロードを実行します');
      await _reloadKeys();
      print('[SERVER] 🔄 PSI鍵セットを更新しました');
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

    print('[SERVER] 🔑 BLE鍵読み込み: generated=${generated.length}, collected=${collected.length}, total=${_myKeys.length}');

    print('[SERVER] 🔒 aP（サーバ側暗号化鍵）を再計算します...');
    _myEncKeys = _keyService.encryptSet(_myKeys, _mySecret);
    print('[SERVER] 🔒 aP 計算完了 (${_myEncKeys.length} 件)');
  }

  Future<void> _ensureReady() async => await _ready;

  // ===============================================================
  // Phase 1: ExchangeKeys
  // ===============================================================
  @override
  Future<KeyExchangeResp> exchangeKeys(
      ServiceCall call, KeyExchangeReq request) async {
    await _ensureReady();

    print('\n[SERVER] === Phase1: ExchangeKeys 開始 ===');

    final bQ = request.encKeys.map(Uint8List.fromList).toList();
    print('[SERVER] 📥 受信: bQ=${bQ.length}');

    print('[SERVER] 🔒 bQ を受け取り abQ を計算中...');
    _serverAbQ = _keyService.encryptSet(bQ, _mySecret);
    print('[SERVER] 🔒 abQ 計算完了 (${_serverAbQ.length} 件)');

    print('[SERVER] 📤 aP と abQ をクライアントへ送信します');

    print('[SERVER] === Phase1: ExchangeKeys 終了 ===');
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

    print('\n[SERVER] === Phase2: FinalizePsi 開始 ===');

    final clientAbP =
    request.clientReencServerKeys.map(Uint8List.fromList).toList();

    print('[SERVER] 📥 受信: abP=${clientAbP.length}');

    print('[SERVER] 🔍 PSI 共通集合の計算を開始します...');
    final intersected = _computeIntersection(clientAbP);

    _lastIntersection = intersected;

    print('[SERVER] 🎯 PSI 共通集合 = ${intersected.length} 件');
    for (int i = 0; i < intersected.length; i++) {
      print('[SERVER]   共通[$i] = ${_hex(intersected[i])}');
    }

    final commonHex = intersected.map(_hex).toList();
    final familiar = commonHex.toSet().intersection(
      _myGeneratedKeysHex.toSet(),
    ).isNotEmpty;

    print('[SERVER] 👤 PSIベースの顔見知り判定 = $familiar');

    _psiEventController.add(
      PsiResult(commonKeys: commonHex, isFamiliar: familiar),
    );

    _lastChallengeC = null;
    _lastChallengeS = null;

    print('[SERVER] === Phase2: FinalizePsi 終了 ===');
    return PsiDone();
  }

  // ===============================================================
  // Phase 3A: ExchangeChallenges
  // ===============================================================
  @override
  Future<ServerChallenge> exchangeChallenges(
      ServiceCall call, ClientChallenge request) async {
    await _ensureReady();

    print('\n[SERVER] === Phase3A: ExchangeChallenges 開始 ===');

    if (_lastIntersection.isEmpty) {
      print('[SERVER] ❌ PSI共通集合が空のためリング署名へ進めません');
      throw GrpcError.failedPrecondition('PSI intersection empty.');
    }

    _lastChallengeC = Uint8List.fromList(request.challengeC);
    _lastChallengeS = _keyService.generateRandomSecret();

    print('[SERVER] 📥 challenge_C 受信: ${_hex(_lastChallengeC!)}');
    print('[SERVER] 📤 challenge_S 送信: ${_hex(_lastChallengeS!)}');

    // 非同期署名生成スタート
    print('[SERVER] ✍️（非同期）サーバ署名生成を開始します');
    _serverSignatureFuture = _computeServerSignatureAsync();

    print('[SERVER] === Phase3A: ExchangeChallenges 終了 ===');
    return ServerChallenge()..challengeS = _lastChallengeS!;
  }

  // ===============================================================
  // サーバ署名生成（非同期）
  // ===============================================================
  Future<Uint8List> _computeServerSignatureAsync() async {
    print('[SERVER] ✍️（非同期）署名生成フェーズ開始');

    final msgHex = _hex(_lastChallengeC!);
    print('[SERVER]   署名対象メッセージ: $msgHex');

    final ring = [..._lastIntersection]..sort(_compare);
    print('[SERVER] 🔗 リングサイズ = ${ring.length}（ソート済）');

    final keyPair = await _kms.getLatestKeyPair();
    if (keyPair == null) {
      print('[SERVER] ❌ サーバ秘密鍵が存在しません');
      throw GrpcError.failedPrecondition('Missing keypair');
    }

    // --- FFI 署名処理 ---
    final msgPtr = msgHex.toNativeUtf8().cast<Char>();
    const pubLen = 33;

    final ringPtr = calloc<Uint8>(pubLen * ring.length);
    final list = ringPtr.asTypedList(pubLen * ring.length);

    int offset = 0;
    for (final pk in ring) {
      list.setAll(offset, pk);
      offset += pk.length;
    }

    final privPtr = calloc<Uint8>(keyPair.privateKey.length)
      ..asTypedList(keyPair.privateKey.length)
          .setAll(0, keyPair.privateKey);

    final sigOutPtr = calloc<Uint8>((1 + ring.length) * 32);

    final rc = _keyService.createRingSignature(
      msgPtr,
      msgHex.length,
      privPtr,
      ringPtr,
      ring.length,
      sigOutPtr,
    );

    calloc.free(msgPtr);
    calloc.free(privPtr);
    calloc.free(ringPtr);

    if (rc != 1) {
      calloc.free(sigOutPtr);
      print('[SERVER] ❌ 署名生成失敗');
      throw GrpcError.internal('Signature failed');
    }

    final sig = Uint8List.fromList(sigOutPtr.asTypedList((1 + ring.length) * 32));
    calloc.free(sigOutPtr);

    print('[SERVER] ✍️（非同期）署名生成完了 len=${sig.length}');
    return sig;
  }

  // ===============================================================
  // Phase 3B: RingSignature Exchange（レスポンス即返し）
  // ===============================================================
  @override
  Future<RingSignatureResp> exchangeRingSignatures(
      ServiceCall call, RingSignatureReq request) async {
    await _ensureReady();

    print('\n[SERVER] === Phase3B: ExchangeRingSignatures 開始 ===');

    final clientSig = Uint8List.fromList(request.signatureForServer);
    print('[SERVER] 📥 クライアント署名を受信');

    if (_serverSignatureFuture == null) {
      print('[SERVER] ❌ サーバ署名生成が開始されていません');
      throw GrpcError.failedPrecondition('Signature not started');
    }

    // サーバ署名生成完了まで待つ
    print('[SERVER] ⏳ サーバ署名生成完了待ち...');
    final sigForClient = await _serverSignatureFuture!;

    print('[SERVER] 📤 サーバ署名を返します（検証は非同期で実施）');

    // クライアント署名の検証は非同期
    unawaited(_verifyClientSignatureLater(clientSig));

    print('[SERVER] === Phase3B: ExchangeRingSignatures 終了 ===');
    return RingSignatureResp()..signatureForClient = sigForClient;
  }

  // ===============================================================
  // クライアント署名の非同期検証
  // ===============================================================
  Future<void> _verifyClientSignatureLater(Uint8List sig) async {
    print('[SERVER] 🔍（非同期）クライアント署名の検証開始');

    try {
      final msgHex = _hex(_lastChallengeS!);
      final ring = [..._lastIntersection]..sort(_compare);

      print('[SERVER] 🔗 リングサイズ = ${ring.length}（ソート済）');

      // --- FFI ---
      const pubLen = 33;

      final ringPtr = calloc<Uint8>(pubLen * ring.length)
        ..asTypedList(pubLen * ring.length);

      int offset = 0;
      for (final k in ring) {
        ringPtr.asTypedList(pubLen * ring.length).setAll(offset, k);
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
        print('[SERVER] 🎉（非同期）クライアント署名 → 正当と確認');
        _ringAuthController.add(
          PsiResult(
            commonKeys: _lastIntersection.map(_hex).toList(),
            isFamiliar: true,
          ),
        );
      } else {
        print('[SERVER] ❌（非同期）クライアント署名 → 不正');
      }
    } catch (e) {
      print('[SERVER] ❌（非同期）署名検証中エラー: $e');
    } finally {
      print('[SERVER] 🔄 チャレンジ値と内部状態をクリア');
      _lastChallengeC = null;
      _lastChallengeS = null;
      _serverSignatureFuture = null;
    }
  }

  // ===============================================================
  // PSI 共通集合ロジック
  // ===============================================================
  List<Uint8List> _computeIntersection(List<Uint8List> clientAbP) {
    print('[SERVER] 🔍 PSI共通集合ロジック開始');

    final abQSet = _serverAbQ.map(_hex).toSet();
    final res = <Uint8List>[];

    final len = clientAbP.length < _myKeys.length
        ? clientAbP.length
        : _myKeys.length;

    for (int i = 0; i < len; i++) {
      if (abQSet.contains(_hex(clientAbP[i]))) {
        res.add(_myKeys[i]);
      }
    }

    print('[SERVER] 🔚 PSI共通集合ロジック終了（${res.length} 件）');
    return res;
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

    print('[SERVER] 🚀 gRPC サーバ起動: 0.0.0.0:${_port}');
    return _port!;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _port = null;

    if (s != null) {
      await s.shutdown();
      print('[SERVER] 🛑 gRPC サーバ停止');
    }
  }
}
