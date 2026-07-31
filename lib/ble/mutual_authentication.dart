/// BLEでニックネームを公開鍵として相互認証するBLEサービスを定義したファイル
library; // 上のドキュメントコメントをファイルに対するコメントにするためにlibraryと書いている．

import 'dart:async'; // Timer
import 'dart:math' show Random;
import 'package:flutter/foundation.dart'; // kDebugMode
import "package:bluetooth_low_energy/bluetooth_low_energy.dart";
import '../friend.dart';
import 'nickname.dart';
import '../key_management.dart';
import '../ffi/native_key_service.dart';

/// BLEでニックネームを公開鍵として相互認証するBLEサービス
/// 特性がread, writeされたときに署名生成・検証を行う
///
/// 先頭1バイトを使って，どの段階のデータを読み書きしているかを示すことにして，特性の数を1つだけにする．
///
/// C -> P: 1.
/// Peripheralの認証のためにCentralが課題（チャレンジ 32バイト）を書き込み（write）
///
/// C <- P: 2-1.
/// Centralに応答（レスポンス 64バイト）を返す通知（read）．
/// Centralは5で応答を検証する．友達でない場合も検証失敗とする．
///
/// C <- P: 2-2.
/// Centralの認証のために，Peripheralが課題（チャレンジ 32 バイト）を返す（read）
///
/// C -> P: 3-1.
/// Centralが検証結果（1バイト）を書き込む（write）
///
/// C -> P: 3-2.
/// Centralが応答（レスポンス 64バイト）を書き込む（write）．
/// Peripheralは応答を検証する．友達でない場合も検証失敗とする．
///
/// C <- P: 4.
/// Peripheralが検証結果を返す（read 1バイト）
class BleMutualAuthentication {
  /// PeripheralとCentralの間で相互認証するためにの特性識別子（Read, Write
  /// UUID）
  static final UUID authenticationCharacteristicUuid =
  UUID.fromString('D3534351-C5F4-4A63-A21A-974C68459ED2');

  /// Peripheralを認証するために，Centralが課題（チャレンジ）を書き込み，応答（レスポンス）を返すための特性（Characteristic）
  /// 図3.7 ... 山口賢紘 卒業論文「BLE
  /// を使った信頼関係に基づく近接認識方式の提案と実装」，2026年2月
  static final GATTCharacteristic authenticationCharacteristic =
  GATTCharacteristic.mutable(
    uuid: authenticationCharacteristicUuid,
    properties:
    [
      GATTCharacteristicProperty.write, // writeWithoutResponse,
      GATTCharacteristicProperty.read,
    ],
    permissions:
    [ // iOSがEncryptedだとペアリングを要求するので，Encryptedは使わない．
      GATTCharacteristicPermission.write, // writeEncrypted,
      GATTCharacteristicPermission.read,  // readEncrypted,
    ],
    descriptors: [],);

  /// シングルトン
  static final BleMutualAuthentication _instance = BleMutualAuthentication._internal();
  factory BleMutualAuthentication() { return _instance; }
  BleMutualAuthentication._internal(); // { }

  /// クラスが破棄される時にストリーム・コントローラーを閉じる
  void dispose() {
    // ストリームなどがあればclose()する．_localNicknameStreamController.close();
    // super.dispose();
  }

  static final challengeBytes = 32;
  static final responseBytes = 64;
  static final verifiedBytes = 1; // 3で成功．0x01: 応答検証OK, 0x02: 友達である
  static final maxPayloadSize = 1 + challengeBytes + responseBytes;

  final _rand = Random.secure();
  final _native = NativeKeyService();
  bool _verbose = false; // debugPrintが多すぎるので verbose = true の時だけ出力する

  /// Centralが認証シーケンスを処理する
  /// centralPubkey, peripheralPubkey はニックネームであり，公開鍵
  /// ToDo: 双方向認証を反対側から開始すると二重になるので避ける
  Future<bool> startAuthentication(Peripheral peripheral,
      GATTCharacteristic authenticationCharacteristic, // discoverGATT(peripheral) で得たもの．static finalと同じ型だが中身が違う
      { required NicknameKeyPair centralKeyPair,    // centralのニックネームに対応する秘密鍵
        required Uint8List peripheralPubKey, // peripheralのニックネームのこと
        required int friendId,      // 友達ID in friends テーブル
      }) async {
    assert(centralKeyPair.privateKey.length == 32 && peripheralPubKey.length == 33);
    // final mtu = await CentralManager().getMaximumWriteLength(peripheral, type: GATTCharacteristicWriteType.withResponse);  -> 512だった．
    try {
      // C -> P: 1. Peripheralの認証のためにCentralが課題（チャレンジ）を書き込み（write 16バイト or 32バイト）
      final challenge1 = await _firstCentral(peripheral, authenticationCharacteristic);
      if (kDebugMode && _verbose) {
        final challenge1Str = challenge1.hexStr(len: 4);
        print('BLE startAuthentication _FirstCentral: '
            'challenge1 $challenge1Str, '
            'peripheral ${peripheral.shortUuid}');
      }

      // C <- P: 2-1. Centralに応答（レスポンス）を返す通知（read or notify 64バイト）．Centralは応答を検証する
      //         2-2. Centralの認証のために，Peripheralが課題（チャレンジ）を返す（2と一緒にread or notify）
      final (verified1, challenge2) = await _secondCentral(peripheral, authenticationCharacteristic, challenge1, peripheralPubKey);
      // success1はperipheralの認証に成功したときtrue
      if (kDebugMode) {
        final challenge2Str = challenge2.hexStr(len: 4);
        print('BLE startAuthentication _SecondCentral: '
            'success1 $verified1, '
            'challenge2 $challenge2Str, '
            'peripheral ${peripheral.shortUuid}');
      }

      // C -> P: 3-1.
      //         3-2. Centralが応答（レスポンス）を書き込む（write）．Peripheralは応答を検証する
      final response2 = await _thirdCentral(peripheral,
          authenticationCharacteristic, centralKeyPair, verified1, challenge2);
      if (kDebugMode && _verbose) {
        final response2Str = response2.hexStr(len: 4);
        print('BLE startAuthentication _ThirdCentral: '
            'verified1 $verified1, '
            'response2 $response2Str, '
            'peripheral ${peripheral.shortUuid}');
      }

      // C <- P: 4.
      final verified2 = await _fourthCentral(peripheral, authenticationCharacteristic);

      // 相互認証に成功して，両者ともに友達と認識しているので，ユーザに通知する
      if (verified1 == 3 && verified2 == 3) {
        await BlePeerList().onFriendDetected(peripheral, friendId);
      }

      if (kDebugMode) {
        print('BLE startAuthentication done (3: success): '
            'verified1: $verified1, verified2: $verified2, peripheral ${peripheral.shortUuid}');
      }

      return verified1 == 0x03 ? true : false; // Peripheralの認証に成功．Centralの認証結果は不明
    } catch (e) { // Peripheralへの読み書きに失敗した．
      if (kDebugMode) {
        final list = await CentralManager().retrieveConnectedPeripherals();
        print('ERROR BLE startAuthentication:'
            ' peripheral: ${peripheral.shortUuid} cps: ${list.length}'
            ' error: $e');
      }
    }
    return false; // 相互認証失敗
  }

  /// Peripheralがwrite要求を受け取ったときの処理
  /// 先頭1バイトが要求のシーケンス番号
  Future<void> onWriteRequest(
      GATTCharacteristicWriteRequestedEventArgs event) async {
    final central = event.central;
    assert(event.request.offset == 0);
    final Uint8List value = event.request.value;
    final state = value.first;
    final payload = value.sublist(1);

    if ((central.state == _State.notStarted || central.state == _State.fourth) &&
        state == _State.first.value &&
        payload.length == challengeBytes) { // C -> P: 1
      final challenge1 = payload;
      await _onFirstPeripheral(event, challenge1);
      return; // 正常終了

    } else if (central.state == _State.second &&
        state == _State.third.value &&
        payload.length == verifiedBytes + responseBytes) { // C -> P: 3
      final verified1 = payload.first;
      final response2 = payload.sublist(1);
      await _onThirdPeripheral(event, verified1, response2);
      return; // 正常終了
    }

    // 不正なWrite
    // _PeripheralState.peripherals.remove(central.uuid);
    await PeripheralManager().respondWriteRequestWithError(
        event.request, error: GATTError.invalidPDU);
    if (kDebugMode) {
      final payloadStr = payload.hexStr(len: 8);
      print('ERROR BleMutualAuthentication onWriteRequest: state $state'
          ', payload: $payloadStr, '
          ', central: ${central.shortUuid}'
      );
    }
  }

  /// Peripheralがread要求を受け取ったときの処理
  /// 先頭1バイトが応答のシーケンス番号
  /// 未実装
  Future<void> onReadRequest(
      GATTCharacteristicReadRequestedEventArgs event) async {
    final central = event.central;

    if (central.state == _State.first) { // C <- P: 2-1, 2-2
      await _onSecondPeripheral(event);
      return;
    }

    if (central.state == _State.third ||
        central.state == _State.thirdVerificationFail) { // C <- P: 4
      await _onFourthPeripheral(event);
      return;
    }

    // 不正なRead
    // _PeripheralState.peripherals.remove(central.uuid);
    await PeripheralManager().respondReadRequestWithError(
        event.request, error: GATTError.invalidPDU);
    if (kDebugMode) {
      print('ERROR BleMutualAuthentication onReadRequest:'
          ' previous state ${central.state}'
          ', central: ${central.shortUuid}'
      );
    }
  }

  /// セントラル側
  /// C -> P: 1.
  Future<Uint8List> _firstCentral(
      Peripheral peripheral, GATTCharacteristic authenticationCharacteristic) async {
    final challenge1 = Uint8List.fromList(
        List.generate(challengeBytes, (_) => _rand.nextInt(256)));
    final payload = Uint8List.fromList([_State.first.value, ...challenge1]);
    await CentralManager().writeCharacteristic(peripheral, authenticationCharacteristic,
        value: payload, type: GATTCharacteristicWriteType.withResponse);
    return challenge1;
  }

  /// ペリフェラル側．
  /// C -> P: 1.
  Future<void> _onFirstPeripheral(
      GATTCharacteristicWriteRequestedEventArgs event,
      Uint8List challenge1) async {
    final central = event.central;
    if (kDebugMode && _verbose) {
      final challenge1Str = challenge1.hexStr(len: 4);
      print('BleMutualAuthentication _onFirstPeripheral: '
          'challenge1 $challenge1Str, '
          'central: ${event.central.shortUuid}');
    }
    if (central.nickname == null) {
      await PeripheralManager().respondWriteRequestWithError(event.request, error: GATTError.invalidPDU);
      return; // エラー
    }
    await PeripheralManager().respondWriteRequest(event.request);
    central.state = _State.first;
    central.challenge1 = challenge1;
  }

  /// セントラル側
  /// C <- P: 2-1, 2-2.
  Future<(int, Uint8List)> _secondCentral(
      Peripheral peripheral, GATTCharacteristic authenticationCharacteristic,
      Uint8List challenge1,
      Uint8List peripheralPubkey) async {
    final value = await CentralManager().readCharacteristic(peripheral, authenticationCharacteristic);
    if (value.length != 1 + responseBytes + challengeBytes) {
      // Peripheralからのデータ長が不正
      throw FormatException('ペリフェラルから受信したデータ長が${1 + responseBytes + challengeBytes}ではありません', value);
    }
    final state = value[0];
    if (state != _State.second.value) {
      throw throw FormatException('ペリフェラルから受信したデータの先頭が${_State.second.value}ではありません', value);
    }
    final response1 = value.sublist(1, 1 + responseBytes);
    final challenge2 = value.sublist(1 + responseBytes);
    
    int verified1 = 2; // startAuthenticationの呼び出し元で友達であることを確認済み
    final result = _native.verifyChallenge(peripheralPubkey, challenge1, response1);
    if (result) verified1 |= 1;
    
    return (verified1, challenge2);
  }

  /// ペリフェラル側．
  /// C <- P: 2-1, 2-2.
  Future<void> _onSecondPeripheral(
      GATTCharacteristicReadRequestedEventArgs event) async {
    final central = event.central;
    final challenge1 = central.challenge1;
    final localKeyPair = central.localKeyPair; // 鍵ペアの更新タイミングで変わると失敗
    final offset = event.request.offset;

    if (localKeyPair == null) {
      await PeripheralManager().respondReadRequestWithError(event.request, error: GATTError.invalidPDU);
      if (kDebugMode) {
        print('ERROR BleMutualAuthentication _onSecondPeripheral: '
            'can not sign because localKeyPair is null, central: ${central.shortUuid}');
      }
      return; // エラー．自分の鍵ペアがないので署名できない
    }

    // FFIでエラーなら0で埋めたresponse1で処理を続ける．
    final response1 = _native.signChallenge(localKeyPair.privateKey, challenge1) ??
        Uint8List(responseBytes);
    // response1![0] = 0; // 認証に失敗するテストをするときに使う

    final challenge2 = Uint8List.fromList(
        List.generate(challengeBytes, (_) => _rand.nextInt(256)));
    if (kDebugMode && _verbose) {
      debugPrint('BleMutualAuthentication _onSecondPeripheral: '
          'response1: ${response1.hexStr(len: 4)}, '
          'challenge2: ${challenge2.hexStr(len: 4)}, '
          'central: ${event.central.shortUuid}');
    }
    final payload = Uint8List.fromList([
      _State.second.value,
      ...response1,
      ...challenge2]); // ...でリストを展開（Spread 演算子）
    await PeripheralManager().respondReadRequestWithValue(
      event.request,
      value: payload.sublist(offset),
    );

    central.state = _State.second;
    central.response1 = response1;
    central.challenge2 = challenge2;
  }

  /// セントラル側．
  /// C -> P: 3-1, 3-2.
  Future<Uint8List> _thirdCentral(
      Peripheral peripheral, GATTCharacteristic authenticationCharacteristic,
      NicknameKeyPair centralKeyPair,
      int verified1,
      Uint8List challenge2) async {
    // centralPriKeyとchallenge2を使って，response2を計算してperipheralに送る
    var response2 = await _native.signChallenge(centralKeyPair.privateKey, challenge2);
    if (response2 == null) { // _nativeでエラーになったときは
      response2 = Uint8List(responseBytes);
      if (kDebugMode) debugPrint('signChallenge failed in _thirdCentral'); // ToDo: エラー処理
    }

    final payload = Uint8List.fromList([_State.third.value, verified1, ...response2]);
    await CentralManager().writeCharacteristic(peripheral, authenticationCharacteristic,
        value: payload, type: GATTCharacteristicWriteType.withResponse);
    return response2;
  }

  /// ペリフェラル側．
  /// C -> P: 3-1, 3-2.
  Future<void> _onThirdPeripheral(
      GATTCharacteristicWriteRequestedEventArgs event,
      int verified1,
      Uint8List response2) async {
    final central = event.central;
    final centralNickname = central.nickname;
    final challenge2 = central.challenge2;
    var verified2 = 0;

    if (centralNickname == null) {
      await PeripheralManager().respondWriteRequestWithError(event.request, error: GATTError.invalidPDU);
      return; // エラー
    }

    // centralを認証するために，response2をchallenge2とcentralの公開鍵で検証する．
    final result = _native.verifyChallenge(centralNickname, challenge2, response2);
    if (result) verified2 |= 1;

    final matchedFriendId = await FriendList().getFriendByNickname(centralNickname);
    if (matchedFriendId != null) {
      verified2 |= 2;
    }

    if (kDebugMode) { //
      final response2Str = response2.hexStr(len: 4);
      print('BleMutualAuthentication _onThirdPeripheral: '
          'verified2: $verified2, '
          'response2  $response2Str, '
          'central: ${event.central.shortUuid}');
    }
    // ペリフェラル側でのセントラルの認証に成功
    await PeripheralManager().respondWriteRequest(event.request);

    central.verified2 = verified2;
    // 相互認証の成否をcentral.stateに記録する
    if (verified1 == 3 && verified2 == 3) {
      central.state = _State.third;
    } else {
      central.state = _State.thirdVerificationFail;
    }
    central.matchedFriendId = matchedFriendId;
  }

  /// セントラル側
  /// C <- P: 4.
  Future<int> _fourthCentral(
      Peripheral peripheral, GATTCharacteristic authenticationCharacteristic) async {
    final value = await CentralManager().readCharacteristic(peripheral, authenticationCharacteristic);
    final expectedLength = 1 + verifiedBytes;
    if (value.length != expectedLength) {
      throw FormatException('ペリフェラルから受信したデータ長が${expectedLength}ではありません', value);
    }

    final state = value[0];
    final expectedState = _State.fourth.value;
    if (state != expectedState) {
      throw throw FormatException('ペリフェラルから受信したデータの先頭が${expectedState}ではありません', value);
    }
    final verified1 = value[1];
    return verified1;
  }

  /// ペリフェラル側．
  /// C <- P: 4.
  Future<void> _onFourthPeripheral(
      GATTCharacteristicReadRequestedEventArgs event) async {
    final central = event.central;
    final state = central.state;
    final verified2 = central.verified2;
    final offset = event.request.offset;

    if (kDebugMode) {
      debugPrint('BleMutualAuthentication _onFourthPeripheral: '
          'verified2: $verified2, '
          'isAuthenticated: ${state == _State.third}, '
          'central: ${event.central.shortUuid}');
    }
    final payload = Uint8List.fromList([_State.fourth.value, verified2]);
    await PeripheralManager().respondReadRequestWithValue(
      event.request,
      value: payload.sublist(offset),
    );

    // 認証が終わった
    if (state == _State.third) {
      final matchedFriendId = central.matchedFriendId;
      if (matchedFriendId != null) {
        BlePeerList().onFriendDetected(central, matchedFriendId);
      }
    }
    central.state = _State.fourth;

    // 後片付け
    // 残す _centralMAuthState.remove(central);
    _centralMAuthChallenge1.remove(central);
    _centralMAuthResponse1.remove(central);
    _centralMAuthChallenge2.remove(central);
    _centralMAuthVerified2.remove(central);
    _centralMAuthFriendId.remove(central);
  }
}

enum _State {
  notStarted(0),
  /// C -> P: 1.
  /// Peripheralの認証のためにCentralが課題（チャレンジ）を書き込み（write
  /// 16バイト or 32バイト）
  first(1),
  /// C <- P: 2-1. Centralに応答（レスポンス）を返す通知（read64バイト）．Centralは応答を検証する
  ///         2-2. Centralの認証のために，Peripheralが課題（チャレンジ）を返す
  second(2),
  /// C -> P: 3-1. Centralが検証結果（1バイト）を書き込む
  ///         3-2. Centralが応答（レスポンス）を書き込む（write）．Peripheralは応答を検証する
  third(3), /// 相互認証成功
  /// 相互認証失敗
  thirdVerificationFail(13),
  /// C <- P: 4.
  fourth(4);
  final int value;
  const _State(this.value);
}

/// セントラルとの相互認証の経過を記録するためのMap
///
/// ToDo: 定期的に古いものを削除する．メモリリーク対策
final Map<Central, _State> _centralMAuthState = {};
final Map<Central, Uint8List> _centralMAuthChallenge1 = {};      // centralからperipheralへ
final Map<Central, Uint8List> _centralMAuthResponse1 = {};  // peripheralからcentralへ
final Map<Central, Uint8List> _centralMAuthChallenge2 = {}; // peripheralからcentralへ
final Map<Central, int> _centralMAuthVerified2 = {}; // _onThirdPeripheral で記録し _onFourthPeripheralで使う
final Map<Central, int> _centralMAuthFriendId = {}; // 一時的なデータを格納するためのMap

extension CentralMutualAuthenticationExtension on Central {
  set state(_State state) => _centralMAuthState[this] = state;
  _State get state => _centralMAuthState[this] ?? _State.notStarted;

  set challenge1(Uint8List challenge1) => _centralMAuthChallenge1[this] = challenge1;
  Uint8List get challenge1 => _centralMAuthChallenge1[this] ?? Uint8List(BleMutualAuthentication.challengeBytes);

  set response1(Uint8List response1) => _centralMAuthResponse1[this] = response1;
  Uint8List get response1 => _centralMAuthResponse1[this] ?? Uint8List(BleMutualAuthentication.responseBytes);

  set challenge2(Uint8List challenge2) => _centralMAuthChallenge2[this] = challenge2;
  Uint8List get challenge2 => _centralMAuthChallenge2[this] ?? Uint8List(BleMutualAuthentication.challengeBytes);

  set verified2(int verified2) => _centralMAuthVerified2[this] = verified2;
  int get verified2 => _centralMAuthVerified2[this] ?? 0;

  set matchedFriendId(int? friendId) {
    if (friendId != null) {
      _centralMAuthFriendId[this] = friendId;
    }
  }
  int? get matchedFriendId => _centralMAuthFriendId[this];
}
