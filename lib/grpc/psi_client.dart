import 'dart:typed_data';
import 'package:grpc/grpc.dart';

import '../proto/generated/psi.pbgrpc.dart';
import '../native_key_service.dart';
import '../key_management_service.dart';

class PsiGrpcClient {
  ClientChannel? _channel;
  PsiServiceClient? _stub;

  final NativeKeyService _keyService = NativeKeyService();
  final KeyManagementService _kms = KeyManagementService();

  late final Future<void> _ready;
  bool get isConnected => _stub != null;

  PsiGrpcClient() {
    _ready = _initialize();
  }

  Future<void> _initialize() async {
    print('[CLIENT] Initializing PSI Client...');
    print('[CLIENT] PSI Client initialization complete.');
  }

  Future<void> _ensureReady() async => await _ready;

  // -------------------------------------------------------------------
  // gRPC Connection
  // -------------------------------------------------------------------
  Future<void> connect(String host, int port) async {
    await _ensureReady();

    print('\n[CLIENT] === connect() called ===');
    print('[CLIENT] Connecting to $host:$port ...');

    try {
      await disconnect();

      _channel = ClientChannel(
        host,
        port: port,
        options: const ChannelOptions(
          credentials: ChannelCredentials.insecure(),
          idleTimeout: Duration(seconds: 30),
        ),
      );
      _stub = PsiServiceClient(_channel!);

      print('[CLIENT] ✅ Connected to server.');
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

  // ================================================================
  //                     ECC-PSI（双方向対応）
  // ================================================================
  Future<List<String>> executePsi() async {
    await _ensureReady();
    final stub = _stub;
    if (stub == null) throw StateError('[CLIENT] Not connected.');

    print('\n[CLIENT] === PSI Flow Start ===');

    // -------------------------------------------------------------------
    // 1. BLE DB から鍵集合を取得
    // -------------------------------------------------------------------
    final generated = await _kms.getAllGeneratedPublicKeys();
    final collected = await _kms.getAllCollectedPublicKeys();

    final myKeys = [...generated, ...collected];
    print('[CLIENT] 📦 Loaded ${myKeys.length} BLE keys.');

    if (myKeys.isEmpty) {
      print('[CLIENT] ⚠ No BLE keys found — PSI aborted.');
      return [];
    }

    // -------------------------------------------------------------------
    // 2. クライアント秘密 b 生成 → bQ
    // -------------------------------------------------------------------
    print('[CLIENT] 🔒 Generating client secret "b"...');
    final mySecret = _keyService.generateRandomSecret();
    final myEncKeys = _keyService.encryptSet(myKeys, mySecret);

    print('[CLIENT] 🔑 Created encrypted keys bQ (${myEncKeys.length}).');

    // -------------------------------------------------------------------
    // 3. bQ を Server へ送信
    // -------------------------------------------------------------------
    print('[CLIENT] 📤 Sending bQ to server...');
    final req = KeyExchangeReq()..encKeys.addAll(myEncKeys);

    final resp = await stub.exchangeKeys(
      req,
      options: CallOptions(compression: const GzipCodec()),
    );

    // aP
    final serverEncKeys =
    resp.serverEncKeys.map((e) => Uint8List.fromList(e)).toList();

    // abQ
    final abQ =
    resp.clientReencKeys.map((e) => Uint8List.fromList(e)).toList();

    print('[CLIENT] 📥 Received aP=${serverEncKeys.length}, abQ=${abQ.length}.');

    // -------------------------------------------------------------------
    // 4. aP → abP へ再暗号化
    // -------------------------------------------------------------------
    print('[CLIENT] 🔒 Computing abP = b(aP)...');
    final abP = _keyService.encryptSet(serverEncKeys, mySecret);

    print('[CLIENT] 🔄 Converted aP → abP.');

    // -------------------------------------------------------------------
    // 5. Client 側での PSI（共通集合の抽出）
    // -------------------------------------------------------------------
    print('[CLIENT] 🎯 Extracting PSI intersection (client-side)...');
    final clientCommon = _keyService.intersect(myKeys, abQ, abP);

    print('[CLIENT] 🎯 PSI intersection (client) = ${clientCommon.length} items.');

    if (clientCommon.isNotEmpty) {
      print('[CLIENT] 💍 [Client-side Intersection Results]');
      for (int i = 0; i < clientCommon.length; i++) {
        print('[CLIENT]   common key[$i]: ${_bytesToHex(clientCommon[i])}');
      }
    }

    // -------------------------------------------------------------------
    // 6. Server にも同じ PSI 結果を得させるため abP を送る
    // -------------------------------------------------------------------
    print('[CLIENT] 📤 Sending abP to server for finalizePsi()...');
    final finalReq = ClientFinalReq()
      ..clientReencServerKeys.addAll(abP);

    final finalResp = await stub.finalizePsi(
      finalReq,
      options: CallOptions(compression: const GzipCodec()),
    );

    final serverCommon =
    finalResp.commonKeys.map((e) => Uint8List.fromList(e)).toList();

    print('[CLIENT] 🎯 PSI intersection (server-side) = ${serverCommon.length} items.');

    if (serverCommon.isNotEmpty) {
      print('[CLIENT] 💍 [Server-side Intersection Results]');
      for (int i = 0; i < serverCommon.length; i++) {
        print('[CLIENT]   server common key[$i]: ${_bytesToHex(serverCommon[i])}');
      }
    }

    print('[CLIENT] === PSI Flow Complete ===\n');

    // ★ クライアントの集合を返す（Server と一致しているはず）
    return clientCommon.map(_bytesToHex).toList();
  }

  String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
