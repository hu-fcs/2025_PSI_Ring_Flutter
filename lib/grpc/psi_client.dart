import 'dart:typed_data';
import 'dart:math';
import 'package:grpc/grpc.dart';

import '../proto/generated/psi.pbgrpc.dart';
import '../native_key_service.dart';
import '../key_management_service.dart';

class PsiGrpcClient {
  ClientChannel? _channel;
  PsiServiceClient? _stub;

  // PSI暗号処理
  final NativeKeyService _keyService = NativeKeyService();

  // BLE鍵管理(DB)
  final KeyManagementService _kms = KeyManagementService();

  // ★ 初期化完了を保証する Future
  late final Future<void> _ready;

  bool get isConnected => _stub != null;

  PsiGrpcClient() {
    _ready = _initialize();
  }

  // ============================================================
  // 🔧 クライアント初期化
  //
  //  - NativeKeyService のロード完了を保証
  //  - BLEデータベースの準備ができたことを保証
  // ============================================================
  Future<void> _initialize() async {
    print('[CLIENT] Initializing PSI client...');

    // （必要ならここに KeyManagementService 側の初期化も追加可能）

    print('[CLIENT] PSI client initialization complete.');
  }

  // ★ RPC 実行前に初期化完了を保証
  Future<void> _ensureReady() async {
    await _ready;
  }

  // --------------------------------------------------------------
  //  gRPC 接続
  // --------------------------------------------------------------
  Future<void> connect(String host, int port) async {
    await _ensureReady();

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

  // ================================================================
  //  ECC-PSI 実行
  // ================================================================
  Future<List<String>> executePsi() async {
    await _ensureReady(); // ★ 初期化待ち

    final stub = _stub;
    if (stub == null) throw StateError('Client not connected');

    print('\n[CLIENT] --- PSI Flow Start ---');

    // ------------------------------------------------------------
    // 1. BLE データベースから鍵集合 Q を取得する
    // ------------------------------------------------------------
    final generated = await _kms.getAllGeneratedPublicKeys();
    final collected = await _kms.getAllCollectedPublicKeys();

    final myKeys = [...generated, ...collected];
    print('[CLIENT] Loaded ${myKeys.length} BLE keys for PSI.');

    if (myKeys.isEmpty) {
      print('[CLIENT] ⚠ WARNING: No BLE keys available.');
      return [];
    }

    // ------------------------------------------------------------
    // 2. 秘密スカラー b を生成 → bQ
    // ------------------------------------------------------------
    final mySecret = _keyService.generateRandomSecret();
    final myEncKeys = _keyService.encryptSet(myKeys, mySecret);

    print('[CLIENT] Encrypted my keys (bQ).');

    try {
      // ------------------------------------------------------------
      // 3. bQ をサーバへ送信
      // ------------------------------------------------------------
      print('[CLIENT] 📤 Sending ${myEncKeys.length} encrypted keys to server...');
      final request = KeyExchangeReq()..encKeys.addAll(myEncKeys);

      final resp = await stub.exchangeKeys(
        request,
        options: CallOptions(compression: const GzipCodec()),
      );

      // ------------------------------------------------------------
      // 4. aP, abQ を受信
      // ------------------------------------------------------------
      final serverEncKeys =
      resp.serverEncKeys.map((e) => Uint8List.fromList(e)).toList();

      final myReencKeys =
      resp.clientReencKeys.map((e) => Uint8List.fromList(e)).toList();

      print('[CLIENT] 📥 Received ${serverEncKeys.length} aP and ${myReencKeys.length} abQ.');

      // ------------------------------------------------------------
      // 5. aP → abP
      // ------------------------------------------------------------
      final serverReencKeys = _keyService.encryptSet(serverEncKeys, mySecret);

      print('[CLIENT] 🔒 Re-encrypted server keys (aP -> abP).');

      // ------------------------------------------------------------
      // 6. 共通集合の抽出
      // ------------------------------------------------------------
      final commonKeysBytes =
      _keyService.intersect(myKeys, myReencKeys, serverReencKeys);

      print('[CLIENT] ✅ PSI Complete. Found ${commonKeysBytes.length} common keys.');

      return commonKeysBytes.map(_bytesToHex).toList();

    } catch (e) {
      print('[CLIENT] ❌ PSI ERROR: $e');
      rethrow;
    }
  }

  // Hex変換（ログ用）
  String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
