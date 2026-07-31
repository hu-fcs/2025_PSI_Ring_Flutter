// flutterでbluetooth_low_energyパッケージを使ってペリフェラルのクラスを作ってください．32バイトnotifyの特性だけからなるサービスを広告してください．subscribeしたらすぐにnotifyするサービスにしてください．main.dartからこのクラスを呼び出してください．

/*
Android: AndroidManifest.xml に BLUETOOTH_ADVERTISE や BLUETOOTH_CONNECT などのパーミッション定義、および実行時パーミッションの要求コードが実運用では必要になります。iOS: Info.plist に NSBluetoothAlwaysUsageDescription および NSBluetoothPeripheralUsageDescription の鍵（説明文）を追加してください。
*/

import 'dart:async';
import 'package:flutter/foundation.dart'; // ChangeNotifier
import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'nickname.dart';
import 'mutual_authentication.dart';
import '../key_management.dart';

class BlePeripheral extends ChangeNotifier {
  // シングルトン
  static final BlePeripheral _instance = BlePeripheral._internal();
  factory BlePeripheral() => _instance;
  BlePeripheral._internal();

  bool _isAdvertising = false;
  /// 広告中．ChangeNotifierでUIに変化を通知
  bool get isAdvertising => _isAdvertising;
  /// 最後に要求を受け取った時刻
  DateTime? _lastRequestTime;
  DateTime? get lastRequestTime => _lastRequestTime;

  /// サービス追加を最初の1回だけにする
  bool _addService = true;

  StreamSubscription? _characteristicNotifyStateChangedSubscription;
  StreamSubscription? _characteristicReadRequestedSubscription;
  StreamSubscription? _characteristicWriteRequestedSubscription;

  /// キーマネージャの（ニックネームを管理している）
  StreamSubscription<void>? _keyUpdateSub;

  /// このオブジェクトを破棄．
  @override
  void dispose() {
    unawaited(_keyUpdateSub?.cancel());
    unawaited(PeripheralManager().removeAllServices());
    super.dispose();
  }

  void _setAdvertisingState(bool isAdvertising) {
    if (_isAdvertising == isAdvertising) return;
    _isAdvertising = isAdvertising;
    notifyListeners(); // UIに通知
  }

  /// ペリフェラルの初期化とアドバタイズの開始
  Future<void> start() async {
    await KeyManagementService().init();
    final pm = PeripheralManager();
    var currentState = pm.state; // BluetoothLowEnergyState
    if (kDebugMode) print("BlePeripheral start: state $currentState");
    if (currentState != BluetoothLowEnergyState.poweredOn) {
      await pm.stateChanged.firstWhere(
        (args) => args.state == BluetoothLowEnergyState.poweredOn,
      );
      currentState = pm.state; // BluetoothLowEnergyState
      if (kDebugMode) debugPrint("BlePeripheral start: state (2) $currentState");
    }
    await startAdvertising();
  }

  /// 広告の開始
  Future<void> startAdvertising() async {
    final pm = PeripheralManager();
    final kms = KeyManagementService();
    if (kDebugMode) debugPrint("BlePeripheral startAdvertising: BLE state ${pm.state}");
    // サービスををペリフェラルマネージャーに登録
    if (_addService) {
      if (kDebugMode) debugPrint("startAdvertising addService");
      await pm.addService(BleNickname.nicknameService);
      _addService = false; // サービス登録済み
    }

    await kms.start(byPeripheral: true);
    _keyUpdateSub = kms.onKeyUpdated.listen((_) async {
      if (kDebugMode) debugPrint("BlePeripheral: key updated, restart advertising");
      await restart();
    });

    // セントラル（相手側）からの状態変更の監視メソッドを登録
    _characteristicReadRequestedSubscription = pm
        .characteristicReadRequested
        .listen(_onReadRequest);
    _characteristicWriteRequestedSubscription = pm
        .characteristicWriteRequested
        .listen(_onWriteRequest);
    // BLE Notifyは使わない
    // _characteristicNotifyStateChangedSubscription = pm
    //     .characteristicNotifyStateChanged
    //     .listen(_onNotifyStateChanged);

    // アドバタイズ（広告）の開始
    final advertisement = Advertisement(
      serviceUUIDs: [BleNickname.serviceUuid],
    );
    await pm.startAdvertising(advertisement);
    if (kDebugMode) {
      final localNickname = kms.currentLocalKeyPair.publicKey;
      final localNicknameStr = localNickname.hexStr(len: 5);
      debugPrint("Advertising started... ${DateTime.now()} ${localNicknameStr}");
    }
    _setAdvertisingState(true);
  }

  /// ニックネームが変わった時に呼ばれる．（以前は広告を一時停止して再開していた）
  Future<void> restart() async {
    final kms = KeyManagementService();

    /*
    final pm = PeripheralManager();
    await pm.stopAdvertising();
    // await Future.delayed(Duration(seconds: 1));
    final advertisement = Advertisement(
      serviceUUIDs: [BleNickname.serviceUuid],
    );
    await pm.startAdvertising(advertisement);
     */
    if (kDebugMode) {
      final localNickname = kms.currentLocalKeyPair.publicKey;
      final localNicknameStr = localNickname.hexStr(len: 5);
      debugPrint("Advertise new nickname. ${DateTime.now()} ${localNicknameStr}");
    }
    notifyListeners();
  }

  /// ペリフェラルの停止．リソースの解放
  Future<void> stop() async {
    await _characteristicNotifyStateChangedSubscription?.cancel();
    await _characteristicReadRequestedSubscription?.cancel();
    await _characteristicWriteRequestedSubscription?.cancel();
    await _keyUpdateSub?.cancel();
    // await _localNicknameStreamSubscription?.cancel();

    await PeripheralManager().stopAdvertising();
    await KeyManagementService().stop(byPeripheral: true);
    _setAdvertisingState(false);
  }

  /// CentralがPeripheraのニックネームを読み取り（Read）たいと要求している．特性（Characteristic）
  Future<void> _onReadRequest(
    GATTCharacteristicReadRequestedEventArgs event,
  ) async {
    final pm = PeripheralManager();
    final kms = KeyManagementService();
    final now = DateTime.now();
    final central = event.central;
    central.setLastAccessedAt(now);

    // 対象の特性（Nicknameの読み取り特性など）であるかチェック
    if (event.characteristic == BleNickname.nicknameCharacteristic) {
      if (_lastRequestTime == null || now.difference(_lastRequestTime!).inSeconds > 1) {
        _lastRequestTime = now;
        notifyListeners(); // UIに通知
      }

      try {
        // セントラルにデータを応答．33バイトのニックネーム
        final keyPair = kms.currentLocalKeyPair;
        final localNickname = keyPair.publicKey;
        central.setLocalKeyPair(keyPair); // 相互認証で使う

        if (kDebugMode) {
          final shortNicknameStr = localNickname.hexStr(len: 5);
          debugPrint(
            "_onReadRequest. local nickname: $shortNicknameStr"
                ", peripheral: ${event.central.shortUuid}"
                ", event.request.offset ${event.request.offset}",
          );
        }
        await pm.respondReadRequestWithValue(
          event.request,
          value: localNickname.sublist(event.request.offset),
        );
      } catch (e) {
        if (kDebugMode) debugPrint("BLE Error: _onReadRequest (nickname): $e");
        await pm.respondReadRequestWithError(event.request,
          error: GATTError.unlikelyError);
      }
    } else if (event.characteristic ==
        BleMutualAuthentication.authenticationCharacteristic) {

      try {
        await BleMutualAuthentication().onReadRequest(event);
      }  catch (e) {
        if (kDebugMode) debugPrint("BLE Error: _onReadRequest (mutual auth): $e");
        await pm.respondReadRequestWithError(event.request,
            error: GATTError.unlikelyError);
      }
    }
  }

  /// CentralがCentralのニックネームを書き込み（Write）たいと要求している．特性（Characteristic）
  Future<void> _onWriteRequest(
    GATTCharacteristicWriteRequestedEventArgs event,
  ) async {
    final pm = PeripheralManager();
    final now = DateTime.now();
    final central = event.central;
    central.setLastAccessedAt(now);

    // 対象の特性（Nicknameの書き込み特性など）であるかチェック
    if (event.characteristic == BleNickname.nicknameCharacteristic) {
      try {
        // セントラルから書き込まれたデータ (Uint8List) を取得
        final Uint8List remoteNickname = event.request.value;
        central.setNickname(remoteNickname); // Centralのニックネームを更新
        if (_lastRequestTime == null || now.difference(_lastRequestTime!).inSeconds > 1) {
          _lastRequestTime = now;
          notifyListeners(); // UIに通知
        }

        if (kDebugMode) {
          final shortNicknameStr = remoteNickname.hexStr(len: 5);
          debugPrint("_onWriteRequest remote nickname: $shortNicknameStr"
              ", peripheral: ${event.central.shortUuid}");
        }
        await pm.respondWriteRequest(event.request);

        if (remoteNickname.length == KeyManagementService.nicknameBytes) {
          // MTUが33バイト未満の時は追加しない．
          await BlePeerList().addRemote(event.central, remoteNickname, now);
        }
      } catch (e) {
        if (kDebugMode) debugPrint("BLE Error: _onWriteRequest (nickname): $e");
        await pm.respondWriteRequestWithError(event.request,
            error: GATTError.unlikelyError);
      }
    } else if (event.characteristic ==
        BleMutualAuthentication.authenticationCharacteristic) {
      try {
        // 将来ニックネームリストにremoteNicknameが含まれているときには認証に進む（山口 賢紘, 2026年2月，卒業論文）
        // Central側から認証に進むはずなので，Peripheral側からは認証を始めないでいいだろう．
        await BleMutualAuthentication().onWriteRequest(event);
      } catch (e) {
        if (kDebugMode) debugPrint("BLE Error: _onWriteRequest (mutual auth): $e");
        await pm.respondWriteRequestWithError(event.request,
            error: GATTError.unlikelyError);
      }
    }
  }
}
