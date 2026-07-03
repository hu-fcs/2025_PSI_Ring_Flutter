// flutterでbluetooth_low_energyパッケージを使ってペリフェラルのクラスを作ってください．32バイトnotifyの特性だけからなるサービスを広告してください．subscribeしたらすぐにnotifyするサービスにしてください．main.dartからこのクラスを呼び出してください．

/*
Android: AndroidManifest.xml に BLUETOOTH_ADVERTISE や BLUETOOTH_CONNECT などのパーミッション定義、および実行時パーミッションの要求コードが実運用では必要になります。iOS: Info.plist に NSBluetoothAlwaysUsageDescription および NSBluetoothPeripheralUsageDescription の鍵（説明文）を追加してください。
*/

import 'dart:async';
// import 'dart:io'; // Platform
import 'package:flutter/foundation.dart'; // ChangeNotifier
// import 'dart:convert'; // utf8.decode
import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
// import 'package:permission_handler/permission_handler.dart';
import 'nickname.dart';
import 'mutual_authentication.dart';

/// BLEでニックネームを広告するクラス
class BlePeripheral extends ChangeNotifier {
  bool _isAdvertising = false;
  /// 広告中．ChangeNotifierでUIに変化を通知
  bool get isAdvertising => _isAdvertising;
  /// サービス追加を最初の1回だけにする．ToDo: アプリがバックグラウンドから戻った時はtrueに戻るので，2回以上呼ばれることがある．Android
  bool _addService = true;

  StreamSubscription? _characteristicReadRequestedSubscription;
  StreamSubscription? _characteristicWriteRequestedSubscription;
  StreamSubscription? _characteristicNotifyStateChangedSubscription;
  StreamSubscription? _mtuChangedSubscription;
  StreamSubscription? _connectionStateChangedSubscription;
  StreamSubscription? _stateChangedSubscription;
  // StreamSubscription? _descriptorReadRequestedSubscription;
  // StreamSubscription? _descriptorWriteRequestedSubscription;

  /// このオブジェクトを破棄．
  @override
  void dispose() async {
    // await _localNicknameStreamSubscription?.cancel();
    await PeripheralManager().removeAllServices();
    super.dispose();
  }

  /// ペリフェラルの初期化とアドバタイズの開始
  Future<void> start() async {
    // ニックネーム関する初期化
    // _peripheralNickname = Uint8List.fromList(BleNickname().lastNickname);
    /*_localNicknameStreamSubscription = BleNickname().localNicknameStream.listen((nickname) async { // ニックネームの更新
      // await stop(); // PeripheralManager().stopAdvertising();
      _peripheralNickname = nickname;
      // await PeripheralManager().startAdvertising();
    });*/

    // PeripheralManagerを使ってBluetoothLowEnergyStateを確認し，
    // poweredOnならすぐに広告を開始（startAdvertising()する．
    // poweredOnでなければOnに状態が変わるのを待つ．
    // requestPeripheralPermissions(); // exchange_page.dart: ExchangePageクラスで実施済み

    var currentState = PeripheralManager().state; // BluetoothLowEnergyState
    if (kDebugMode) debugPrint("BlePeripheral start: state $currentState");
    if (currentState != BluetoothLowEnergyState.poweredOn) {
      await PeripheralManager().stateChanged.firstWhere(
              (args) => args.state == BluetoothLowEnergyState.poweredOn);
      currentState = PeripheralManager().state; // BluetoothLowEnergyState
      if (kDebugMode) debugPrint("BlePeripheral start: state (2) $currentState");
    }
    await startAdvertising();
  }

  /// 広告の開始
  Future<void> startAdvertising() async {
    if (kDebugMode) debugPrint("BlePeripheral startAdvertising: BLE state ${PeripheralManager().state}");
    // サービスををペリフェラルマネージャーに登録
    if (_addService) {
      if (kDebugMode) debugPrint("startAdvertising addService");
      await PeripheralManager().addService(BleNickname.nicknameService);
      _addService = false; // サービス登録済み
    }

    // セントラル（相手側）からの状態変更の監視メソッドを登録
    _characteristicReadRequestedSubscription = PeripheralManager().characteristicReadRequested.listen(_onReadRequest);
    _characteristicWriteRequestedSubscription = PeripheralManager().characteristicWriteRequested.listen(_onWriteRequest);
    _characteristicNotifyStateChangedSubscription = PeripheralManager().characteristicNotifyStateChanged.listen(_onNotifyStateChanged);
    _mtuChangedSubscription = PeripheralManager().mtuChanged.listen(_onMtuChanged);
    _connectionStateChangedSubscription = PeripheralManager().connectionStateChanged.listen(_onConnectionStateChanged);
    _stateChangedSubscription = PeripheralManager().stateChanged.listen(_onStateChanged);
    // _descriptorReadRequestedSubscription = PeripheralManager().descriptorReadRequested.listen(_onDescriptorReadRequested);
    // _descriptorWriteRequestedSubscription = PeripheralManager().descriptorWriteRequested.listen(_onDescriptorWriteRequested);


    // アドバタイズ（広告）の開始
    final advertisement = Advertisement(
        serviceUUIDs: [BleNickname.serviceUuid]);
    await PeripheralManager().startAdvertising(advertisement);
    if (kDebugMode) debugPrint("Advertising started...");

    _isAdvertising = true;
    notifyListeners(); // UIに通知
  }

  /// ペリフェラルの停止．リソースの解放
  Future<void> stop([bool fPoweredOn = true]) async {
    if (fPoweredOn) {
      await PeripheralManager().stopAdvertising();
      await PeripheralManager().removeAllServices();
    }
    await _characteristicReadRequestedSubscription?.cancel();
    await _characteristicWriteRequestedSubscription?.cancel();
    await _characteristicNotifyStateChangedSubscription?.cancel();
    await _mtuChangedSubscription?.cancel();
    await _connectionStateChangedSubscription?.cancel();
    await _stateChangedSubscription?.cancel();
    // await _localNicknameStreamSubscription?.cancel();
    _isAdvertising = false;
    notifyListeners(); // UIに通知
  }

  /// ニックネームが変わった時に呼ばれ，広告を一時停止して再開
  Future<void> restart() async {
    await PeripheralManager().stopAdvertising();
    final advertisement = Advertisement(
        serviceUUIDs: [BleNickname.serviceUuid]);
    await PeripheralManager().startAdvertising(advertisement);
    if (kDebugMode) debugPrint("Advertising restarted...");
  }

  /// CentralがPeripheraのニックネームを読み取り（Read）たいと要求している．特性（Characteristic）
  Future<void> _onReadRequest(GATTCharacteristicReadRequestedEventArgs event) async {
    // 対象の特性（Nicknameの読み取り特性など）であるかチェック
    if (event.characteristic == BleNickname.nicknameCharacteristic) {
      try {
        // セントラルにデータを応答．33バイトのニックネーム
        final localNickname = BleNickname().localNickname;
        if (kDebugMode) {
          debugPrint('_onReadRequest. length: ${localNickname.length}, '
              'nickname: ${BleNickname.nickname2string(localNickname)}, '
              'peripheral: ${event.central.uuid}');
        }
        await PeripheralManager().respondReadRequestWithValue(
          event.request,
          value: localNickname,
        );
      } catch (e) {
        if (kDebugMode) debugPrint("Failed to respond read request: $e");
      }
    } else if (event.characteristic == BleMutualAuthentication.authenticationCharacteristic) {
      BleMutualAuthentication().onReadRequest(event);
    }
  }

  /// CentralがCentralのニックネームを書き込み（Write）たいと要求している．特性（Characteristic）
  Future<void> _onWriteRequest(GATTCharacteristicWriteRequestedEventArgs event) async {
    // 対象の特性（Nicknameの書き込み特性など）であるかチェック
    if (event.characteristic == BleNickname.nicknameCharacteristic) {
      // セントラルから書き込まれたデータ (Uint8List) を取得
      final Uint8List remoteNickname = event.request.value;
      if (kDebugMode) {
        debugPrint('_onWriteRequest length: ${remoteNickname.length}, '
            'nickname: ${BleNickname.nickname2string(remoteNickname)}, '
            'central: ${event.central.uuid}');
      }
      BleNickname().addRemote(remoteNickname, DateTime.now(), centralUuid: event.central.uuid, );
    } else if (event.characteristic == BleMutualAuthentication.authenticationCharacteristic) {
      BleMutualAuthentication().onWriteRequest(event);
    }
  }

  /// Subscribe状態が変化した時のハンドラ
  void _onNotifyStateChanged(GATTCharacteristicNotifyStateChangedEventArgs eventArgs) {
    if (eventArgs.characteristic == BleNickname.nicknameCharacteristic) {
      if (kDebugMode) {
        final central = eventArgs.central;
        final state = eventArgs.state; // bool
        debugPrint('_onNotifyStateChanged: state $state, '
            'central.uuid ${central.uuid}');
      }
      // 即座に32バイトのデータを送信
    }
  }

  void _onMtuChanged(CentralMTUChangedEventArgs eventArgs) {
    if (kDebugMode) {
      final central = eventArgs.central;
      final mtu = eventArgs.mtu;
      debugPrint('_onMtuChanged: mtu $mtu, central.uuid ${central.uuid}');
    }
  }

  void _onConnectionStateChanged(CentralConnectionStateChangedEventArgs eventArgs) {
    if (kDebugMode) {
      final central = eventArgs.central;
      final state = eventArgs.state;
      debugPrint('_onConnectionStateChanged: state $state, '
          'central.uuid ${central.uuid}');
    }
  }

  void _onStateChanged(BluetoothLowEnergyStateChangedEventArgs eventArgs) async {
    if (kDebugMode) {
      final state = eventArgs.state;
      debugPrint('_stateChanged: state $state (peripheralManager)');
    }
    // PoweredOff なら main isolateに伝えて，KeyManagementTaskHandler を停止
    await BleNickname().onBleStateChanged(eventArgs);
  }

/*
  /// OSやユーザにBLEを使う許可をもらう
  Future<void> requestPeripheralPermissions() async {
    if (Platform.isAndroid) {
      // スキャン、接続に加えて「アドバタイズ」の権限もまとめてリクエストする
      Map<Permission, PermissionStatus> statuses = await [
        // Permission.bluetoothScan,
        // Permission.bluetoothConnect,
        Permission.bluetoothAdvertise, // ★これを追加
        // Permission.location,
      ].request();

      if (kDebugMode) debugPrint("Bluetooth Peripheral の許可: ${statuses[Permission.bluetoothAdvertise]}");
    } else if (Platform.isIOS) {
      // iOS用のBluetooth権限リクエスト
      PermissionStatus status = await Permission.bluetooth.request();
      if (kDebugMode) debugPrint("Bluetooth 許可 (iOS Peripheral): ${status}");
    }
  }
  */
/*
  // ニックネームのつもりの32バイトのデータを生成してセントラルに通知する
  Future<void> _send32ByteNotify(Central central) async {
    try {
      // 32バイトのダミーデータを生成 (例: 0から31までの連番)
      final Uint8List data = Uint8List.fromList(
        List<int>.generate(32, (index) => index & 0xFF), // ダミーデータ 0x000102030405...1F
      );

      // セントラルへNotifyを送信
      await PeripheralManager().notifyCharacteristic(
        central, BleNickname.nicknameCharacteristic,
          value: data
        /*central, : central,
        characteristic: _notifyCharacteristic,
        value: data,*/
      );
      if (kDebugMode) debugPrint("Successfully notified 32 bytes.");
    } catch (e) {
      if (kDebugMode) debugPrint("Failed to notify: $e");
    }
  }
  */
}
