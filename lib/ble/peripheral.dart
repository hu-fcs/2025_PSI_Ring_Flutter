// flutterでbluetooth_low_energyパッケージを使ってペリフェラルのクラスを作ってください．32バイトnotifyの特性だけからなるサービスを広告してください．subscribeしたらすぐにnotifyするサービスにしてください．main.dartからこのクラスを呼び出してください．

/*
Android: AndroidManifest.xml に BLUETOOTH_ADVERTISE や BLUETOOTH_CONNECT などのパーミッション定義、および実行時パーミッションの要求コードが実運用では必要になります。iOS: Info.plist に NSBluetoothAlwaysUsageDescription および NSBluetoothPeripheralUsageDescription の鍵（説明文）を追加してください。
*/

import 'dart:async';
import 'dart:io'; // Platform
import 'package:flutter/foundation.dart'; // ChangeNotifier
// import 'dart:convert'; // utf8.decode
import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:permission_handler/permission_handler.dart';
import 'nickname.dart';

class BlePeripheral extends ChangeNotifier {
  StreamSubscription? _stateSubscription;

  bool _isAdvertising = false;
  /// 広告中．ChangeNotifierでUIに変化を通知
  bool get isAdvertising => _isAdvertising;

  final StreamController<bool> _advertisingStateController = StreamController<bool>.broadcast();
  /// 削除予定．ChangeNotifierに変更．_PeripheralHomeScreenState で使用
  Stream<bool> get advertisingStateStream => _advertisingStateController.stream;

  StreamSubscription? _characteristicNotifyStateChangedSubscription;
  StreamSubscription? _characteristicReadRequestedSubscription;
  StreamSubscription? _characteristicWriteRequestedSubscription;

  // Uint8List _peripheralNickname = Uint8List(33); // BleNickname().localNickname
  // StreamSubscription? _localNicknameStreamSubscription;

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

    final currentState = PeripheralManager().state;
    if (kDebugMode) print("現在のBluetooth状態: $currentState");
    if (currentState == BluetoothLowEnergyState.poweredOn) {
      // 既にONならすぐにアドバタイズを開始
      await startAdvertising();
    } else {
      // unknown や poweringOn などの場合は、状態変化をリッスンして待つ
      if (kDebugMode) print("Bluetoothの準備を待っています...");
      await _stateSubscription?.cancel();
      _stateSubscription = PeripheralManager().stateChanged.listen((arg) async {
        if (arg.state == BluetoothLowEnergyState.poweredOn && !_isAdvertising) {
          if (kDebugMode) print("Bluetooth状態がOnに変化しました");
          // 準備が整ったらリッスンを解除して起動
          await _stateSubscription?.cancel();
          await startAdvertising();
        } else {
          if (kDebugMode) print("Bluetooth状態が ${arg.state} に変化しました");
        }
      });
    }
  }

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

  /// 広告の開始
  Future<void> startAdvertising() async {
    // サービスををペリフェラルマネージャーに登録
    await PeripheralManager().addService(BleNickname.nicknameService);

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
    _advertisingStateController.add(_isAdvertising);/* ChangeNotifierに変更．_PeripheralHomeScreenState でのみ必要 */
  }

  /// Subscribe状態が変化した時のハンドラ
  void _onNotifyStateChanged(GATTCharacteristicNotifyStateChangedEventArgs event) {
    // 対象の特性かつ、セントラルがSubscribe（通知有効化）した場合
    if (event.characteristic == BleNickname.nicknameReadCharacteristic && event.state) {
      if (kDebugMode) print("Central subscribed. Sending 32-byte data immediately.");
      
      // 即座に32バイトのデータを送信
      _send32ByteNotify(event.central);
    }
  }

  /// CentralがPeripheraのニックネームを読み取り（Read）たいと要求している．特性（Characteristic）
  void _onReadRequest(GATTCharacteristicReadRequestedEventArgs event) async {
    // 対象の特性（Nicknameの読み取り特性など）であるかチェック
    if (event.characteristic == BleNickname.nicknameReadCharacteristic) {
      if (kDebugMode) print("_onReadRequest from central ${event.central.uuid}");

      // 送信したいデータは33バイトのニックネーム
      var nickname = BleNickname().localNickname;
      // value = value.sublist(0, 18);
      // セントラルにデータを応答（成功ステータスとともに送信）
      try {
        // バージョン6では PeripheralManager のメソッド経由で直接応答を返す
        await PeripheralManager().respondReadRequestWithValue(
          event.request, // eventからGATTReadRequestを取り出して渡す
          value: nickname,
        );
      } catch (e) {
        if (kDebugMode) print("Failed to respond read request: $e");
      }
    }
  }

  /// CentralがCentralのニックネームを書き込み（Write）たいと要求している．特性（Characteristic）
  void _onWriteRequest(GATTCharacteristicWriteRequestedEventArgs event) async {
    // 対象の特性（Nicknameの書き込み特性など）であるかチェック
    if (event.characteristic == BleNickname.nicknameWriteCharacteristic) {

      // セントラルから書き込まれたデータ (Uint8List) を取得
      final Uint8List rawData = event.request.value;
      if (kDebugMode) print("_onWriteRequest from central ${event.central.uuid} ${BleNickname.nickname2string(rawData)}");

      /* GATTCharacteristicProperty.writeWithoutResponse の特性にしたので応答は不要
      try {
        await PeripheralManager().respondWriteRequest(event.request);
      } catch (e) {
        if (kDebugMode) print("Failed to respond write request: $e");
      }
      */

      BleNickname().addRemote(rawData, DateTime.now(), centralUuid: event.central.uuid, );
    }
  }
  // ニックネームのつもりの32バイトのデータを生成してセントラルに通知する
  Future<void> _send32ByteNotify(Central central) async {
    try {
      // 32バイトのダミーデータを生成 (例: 0から31までの連番)
      final Uint8List data = Uint8List.fromList(
        List<int>.generate(32, (index) => index & 0xFF), // ダミーデータ 0x000102030405...1F
      );

      // セントラルへNotifyを送信
      await PeripheralManager().notifyCharacteristic(
        central, BleNickname.nicknameReadCharacteristic,
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
  /// 
  /// リソースの解放
  Future<void> stop() async {
    await _characteristicNotifyStateChangedSubscription?.cancel();
    await _characteristicReadRequestedSubscription?.cancel();
    await _characteristicWriteRequestedSubscription?.cancel();
    // await _localNicknameStreamSubscription?.cancel();

    await PeripheralManager().stopAdvertising();
    _isAdvertising = false;
    notifyListeners(); // UIに通知
    _advertisingStateController.add(_isAdvertising); /* ChangeNotifierに変更．_PeripheralHomeScreenState でのみ必要 */
  }
  /// このオブジェクトを破棄．
  ///
  /// 購読をやめる．
  @override
  void dispose() async {
    // await _localNicknameStreamSubscription?.cancel();

    _stateSubscription?.cancel();
    await PeripheralManager().removeAllServices();
    super.dispose();
  }

}
