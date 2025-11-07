import 'dart:io';
import 'package:grpc/grpc.dart';

// 生成コード（lib/proto/generated）を相対インポート
import '../proto/generated/psi.pbgrpc.dart';

class PsiServiceImpl extends PsiServiceBase {
  @override
  Future<PingResp> ping(ServiceCall call, PingReq request) async {
    final msg = request.msg;
    // 疎通確認ログ
    // ignore: avoid_print
    print('[gRPC Server] Ping received: $msg');
    return PingResp()..msg = 'pong: $msg';
  }
}

class PsiGrpcServer {
  Server? _server;
  int? _port;

  bool get isRunning => _server != null;
  int? get port => _port;

  /// [port] に 0 を渡すと空きポートにバインドします（推奨: 指定ポートが被る可能性があるなら0）
  Future<int> start({int port = 50051}) async {
    if (_server != null) return _port!;
    final server = Server(
      [PsiServiceImpl()],
      const <Interceptor>[], // 監査や認証を入れる場合はここに
      CodecRegistry(codecs: const [GzipCodec(), IdentityCodec()]),
    );
    await server.serve(
      address: InternetAddress.anyIPv4, // LAN内からアクセス可能
      port: port,
    );
    _server = server;
    _port = server.port!;
    // ignore: avoid_print
    print('[gRPC Server] started on 0.0.0.0:${_port!}');
    return _port!;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _port = null;
    if (s != null) {
      await s.shutdown();
      // ignore: avoid_print
      print('[gRPC Server] stopped');
    }
  }
}
