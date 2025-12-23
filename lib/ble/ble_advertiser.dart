// lib/ble/ble_advertiser.dart

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:pointycastle/export.dart' as pc;

import '../key_management_service.dart';
import 'ble_protocol.dart';

/// 2パート(front/back)を Manufacturer Data で交互送信する Advertiser。
///
/// 31B Manufacturer Data (ペイロード) 構成:
/// - [0]   : 1B ヘッダ (seq2, part, ver, yParity)
/// - [1-4] : 4B 鍵ハッシュID (SHA256(pubkey[0..32]) の先頭4B)
/// - [5-20]: 16B 鍵データ (part 0: pubkey[1..16])
/// - [21-30]:10B 鍵データ (part 1: pubkey[17..32] ※末尾6Bパディング)
///
class BleAdvertiser {
  final _peripheral = FlutterBlePeripheral();
  final _kms = KeyManagementService();

  /// Manufacturer ID（0xFFFF = 未割り当て）
  static const int _companyId = 0xFFFF;

  static const Duration _rotateInterval = Duration(milliseconds: 500);

  final _settings = AdvertiseSettings(
    advertiseMode: AdvertiseMode.advertiseModeLowLatency,
    txPowerLevel: AdvertiseTxPower.advertiseTxPowerHigh,
    connectable: false,
    timeout: 0,
  );

  bool _isAdvertising = false;
  bool _isStarted = false;
  bool _sendFrontNext = true;

  Timer? _rotateTimer;

  // 2パート分のペイロード (31B x 2)
  Uint8List? _payloadFront;
  Uint8List? _payloadBack;
  int? _lastSeq2;

  bool get isAdvertising => _isAdvertising;

  // ===============================================================
  // Public API
  // ===============================================================

  Future<void> start() async {
    if (_isAdvertising) return;

    // 念のため事前停止
    try {
      await _peripheral.stop();
    } catch (_) {}

    _isAdvertising = true;
    _isStarted = false;
    _sendFrontNext = true;

    await _preparePayloadsForCurrentSeq();
    await _rotateAndSend();
  }

  Future<void> stop() async {
    if (!_isAdvertising) return;

    _isAdvertising = false;
    _isStarted = false;

    _rotateTimer?.cancel();
    _rotateTimer = null;

    try {
      await _peripheral.stop();
    } catch (_) {}

    if (kDebugMode) {
      print('BLE_AD: 🛑 Advertising stopped.');
    }
  }

  // ===============================================================
  // Core loop
  // ===============================================================

  Future<void> _rotateAndSend() async {
    if (!_isAdvertising) return;

    try {
      // Android 対策：必ず stop → 少し待ってから start
      if (_isStarted) {
        await _peripheral.stop();
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // 10分境界チェック
      if (_isStarted) {
        final nowSeq2 = currentTenMinSeq2();
        if (_lastSeq2 == null || nowSeq2 != _lastSeq2) {
          if (kDebugMode) {
            print('BLE_AD: ⏱️ 10分境界を検出。ペイロード再生成');
          }
          await _preparePayloadsForCurrentSeq();
          _sendFrontNext = true;
        }
      }

      final payload = _sendFrontNext ? _payloadFront : _payloadBack;
      final partSent = _sendFrontNext ? 0 : 1;
      _sendFrontNext = !_sendFrontNext;

      if (payload == null) {
        throw StateError('BLE payload not prepared');
      }

      final data = AdvertiseData(
        includeDeviceName: false,
        manufacturerId: _companyId,
        manufacturerData: payload,
      );

      await _peripheral.start(
        advertiseData: data,
        advertiseSettings: _settings,
      );

      if (!_isStarted) {
        _isStarted = true;
        if (kDebugMode) {
          print('BLE_AD: 🚀 Advertising started (part=$partSent)');
        }
      } else {
        if (kDebugMode) {
          print('BLE_AD: 📡 Advertising rotated (part=$partSent)');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('BLE_AD: ❌ advertise failed: $e');
      }
      try {
        await _peripheral.stop();
      } catch (_) {}
    } finally {
      if (_isAdvertising) {
        _rotateTimer = Timer(_rotateInterval, _rotateAndSend);
      }
    }
  }

  // ===============================================================
  // Payload preparation
  // ===============================================================

  Future<void> _preparePayloadsForCurrentSeq() async {
    final Uint8List pubKey33 =
    await _kms.getPublicKeyForBleAdvertise().catchError((e, st) {
      if (kDebugMode) {
        print('BLE_AD: ❌ getPublicKeyForBleAdvertise failed: $e');
      }
      throw e;
    });

    final seq2 = currentTenMinSeq2();
    final yParity = pubKey33[0] & 0x01;
    final keyId = _getKeyHashId(pubKey33);

    final hdrFront =
    BleHdr.make(seq2: seq2, part: 0, yParity: yParity);
    final hdrBack =
    BleHdr.make(seq2: seq2, part: 1, yParity: yParity);

    final keyData = pubKey33.sublist(1); // 32B
    final dataP0 = keyData.sublist(0, 16);
    final dataP1 = keyData.sublist(16, 32);

    final padding = Uint8List(31 - 1 - 4 - 16); // 10B

    _payloadFront = Uint8List.fromList(
        [hdrFront, ...keyId, ...dataP0, ...padding]);
    _payloadBack = Uint8List.fromList(
        [hdrBack, ...keyId, ...dataP1, ...padding]);

    _lastSeq2 = seq2;

    if (kDebugMode) {
      print(
          'BLE_AD: 🔑 Payload prepared seq2=$seq2 keyId=${_bytesToHex(keyId)}');
    }
  }

  // ===============================================================
  // Utils
  // ===============================================================

  Uint8List _getKeyHashId(Uint8List key33) {
    final digest = pc.SHA256Digest();
    final hash = digest.process(key33);
    return Uint8List.fromList(hash.sublist(0, 4));
  }

  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
