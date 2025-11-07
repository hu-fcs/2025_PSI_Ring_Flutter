import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:network_info_plus/network_info_plus.dart';

import '../ble/ble_exchange_controller.dart';
import '../grpc/psi_server.dart';
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
  int _serverPort = 50051; // 固定でもOK。0にすると空きポートが割当て

  // ===== BLE: 権限確認 =====
  Future<bool> _ensureBlePermissions() async {
    final perms = <Permission>[
      Permission.bluetoothAdvertise,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ];
    final statuses = await perms.request();
    for (final p in perms) {
      if (!(statuses[p]?.isGranted ?? false)) return false;
    }
    return true;
  }

  Future<void> _toggleBleExchange() async {
    if (!_bleRunning) {
      final ok = await _ensureBlePermissions();
      if (!ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Bluetooth の権限が必要です')),
          );
        }
        return;
      }
    }
    await _ble.toggleExchange();
    if (mounted) setState(() {});
  }

  // ===== gRPC: サーバ起動/停止 + QR表示 =====
  Future<String?> _getLocalWifiIp() async {
    try {
      final info = NetworkInfo();
      final ip = await info.getWifiIP();
      return ip;
    } catch (_) {
      return null;
    }
  }

  Future<void> _startGrpcServer() async {
    if (_grpcRunning) return;
    final ip = await _getLocalWifiIp();
    if (ip == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ローカルIPが取得できません（同じWi-Fiに接続してください）')),
        );
      }
      return;
    }
    final server = PsiGrpcServer();
    final port = await server.start(port: _serverPort);
    setState(() {
      _grpcServer = server;
      _serverIp = ip;
      _serverPort = port;
    });
    // ignore: avoid_print
    print('✅ gRPC Server on $_serverIp:$_serverPort');
  }

  Future<void> _stopGrpcServer() async {
    final s = _grpcServer;
    _grpcServer = null;
    setState(() {});
    await s?.stop();
  }

  String get _qrPayload => jsonEncode({'ip': _serverIp ?? '', 'port': _serverPort});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // ==== ブランド化した AppBar ====
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PSI Ring Match',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            Text(
              '通信設定',
              style: TextStyle(fontSize: 14),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'デバッグページ',
            icon: const Icon(Icons.bug_report),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DebugPage()),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ===== BLE セクション =====
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('BLE 近接交換', style: Theme.of(context).textTheme.titleMedium),
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
                        style: TextStyle(
                          color: _bleRunning ? Colors.green : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '近くの端末と鍵を交換します。',
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ===== gRPC サーバ セクション =====
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('gRPC サーバ', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Switch(
                        value: _grpcRunning,
                        onChanged: (on) => on ? _startGrpcServer() : _stopGrpcServer(),
                      ),
                      Text(_grpcRunning ? '稼働中' : '停止中'),
                      const Spacer(),
                      IconButton(
                        tooltip: 'QR をスキャン（クライアント側へ）',
                        onPressed: () => Navigator.pushNamed(context, '/scanner'),
                        icon: const Icon(Icons.qr_code_scanner),
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
                        version: QrVersions.auto,
                        size: 200,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'もう一方の端末で「QRコードをスキャン」を押して接続してください。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    const Text('ON にすると IP/ポートの QR を表示します。'),
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
