// lib/ble/ble_advertiser.dart

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:pointycastle/export.dart' as pc;

import '../key_management_service.dart';
import 'ble_protocol.dart';

/// BLE 広告で仮名（圧縮公開鍵）を送信するための Advertiser。
///
/// Legacy Advertising の Manufacturer Specific Data(最大 31B) に収めるため，
/// 圧縮公開鍵(33B)を 2 断片に分割し，断片を交互に広告する。
///
/// ペイロード(31B)の構成:
/// - [0]    : ヘッダ 1B (seq2, part, ver, yParity)
/// - [1-4]  : KeyID 4B (SHA-256(公開鍵33B)の先頭4B)
/// - [5-20] : 鍵データ 16B (part=0: 公開鍵[1..16])
/// - [21-30]: 鍵データ 10B (part=1: 公開鍵[17..32] のうち先頭10B, 残りはパディング)
class BleAdvertiser {
  final _peripheral = FlutterBlePeripheral();
  final _kms = KeyManagementService();

  /// Manufacturer ID（0xFFFF はテスト用途でよく用いられる値）
  static const int _companyId = 0xFFFF;

  /// 断片の切り替え間隔
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

  // 断片ごとのペイロード (31B x 2)
  Uint8List? _payloadFront;
  Uint8List? _payloadBack;
  int? _lastSeq2;

  bool get isAdvertising => _isAdvertising;

  // ----- Public API -----

  Future<void> start() async {
    if (_isAdvertising) return;

    // 既存の広告を停止して状態を初期化する
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
      debugPrint('BLE_AD: advertising stopped');
    }
  }

  // ----- Core loop -----

  Future<void> _rotateAndSend() async {
    if (!_isAdvertising) return;

    try {
      // Android では連続 start が不安定な場合があるため，stop/start を挟む
      if (_isStarted) {
        await _peripheral.stop();
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // 時刻スロット(10分)の更新を検出したら，仮名に対応するペイロードを再生成する
      if (_isStarted) {
        final nowSeq2 = currentTenMinSeq2();
        if (_lastSeq2 == null || nowSeq2 != _lastSeq2) {
          if (kDebugMode) {
            debugPrint('BLE_AD: slot changed; rebuild payload');
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
          debugPrint('BLE_AD: advertising started (part=$partSent)');
        }
      } else {
        if (kDebugMode) {
          debugPrint('BLE_AD: advertising rotated (part=$partSent)');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('BLE_AD: advertise failed: $e');
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

  // ----- Payload preparation -----

  Future<void> _preparePayloadsForCurrentSeq() async {
    final Uint8List pubKey33 =
    await _kms.getPublicKeyForBleAdvertise().catchError((e, st) {
      if (kDebugMode) {
        debugPrint('BLE_AD: getPublicKeyForBleAdvertise failed: $e');
      }
      throw e;
    });

    final seq2 = currentTenMinSeq2();
    final yParity = pubKey33[0] & 0x01;

    // KeyID: SHA-256(公開鍵33B)の先頭4バイト
    final keyId = _getKeyHashId(pubKey33);

    final hdrFront = BleHdr.make(seq2: seq2, part: 0, yParity: yParity);
    final hdrBack = BleHdr.make(seq2: seq2, part: 1, yParity: yParity);

    // 圧縮公開鍵(33B)の先頭1B(圧縮プレフィクス)を除いた 32B を断片化する
    final keyData = pubKey33.sublist(1); // 32B
    final dataP0 = keyData.sublist(0, 16);
    final dataP1 = keyData.sublist(16, 32);

    // 31B に合わせるためのパディング
    final padding = Uint8List(31 - 1 - 4 - 16); // 10B

    _payloadFront =
        Uint8List.fromList([hdrFront, ...keyId, ...dataP0, ...padding]);
    _payloadBack =
        Uint8List.fromList([hdrBack, ...keyId, ...dataP1, ...padding]);

    _lastSeq2 = seq2;

    if (kDebugMode) {
      debugPrint(
        'BLE_AD: payload prepared seq2=$seq2 keyId=${_bytesToHex(keyId)}',
      );
    }
  }

  // ----- Utils -----

  Uint8List _getKeyHashId(Uint8List key33) {
    final digest = pc.SHA256Digest();
    final hash = digest.process(key33);
    return Uint8List.fromList(hash.sublist(0, 4));
  }

  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
