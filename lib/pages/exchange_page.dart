import 'dart:convert';
import 'dart:io'; // ★ NetworkInterface を使うために必要

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../ble/ble_exchange_controller.dart';
import '../grpc/psi_server.dart';
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
  // ★ 常に DB から最新の鍵数を取得する
  // ==========================================================
  Future<bool> _hasAnyKey() async {
    final count = await _db.getTotalKeyCount();
    return count > 0;
  }

  // ==========================================================
  // ★ 鍵なし警告ダイアログ
  // ==========================================================
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
  // ★ BLE 権限チェック
  // ==========================================================
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

  // ==========================================================
  // ★ BLE の ON/OFF を切り替え
  // ==========================================================
  Future<bool> _ensureLocationPermissions() async {
    // 許可を求める（拒否されても OK）
    await Permission.location.request();

    // 許可されていれば true、拒否なら false
    return await Permission.location.isGranted;
  }

  Future<void> _toggleBleExchange() async {
    if (!_bleRunning) {
      // BLE の権限チェック（これは必須）
      final bleOk = await _ensureBlePermissions();
      if (!bleOk) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Bluetooth の権限が必要です')),
          );
        }
        return;
      }

      // ★ 位置情報権限は optional のため、拒否されても BLE を開始する
      await _ensureLocationPermissions();
    }

    await _ble.toggleExchange();
    if (mounted) setState(() {});
  }


  // ==========================================================
  // ★ 正しい Wi-Fi IPv4 を取得（wlan0 のみ使用）
  // ==========================================================
  Future<String?> _getLocalWifiIp() async {
    try {
      final interfaces = await NetworkInterface.list();

      for (var interface in interfaces) {
        if (interface.name == 'wlan0') {
          for (var addr in interface.addresses) {
            if (addr.type == InternetAddressType.IPv4) {
              return addr.address; // ★ 正しい IPv4 を返す
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  // ==========================================================
  // ★ gRPC サーバ開始
  // ==========================================================
  Future<void> _startGrpcServer() async {
    if (!await _requireKeyWarning()) return;

    if (_grpcRunning) return;

    final ip = await _getLocalWifiIp();
    if (ip == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ローカル IP が取得できません（同じ Wi-Fi に接続してください）'),
        ),
      );
      return;
    }

    final server = PsiGrpcServer();
    final port = await server.start(port: _serverPort);

    setState(() {
      _grpcServer = server;
      _serverIp = ip;
      _serverPort = port;
    });

    print('✅ gRPC Server started on $_serverIp:$_serverPort');
  }

  Future<void> _stopGrpcServer() async {
    final s = _grpcServer;
    _grpcServer = null;
    setState(() {});
    await s?.stop();
  }

  // ==========================================================
  // ★ ScannerPage 起動前にも鍵チェック
  // ==========================================================
  void _openScannerPage() async {
    if (!await _requireKeyWarning()) return;
    Navigator.pushNamed(context, '/scanner');
  }

  String get _qrPayload => jsonEncode({
    'ip': _serverIp ?? '',
    'port': _serverPort,
  });

  // ==========================================================
  // UI
  // ==========================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PSI Ring Match',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            Text('通信設定', style: TextStyle(fontSize: 14)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.bug_report),
            tooltip: 'デバッグページ',
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
          // BLE セクション
          // ------------------------------------------------------
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
                  const Text('近くの端末と鍵を交換します。'),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ------------------------------------------------------
          // gRPC セクション
          // ------------------------------------------------------
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('gRPC 接続', style: Theme.of(context).textTheme.titleMedium),
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
                        tooltip: 'QR をスキャン（接続）',
                        icon: const Icon(Icons.qr_code_scanner),
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
                        version: QrVersions.auto,
                        size: 200,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text('もう一方の端末で QR をスキャンして接続してください。'),
                  ] else ...[
                    const SizedBox(height: 8),
                    const Text('ON にすると接続用の QR が表示されます。'),
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
