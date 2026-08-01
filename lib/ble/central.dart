import 'dart:async';
import 'dart:io'; // Platform
import 'dart:math' show min;
import 'package:flutter/foundation.dart'; // ChangeNotifier
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'nickname.dart';
import 'mutual_authentication.dart';
import '../friend.dart';
import '../key_management.dart';

/// BLEのCentral機能．
/// このアプリのサービスをスキャンし，
/// 見つけた端末に接続してニックネームを交換する．
/// 将来ニックネーム中に相手のニックネームを見つけたら，
/// 相互認証して，UIに通知する．UIは友人として画面に表示する．
///
/// bluetooth_low_energy パッケージを使う．
class BleCentralManager extends ChangeNotifier {
  // シングルトン
  static final BleCentralManager _instance = BleCentralManager._internal();
  factory BleCentralManager() => _instance;
  BleCentralManager._internal();

  bool _isScanning = false;
  bool _isAvailable = false;
  final bool _verbose = false; // debugPrintが多すぎるので verbose = true の時だけ出力するように

  /// BLE使用可能．ChangeNotifierでUIに変化を通知
  bool get isAvailable => _isAvailable;

  /// スキャン中．ChangeNotifierでUIに変化を通知
  bool get isScanning => _isScanning;
  /// 最後の発見時間
  DateTime? _lastDiscoveredTime;
  DateTime? get lastDiscoveredTime => _lastDiscoveredTime;
  /// スキャンの自動停止タイマー
  Timer? _autoStopTimer;

  /// 接続ペリフェラルのリスト
  /// CentralManager().retrieveConnectedPeripherals() で定期的に取得．
  /// _onDeviceDiscoveredで参照して接続数をmaxConnections以下に制限するために使う．
  /// UIに接続ペリフェラル数を表示するために使う．
  List<Peripheral> _connectedPeripherals = [];
  List<Peripheral> get connectedPeripherals => _connectedPeripherals;
  /// 接続ペリフェラル数を更新するタイマー
  Timer? _retrieveConnectedPeripheralsTimer;

  /// 同時最大接続peripheral数
  var maxConnections = 1;
  /// スキャンの一時停止から回復する時のタイマー
  Timer? _resumeTimer;
  /// BLEで発見したペリフェラルで処理中のものを記録するためのSet
  /// 同じペリフェラルに同時に接続しないようにするために使う
  final Set<Peripheral> _inProcessPeripherals = {};

  StreamSubscription? _stateSubscription;
  StreamSubscription? _discoveredSubscription;
  StreamSubscription? _connectionStateSubscription;

  /// アプリ起動時にBLEのCentralを初期化
  void initialize() {
    // await _requestPermissions(); // exchange_page.dart: ExchangePageクラスで実施済み

    // BLEが利用可能かチェック・監視
    final cm = CentralManager();
    _isAvailable = (cm.state == BluetoothLowEnergyState.poweredOn);
    notifyListeners(); // UIに通知
    _stateSubscription = cm.stateChanged.listen((arg) {
      if (kDebugMode) print("BleCentralManager CentralManager().stateChanged.listen: ${arg.state}");
      _isAvailable = (arg.state == BluetoothLowEnergyState.poweredOn);
      notifyListeners(); // UIに通知
    });
  }

  /// このオブジェクトを破棄．
  ///
  /// 購読をやめる．
  @override
  void dispose() {
    CentralManager().stopDiscovery(); // await stopScan();

    _stateSubscription?.cancel();
    _discoveredSubscription?.cancel();
    _connectionStateSubscription?.cancel();

    _retrieveConnectedPeripheralsTimer?.cancel();
    _resumeTimer?.cancel();
    _autoStopTimer?.cancel();
    super.dispose(); // ChangeNotifierクラス
  }

  /// スキャン開始
  Future<void> startScan({Duration? autoStop}) async {
    if (_isScanning) return;

    final kms = KeyManagementService();
    await kms.init();
    await kms.start(byCentral: true);
    final cm = CentralManager();
    _discoveredSubscription = cm.discovered.listen(_onDeviceDiscovered);
    _connectionStateSubscription = cm.connectionStateChanged.listen((eventArgs) async {
      if (eventArgs.state == ConnectionState.connected) {
        await _onDeviceConnected(eventArgs.peripheral);
      } else { // ConnectionState.disconnected
        await _onDeviceDisconnected(eventArgs.peripheral);
      }
    });
    _inProcessPeripherals.clear();

    _connectedPeripherals = await cm.retrieveConnectedPeripherals()
        .onError((e, st) { return []; });
    for (final peripheral in _connectedPeripherals) {
      cm.disconnect(peripheral).onError((e, st) {
        if (kDebugMode) debugPrint('BLE startScan. ERROR disconect(${peripheral.shortUuid})');
      });
    }
    _connectedPeripherals = await cm.retrieveConnectedPeripherals()
        .onError((e, st) { return []; });
    maxConnections = _connectedPeripherals.length + 1;
    if (kDebugMode) debugPrint('BLE startScan. cps:${_connectedPeripherals.length} max:$maxConnections');

    // 接続ペリフェラルのリストを10秒ごとに更新するタイマー．主にテスト用．UIに接続ペリフェラル数を表示するために使う．
    _retrieveConnectedPeripheralsTimer = Timer.periodic(Duration(seconds: 10), (timer) async {
      _connectedPeripherals = await cm.retrieveConnectedPeripherals();
      if (kDebugMode) debugPrint('BLE central timer. cps ${_connectedPeripherals.length}');
      notifyListeners(); // UIに通知
    });

    if (Platform.isIOS) { // iOSはdiscovered.listenとstartDiscoveryの間で少し待つ（100msは短いのかも）
      await Future.delayed(Duration(milliseconds: 500));
    }

    try {
      await cm.startDiscovery(serviceUUIDs: [BleNickname.serviceUuid]);
      _isScanning = true;
      notifyListeners();
      if (autoStop != null) {
        _autoStopTimer?.cancel();
        _autoStopTimer = Timer(autoStop, () async {
          await stopScan();
        });
      }
    }  catch (e) {
      if (kDebugMode) debugPrint('BLE Error: startScan CentralManager.startDiscovery $e');
    }
  }

  /// スキャン停止
  Future<void> stopScan() async {
    if (!_isScanning) return;

    final cm = CentralManager();
    if (kDebugMode) debugPrint('BLE stopScan');
    try {
      await cm.stopDiscovery();
      _connectedPeripherals = await cm.retrieveConnectedPeripherals();
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint('BLE Error: stopScan CentralManager $e');
    }
    try {
      await KeyManagementService().stop(byCentral: true);
    } catch (e) {
      if (kDebugMode) debugPrint('BLE Error: stopScan KeyManagementService $e');
    }

    _isScanning = false;

    await _discoveredSubscription?.cancel();
    _discoveredSubscription = null;
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;

    _retrieveConnectedPeripheralsTimer?.cancel();
    _retrieveConnectedPeripheralsTimer = null;
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _autoStopTimer?.cancel();
    _autoStopTimer = null;
    _lastDiscoveredTime = null;

    notifyListeners();
  }

  /// ペリフェラル発見時のコールバック．
  /// startDiscoveryでBleNickname.serviceUuidを含むperipheralのみ見つかる．
  /// 以前に発見していればスキップし，初めてならば接続．
  Future<void> _onDeviceDiscovered(DiscoveredEventArgs eventArg) async {
    final now = DateTime.now();
    final Peripheral peripheral = eventArg.peripheral;

    // 発見した時刻を
    peripheral.setDiscoveredAt(now);

    // 接続を試みているperipheralはスキップする．
    if (_inProcessPeripherals.contains(peripheral)) {
      // if (kDebugMode) debugPrint('_onDeviceDiscovered: skipped ${peripheral.uuid} $now duration: ${duration.inSeconds}s');
      return;
    }
    _inProcessPeripherals.add(peripheral); // remove(peripheral)するまで同じperipheralが見つかっても接続しない

    // 相手に関わらず発見した時刻をUIに通知．通知の間隔を1秒以上あける．
    if (_lastDiscoveredTime == null || now.difference(_lastDiscoveredTime!).inSeconds > 1) {
      _lastDiscoveredTime = now;
      notifyListeners();
    }

    // 同じ端末に接続する間隔を開ける
    final nextConnectAt = peripheral.nextConnectAt;
    if (nextConnectAt != null && nextConnectAt.isAfter(now)) {
      if (kDebugMode && _verbose) debugPrint('_onDeviceDiscovered: skipped ${peripheral.shortUuid} $now'
          ' nextConnectAt: ${nextConnectAt.difference(now).inMilliseconds} ms'
          ' discoveredCount ${peripheral.discoveredCount}');
      _inProcessPeripherals.remove(peripheral);
      return;
    }

    // 同時接続する数を抑える．
    if (_connectedPeripherals.length >= maxConnections) { // 同時に7台まで接続．1ならテストで1台ずつ接続
      if (kDebugMode && _verbose) debugPrint('_onDeviceDiscovered: skipped ${peripheral.shortUuid} $now'
          ' cps ${_connectedPeripherals.length}'
          ' discoveredCount ${peripheral.discoveredCount}');
      _inProcessPeripherals.remove(peripheral);
      return;
    }
    // この後 _connect()で_connectedPeripheralsを更新する間，接続数を仮に増やして同時接続数を抑える．
    if (! _connectedPeripherals.contains(peripheral)) {
      _connectedPeripherals.add(peripheral);
    }

    if (kDebugMode) debugPrint('_onDeviceDiscovered: connecting ${peripheral.shortUuid} $now'
        ' nextConnectAt: ${nextConnectAt?.difference(now).inMilliseconds} ms'
        ' discoveredCount ${peripheral.discoveredCount}');
    peripheral.setConnectAt(now);
    await _connect(peripheral);
  }

  /// ペリフェラルに接続する．_onDeviceDiscoveredと_onDeviceDisconnectedから呼ばれる．
  Future<void> _connect(Peripheral peripheral) async {
    final cm = CentralManager();
    try {
      await cm.connect(peripheral);
      _connectedPeripherals = await cm.retrieveConnectedPeripherals();
      if (kDebugMode) {
        debugPrint("_connect: ${peripheral.uuid} cps: ${_connectedPeripherals.length}");
      }
    } catch (e) {
      peripheral.setErrorAt(DateTime.now());
      await cm.disconnect(peripheral).onError((e, st) {});
      _inProcessPeripherals.remove(peripheral);
      if (kDebugMode) debugPrint('BLE Error: _connect ${peripheral.shortUuid} $e');
    }
  }

  /// 切断した
  Future<void> _onDeviceDisconnected(Peripheral peripheral) async {
    _inProcessPeripherals.remove(peripheral);

    _connectedPeripherals = await CentralManager().retrieveConnectedPeripherals();
    notifyListeners();
    if (kDebugMode) {
      final f = _connectedPeripherals.contains(peripheral);
      debugPrint('_onDeviceDisconnected: _connectedPeripherals.contains(${peripheral.shortUuid}) -> $f');
    }
  }

  /// 接続した．ニックネームを交換し，友達なら相互認証する．
  Future<void> _onDeviceConnected(Peripheral peripheral) async {
    final cm = CentralManager();
    final blePeerList = BlePeerList();

    GATTCharacteristic? nicknameCharacteristic;
    GATTCharacteristic? authenticationCharacteristic;
    try {
      // 特性（Characteristic）を探す
      final services = await cm.discoverGATT(peripheral);
      for (var service in services) {
        if (service.uuid == BleNickname.serviceUuid) {
          for (var characteristic in service.characteristics) {
            if (characteristic.uuid == BleNickname.nicknameCharacteristicUuid) {
              nicknameCharacteristic = characteristic;
            } else if (characteristic.uuid == BleMutualAuthentication.authenticationCharacteristicUuid) {
              authenticationCharacteristic = characteristic;
            }
          }
          break;
        }
      }

      // 特定が見つからないので，読み書きせずに切断する
      if (nicknameCharacteristic == null || authenticationCharacteristic == null) {
        if (kDebugMode) debugPrint('BLE Error: _onDeviceConnected no characteristics n: $nicknameCharacteristic a: $authenticationCharacteristic');
        await cm.disconnect(peripheral);
        return; // finallyは実行される
      }

      // MTUの確認（Androidでは20バイトを33バイトに増やす．iOSでは自動的に増やすらしいので不要）
      final len1 = await cm.getMaximumWriteLength(peripheral, type: GATTCharacteristicWriteType.withResponse);
      if (Platform.isAndroid && len1 < BleMutualAuthentication.maxPayloadSize) {
        final len2 = await cm.requestMTU(peripheral, mtu: BleMutualAuthentication.maxPayloadSize + 5); // 相互認証のヘッダ1+レスポンス64バイト + ヘッダ5バイト?（iPhoneでは3バイト?）
        if (kDebugMode && _verbose) debugPrint('MTU write: $len1 -> $len2 (Peripheral ${peripheral.shortUuid})');
      } else {
        if (kDebugMode && _verbose) debugPrint('MTU write: $len1 (Peripheral ${peripheral.shortUuid})');
      }

      // Peripheralのニックネームを読み込み
      final now = DateTime.now();
      final remoteNickname = await cm.readCharacteristic(peripheral, nicknameCharacteristic);
      if (kDebugMode) {
        final shortNicknameStr = remoteNickname.hexStr(len: 5);
        debugPrint('_onDeviceConnected read. remote nickname: $shortNicknameStr'
            ', peripheral: ${peripheral.shortUuid}, $now');
      }
      await blePeerList.addRemote(peripheral, remoteNickname, now);

      // 書き込み可能なMTUを取得．33バイトに満たない場合は先頭から一部の不完全なニックネームを送信．
      final len = await cm.getMaximumWriteLength(peripheral, type: GATTCharacteristicWriteType.withResponse);
      if (kDebugMode) debugPrint('_onDeviceConnected MaximumWriteLength $len $now');

      // CentralのニックネームをPeripheralに書き込み
      final localKeyPair = KeyManagementService().currentLocalKeyPair; // キーの更新を開始していないとnullになるので，start()しておくこと
      final localNickname = localKeyPair.publicKey; // キーの更新を開始していないとnullになるので，start()しておくこと
      await cm.writeCharacteristic(
        peripheral, nicknameCharacteristic,
        value: localNickname.sublist(0, min(len, localNickname.length)),
        type: GATTCharacteristicWriteType.withResponse,
      );
      if (kDebugMode) {
        final shortNicknameStr = localNickname.hexStr(len: 5);
        debugPrint('_onDeviceConnected write. local nickname: $shortNicknameStr'
            ', peripheral: ${peripheral.shortUuid}');
      }
      peripheral.setNicknameExchangedAt(now);

      // 将来ニックネームリストにremoteNicknameが含まれているときは認証に進む（山口 賢紘, 2026年2月，卒業論文）
      // まずは，将来ニックネームリストにremoteNicknameが含まれているか探す
      //final labels = await FriendsDao.instance.findFriendLabelsByPubkey(remoteNickname);
      final friend = await FriendList().getFriendByNickname(remoteNickname);
      if (friend != null &&
          len >= BleMutualAuthentication.maxPayloadSize) { // 相互認証．Write MTUが十分でなければ相互認証は省略
        // 候補として通知（authenticated=false）
        // ToDo: 認証が終わってから表示したら十分では？稲葉くんの意見
        await blePeerList.onFriendDetected(peripheral, friend, false);

        if (peripheral.isAuthenticated) { // ToDo: すでに認証済みでも再認証している．再認証をしない方法を考えること．
          if (kDebugMode) debugPrint('_onDeviceConnected: reauthenticate ${peripheral.shortUuid}');
        }

        // 相互認証
        await BleMutualAuthentication().startAuthentication(
            peripheral, authenticationCharacteristic,
            centralKeyPair: localKeyPair,
            peripheralPubKey: remoteNickname, friend: friend);
      }
    } catch (e) {
      peripheral.setErrorAt(DateTime.now());
      if (kDebugMode) debugPrint('BLE Error: _onDeviceConnected $e');
    } finally {
      await cm.disconnect(peripheral).onError((e, st) {});
      // disconnectより後，addRemoteより後に_discoveredPeripheralsから削除
      _inProcessPeripherals.remove(peripheral);

      _connectedPeripherals = await cm.retrieveConnectedPeripherals()
          .onError((e, st) { return []; });
      notifyListeners();
    }
  }
}
