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

  // start()が呼ばれたかを追跡
  bool _isStarted = false;

  // ★ start()で使う設定をクラス変数として保持
  final _settings = AdvertiseSettings(
    advertiseMode: AdvertiseMode.advertiseModeLowLatency,
    txPowerLevel: AdvertiseTxPower.advertiseTxPowerHigh,
    connectable: false,
    timeout: 0,
  );

  bool get isAdvertising => _isAdvertising;

  // ★★★ ロジック修正 (stop/start の代わりに start() を再利用) ★★★
  Future<void> _rotateAndSend(Timer? timer) async {
    try {
      // 1. 10分境界チェック (タイマー経由の場合のみ)
      if (timer != null) {
        final nowSeq2 = currentTenMinSeq2();
        if (_lastSeq2 == null || nowSeq2 != _lastSeq2) {
          if (kDebugMode) print('BLE_AD: 10分境界を検出。ペイロードを再生成します。');
          await _preparePayloadsForCurrentSeq();
          // 鍵が変わったので、必ず part 0 から送る
          _sendFrontNext = true;
        }
      }

      // 2. 送信内容を決定し、フラグを反転
      final bool sendThisTimeIsFront = _sendFrontNext;
      _sendFrontNext = !_sendFrontNext; // 次回のために反転

      final payload = sendThisTimeIsFront ? _payloadFront : _payloadBack;
      if (payload == null) throw StateError('payload not prepared');

      final data = AdvertiseData(
        includeDeviceName: false,
        manufacturerId: _companyId,
        manufacturerData: payload,
      );

      // 3. 最初の呼び出し(timer==null)も、タイマー経由も、
      //    すべて 'start()' を呼ぶ。
      //    stop() を呼ばない限り、MACアドレスは変更されないはず。
      if (!_isStarted) {
        // 初回呼び出し (start()から)
        await _peripheral.start(advertiseData: data, advertiseSettings: _settings);
        _isStarted = true;
        if (kDebugMode) print('BLE_AD: 🚀 Advertising started (Part ${sendThisTimeIsFront ? 0 : 1}).');
      } else {
        // 2回目以降 (タイマーから)
        // ★★★ ここを 'start()' に修正 ★★★
        await _peripheral.start(advertiseData: data, advertiseSettings: _settings);
        if (kDebugMode) {
          print('BLE_AD: 📡 Advertising updated via start() (Part ${sendThisTimeIsFront ? 0 : 1}).');
        }
      }
    } catch (e) {
      if (kDebugMode) print('BLE_AD: ❌ advertise rotate/update failed: $e');
      // "already advertising" のようなエラーが出た場合、ここを stop/start に戻す必要がある
    }
  }

  Future<void> start() async {
    if (_isAdvertising) return;

    await _preparePayloadsForCurrentSeq();
    _sendFrontNext = true; // 必ず front から
    _isStarted = false;    // start() 未呼び出し状態に

    // 1. 初回の _rotateAndSend を手動で呼び出し (start() を実行させる)
    await _rotateAndSend(null);

    // 2. 2回目以降の _rotateAndSend をタイマーで設定
    _rotateTimer = Timer.periodic(_rotateInterval, _rotateAndSend);

    _isAdvertising = true;
  }

  Future<void> stop() async {
    if (!_isAdvertising) return;
    _rotateTimer?.cancel();
    _rotateTimer = null;
    await _peripheral.stop();
    _isAdvertising = false;
    _isStarted = false; // 停止
    if (kDebugMode) print('BLE_AD: 🛑 Advertising stopped.');
  }
  // ★★★ 修正ここまで ★★★

  /// 現在の seq2 に合わせて鍵を取得し、ヘッダ付与した payload を準備
  Future<void> _preparePayloadsForCurrentSeq() async {
    final chunks = await _repo.getPublicKeyForAdvertise().catchError((e, st) {
      if (kDebugMode) print('BLE_AD: ❌ getPublicKeyForAdvertise failed: $e');
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

    if (kDebugMode) print('BLE_AD: 🔑 Payloads prepared for seq2=$seq2');
  }
}