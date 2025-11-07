// lib/ble/ble_advertiser.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:pointycastle/export.dart' as pc;

import 'ble_constants.dart';
import 'key_advertise_repository.dart';

/// 2パート(front/back)を Manufacturer Data で交互送信する Advertiser。 (★ 仕様変更)
///
/// 31B Manufacturer Data (ペイロード) 構成:
/// - [0]   : 1B ヘッダ (seq2, part, ver, yParity)
/// - [1-4] : 4B 鍵ハッシュID (SHA256(pubkey[0..32]) の先頭4B)
/// - [5-20]: 16B 鍵データ (part 0: pubkey[1..16])
/// - [21-30]:10B 鍵データ (part 1: pubkey[17..32] ※末尾6Bパディング)
///
class BleAdvertiser {
  final _peripheral = FlutterBlePeripheral();
  final _repo = KeyAdvertiseRepository();

  // ★★★ Manufacturer ID を 0xFFFF (未割り当て) に変更 ★★★
  static const int _companyId = 0xFFFF;

  bool _isAdvertising = false;
  Timer? _rotateTimer;
  bool _sendFrontNext = true;

  // ★ 2パート分のペイロード (31B x 2)
  Uint8List? _payloadFront;
  Uint8List? _payloadBack;
  int? _lastSeq2;

  bool _isStarted = false;

  static const Duration _rotateInterval = Duration(milliseconds: 500);

  final _settings = AdvertiseSettings(
    advertiseMode: AdvertiseMode.advertiseModeLowLatency,
    txPowerLevel: AdvertiseTxPower.advertiseTxPowerHigh,
    connectable: false,
    timeout: 0,
  );

  bool get isAdvertising => _isAdvertising;

  Future<void> _rotateAndSend() async {
    if (!_isAdvertising) return;

    try {
      if (_isStarted) {
        final nowSeq2 = currentTenMinSeq2();
        if (_lastSeq2 == null || nowSeq2 != _lastSeq2) {
          if (kDebugMode) print('BLE_AD: 10分境界を検出。ペイロードを再生成します。');
          await _preparePayloadsForCurrentSeq();
          _sendFrontNext = true;
        }
      }

      final Uint8List? payload;
      // ★★★ ここを修正 ★★★
      final int partSent = _sendFrontNext ? 0 : 1;

      if (_sendFrontNext) { // 'sendThisTimeIsFront' ではなく '_sendFrontNext' を使う
        payload = _payloadFront;
      } else {
        payload = _payloadBack;
      }
      _sendFrontNext = !_sendFrontNext; // 次回のために反転
      // ★★★ 修正ここまで ★★★

      if (payload == null) throw StateError('payload not prepared');

      final data = AdvertiseData(
        includeDeviceName: false,
        manufacturerId: _companyId,
        manufacturerData: payload, // 31Bのペイロード
      );

      await _peripheral.start(advertiseData: data, advertiseSettings: _settings);

      if (!_isStarted) {
        _isStarted = true;
        if (kDebugMode) print('BLE_AD: 🚀 Advertising started (Part $partSent).');
      } else {
        if (kDebugMode) {
          print('BLE_AD: 📡 Advertising updated via start() (Part $partSent).');
        }
      }

    } catch (e) {
      if (kDebugMode) print('BLE_AD: ❌ advertise rotate/update failed: $e');
    } finally {
      if (_isAdvertising) {
        _rotateTimer = Timer(_rotateInterval, _rotateAndSend);
      }
    }
  }

  Future<void> start() async {
    if (_isAdvertising) return;

    _isAdvertising = true;
    await _preparePayloadsForCurrentSeq();
    _sendFrontNext = true;
    _isStarted = false;

    await _rotateAndSend();
  }

  Future<void> stop() async {
    if (!_isAdvertising) return;

    _isAdvertising = false;
    _isStarted = false;

    _rotateTimer?.cancel();
    _rotateTimer = null;

    await _peripheral.stop();

    if (kDebugMode) print('BLE_AD: 🛑 Advertising stopped.');
  }

  Uint8List _getKeyHashId(Uint8List key33) {
    final digest = pc.SHA256Digest();
    final hash = digest.process(key33);
    return hash.sublist(0, 4);
  }

  /// 31Bのペイロードを2パート分準備
  Future<void> _preparePayloadsForCurrentSeq() async {
    final Uint8List pubKey33 = await _repo.getPublicKeyForAdvertise().catchError((e, st) {
      if (kDebugMode) print('BLE_AD: ❌ getPublicKeyForAdvertise failed: $e');
      throw e;
    });

    final yParity = pubKey33[0] & 0x01;
    final seq2 = currentTenMinSeq2();
    final keyId = _getKeyHashId(pubKey33); // 4B

    final hdrFront = BleHdr.make(seq2: seq2, part: 0, yParity: yParity);
    final hdrBack  = BleHdr.make(seq2: seq2, part: 1, yParity: yParity);

    final keyData = pubKey33.sublist(1); // pubkey[1..32] (32B)
    final dataP0 = keyData.sublist(0, 16);  // 16B
    final dataP1 = keyData.sublist(16, 32); // 16B

    // 31Bペイロード = [Hdr(1B)] + [KeyId(4B)] + [Data(16B)] + [Padding(10B)]
    final paddingFront = Uint8List(31 - 1 - 4 - 16); // 10B
    _payloadFront = Uint8List.fromList([hdrFront, ...keyId, ...dataP0, ...paddingFront]);

    final paddingBack = Uint8List(31 - 1 - 4 - 16); // 10B
    _payloadBack = Uint8List.fromList([hdrBack, ...keyId, ...dataP1, ...paddingBack]);

    _lastSeq2 = seq2;

    if (kDebugMode) print('BLE_AD: 🔑 Payloads prepared for seq2=$seq2, keyId=${_bytesToHex(keyId)}');
  }

  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}