import 'dart:convert';
import 'dart:io';

import '../ble/ble_exchange_controller.dart';
import 'package:flutter/material.dart';
// import 'package:grpc/grpc.dart'; // gRPC機能削除
import 'package:qr_flutter/qr_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
// import 'package:faker/faker.dart'; // 仮名機能削除

// import '../generated/hello.pbgrpc.dart'; // gRPC機能削除

class ExchangePage extends StatefulWidget {
  const ExchangePage({super.key});

  @override
  State<ExchangePage> createState() => _ExchangePageState();
}

class _ExchangePageState extends State<ExchangePage> {
  bool isExchanging = false;
  bool isServerRunning = false; // UI表示トグルとしてのみ使用
  String? serverIp;
  final int serverPort = 50051;
  // Server? grpcServer; // gRPC機能削除

  // --- 仮名関連の変数を削除 ---
  // String displayName = '';
  // String? latestClientName;
  // bool isClientConnected = false;
  // String? connectedInfo;

  @override
  void initState() {
    super.initState();
    // generateDisplayName(); // 仮名機能削除
    fetchLocalIp(); // QRコード表示用にIP取得は残す
  }

  // --- 仮名関連の関数を削除 ---
  // void generateDisplayName() { ... }

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

  // --- gRPCサーバーのロジックを削除し、UIのトグル機能だけ残す ---
  Future<void> startGrpcServer() async {
    // if (grpcServer != null) return;
    // ... (サーバー起動ロジック削除) ...
    print("gRPCサーバは現在無効化されています。(UI表示のみ)");
    setState(() {
      isServerRunning = true;
    });
  }

  Future<void> stopGrpcServer() async {
    // if (grpcServer != null) { ... }
    setState(() {
      isServerRunning = false;
      // latestClientName = null;
    });
  }

  final _bleExchange = BleExchangeController();
  void toggleExchange(bool value) async {
    setState(() {
      isExchanging = value;
    });

    if (!Platform.isAndroid) {
      print("⚠️ この機能は Android 専用です。");
      return;
    }

    try {
      if (value) {
        final ok = await _ensureBlePermissions();
        if (!ok) {
          print("🚨 必要な権限が許可されていません。設定から許可してください。");
          setState(() => isExchanging = false);
          return;
        }
        await _bleExchange.toggleExchange(); // start
      } else {
        await _bleExchange.toggleExchange(); // stop
        print("🛑 Advertising & scanning stopped.");
      }
    } catch (e) {
      print("❌ toggleExchange error: $e");
      setState(() => isExchanging = !value);
    }
  }

  // --- gRPCクライアントのロジックを削除 ---
  void startScan(BuildContext context) async {
    // スキャナ画面を呼び出すだけ (仮名引数と戻り値の処理を削除)
    await Navigator.pushNamed(context, '/scanner');
    // if (result != null && result is String) { ... }
  }

  @override
  void dispose() {
    // grpcServer?.shutdown(); // gRPC機能削除
    if (isExchanging) {
      _bleExchange.toggleExchange();
    }
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

              // --- 仮名表示を削除 ---
              // Row( ... displayName ... ),

              SwitchListTile(
                title: const Text('アドバタイズ'),
                subtitle: Text(isExchanging ? 'アドバタイズ中' : '停止中'),
                value: isExchanging,
                onChanged: toggleExchange,
                secondary: Icon(Icons.bluetooth, color: isExchanging ? Colors.blue : Colors.grey),
              ),
              SwitchListTile(
                title: const Text('gRPCサーバ (UIのみ)'), // UIのみであることを明記
                subtitle: Text(isServerRunning ? 'QRコード表示中' : '停止中'),
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
                    const Text('サーバ待受 (シミュレーション)', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('IPアドレス: $serverIp'),
                    Text('ポート番号: $serverPort'),
                  ],
                )
                    : const Text('⚠️ IPアドレス取得失敗', style: TextStyle(color: Colors.red)),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: () => startScan(context),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('QRコードをスキャン'), // 「して接続」を削除
              ),
              const SizedBox(height: 20),

              // --- 接続結果の表示UIを削除 ---
              // if (isClientConnected) ...
              // if (latestClientName != null) ...
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _ensureBlePermissions() async {
    if (!Platform.isAndroid) return false;

    final perms = <Permission>[
      Permission.bluetoothAdvertise,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ];

    final alreadyAllGranted = await Future.wait(perms.map((p) async => (await p.status).isGranted))
        .then((list) => list.every((v) => v));
    if (alreadyAllGranted) return true;

    final result = await perms.request();

    for (final p in [Permission.bluetoothAdvertise, Permission.bluetoothScan, Permission.bluetoothConnect]) {
      if (!(result[p]?.isGranted ?? false)) {
        return false;
      }
    }
    return true;
  }
}

// --- gRPCサーバー実装 (HelloServiceImpl) を削除 ---
// class HelloServiceImpl extends HelloServiceBase { ... }