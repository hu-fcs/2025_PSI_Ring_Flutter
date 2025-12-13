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
  // 共通鍵 → 16進文字列
  // ==========================================================
  String _bytesToHex(Uint8List b) =>
      b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

  // ==========================================================
  // 時刻フォーマット
  // ==========================================================
  String _fmtTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String z(int v) => v.toString().padLeft(2, '0');
    return '${d.year}/${z(d.month)}/${z(d.day)} ${z(d.hour)}:${z(d.minute)}';
  }

  // ==========================================================
  // 会った回数 / 初回 / 最終回 を計算
  // ==========================================================
  Future<({
  int count,
  int? first,
  int? last,
  int? firstLat,
  int? firstLon,
  int? lastLat,
  int? lastLon,
  })> _calcMeetStats(List<String> commonKeys) async {
    if (commonKeys.isEmpty) {
      return (
      count: 0,
      first: null,
      last: null,
      firstLat: null,
      firstLon: null,
      lastLat: null,
      lastLon: null,
      );
    }

    final db = await DatabaseHelper.getDatabase();
    final rows = await db.query(
      'generated_keys',
      columns: ['pubkey_ecd', 'generate_time', 'lat', 'lon'],
    );

    // pubkey(hex) -> { time, lat, lon }
    final Map<String, Map<String, int?>> myKeys = {
      for (final r in rows)
        _bytesToHex(r['pubkey_ecd'] as Uint8List): {
          'time': r['generate_time'] as int,
          'lat': r['lat'] as int?,
          'lon': r['lon'] as int?,
        }
    };

    final List<Map<String, int?>> hits = [];
    for (final k in commonKeys) {
      final v = myKeys[k];
      if (v != null) hits.add(v);
    }

    if (hits.isEmpty) {
      return (
      count: 0,
      first: null,
      last: null,
      firstLat: null,
      firstLon: null,
      lastLat: null,
      lastLon: null,
      );
    }

    // time 昇順
    hits.sort((a, b) => a['time']!.compareTo(b['time']!));

    final first = hits.first;

    // 「最後」は前日以前を優先（なければ最新）
    final now = DateTime.now();
    final today0 = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;

    final last = hits.lastWhere(
          (h) => h['time']! < today0,
      orElse: () => hits.last,
    );

    return (
    count: hits.length,
    first: first['time'],
    last: last['time'],
    firstLat: first['lat'],
    firstLon: first['lon'],
    lastLat: last['lat'],
    lastLon: last['lon'],
    );
  }

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
                    _timeRow(
                      icon: Icons.first_page,
                      label: '初めて会った時間',
                      value: stats.first == null ? 'N/A' : _fmtTime(stats.first!),
                    ),
                    _timeRow(
                      icon: Icons.place,
                      label: '初めて会った場所',
                      value: (stats.firstLat == null || stats.firstLon == null)
                          ? 'N/A'
                          : '${stats.firstLat! / 1e6}, ${stats.firstLon! / 1e6}',
                    ),


                    const SizedBox(height: 8),

                    // 最後に
                    _timeRow(
                      icon: Icons.history,
                      label: '最後に会った時間',
                      value: stats.last == null ? 'N/A' : _fmtTime(stats.last!),
                    ),
                    _timeRow(
                      icon: Icons.place,
                      label: '最後に会った場所',
                      value: (stats.lastLat == null || stats.lastLon == null)
                          ? 'N/A'
                          : '${stats.lastLat! / 1e6}, ${stats.lastLon! / 1e6}',
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
  Widget _timeRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final theme = Theme.of(context);

        final labelStyle = theme.textTheme.bodyMedium!;
        final valueStyle =
        theme.textTheme.bodyMedium!.copyWith(fontWeight: FontWeight.w500);

        // ---- value（日時）の横幅を計測 ----
        final valuePainter = TextPainter(
          text: TextSpan(text: value, style: valueStyle),
          maxLines: 1,
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();

        // アイコン＋余白の固定幅
        const iconSize = 18.0;
        const iconGap = 6.0;
        const betweenGap = 8.0;

        final fixedWidth =
            iconSize + iconGap + betweenGap + valuePainter.width;

        // ---- label が1行で収まるかを計測 ----
        final labelPainter = TextPainter(
          text: TextSpan(text: label, style: labelStyle),
          maxLines: 1,
          ellipsis: '…',
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(
          maxWidth: (constraints.maxWidth - fixedWidth)
              .clamp(0.0, constraints.maxWidth),
        );

        final fitsOneLine = !labelPainter.didExceedMaxLines;

        if (fitsOneLine) {
          // ===== 横並び（1行で収まる場合）=====
          return Row(
            children: [
              Icon(icon, size: iconSize),
              const SizedBox(width: iconGap),
              Expanded(
                child: Text(label, style: labelStyle),
              ),
              const SizedBox(width: betweenGap),
              Text(value, style: valueStyle),
            ],
          );
        }

        // ===== 縦並び（ラベル → 次行右寄せで日時）=====
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: iconSize),
                const SizedBox(width: iconGap),
                Expanded(
                  child: Text(label, style: labelStyle),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Text(value, style: valueStyle),
            ),
          ],
        );
      },
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
            '・一方の端末で「QRを表示する」をタップ\n'
            '・もう一方の端末で「QRを読み取る」をタップ',
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
            label: const Text('QRを表示'),
            onPressed: _showQr,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('QRを読取'),
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
            size: 200,
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
