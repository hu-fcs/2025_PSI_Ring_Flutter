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
    print('[CLIENT] Initializing PSI client...');
    print('[CLIENT] PSI client initialization complete.');
  }

  Future<void> _ensureReady() async => await _ready;

  // --------------------------------------------------------------
  // gRPC Connection
  // --------------------------------------------------------------
  Future<void> connect(String host, int port) async {
    await _ensureReady();

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
      print('[CLIENT] ✅ Connected');
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
  //  ECC-PSI（双方向）
  // ================================================================
  Future<List<String>> executePsi() async {
    await _ensureReady();
    final stub = _stub;
    if (stub == null) throw StateError('Client not connected');

    print('\n[CLIENT] --- PSI Flow Start ---');

    // ------------------------------------------------------------
    // 1. BLE DB から鍵集合を取得
    // ------------------------------------------------------------
    final generated = await _kms.getAllGeneratedPublicKeys();
    final collected = await _kms.getAllCollectedPublicKeys();
    final myKeys = [...generated, ...collected];

    print('[CLIENT] Loaded ${myKeys.length} BLE keys.');

    if (myKeys.isEmpty) {
      print('[CLIENT] ⚠ No BLE keys found.');
      return [];
    }

    // ------------------------------------------------------------
    // 2. クライアント秘密 b 生成 → bQ
    // ------------------------------------------------------------
    final mySecret = _keyService.generateRandomSecret();
    final myEncKeys = _keyService.encryptSet(myKeys, mySecret);

    print('[CLIENT] Generated b and created bQ.');

    // ------------------------------------------------------------
    // 3. bQ を Server へ送信
    // ------------------------------------------------------------
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

    print('[CLIENT] Received: aP=${serverEncKeys.length}, abQ=${abQ.length}');

    // ------------------------------------------------------------
    // 4. Server → Client : aP を abP に変換
    // ------------------------------------------------------------
    final abP = _keyService.encryptSet(serverEncKeys, mySecret);
    print('[CLIENT] Converted aP -> abP.');

    // ------------------------------------------------------------
    // 5. Client 自身の共通集合（PSI結果）
    // ------------------------------------------------------------
    final clientCommon =
    _keyService.intersect(myKeys, abQ, abP);

    print('[CLIENT] 🎯 Client PSI result = ${clientCommon.length}');

    // ------------------------------------------------------------
    // 6. Server側も PSI を計算できるように abP を送信
    // ------------------------------------------------------------
    final finalReq = ClientFinalReq()
      ..clientReencServerKeys.addAll(abP);

    final finalResp = await stub.finalizePsi(
      finalReq,
      options: CallOptions(compression: const GzipCodec()),
    );

    final serverCommon =
    finalResp.commonKeys.map((e) => Uint8List.fromList(e)).toList();

    print('[CLIENT] 🎯 Server PSI result (received) = ${serverCommon.length}');

    // どちらも同じ集合のはずだが、クライアントは clientCommon を返却
    return clientCommon.map(_bytesToHex).toList();
  }

  String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
