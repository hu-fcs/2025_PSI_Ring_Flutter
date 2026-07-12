// lib/pages/scanner_page.dart

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:grpc/grpc.dart' as grpc;
import 'package:mobile_scanner/mobile_scanner.dart';

import '../grpc/grpc_client.dart';

/// QR コードから接続先(IP/Port)を取得し，gRPC で PSI を実行する画面。
///
/// QR を読み取れない場合に備えて，手入力による接続も提供する。
class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final _client = GrpcClient();

  bool isConnecting = false;
  bool _isProcessingScan = false;
  bool _isManualInputMode = false;

  final MobileScannerController _scannerController = MobileScannerController();

  // start/stop の連続呼び出しを避けるための排他
  bool _cameraLock = false;

  final TextEditingController ipController = TextEditingController();
  final TextEditingController portController =
  TextEditingController(text: '50051');
  final TextEditingController nanceController = TextEditingController();

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
    _scannerController.dispose();
    ipController.dispose();
    portController.dispose();
    nanceController.dispose();
    super.dispose();
  }

  Future<void> _confirmAndConnect(String ip, int port, int nance) async {
    await safeStopCamera();

    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('接続確認'),
        content: Text('サーバ $ip:$port に接続しますか？'),
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

    if (ok != true) { // キャンセルした時
      _isProcessingScan = false;
      await safeStartCamera();
      return;
    }

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.2),
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      await _client.connect(ip, port, nance);
      final psiResult = await _client.executePsi();
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        Navigator.pop(context, psiResult);
      }
    } on grpc.GrpcError catch (e) {
      var text = 'gRPC接続に失敗しました：\n$e';
      if (e.code == grpc.StatusCode.unavailable) {
        text = 'IPアドレスとポート番号を確認してください：\n$e';
      } else if (e.code == grpc.StatusCode.unauthenticated) {
        text = '確認コードが正しくありません';
      }
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(text)),
        );
      }
      return; // 接続失敗で中断
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('接続に失敗しました: \n$e')),
        );
      }
      _isProcessingScan = false;
      await safeStartCamera();
    }
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (isConnecting || _isProcessingScan) return;

    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;

      _isProcessingScan = true;
      try {
        await safeStopCamera();
        final s = raw.split(':');
        if (s.first != 'FCS') {
          throw Exception('他のQRコードです');
        }
        final ip = s[1].trim();
        final port = int.tryParse(s[2]) ?? 0;
        final nance = int.tryParse(s[3]) ?? 0;
        await _confirmAndConnect(ip, port, nance);
      } catch (_) {
        _isProcessingScan = false;
        await safeStartCamera();
      }
      break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    final size = MediaQuery.of(context).size;

    final overlay = const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light, // Android
      statusBarBrightness: Brightness.dark, // iOS
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlay,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (!_isManualInputMode)
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.only(top: topInset),
                  child: MobileScanner(
                    controller: _scannerController,
                    onDetect: _onDetect,
                    fit: BoxFit.cover,
                  ),
                ),
              ),

            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: Container(
                height: topInset + 96,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: Padding(
                  padding: EdgeInsets.only(top: topInset),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Text('スキャン',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(color: Colors.white)),
                      Positioned(
                        left: 6,
                        child: IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            if (!_isManualInputMode)
              Positioned(
                top: size.height * 0.25,
                left: 0,
                right: 0,
                child: Center(
                  child: Icon(
                    Icons.qr_code_scanner,
                    size: 200,
                    color: Colors.white.withValues(alpha: 0.25),
                  ),
                ),
              ),

            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('QRコードをカメラにかざしてください',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(color: Colors.white)),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              setState(() => _isManualInputMode = true);
                              await safeStopCamera();
                            },
                            icon: const Icon(Icons.keyboard),
                            label: const Text('手入力で接続'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.65),
                              ),
                              padding: const EdgeInsets.symmetric(
                                vertical: 12,
                                horizontal: 14,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            if (_isManualInputMode) _manualBottomSheet(),
          ],
        ),
      ),
    );
  }

  Widget _manualBottomSheet() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('手入力で接続',
                    style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    tooltip: '閉じる',
                    icon: const Icon(Icons.close),
                    onPressed: () async {
                      setState(() => _isManualInputMode = false);
                      _isProcessingScan = false;
                      await safeStartCamera();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ipController,
                decoration: const InputDecoration(
                  labelText: 'IPアドレス',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: portController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'ポート番号',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nanceController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '確認コード',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _confirmAndConnect(
                    ipController.text.trim(),
                    int.tryParse(portController.text) ?? 50051,
                    int.tryParse(nanceController.text) ?? 0,
                  ),
                  icon: const Icon(Icons.link),
                  label: const Text('接続'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
