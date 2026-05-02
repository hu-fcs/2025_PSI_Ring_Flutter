// lib/ble/ble_advertiser.dart
import 'dart:async';
import 'dart:collection'; // ★追加（Queueを使う）
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:pointycastle/export.dart' as pc;

import 'ble_constants.dart';
import 'key_advertise_repository.dart';

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
  final _repo = KeyAdvertiseRepository();

  // Manufacturer ID を 0xFFFF (未割り当て)
  static const int _companyId = 0xFFFF;

  bool _isAdvertising = false;
  Timer? _rotateTimer;
  bool _sendFrontNext = true;

  // 2パート分のペイロード (31B x 2)
  Uint8List? _payloadFront;
  Uint8List? _payloadBack;
  int? _lastSeq2;

  // ★優先送信フレーム（Challenge/Signatureを先に流す）
  final Queue<Uint8List> _priorityFrames = Queue<Uint8List>();
  static const int _priorityMaxFrames = 32;

  void _pushPriority(Uint8List frame31) {
    // キューが溜まりすぎると遅延が増えるので古いものから落とす
    if (_priorityFrames.length >= _priorityMaxFrames) {
      _priorityFrames.removeFirst();
    }
    _priorityFrames.addLast(frame31);
  }


  bool _isStarted = false;

  static const Duration _rotateInterval = Duration(milliseconds: 500);

  final _settings = AdvertiseSettings(
    advertiseMode: AdvertiseMode.advertiseModeLowLatency,
    txPowerLevel: AdvertiseTxPower.advertiseTxPowerHigh,
    connectable: false,
    timeout: 0,
  );

  bool get isAdvertising => _isAdvertising;

  /// ver=7 Challenge を優先キューへ
  void enqueueChallenge({
    required Uint8List targetKeyId4,
    required int challengeId,
    required Uint8List nonce16,
    required Uint8List verifierId4,
  }) {
    if (targetKeyId4.lengthInBytes != 4) return;
    if (nonce16.lengthInBytes != 16) return;
    if (verifierId4.lengthInBytes != 4) return;

    final hdr = BleHdr.make(
      seq2: currentTenMinSeq2(),
      part: 0,
      yParity: 0,
      ver: BleHdr.verChallenge,
    );

    final paddingLen = 31 - (1 + 4 + 1 + 16 + 4);
    final payload = Uint8List.fromList([
      hdr,
      ...targetKeyId4,
      challengeId & 0xFF,
      ...nonce16,
      ...verifierId4,
      ...Uint8List(paddingLen),
    ]);

    _pushPriority(payload);
  }

  /// ver=8 Signature(64B) を 16B×4 に分割して優先キューへ
  void enqueueSignature({
    required Uint8List targetKeyId4,
    required int challengeId,
    required Uint8List signature64,
    required Uint8List verifierId4,
  }) {
    if (targetKeyId4.lengthInBytes != 4) return;
    if (signature64.lengthInBytes != 64) return;
    if (verifierId4.lengthInBytes != 4) return;

    for (int partIndex = 0; partIndex < 4; partIndex++) {
      final hdr = BleHdr.make(
        seq2: currentTenMinSeq2(),
        part: 0,
        yParity: 0,
        ver: BleHdr.verSignature,
      );

      final start = partIndex * 16;
      final sigPart16 = signature64.sublist(start, start + 16);

      final paddingLen = 31 - (1 + 4 + 1 + 1 + 16 + 4);
      final payload = Uint8List.fromList([
        hdr,
        ...targetKeyId4,
        challengeId & 0xFF,
        partIndex & 0xFF,
        ...sigPart16,
        ...verifierId4,
        ...Uint8List(paddingLen),
      ]);

      _pushPriority(payload);
    }
  }


  Future<void> _rotateAndSend() async {
    if (!_isAdvertising) return;

    try {
      // -----------------------------------------------------------------------
      // 【修正箇所】開始済みの場合、次の start を呼ぶ前に必ず stop し、少し待機する
      // これを行わないと Android では 'TOO_MANY_ADVERTISERS' エラーでクラッシュします。
      // -----------------------------------------------------------------------
      if (_isStarted) {
        await _peripheral.stop();
        // OSがリソースを解放する時間を稼ぐ (100ms程度が安全圏)
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // 10分ごとの鍵更新チェック
      if (_isStarted) {
        final nowSeq2 = currentTenMinSeq2();
        if (_lastSeq2 == null || nowSeq2 != _lastSeq2) {
          if (kDebugMode) print('BLE_AD: 10分境界を検出。ペイロードを再生成します。');
          await _preparePayloadsForCurrentSeq();
          _sendFrontNext = true;
        }
      }

      Uint8List? payload;
      int partSent;

      // ★優先フレームがあれば先に送る（Challenge/Signature）
      if (_priorityFrames.isNotEmpty) {
        payload = _priorityFrames.removeFirst();
        // 優先フレームは part の意味が薄いので、表示用に headerから取る
        partSent = BleHdr.parsePart(payload[0]);
      } else {
        partSent = _sendFrontNext ? 0 : 1;
        payload = _sendFrontNext ? _payloadFront : _payloadBack;
        _sendFrontNext = !_sendFrontNext; // 次回のために反転
      }

      if (payload == null) throw StateError('payload not prepared');


      final data = AdvertiseData(
        includeDeviceName: false,
        manufacturerId: _companyId,
        manufacturerData: payload, // 31Bのペイロード
      );

      // 新しいアドバタイズセットを開始
      await _peripheral.start(advertiseData: data, advertiseSettings: _settings);

      if (!_isStarted) {
        _isStarted = true;
        if (kDebugMode) print('BLE_AD: 🚀 Advertising started (Part $partSent).');
      } else {
        if (kDebugMode) {
          // 実際には update ではなく restart している状態
          print('BLE_AD: 📡 Advertising rotated (Part $partSent).');
        }
      }

    } catch (e) {
      if (kDebugMode) print('BLE_AD: ❌ advertise rotate/update failed: $e');

      // エラー発生時は安全のため stop を試みてクリーンアップする
      try {
        await _peripheral.stop();
      } catch (_) {}

    } finally {
      if (_isAdvertising) {
        _rotateTimer = Timer(_rotateInterval, _rotateAndSend);
      }
    }
  }

  Future<void> start() async {
    if (_isAdvertising) return;

    // 開始前にも念のため停止を呼んでおく
    try {
      await _peripheral.stop();
    } catch (_) {}

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