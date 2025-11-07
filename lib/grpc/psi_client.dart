import 'package:grpc/grpc.dart';

// 生成コード（lib/proto/generated）を相対インポート
import '../proto/generated/psi.pbgrpc.dart';

class PsiGrpcClient {
  ClientChannel? _channel;
  PsiServiceClient? _stub;

  bool get isConnected => _stub != null;

  Future<void> connect(String host, int port) async {
    await disconnect(); // 再接続時の後始末
    _channel = ClientChannel(
      host,
      port: port,
      options: const ChannelOptions(
        // ローカルLAN前提なのでまずは平文。後でTLSに変更可能
        credentials: ChannelCredentials.insecure(),
        idleTimeout: Duration(seconds: 30),
      ),
    );
    _stub = PsiServiceClient(_channel!);
  }

  Future<String> ping(String msg) async {
    final stub = _stub;
    if (stub == null) {
      throw StateError('Client not connected');
    }
    final resp = await stub.ping(PingReq()..msg = msg);
    return resp.msg;
  }

  Future<void> disconnect() async {
    try {
      await _channel?.shutdown();
    } finally {
      _channel = null;
      _stub = null;
    }
  }
}
