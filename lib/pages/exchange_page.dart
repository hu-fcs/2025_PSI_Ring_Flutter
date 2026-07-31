// lib/pages/exchange_page.dart

import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart'; //import Shared Preferences

import '../ble/nickname.dart';
import '../key_management.dart';
import '../db/database_helper.dart';
import '../grpc/grpc_common.dart';
import '../grpc/grpc_server.dart';
import '../grpc/grpc_client.dart';
import 'debug_page.dart';

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

  GrpcServer? _grpcServer;
  bool get _grpcRunning => _grpcServer?.isRunning == true;
  String? _serverIp;
  int _serverPort = 50051;
  int _serverOobCode = 0;

  final _db = DatabaseHelper();

  Future<bool> _hasAnyKey() async => (await _db.getTotalKeyCount()) > 0;

  final _ownerNameController = TextEditingController(text: '自分の端末');
  final _hostController = TextEditingController(text: '192.168.0.10'); // 相手IP
  final _portController = TextEditingController(text: '50051');
  final _nonceController = TextEditingController();

  NicknameSchedulePeriod _selectedPeriod = NicknameSchedulePeriod.oneDay;

  final _grpcClient = GrpcClient();
  // 近くにいる友達一覧（最後に見えた時刻も保持）
  final Map<String, int> _nearbyLastSeenMs = {};
  final Map<String, bool> _nearbyAuth = {};
  Timer? _nearbyGcTimer;

  static const Duration _nearbyTtl = Duration(seconds: 30); // 30秒見えなければ消す
  // 認証OKを保持する時間
  static const Duration _authHold = Duration(seconds: 30);
  // friendLabelごとに「最後にOKになった時刻」を保存
  final Map<String, int> _authOkLastMs = {};

  @override
  void initState() {
    super.initState();

    //保存されている設定を読み込む
    _loadSettings();

    BlePeerList().onFriendDetectedCallback = _onFriendDetected;

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

    // 広告をUIの準備ができてから自動的に開始
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Timer(const Duration(seconds: 3), () async {
        _toggleBleExchange();
      });
    });
  }

  // よく使うTextStyle．カスタマイズした Theme.of(context).textTheme
  late TextStyle _textThemeBodySmallGreyShade600; // 説明のテキストで使うスタイル

  @override
  void didChangeDependencies() { // 画面が立ち上がった時などに呼び出される．
    super.didChangeDependencies();
    _textThemeBodySmallGreyShade600 = Theme.of(context).textTheme.bodySmall
        !.copyWith(color: Colors.grey.shade600); // 説明のテキストで使われることが多い．
  }

  //設定をShared preferencesへ保存
  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(
      'owner_name',
      _ownerNameController.text,
    );

    await prefs.setInt(
      'period',
      _selectedPeriod.index,
    );
  }

  //Shared preferencesから設定を読み込む
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();

    _ownerNameController.text =
        prefs.getString('owner_name') ?? '自分の端末';

    final period = prefs.getInt('period');

    if (period != null) {
      _selectedPeriod = NicknameSchedulePeriod.values[period];
    }

    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _nearbyGcTimer?.cancel();
    _ownerNameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _nonceController.dispose();
    super.dispose();
  }

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
      // Android: wlan0（J9110実機  や Androidエミュレータ 36.6.11 など）
      // iOS:     en0（らしい）ToDo: 要確認
      // メモ：Androidエミュレータの eth0 はエミュレータ間で同じアドレスになっているので使わない．
      for (final i in interfaces) {
        if (i.name == 'wlan0' || i.name == 'en0') {
          for (final a in i.addresses) {
            if (a.type == InternetAddressType.IPv4) return a.address;
          }
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('ERROR in _getLocalWifiIp $e'); // PlatformExceptionにする？
    }
    return null;
  }

  Future<void> _showQr() async {
    if (!await _requireKeyWarning()) return;
    if (_grpcRunning) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('すでにgRPCサーバが起動しています')),
        );
      }
      return;
    }

    final ip = await _getLocalWifiIp();
    if (ip == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ネットワークが利用できません')),
        );
      }
      return;
    }

    final server = GrpcServer();
    server.addListener(_onGrpcServerStateChanged);
    final port = await server.start(port: _serverPort);
    final oobNonce = server.oobNonce;

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
      _serverOobCode = oobNonce;
    });
  }

  Future<void> _stopQr() async {
    final s = _grpcServer;
    setState(() {
      _grpcServer = null; // stop前にnullにする
    });
    await s?.stop();
  }

  void _onGrpcServerStateChanged() { // GrpcServerのnotifyListeners()のコールバック
    if (_grpcServer?.server == null) { // サーバが停止している
      final msg = _grpcServer?.reason;
      if (msg != null) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('gRPCサーバ終了：$msg')));
      }
      setState(() {
        _grpcServer = null; // stop前にnullにする
      });
    }
  }

  Future<void> _scanQr() async {
    if (!await _requireKeyWarning()) return;

    final result = await Navigator.pushNamed(context, '/scanner');
    if (result is PsiResult) {
      _showUnifiedPsiDialog(result, isServerSide: false);
    }
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
    //現在の設定を保存
    await _saveSettings();

    final owner = _ownerNameController.text.trim();
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text);
    final nonce = int.tryParse(_nonceController.text);

    if (owner.isEmpty || host.isEmpty || port == null || nonce == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名前 / ホスト / ポート / 確認コードを正しく入力してください')));
      return;
    }

    final slot = KeyManagementService().slot;
    final period = _selectedPeriod.duration;

    try {
      // 1) gRPC 送信（nickname_schedule JSON）
      await _grpcClient.connect(host, port, nonce);
      await _grpcClient.exchangeNicknameSchedule(
        ownerName: owner,
        period: period,
        slot: slot,
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('共有しました：${_selectedPeriod.label}（${period.inDays}日）')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('共有に失敗: $e')),
      );
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
                    style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold, color: titleColor)),
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
                    Text('会った回数',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text('${stats.count} 回',
                        style: Theme.of(context).textTheme.headlineLarge),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('初めて会った',
                                  style: Theme.of(context).textTheme.titleSmall),
                              const SizedBox(height: 4),
                              Text(stats.first == null
                                  ? 'N/A'
                                  : _fmtTime(stats.first!),
                                  style: Theme.of(context).textTheme.bodyLarge),
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
                              Text('最後に会った',
                                  style: Theme.of(context).textTheme.titleSmall),
                              const SizedBox(height: 4),
                              Text(stats.last == null
                                  ? 'N/A'
                                  : _fmtTime(stats.last!),
                                  style: Theme.of(context).textTheme.bodyLarge),
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
                  title: Row(
                    children: [
                      const Icon(Icons.bug_report),
                      Text('デバッグ情報',
                          style: _textThemeBodySmallGreyShade600),
                    ]
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          DefaultTextStyle.merge(
              style: _textThemeBodySmallGreyShade600,
              child: label),
          const Spacer(),
          Text(value, style: _textThemeBodySmallGreyShade600),
        ],
      ),
    );
  }

  Widget _debugRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text('$label:', style: _textThemeBodySmallGreyShade600),
          const Spacer(),
          Text(value, style: _textThemeBodySmallGreyShade600),
        ],
      ),
    );
  }
  // QRコードのサイズを小さくしたいのでJSONからコロン区切りに．_onDetectと一緒に変更
  String get _qrPayload =>
      'FCS:${(_serverIp ?? '').padRight(15)}:$_serverPort:$_serverOobCode';

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
          _friendCard(),
          const SizedBox(height: 20),
          _familiarCheckCard(),
          const SizedBox(height: 20),
          _futureNicknameShareCard(),
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
                Text('近くの端末と匿名のニックネームを交換します',
                    style: _textThemeBodySmallGreyShade600),
                // style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                const SizedBox(height: 8),
                ListenableBuilder(
                  listenable: _ble,
                  builder: (context, child) {
                    final stateStr = _ble.currentStateString();
                    return Text('ニックネーム：$stateStr');
                  },
                ),
                ListenableBuilder(
                  listenable: _ble.advertiser,
                  builder: (context, child) {
                    final s = _ble.advertiser.lastRequestTime?.shortStr();
                    return Text('接続された：$s');
                  },
                ),
                ListenableBuilder(
                  listenable: _ble.scanner,
                  builder: (context, child) {
                    final s = _ble.scanner.lastDiscoveredTime?.shortStr();
                    return Text('広告を受信：$s');
                  },
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

  Widget _friendCard() {
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
              Icon(Icons.person, size: 22),
              const SizedBox(width: 8),
              Text(_nearbyLastSeenMs.isEmpty
                  ? '近くの友達：なし'
                  : '近くの友達：${_nearbyLastSeenMs.length}人',
                  style: Theme.of(context).textTheme.titleMedium),
            ],
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
                    Text(ok ? 'OK' : '未認証',
                        style: Theme.of(context).textTheme.bodySmall),
                        // style: const TextStyle(fontSize: 12)),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _familiarCheckCard() {
    return _card(
      icon: Icons.history, // Icons.cloud,
      title: '顔見知りチェック',
      description: '過去に会ったことがあるかを確認します',
      trailing: const SizedBox.shrink(),
      extra: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          Text('使い方',
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 6),
          Text('・一方の端末で「QRを表示する」をタップ\n'
              '・もう一方の端末で「QRを読み取る」をタップ',
              style: _textThemeBodySmallGreyShade600),
                  // ?.copyWith(color: Colors.grey.shade700)),
          const SizedBox(height: 14),
          _grpcRunning ? _qrDisplaySection() : _qrActionButtons(),
        ],
      ),
    );
  }

  Widget _futureNicknameShareCard() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.handshake, size: 22), // Icons.sync
              const SizedBox(width: 8),
              Text('将来ニックネームの共有（送信側）',
                  style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
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

          TextField(
            controller: _nonceController,
            decoration: const InputDecoration(labelText: '確認コード'),
          ),
          const SizedBox(height: 8),

          InputDecorator(
            decoration: InputDecoration(
              labelText: '共有期間',
              helper: Text('この期間分の将来ニックネームを生成し、相手端末へ共有します。',
                  style: _textThemeBodySmallGreyShade600),
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
        Text('このQRコードを相手に見せてください',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 10),
        Center(
          child: QrImageView(
            data: _qrPayload,
            size: 200,
          ),
        ),
        const SizedBox(height: 10),
        Text('IPアドレス：${_serverIp!}',
            style: _textThemeBodySmallGreyShade600),
        Text('ポート番号：${_serverPort.toString()}',
            style: _textThemeBodySmallGreyShade600),
        Text('確認コード：${_serverOobCode.toString()}',
            style: _textThemeBodySmallGreyShade600),
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
          Text(description,
              style: _textThemeBodySmallGreyShade600),
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
          Text(label,
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(fontWeight: FontWeight.bold, color: color)),
              // style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
        ],
      ),
    );
  }
}
