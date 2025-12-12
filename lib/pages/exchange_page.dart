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
          '顔見知り確認のための鍵がありません。\nまずは BLE 近接交換を行ってください。',
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

  Future<bool> _ensureBluetoothEnabled() async {
    try {
      final current = await FlutterBluePlus.adapterState.first;
      if (current == BluetoothAdapterState.on) return true;

      await FlutterBluePlus.turnOn();

      final state = await FlutterBluePlus.adapterState
          .firstWhere((s) => s == BluetoothAdapterState.on)
          .timeout(const Duration(seconds: 30));

      return state == BluetoothAdapterState.on;
    } catch (_) {
      return false;
    }
  }

  Future<void> _toggleBleExchange() async {
    if (!_bleRunning) {
      if (!await _ensureBlePermissions()) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Bluetooth の権限が必要です')));
        }
        return;
      }

      await _ensureLocationPermissions();

      final enabled = await _ensureBluetoothEnabled();
      if (!enabled) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Bluetooth を ON にできませんでした')));
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
  /// gRPC サーバ起動
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

    server.service.onPsiFinished.listen((PsiResult psi) {
      if (!psi.isFamiliar) {
        _showUnifiedPsiDialog(psi, isServerSide: true);
      }
    });

    server.service.onRingAuthenticated.listen((PsiResult psi) {
      _showUnifiedPsiDialog(psi, isServerSide: true);
    });

    setState(() {
      _grpcServer = server;
      _serverIp = ip;
      _serverPort = port;
    });
  }

  Future<void> _stopGrpcServer() async {
    final s = _grpcServer;
    _grpcServer = null;
    setState(() {});
    await s?.stop();
  }

  // ==========================================================
  /// Scanner → クライアント結果
  // ==========================================================
  Future<void> _openScannerPage() async {
    if (!await _requireKeyWarning()) return;

    final result = await Navigator.pushNamed(context, '/scanner');
    if (result is PsiResult) {
      _showUnifiedPsiDialog(result, isServerSide: false);
    }
  }

  // ==========================================================
  /// ---- ここから追加ロジック ----
  // ==========================================================
  String _bytesToHex(Uint8List b) =>
      b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

  String _fmtTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String z(int v) => v.toString().padLeft(2, '0');
    return '${d.year}/${z(d.month)}/${z(d.day)} ${z(d.hour)}:${z(d.minute)}';
  }

  Future<({int count, int? first, int? last})> _calcMeetStats(
      List<String> commonKeys) async {
    if (commonKeys.isEmpty) return (count: 0, first: null, last: null);

    final db = await DatabaseHelper.getDatabase();
    final rows = await db.query(
      'generated_keys',
      columns: ['pubkey_ecd', 'generate_time'],
    );

    final map = <String, int>{
      for (final r in rows)
        _bytesToHex(r['pubkey_ecd'] as Uint8List):
        r['generate_time'] as int
    };

    final times = <int>[];
    for (final k in commonKeys) {
      final t = map[k];
      if (t != null) times.add(t);
    }

    if (times.isEmpty) return (count: 0, first: null, last: null);

    times.sort();
    final first = times.first;

    final now = DateTime.now();
    final today0 =
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;

    final beforeToday = times.where((t) => t < today0).toList();
    final last = beforeToday.isNotEmpty ? beforeToday.last : times.last;

    return (count: times.length, first: first, last: last);
  }

  // ==========================================================
  /// 結果ダイアログ
  // ==========================================================
  Future<void> _showUnifiedPsiDialog(
      PsiResult psi, {
        required bool isServerSide,
      }) async {
    final familiar = psi.isFamiliar;
    final stats = await _calcMeetStats(psi.commonKeys);

    final titleColor = familiar ? Colors.green : Colors.red;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ======================
              // タイトル
              // ======================
              Row(
                children: [
                  Icon(
                    familiar ? Icons.favorite : Icons.help_outline,
                    color: titleColor,
                    size: 28,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    familiar ? '顔見知りです' : '見知らぬ人です',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: titleColor,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),

              // ======================
              // 重要情報（上）
              // ======================
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: familiar
                      ? Colors.green.withOpacity(0.08)
                      : Colors.grey.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 会った回数（強調）
                    Text(
                      '会った回数',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${stats.count} 回',
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                      ),
                    ),

                    const SizedBox(height: 16),

                    // 初めて
                    Row(
                      children: [
                        const Icon(Icons.first_page, size: 18),
                        const SizedBox(width: 6),
                        const Text('初めて会った時間'),
                        const Spacer(),
                        Text(
                          stats.first == null
                              ? 'N/A'
                              : _fmtTime(stats.first!),
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),

                    const SizedBox(height: 8),

                    // 最後に
                    Row(
                      children: [
                        const Icon(Icons.history, size: 18),
                        const SizedBox(width: 6),
                        const Text('最後に会った時間'),
                        const Spacer(),
                        Text(
                          stats.last == null
                              ? 'N/A'
                              : _fmtTime(stats.last!),
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // ======================
              // デバッグ情報（下）
              // ======================
              Divider(color: Colors.grey.shade300),

              const SizedBox(height: 8),

              Text(
                'デバッグ情報',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                ),
              ),

              const SizedBox(height: 8),

              _debugRow('共通鍵数', '${psi.commonKeys.length} 件'),
              _debugRow(
                '自身の生成鍵との一致',
                familiar ? 'あり' : 'なし',
              ),
              _debugRow(
                '判定側',
                isServerSide ? 'サーバ側' : 'クライアント側',
              ),

              const SizedBox(height: 20),

              // ======================
              // OKボタン
              // ======================
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

// ----------------------------
// デバッグ用の1行UI
// ----------------------------
  Widget _debugRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(
            '$label:',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade500,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade500,
            ),
          ),
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
          // BLE
          Card(
            shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                        icon: Icon(
                            _bleRunning ? Icons.stop : Icons.play_arrow),
                        label: Text(_bleRunning ? '停止' : '開始'),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _bleRunning ? '実行中' : '停止中',
                        style: TextStyle(
                            color:
                            _bleRunning ? Colors.green : Colors.grey),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // gRPC
          Card(
            shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                        onChanged: (on) =>
                        on ? _startGrpcServer() : _stopGrpcServer(),
                      ),
                      Text(_grpcRunning ? '稼働中' : '停止中'),
                      const Spacer(),
                      IconButton(
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
                      child: QrImageView(data: _qrPayload, size: 200),
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
