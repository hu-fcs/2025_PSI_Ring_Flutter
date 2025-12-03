import 'dart:typed_data';
import 'package:grpc/grpc.dart';

import '../proto/generated/psi.pbgrpc.dart';
import '../native_key_service.dart'; // 統合されたサービスをimport

class PsiGrpcClient {
  ClientChannel? _channel;
  PsiServiceClient? _stub;

  // Cライブラリへのアクセスポイント（統合版サービス）
  final NativeKeyService _keyService = NativeKeyService();

  bool get isConnected => _stub != null;

  // Hex文字列 -> List<int> 変換
  Uint8List _hexToBytes(String hex) {
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  // List<int> -> Hex文字列 変換
  String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Future<void> connect(String host, int port) async {
    print('[CLIENT] Connecting to $host:$port ...');
    try {
      await disconnect();
      _channel = ClientChannel(
        host,
        port: port,
        options: ChannelOptions(
          credentials: ChannelCredentials.insecure(),
          idleTimeout: const Duration(seconds: 30),
          codecRegistry: CodecRegistry(codecs: [GzipCodec(), IdentityCodec()]),
        ),
      );
      _stub = PsiServiceClient(_channel!);
      print('[CLIENT] ✅ Connected success');
    } catch (e) {
      print('[CLIENT] ❌ Connect ERROR: $e');
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

  /// 鍵交換を行い、共通する鍵のリストを返す
  /// [myKeysHex]: 自分の持っている公開鍵のHex文字列リスト
  /// Returns: 共通集合に含まれる鍵のHex文字列リスト
  Future<List<String>> exchangeKeys(List<String> myKeysHex) async {
    final stub = _stub;
    if (stub == null) throw StateError('Client not connected');

    print('\n[CLIENT] --- PSI Flow Start ---');
    print('[CLIENT] My Keys Count: ${myKeysHex.length}');

    // 1. 準備 (鍵変換 & 秘密鍵生成)
    final mySecret = _keyService.generateRandomSecret();
    final List<Uint8List> myKeys = myKeysHex.map(_hexToBytes).toList();

    // 2. 暗号化 (Q -> bQ)
    // 自分の鍵リストを自分の秘密鍵で暗号化
    final myEncKeys = _keyService.encryptSet(myKeys, mySecret);
    print('[CLIENT] Encrypted my keys (bQ).');

    try {
      // 3. 通信 (Request: bQ)
      print('[CLIENT] 📤 Sending ${myEncKeys.length} encrypted keys to server...');

      final request = KeyExchangeReq()..encKeys.addAll(myEncKeys);

      final resp = await stub.exchangeKeys(
        request,
        options: CallOptions(compression: const GzipCodec()),
      );

      // Response: EncA(aP) と DoubleA(abQ)
      final serverEncKeys = resp.serverEncKeys.map((e) => Uint8List.fromList(e)).toList();
      final myReencKeys = resp.clientReencKeys.map((e) => Uint8List.fromList(e)).toList();

      print('[CLIENT] 📥 Received ${serverEncKeys.length} server keys (aP) and re-encrypted keys (abQ).');

      // 4. 再暗号化 (aP -> abP)
      // サーバーの暗号化鍵(aP)を受け取り、さらに自分の秘密鍵(b)で暗号化
      final serverReencKeys = _keyService.encryptSet(serverEncKeys, mySecret);
      print('[CLIENT] 🔒 Re-encrypted server keys (aP -> abP).');

      // 5. 共通集合の判定 (Intersection)
      // - originalKeys: myKeys (Q) -> 結果として欲しい元の鍵
      // - myDoubleSet: myReencKeys (abQ) -> サーバー経由で戻ってきた自分の二重暗号化鍵
      // - remoteDoubleSet: serverReencKeys (abP) -> 自分で計算した相手の二重暗号化鍵
      //
      // 論理: abQ と abP が一致すれば、それは共通の鍵である
      final commonKeysBytes = _keyService.intersect(myKeys, myReencKeys, serverReencKeys);

      print('[CLIENT] ✅ PSI Complete. Found ${commonKeysBytes.length} common keys.');

      // Hex文字列に戻して返す
      final commonKeysHex = commonKeysBytes.map(_bytesToHex).toList();
      return commonKeysHex;

    } catch (e) {
      print('[CLIENT] ❌ exchangeKeys ERROR: $e');
      rethrow;
    }
  }
}