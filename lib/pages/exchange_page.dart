import 'dart:convert';
import 'dart:io';

import '../ble/ble_exchange_controller.dart';
import 'package:flutter/material.dart';
import 'package:grpc/grpc.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:faker/faker.dart';

import '../generated/hello.pbgrpc.dart';
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

  @override
  void initState() {
    super.initState();
    generateDisplayName();
    fetchLocalIp();
  }

  // ★★★ 20文字以内の名前ができるまで再生成するロジックを追加 ★★★
  void generateDisplayName() {
    final faker = Faker();
    String newName;

    do {
      // 1. ランダムな「色」と「動物」を生成
      String color = faker.color.commonColor();
      final String animal = faker.animal.name();

      // 2. 色の頭文字を大文字に変換
      if (color.isNotEmpty) {
        color = '${color[0].toUpperCase()}${color.substring(1)}';
      }

      // 3. 組み合わせて仮の名前を作成
      newName = '$color${animal.replaceAll(' ', '')}';

    } while (newName.length > 20); // 4. 文字数が20文字を超えていたらループ

    // 5. 条件に合う名前が確定したらstateを更新
    setState(() {
      displayName = newName;
    });
  }

  Future<void> fetchLocalIp() async {
    try {
      final interfaces =
      await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
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

  final _bleExchange = BleExchangeController();
  void toggleExchange(bool value) async {
    setState(() {
      isExchanging = value;
    });

    // Android 専用（iOS は広告非対応運用）
    if (!Platform.isAndroid) {
      print("⚠️ この機能は Android 専用です。");
      return;
    }

    try {
      if (value) {
        // ON: 権限チェック → OK なら広告＋スキャン開始
        final ok = await _ensureBlePermissions();
        if (!ok) {
          print("🚨 必要な権限が許可されていません。設定から許可してください。");
          setState(() => isExchanging = false);
          return;
        }

        await _bleExchange.toggleExchange(); // start

        // （既存ロギングは維持）
        // final keyManager = KeyManagementService();
        // final pubkey = await keyManager.getPublicKeyForAdvertise(
        //   validity: const Duration(minutes: 10),
        // );
        // if (pubkey != null) {
        //   print("📡 アドバタイズ予定公開鍵: ${pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}");
        // } else {
        //   print("🚨 アドバタイズ用の公開鍵が取得できませんでした。");
        // }
      } else {
        // OFF: 広告＋スキャン停止
        await _bleExchange.toggleExchange(); // stop
        print("🛑 Advertising & scanning stopped.");
      }
    } catch (e) {
      print("❌ toggleExchange error: $e");
      // 失敗時はUI状態を戻す
      setState(() => isExchanging = !value);
    }
  }


  void startScan(BuildContext context) async {
    final result =
    await Navigator.pushNamed(context, '/scanner', arguments: {'displayName': displayName});
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
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text('仮名：$displayName', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: '新しい仮名を生成',
                    onPressed: generateDisplayName,
                  ),
                ],
              ),
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
                      child:
                      QrImageView(data: grpcInfoJson, version: QrVersions.auto, size: 200.0),
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
                Text('クライアント接続成功: $connectedInfo',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              if (latestClientName != null)
                Text('接続完了：Hello, $latestClientName',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _ensureBlePermissions() async {
    if (!Platform.isAndroid) return false;

    // Android 12+ 個別権限 + Android 10–11向け位置情報
    final perms = <Permission>[
      Permission.bluetoothAdvertise,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ];

    // 既に全部OKならそのまま
    final alreadyAllGranted = await Future.wait(perms.map((p) async => (await p.status).isGranted))
        .then((list) => list.every((v) => v));
    if (alreadyAllGranted) return true;

    // まとめて要求
    final result = await perms.request();

    // 少なくとも BLE の3権限が許可されているか確認
    for (final p in [Permission.bluetoothAdvertise, Permission.bluetoothScan, Permission.bluetoothConnect]) {
      if (!(result[p]?.isGranted ?? false)) {
        return false;
      }
    }
    return true;
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