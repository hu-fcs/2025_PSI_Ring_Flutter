import 'dart:async';
import 'dart:io'; // Platform
import 'dart:math' show min;
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart'; // ChangeNotifier
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'nickname.dart';
import 'mutual_authentication.dart';
import '../db/friends_dao.dart';

/// BLEのCentral機能．
/// このアプリのサービスをスキャンし，
/// 見つけた端末に接続してニックネームを交換する．
/// 将来ニックネーム中に相手のニックネームを見つけたら，
/// 相互認証して，UIに通知する．UIは友人として画面に表示する．
///
/// bluetooth_low_energy パッケージを使う．
class BleCentralManager extends ChangeNotifier {
  bool _isScanning = false;
  bool _isAvailable = false;
  bool _verbose = false; // debugPrintが多すぎるので verbose = true の時だけ出力するように
  final QueueList<({DiscoveredEventArgs arg, DateTime t})> _discoveredPeripherals = QueueList<({DiscoveredEventArgs arg, DateTime t})>();
  final PriorityQueue<({int rssi, Peripheral peripheral})> _waitingPeripherals = HeapPriorityQueue<({int rssi, Peripheral peripheral})>(
      (a, b) => b.rssi.compareTo(a.rssi)
    );

  /// スキャン中．ChangeNotifierでUIに変化を通知
  bool get isScanning => _isScanning;
  /// BLE使用可能．ChangeNotifierでUIに変化を通知
  bool get isAvailable => _isAvailable;
  /// 発見したPeripheral
  QueueList<({DiscoveredEventArgs arg, DateTime t})> get discoveredPeripherals => _discoveredPeripherals;

  /// 同時最大接続peripheral数
  static final int maxConnections = 1;
  /// 接続中のPeripheral（connectを呼び出したがretrieveConnectedPeripheralsには反映されていないものを含む）．同時接続数の上限を決めるため．
  Set<UUID> _connectingPeripherals = Set<UUID>();
  /// 接続中のPeripheral（connectのコールバックがあったものだけ）
  Set<UUID> _connectedPeripherals = Set<UUID>();

  StreamSubscription? _stateSubscription;
  StreamSubscription? _discoveredSubscription;
  StreamSubscription? _connectionStateSubscription;

  /// アプリ起動時にBLEのCentralを初期化
  void initialize() {
    // await _requestPermissions(); // exchange_page.dart: ExchangePageクラスで実施済み

    // BLEが利用可能かチェック・監視
    _stateSubscription = CentralManager().stateChanged.listen((arg) {
      if (kDebugMode) print("BleCentralManager CentralManager().stateChanged.listen: ${arg.state}");
      _isAvailable = (arg.state == BluetoothLowEnergyState.poweredOn);
      notifyListeners(); // UIに通知
    });
  }

  /// このオブジェクトを破棄．
  ///
  /// 購読をやめる．
  @override
  void dispose() async {
    await stopScan();
    // await _localNicknameStreamSubscription?.cancel();

    _stateSubscription?.cancel();
    _discoveredSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    super.dispose(); // ChangeNotifierクラス
  }

  /// スキャン開始
  Future<void> startScan() async {
    if (_isScanning) return;

    _discoveredPeripherals.clear(); // ToDo: clearするタイミングはここだけでいいのか．
    _discoveredSubscription = CentralManager().discovered.listen(_onDeviceDiscovered);
    _connectionStateSubscription = CentralManager().connectionStateChanged.listen((eventArgs) async {
      if (eventArgs.state == ConnectionState.connected) {
        await _onDeviceConnected(eventArgs.peripheral);
      } else { // ConnectionState.disconnected
        await _onDeviceDisconnected(eventArgs.peripheral);
      }
    });
    await CentralManager().startDiscovery(serviceUUIDs: [BleNickname.serviceUuid]);
    _isScanning = true;
    notifyListeners();
  }

  /// スキャン停止
  Future<void> stopScan() async {
    if (!_isScanning) return;

    if (kDebugMode) debugPrint('BLE stopScan');
    await CentralManager().stopDiscovery();
    await _discoveredSubscription?.cancel();
    _discoveredPeripherals.clear();

    _isScanning = false;
    notifyListeners();
  }

  /// ペリフェラル発見時のコールバック．
  /// startDiscoveryでBleNickname.serviceUuidを含むperipheralのみ見つかる．
  /// 以前に発見していればスキップし，初めてならば接続．
  Future<void> _onDeviceDiscovered(DiscoveredEventArgs eventArg) async {
    final Peripheral peripheral = eventArg.peripheral;
    if (_discoveredPeripherals.any((arg) => peripheral.uuid == arg.arg.peripheral.uuid)) {
      // if (kDebugMode) debugPrint("already added ${DateTime.now()}");
      return; // 以前に発見している
    }
    if (_connectingPeripherals.contains(peripheral.uuid)) {
      // 同じデバイスに対して_onDeviceDiscoveredが複数回呼ばれることがエミューレータであったので，1回目以外はスキップ．
      return;
    }
    final now = DateTime.now();
    await _printConnectedPeripherals('_onDeviceDiscovered');
    _discoveredPeripherals.add((arg: eventArg, t: now));

    if (_connectingPeripherals.length < maxConnections) { // 同時に7台まで接続．1ならテストで1台ずつ接続
      if (kDebugMode) debugPrint('_onDeviceDiscovered: ${peripheral.uuid} $now');
      await _connect(peripheral);
    } else { // 後ほど _onDeviceDisconnectedで接続するのでrssiの大きいものから並んだ優先度付きキューに追加する
      if (kDebugMode) debugPrint('_onDeviceDiscovered: ${peripheral.uuid} wait');
      _waitingPeripherals.add((rssi: eventArg.rssi, peripheral: eventArg.peripheral));
    }
  }

  /// ペリフェラルに接続する．_onDeviceDiscoveredと_onDeviceDisconnectedから呼ばれる．
  Future<void> _connect(Peripheral peripheral) async {
    _connectingPeripherals.add(peripheral.uuid);
    try {
      await CentralManager().connect(peripheral);
      if (kDebugMode) debugPrint("_connect: ${peripheral.uuid}");
    } catch (e) {
      if (kDebugMode) debugPrint('BLE Error: _connect $e');
    }
  }

  /// 切断した（同じPeripheralへの接続に対して2，3回呼ばれることがある）
  Future<void> _onDeviceDisconnected(Peripheral peripheral) async {
    _connectingPeripherals.remove(peripheral.uuid);
    bool f = _connectedPeripherals.contains(peripheral.uuid);
    _connectedPeripherals.remove(peripheral.uuid);
    if (kDebugMode) {
      await _printConnectedPeripherals('_onDeviceDisconnected:');
      debugPrint('_onDeviceDisconnected: _connectedPeripherals.contains(${peripheral.uuid}) -> $f, waited: ${_waitingPeripherals.length}');
    }
    // 接続を待たせているPeripheralがあれば接続する
    if (f && _waitingPeripherals.length > 0) {
      final element = _waitingPeripherals.removeFirst();
      if (kDebugMode) debugPrint('_onDeviceDisconnected: connect next peripheral: ${element.peripheral.uuid}');
      await _connect(element.peripheral);
    }
  }

  /// 接続した（同じPeripheralへの接続に対して2，3回呼ばれることがある）
  Future<void> _onDeviceConnected(Peripheral peripheral) async {
    final centralManager = CentralManager();
    final bleNickname = BleNickname();

    // 同一Peripheralに対して重複して呼び出された場合は何もしない
    if (_connectedPeripherals.contains(peripheral.uuid))
      return;
    _connectedPeripherals.add(peripheral.uuid);

    GATTCharacteristic? nicknameCharacteristic;
    GATTCharacteristic? authenticationCharacteristic;
    try {
      // 特性（Characteristic）を探す
      final services = await centralManager.discoverGATT(peripheral);
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
        await centralManager.disconnect(peripheral);
        return; // finallyは実行される
      }

      // MTUの確認（Androidでは20バイトを33バイトに増やす．iOSでは自動的に増やすらしいので不要）
      final len1 = await centralManager.getMaximumWriteLength(peripheral, type: GATTCharacteristicWriteType.withoutResponse);
      if (Platform.isAndroid && len1 < 1 + 64) {
        final len2 = await centralManager.requestMTU(peripheral, mtu: 1 + 64); // 相互認証のヘッダ1+レスポンス64バイト
        if (kDebugMode && _verbose) debugPrint('MTU write: $len1 -> $len2 (Peripheral ${peripheral.uuid})');
      } else {
        if (kDebugMode && _verbose) debugPrint('MTU write: $len1 (Peripheral ${peripheral.uuid})');
      }

      // Peripheralのニックネームを読み込み
      final now = DateTime.now();
      final remoteNickname = await centralManager.readCharacteristic(
          peripheral, nicknameCharacteristic);
      if (kDebugMode) debugPrint('_onDeviceConnected read. remote nickname: ${BleNickname.nickname2string(remoteNickname, len: 9)}, peripheral: ${peripheral.uuid}, $now');
      await bleNickname.addRemote(remoteNickname, now, peripheralUuid: peripheral.uuid);

      // CentralのニックネームをPeripheralに書き込み
      final Uint8List localNickname = bleNickname.localNickname;
      // 書き込み可能なMTUを取得．33バイトに満たない場合は先頭から一部の不完全なニックネームを送信．
      final len = await centralManager.getMaximumWriteLength(peripheral, type: GATTCharacteristicWriteType.withResponse);
      if (kDebugMode && len < localNickname.length) debugPrint('WARNING: MTU is too short.  getMaximumWriteLength $len');
      await centralManager.writeCharacteristic(
        peripheral, nicknameCharacteristic,
        value: localNickname.sublist(0, min(len, localNickname.length)),
        type: GATTCharacteristicWriteType.withResponse,
      );
      if (kDebugMode) debugPrint('_onDeviceConnected write. local nickname: ${BleNickname.nickname2string(localNickname, len: 9)}, peripheral: ${peripheral.uuid}');

      // 将来ニックネームリストにremoteNicknameが含まれているときは認証に進む（山口 賢紘, 2026年2月，卒業論文）
      // まずは，将来ニックネームリストにremoteNicknameが含まれているか探す
      final labels = await FriendsDao.instance.findFriendLabelsByPubkey(remoteNickname);
      // ToDo: 複数のlabel（名前）が見つかるのは不自然では？同じニックネームを複数人が使っているということになる？
      // 最初に見つかったlabelのみ使うように変更した．
      if (labels.isNotEmpty && len >= 1 + 64) { // 相互認証．Write MTUが十分でなければ相互認証は省略
        // 候補として通知（authenticated=false）
        final friendLabel = labels.first;
        // ToDo: 認証が終わってから表示したら十分では？稲葉くんの意見
        BleNickname().onFriendDetected?.call(friendLabel, false); // ToDo: central側しか表示していない
         // 相互認証
        final success = await BleMutualAuthentication().startAuthentication(
            peripheral, authenticationCharacteristic,
            centralPriKey: BleNickname().lastLocalPrivateKey,
            peripheralPubKey: remoteNickname, peripheralName: friendLabel);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('BLE Error: _onDeviceConnected $e');
    } finally {
      try {
        await CentralManager().disconnect(peripheral);
      } catch (e) {
        if (kDebugMode) debugPrint('BLE Error: _onDeviceConnected disconnect $e');
      }
    }
  }

  /// 動作確認用に
  Future<void> _printConnectedPeripherals(String funcname) async {
    if (kDebugMode && _verbose) {
      List<Peripheral> list = await CentralManager().retrieveConnectedPeripherals();
      debugPrint('$funcname _printConnectedPeripherals c:${_connectingPeripherals.length} w:${_waitingPeripherals.length} r:${list.length}');
      for (Peripheral peripheral in list) {
        debugPrint('_printConnectedPeripherals ${peripheral.uuid}');
      }
    }
  }

/// OSやユーザにBLEを使う許可をもらう．同等のものがExchangePageクラスに実装されている．
/* Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      // Android 12 (API 31) 以降とそれ未満で必要な権限をまとめてリクエスト
      Map<Permission, PermissionStatus> statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location, // Android 11以前の端末や念のための位置情報
      ].request();

      // デバッグ確認用（すべての権限が許可されたか）
      final isGranted = statuses.values.every((status) => status.isGranted);
      if (kDebugMode) debugPrint("Bluetooth 許可 (Android): $isGranted");

    } else if (Platform.isIOS) {
      // iOS用のBluetooth権限リクエスト
      PermissionStatus status = await Permission.bluetooth.request();
      if (status.isPermanentlyDenied) {
        // 設定画面を開いてユーザーに許可を促す
        openAppSettings();
      }
      if (kDebugMode) debugPrint("Bluetooth 許可 (iOS Central): ${status}");
    }
  }*/
}
