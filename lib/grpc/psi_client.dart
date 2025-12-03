import 'dart:typed_data';
import 'package:grpc/grpc.dart';

import '../proto/generated/psi.pbgrpc.dart';

class PsiGrpcClient {
  ClientChannel? _channel;
  PsiServiceClient? _stub;

  bool get isConnected => _stub != null;

  // Hex文字列 -> List<int> (Bytes) 変換ヘルパー
  List<int> _hexToBytes(String hex) {
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  // List<int> (Bytes) -> Hex文字列 変換ヘルパー
  String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Future<void> connect(String host, int port) async {
    // 接続ログも統一感を出します
    print('[gRPC Client] Connecting to $host:$port ...');

    try {
      await disconnect();

      _channel = ClientChannel(
        host,
        port: port,
        options: ChannelOptions(
          credentials: ChannelCredentials.insecure(),
          idleTimeout: const Duration(seconds: 30),
          codecRegistry: CodecRegistry(
            codecs: [
              GzipCodec(),
              IdentityCodec(),
            ],
          ),
        ),
      );

      _stub = PsiServiceClient(_channel!);
      print('[gRPC Client] ✅ Connected success');
    } catch (e) {
      print('[gRPC Client] ❌ Connect ERROR: $e');
      rethrow;
    }
  }

  Future<String> ping(String msg) async {
    final stub = _stub;
    if (stub == null) throw StateError('Client not connected');

    try {
      final resp = await stub.ping(
        PingReq()..msg = msg,
        options: CallOptions(
          compression: const GzipCodec(),
        ),
      );
      return resp.msg;
    } catch (e) {
      print('[gRPC Client] Ping ERROR: $e');
      rethrow;
    }
  }

  // ★ サーバー側のログ形式に完全準拠
  Future<List<String>> exchangeKeys(List<String> myKeysHex) async {
    final stub = _stub;
    if (stub == null) throw StateError('Client not connected');

    // 1. 送信ログ（サーバーの受信ログと対になるように整形）
    print('[gRPC Client] 🔑 Sending ${myKeysHex.length} keys to server');
    for (var i = 0; i < myKeysHex.length; i++) {
      print('[gRPC Client]   client key[$i]: ${myKeysHex[i]}');
    }

    try {
      // 2. データ変換 & リクエスト作成
      final List<List<int>> myKeysBytes = myKeysHex.map(_hexToBytes).toList();
      final request = KeyExchangeReq()..keys.addAll(myKeysBytes);

      // 3. gRPC呼び出し
      final resp = await stub.exchangeKeys(
        request,
        options: CallOptions(
          compression: const GzipCodec(),
        ),
      );

      // 4. 受信ログ（サーバーの送信ログと対になるように整形）
      print('[gRPC Client] 🔑 Received ${resp.keys.length} keys from server');

      final List<String> serverKeysHex = [];
      for (var i = 0; i < resp.keys.length; i++) {
        final hexStr = _bytesToHex(resp.keys[i]);
        serverKeysHex.add(hexStr);
        print('[gRPC Client]   server key[$i]: $hexStr');
      }

      return serverKeysHex;

    } catch (e) {
      print('[gRPC Client] ❌ exchangeKeys ERROR: $e');
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