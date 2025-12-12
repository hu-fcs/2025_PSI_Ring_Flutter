// lib/pages/scanner_page.dart

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../grpc/grpc_client.dart';

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

  bool _cameraLock = false;

  final TextEditingController ipController = TextEditingController();
  final TextEditingController portController =
  TextEditingController(text: '50051');

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
    super.dispose();
  }

  // ==========================================================
  Future<void> _confirmAndConnect(String ip, int port) async {
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

    if (ok != true) {
      _isProcessingScan = false;
      await safeStartCamera();
      return;
    }

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.2),
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      await _client.connect(ip, port);
      final psiResult = await _client.executePsi();
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        Navigator.pop(context, psiResult);
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('接続に失敗しました: $e')),
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
        final map = jsonDecode(raw) as Map<String, dynamic>;
        await _confirmAndConnect(map['ip'], map['port']);
      } catch (_) {
        _isProcessingScan = false;
        await safeStartCamera();
      }
      break;
    }
  }

  // ==========================================================
  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    final size = MediaQuery.of(context).size;

    // ステータスバー文字を白に（背景は透明）
    final overlay = const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light, // Android
      statusBarBrightness: Brightness.dark, // iOS（dark=文字白）
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlay,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand, // ★ これで「左上に縮む」事故を防ぐ
          children: [
            // ===== カメラ（ステータスバー領域を避ける）=====
            if (!_isManualInputMode)
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.only(top: topInset),
                  child: MobileScanner(
                    controller: _scannerController,
                    onDetect: _onDetect,
                    fit: BoxFit.cover, // ★ 画面に覆うように表示
                  ),
                ),
              ),

            // ===== 上部（PayPay風：グラデ＋タイトル＋×）=====
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: Container(
                height: topInset + 96, // ステータスバー + ヘッダー
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
                      const Text(
                        'スキャン',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
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

            // ===== QR枠（上寄り）=====
            if (!_isManualInputMode)
              Positioned(
                top: size.height * 0.25,
                left: 0,
                right: 0,
                child: Center(
                  child: Icon(
                    Icons.qr_code_scanner,
                    size: 200,
                    color: Colors.white.withOpacity(0.25),
                  ),
                ),
              ),


            // ===== 下部ガイド（半透明黒は前のまま）=====
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
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'QRコードをカメラにかざしてください',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),

                        // ★ 押せると分かるボタンに
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
                                color: Colors.white.withOpacity(0.65),
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

            // ===== 手入力ボトムシート（見た目改善版）=====
            if (_isManualInputMode) _manualBottomSheet(),
          ],
        ),
      ),
    );
  }

  // ==========================================================

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
              // ===== タイトル行 + ✕ =====
              Row(
                children: [
                  Text(
                    '手入力で接続',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
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

              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _confirmAndConnect(
                    ipController.text.trim(),
                    int.tryParse(portController.text) ?? 50051,
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