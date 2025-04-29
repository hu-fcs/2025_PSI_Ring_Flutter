import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:grpc/grpc.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../generated/hello.pbgrpc.dart';

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

  void generateDisplayName() {
    final random = Random();
    setState(() {
      displayName = '${adjectives[random.nextInt(adjectives.length)]}${nouns[random.nextInt(nouns.length)]}';
    });
  }

  Future<void> fetchLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            setState(() {
              serverIp = addr.address;
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

    await grpcServer!.serve(
      port: serverPort,
      address: '0.0.0.0',
    );

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

  void toggleExchange(bool value) {
    setState(() {
      isExchanging = value;
    });
  }

  void startScan(BuildContext context) async {
    final result = await Navigator.pushNamed(
      context,
      '/scanner',
      arguments: {'displayName': displayName},
    );

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
    final grpcInfoJson = serverIp != null
        ? jsonEncode({
      'ip': serverIp,
      'port': serverPort,
    })
        : '';

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
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
                    child: QrImageView(
                      data: grpcInfoJson,
                      version: QrVersions.auto,
                      size: 200.0,
                    ),
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
    );
  }
}

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