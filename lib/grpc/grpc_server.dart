// lib/grpc/grpc_server.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:grpc/grpc.dart';

import '../proto/generated/psi.pbgrpc.dart';
import '../ffi/native_key_service.dart';
import '../key_management_service.dart';
import 'grpc_client.dart'; // ★ PsiResult を使う

/// ===============================================================
///  ECC-PSI サーバ
///  - FinalizePsi は結果を gRPC では返さない（PsiDone）
///  - 代わりに Stream<PsiResult> で UI にイベント通知
/// ===============================================================
class PsiServiceImpl extends PsiServiceBase {
  final NativeKeyService _keyService = NativeKeyService();
  final KeyManagementService _kms = KeyManagementService();

  late final Future<void> _ready;

  late Uint8List _mySecret;          // 秘密スカラー a
  List<Uint8List> _myKeys = [];      // P（generated + collected）
  List<Uint8List> _myEncKeys = [];   // aP

  // ★ 自分が「生成した」鍵のみ HEX で保持（顔見知り判定用）
  List<String> _myGeneratedKeysHex = [];

  // クライアント集合 Q に対する abQ
  List<Uint8List> _serverAbQ = [];

  // ★ PSI完了イベント（共通集合 + 顔見知り判定をまとめて通知）
  final StreamController<PsiResult> _psiEventController =
  StreamController<PsiResult>.broadcast();
  Stream<PsiResult> get onPsiFinished => _psiEventController.stream;

  PsiServiceImpl() {
    _ready = _initialize();

    // BLE鍵ホットリロード（DebugPage の DB 更新はここには含まれない）
    _kms.onKeyUpdated.listen((_) async {
      print('[SERVER] 🔔 BLE keys changed → reloading PSI keys...');
      await _reloadKeys();
      print('[SERVER] 🔄 PSI keyset updated.');
    });
  }

  // --------------------------------------------------------------
  /// 初期化
  // --------------------------------------------------------------
  Future<void> _initialize() async {
    print('[SERVER] === Initializing PSI Server ===');

    _mySecret = _keyService.generateRandomSecret();
    await _reloadKeys();

    print('[SERVER] === PSI Server Ready ===');
  }

  // --------------------------------------------------------------
  /// DB から鍵を読み込み aP を再計算
  ///  - generated: 自分が生成した鍵
  ///  - collected: 相手などから収集した鍵
  // --------------------------------------------------------------
  Future<void> _reloadKeys() async {
    final generated = await _kms.getAllGeneratedPublicKeys(); // 自分の鍵
    final collected = await _kms.getAllCollectedPublicKeys(); // 他人の鍵

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
  Future<PingResp> ping(ServiceCall call, PingReq request) async {
    await _ensureReady();
    return PingResp()..msg = 'pong: ${request.msg}';
  }

  // --------------------------------------------------------------
  /// Phase 1: bQ を受け取り abQ と aP を返す
  // --------------------------------------------------------------
  @override
  Future<KeyExchangeResp> exchangeKeys(
      ServiceCall call, KeyExchangeReq request) async {
    await _ensureReady();

    print('\n[SERVER] === exchangeKeys() called ===');

    // PSI 開始前に、DebugPage などの DB 更新を反映
    await _reloadKeys();

    final bQ = request.encKeys.map(Uint8List.fromList).toList();
    print('[SERVER] 📥 Received ${bQ.length} bQ keys.');

    // abQ = a(bQ)
    _serverAbQ = _keyService.encryptSet(bQ, _mySecret);
    print('[SERVER] 🔒 Computed abQ keys.');

    final resp = KeyExchangeResp()
      ..serverEncKeys.addAll(_myEncKeys)    // aP
      ..clientReencKeys.addAll(_serverAbQ); // abQ

    print('[SERVER] 📤 Sent aP and abQ.');
    return resp;
  }

  // --------------------------------------------------------------
  /// Phase 2: abP を受け取り PSI を完了
  ///         - gRPC の戻り値は PsiDone（軽量）
  ///         - UI には Stream<PsiResult> で通知
  // --------------------------------------------------------------
  @override
  Future<PsiDone> finalizePsi(
      ServiceCall call, ClientFinalReq request) async {
    await _ensureReady();

    print('\n[SERVER] === finalizePsi() called ===');

    final clientAbP =
    request.clientReencServerKeys.map(Uint8List.fromList).toList();

    print('[SERVER] 📥 Received ${clientAbP.length} abP keys.');

    // PSI 共通鍵（元の公開鍵 P のリスト）
    final intersected = _computeServerIntersection(
      serverAbQ: _serverAbQ,
      clientAbP: clientAbP,
      originalKeys: _myKeys,
    );

    print('[SERVER] 🎯 PSI intersection = ${intersected.length} items.');
    if (intersected.isNotEmpty) {
      print('[SERVER] 💍 [Intersection Results]');
      for (int i = 0; i < intersected.length; i++) {
        print('[SERVER]   common[$i]: ${_hex(intersected[i])}');
      }
    }

    // ----------------------------------------------------------
    // 顔見知り判定:
    //   - intersected に「自分が生成した鍵」の HEX が含まれているか
    // ----------------------------------------------------------
    final commonHex = intersected.map(_hex).toList(growable: false);
    final myGenSet = _myGeneratedKeysHex.toSet();
    final familiar =
        commonHex.toSet().intersection(myGenSet).isNotEmpty;

    print('[SERVER] 👤 Familiar? → $familiar');

    // UI（ExchangePage）へイベント通知
    final psiResult = PsiResult(
      commonKeys: commonHex,
      isFamiliar: familiar,
    );
    _psiEventController.add(psiResult);

    // gRPC レスポンス自体は軽量な PsiDone のみ
    return PsiDone();
  }

  // --------------------------------------------------------------
  /// abQ と abP を比較し、一致する P[i] を返す
  // --------------------------------------------------------------
  List<Uint8List> _computeServerIntersection({
    required List<Uint8List> serverAbQ,   // abQ
    required List<Uint8List> clientAbP,   // abP
    required List<Uint8List> originalKeys, // P
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
}

/// ===============================================================
/// gRPC Server 管理
/// ===============================================================
class PsiGrpcServer {
  Server? _server;
  int? _port;

  // ★ PsiServiceImpl を直接参照できるようにしておく
  late PsiServiceImpl service;

  bool get isRunning => _server != null;

  Future<int> start({int port = 50051}) async {
    if (_server != null) return _port!;

    service = PsiServiceImpl();
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
