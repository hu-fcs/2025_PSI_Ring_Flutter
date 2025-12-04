import 'dart:io';
import 'dart:typed_data';
import 'package:grpc/grpc.dart';

import '../proto/generated/psi.pbgrpc.dart';
import '../native_key_service.dart';
import '../key_management_service.dart';

/// ===============================================================
///      ECC-PSI サーバ (BLE鍵ホットリロード対応版)
/// ===============================================================
class PsiServiceImpl extends PsiServiceBase {
  final NativeKeyService _keyService = NativeKeyService();
  final KeyManagementService _kms = KeyManagementService();

  late final Future<void> _ready;

  late Uint8List _mySecret;         // 秘密スカラー a
  List<Uint8List> _myKeys = [];     // BLE 由来の公開鍵 P
  List<Uint8List> _myEncKeys = [];  // aP

  PsiServiceImpl() {
    _ready = _initialize();

    // ★ BLE鍵の更新通知イベントに購読を追加（ホットリロード）
    _kms.onKeyUpdated.listen((_) async {
      print('[SERVER] 🔔 BLE keys updated — reloading PSI keys...');
      await _reloadKeys();
      print('[SERVER] 🔄 PSI keyset updated successfully.');
    });
  }

  /// 初期化処理
  Future<void> _initialize() async {
    print('[SERVER] Initializing PSI Server...');

    // 1. 秘密スカラー a 生成（固定：PSIセッション中は不変）
    _mySecret = _keyService.generateRandomSecret();

    // 2. 初回ロード
    await _reloadKeys();

    print('[SERVER] PSI Server Initialization Complete.');
  }

  /// --------------------------------------------------------------
  /// 🔁 BLE 由来の鍵を再ロードし、aP を再計算する（ホットリロード）
  /// --------------------------------------------------------------
  Future<void> _reloadKeys() async {
    // BLE鍵をDBから再取得
    final generated = await _kms.getAllGeneratedPublicKeys();
    final collected = await _kms.getAllCollectedPublicKeys();
    _myKeys = [...generated, ...collected];

    print('[SERVER] Loaded ${_myKeys.length} BLE keys.');

    // aP の再計算
    _myEncKeys = _keyService.encryptSet(_myKeys, _mySecret);
    print('[SERVER] 🔒 Recomputed aP keys.');
  }

  Future<void> _ensureReady() async => await _ready;

  /// 疎通確認
  @override
  Future<PingResp> ping(ServiceCall call, PingReq request) async {
    await _ensureReady();
    return PingResp()..msg = 'pong: ${request.msg}';
  }

  /// ECC-PSI 鍵交換 RPC
  @override
  Future<KeyExchangeResp> exchangeKeys(
      ServiceCall call, KeyExchangeReq request) async {
    await _ensureReady();

    print('\n[SERVER] === exchangeKeys() called ===');

    // 1. クライアントから bQ
    final encB = request.encKeys.map(Uint8List.fromList).toList();
    print('[SERVER] 📥 Received ${encB.length} encrypted keys (bQ).');

    // 2. abQ = a(bQ)
    final doubleA = _keyService.encryptSet(encB, _mySecret);

    // 3. 応答 (aP, abQ)
    final resp = KeyExchangeResp()
      ..serverEncKeys.addAll(_myEncKeys)
      ..clientReencKeys.addAll(doubleA);

    print('[SERVER] 📤 Sent aP and abQ.\n');
    return resp;
  }
}

/// ===============================================================
/// gRPC サーバ管理
/// ===============================================================
class PsiGrpcServer {
  Server? _server;
  int? _port;

  bool get isRunning => _server != null;

  Future<int> start({int port = 50051}) async {
    if (_server != null) return _port!;

    final service = PsiServiceImpl();

    // 初期化待ち
    await service._ready;

    final server = Server.create(
      services: [service],
      interceptors: const <Interceptor>[],
      codecRegistry:
      CodecRegistry(codecs: [GzipCodec(), IdentityCodec()]),
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

    if (s != null) {
      await s.shutdown();
      print('[gRPC Server] stopped');
    }
  }
}
