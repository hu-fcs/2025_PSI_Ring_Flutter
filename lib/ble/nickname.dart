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
// import 'dart:js_interop';
import 'dart:typed_data'; // Uint8List
import 'dart:math' show Random;       // min
// import 'dart:collection';
import 'package:flutter/foundation.dart'; // kDebugMode
import "package:bluetooth_low_energy/bluetooth_low_energy.dart";
import 'package:convert/convert.dart' show hex; // hex.decode(Uint8List)のため
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

  void _onStateChanged() {
    if (kDebugMode) print('_onStateChanged: ${_advertiser.isAdvertising} ${_scanner.isScanning}');
    _isRunning = _advertiser.isAdvertising && _scanner.isScanning;
    notifyListeners();
  }

  // シングルトン
  static final BleNickname _instance = BleNickname._internal();
  /// シングルトン：このクラスのオブジェクトは一つだけ．
  factory BleNickname() {
    return _instance;
  }
  BleNickname._internal() {
    _timer = Timer.periodic(validDuration, _updateNickname);
    _advertiser.addListener(_onStateChanged);
    _scanner.addListener(_onStateChanged);
    // _keyUpdateSub = _kms.onKeyUpdated.listen(_updateNickname); // 広告・スキャンONのタイミングに変更
  }

  /// クラスが破棄される時にストリーム・コントローラーを閉じる
  @override
  void dispose() {
    // _localNicknameStreamController.close();
    _timer?.cancel();
    _keyUpdateSub?.cancel();
    super.dispose();
  }

  /// BLE広告（アドバタイズ）とスキャンのON/OFF切り替え
  Future<void> toggleExchange() async {
    if (isRunning) {
      _keyUpdateSub?.cancel();
      _timer?.cancel();
      await _scanner.stopScan();
      await _advertiser.stop();
    } else {
      _keyUpdateSub = _kms.onKeyUpdated.listen(_updateNickname);
      _start();
      if (! _advertiser.isAdvertising) await _advertiser.start();
      if (! _scanner.isScanning) await _scanner.startScan();
    }
  }

  /// ニックネームの前回のスロット
  int _lastSlotStartTime = 0;
  /// ニックネームの前回のニックネーム
  Uint8List _lastLocalNickname = Uint8List(33);
  /// ニックネームの前回のスロット（変更はlocalNicknameStreamで通知するので最初だけ）
  Uint8List get localNickname => _lastLocalNickname;
  /// ニックネームの前回のニックネーム
  Uint8List _lastLocalPrivateKey = Uint8List(33); // ToDo: KeyPairを保持したほうがいよさそう
  /// ニックネームの前回のスロット（変更はlocalNicknameStreamで通知するので最初だけ）
  Uint8List get lastLocalPrivateKey => _lastLocalPrivateKey;

  final _insecureRandom = Random();

  /// ニックネームの更新（タイマーで呼び出す）
  /// validDuration の半分の時間程度まで適当に広告を遅れさせて揺らぎを持たせる．
  void _updateNickname(void _) async {
    final currentValidDuration = Duration(milliseconds: _kms.slotMs);
    if (validDuration != currentValidDuration) {
      validDuration = currentValidDuration;
      _timer?.cancel();
      _timer = Timer.periodic(validDuration, _updateNickname);
    }
    if (_lastLocalNickname[0] != 0x00) {
      // [0] == 0x00の場合，アプリ実行後の最初のニックネームでは，待ち時間なし．
      // ニックネームの更新
      final jitter = _insecureRandom.nextInt(validDuration.inMilliseconds ~/ 2);
      await Future.delayed(Duration(milliseconds: jitter));
    }
    // 杉浦プロジェクトと同様（3行）
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int slotMillis = validDuration.inMilliseconds;
    final slotStartTime = (now ~/ slotMillis) * slotMillis; // (now ~/ slotMillis) は (int)(now / slotMillis) と同じ

    if (_lastSlotStartTime != slotStartTime) { // 時間が経っていなら更新しない．
      _lastSlotStartTime = slotStartTime;
      final keyPair = await _kms.getKeyPairForBleAdvertise().catchError((e, st) {
        if (kDebugMode) {
          debugPrint('BleNickname: getKeyPairForBleAdvertise failed: $e');
        }
        throw e;
      });
      _lastLocalNickname = keyPair.publicKey;
      _lastLocalPrivateKey = keyPair.privateKey;

      if (_advertiser.isAdvertising) {
        await _advertiser.restart();
      }
      if (kDebugMode) print('_updateNickname: ${nickname2string(_lastLocalNickname)}, $validDuration, ${DateTime.fromMillisecondsSinceEpoch(now)}');
    }
    // _localNicknameStreamController.add(Uint8List.fromList(_lastNickname!)); // 通知する
    // BleRemoteMap().addRemote(_lastNickname!, DateTime.now(), local: true);
  }

  Future<void> _start() async {
    final keyPair = await _kms.getKeyPairForBleAdvertise().catchError((e, st) {
      if (kDebugMode) {
        debugPrint('BleNickname: getKeyPairForBleAdvertise failed: $e');
      }
      throw e;
    });
    _lastLocalNickname = keyPair.publicKey;
    _lastLocalPrivateKey = keyPair.privateKey;
    if (kDebugMode) print('nickname _start ${nickname2string(_lastLocalNickname)} ${_kms.slotMs}');
    // _localNicknameStreamController.add(Uint8List.fromList(_lastNickname!)); // 通知する
  }

  /// リモートのニックネームをリモートのuuidから探せるようにするMap
  /// ペリフェラルが相互認証するときにセントラルのニックネームを調べる必要があるため
  final Map<UUID, ({Uint8List nickname, DateTime time})> _remoteNicknameCache = {};
  /// _remoteNicknameCache から古いエントリーを削除するためのタイマー
  Timer? _remoteNicknameCacheTimer;

  /// リモートのニックネームを追加
  Future<void> addRemote(Uint8List nickname, DateTime now, {UUID? peripheralUuid, UUID? centralUuid, bool local = false}) async {
    if (! local) { // リモートのニックネームを追加
      // 収集鍵として collected_keys テーブルに登録する
      final inserted = await _kms.insertCollectedKeyIfAbsent(
        pubkey33: nickname,
        receivedAtMs: now.millisecondsSinceEpoch,
      );
      if (inserted) {
        if (kDebugMode) {
          debugPrint('BLE_SCAN: new collected key stored');
        }
      }

      // 相互認証のPeripheral側でCentralのニックネームを探せるように記録する
      if (centralUuid != null) {
        _remoteNicknameCache[centralUuid] = (nickname: nickname, time: now);

        // _remoteNicknameCache に残っている古いエントリーを削除するために周期タイマーを動かす．
        // もし，すでにタイマーがセットいたら，新しいタイマーは動かさない
        _remoteNicknameCacheTimer ??= Timer.periodic(const Duration(minutes: 30), (timer) {
          // タイマーの動作．30分経過したリモートニックネームは _remoteNicknameCache から削除する
          final expireTime = DateTime.now().subtract(Duration(minutes: 3));
          _remoteNicknameCache.removeWhere((key, value) =>
              value.time.isBefore(expireTime));
          // _remoteNicknameCache から空になったら周期タイマーを停止
          if (_remoteNicknameCache.isEmpty) {
            timer.cancel();
            _remoteNicknameCacheTimer = null;
          }
        });
      }
    }
  }

  /// Peripheral側でCentralのニックネームを探す．
  Uint8List? findRemoteNickname(UUID centralUuid) => _remoteNicknameCache[centralUuid]?.nickname;

  /// 友達ニックネームにマッチした & 認証結果を UI に通知するためのコールバック
  void Function(String friendLabel, bool authenticated)? onFriendDetected;

  /// 33バイトのニックネームを16進表現の文字列にして，4バイトごとに_アンダースコアで区切る．クラスメソッド．主にデバッグ用
  static String nickname2string(Uint8List bytes, {int len = 0}) {
    if (len == 0) len = bytes.length;
    final hexString = hex.encode(bytes.sublist(0, len));
    final joined = RegExp(r'.{1,8}(?=(?:.{8})*$)').allMatches(hexString).map((m) => m.group(0)).join('_');
    if (len < bytes.length) {
      return '$joined...';
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