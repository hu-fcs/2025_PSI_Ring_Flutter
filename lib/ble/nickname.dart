/// BleCentralManagerクラスとBlePeripheralクラスを使って，
/// 自身のニックネームを相手に知らせたり，
/// 受信したニックネームをアプリの他の部分に知らせて，友達か判定したりDBに記録する．
///
/// とりあえず効率化は考えないで，全部知らせる．
///
/// 杉浦修論版のアプリでは
/// BLEでの鍵交換を行う際に，次のようにKeyManagementServiceクラスを使っているので，
/// それに似せる．
///
/// ```dart key_management.dart
/// class KeyManagementService {
///   Future<Uint8List?> getPublicKeyForBleAdvertise(); // 広告用の自身のニックネームを取得
///   Future<bool> insertCollectedKeyIfAbsent({ // 受信した相手のニックネームを記録
///     required Uint8List pubkey33,
///     required int receivedAtMs,});
///   final receivedAtMs = DateTime.now().millisecondsSinceEpoch;
/// }
library; // 上のドキュメントコメントをファイルに対するコメントにするためにlibraryと書いている．

import 'dart:async';      // Timer
import 'dart:math' show Random;       // min
import 'dart:typed_data' show Uint8List;
import 'package:flutter/foundation.dart'show kDebugMode, debugPrint, ChangeNotifier;
import "package:bluetooth_low_energy/bluetooth_low_energy.dart";
import 'package:convert/convert.dart' show hex; // hex.decode(Uint8List)のため
// import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:fluttersample_2025/key_foreground_task.dart';
import '../key_management.dart';
import 'peripheral.dart';
import 'central.dart';
import 'mutual_authentication.dart';

/// BLEで広告するニックネームや受信したニックネームを処理するクラス
///
/// 関係するファイル：
/// - central.dart, peripheral.dart: BLEペリフェラルとセントラルの実装
/// - mutual_authentication.dart: BLEで相互認証する部分
/// - exchange_page.dart, debug_page.dart: ユーザインタフェース
///
/// KeyManagementServiceとの関係
/// - 広告するニックネームを問い合わせる．_kms.getPublicKeyForBleAdvertise()
/// - 収集したニックネームを登録する．_kms.insertCollectedKeyIfAbsent()
/// - キーの更新をlisten．_kms.onKeyUpdated.listen(_updateNickname);
/// - キーの更新間隔を時々問い合わせる．_kms.slotMs
///
/// 状態遷移図: /doc/images/ble_central.png
class BleNickname extends ChangeNotifier {
  /// サービス識別子（UUID）
  static final UUID serviceUuid = UUID.fromString('D353434A-C5F4-4A63-A21A-974C68459ED2');
  /// Peripheral自身のニックネームをCentralが読み取り（read）
  /// CentralのニックネームをPeripheralに書き込む（write）ための特性識別子（UUID）
  static final UUID nicknameCharacteristicUuid = UUID.fromString('D3534340-C5F4-4A63-A21A-974C68459ED2');

  /// Peripheralのニックネーム・サービス（Service）
  static final GATTService nicknameService = GATTService(
    uuid: BleNickname.serviceUuid,
    isPrimary: true,
    includedServices: [], // [BleMutualAuthentication.authenticationService], // secondary serviceを追加しようとしたがうまくいかない
    characteristics: [
      nicknameCharacteristic,
      BleMutualAuthentication.authenticationCharacteristic,
    ],
  );
  /// Peripheralのニックネームを読み出す特性（Characteristic）
  static final GATTCharacteristic nicknameCharacteristic = GATTCharacteristic.mutable(
    uuid: BleNickname.nicknameCharacteristicUuid,
    properties: [
      GATTCharacteristicProperty.read,
      GATTCharacteristicProperty.writeWithoutResponse,
    ],
    permissions: [
      GATTCharacteristicPermission.read,
      GATTCharacteristicPermission.write,
    ],
    descriptors: [],
  );

  /// 単一ニックネームの使用期間．杉浦修論では10分．デバッグ画面で10分，1分，10秒で切り替えられる．
  static var validDuration = const Duration(seconds: 30); // 標準ば10分．minutes: 10); // KeyManagementService 内の validity の値
  /// ニックネームの更新タイマー
  Timer? _timer;

  /// キーマネージャ（ニックネームを管理している）
  final _kms = KeyManagementService();
  /// キーマネージャの（ニックネームを管理している）
  StreamSubscription<void>? _keyUpdateSub;

  final _advertiser = BlePeripheral();
  final _scanner = BleCentralManager();

  bool _isRunning = false;
  bool get isRunning => _isRunning;

  /// BLEがONになったら，StartExchangeするためのフラグ
  bool _waitForPoweredOn = false;

  // シングルトン
  static final BleNickname _instance = BleNickname._internal();
  /// シングルトン：このクラスのオブジェクトは一つだけ．
  factory BleNickname() {
    return _instance;
  }
  BleNickname._internal() {
    _timer = Timer.periodic(validDuration, _updateNickname);
    _advertiser.addListener(onPeripheralStateChanged);
    _scanner.addListener(onCentralStateChanged);
    // _keyUpdateSub = _kms.onKeyUpdated.listen(_updateNickname); // 広告・スキャンONのタイミングに変更
  }

  /// クラスが破棄される時にストリーム・コントローラーを閉じる
  void dispose() {
    // _localNicknameStreamController.close();
    _timer?.cancel();
    _keyUpdateSub?.cancel();
    super.dispose();
  }

  /// BLE広告（アドバタイズ）とスキャンのON/OFF切り替え
  Future<void> toggleExchange() async {
    if (isRunning) {
      await stopExchange();
    } else {
      await startExchange();
    }
  }

  /// BLE広告（アドバタイズ）とスキャンのON
  Future<void> startExchange() async {
    _kms.init(); // main() から移動
    _keyUpdateSub = _kms.onKeyUpdated.listen(_updateNickname);
    _start();
    if (!_advertiser.isAdvertising || _waitForPoweredOn) {
      await _advertiser.start();
    }
    if (!_scanner.isScanning || _waitForPoweredOn) {
      await _scanner.startScan();
    }
    _waitForPoweredOn = false;
  }

  /// BLE広告（アドバタイズ）とスキャンのOFF
  Future<void> stopExchange([bool fPoweredOn = true]) async {
    _keyUpdateSub?.cancel();
    _timer?.cancel();
    if (fPoweredOn) {
      await _scanner.stopScan(fPoweredOn);
      await _advertiser.stop(fPoweredOn);
    } else {
      _waitForPoweredOn = true; // PowerOffでstopした場合はPowerOnで再開
    }
    _lastNickname = Uint8List(33);
  }

  void onPeripheralStateChanged() {
    if (kDebugMode) debugPrint('_onStateChanged: ${_advertiser.isAdvertising}');
    final isRunning = _advertiser.isAdvertising || _scanner.isScanning;
    if (_isRunning != isRunning) {
      _isRunning = isRunning;
      notifyListeners();
    }
    // main isolate への通知 (_onReceiveTaskDataへ)
    final now = DateTime.now();
    KeyManagementTaskHandler().sendDataToMain(<String, Object>{
      'event': 'advertiser', 'isRunning': _advertiser.isAdvertising, 'now': now.millisecondsSinceEpoch});
  }

  void onCentralStateChanged() {
    if (kDebugMode) debugPrint('_onStateChanged: ${_advertiser.isAdvertising} ${_scanner.isScanning}');
    final isRunning = _advertiser.isAdvertising || _scanner.isScanning;
    if (_isRunning != isRunning) {
      _isRunning = isRunning;
      notifyListeners();
    }
    // main isolate への通知 (_onReceiveTaskDataへ)
    final now = DateTime.now();
    KeyManagementTaskHandler().sendDataToMain(<String, Object>{
      'event': 'scanner', 'isRunning': _scanner.isScanning, 'now': now.millisecondsSinceEpoch});
  }

  Future<void> onBleStateChanged(BluetoothLowEnergyStateChangedEventArgs eventArgs) async {
    final state = eventArgs.state;
    if (state != BluetoothLowEnergyState.poweredOn) {
      // PoweredOff なら main isolateに伝えて，KeyManagementTaskHandler を停止
      if (_advertiser.isAdvertising || _scanner.isScanning) {
        // main isolate への通知 (_onReceiveTaskDataへ)
        KeyManagementTaskHandler().sendDataToMain(<String, Object>{
          'event': 'blePoweredOff', 'now': DateTime.now().millisecondsSinceEpoch});
      }
    }
  }

  /// ニックネームの前回のスロット
  int _lastSlotStartTime = 0;
  /// ニックネームの前回のニックネーム
  Uint8List _lastNickname = Uint8List(33);
  /// ニックネームの前回のスロット（変更はlocalNicknameStreamで通知するので最初だけ）
  Uint8List get localNickname => _lastNickname;
  ///
  final _random = Random();

  /// ニックネームの更新（タイマーで呼び出す）
  /// validDuration の半分の時間程度まで適当に広告を遅れさせて揺らぎを持たせる．
  Future<void> _updateNickname(void _) async {
    final currentValidDuration = Duration(milliseconds: _kms.slotMs);
    if (validDuration != currentValidDuration) {
      validDuration = currentValidDuration;
      _timer?.cancel();
      _timer = Timer.periodic(validDuration, _updateNickname);
    }
    if (_lastNickname[0] != 0x00) {
      // [0] == 0x00の場合，アプリ実行後の最初のニックネームでは，待ち時間なし．
      // ニックネームの更新
      final jitter = _random.nextInt(validDuration.inMilliseconds ~/ 2);
      await Future.delayed(Duration(milliseconds: jitter));
    }
    // 杉浦プロジェクトと同様（3行）
    final now = DateTime.now();
    final int slotMillis = validDuration.inMilliseconds;
    final slotStartTime = (now.millisecondsSinceEpoch ~/ slotMillis) * slotMillis; // (now ~/ slotMillis) は (int)(now / slotMillis) と同じ

    if (_lastSlotStartTime != slotStartTime) { // 時間が経っていなら更新しない．
      _lastSlotStartTime = slotStartTime;
      _lastNickname = await _kms.getPublicKeyForBleAdvertise().catchError((e, st) {
        if (kDebugMode) {
          debugPrint('_updateNickname: getPublicKeyForBleAdvertise failed: $e');
        }
        throw e;
      });
      if (_advertiser.isAdvertising) {
        if (CentralManager().state == BluetoothLowEnergyState.poweredOn) {
          await _advertiser.restart();
        } else { // BluetoothがOffなどOn以外
          stopExchange();
        }
      }

      // notification．awaitしない
      KeyManagementTaskHandler.UpdateNotificationText(localNickname: _lastNickname, now: now);

      // main isolate への通知
      KeyManagementTaskHandler().sendDataToMain(<String, Object>{
        'event': 'localNickname', 'nickname': _lastNickname, 'now': now.millisecondsSinceEpoch});

      if (kDebugMode) {
        debugPrint('_updateNickname: $now, '
            'duration $validDuration, '
            '${nickname2string(_lastNickname, len: 9)}');
      }
    }
    // _localNicknameStreamController.add(Uint8List.fromList(_lastNickname!)); // 通知する
    // BleRemoteMap().addRemote(_lastNickname!, DateTime.now(), local: true);
  }

  Future<void> _start() async {
    _lastNickname = await _kms.getPublicKeyForBleAdvertise().catchError((e, st) {
      if (kDebugMode) {
        debugPrint('BleNickname: start failed: $e');
      }
      throw e;
    });

    if (kDebugMode) debugPrint('nickname _start ${nickname2string(_lastNickname)} ${_kms.slotMs}');

    // await _updateNickname(null);
    // notification．awaitしない
    KeyManagementTaskHandler.UpdateNotificationText(localNickname: _lastNickname, now: DateTime.now());
    // main isolate への通知
    KeyManagementTaskHandler().sendDataToMain(<String, Object>{
      'event': 'localNickname', 'nickname': _lastNickname, 'now': DateTime.now().millisecondsSinceEpoch});
  }

  /// リモートのニックネームを追加
  Future<void> addRemote(Uint8List nickname, DateTime now, {UUID? peripheralUuid, UUID? centralUuid, bool local = false}) async {
    if (! local) { // リモートのニックネームを追加
      // 収集鍵として登録する
      final inserted = await _kms.insertCollectedKeyIfAbsent(
        pubkey33: nickname,
        receivedAtMs: now.millisecondsSinceEpoch,
      );
      if (inserted) {
        // notification．awaitしない
        KeyManagementTaskHandler.UpdateNotificationText(remoteNickname: nickname, now: DateTime.now());
        // main isolate への通知
        KeyManagementTaskHandler().sendDataToMain(<String, Object>{
          'event': 'remoteNickname', 'nickname': nickname, 'now': now.millisecondsSinceEpoch});
        if (kDebugMode) {
          debugPrint('BLE_SCAN: new collected key stored');
        }
      }
    }
  }

  /// 33バイトのニックネームを16進表現の文字列にして，4バイトごとに_アンダースコアで区切る．クラスメソッド．主にデバッグ用
  static String nickname2string(Uint8List bytes, {int len = 0}) {
    if (len == 0) len = bytes.length;
    final hexString = hex.encode(bytes.sublist(0, len));
    final joined = RegExp(r'.{1,8}(?=(?:.{8})*$)').allMatches(hexString).map((m) => m.group(0)).join('_');
    if (len < bytes.length) {
      return joined + '...';
    } else {
      return joined;
    }
  }
}
/*
/// BLEで受信したニックネームを格納するオブジェクト
class BleRemote {
  Uint8List remoteNickname;   // Uint8List, 33バイト．相手のニックネーム
  DateTime time;              // ニックネームを交換した日時
  UUID? centralUuid;          // Peripheralとして接続されたときのcentralのUUID
  UUID? peripheralUuid;       // Centralとして接続したときに記録
  Timer? timer;

  BleRemote({
    required this.remoteNickname,
    this.centralUuid,
    this.peripheralUuid,
    this.timer,
  })
    : time = DateTime.now();

  void dispose() {
  }
}
*/