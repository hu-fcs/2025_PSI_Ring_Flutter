import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:grpc/grpc.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../generated/hello.pbgrpc.dart';
import '../boringssl_service.dart';
import '../key_management_service.dart';

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

  // This method is corrected to handle nulls.
  void toggleExchange(bool value) async {
    setState(() {
      isExchanging = value;
    });
    if (value) {
      final keyManager = KeyManagementService();
      final pubkey = await keyManager.prepareCurrentPublicKeyForAdvertise();

      // Check if the public key is not null before using it.
      if (pubkey != null) {
        print("📡 アドバタイズ予定公開鍵: ${base64.encode(pubkey)}");
        // TODO: Implement actual BLE advertising with the public key here.
      } else {
        print("🚨 アドバタイズ用の公開鍵が取得できませんでした。");
      }
    } else {
      // TODO: Stop BLE advertising here.
      print("🛑 Advertising stopped.");
    }
  }

  void startScan(BuildContext context) async {
    // Assuming '/scanner' route exists and handles QR code scanning.
    final result = await Navigator.pushNamed(context, '/scanner', arguments: {'displayName': displayName});
    if (result != null && result is String) {
      setState(() {
        connectedInfo = result;
        isClientConnected = true;
      });
    }
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
