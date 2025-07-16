import 'dart:convert';
import 'dart:ffi'; // ★ FFI関連の型（Pointerなど）のために追加
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart'; // ★ FFI関連のヘルパー（callocなど）のために追加
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:grpc/grpc.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:convert/convert.dart' as convert; // ★ hexエンコードのために追加（名前衝突を避ける）

import '../generated/hello.pbgrpc.dart';
import '../boringssl_service.dart';
import '../key_management_service.dart';
import '../native_key_service.dart';

class ExchangePage extends StatefulWidget {
  const ExchangePage({super.key});

  @override
  State<ExchangePage> createState() => _ExchangePageState();
}

class _ExchangePageState extends State<ExchangePage> {
  bool isExchanging = false;
  bool isServerRunning = false;
  bool isClientConnected = false;
  String? serverIp;
  final int serverPort = 50051;
  String? connectedInfo;
  String displayName = '';
  String? latestClientName;
  Server? grpcServer;
  String? _boringSSLVersion;

  // サービスへの参照をインスタンス変数として保持
  final KeyManagementService _keyManagementService = KeyManagementService();
  final NativeKeyService _nativeKeyService = NativeKeyService();

  final List<String> adjectives = [
    'Blue', 'Silent', 'Swift', 'Bright', 'Lucky', 'Misty', 'Fierce', 'Brave'
  ];
  final List<String> nouns = [
    'Tiger', 'River', 'Falcon', 'Shadow', 'Mountain', 'Wind', 'Ocean', 'Flame'
  ];

  @override
  void initState() {
    super.initState();
    generateDisplayName();
    fetchLocalIp();
  }

  void checkBoringSSL() {
    if (Platform.isAndroid) {
      try {
        final service = BoringSSLService();
        setState(() {
          _boringSSLVersion = service.testRandomBytes();
        });
      } catch (e) {
        setState(() {
          _boringSSLVersion = 'エラー: ライブラリの読み込みに失敗しました。 $e';
        });
      }
    } else {
      setState(() {
        _boringSSLVersion = 'Android以外のプラットフォームでは確認しません。';
      });
    }
  }

  void generateDisplayName() {
    final random = Random();
    setState(() {
      displayName = '${adjectives[random.nextInt(adjectives.length)]}${nouns[random.nextInt(nouns.length)]}';
    });
  }

  Future<void> fetchLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.')) {
            setState(() {
              serverIp = ip;
            });
            return;
          }
        }
      }
      setState(() {
        serverIp = null;
      });
    } catch (e) {
      setState(() {
        serverIp = null;
      });
    }
  }

  Future<void> startGrpcServer() async {
    if (grpcServer != null) return;
    grpcServer = Server.create(
      services: [
        HelloServiceImpl(displayName, (clientName) {
          setState(() {
            latestClientName = clientName;
          });
        })
      ],
      codecRegistry: CodecRegistry(codecs: const [GzipCodec(), IdentityCodec()]),
      interceptors: const <Interceptor>[],
    );
    await grpcServer!.serve(port: serverPort, address: '0.0.0.0');
    setState(() {
      isServerRunning = true;
    });
  }

  Future<void> stopGrpcServer() async {
    if (grpcServer != null) {
      await grpcServer!.shutdown();
      grpcServer = null;
    }
    setState(() {
      isServerRunning = false;
      latestClientName = null;
    });
  }

  void toggleExchange(bool value) async {
    setState(() {
      isExchanging = value;
    });
    if (value) {
      final pubkey = await _keyManagementService.getPublicKeyForAdvertise(
        validity: const Duration(minutes: 10),
      );
      if (pubkey != null) {
        print("📡 アドバタイズ予定公開鍵: ${base64.encode(pubkey)}");
      } else {
        print("🚨 アドバタイズ用の公開鍵が取得できませんでした。");
      }
    } else {
      print("🛑 Advertising stopped.");
    }
  }

  void startScan(BuildContext context) async {
    final result = await Navigator.pushNamed(context, '/scanner', arguments: {'displayName': displayName});
    if (result != null && result is String) {
      setState(() {
        connectedInfo = result;
        isClientConnected = true;
      });
    }
  }

  // --- リング署名関連のロジック ---

  /// リング署名を生成し、結果を表示する
  Future<void> _performRingSignature() async {
    // 1. 署名者自身の最新の鍵ペアを取得
    final signerKeyPair = await _keyManagementService.getLatestKeyPair();
    if (signerKeyPair == null) {
      _showErrorSnackbar('署名用の鍵ペアが見つかりませんでした。');
      return;
    }

    // 2. DBから収集済みの公開鍵をすべて取得
    final collectedKeys = await _keyManagementService.getAllCollectedPublicKeys();

    // 3. リングを構成（収集済み鍵 + 自身の公開鍵）
    final ringPublicKeys = <Uint8List>[...collectedKeys];
    // 自身の鍵がリストにない場合のみ追加する
    if (!ringPublicKeys.any((key) => listEquals(key, signerKeyPair.publicKey))) {
      ringPublicKeys.add(signerKeyPair.publicKey);
    }

    // リング署名には最低2つの鍵が必要
    if (ringPublicKeys.length < 2) {
      _showErrorSnackbar('リング署名には最低2つの鍵が必要です。収集済み鍵が足りません。');
      return;
    }

    // 4. FFI呼び出しの準備
    const message = 'This is a test message for ring signature';
    final ringSize = ringPublicKeys.length;

    // FFIのためにメモリを確保
    final msgPtr = message.toNativeUtf8().cast<Char>();
    final privKeyPtr = _uint8ListToPointer(signerKeyPair.privateKey);
    final ringKeysPtr = _listOfUint8ListToPointer(ringPublicKeys);
    // 署名の出力先バッファ: (c0 + s0 + s1 + ...) * 32バイト
    final signatureOutPtr = calloc<Uint8>((1 + ringSize) * 32);

    try {
      // 5. Cの関数を呼び出して署名を生成
      final result = _nativeKeyService.createRingSignature(
        msgPtr,
        message.length,
        privKeyPtr,
        ringKeysPtr,
        ringSize,
        signatureOutPtr,
      );

      // 6. 結果を処理
      if (result == 1) {
        final signatureBytes = signatureOutPtr.asTypedList((1 + ringSize) * 32);
        _showSignatureResultDialog(convert.hex.encode(signatureBytes));
      } else {
        _showErrorSnackbar('リング署名の作成に失敗しました。(ネイティブコードエラー)');
      }
    } finally {
      // 7. 確保したメモリを解放
      calloc.free(msgPtr);
      calloc.free(privKeyPtr);
      calloc.free(ringKeysPtr);
      calloc.free(signatureOutPtr);
    }
  }

  // FFIのためにUint8ListをCのポインタに変換するヘルパー
  Pointer<Uint8> _uint8ListToPointer(Uint8List list) {
    final ptr = calloc<Uint8>(list.length);
    ptr.asTypedList(list.length).setAll(0, list);
    return ptr;
  }

  // FFIのためにUint8ListのリストをCのポインタに変換するヘルパー
  Pointer<Uint8> _listOfUint8ListToPointer(List<Uint8List> lists) {
    if (lists.isEmpty) return nullptr;
    final totalLength = lists.fold<int>(0, (sum, list) => sum + list.length);
    final ptr = calloc<Uint8>(totalLength);
    final bytes = ptr.asTypedList(totalLength);
    int offset = 0;
    for (final list in lists) {
      bytes.setRange(offset, offset + list.length, list);
      offset += list.length;
    }
    return ptr;
  }

  // エラーメッセージを画面下部に表示
  void _showErrorSnackbar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  // 署名結果をダイアログで表示
  void _showSignatureResultDialog(String signatureHex) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('リング署名 結果'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('署名が正常に作成されました。'),
                const SizedBox(height: 16),
                SelectableText(
                  signatureHex,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('OK'),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      },
    );
  }


  @override
  void dispose() {
    grpcServer?.shutdown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final grpcInfoJson = serverIp != null ? jsonEncode({'ip': serverIp, 'port': serverPort}) : '';

    return Scaffold(
      appBar: AppBar(
        title: const Text('鍵交換画面'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bug_report),
            tooltip: 'デバッグへ',
            onPressed: () => Navigator.pushNamed(context, '/debug'),
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: checkBoringSSL,
                child: const Text('BoringSSLのRAND_bytesをテスト'),
              ),
              const SizedBox(height: 20),
              if (_boringSSLVersion != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12.0),
                  decoration: BoxDecoration(
                    color: Colors.green.shade100,
                    borderRadius: BorderRadius.circular(8.0),
                    border: Border.all(color: Colors.green.shade300),
                  ),
                  child: Text(
                    'テスト結果: $_boringSSLVersion',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.green.shade800,
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              Text('仮名：$displayName', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              SwitchListTile(
                title: const Text('アドバタイズ'),
                subtitle: Text(isExchanging ? 'アドバタイズ中' : '停止中'),
                value: isExchanging,
                onChanged: toggleExchange,
                secondary: Icon(Icons.bluetooth, color: isExchanging ? Colors.blue : Colors.grey),
              ),
              SwitchListTile(
                title: const Text('gRPCサーバ'),
                subtitle: Text(isServerRunning ? '起動中' : '停止中'),
                value: isServerRunning,
                onChanged: (value) async {
                  if (value) {
                    await startGrpcServer();
                  } else {
                    await stopGrpcServer();
                  }
                },
                secondary: Icon(Icons.wifi, color: isServerRunning ? Colors.green : Colors.grey),
              ),
              const SizedBox(height: 20),
              if (isServerRunning)
                serverIp != null
                    ? Column(
                  children: [
                    Center(
                      child: QrImageView(data: grpcInfoJson, version: QrVersions.auto, size: 200.0),
                    ),
                    const SizedBox(height: 10),
                    const Text('サーバ起動中！', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('IPアドレス: $serverIp'),
                    Text('ポート番号: $serverPort'),
                  ],
                )
                    : const Text('⚠️ IPアドレス取得失敗', style: TextStyle(color: Colors.red)),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: () => startScan(context),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('QRコードをスキャンして接続'),
              ),
              const SizedBox(height: 20),

              // --- ここに新しいボタンを追加 ---
              ElevatedButton.icon(
                onPressed: _performRingSignature,
                icon: const Icon(Icons.edit),
                label: const Text('リング署名を作成して表示'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                  foregroundColor: Colors.white,
                ),
              ),
              // --- 追加ここまで ---

              const SizedBox(height: 20),
              if (isClientConnected)
                Text('クライアント接続成功: $connectedInfo', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              if (latestClientName != null)
                Text('接続完了：Hello, $latestClientName', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            ],
          ),
        ),
      ),
    );
  }
}

// gRPC Service Implementation
class HelloServiceImpl extends HelloServiceBase {
  final String serverDisplayName;
  final void Function(String clientName) onClientConnected;
  HelloServiceImpl(this.serverDisplayName, this.onClientConnected);
  @override
  Future<HelloReply> sayHello(ServiceCall call, HelloRequest request) async {
    print('📥 クライアントから受信: ${request.name}');
    onClientConnected(request.name);
    return HelloReply()..message = 'Hello!, $serverDisplayName';
  }
}
