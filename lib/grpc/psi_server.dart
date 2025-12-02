import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:grpc/grpc.dart';

import '../proto/generated/psi.pbgrpc.dart';
import '../key_management_service.dart';

class PsiServiceImpl extends PsiServiceBase {
  final KeyManagementService _keyService = KeyManagementService();

  String _bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  Future<PingResp> ping(ServiceCall call, PingReq request) async {
    print('[SERVER] ping() called');   // ★必須ログ
    final msg = request.msg;
    print('[gRPC Server] Ping received: $msg');

    try {
      final Map<String, dynamic> reqJson = jsonDecode(msg);

      if (reqJson['type'] == 'key_sync') {
        final List<dynamic> clientKeys = (reqJson['keys'] as List?) ?? const [];
        print('[gRPC Server] 🔑 Received ${clientKeys.length} keys from client');

        for (var i = 0; i < clientKeys.length; i++) {
          print('[gRPC Server]   client key[$i]: ${clientKeys[i]}');
        }

        // サーバ側の鍵を取得
        final generated = await _keyService.getAllGeneratedPublicKeys();
        final collected = await _keyService.getAllCollectedPublicKeys();
        final all = <Uint8List>[...generated, ...collected];

        final serverKeys = all.map(_bytesToHex).toList();
        print('[gRPC Server] 🔑 Sending ${serverKeys.length} keys back to client');

        for (var i = 0; i < serverKeys.length; i++) {
          print('[gRPC Server]   server key[$i]: ${serverKeys[i]}');
        }

        final respJson = jsonEncode({
          'type': 'key_sync_resp',
          'keys': serverKeys,
        });

        return PingResp()..msg = respJson;
      }
    } catch (e) {
      print('[gRPC Server] JSON decode error: $e');
    }

    return PingResp()..msg = 'pong: $msg';
  }
}

class PsiGrpcServer {
  Server? _server;
  int? _port;

  bool get isRunning => _server != null;
  int? get port => _port;

  Future<int> start({int port = 50051}) async {
    if (_server != null) return _port!;

    final server = Server(
      [PsiServiceImpl()],
      const <Interceptor>[],
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
