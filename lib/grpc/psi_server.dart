import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:grpc/grpc.dart';

import '../proto/generated/psi.pbgrpc.dart';
import '../native_key_service.dart'; // 統合されたサービスをimport

/// ECC-PSI プロトコルを実装する gRPC サービス
class PsiServiceImpl extends PsiServiceBase {
  // Cライブラリへのアクセスポイント（統合版サービス）
  final NativeKeyService _keyService = NativeKeyService();

  // サーバー側の鍵と秘密情報（メモリ上で保持）
  late List<Uint8List> _myKeys;     // 元の公開鍵リスト P (Server Keys)
  late Uint8List _mySecret;         // 秘密スカラー a (Secret Scalar)
  late List<Uint8List> _myEncKeys;  // 暗号化済み鍵リスト EncA = a * P

  PsiServiceImpl() {
    _initServerKeys();
  }

  /// サーバー起動時に鍵を生成・準備する
  void _initServerKeys() {
    print('[SERVER] Initializing Server Keys (ECC)...');

    // 1. 秘密スカラー 'a' の生成
    _mySecret = _keyService.generateRandomSecret();

    // 2. 公開鍵リスト 'P' の生成
    // デモ用に10個生成し、ランダムな位置に「本物の鍵」を配置する
    int realIdx = Random().nextInt(10);
    // メソッド名を generateKeysForPsi に変更 (NativeKeyServiceの実装に合わせる)
    _myKeys = _keyService.generateKeysForPsi(10, realIdx);

    print('[SERVER] Generated 10 keys. Real key at index $realIdx');
    // デバッグ用（先頭バイトのみ表示など簡略化しても良い）
    // print('[SERVER] Real Key (Hex): ${_bytesToHex(_myKeys[realIdx])}');

    // 3. 事前暗号化: EncA = a * P
    // クライアントが接続してきたらすぐに渡せるように準備しておく
    _myEncKeys = _keyService.encryptSet(_myKeys, _mySecret);

    print('[SERVER] Pre-encrypted keys with secret scalar "a". Ready to exchange.');
  }

  // デバッグログ用: バイト列をHex文字列に変換
  String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// 疎通確認用
  @override
  Future<PingResp> ping(ServiceCall call, PingReq request) async {
    print('[SERVER] ping received: ${request.msg}');
    return PingResp()..msg = 'pong: ${request.msg}';
  }

  /// 鍵交換 RPC (ECC-PSI)
  /// Clientから b*Q を受け取り、a*P と a*b*Q を返す
  @override
  Future<KeyExchangeResp> exchangeKeys(ServiceCall call, KeyExchangeReq request) async {
    print('\n[SERVER] === exchangeKeys() request received ===');

    // 1. クライアントから受信した暗号化鍵セット (EncB = b * Q)
    final clientEncKeys = request.encKeys;
    print('[SERVER] 📥 Received ${clientEncKeys.length} encrypted keys (bQ) from client.');

    // ProtobufのList<int>をUint8Listに変換
    final List<Uint8List> encB = clientEncKeys.map((e) => Uint8List.fromList(e)).toList();

    // 2. サーバー側で再暗号化: DoubleA = a * (b * Q) = abQ
    // 自分の秘密スカラー 'a' を掛ける
    final doubleA = _keyService.encryptSet(encB, _mySecret);
    print('[SERVER] 🔒 Re-encrypted client keys (bQ -> abQ) using secret "a".');

    // 3. レスポンスの作成
    // - serverEncKeys:   EncA (a * P) ... サーバーが自分の鍵を暗号化したもの
    // - clientReencKeys: DoubleA (abQ) ... クライアントの鍵をさらに暗号化したもの
    final resp = KeyExchangeResp()
      ..serverEncKeys.addAll(_myEncKeys)
      ..clientReencKeys.addAll(doubleA);

    print('[SERVER] 📤 Sending EncA (aP) and DoubleA (abQ) back to client.');
    print('[SERVER] === exchangeKeys() completed ===\n');

    return resp;
  }
}

/// gRPCサーバーの起動管理クラス
class PsiGrpcServer {
  Server? _server;
  int? _port;

  bool get isRunning => _server != null;
  int? get port => _port;

  /// サーバーを開始する
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

    print('[gRPC Server] listening on 0.0.0.0:${_port}');
    return _port!;
  }

  /// サーバーを停止する
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