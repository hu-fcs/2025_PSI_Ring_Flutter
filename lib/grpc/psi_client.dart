import 'dart:convert';
import 'package:grpc/grpc.dart';

import '../proto/generated/psi.pbgrpc.dart';

class PsiGrpcClient {
  ClientChannel? _channel;
  PsiServiceClient? _stub;

  bool get isConnected => _stub != null;

  Future<void> connect(String host, int port) async {
    print('[CLIENT] trying to connect to $host:$port');

    try {
      await disconnect();

      _channel = ClientChannel(
        host,
        port: port,
        options: ChannelOptions(
          credentials: ChannelCredentials.insecure(),
          idleTimeout: const Duration(seconds: 30),

          // ★ GzipCodec を登録（サーバーから gzip 受信できるようにする）
          codecRegistry: CodecRegistry(
            codecs: [
              GzipCodec(),
              IdentityCodec(),
            ],
          ),
        ),
      );

      _stub = PsiServiceClient(_channel!);
      print('[CLIENT] connect() success');
    } catch (e) {
      print('[CLIENT] connect() ERROR = $e');
      rethrow;
    }
  }

  Future<String> ping(String msg) async {
    final stub = _stub;
    if (stub == null) throw StateError('Client not connected');

    print('[CLIENT] sending ping payload: $msg');

    try {
      final resp = await stub.ping(
        PingReq()..msg = msg,

        // ★ 毎回 gzip で送信する
        options: CallOptions(
          compression: const GzipCodec(),
        ),
      );

      print('[CLIENT] got ping response: ${resp.msg}');
      return resp.msg;
    } catch (e) {
      print('[CLIENT] ping() ERROR = $e');
      rethrow;
    }
  }

  Future<List<String>> exchangeKeys(List<String> myKeysHex) async {
    if (_stub == null) throw StateError('Client not connected');

    final payload = jsonEncode({
      'type': 'key_sync',
      'keys': myKeysHex,
    });

    print('[CLIENT] exchangeKeys() sending ${myKeysHex.length} keys');

    try {
      final resp = await ping(payload);

      final json = jsonDecode(resp);
      if (json['type'] == 'key_sync_resp') {
        final list = (json['keys'] as List?) ?? const [];
        print('[CLIENT] received ${list.length} keys from server');
        return List<String>.from(list);
      }

      print('[CLIENT] unexpected response: $resp');
      return [resp];
    } catch (e) {
      print('[CLIENT] exchangeKeys ERROR = $e');
      rethrow;
    }
  }

  Future<void> disconnect() async {
    try {
      await _channel?.shutdown();
    } catch (_) {}
    _channel = null;
    _stub = null;
  }
}
