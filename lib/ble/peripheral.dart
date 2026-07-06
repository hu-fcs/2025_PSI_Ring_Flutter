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

class BlePeripheral extends ChangeNotifier {
  bool _isAdvertising = false;
  /// 広告中．ChangeNotifierでUIに変化を通知
  bool get isAdvertising => _isAdvertising;
  /// サービス追加を最初の1回だけにする
  bool _addService = true;

  StreamSubscription? _characteristicNotifyStateChangedSubscription;
  StreamSubscription? _characteristicReadRequestedSubscription;
  StreamSubscription? _characteristicWriteRequestedSubscription;

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
    if (kDebugMode) print("BlePeripheral start: state $currentState");
    if (currentState != BluetoothLowEnergyState.poweredOn) {
      await PeripheralManager().stateChanged.firstWhere(
              (args) => args.state == BluetoothLowEnergyState.poweredOn);
      currentState = PeripheralManager().state; // BluetoothLowEnergyState
      if (kDebugMode) print("BlePeripheral start: state (2) $currentState");
    }
    await startAdvertising();
  }

  /// 広告の開始
  Future<void> startAdvertising() async {
    if (kDebugMode) print("BlePeripheral startAdvertising: BLE state ${PeripheralManager().state}");
    // サービスををペリフェラルマネージャーに登録
    if (_addService) {
      if (kDebugMode) print("startAdvertising addService");
      await PeripheralManager().addService(BleNickname.nicknameService);
      _addService = false; // サービス登録済み
    }

    // セントラル（相手側）からの状態変更の監視メソッドを登録
    _characteristicNotifyStateChangedSubscription =
        PeripheralManager().characteristicNotifyStateChanged.listen(_onNotifyStateChanged);
    _characteristicReadRequestedSubscription =
        PeripheralManager().characteristicReadRequested.listen(_onReadRequest);
    _characteristicWriteRequestedSubscription =
        PeripheralManager().characteristicWriteRequested.listen(_onWriteRequest);

    // アドバタイズ（広告）の開始
    final advertisement = Advertisement(
      // name: 'BLE32',
      serviceUUIDs: [BleNickname.serviceUuid],
      // manufacturerSpecificData: [data, data2],
    );
    await PeripheralManager().startAdvertising(advertisement);
    if (kDebugMode) print("Advertising started...");

    _isAdvertising = true;
    notifyListeners(); // UIに通知
  }

  /// CentralがPeripheraのニックネームを読み取り（Read）たいと要求している．特性（Characteristic）
  Future<void> _onReadRequest(GATTCharacteristicReadRequestedEventArgs event) async {
    // 対象の特性（Nicknameの読み取り特性など）であるかチェック
    if (event.characteristic == BleNickname.nicknameCharacteristic) {
      try {
        // セントラルにデータを応答．33バイトのニックネーム
        final localNickname = BleNickname().localNickname;
        if (kDebugMode) print("_onReadRequest. length: ${localNickname.length}, nickname: ${BleNickname.nickname2string(localNickname)}, peripheral: ${event.central.uuid}");
        await PeripheralManager().respondReadRequestWithValue(
          event.request,
          value: localNickname,
        );
      } catch (e) {
        if (kDebugMode) print("Failed to respond read request: $e");
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
      if (kDebugMode) print("_onWriteRequest length: ${remoteNickname.length}, nickname: ${BleNickname.nickname2string(remoteNickname)}, peripheral: ${event.central.uuid}");
      BleNickname().addRemote(remoteNickname, DateTime.now(), centralUuid: event.central.uuid, );

      // 将来ニックネームリストにremoteNicknameが含まれているときには認証に進む（山口 賢紘, 2026年2月，卒業論文）
      // Central側から認証に進むはずなので，Peripheral側からは認証を始めないでいいだろう．
    } else if (event.characteristic == BleMutualAuthentication.authenticationCharacteristic) {
      BleMutualAuthentication().onWriteRequest(event);
    }
  }

  /// Subscribe状態が変化した時のハンドラ
  void _onNotifyStateChanged(GATTCharacteristicNotifyStateChangedEventArgs event) {
    // 対象の特性かつ、セントラルがSubscribe（通知有効化）した場合
    if (event.characteristic == BleNickname.nicknameCharacteristic && event.state) {
      if (kDebugMode) print("Central subscribed. Sending 32-byte data immediately.");

      // 即座に32バイトのデータを送信
      // _send32ByteNotify(event.central);
    }
  }

  /// ニックネームが変わった時に呼ばれ，広告を一時停止して再開
  Future<void> restart() async {
    await PeripheralManager().stopAdvertising();
    final advertisement = Advertisement(
      // name: 'BLE32',
      serviceUUIDs: [BleNickname.serviceUuid],
      // manufacturerSpecificData: [data, data2],
    );
    await PeripheralManager().startAdvertising(advertisement);
    if (kDebugMode) print("Advertising restarted...");
  }

  /// ペリフェラルの停止．リソースの解放
  Future<void> stop() async {
    await _characteristicNotifyStateChangedSubscription?.cancel();
    await _characteristicReadRequestedSubscription?.cancel();
    await _characteristicWriteRequestedSubscription?.cancel();
    // await _localNicknameStreamSubscription?.cancel();

    await PeripheralManager().stopAdvertising();

    _isAdvertising = false;
    notifyListeners(); // UIに通知
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

      if (kDebugMode) print("Bluetooth Peripheral の許可: ${statuses[Permission.bluetoothAdvertise]}");
    } else if (Platform.isIOS) {
      // iOS用のBluetooth権限リクエスト
      PermissionStatus status = await Permission.bluetooth.request();
      if (kDebugMode) print("Bluetooth 許可 (iOS Peripheral): ${status}");
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
      if (kDebugMode) print("Successfully notified 32 bytes.");
    } catch (e) {
      if (kDebugMode) print("Failed to notify: $e");
    }
  }
  */
}
