import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../grpc/psi_client.dart';

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final _client = PsiGrpcClient();

  bool isConnecting = false;
  bool isManualInputMode = false;

  final TextEditingController ipController = TextEditingController();
  final TextEditingController portController = TextEditingController(text: '50051');

  String? ipToConnect;
  int? portToConnect;

  @override
  void dispose() {
    ipController.dispose();
    portController.dispose();
    super.dispose();
  }

  Future<void> _confirmAndConnect(String ip, int port) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('接続確認'),
        content: Text('サーバ: $ip:$port に接続しますか？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('接続')),
        ],
      ),
    );

    if (ok != true) return;

    setState(() => isConnecting = true);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      await _client.connect(ip, port);
      final pong = await _client.ping('hello');
      // ignore: avoid_print
      print('Client received: $pong');

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // ローディング閉じる
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('接続成功: $pong')),
        );
        Navigator.pop(context, '接続成功: $pong');
      }
    } catch (e) {
      // ignore: avoid_print
      print('接続失敗: $e');
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // ローディング閉じる
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('接続失敗: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => isConnecting = false);
    }
  }

  Future<void> _connectManual() async {
    final ip = ipController.text.trim();
    final port = int.tryParse(portController.text) ?? 50051;
    if (ip.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('IP を入力してください')),
      );
      return;
    }
    await _confirmAndConnect(ip, port);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('サーバをスキャン'),
        actions: [
          IconButton(
            tooltip: isManualInputMode ? 'カメラで読み取る' : '手入力する',
            onPressed: () => setState(() => isManualInputMode = !isManualInputMode),
            icon: Icon(isManualInputMode ? Icons.qr_code_scanner : Icons.keyboard),
          ),
        ],
      ),
      body: isManualInputMode ? _buildManual() : _buildScanner(),
    );
  }

  Widget _buildManual() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: ipController,
          decoration: const InputDecoration(
            labelText: 'IPアドレス',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: portController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'ポート番号',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: isConnecting ? null : _connectManual,
          icon: const Icon(Icons.link),
          label: const Text('接続'),
        ),
      ],
    );
  }

  Widget _buildScanner() {
    return Stack(
      children: [
        MobileScanner(
          onDetect: (capture) {
            if (isConnecting) return;
            final barcodes = capture.barcodes;
            for (final barcode in barcodes) {
              final code = barcode.rawValue;
              if (code == null) continue;

              try {
                final Map<String, dynamic> grpcInfo = jsonDecode(code);
                final String ip = grpcInfo['ip'];
                final int port = grpcInfo['port'];

                setState(() {
                  ipToConnect = ip;
                  portToConnect = port;
                });

                _confirmAndConnect(ip, port);
                break; // 1つ処理したら抜ける
              } catch (e) {
                // ignore: avoid_print
                print('QRデコードエラー: $e');
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('QRコードの形式が不正です')),
                  );
                }
              }
            }
          },
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Card(
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('カメラに QR をかざしてください'),
                  if (ipToConnect != null && portToConnect != null) ...[
                    const SizedBox(height: 8),
                    Text('検出: $ipToConnect:$portToConnect'),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
