/// BLEでニックネームを公開鍵として相互認証するBLEサービスを定義したファイル
library; // 上のドキュメントコメントをファイルに対するコメントにするためにlibraryと書いている．

import 'dart:async'; // Timer
import 'dart:ffi';
import 'dart:typed_data';                 // Uint8List
import 'dart:collection';                 // LinkedHashMap
import 'dart:math' show Random;
import 'package:flutter/foundation.dart'; // kDebugMode
import "package:bluetooth_low_energy/bluetooth_low_energy.dart";
import 'nickname.dart';
import '../key_management.dart';
import '../ffi/native_key_service.dart';

/// BLEでニックネームを公開鍵として相互認証するBLEサービス
/// 特性がread, writeされたときに署名生成・検証を行う
///
/// 先頭1バイトを使って，1から4のどの段階のデータを読み書きしているかを示すことにして，特性の数を1つだけにする．
///
/// C -> P: 1.
/// Peripheralの認証のためにCentralが課題（チャレンジ）を書き込み（write
/// 16バイト or 32バイト）
///
/// C <- P: 2.
/// Centralに応答（レスポンス）を返す通知（read or notify
/// 64バイト）．Centralは応答を検証する
///
/// C <- P: 3.
/// Centralの認証のために，Peripheralが課題（チャレンジ）を返す（2と一緒にread
/// or notify）
///
/// C -> P: 4.
/// Centralが応答（レスポンス）を書き込む（write）．Peripheralは応答を検証する
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
    [
      GATTCharacteristicPermission.writeEncrypted, // writeEncrypted,
      GATTCharacteristicPermission.readEncrypted,  // readEncrypted,
    ],
    descriptors: [],);

  /// シングルトン
  static final BleMutualAuthentication _instance =
  BleMutualAuthentication._internal();

  /// シングルトン：このクラスのオブジェクトは一つだけ．
  factory BleMutualAuthentication() {
    return _instance;
  }

  BleMutualAuthentication._internal(); // { }

  /// クラスが破棄される時にストリーム・コントローラーを閉じる
  void dispose() {
    // ストリームなどがあればclose()する．_localNicknameStreamController.close();
    // super.dispose();
  }

  static final challengeLen = 32;
  static final responseBytes = 64;
  final _rand = Random.secure();
  final _native = NativeKeyService();

  /// Centralが認証シーケンスを処理する
  /// centralPubkey, peripheralPubkey はニックネームであり，公開鍵
  /// ToDo: 双方向認証を反対側から開始すると二重になるので避ける
  Future<bool> startAuthentication(Peripheral peripheral,
      GATTCharacteristic authenticationCharacteristic, // discoverGATT(peripheral) で得たもの．static finalと同じ型だが中身が違う
      { required Uint8List centralPriKey,  // centralのニックネームに対応する秘密鍵
        required Uint8List peripheralPubKey, // peripheralのニックネームのこと
      }) async {
    assert(centralPriKey.length == 32 && peripheralPubKey.length == 33);
    // final mtu = await CentralManager().getMaximumWriteLength(peripheral, type: GATTCharacteristicWriteType.withResponse);  -> 512だった．
    try {
      // C -> P: 1. Peripheralの認証のためにCentralが課題（チャレンジ）を書き込み（write 16バイト or 32バイト）
      final challenge1 = await _firstCentral(peripheral, authenticationCharacteristic);
      if (kDebugMode) {
        print('BLE startAuthentication _FirstCentral: '
            'challenge1 (${challenge1.length}) ${BleNickname.nickname2string(challenge1)}, '
            'peripheral ${peripheral.uuid}');
      }

      // C <- P: 2. Centralに応答（レスポンス）を返す通知（read or notify 64バイト）．Centralは応答を検証する
      //         3. Centralの認証のために，Peripheralが課題（チャレンジ）を返す（2と一緒にread or notify）
      final (success1, challenge2) = await _secondCentral(peripheral, authenticationCharacteristic, challenge1, peripheralPubKey);
      // success1はperipheralの認証に成功したときtrue
      if (kDebugMode) {
        print('BLE startAuthentication _SecondCentral: '
            'success1 $success1, '
            'challenge2 (${challenge2.length}) ${BleNickname.nickname2string(challenge2)}, '
            'peripheral ${peripheral.uuid}');
      }

      // C -> P: 4. Centralが応答（レスポンス）を書き込む（write）．Peripheralは応答を検証する
      final response2 = await _thirdCentral(peripheral, authenticationCharacteristic, centralPriKey, challenge2);
      if (kDebugMode) {
        print('BLE startAuthentication _ThirdCentral: '
            'response2 (${response2.length}) ${BleNickname.nickname2string(response2)}, '
            'peripheral ${peripheral.uuid}');
      }

      return success1; // Peripheralの認証に成功．Centralの認証結果は不明
    } catch (e) { // Peripheralへの読み書きに失敗した．
      if (kDebugMode) {
        print('ERROR BLE startAuthentication: $e, '
            'peripheral: ${peripheral.uuid}');
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
    if (state == _State.first.value && payload.length == challengeLen) { // C -> P: 1
      final challenge1 = payload;
      await _onFirstPeripheral(event, challenge1);
      return;

    } else {
      final authPeripheral = _PeripheralState.peripherals[central.uuid];
      if (authPeripheral != null && authPeripheral.state == _State.second
          && state == _State.third.value && payload.length == responseBytes) { // C -> P: 3
        final response2 = payload;
        final success2 = await _onThirdPeripheral(event, authPeripheral, response2);
        // ToDo: 認証成功・失敗（verificationResult）を伝える．どこにどうやって？
      }
    }

    // 不正なWrite
    if (kDebugMode) {
      print('ERROR BleMutualAuthentication onWriteRequest: state $state, '
          'payload: (${payload.length}) ${BleNickname.nickname2string(payload)}, '
          'central: ${central.uuid}, '
      );
    }
    _PeripheralState.peripherals.remove(central.uuid);
    await PeripheralManager().respondWriteRequestWithError(
        event.request, error: GATTError.invalidPDU);
  }

  /// Peripheralがread要求を受け取ったときの処理
  /// 先頭1バイトが応答のシーケンス番号
  /// 未実装
  Future<void> onReadRequest(
      GATTCharacteristicReadRequestedEventArgs event) async {
    final central = event.central;
    final authPeripheral = _PeripheralState.peripherals[central.uuid];
    if (authPeripheral != null && authPeripheral.state == _State.first) {
      await _onSecondPeripheral(event, authPeripheral);
      authPeripheral.state == _State.second;
      return;

    }

    // 不正なRead
    _PeripheralState.peripherals.remove(central.uuid);
    await PeripheralManager().respondReadRequestWithError(
        event.request, error: GATTError.invalidPDU);
  }

  /// セントラル側
  /// C -> P: 1.
  Future<Uint8List> _firstCentral(
      Peripheral peripheral, GATTCharacteristic authenticationCharacteristic) async {
    final challenge1 = Uint8List.fromList(
        List.generate(challengeLen, (_) => _rand.nextInt(256)));
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
    if (kDebugMode) {
      print('BleMutualAuthentication _onFirstPeripheral: '
          'challenge1 (${challenge1.length}) ${BleNickname.nickname2string(challenge1)}, '
          'central: ${event.central.uuid}');
    }
    _PeripheralState(central: event.central, challenge1: challenge1);
    await PeripheralManager().respondWriteRequest(event.request);
  }

  /// セントラル側
  /// C <- P: 2. 3.
  Future<(bool, Uint8List)> _secondCentral(
      Peripheral peripheral, GATTCharacteristic authenticationCharacteristic,
      Uint8List challenge1,
      Uint8List peripheralPubkey) async {
    final value = await CentralManager().readCharacteristic(peripheral, authenticationCharacteristic);
    if (value.length != 1 + responseBytes + challengeLen) {
      // Peripheralからのデータ長が不正
      throw FormatException('ペリフェラルから受信したデータ長が${1 + responseBytes + challengeLen}ではありません', value);
    }
    final state = value[0];
    if (state != _State.second.value) {
      throw throw FormatException('ペリフェラルから受信したデータの先頭が${_State.second.value}ではありません', value);
    }
    final response1 = value.sublist(1, 1 + responseBytes);
    final challenge2 = value.sublist(1 + responseBytes);

    // ToDo: challenge1とperipheralPubkeyを使って，response1の検証結果をverificationResultに
    final verificationResult = _native.verifyChallenge(peripheralPubkey, challenge1, response1);
    return (verificationResult, challenge2);
  }

  /// ペリフェラル側．
  /// C <- P: 2. 3.
  Future<void> _onSecondPeripheral(
      GATTCharacteristicReadRequestedEventArgs event,
      _PeripheralState authPeripheral) async {
    final challenge1 = authPeripheral.challenge1;
    final keyPair = await KeyManagementService().getLatestKeyPair();
    if (keyPair == null) {
      return; // ToDo: エラー処理
    }
    assert(listEquals(keyPair.publicKey, BleNickname().localNickname));

    final response1 = _native.signChallenge(keyPair.privateKey, challenge1);
    if (response1 == null) {
      return; // ToDo: エラー処理
    }

    final challenge2 = Uint8List.fromList(
        List.generate(challengeLen, (_) => _rand.nextInt(256)));
    if (kDebugMode) {
      print('BleMutualAuthentication _onSecondPeripheral: '
          'response1: (${response1.length}) ${BleNickname.nickname2string(response1)}, '
          'challenge2: (${challenge2.length}) ${BleNickname.nickname2string(challenge2)}, '
          'central: ${event.central.uuid}');
    }
    final payload = Uint8List.fromList([
      _State.second.value,
      ...response1,
      ...challenge2]); // ...でリストを展開（Spread 演算子）
    await PeripheralManager().respondReadRequestWithValue(
      event.request,
      value: payload,
    );

    authPeripheral.state = _State.second;
    authPeripheral.response1 = response1;
    authPeripheral.challenge2 = challenge2;
    return;
  }

  /// セントラル側．
  /// C -> P: 4.
  Future<Uint8List> _thirdCentral(
      Peripheral peripheral, GATTCharacteristic authenticationCharacteristic,
      Uint8List centralPriKey,
      Uint8List challenge2) async {
    // ToDo: centralPriKeyとchallenge2を使って，response2を計算してperipheralに送る
    final response2 = _native.signChallenge(centralPriKey, challenge2);
    if (response2 == null) {
      return Uint8List(0); // ToDo: エラー処理
    }

    final payload = Uint8List.fromList([_State.third.value, ...response2]);
    await CentralManager().writeCharacteristic(peripheral, authenticationCharacteristic,
        value: payload, type: GATTCharacteristicWriteType.withResponse);
    return response2;
  }

  /// ペリフェラル側．
  /// C -> P: 4.
  Future<bool> _onThirdPeripheral(
      GATTCharacteristicWriteRequestedEventArgs event,
      _PeripheralState authPeripheral,
      Uint8List response2) async {
    final challenge2 = authPeripheral.challenge2;
    // ToDo: centralPubkey を持ってくる．
    final centralPubkey = Uint8List(32); // ダミー
    final verificationResult2 = _native.verifyChallenge(centralPubkey, challenge2, response2);

    if (kDebugMode) {
      print('BleMutualAuthentication _onThirdPeripheral: '
          'response2 (${response2.length}) ${BleNickname.nickname2string(response2)}, '
          'central: ${event.central.uuid}');
    }
    // 認証が終わったので後片付け．
    _PeripheralState.peripherals.remove(event.central.uuid);
    await PeripheralManager().respondWriteRequest(event.request);
    return verificationResult2;
  }
}

enum _State {
  /// C -> P: 1.
  /// Peripheralの認証のためにCentralが課題（チャレンジ）を書き込み（write
  /// 16バイト or 32バイト）
  first(1),
  /// C <- P: 2. Centralに応答（レスポンス）を返す通知（read or notify
  /// 64バイト）．Centralは応答を検証する
  ///         3.
  ///         Centralの認証のために，Peripheralが課題（チャレンジ）を返す（2と一緒にread
  ///         or notify）
  second(2),
  /// C -> P: 4.
  /// Centralが応答（レスポンス）を書き込む（write）．Peripheralは応答を検証する
  third(3);
  final int value;
  const _State(this.value);
}

class _PeripheralState {
  static final LinkedHashMap<UUID, _PeripheralState> peripherals = LinkedHashMap();
  final Central central;
  late _State state;
  late final DateTime time;        // 古いものを削除する（ToDo: 5分経過したものを削除．メモリリーク対策）
  final Uint8List challenge1;      // centralからperipheralへ
  late final Uint8List response1;  // peripheralからcentralへ
  late final Uint8List challenge2; // peripheralからcentralへ
  late final Uint8List response2;  // centralからperipheralへ

  _PeripheralState({required this.central, required this.challenge1}) {
    state = _State.first;
    time = DateTime.now();
    peripherals[central.uuid] = this;
  }
}

