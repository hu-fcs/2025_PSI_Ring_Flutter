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
import '../grpc/psi_client.dart'; // ★追加
import 'dart:async';


enum NicknameSchedulePeriod { oneDay, oneWeek, oneMonth }

extension NicknameSchedulePeriodExt on NicknameSchedulePeriod {
  String get label => switch (this) {
    NicknameSchedulePeriod.oneDay => '1日',
    NicknameSchedulePeriod.oneWeek => '1週間',
    NicknameSchedulePeriod.oneMonth => '1か月',
  };

  Duration get duration => switch (this) {
    NicknameSchedulePeriod.oneDay => const Duration(days: 1),
    NicknameSchedulePeriod.oneWeek => const Duration(days: 7),
    NicknameSchedulePeriod.oneMonth => const Duration(days: 30),
  };
}

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

  final _ownerNameController = TextEditingController(text: '自分の端末');
  final _hostController = TextEditingController(text: '192.168.0.10'); // 相手IP
  final _portController = TextEditingController(text: '50051');

  NicknameSchedulePeriod _selectedPeriod = NicknameSchedulePeriod.oneDay;

  final _grpcClient = PsiGrpcClient();
  // 近くにいる友達一覧（最後に見えた時刻も保持）
  final Map<String, int> _nearbyLastSeenMs = {};
  final Map<String, bool> _nearbyAuth = {};
  Timer? _nearbyGcTimer;

  static const Duration _nearbyTtl = Duration(seconds: 30); // 30秒見えなければ消す
  // 認証OKを保持する時間
  static const Duration _authHold = Duration(seconds: 30);
  // friendLabelごとに「最後にOKになった時刻」を保存
  final Map<String, int> _authOkLastMs = {};


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
                  const SizedBox(height: 8),
                  Text(
                    _nearbyLastSeenMs.isEmpty
                        ? '近くの友達: なし'
                        : '近くの友達: ${_nearbyLastSeenMs.length}人',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (_nearbyLastSeenMs.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ..._nearbyLastSeenMs.keys.map((name) {
                      final ok = _nearbyAuth[name] ?? false;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Icon(ok ? Icons.verified : Icons.person, size: 18),
                            const SizedBox(width: 8),
                            Expanded(child: Text(name)),
                            Text(ok ? 'OK' : '未認証', style: const TextStyle(fontSize: 12)),
                          ],
                        ),
                      );
                    }),
                  ],
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
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('将来ニックネームの共有（送信側）',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),

                  TextField(
                    controller: _ownerNameController,
                    decoration: const InputDecoration(labelText: '相手に表示される自分の名前'),
                  ),
                  const SizedBox(height: 8),

                  TextField(
                    controller: _hostController,
                    decoration: const InputDecoration(labelText: '相手のIP（gRPCサーバ）'),
                  ),
                  const SizedBox(height: 8),

                  TextField(
                    controller: _portController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'ポート'),
                  ),
                  const SizedBox(height: 12),

                  InputDecorator(
                    decoration: const InputDecoration(
                      labelText: '共有期間',
                      helper: Text(
                        'この期間分の将来ニックネームを生成し、相手端末へ共有します。',
                        softWrap: true,
                      ),
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<NicknameSchedulePeriod>(
                        value: _selectedPeriod,
                        isExpanded: true,
                        items: NicknameSchedulePeriod.values
                            .map((p) => DropdownMenuItem(value: p, child: Text(p.label)))
                            .toList(),
                        onChanged: (p) => setState(() => _selectedPeriod = p!),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),


                  ElevatedButton(
                    onPressed: _generateAndShare,
                    child: const Text('生成して共有'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
  @override
  void initState() {
    super.initState();
    _ble.onFriendDetected = _onFriendDetected;

    _nearbyGcTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final expired = _nearbyLastSeenMs.entries
          .where((e) => now - e.value > _nearbyTtl.inMilliseconds)
          .map((e) => e.key)
          .toList();

      if (expired.isEmpty) return;
      setState(() {
        for (final k in expired) {
          _nearbyLastSeenMs.remove(k);
          _nearbyAuth.remove(k);
        }
      });
    });
  }
  @override
  void dispose() {
    _nearbyGcTimer?.cancel();
    _ownerNameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }


  void _onFriendDetected(String friendLabel, bool authenticated) {
    if (!mounted) return;

    final now = DateTime.now().millisecondsSinceEpoch;

    // 初回だけSnackBar（連発防止）
    final isNew = !_nearbyLastSeenMs.containsKey(friendLabel);

    // 以前の認証状態
    final prevAuth = _nearbyAuth[friendLabel] ?? false;

    // 署名検証が通った“本当のOK”が来たら、OK時刻を更新
    if (authenticated) {
      _authOkLastMs[friendLabel] = now;
    }

    // OK保持中かどうか（保持中は false が来てもOK扱いにする）
    final lastOk = _authOkLastMs[friendLabel] ?? 0;
    final keepOk = (now - lastOk) < _authHold.inMilliseconds;

    // 表示上の認証状態
    final effectiveAuth = authenticated || keepOk;

    // ★昇格判定（未認証→認証OKになった瞬間）
    // これは “authenticated=true” が来た瞬間だけを昇格としたいので、そのまま
    final isUpgrade = !prevAuth && authenticated;

    setState(() {
      _nearbyLastSeenMs[friendLabel] = now;

      // 降格は「保持時間が切れた時」だけ許可
      _nearbyAuth[friendLabel] = effectiveAuth;
    });

    // 昇格のときに出す
    if (isNew || isUpgrade) {
      final msg = authenticated
          ? '近くで $friendLabel さんを検出しました ✅'
          : '近くで $friendLabel さん候補を検出しました';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _generateAndShare() async {
    final owner = _ownerNameController.text.trim();
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim());

    if (owner.isEmpty || host.isEmpty || port == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名前 / ホスト / ポートを正しく入力してください')),
      );
      return;
    }

    const slot = Duration(minutes: 10);
    final period = _selectedPeriod.duration;

    try {
      // 1) 期間分の将来ニックネームを生成
      final schedule = await _keyService.generateFutureNicknameList(
        period: period,
        slot: slot,
      );

      // 2) gRPC 送信（nickname_schedule JSON）
      await _grpcClient.connect(host,port); // 既存実装に合わせて
      await _grpcClient.sendNicknameSchedule(
        ownerName: owner,
        period: period,
        slot: slot,
        schedule: schedule,
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('共有しました：${_selectedPeriod.label}（${schedule.length}件）')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('共有に失敗: $e')),
      );
    }
  }
}
