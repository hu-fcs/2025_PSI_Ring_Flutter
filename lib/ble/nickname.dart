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

import 'dart:async'; // Timer
import 'package:flutter/foundation.dart'; // kDebugMode
import "package:bluetooth_low_energy/bluetooth_low_energy.dart";
import 'package:intl/intl.dart' show DateFormat;
import '../key_management.dart';
import '../ffi/native_key_service.dart';
import '../friend.dart';
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
class BleNickname extends ChangeNotifier {
  /// サービス識別子（UUID）
  static final UUID serviceUuid = UUID.fromString(
    'D353434A-C5F4-4A63-A21A-974C68459ED2',
  );

  /// Peripheral自身のニックネームをCentralが読み取り（read）
  /// CentralのニックネームをPeripheralに書き込む（write）ための特性識別子（UUID）
  static final UUID nicknameCharacteristicUuid = UUID.fromString(
    'D3534340-C5F4-4A63-A21A-974C68459ED2',
  );

  /// Peripheralのニックネーム・サービス（Service）
  static final GATTService nicknameService = GATTService(
    uuid: BleNickname.serviceUuid,
    isPrimary: true,
    includedServices:
        [], // [BleMutualAuthentication.authenticationService], // secondary serviceを追加しようとしたがうまくいかない
    characteristics: [
      nicknameCharacteristic,
      BleMutualAuthentication.authenticationCharacteristic,
    ],
  );

  /// Peripheralのニックネームを読み出す特性（Characteristic）
  static final GATTCharacteristic
  nicknameCharacteristic = GATTCharacteristic.mutable(
    uuid: BleNickname.nicknameCharacteristicUuid,
    properties: [
      GATTCharacteristicProperty.read,
      GATTCharacteristicProperty.write, // writeWithoutResponse だと33バイトは書き込めない
    ],
    permissions: [
      GATTCharacteristicPermission.read,
      GATTCharacteristicPermission.write,
    ],
    descriptors: [],
  );

  /// キーマネージャ（ニックネームを管理している）
  final _kms = KeyManagementService();

  final _advertiser = BlePeripheral();
  BlePeripheral get advertiser => _advertiser;
  final _scanner = BleCentralManager();
  BleCentralManager get scanner => _scanner;

  bool _isRunning = false;
  bool get isRunning => _isRunning;

  void _onStateChanged() {
    if (kDebugMode)
      print('_onStateChanged'
          ' peripheral: ${_advertiser.isAdvertising}'
          ' central: ${_scanner.isScanning}',
      );
    _isRunning = _advertiser.isAdvertising && _scanner.isScanning;
    notifyListeners();
  }

  // シングルトン
  static final BleNickname _instance = BleNickname._internal();
  factory BleNickname() => _instance;
  BleNickname._internal() {
    _advertiser.addListener(_onStateChanged);
    _scanner.addListener(_onStateChanged);
  }

  /// クラスが破棄される時にストリーム・コントローラーを閉じる
  @override
  void dispose() {
    // _localNicknameStreamController.close();
    super.dispose();
  }

  /// BLE広告（アドバタイズ）とスキャンのON/OFF切り替え
  Future<void> toggleExchange() async {
    if (isRunning) { // BLE広告とスキャンを停止
      await _scanner.stopScan();
      await _advertiser.stop();
    } else { // BLE広告とスキャンを開始
      _start();
      if (!_advertiser.isAdvertising) await _advertiser.start();
      if (!_scanner.isScanning) await _scanner.startScan();
    }
  }

  Future<void> _start() async {
    if (kDebugMode) {
      final localNickname = _kms.currentLocalKeyPair.publicKey;
      print('nickname _start ${localNickname.hexStr(len: 5)} ${_kms.slot}');
    }
  }

  /// UIに表示するための現在の状態を返す．
  String currentStateString() {
    final df = DateFormat('E HH:mm:ss'); // 'yyyy-MM-dd HH:mm:ss'
    final localNicknameStr = _kms.currentLocalKeyPair.publicKey.hexStr(len: 3);
    final exireAtStr = df.format(_kms.currentKeyExpirationTime);
    // _scanner
    // _advertiser
    return '$localNicknameStr $exireAtStrまで';
  }
}

/// 受信/送信したBLEニックネーム履歴を保持するシングルトン
class BlePeerList extends ChangeNotifier {
  static final BlePeerList _instance = BlePeerList._internal();
  factory BlePeerList() => _instance;
  BlePeerList._internal();

  final List<BluetoothLowEnergyPeer> _list = [];
  List<BluetoothLowEnergyPeer> get list => _list;

  /// 友達のperipheraとcentralを取得する．
  (Peripheral?, Central?, bool) of(DummyFriend friend) {
    Peripheral? peripheral = null;
    Central? central = null;
    bool exist = false; // 友達のperipheraとcentralと最近ニックネームを交換したか
    final slotPlus = KeyManagementService().slot * 2;
    final expireAt = DateTime.now().subtract(slotPlus);

    for (final peer in _list.reversed) {
      if (peer.friend == friend && peer.isAuthenticated) {
//        print('BlePeerList.of: peerInList.friend=${peerInList.friend?.name}, friend=${friend.name}');
        if (peripheral == null && peer is Peripheral) {
          peripheral = peer;
          if (peer.lastExchangedAt!.isAfter(expireAt)) exist = true;
        }
        if (central == null && peer is Central) {
          central = peer;
          if (peer.lastExchangedAt!.isAfter(expireAt)) exist = true;
        }
        if (peripheral != null && central != null) break;
      }
    }
    return (peripheral, central, exist);
  }

  /// 接続相手のニックネームを記録する．
  Future<void> addRemote(BluetoothLowEnergyPeer peer,
      Uint8List nickname, DateTime now) async {
    // collected_keysテーブルに追加
    KeyManagementService().insertCollectedPubKeyIfAbsent(pubkey33: nickname, exchangedAt: now);

    // _list にすでにニックネームが存在すれば更新
    for (final peerInList in _list.reversed) {
      if (peerInList == peer) {
        peerInList.setNickname(nickname);
        peerInList.setLastExchangedAt(now);
        reorderList();
        notifyListeners();
        return;
      }
    }
    // _list に追加
    peer.setNickname(nickname);
    peer.setLastExchangedAt(now);
    _list.add(peer);
    notifyListeners();
  }

  /// lastExchangedAt が slot * 2 より新しいものより後に，
  /// slot * 2 より古いものがあったら，古いものを一つだけリストの前の方に移動する．
  /// 古いものがリストの前の方に少しずつ集まるようにする．
  void reorderList() {
    final slotPlus = KeyManagementService().slot * 2;
    final expireAt = DateTime.now().subtract(slotPlus);
    int fresh = -1; // リストの先頭から最初に見つかった新しい要素の位置
    int decay = -1; // リストのfreshより後で最初に見つかった古い要素の位置
    for (int i = 0; i < _list.length; i++) {
      if (fresh == -1 && _list[i].lastExchangedAt!.isAfter(expireAt))
        fresh = i;
      if (fresh != -1 && decay == -1 && _list[i].lastExchangedAt!.isBefore(expireAt))
        decay = i;
      if (fresh != -1 && decay != -1) break;
    }
    // _list[decay]を_list[fresh]の前に移動する．逆順に表示するので_list[decay]の表示は後ろに移動
    if (fresh != -1 && decay != -1 && fresh < decay) {
      if (kDebugMode) debugPrint('reorderList: moving peer from $decay to $fresh');
      final decayPeer = _list[decay];
      for (int i = decay; i > fresh; i--) {
        _list[i] = _list[i - 1];
      }
      _list[fresh] = decayPeer;
    }
  }

  void Function(String friendLabel, bool authenticated)? onFriendDetectedCallback;

  /// 友達を検出したときに呼び出す．
  Future<void> onFriendDetected(BluetoothLowEnergyPeer peer,
      int friendId, [bool authenticated = true]) async {
    final friendName = FriendList().labelOf(friendId);
    if (kDebugMode) {
      debugPrint('onFriendDetected nickname: ${peer.nickname?.hexStr(len: 5)}'
          ', authenticated: $authenticated, friendName: $friendName');
    }
    peer.setFriend(friendId);
    peer.isAuthenticated = authenticated;
    if (onFriendDetectedCallback != null) {
      onFriendDetectedCallback!(friendName, authenticated);
    }
    notifyListeners();
  }

  void clear() {
    _list.clear();
    notifyListeners();
  }
}

final Map<BluetoothLowEnergyPeer, Uint8List> _peerNickname = {};
final Map<BluetoothLowEnergyPeer, DateTime> _peerLastExchangedAt = {};
final Map<BluetoothLowEnergyPeer, bool> _peerIsAuthenticated = {};
final Map<BluetoothLowEnergyPeer, int> _peerFriend = {}; // int: friendID in friends テーブル

extension BluetoothLowEnergyPeerExtension on BluetoothLowEnergyPeer {
  /// UUIDの末尾の文字列
  String get shortUuid => uuid.toString().substring(uuid.toString().length - 4);

  setNickname(Uint8List value) => _peerNickname[this] = value;
  Uint8List? get nickname => _peerNickname[this];

  setLastExchangedAt(DateTime value) => _peerLastExchangedAt[this] = value;
  DateTime? get lastExchangedAt => _peerLastExchangedAt[this];

  set isAuthenticated(bool value) => _peerIsAuthenticated[this] = value;
  bool get isAuthenticated => _peerIsAuthenticated[this] ?? false;

  setFriend(int friendId) => _peerFriend[this] = friendId;
  int? get friend => _peerFriend[this];
}

/// ペリフェラルとの接続回数や最後に発見された時刻を記録するためのMap
// ToDo: これらのMapは古いペリフェラルの要素を削除しないとメモリリークしている．
final Map<Peripheral, DateTime> _peripheralLastDiscoveredAt = {};
final Map<Peripheral, int> _peripheralDiscoveredCount = {};
final Map<Peripheral, DateTime> _peripheralLastConnectAt = {};
final Map<Peripheral, DateTime> _peripheralNextConenctAt = {};
final Map<Peripheral, int> _peripheralLastConnectErrorCount = {};

extension PeripheralExtension on Peripheral {

  /// ペリフェラルが最後に発見された時刻を記録する．
  int setDiscoveredAt(DateTime now) {
    _peripheralLastDiscoveredAt[this] = now;
    final count = (_peripheralDiscoveredCount[this] ?? 0) + 1;
    _peripheralDiscoveredCount[this] = count;
    return count;
  }
  DateTime? get lastDiscoveredAt => _peripheralLastDiscoveredAt[this];
  int get discoveredCount => _peripheralDiscoveredCount[this] ?? 0;
  DateTime? get nextConnectAt => _peripheralNextConenctAt[this];

  /// ペリフェラルに接続したので，次の接続までに少なくとも1秒空ける．
  void setConnectAt(DateTime now) {
    _peripheralLastConnectAt[this] = now;
    _peripheralNextConenctAt[this] = now.add(const Duration(seconds: 1));
  }
  DateTime? get lastConnectAt => _peripheralLastConnectAt[this];

  /// ペリフェラルに接続エラーが発生したので，次の接続までに少なくとも10秒空ける．
  void setErrorAt(DateTime now) {
    final errorCount = (_peripheralLastConnectErrorCount[this] ?? 0) + 1;
    _peripheralLastConnectErrorCount[this] = errorCount;
    _peripheralNextConenctAt[this] = now.add(Duration(seconds: 10 * errorCount));
  }

  /// ニックネームの交換に成功したので，次の接続までにスロット時間を空ける．
  void setNicknameExchangedAt(DateTime now) {
    final slot = KeyManagementService().slot;
    _peripheralNextConenctAt[this] = now.add(slot);
    _peripheralLastConnectErrorCount[this] = 0; // 成功したのでエラー回数をリセット
  }
}

/// セントラルから接続された時刻を記録するためのMap
final Map<Central, DateTime> _centralLastAccessedAt = {};
final Map<Central, NicknameKeyPair> _centralKeyPair = {}; // centralのキーペア（centralの認証に使う）

extension CentralExtension on Central {
  /// セントラルが最後に接続された時刻を記録する．
  setLastAccessedAt(DateTime now) => _centralLastAccessedAt[this] = now;
  DateTime? get lastAccessedAt => _centralLastAccessedAt[this];

  setLocalKeyPair(NicknameKeyPair keyPair) => _centralKeyPair[this] = keyPair;
  NicknameKeyPair? get localKeyPair => _centralKeyPair[this];
}

final df = DateFormat('E HH:mm:ss'); // 'yyyy-MM-dd HH:mm:ss'

extension NicknameDateTime on DateTime {
  String shortStr() => df.format(this);
}