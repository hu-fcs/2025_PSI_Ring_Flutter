// lib/pages/exchange_page.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../ble/ble_exchange_controller.dart';
import '../grpc/grpc_server.dart';
import '../grpc/grpc_client.dart'; // PsiResult
import '../db/database_helper.dart';
import 'debug_page.dart';

class ExchangePage extends StatefulWidget {
  const ExchangePage({super.key});

  @override
  State<ExchangePage> createState() => _ExchangePageState();
}

class _ExchangePageState extends State<ExchangePage> {
  // ===== BLE =====
  final _ble = BleExchangeController();
  bool get _bleRunning => _ble.isRunning;

  // ===== gRPC（QR表示側のみ）=====
  PsiGrpcServer? _grpcServer;
  bool get _grpcRunning => _grpcServer?.isRunning == true;
  String? _serverIp;
  int _serverPort = 50051;

  final _db = DatabaseHelper();

  // ==========================================================
  Future<bool> _hasAnyKey() async => (await _db.getTotalKeyCount()) > 0;

  Future<bool> _requireKeyWarning() async {
    if (await _hasAnyKey()) return true;

    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('鍵がありません'),
        content: const Text(
          '顔見知り確認のための鍵がありません。\n'
              'まずは「近くの人を記録」をONにしてください。',
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
    final perms = [
      Permission.bluetoothAdvertise,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ];
    final statuses = await perms.request();
    return perms.every((p) => statuses[p]?.isGranted ?? false);
  }

  Future<bool> _ensureBluetoothEnabled() async {
    try {
      if (await FlutterBluePlus.adapterState.first == BluetoothAdapterState.on) {
        return true;
      }
      await FlutterBluePlus.turnOn();
      await FlutterBluePlus.adapterState
          .firstWhere((s) => s == BluetoothAdapterState.on);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _toggleBleExchange() async {
    if (!_bleRunning) {
      if (!await _ensureBlePermissions() || !await _ensureBluetoothEnabled()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Bluetooth を使用できません')),
          );
        }
        return;
      }
    }
    await _ble.toggleExchange();
    if (mounted) setState(() {});
  }

  // ==========================================================
  Future<String?> _getLocalWifiIp() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (final i in interfaces) {
        if (i.name == 'wlan0') {
          for (final a in i.addresses) {
            if (a.type == InternetAddressType.IPv4) return a.address;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  // ==========================================================
  /// QRを表示する（表示側）
  // ==========================================================
  Future<void> _showQr() async {
    if (!await _requireKeyWarning()) return;
    if (_grpcRunning) return;

    final ip = await _getLocalWifiIp();
    if (ip == null) return;

    final server = PsiGrpcServer();
    final port = await server.start(port: _serverPort);

    server.service.onPsiFinished.listen((psi) {
      if (!psi.isFamiliar) {
        _showUnifiedPsiDialog(psi, isServerSide: true);
      }
    });

    server.service.onRingAuthenticated.listen((psi) {
      _showUnifiedPsiDialog(psi, isServerSide: true);
    });

    setState(() {
      _grpcServer = server;
      _serverIp = ip;
      _serverPort = port;
    });
  }

  Future<void> _stopQr() async {
    final s = _grpcServer;
    _grpcServer = null;
    setState(() {});
    await s?.stop();
  }

  // ==========================================================
  /// QRを読み取る（読み取り側）
  // ==========================================================
  Future<void> _scanQr() async {
    if (!await _requireKeyWarning()) return;

    final result = await Navigator.pushNamed(context, '/scanner');
    if (result is PsiResult) {
      _showUnifiedPsiDialog(result, isServerSide: false);
    }
  }

  // ==========================================================
  Future<void> _showUnifiedPsiDialog(
      PsiResult psi, {
        required bool isServerSide,
      }) async {
    // 既存のポップアップ実装をそのまま使用
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
        title: const Text('PSI Ring Match'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bug_report),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DebugPage()),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _statusRow(),
          const SizedBox(height: 20),
          _bleCard(),
          const SizedBox(height: 20),
          _familiarCheckCard(),
        ],
      ),
    );
  }

  // ==========================================================
  Widget _statusRow() {
    return Row(
      children: [
        _statusBadge(
          Icons.bluetooth,
          '近接記録(BLE)',
          _bleRunning,
        ),
        const SizedBox(width: 8),
        _statusBadge(
          Icons.cloud_sharp,
          '顔見知り確認(gRPC)',
          _grpcRunning,
        ),
      ],
    );
  }

  // ==========================================================
  // ★ 修正: 左側（タイトル+説明）を縦にグループ化し、右にトグル
  // ==========================================================
  Widget _bleCard() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 左: タイトル + 説明（グループ）
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.bluetooth, size: 22),
                    const SizedBox(width: 8),
                    Text(
                      '近くの人を記録',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '近くの端末と匿名で鍵を交換します',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),

          const SizedBox(width: 12),

          // 右: トグル
          Switch(
            value: _bleRunning,
            onChanged: (_) => _toggleBleExchange(),
          ),
        ],
      ),
    );
  }

  Widget _familiarCheckCard() {
    return _card(
      icon: Icons.cloud,
      title: '顔見知りチェック',
      description: '過去に会ったことがあるかを確認します',
      trailing: const SizedBox.shrink(),
      extra: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),

          // ===== 使い方（現行UI準拠）=====
          Text(
            '使い方',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '・一方の端末で「QRを表示する」をタップします\n'
                '・もう一方の端末で「QRを読み取る」をタップします',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          ),

          const SizedBox(height: 14),

          _grpcRunning ? _qrDisplaySection() : _qrActionButtons(),
        ],
      ),
    );
  }

  // ==========================================================
  Widget _qrActionButtons() {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            icon: const Icon(Icons.qr_code),
            label: const Text('QRを表示する'),
            onPressed: _showQr,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('QRを読み取る'),
            onPressed: _scanQr,
          ),
        ),
      ],
    );
  }

  Widget _qrDisplaySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'このQRを相手に見せてください',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.grey.shade800,
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: QrImageView(
            data: _qrPayload,
            size: 180,
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: OutlinedButton.icon(
            onPressed: _stopQr,
            icon: const Icon(Icons.close),
            label: const Text('表示を終了'),
          ),
        ),
      ],
    );
  }

  // ==========================================================
  Widget _card({
    required IconData icon,
    required String title,
    required String description,
    required Widget trailing,
    Widget? extra,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 22),
              const SizedBox(width: 8),
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              trailing,
            ],
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          if (extra != null) extra,
        ],
      ),
    );
  }

  Widget _statusBadge(IconData icon, String label, bool active) {
    final color = active ? Colors.green.shade800 : Colors.grey.shade600;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: active ? Colors.green.shade100 : Colors.grey.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
