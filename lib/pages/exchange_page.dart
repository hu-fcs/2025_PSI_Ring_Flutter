// lib/pages/exchange_page.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../ble/nickname.dart';
import '../db/database_helper.dart';
import '../grpc/grpc_common.dart';
import '../grpc/grpc_server.dart';
import 'debug_page.dart';

/// 近接記録（BLE）と顔見知り確認（gRPC）を操作する画面。
///
/// - BLE: 周辺端末へ仮名（公開鍵断片）を広告し，同時に周囲の仮名を収集する。
/// - gRPC: PSI とリング署名によって顔見知り判定を行い，結果を表示する。
class ExchangePage extends StatefulWidget {
  const ExchangePage({super.key});

  @override
  State<ExchangePage> createState() => _ExchangePageState();
}

class _ExchangePageState extends State<ExchangePage> {
  final _ble = BleNickname();
  bool get _bleRunning => _ble.isRunning;

  PsiGrpcServer? _grpcServer;
  bool get _grpcRunning => _grpcServer?.isRunning == true;
  String? _serverIp;
  int _serverPort = 50051;

  final _db = DatabaseHelper();

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
      // if (await FlutterBluePlus.adapterState.first ==] BluetoothAdapterState.on) {
      if (await CentralManager().state == BluetoothLowEnergyState.unknown) {
        await CentralManager().stateChanged.firstWhere(
                (args) => args.state != BluetoothLowEnergyState.unknown);
      }
      if (await CentralManager().state == BluetoothLowEnergyState.poweredOn) {
        return true;
      }
      // await FlutterBluePlus.turnOn(); BTをオンにするメソッドが bluetooth_low_energyパッケージにはないので，
      // ToDo: Bluetoothが使用できないとメッセージを出すべきだ
      // CentralManager().showAppSettings();
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _toggleBleExchange() async {
    if (! await _ensureBlePermissions() || ! await _ensureBluetoothEnabled()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bluetooth を使用できません')),
        );
      }
      return;
    }
    await _ble.toggleExchange();
    if (mounted) setState(() {});
  }

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

  Future<void> _scanQr() async {
    if (!await _requireKeyWarning()) return;

    final result = await Navigator.pushNamed(context, '/scanner');
    if (result is PsiResult) {
      _showUnifiedPsiDialog(result, isServerSide: false);
    }
  }

  String _bytesToHex(Uint8List b) =>
      b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

  String _fmtTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String z(int v) => v.toString().padLeft(2, '0');
    return '${d.year}/${z(d.month)}/${z(d.day)} ${z(d.hour)}:${z(d.minute)}';
  }

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

    hits.sort((a, b) => a['time']!.compareTo(b['time']!));

    final first = hits.first;

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
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '初めて会った',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                stats.first == null
                                    ? 'N/A'
                                    : _fmtTime(stats.first!),
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.place, size: 18),
                          label: const Text('場所'),
                          onPressed:
                          (stats.firstLat != null && stats.firstLon != null)
                              ? () => _openExternalMap(
                            stats.firstLat!,
                            stats.firstLon!,
                          )
                              : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '最後に会った',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                stats.last == null
                                    ? 'N/A'
                                    : _fmtTime(stats.last!),
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.place, size: 18),
                          label: const Text('場所'),
                          onPressed:
                          (stats.lastLat != null && stats.lastLon != null)
                              ? () => _openExternalMap(
                            stats.lastLat!,
                            stats.lastLon!,
                          )
                              : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Divider(color: Colors.grey.shade300),
              Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  initiallyExpanded: false,
                  title: Text(
                    'デバッグ情報',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  trailing: Icon(
                    Icons.expand_more,
                    size: 20,
                    color: Colors.grey.shade600,
                  ),
                  children: [
                    _debugRow('判定側', isServerSide ? 'サーバ側' : 'クライアント側'),
                    _debugRowWidget(
                      _mathLabel(main: 'S', sub: 'A', suffix: 'クライアント鍵数'),
                      '${psi.saKeyCount} 件',
                    ),
                    _debugRowWidget(
                      _mathLabel(main: 'S', sub: 'B', suffix: 'サーバ鍵数'),
                      '${psi.sbKeyCount} 件',
                    ),
                    _debugRowWidget(
                      _mathLabel(main: 'I', suffix: '共通集合サイズ'),
                      '${psi.commonKeys.length} 件',
                    ),
                    _debugRowWidget(
                      _mathLabel(main: 'R', suffix: 'リングサイズ'),
                      '${psi.ringSize} 件',
                    ),
                    _debugRow('自身の鍵との一致', familiar ? 'あり' : 'なし'),
                    if (!isServerSide) ...[
                      const SizedBox(height: 6),
                      Divider(color: Colors.grey.shade300),
                      const SizedBox(height: 6),
                      _debugRow('SQLite鍵読み込み時間', '${psi.dbLoadTimeMs} ms'),
                      _debugRow('PSI時間', '${psi.psiTimeMs} ms'),
                      _debugRow('リング選択時間', '${psi.ringSelectTimeMs} ms'),
                      _debugRow('リング署名・検証時間', '${psi.ringSigTimeMs} ms'),
                      _debugRow('総時間', '${psi.totalTimeMs} ms'),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 10),
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

  static const MethodChannel _mapChannel = MethodChannel('app.maps');

  Future<void> _openExternalMap(int latE6, int lonE6) async {
    final lat = latE6 / 1e6;
    final lon = lonE6 / 1e6;

    try {
      await _mapChannel.invokeMethod('openMap', {'lat': lat, 'lon': lon});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('地図アプリを開けませんでした: $e')),
      );
    }
  }

  Widget _mathLabel({
    required String main,
    String? sub,
    required String suffix,
  }) {
    final subText = (sub ?? '').trim();

    if (subText.isEmpty) {
      return Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: '|'),
            TextSpan(text: main),
            const TextSpan(text: '| '),
            TextSpan(text: suffix),
          ],
        ),
      );
    }

    return Text.rich(
      TextSpan(
        children: [
          const TextSpan(text: '|'),
          TextSpan(text: main),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Transform.translate(
              offset: const Offset(0, 3),
              child: Text(
                subText,
                style: const TextStyle(fontSize: 6),
              ),
            ),
          ),
          const TextSpan(text: '| '),
          TextSpan(text: suffix),
        ],
      ),
    );
  }

  Widget _debugRowWidget(Widget label, String value) {
    final s = TextStyle(fontSize: 11, color: Colors.grey.shade600);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          DefaultTextStyle.merge(style: s, child: label),
          const Spacer(),
          Text(value, style: s),
        ],
      ),
    );
  }

  Widget _debugRow(String label, String value) {
    final s = TextStyle(fontSize: 11, color: Colors.grey.shade600);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text('$label:', style: s),
          const Spacer(),
          Text(value, style: s),
        ],
      ),
    );
  }

  String get _qrPayload => jsonEncode({
    'ip': _serverIp ?? '',
    'port': _serverPort,
  });

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

  Widget _statusRow() {
    return Row(
      children: [
        _statusBadge(Icons.bluetooth, '近接記録(BLE)', _bleRunning),
        const SizedBox(width: 8),
        _statusBadge(Icons.cloud_sharp, '顔見知り確認(gRPC)', _grpcRunning),
      ],
    );
  }

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
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.bluetooth, size: 22),
                    const SizedBox(width: 8),
                    Text('近くの人を記録',
                        style: Theme.of(context).textTheme.titleMedium),
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
          ListenableBuilder(
            listenable: _ble,
            builder: (context, child) {
              return Switch(
                value: _ble.isRunning,
                onChanged: (_) => _toggleBleExchange(),
              );
            },
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
        Text(
          _serverIp!,
          style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.grey.shade800,
          ),
        ),
        Text(
          _serverPort.toString(),
          style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.grey.shade800,
          ),
        ),
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
              Text(title, style: Theme.of(context).textTheme.titleMedium),
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
