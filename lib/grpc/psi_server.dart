// psi_server.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:grpc/grpc.dart';

import '../proto/generated/psi.pbgrpc.dart';
import '../native_key_service.dart';
import '../key_management_service.dart';

/// ===============================================================
///      ECC-PSI サーバ（正しい双方向 PSI 対応 + ホットリロード）
/// ===============================================================
class PsiServiceImpl extends PsiServiceBase {
  final NativeKeyService _keyService = NativeKeyService();
  final KeyManagementService _kms = KeyManagementService();

  late final Future<void> _ready;

  late Uint8List _mySecret;         // 秘密スカラー a
  List<Uint8List> _myKeys = [];     // サーバの公開鍵集合 P
  List<Uint8List> _myEncKeys = [];  // aP

  // ★FIX: クライアントの abQ を保持する必要がある
  List<Uint8List> _serverAbQ = [];

  PsiServiceImpl() {
    _ready = _initialize();

    // BLE鍵ホットリロード
    _kms.onKeyUpdated.listen((_) async {
      print('[SERVER] 🔔 BLE keys updated → reloading PSI keys...');
      await _reloadKeys();
      print('[SERVER] 🔄 PSI keyset updated.');
    });
  }

  Future<void> _initialize() async {
    print('[SERVER] Initializing PSI Server...');

    _mySecret = _keyService.generateRandomSecret();

    await _reloadKeys();

    print('[SERVER] PSI Server ready.');
  }

  Future<void> _reloadKeys() async {
    final generated = await _kms.getAllGeneratedPublicKeys();
    final collected = await _kms.getAllCollectedPublicKeys();
    _myKeys = [...generated, ...collected];

    print('[SERVER] Loaded ${_myKeys.length} BLE keys.');

    _myEncKeys = _keyService.encryptSet(_myKeys, _mySecret);
    print('[SERVER] 🔒 Recomputed aP keys.');
  }

  Future<void> _ensureReady() async => await _ready;

  @override
  Future<PingResp> ping(ServiceCall call, PingReq request) async {
    await _ensureReady();
    return PingResp()..msg = 'pong: ${request.msg}';
  }

  /// --------------------------------------------------------------
  /// Phase 1: bQ を受け取り abQ と aP を返す
  /// --------------------------------------------------------------
  @override
  Future<KeyExchangeResp> exchangeKeys(
      ServiceCall call, KeyExchangeReq request) async {
    await _ensureReady();

    print('\n[SERVER] === exchangeKeys() called ===');

    final bQ = request.encKeys.map(Uint8List.fromList).toList();
    print('[SERVER] 📥 Received ${bQ.length} bQ keys.');

    // abQ = a(bQ)
    _serverAbQ = _keyService.encryptSet(bQ, _mySecret);  // ★FIX 保存必須

    print('[SERVER] 🔒 Computed abQ keys.');

    final resp = KeyExchangeResp()
      ..serverEncKeys.addAll(_myEncKeys)   // aP
      ..clientReencKeys.addAll(_serverAbQ); // abQ

    print('[SERVER] 📤 Sent aP and abQ.');
    return resp;
  }

  /// --------------------------------------------------------------
  /// Phase 2: クライアントから abP が送られてきたので、
  ///          サーバ側で abP と abQ の一致を調べる
  /// --------------------------------------------------------------
  @override
  Future<ServerPsiResult> finalizePsi(
      ServiceCall call, ClientFinalReq request) async {
    await _ensureReady();

    print('\n[SERVER] === finalizePsi() called ===');

    final clientAbP =
    request.clientReencServerKeys.map(Uint8List.fromList).toList();

    print('[SERVER] 📥 Received ${clientAbP.length} abP keys.');

    // ★FIX: 正しくは「abQ と abP の比較」
    final intersected = _computeServerIntersection(
      serverAbQ: _serverAbQ,
      clientAbP: clientAbP,
      originalKeys: _myKeys,
    );

    print('[SERVER] 🎯 PSI intersection = ${intersected.length} items.');

    if (intersected.isNotEmpty) {
      print('[SERVER] 💍 [Intersection Results]');
      for (int i = 0; i < intersected.length; i++) {
        final hex = _hex(intersected[i]);
        print('[SERVER]   common key[$i]: $hex');
      }
    }

    final resp = ServerPsiResult()..commonKeys.addAll(intersected);
    return resp;
  }

  /// --------------------------------------------------------------
  /// abQ と abP が一致したら共通集合
  ///
  /// originalKeys[i] がサーバ側の元の公開鍵 (P)
  /// --------------------------------------------------------------
  List<Uint8List> _computeServerIntersection({
    required List<Uint8List> serverAbQ,
    required List<Uint8List> clientAbP,
    required List<Uint8List> originalKeys,
  }) {
    final map = <String, Uint8List>{};

    for (int i = 0; i < serverAbQ.length; i++) {
      map[_hex(serverAbQ[i])] = originalKeys[i];
    }

    final result = <Uint8List>[];

    for (final abp in clientAbP) {
      final h = _hex(abp);
      if (map.containsKey(h)) {
        result.add(map[h]!);
      }
    }

    return result;
  }

  String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}

/// ===============================================================
/// gRPC 管理
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
      interceptors: const <Interceptor>[],
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
