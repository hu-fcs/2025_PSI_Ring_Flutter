import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../grpc/psi_client.dart';
import '../key_management_service.dart';

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final _client = PsiGrpcClient();
  final _keyService = KeyManagementService();

  bool isConnecting = false;
  bool isManualInputMode = false;
  bool _isProcessingScan = false;

  final TextEditingController ipController = TextEditingController();
  final TextEditingController portController =
  TextEditingController(text: '50051');

  String? ipToConnect;
  int? portToConnect;

  final MobileScannerController _scannerController = MobileScannerController();

  @override
  void dispose() {
    ipController.dispose();
    portController.dispose();
    _scannerController.dispose();
    super.dispose();
  }

  /// バイト列 → Hex（ログ用途）
  String _bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// ----------------------------------------------------------------------
  ///  接続確認 → gRPC 接続 → PSI 実行
  /// ----------------------------------------------------------------------
  Future<void> _confirmAndConnect(String ip, int port) async {
    // ★ カメラ停止（背景停止のため）
    await _scannerController.stop();

    // ---- 接続確認ダイアログ ----
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('接続確認'),
        content: Text('サーバ: $ip:$port に接続しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('接続'),
          ),
        ],
      ),
    );

    if (ok != true) {
      _isProcessingScan = false;
      _scannerController.start();
      return;
    }

    // ---- ローディング表示 ----
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.1),
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    setState(() => isConnecting = true);

    try {
      print('[CLIENT] trying to connect to $ip:$port');
      await _client.connect(ip, port);
      print('[CLIENT] connect() success');

      // ------------------------------------------------------------
      // 2. ECC-PSI 実行（鍵DB処理は psi_client が全て担当）
      // ------------------------------------------------------------
      print('[Scanner] 🔍 Starting PSI...');

      final commonKeys = await _client.executePsi();

      print('\n[Scanner] ✅ PSI Complete!');
      print('Found ${commonKeys.length} common keys.');

      if (commonKeys.isNotEmpty) {
        print('💍 [Intersection Results]');
        for (var i = 0; i < commonKeys.length; i++) {
          print('   common key[$i]: ${commonKeys[i]}');
        }
      } else {
        print('❌ No common keys found.');
      }

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // ローディング閉じる

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('PSI完了: 共通鍵 ${commonKeys.length} 件を発見しました'),
            backgroundColor: commonKeys.isNotEmpty ? Colors.green : Colors.black,
          ),
        );

        Navigator.pop(context, 'PSI完了: ${commonKeys.length}件一致');
      }
    } catch (e) {
      print('[CLIENT] PSI/Exchange ERROR: $e');

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // ローディング閉じる
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('接続またはPSI実行に失敗しました: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }

      _isProcessingScan = false;
      _scannerController.start();
    } finally {
      if (mounted) setState(() => isConnecting = false);
    }
  }

  /// 手入力で接続
  Future<void> _connectManual() async {
    final ip = ipController.text.trim();
    final port = int.tryParse(portController.text) ?? 50051;

    if (ip.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('IP を入力してください')),
      );
      return;
    }

    _isProcessingScan = true;
    await _scannerController.stop();
    await _confirmAndConnect(ip, port);
  }

  /// QR検出
  Future<void> _onDetect(BarcodeCapture capture) async {
    if (isConnecting || _isProcessingScan) return;

    final barcodes = capture.barcodes;

    for (final barcode in barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;

      _isProcessingScan = true;

      try {
        await _scannerController.stop();

        final map = jsonDecode(raw) as Map<String, dynamic>;
        final ip = map['ip'];
        final port = map['port'];

        ipToConnect = ip;
        portToConnect = port;

        await _confirmAndConnect(ip, port);
      } catch (e) {
        print('QR decode error: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('QRコードの形式が不正です')),
          );
        }

        _isProcessingScan = false;
        _scannerController.start();
      }

      break;
    }
  }

  /// ----------------------------------------------------------------------
  /// UI
  /// ----------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('サーバをスキャン'),
        actions: [
          IconButton(
            tooltip: isManualInputMode ? 'カメラで読み取る' : '手入力する',
            onPressed: () {
              setState(() => isManualInputMode = !isManualInputMode);
              if (isManualInputMode) {
                _scannerController.stop();
              } else {
                _isProcessingScan = false;
                _scannerController.start();
              }
            },
            icon: Icon(
              isManualInputMode ? Icons.qr_code_scanner : Icons.keyboard,
            ),
          ),
        ],
      ),

      body: isManualInputMode ? _buildManual() : _buildScanner(),
    );
  }

  /// 手入力UI
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
        const SizedBox(height: 12),
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

  /// カメラスキャナUI
  Widget _buildScanner() {
    return Stack(
      children: [
        MobileScanner(
          controller: _scannerController,
          onDetect: _onDetect,
        ),

        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
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
