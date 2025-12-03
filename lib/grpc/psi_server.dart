// psi_server.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:grpc/grpc.dart';

import '../proto/generated/psi.pbgrpc.dart';
import '../key_management_service.dart';

class PsiServiceImpl extends PsiServiceBase {
  final KeyManagementService _keyService = KeyManagementService();

  // デバッグログ用: バイト列をHex文字列に変換
  String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  Future<PingResp> ping(ServiceCall call, PingReq request) async {
    // Pingは純粋な疎通確認用に戻します
    print('[SERVER] ping() called');
    final msg = request.msg;
    print('[gRPC Server] Ping received: $msg');

    return PingResp()..msg = 'pong: $msg';
  }

  // ★ 新規追加: 鍵交換専用RPCの実装
  @override
  Future<KeyExchangeResp> exchangeKeys(ServiceCall call, KeyExchangeReq request) async {
    print('[SERVER] exchangeKeys() called');

    // 1. クライアントから受信した鍵リスト (List<List<int>>)
    final clientKeys = request.keys;
    print('[gRPC Server] 🔑 Received ${clientKeys.length} keys from client');

    // ログ出力 (数が多い場合は最初の数件のみ表示するなど調整してください)
    for (var i = 0; i < clientKeys.length; i++) {
      // 全て出すと多い場合は if (i < 5) 等で制限
      print('[gRPC Server]   client key[$i]: ${_bytesToHex(clientKeys[i])}');
    }

    // 2. サーバ側の鍵を取得
    // KeyManagementServiceは Uint8List のリストを返すと想定
    final generated = await _keyService.getAllGeneratedPublicKeys();
    final collected = await _keyService.getAllCollectedPublicKeys();

    // 3. リストを結合
    // protobufの repeated bytes は Dartでは List<List<int>> にマッピングされます
    // Uint8List は List<int> を実装しているため、そのまま格納可能です
    final allServerKeys = <List<int>>[...generated, ...collected];

    print('[gRPC Server] 🔑 Sending ${allServerKeys.length} keys back to client');

    // ログ出力
    for (var i = 0; i < allServerKeys.length; i++) {
      print('[gRPC Server]   server key[$i]: ${_bytesToHex(allServerKeys[i])}');
    }

    // 4. レスポンスを返却
    return KeyExchangeResp()..keys.addAll(allServerKeys);
  }
}

class PsiGrpcServer {
  Server? _server;
  int? _port;

  bool get isRunning => _server != null;
  int? get port => _port;

  Future<int> start({int port = 50051}) async {
    if (_server != null) return _port!;

    final server = Server.create(
      services: [PsiServiceImpl()],
      interceptors: const <Interceptor>[],
      codecRegistry: CodecRegistry(
        codecs: [
          GzipCodec(),
          IdentityCodec(),
        ],
      ),
    );

    await server.serve(
      address: InternetAddress.anyIPv4,
      port: port,
    );

    _server = server;
    _port = server.port;

    print('[gRPC Server] started on 0.0.0.0:${_port}');
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