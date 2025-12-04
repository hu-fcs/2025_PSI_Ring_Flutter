import 'dart:io';
import 'dart:typed_data';
import 'package:grpc/grpc.dart';

import '../proto/generated/psi.pbgrpc.dart';
import '../native_key_service.dart';
import '../key_management_service.dart';

/// ===============================================================
///  ECC-PSI サーバ実装（初期化完了を保証する async-ready 対応版）
/// ===============================================================
class PsiServiceImpl extends PsiServiceBase {
  final NativeKeyService _keyService = NativeKeyService();
  final KeyManagementService _kms = KeyManagementService();

  late final Future<void> _ready; // ★ 初期化完了待ち用 Future

  late List<Uint8List> _myKeys;     // BLE の公開鍵 (P)
  late Uint8List _mySecret;         // 秘密スカラー a
  late List<Uint8List> _myEncKeys;  // aP

  PsiServiceImpl() {
    _ready = _initialize(); // ★ 初期化 Future を保持
  }

  /// ---------------------------------------------------------------
  /// 🔧 初期化: BLE の鍵を読み込み、自分の秘密値で aP を準備する
  /// ---------------------------------------------------------------
  Future<void> _initialize() async {
    print('[SERVER] Initializing PSI Server...');

    // 1. 秘密スカラー a を生成
    _mySecret = _keyService.generateRandomSecret();

    // 2. BLE DB から公開鍵を読み出し
    final generated = await _kms.getAllGeneratedPublicKeys();
    final collected = await _kms.getAllCollectedPublicKeys();
    _myKeys = [...generated, ...collected];

    print('[SERVER] Loaded ${_myKeys.length} BLE-derived keys.');

    if (_myKeys.isEmpty) {
      print('[SERVER] ⚠ No BLE keys found. PSI results will be empty.');
    }

    // 3. P → aP の暗号化（PSI 第1段階）
    _myEncKeys = _keyService.encryptSet(_myKeys, _mySecret);

    print('[SERVER] PSI Server Initialization Complete.');
  }

  /// ---------------------------------------------------------------
  /// 🔒 RPC 呼び出し前に初期化完了を保証する
  /// ---------------------------------------------------------------
  Future<void> _ensureReady() async {
    await _ready;
  }

  /// 疎通確認
  @override
  Future<PingResp> ping(ServiceCall call, PingReq request) async {
    await _ensureReady(); // ← 初期化が終わるまで待つ
    print('[SERVER] ping received: ${request.msg}');
    return PingResp()..msg = 'pong: ${request.msg}';
  }

  /// ---------------------------------------------------------------
  /// 🔄 ECC-PSI 鍵交換
  ///
  /// Client:  bQ を送信
  /// Server:  aP（自分側） + abQ（相手側再暗号化）
  /// ---------------------------------------------------------------
  @override
  Future<KeyExchangeResp> exchangeKeys(
      ServiceCall call, KeyExchangeReq request) async {
    await _ensureReady(); // ← 初期化保証

    print('\n[SERVER] === exchangeKeys() called ===');

    // 1. クライアントの bQ
    final encB = request.encKeys.map(Uint8List.fromList).toList();
    print('[SERVER] 📥 Received ${encB.length} encrypted keys (bQ).');

    // 2. abQ = a(bQ)
    final doubleA = _keyService.encryptSet(encB, _mySecret);
    print('[SERVER] 🔒 Re-encrypted client keys → abQ');

    // 3. 応答 (aP + abQ)
    final resp = KeyExchangeResp()
      ..serverEncKeys.addAll(_myEncKeys) // aP
      ..clientReencKeys.addAll(doubleA); // abQ

    print('[SERVER] 📤 Sending aP and abQ.');
    print('[SERVER] === exchangeKeys() completed ===\n');

    return resp;
  }
}

/// ===============================================================
///  gRPC サーバ管理クラス（サービスの初期化完了を待ってから起動）
/// ===============================================================
class PsiGrpcServer {
  Server? _server;
  int? _port;

  bool get isRunning => _server != null;
  int? get port => _port;

  Future<int> start({int port = 50051}) async {
    if (_server != null) return _port!;

    final service = PsiServiceImpl();

    // ★ ここでサービスの初期化が終わるまで待つ
    await service._ready;
    print('[gRPC Server] PSI service initialization completed.');

    final server = Server.create(
      services: [service],
      interceptors: const <Interceptor>[],
      codecRegistry: CodecRegistry(
        codecs: [GzipCodec(), IdentityCodec()],
      ),
    );

    await server.serve(
      address: InternetAddress.anyIPv4,
      port: port,
    );

    _server = server;
    _port = server.port;

    print('[gRPC Server] listening on 0.0.0.0:${_port}');
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
