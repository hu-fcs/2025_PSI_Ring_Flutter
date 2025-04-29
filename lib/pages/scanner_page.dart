import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:grpc/grpc.dart';
import '../generated/hello.pbgrpc.dart';

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

  // 接続先情報（スキャン時のみ保持）
  String? ipToConnect;
  int? portToConnect;

  @override
  Widget build(BuildContext context) {
    final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    final String displayName = args?['displayName'] ?? 'UnknownName';

    return Scaffold(
      appBar: AppBar(title: const Text('サーバに接続する')),
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

                      // QRスキャン時だけ確認ポップアップを出す
                      _confirmAndConnect(ip, port, displayName);
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
                          // 手入力時は即接続
                          connectAndSendHello(ip, port, displayName);
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

  // スキャン時だけ確認してから接続する
  Future<void> _confirmAndConnect(String ip, int port, String displayName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('接続確認'),
        content: Text('IPアドレス: $ip\nポート: $port\nに接続しますか？'),
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
      connectAndSendHello(ip, port, displayName);
    } else {
      setState(() {
        ipToConnect = null;
        portToConnect = null;
      });
    }
  }

  // gRPC接続処理
  Future<void> connectAndSendHello(String ip, int port, String displayName) async {
    setState(() {
      isConnecting = true;
    });

    showConnectingDialog(ip, port);

    final channel = ClientChannel(
      ip,
      port: port,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    final stub = HelloServiceClient(channel);

    try {
      final response = await stub.sayHello(HelloRequest(name: displayName));
      Navigator.of(context, rootNavigator: true).pop(); // 接続中ダイアログを閉じる
      if (mounted) {
        Navigator.pop(context, response.message);
      }
    } catch (e) {
      print('❌ gRPC接続エラー: $e');
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        Navigator.pop(context, '接続失敗');
      }
    } finally {
      await channel.shutdown();
      setState(() {
        isConnecting = false;
        ipToConnect = null;
        portToConnect = null;
      });
    }
  }

  // 接続中のプログレス表示
  void showConnectingDialog(String ip, int port) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('接続中...'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text('IPアドレス: $ip\nポート: $port\nに接続しています'),
          ],
        ),
      ),
    );
  }
}
