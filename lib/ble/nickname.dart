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
import 'dart:math' show min, Random;       // min
// import 'dart:collection';
import 'package:flutter/foundation.dart'; // kDebugMode
import "package:bluetooth_low_energy/bluetooth_low_energy.dart";
import 'package:convert/convert.dart' show hex; // hex.decode(Uint8List)のため
import '../key_management.dart';
import 'peripheral.dart';
import 'central.dart';
import 'mutual_authentication.dart';

/// BLEで広告するニックネームや受信したニックネームを処理するクラス
class BleNickname extends ChangeNotifier {
  /// サービス識別子（UUID）
  static final UUID serviceUuid = UUID.fromString('D353434A-C5F4-4A63-A21A-974C68459ED2');
  /// Peripheral自身のニックネームをCentralが読み取り（read）
  /// CoetralのニックネームをPeripheralに書き込む（write）ための特性識別子（UUID）
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

  /// 広告とスキャンのON/OFF
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

  /// ニックネーム・ストリーム・コントローラ：時間が経過して新しくなったニックネームをペリフェラルとセントラルに通知する
  ///
  /// 通知するこのクラスは
  /// _localNicknameStreamController.add(Uint8list);
  /// クラスが破棄される時にストリーム・コントローラーを閉じる
  /// _localNicknameStreamController.close();
  // 削除 // static final StreamController<Uint8List> _localNicknameStreamController = StreamController<Uint8List>.broadcast();
  /// ストリーム：時間が経過して新しくなったニックネームをペリフェラルとセントラルに通知する
  ///
  /// 受け取る側は
  /// ```
  /// final bleNickname = BleNickname();
  /// bleNickname.localNicknameStream.listen((nickname) {
  ///   print('ニックネームを受信: $nickname');
  /// });
  /// ```
  // Stream<Uint8List> get localNicknameStream => _localNicknameStreamController.stream;

  /// ダミーニックネームの生成器
  // DummyNicknameGenerator generator = DummyNicknameGenerator();
  /// ニックネームの更新タイマー（key_management.dartに任せて _timer は不要に）
  // Timer? _timer;
  /// ニックネームの前回のスロット
  int _lastSlotStartTime = 0;
  /// ニックネームの前回のニックネーム
  Uint8List _lastNickname = Uint8List(33);
  /// ニックネームの前回のスロット（変更はlocalNicknameStreamで通知するので最初だけ）
  Uint8List get localNickname => _lastNickname;
  ///
  final _random = Random();
  /// ニックネームの更新（タイマーで呼び出す）
  void _updateNickname(void _) async {
    final currentValidDuration = Duration(milliseconds: _kms.slotMs);
    if (validDuration != currentValidDuration) {
      validDuration = currentValidDuration;
      _timer?.cancel();
      _timer = Timer.periodic(validDuration, _updateNickname);
    }
    if (_lastNickname[0] != 0x00) {
      // [0] == 0x00の場合，アプリ実行後の最初のニックネームでは，待ち時間なし．
      // ニックネームの更新
      // validDuration の半分の時間程度まで適当に広告を遅れさせて揺らぎを持たせる．
      final jitter = _random.nextInt(validDuration.inMilliseconds ~/ 2);
      await Future.delayed(Duration(milliseconds: jitter));
    }
    // 杉浦プロジェクトと同様（3行）
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int slotMillis = validDuration.inMilliseconds;
    final slotStartTime = (now ~/ slotMillis) * slotMillis; // (now ~/ slotMillis) は (int)(now / slotMillis) と同じ

    if (_lastSlotStartTime != slotStartTime) { // 時間が経っていなら更新しない．
      _lastSlotStartTime = slotStartTime;
      _lastNickname = await _kms.getPublicKeyForBleAdvertise().catchError((e, st) {
        if (kDebugMode) {
          debugPrint('_updateNickname: getPublicKeyForBleAdvertise failed: $e');
        }
        throw e;
      });
      if (_advertiser.isAdvertising) {
        await _advertiser.restart();
      }
      if (kDebugMode) print('_updateNickname: ${nickname2string(_lastNickname)}, $validDuration, ${DateTime.fromMillisecondsSinceEpoch(now)}');
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
    if (kDebugMode) print('nickname _start ${nickname2string(_lastNickname)} ${_kms.slotMs}');
    // _localNicknameStreamController.add(Uint8List.fromList(_lastNickname!)); // 通知する
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
        if (kDebugMode) {
          debugPrint('BLE_SCAN: new collected key stored');
        }
      }
    }
  }

  /// クラスが破棄される時にストリーム・コントローラーを閉じる
  void dispose() {
    // _localNicknameStreamController.close();
    _timer?.cancel();
    _keyUpdateSub?.cancel();
    super.dispose();
  }

  /// 33バイトのニックネームを16進表現の文字列にして，4バイトごとに_アンダースコアで区切る．クラスメソッド．主にデバッグ用
  static String nickname2string(Uint8List bytes, {int len = 33}) {
    final hexString = hex.encode(bytes.sublist(0, min(len, bytes.length)));
    return RegExp(r'.{1,8}(?=(?:.{8})*$)').allMatches(hexString).map((m) => m.group(0)).join('_');
  }
}

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
