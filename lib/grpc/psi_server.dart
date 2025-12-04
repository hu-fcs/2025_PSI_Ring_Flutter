// lib/grpc/psi_server.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:grpc/grpc.dart';

import '../proto/generated/psi.pbgrpc.dart';
import '../native_key_service.dart';
import '../key_management_service.dart';

/// ===============================================================
///      ECC-PSI サーバ（FinalizePsi は結果送信しない最終版）
/// ===============================================================
class PsiServiceImpl extends PsiServiceBase {
  final NativeKeyService _keyService = NativeKeyService();
  final KeyManagementService _kms = KeyManagementService();

  late final Future<void> _ready;

  late Uint8List _mySecret;           // 秘密スカラー a
  List<Uint8List> _myKeys = [];       // サーバ側公開鍵 P
  List<Uint8List> _myEncKeys = [];    // aP

  // クライアント側集合 Q → abQ
  List<Uint8List> _serverAbQ = [];

  PsiServiceImpl() {
    _ready = _initialize();

    // BLE ホットリロード
    _kms.onKeyUpdated.listen((_) async {
      print('[SERVER] 🔔 BLE keys changed → reloading PSI keys...');
      await _reloadKeys();
      print('[SERVER] 🔄 PSI keyset updated.');
    });
  }

  // --------------------------------------------------------------
  // 初期化
  // --------------------------------------------------------------
  Future<void> _initialize() async {
    print('[SERVER] === Initializing PSI Server ===');

    _mySecret = _keyService.generateRandomSecret();
    await _reloadKeys();

    print('[SERVER] === PSI Server Ready ===');
  }

  // --------------------------------------------------------------
  // BLE鍵を再読み込みして aP を再計算
  // --------------------------------------------------------------
  Future<void> _reloadKeys() async {
    final generated = await _kms.getAllGeneratedPublicKeys();
    final collected = await _kms.getAllCollectedPublicKeys();
    _myKeys = [...generated, ...collected];

    print('[SERVER] Loaded ${_myKeys.length} BLE keys.');

    _myEncKeys = _keyService.encryptSet(_myKeys, _mySecret);
    print('[SERVER] 🔒 Recomputed server aP keys.');
  }

  Future<void> _ensureReady() async => await _ready;

  // --------------------------------------------------------------
  // Ping
  // --------------------------------------------------------------
  @override
  Future<PingResp> ping(ServiceCall call, PingReq request) async {
    await _ensureReady();
    return PingResp()..msg = 'pong: ${request.msg}';
  }

  // --------------------------------------------------------------
  // Phase 1: bQ を受け取り abQ と aP を返す
  // --------------------------------------------------------------
  @override
  Future<KeyExchangeResp> exchangeKeys(
      ServiceCall call, KeyExchangeReq request) async {
    await _ensureReady();

    print('\n[SERVER] === exchangeKeys() called ===');

    final bQ = request.encKeys.map(Uint8List.fromList).toList();
    print('[SERVER] 📥 Received ${bQ.length} bQ keys.');

    // abQ = a(bQ)
    _serverAbQ = _keyService.encryptSet(bQ, _mySecret);
    print('[SERVER] 🔒 Computed abQ keys.');

    final resp = KeyExchangeResp()
      ..serverEncKeys.addAll(_myEncKeys)     // aP
      ..clientReencKeys.addAll(_serverAbQ);  // abQ

    print('[SERVER] 📤 Sent aP and abQ.');
    return resp;
  }

  // --------------------------------------------------------------
  // Phase 2: クライアント → サーバ へ abP を送信
  //
  // ここでサーバも PSI を完了させる。
  // クライアントには結果を送らない（PsiDone を返す）
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

    // ---- ログ出力（結果はクライアントに送らない）----
    print('[SERVER] 🎯 PSI intersection = ${intersected.length} items.');

    if (intersected.isNotEmpty) {
      print('[SERVER] 💍 [Intersection Results]');
      for (int i = 0; i < intersected.length; i++) {
        print('[SERVER]   common key[$i]: ${_hex(intersected[i])}');
      }
    }

    // クライアントには結果を送らない
    return PsiDone();
  }

  // --------------------------------------------------------------
  // abQ と abP を比較し一致した P[i] を返す
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
      final h = _hex(clientAbP[i]);
      if (abQSet.contains(h)) {
        result.add(originalKeys[i]);
      }
    }

    return result;
  }

  // Hex 表記
  String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}

/// ===============================================================
/// gRPC Server 管理
/// ===============================================================
class PsiGrpcServer {
  Server? _server;
  int? _port;

  bool get isRunning => _server != null;

  Future<int> start({int port = 50051}) async {
    if (_server != null) return _port!;

    final service = PsiServiceImpl();
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
