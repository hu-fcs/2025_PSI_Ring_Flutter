// lib/grpc/grpc_client.dart
import 'dart:typed_data';
import 'package:grpc/grpc.dart';

import '../proto/generated/psi.pbgrpc.dart';
import '../ffi/native_key_service.dart';
import '../key_management_service.dart';

/// ===============================================================
/// PSI の結果（共通集合 + 顔見知り判定）
/// ===============================================================
class PsiResult {
  /// 共通集合（HEX 表記）
  final List<String> commonKeys;

  /// 共通集合の中に「自分が生成した鍵」が含まれているか
  final bool isFamiliar;

  PsiResult({
    required this.commonKeys,
    required this.isFamiliar,
  });
}

/// ===============================================================
///                     ECC-PSI クライアント
/// ===============================================================
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
  Future<PsiResult> executePsi() async {
    await _ensureReady();
    final stub = _stub;
    if (stub == null) throw StateError('[CLIENT] Not connected.');

    print('\n[CLIENT] === PSI Flow Start ===');

    // ------------------------------------------------------------
    // 1. BLE DB から鍵集合を取得
    // ------------------------------------------------------------
    final generated = await _kms.getAllGeneratedPublicKeys();
    final collected = await _kms.getAllCollectedPublicKeys();

    final myKeys = [...generated, ...collected];
    print('[CLIENT] 📦 Loaded ${myKeys.length} BLE keys.');

    if (myKeys.isEmpty) {
      print('[CLIENT] ⚠ No BLE keys found — PSI aborted.');
      return PsiResult(commonKeys: [], isFamiliar: false);
    }

    // ------------------------------------------------------------
    // 2. 秘密スカラー b → bQ
    // ------------------------------------------------------------
    print('[CLIENT] 🔒 Generating client secret "b"...');
    final mySecret = _keyService.generateRandomSecret();
    final myEncKeys = _keyService.encryptSet(myKeys, mySecret);
    print('[CLIENT] 🔑 Created encrypted keys bQ (${myEncKeys.length}).');

    // ------------------------------------------------------------
    // 3. bQ → server へ送信
    // ------------------------------------------------------------
    print('[CLIENT] 📤 Sending bQ to server...');
    final req = KeyExchangeReq()..encKeys.addAll(myEncKeys);

    final resp = await stub.exchangeKeys(
      req,
      options: CallOptions(compression: const GzipCodec()),
    );

    final serverEncKeys =
    resp.serverEncKeys.map((e) => Uint8List.fromList(e)).toList();

    final abQ =
    resp.clientReencKeys.map((e) => Uint8List.fromList(e)).toList();

    print('[CLIENT] 📥 Received aP=${serverEncKeys.length}, abQ=${abQ.length}.');

    // ------------------------------------------------------------
    // 4. aP → abP
    // ------------------------------------------------------------
    print('[CLIENT] 🔒 Computing abP = b(aP)...');
    final abP = _keyService.encryptSet(serverEncKeys, mySecret);
    print('[CLIENT] 🔄 Converted aP → abP.');

    // ------------------------------------------------------------
    // 5. Client 側 PSI（共通集合）
    // ------------------------------------------------------------
    print('[CLIENT] 🎯 Extracting PSI intersection (client-side)...');
    final clientCommon = _keyService.intersect(myKeys, abQ, abP);

    print('[CLIENT] 🎯 PSI intersection = ${clientCommon.length} items.');
    for (int i = 0; i < clientCommon.length; i++) {
      print('[CLIENT]   common[$i]: ${_bytesToHex(clientCommon[i])}');
    }

    // ------------------------------------------------------------
    // 6. abP をサーバへ送信（結果は返ってこない）
    // ------------------------------------------------------------
    print('[CLIENT] 📤 Sending abP to server (FinalizePsi)...');
    final finalReq = ClientFinalReq()
      ..clientReencServerKeys.addAll(abP);

    await stub.finalizePsi(
      finalReq,
      options: CallOptions(compression: const GzipCodec()),
    );

    print('[CLIENT] 🔚 finalizePsi completed.');
    print('[CLIENT] === PSI Flow Complete ===\n');

    // ------------------------------------------------------------
    // 7. 顔見知り判定（自分が生成した鍵を持っているか）
    // ------------------------------------------------------------
    final commonHex = clientCommon.map(_bytesToHex).toList();

    final myGeneratedHex = generated.map(_bytesToHex).toSet();
    final familiar =
        commonHex.toSet().intersection(myGeneratedHex).isNotEmpty;

    return PsiResult(
      commonKeys: commonHex,
      isFamiliar: familiar,
    );
  }

  // HEX 変換
  String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
