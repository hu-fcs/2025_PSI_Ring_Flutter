// lib/pages/scanner_page.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../grpc/grpc_client.dart';
import '../key_management_service.dart';

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final _client = GrpcClient();
  final _keyService = KeyManagementService();

  bool isConnecting = false;
  bool isManualInputMode = false;
  bool _isProcessingScan = false;

  final TextEditingController ipController = TextEditingController();
  final TextEditingController portController =
  TextEditingController(text: '50051');

  String? ipToConnect;
  int? portToConnect;

  final MobileScannerController _scannerController =
  MobileScannerController();

  /// ======== カメラ排他ロック ========
  bool _cameraLock = false;

  Future<void> safeStopCamera() async {
    if (_cameraLock) return;
    _cameraLock = true;
    try {
      await _scannerController.stop();
    } catch (_) {}
    _cameraLock = false;
  }

  Future<void> safeStartCamera() async {
    if (_cameraLock) return;
    _cameraLock = true;
    try {
      await _scannerController.start();
    } catch (_) {}
    _cameraLock = false;
  }

  @override
  void dispose() {
    ipController.dispose();
    portController.dispose();
    _scannerController.dispose();
    super.dispose();
  }

  String _bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  // ===================================================================
  //   接続確認 → gRPC → PSI 実行 → PsiResult を ExchangePage へ返す
  // ===================================================================
  Future<void> _confirmAndConnect(String ip, int port) async {
    await safeStopCamera();

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

    // キャンセルされたらカメラ再開
    if (ok != true) {
      _isProcessingScan = false;
      await safeStartCamera();
      return;
    }

    // ローディング表示
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

      print('[Scanner] 🔍 Starting PSI...');

      /// ★ PsiResult を返す
      final psiResult = await _client.executePsi();

      print('\n[Scanner] ✅ PSI Complete!');
      print('👉 common=${psiResult.commonKeys.length}, '
          'familiar=${psiResult.isFamiliar}');

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // loading close

        /// ★ ScannerPage を閉じて結果を返す（SnackBar は出さない）
        Navigator.pop(context, psiResult);
      }
    } catch (e) {
      print('[CLIENT] PSI/Exchange ERROR: $e');

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // loading close

        /// ★ 失敗時だけ SnackBar 表示
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('接続またはPSI実行に失敗しました: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }

      _isProcessingScan = false;
      await safeStartCamera();
    } finally {
      if (mounted) setState(() => isConnecting = false);
    }
  }

  /// 手入力接続
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
    await safeStopCamera();
    await _confirmAndConnect(ip, port);
  }

  /// QR検出
  Future<void> _onDetect(BarcodeCapture capture) async {
    if (isConnecting || _isProcessingScan) return;

    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;

      _isProcessingScan = true;

      try {
        await safeStopCamera();

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
        await safeStartCamera();
      }

      break;
    }
  }

  // ===================================================================
  // UI
  // ===================================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('サーバをスキャン'),
        actions: [
          IconButton(
            tooltip: isManualInputMode ? 'カメラで読み取る' : '手入力する',
            onPressed: () async {
              setState(() => isManualInputMode = !isManualInputMode);
              if (isManualInputMode) {
                await safeStopCamera();
              } else {
                _isProcessingScan = false;
                await safeStartCamera();
              }
            },
            icon:
            Icon(isManualInputMode ? Icons.qr_code_scanner : Icons.keyboard),
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
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('カメラに QR をかざしてください'),
                  if (ipToConnect != null && portToConnect != null) ...[
                    const SizedBox(height: 8),
                    Text('検出: $ipToConnect:$portToConnect'),
                  ]
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
