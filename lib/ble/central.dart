import 'dart:async';
import 'dart:io'; // Platform
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart'; // ChangeNotifier
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
// import 'package:permission_handler/permission_handler.dart';
import 'nickname.dart';

/// BLEのCentral機能．
/// 自身のニックネーム
///
/// bluetooth_low_energy パッケージを使う．
class BleCentralManager extends ChangeNotifier {
  bool _isScanning = false;
  bool _isAvailable = false;
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

  // Uint8List _centralNickname = Uint8List(33); // BleNickname().localNickname に置き換え

  /// アプリ起動時にBLEのCentralを初期化
  void initialize() async {
    // ニックネーム関する初期化
    // _centralNickname = Uint8List.fromList(BleNickname().lastNickname);
    /*_localNicknameStreamSubscription = BleNickname().localNicknameStream.listen((nickname) async { // ニックネームの更新
      _discoveredPeripherals.clear(); // 自身のニックネームが変わったので，これまでに接続てニックネームをつたえた相手を忘れて，再接続する．（これでは広告というよりプッシュ）
      _centralNickname = nickname;
      if (kDebugMode) print('central stream nickname ${BleNickname.nickname2string(_centralNickname)}');
    });

    // await _requestPermissions(); // exchange_page.dart: ExchangePageクラスで実施済み

    // BLEが利用可能かチェック・監視
    _stateSubscription = CentralManager().stateChanged.listen((arg) {
      _isAvailable = arg.state == BluetoothLowEnergyState.poweredOn;
      notifyListeners(); // UIに通知
    });*/
  }

  /// OSやユーザにBLEを使う許可をもらう
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
      if (kDebugMode) print("Bluetooth 許可 (Android): $isGranted");

    } else if (Platform.isIOS) {
      // iOS用のBluetooth権限リクエスト
      PermissionStatus status = await Permission.bluetooth.request();
      if (status.isPermanentlyDenied) {
        // 設定画面を開いてユーザーに許可を促す
        openAppSettings();
      }
      if (kDebugMode) print("Bluetooth 許可 (iOS Central): ${status}");
    }
  }*/

  /// スキャン開始
  Future<void> startScan() async {
    if (_isScanning) return;

    _discoveredPeripherals.clear();
    _isScanning = true;
    notifyListeners();

    _discoveredSubscription = CentralManager().discovered.listen(_onDeviceDiscovered);
    _connectionStateSubscription = CentralManager().connectionStateChanged.listen((eventArgs) async {
      if (eventArgs.state == ConnectionState.connected) {
        await _onDeviceConnected(eventArgs.peripheral);
      } else { // ConnectionState.disconnected
        await _onDeviceDisconnected(eventArgs.peripheral);
      }
    });
    await CentralManager().startDiscovery(serviceUUIDs: [BleNickname.serviceUuid]);
  }

  /// ペリフェラル発見時のコールバック．
  /// startDiscoveryでBleNickname.serviceUuidを含むperipheralのみ見つかる．
  /// 以前に発見していればスキップし，初めてならば接続．
  Future<void> _onDeviceDiscovered(DiscoveredEventArgs eventArg) async {
    final Peripheral peripheral = eventArg.peripheral;
    if (_discoveredPeripherals.any((arg) => peripheral.uuid == arg.arg.peripheral.uuid)) {
      // if (kDebugMode) print("already added ${DateTime.now()}");
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
      if (kDebugMode) print('_onDeviceDiscovered: ${peripheral.uuid} $now');
      await _connect(peripheral);
    } else { // 後ほど _onDeviceDisconnectedで接続するのでrssiの大きいものから並んだ優先度付きキューに追加する
      if (kDebugMode) print('_onDeviceDiscovered: ${peripheral.uuid} wait');
      _waitingPeripherals.add((rssi: eventArg.rssi, peripheral: eventArg.peripheral));
    }
  }

  Future<void> _connect(Peripheral peripheral) async {
    _connectingPeripherals.add(peripheral.uuid);
    try {
      await CentralManager().connect(peripheral);
      if (kDebugMode) print("_connect: ${peripheral.uuid}");
    } catch (e) {
      if (kDebugMode) print('BLE Error: _connect $e');
    }
  }

  /// 切断した（同じPeripheralへの接続に対して2，3回呼ばれることがある）
  Future<void> _onDeviceDisconnected(Peripheral peripheral) async {
    _connectingPeripherals.remove(peripheral.uuid);
    bool f = _connectedPeripherals.contains(peripheral.uuid);
    _connectedPeripherals.remove(peripheral.uuid);
    if (kDebugMode) {
      await _printConnectedPeripherals('_onDeviceDisconnected:');
      print('_onDeviceDisconnected: ${peripheral.uuid} $f');
    }
    // 接続を待たせているPeripheralがあれば接続する
    if (f && _waitingPeripherals.length > 0) {
      final element = _waitingPeripherals.removeFirst();
      if (kDebugMode) print('_onDeviceDisconnected: connect next peripheral: ${element.peripheral.uuid}');
      await _connect(element.peripheral);
    }
  }

  /// 接続した（同じPeripheralへの接続に対して2，3回呼ばれることがある）
  Future<void> _onDeviceConnected(Peripheral peripheral) async {
    // 同一Peripheralに対して重複して呼び出された場合は何もしない
    if (_connectedPeripherals.contains(peripheral.uuid))
      return;
    _connectedPeripherals.add(peripheral.uuid);

    GATTCharacteristic? nicknameReadCharacteristic;
    GATTCharacteristic? nicknameWriteCharacteristic;
    try {
      // MTUの確認（Androidでは20バイトを33バイトに増やす．iOSでは自動的に増やすらしいので不要）
      final len1 = await CentralManager().getMaximumWriteLength(peripheral, type: GATTCharacteristicWriteType.withoutResponse);
      if (Platform.isAndroid && len1 < 33) {
        final len2 = await CentralManager().requestMTU(peripheral, mtu: 33);
        if (kDebugMode) print('MTU write: $len1 -> $len2 (Perpheral ${peripheral.uuid})');
      } else {
        if (kDebugMode) print('MTU write: $len1 (Perpheral ${peripheral.uuid})');
      }

      // 特性（Characteristic）を探す
      final services = await CentralManager().discoverGATT(peripheral);
      for (var service in services) {
        if (service.uuid == BleNickname.serviceUuid) {
          for (var characteristic in service.characteristics) {
            if (characteristic.uuid == BleNickname.nicknameReadCharacteristicUuid) {
              nicknameReadCharacteristic = characteristic;
            } else if (characteristic.uuid == BleNickname.nicknameWriteCharacteristicUuid) {
              nicknameWriteCharacteristic = characteristic;
            }
          }
          break;
        }
      }

      // 特定が見つからないので，読み書きせずに切断する
      if (nicknameReadCharacteristic == null || nicknameWriteCharacteristic == null) {
        if (kDebugMode) print('BLE Error: _onDeviceConnected no characteristics r: $nicknameReadCharacteristic w: $nicknameWriteCharacteristic');
        await CentralManager().disconnect(peripheral);
        return; // finallyは実行される
      }

      // Peripheraのニックネームを読み込み
      final now = DateTime.now();
      final remoteNickname = await CentralManager().readCharacteristic(peripheral, nicknameReadCharacteristic);
      if (kDebugMode) print('_onDeviceConnected read. length: ${remoteNickname.length}, nickname: ${BleNickname.nickname2string(remoteNickname)}, peripheral: ${peripheral.uuid}, $now');
      BleNickname().addRemote(remoteNickname, now, peripheralUuid: peripheral.uuid, );
      // CentralのニックネームをPeripheralに書き込み
      int len = await CentralManager().getMaximumWriteLength(peripheral, type: GATTCharacteristicWriteType.withoutResponse);
      if (kDebugMode) print('getMaximumWriteLength $len');

      // CentralのニックネームをPeripheralに書き込み
      // nickname.dartなしで試す場合 var localNickname = Uint8List.fromList('0abcdefghabcdefghabcdefghabcdefgh'.codeUnits); data = data.sublist(0, 18);
      var localNickname = BleNickname().localNickname;
      await CentralManager().writeCharacteristic(
        peripheral,
        nicknameWriteCharacteristic,
        value: localNickname,
        type: GATTCharacteristicWriteType.withoutResponse,
      );
      if (kDebugMode) print('_onDeviceConnected write. Length: ${localNickname.length}), nickname: ${BleNickname.nickname2string(localNickname)}, peripheral: ${peripheral.uuid}');

      // UIに通知．ChangeNotifierクラス
      notifyListeners();
    } catch (e) {
      if (kDebugMode) print('BLE Error: _onDeviceConnected  $e');
    } finally {
      try {
        await CentralManager().disconnect(peripheral);
      } catch (e) {
        if (kDebugMode) print('BLE Error: _onDeviceConnected disconnect $e');
      }
    }
  }

  /// スキャン停止
  Future<void> stopScan() async {
    if (!_isScanning) return;

    if (kDebugMode) print('stopScan');
    await CentralManager().stopDiscovery();
    await _discoveredSubscription?.cancel();
    _isScanning = false;
    _discoveredPeripherals.clear();
    notifyListeners();
  }

  /// 動作確認用に
  Future<void> _printConnectedPeripherals(String funcname) async {
    if (kDebugMode) {
      List<Peripheral> list = await CentralManager().retrieveConnectedPeripherals();
      print('$funcname _printConnectedPeripherals c:${_connectingPeripherals.length} w:${_waitingPeripherals.length} r:${list.length}');
      for (Peripheral peripheral in list) {
        print('_printConnectedPeripherals ${peripheral.uuid}');
      }
    }
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
    super.dispose();
  }
}
