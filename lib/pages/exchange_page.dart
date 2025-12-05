import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../ble/ble_exchange_controller.dart';
import '../grpc/grpc_server.dart';
import '../grpc/grpc_client.dart'; // PsiResult
import '../key_management_service.dart';
import '../db/database_helper.dart';
import 'debug_page.dart';

class ExchangePage extends StatefulWidget {
  const ExchangePage({super.key});

  @override
  State<ExchangePage> createState() => _ExchangePageState();
}

class _ExchangePageState extends State<ExchangePage> {
  // ===== BLE 近接交換 =====
  final _ble = BleExchangeController();
  bool get _bleRunning => _ble.isRunning;

  // ===== gRPC サーバ =====
  PsiGrpcServer? _grpcServer;
  bool get _grpcRunning => _grpcServer?.isRunning == true;
  String? _serverIp;
  int _serverPort = 50051;

  // ===== DB / 鍵 =====
  final _keyService = KeyManagementService();
  final _db = DatabaseHelper();

  // ==========================================================
  Future<bool> _hasAnyKey() async {
    final count = await _db.getTotalKeyCount();
    return count > 0;
  }

  Future<bool> _requireKeyWarning() async {
    final hasKey = await _hasAnyKey();
    if (hasKey) return true;

    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('鍵がありません'),
        content: const Text(
          '顔見知り確認のための鍵がありません。\n'
              'まずは BLE 近接交換を行ってください。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return false;
  }

  // ==========================================================
  Future<bool> _ensureBlePermissions() async {
    final perms = <Permission>[
      Permission.bluetoothAdvertise,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ];
    final statuses = await perms.request();

    return perms.every((p) => statuses[p]?.isGranted ?? false);
  }

  Future<bool> _ensureLocationPermissions() async {
    await Permission.location.request();
    return await Permission.location.isGranted;
  }

  Future<void> _toggleBleExchange() async {
    if (!_bleRunning) {
      if (!await _ensureBlePermissions()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Bluetooth の権限が必要です')),
          );
        }
        return;
      }
      await _ensureLocationPermissions();
    }

    await _ble.toggleExchange();
    if (mounted) setState(() {});
  }

  // ==========================================================
  Future<String?> _getLocalWifiIp() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (var interface in interfaces) {
        if (interface.name == 'wlan0') {
          for (var addr in interface.addresses) {
            if (addr.type == InternetAddressType.IPv4) {
              return addr.address;
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  // ==========================================================
  // ★ サーバ起動 & PSI完了通知購読
  // ==========================================================
  Future<void> _startGrpcServer() async {
    if (!await _requireKeyWarning()) return;
    if (_grpcRunning) return;

    final ip = await _getLocalWifiIp();
    if (ip == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ローカル IP が取得できません（Wi-Fi を確認）')),
      );
      return;
    }

    final server = PsiGrpcServer();
    final port = await server.start(port: _serverPort);

    // ★ サーバ側 PSI 完了イベントを購読
    server.service.onPsiFinished.listen((PsiResult psi) {
      _showUnifiedPsiDialog(psi, isServerSide: true);
    });

    setState(() {
      _grpcServer = server;
      _serverIp = ip;
      _serverPort = port;
    });

    print('✅ gRPC Server started on $ip:$port');
  }

  Future<void> _stopGrpcServer() async {
    final s = _grpcServer;
    _grpcServer = null;
    setState(() {});
    await s?.stop();
  }

  // ==========================================================
  // ★ ScannerPage の PSI結果（クライアント側）を受け取る
  // ==========================================================
  Future<void> _openScannerPage() async {
    if (!await _requireKeyWarning()) return;

    final result = await Navigator.pushNamed(context, '/scanner');

    if (result is PsiResult) {
      _showUnifiedPsiDialog(result, isServerSide: false);
    }
  }

  // ==========================================================
  /// ★ クライアント／サーバ共通のポップアップ
  // ==========================================================
  Future<void> _showUnifiedPsiDialog(PsiResult psi, {required bool isServerSide}) async {
    final familiar = psi.isFamiliar;
    final commonCount = psi.commonKeys.length;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text(
          familiar ? '顔見知りです' : '見知らぬ人です',
          style: TextStyle(
            color: familiar ? Colors.green : Colors.red,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          '共通鍵数: $commonCount 件\n'
              '自身の生成鍵との一致: ${familiar ? "あり" : "なし"}\n'
              '${isServerSide ? "（サーバ側）" : "（クライアント側）"}',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          )
        ],
      ),
    );
  }

  // ==========================================================
  String get _qrPayload => jsonEncode({
    'ip': _serverIp ?? '',
    'port': _serverPort,
  });

  // ==========================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('PSI Ring Match',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            Text('通信設定', style: TextStyle(fontSize: 14)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.bug_report),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DebugPage()),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ------------------------------------------------------
          // BLE
          // ------------------------------------------------------
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('BLE 近接交換',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: _toggleBleExchange,
                        icon: Icon(_bleRunning ? Icons.stop : Icons.play_arrow),
                        label: Text(_bleRunning ? '停止' : '開始'),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _bleRunning ? '実行中（広告＋スキャン）' : '停止中',
                        style:
                        TextStyle(color: _bleRunning ? Colors.green : Colors.grey),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ------------------------------------------------------
          // gRPC
          // ------------------------------------------------------
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('gRPC 接続',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Switch(
                        value: _grpcRunning,
                        onChanged: (on) {
                          if (on) {
                            _startGrpcServer();
                          } else {
                            _stopGrpcServer();
                          }
                        },
                      ),
                      Text(_grpcRunning ? '稼働中' : '停止中'),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.qr_code_scanner),
                        tooltip: 'QR をスキャン（接続）',
                        onPressed: _openScannerPage,
                      ),
                    ],
                  ),
                  if (_grpcRunning) ...[
                    const SizedBox(height: 8),
                    Text('サーバ: ${_serverIp ?? "-"} : $_serverPort'),
                    const SizedBox(height: 8),
                    Center(
                      child: QrImageView(
                        data: _qrPayload,
                        size: 200,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '相手端末で QR をスキャンしてください。',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
