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
  // アドバタイズ中かどうか
  bool isExchanging = false;
  // gRPCサーバ起動中かどうか
  bool isServerRunning = false;
  // クライアント接続済みかどうか
  bool isClientConnected = false;

  // サーバのIPアドレス（Wi-Fiに接続しているIPアドレスを取得）
  String? serverIp;
  // サーバのポート番号
  final int serverPort = 50051;
  // クライアントから受け取ったメッセージ
  String? connectedInfo;
  // 自分自身の仮名
  String displayName = '';
  // クライアントから受け取った仮名
  String? latestClientName;

  // gRPCサーバインスタンス
  Server? grpcServer;

  // 仮名生成用単語リスト
  final List<String> adjectives = [
    'Blue', 'Silent', 'Swift', 'Bright', 'Lucky', 'Misty', 'Fierce', 'Brave'
  ];
  final List<String> nouns = [
    'Tiger', 'River', 'Falcon', 'Shadow', 'Mountain', 'Wind', 'Ocean', 'Flame'
  ];

  @override
  void initState() {
    super.initState();
    generateDisplayName();  // 仮名をランダム生成
    fetchLocalIp();         // 現在のWi-Fi IPアドレスを取得
  }

  // 仮名をランダム生成する
  void generateDisplayName() {
    final random = Random();
    setState(() {
      displayName = '${adjectives[random.nextInt(adjectives.length)]}${nouns[random.nextInt(nouns.length)]}';
    });
  }

  // 現在のWi-Fi IPv4アドレスを取得（192.168.x.x や 10.x.x.x に限定）
  Future<void> fetchLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          final ip = addr.address;
          // Wi-Fiの可能性が高いローカルIPを優先
          if (ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.')) {
            setState(() {
              serverIp = ip;
            });
            return;
          }
        }
      }
      // 該当アドレスがなければnull
      setState(() {
        serverIp = null;
      });
    } catch (e) {
      setState(() {
        serverIp = null;
      });
    }
  }

  // gRPCサーバを起動する
  Future<void> startGrpcServer() async {
    if (grpcServer != null) return;

    grpcServer = Server.create(
      services: [
        // サーバ自身の仮名と、クライアント接続時のコールバックを渡す
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
      address: '0.0.0.0', // すべてのネットワークインターフェースから受け付ける
    );

    setState(() {
      isServerRunning = true;
    });
  }

  // gRPCサーバを停止する
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

  // アドバタイズ切り替え
  void toggleExchange(bool value) {
    setState(() {
      isExchanging = value;
    });
  }

  // QRコードスキャンへ遷移
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

  // ページ終了時にgRPCサーバをシャットダウン
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
            // 自分の仮名表示
            Text('仮名：$displayName', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),

            // アドバタイズ切替
            SwitchListTile(
              title: const Text('アドバタイズ'),
              subtitle: Text(isExchanging ? 'アドバタイズ中' : '停止中'),
              value: isExchanging,
              onChanged: toggleExchange,
              secondary: Icon(Icons.bluetooth, color: isExchanging ? Colors.blue : Colors.grey),
            ),

            // gRPCサーバ切替
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

            // サーバが起動しているときのみQR表示
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

            // QRコードスキャンボタン
            ElevatedButton.icon(
              onPressed: () => startScan(context),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('QRコードをスキャンして接続'),
            ),
            const SizedBox(height: 20),

            // クライアントから接続されたときの表示
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

// gRPCサービスの実装クラス
class HelloServiceImpl extends HelloServiceBase {
  final String serverDisplayName;
  final void Function(String clientName) onClientConnected;

  HelloServiceImpl(this.serverDisplayName, this.onClientConnected);

  // クライアントからのsayHelloリクエストを処理する
  @override
  Future<HelloReply> sayHello(ServiceCall call, HelloRequest request) async {
    print('📥 クライアントから受信: ${request.name}');
    onClientConnected(request.name);
    return HelloReply()..message = 'Hello!, $serverDisplayName';
  }
}
