// lib/ble/ble_advertiser.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';

import 'ble_constants.dart';
import 'key_advertise_repository.dart';

/// front/back を manufacturerData で交互送信する Advertiser。
/// - ヘッダ1B（seq2/part/ver/yParity）+ 本体16B
/// - 10分境界で seq2 が変わったら鍵を取り直してヘッダも再生成
class BleAdvertiser {
  final _peripheral = FlutterBlePeripheral();
  final _repo = KeyAdvertiseRepository();

  bool _isAdvertising = false;
  Timer? _rotateTimer;
  bool _sendFrontNext = true;

  // 任意の Company ID（テスト用）
  static const int _companyId = 0x00E0;

  // 交互切替の周期
  static const Duration _rotateInterval = Duration(milliseconds: 600);

  // 現行の送信ペイロード
  Uint8List? _payloadFront; // [1B hdr + 16B]
  Uint8List? _payloadBack;  // [1B hdr + 16B]
  int? _lastSeq2;           // 直近に適用した seq2

  bool get isAdvertising => _isAdvertising;

  Future<void> start() async {
    if (_isAdvertising) return;

    await _preparePayloadsForCurrentSeq();

    _sendFrontNext = true;
    await _startOnce(isFront: true);

    _rotateTimer = Timer.periodic(_rotateInterval, (_) async {
      try {
        // 10分境界チェック：seq2 変化時は鍵＆ヘッダを再生成
        final nowSeq2 = currentTenMinSeq2();
        if (_lastSeq2 == null || nowSeq2 != _lastSeq2) {
          await _peripheral.stop();
          await _preparePayloadsForCurrentSeq();
        }

        await _peripheral.stop();
        await Future.delayed(const Duration(milliseconds: 80));

        final nextIsFront = _sendFrontNext;
        _sendFrontNext = !_sendFrontNext;
        await _startOnce(isFront: nextIsFront);
      } catch (e) {
        if (kDebugMode) print('❌ advertise rotate failed: $e');
      }
    });

    _isAdvertising = true;
  }

  Future<void> stop() async {
    if (!_isAdvertising) return;
    _rotateTimer?.cancel();
    _rotateTimer = null;
    await _peripheral.stop();
    _isAdvertising = false;
  }

  /// 現在の seq2 に合わせて鍵を取得し、ヘッダ付与した payload を準備
  Future<void> _preparePayloadsForCurrentSeq() async {
    final chunks = await _repo.getPublicKeyForAdvertise().catchError((e, st) {
      if (kDebugMode) print('❌ getPublicKeyForAdvertise failed: $e');
      throw e;
    });

    // front[0] は 0x02/0x03 -> yParity
    if (chunks.front.length < 17 || chunks.back.length < 16) {
      throw StateError('Unexpected chunk lengths: front=${chunks.front.length}, back=${chunks.back.length}');
    }
    final yParity = chunks.front[0] & 0x01; // 0x02->0, 0x03->1
    final seq2 = currentTenMinSeq2();

    // front 本体16B = pubkey[1..16]
    final frontBody16 = Uint8List.fromList(chunks.front.sublist(1, 17));
    // back  本体16B = pubkey[17..32]
    final backBody16  = Uint8List.fromList(chunks.back);

    final hdrFront = BleHdr.make(seq2: seq2, part: 0, yParity: yParity);
    final hdrBack  = BleHdr.make(seq2: seq2, part: 1, yParity: yParity);

    _payloadFront = Uint8List.fromList([hdrFront, ...frontBody16]);
    _payloadBack  = Uint8List.fromList([hdrBack,  ...backBody16]);
    _lastSeq2 = seq2;
  }

  /// 1 回分のアドバタイズを開始（manufacturerDataに [1B hdr + 16B] を載せる）
  Future<void> _startOnce({required bool isFront}) async {
    final payload = isFront ? _payloadFront : _payloadBack;
    if (payload == null) throw StateError('payload not prepared');

    final settings = AdvertiseSettings(
      advertiseMode: AdvertiseMode.advertiseModeLowLatency,
      txPowerLevel: AdvertiseTxPower.advertiseTxPowerHigh,
      connectable: false,
      timeout: 0,
    );

    final data = AdvertiseData(
      includeDeviceName: false,
      manufacturerId: _companyId,
      manufacturerData: payload,
    );

    await _peripheral.start(advertiseData: data, advertiseSettings: settings);
  }
}
