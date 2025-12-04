// lib/grpc/psi_server.dart
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

  // クライアント集合 Q に対する abQ を保持（intersection 用）
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

    // サーバ秘密スカラー a
    _mySecret = _keyService.generateRandomSecret();

    await _reloadKeys();

    print('[SERVER] PSI Server ready.');
  }

  Future<void> _reloadKeys() async {
    final generated = await _kms.getAllGeneratedPublicKeys();
    final collected = await _kms.getAllCollectedPublicKeys();
    _myKeys = [...generated, ...collected];

    print('[SERVER] Loaded ${_myKeys.length} BLE keys.');

    // aP を計算
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

    // abQ = a(bQ) （クライアント集合 Q に対応）
    _serverAbQ = _keyService.encryptSet(bQ, _mySecret);

    print('[SERVER] 🔒 Computed abQ keys.');

    final resp = KeyExchangeResp()
      ..serverEncKeys.addAll(_myEncKeys)    // aP（サーバ集合 P に対応）
      ..clientReencKeys.addAll(_serverAbQ); // abQ（クライアント集合 Q に対応）

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

    // abP（サーバ集合 P に対応。順番は _myKeys / _myEncKeys と同じ）
    final clientAbP =
    request.clientReencServerKeys.map(Uint8List.fromList).toList();

    print('[SERVER] 📥 Received ${clientAbP.length} abP keys.');

    final intersected = _computeServerIntersection(
      serverAbQ: _serverAbQ, // abQ（クライアント集合 Q に対応）
      clientAbP: clientAbP,  // abP（サーバ集合 P に対応）
      originalKeys: _myKeys, // P
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
  /// abQ と abP が一致したら共通集合。
  ///
  /// - serverAbQ : クライアント集合 Q の abQ（順序はクライアント側）
  /// - clientAbP : サーバ集合 P の abP（順序は originalKeys と一致）
  /// - originalKeys[i] : サーバ側の公開鍵 P[i]
  ///
  /// ロジック:
  ///   1. abQ をセット（ハッシュセット）化
  ///   2. 各 abP[i] が abQ セットに含まれていれば P[i] が共通要素
  /// --------------------------------------------------------------
  List<Uint8List> _computeServerIntersection({
    required List<Uint8List> serverAbQ,
    required List<Uint8List> clientAbP,
    required List<Uint8List> originalKeys,
  }) {
    // 1. abQ をハッシュセットに（サイズ不一致でも問題なし）
    final abQSet = <String>{};
    for (final q in serverAbQ) {
      abQSet.add(_hex(q));
    }

    // 2. abP と originalKeys（P）は同じインデックス対応として扱う
    final result = <Uint8List>[];

    final n = originalKeys.length;
    final m = clientAbP.length;
    final len = n < m ? n : m; // 念のため、短い方に合わせる

    for (int i = 0; i < len; i++) {
      final h = _hex(clientAbP[i]);
      if (abQSet.contains(h)) {
        result.add(originalKeys[i]); // P[i] が共通鍵
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
