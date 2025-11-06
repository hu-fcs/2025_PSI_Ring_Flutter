import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
// import 'package:grpc/grpc.dart'; // gRPC機能削除
// import '../generated/hello.pbgrpc.dart'; // gRPC機能削除

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  bool isConnecting = false;
  bool isManualInputMode = false;

  final TextEditingController ipController = TextEditingController();
  final TextEditingController portController = TextEditingController();

  String? ipToConnect;
  int? portToConnect;

  @override
  Widget build(BuildContext context) {
    // --- 仮名機能削除 ---
    // final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    // final String displayName = args?['displayName'] ?? 'UnknownName';

    return Scaffold(
      appBar: AppBar(title: const Text('サーバをスキャン')), // 「に接続する」を削除
      body: Stack(
        children: [
          if (!isManualInputMode)
            MobileScanner(
              onDetect: (BarcodeCapture capture) async {
                if (isConnecting || ipToConnect != null) return;

                final List<Barcode> barcodes = capture.barcodes;
                if (barcodes.isNotEmpty) {
                  final String? code = barcodes.first.rawValue;
                  if (code != null) {
                    try {
                      final Map<String, dynamic> grpcInfo = jsonDecode(code);
                      final String ip = grpcInfo['ip'];
                      final int port = grpcInfo['port'];

                      setState(() {
                        ipToConnect = ip;
                        portToConnect = port;
                      });

                      _confirmAndConnect(ip, port); // displayName 引数を削除
                    } catch (e) {
                      print('QRデコードエラー: $e');
                      if (mounted) {
                        Navigator.pop(context, '無効なQRコード');
                      }
                    }
                  }
                }
              },
            )
          else
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('手動入力', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 20),
                  TextField(
                    controller: ipController,
                    decoration: const InputDecoration(labelText: 'IPアドレス (例: 192.168.1.8)'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: portController,
                    decoration: const InputDecoration(labelText: 'ポート番号 (例: 50051)'),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerRight,
                    child: ElevatedButton(
                      onPressed: () {
                        final ip = ipController.text.trim();
                        final int? port = int.tryParse(portController.text.trim());
                        if (ip.isNotEmpty && port != null) {
                          connectAndSendHello(ip, port); // displayName 引数を削除
                        }
                      },
                      child: const Text('接続する'),
                    ),
                  ),
                ],
              ),
            ),
          if (!isConnecting)
            Positioned(
              bottom: 30,
              left: 20,
              right: 20,
              child: ElevatedButton.icon(
                onPressed: () {
                  setState(() {
                    isManualInputMode = !isManualInputMode;
                  });
                },
                icon: Icon(isManualInputMode ? Icons.qr_code : Icons.edit_location_alt),
                label: Text(isManualInputMode ? 'QRコードをスキャン' : '手動でIPを入力'),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmAndConnect(String ip, int port) async { // displayName 引数を削除
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('スキャン成功'), // 「接続確認」から変更
        content: Text('IPアドレス: $ip\nポート: $port\n(gRPC機能は現在無効です)'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('OK'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      connectAndSendHello(ip, port); // displayName 引数を削除
    } else {
      setState(() {
        ipToConnect = null;
        portToConnect = null;
      });
    }
  }

  // gRPC接続処理 (ロジックを削除し、ダミーの待機と戻り値に変更)
  Future<void> connectAndSendHello(String ip, int port) async { // displayName 引数を削除
    setState(() {
      isConnecting = true;
    });

    showConnectingDialog(ip, port);

    // --- gRPC接続ロジックを削除 ---
    // final channel = ClientChannel(...);
    // final stub = HelloServiceClient(channel);
    // try {
    //   final response = await stub.sayHello(...);
    //   ...
    // } catch (e) {
    //   ...
    // } finally {
    //   await channel.shutdown();
    //   ...
    // }

    // ★★★ 代わりにダミーの処理を追加 ★★★
    try {
      print('--- gRPC機能は無効化されています ---');
      print('DEMO: $ip:$port に接続シミュレーション...');
      // 接続デモ用に1秒待機
      await Future.delayed(const Duration(seconds: 1));

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // 接続中ダイアログを閉じる
        Navigator.pop(context, "スキャン完了 (gRPC無効)"); // ダミーの戻り値
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        Navigator.pop(context, 'スキャン失敗');
      }
    } finally {
      setState(() {
        isConnecting = false;
        ipToConnect = null;
        portToConnect = null;
      });
    }
    // ★★★ 修正ここまで ★★★
  }

  // 接続中のプログレス表示
  void showConnectingDialog(String ip, int port) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('処理中...'), // 「接続中」から変更
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text('IPアドレス: $ip\nポート: $port\n(gRPC機能は無効です)'),
          ],
        ),
      ),
    );
  }
}