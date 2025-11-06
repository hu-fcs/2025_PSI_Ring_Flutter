// lib/ble/ble_scanner.dart
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:pointycastle/export.dart' as pc;

import 'ble_constants.dart';
import 'ecd_keys_dao.dart';

/// 2パート(front/back)の鍵断片をメモリ上で管理し、揃ったら結合するスキャナ。 (★ 仕様変更)
/// - Manufacturer Data (31B) を前提
/// - [1Bヘッダ + 4B鍵ID + 16Bデータ + 10Bパディング]
/// - key = "$seq2|$keyIdHex" で断片を保持
class BleScanner {
  final _ble = FlutterReactiveBle();
  StreamSubscription<DiscoveredDevice>? _sub;
  Timer? _gcTimer;

  // ★★★ Manufacturer ID を 0xFFFF に変更 ★★★
  static const int _companyId = 0xFFFF;

  bool _isScanning = false;
  bool get isScanning => _isScanning;

  static const Duration _halfTtl = Duration(minutes: 10);

  final Map<String, _HalfState> _halves = {};
  final Queue<_QueueEntry> _queue = Queue<_QueueEntry>();

  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Uint8List _getKeyHashId(Uint8List key33) {
    final digest = pc.SHA256Digest();
    final hash = digest.process(key33);
    return hash.sublist(0, 4);
  }

  Future<void> start() async {
    if (_isScanning) return;
    _isScanning = true;

    if (kDebugMode) print('BLE_SCAN: 🚀 スキャン開始 (Company ID: 0xFFFF)...');

    // ★★★ 128bit UUID スキャンをやめ、全スキャンに戻す ★★★
    _sub = _ble
        .scanForDevices(
      withServices: [], // 全デバイスをスキャン
      scanMode: ScanMode.lowLatency,
      requireLocationServicesEnabled: false,
    )
        .listen(_onDiscover, onError: (e, st) {
      if (kDebugMode) print('BLE_SCAN: ❌ scan error: $e');
    });

    _gcTimer = Timer.periodic(const Duration(minutes: 1), (_) => _gcSweep());
  }

  Future<void> stop() async {
    if (!_isScanning) return;
    await _sub?.cancel();
    _sub = null;

    _gcTimer?.cancel();
    _gcTimer = null;

    _halves.clear();
    _queue.clear();

    _isScanning = false;
    if (kDebugMode) print('BLE_SCAN: 🛑 スキャン停止。');
  }

  // -------------------- internal --------------------

  void _onDiscover(DiscoveredDevice d) async {
    // ★★★ Manufacturer Data を使うように変更 ★★★
    final Uint8List? payload = d.manufacturerData;
    final deviceId = d.id;

    if (payload == null || payload.isEmpty) return;

    // ★ 期待するペイロード長を (ID 2B + Data 31B) = 33B に変更
    // (注: flutter_reactive_ble は ID(2B) と Data(31B) を結合して返す)
    const int expectedLength = 2 + 31;
    if (payload.length < expectedLength) {
      // if (kDebugMode) print('BLE_SCAN: [$deviceId] ⚠️ Ignoring. payload length ${payload.length} < $expectedLength');
      return;
    }

    // ★ Manufacturer ID のチェック
    final int receivedId = payload[0] | (payload[1] << 8); // リトルエンディアン
    if (receivedId != _companyId) {
      // if (kDebugMode) print('BLE_SCAN: [$deviceId] ⚠️ Ignoring. Company ID ${receivedId.toRadixString(16)} != ${_companyId.toHexString(16)}');
      return;
    }

    // 3. ペイロードとヘッダの解析 (★ 構成変更)
    // (ID 2B をスキップした 31B がペイロード本体)
    final header = payload[2];
    // ★ 鍵ID (4B)
    final keyIdBytes = Uint8List.fromList(payload.sublist(3, 7)); // 2+1 .. 2+5
    final keyIdHex = _bytesToHex(keyIdBytes);
    // ★ データ本体 (16B)
    final body16 = Uint8List.fromList(payload.sublist(7, 23)); // 2+5 .. 2+21

    final seq2 = BleHdr.parseSeq2(header);
    final part = BleHdr.parsePart(header);
    final yp   = BleHdr.parseYParity(header);
    final ver  = BleHdr.parseVer(header);

    if (kDebugMode) {
      print('BLE_SCAN: [$deviceId] Parsed Hdr(0x${header.toRadixString(16)}): keyId=$keyIdHex, seq2=$seq2, part=$part, yParity=$yp, ver=$ver');
    }

    if (ver != BleHdr.currentVer) {
      if (kDebugMode) print('BLE_SCAN: [$deviceId] ⚠️ Ignoring. Version mismatch ver=$ver (expected ${BleHdr.currentVer})');
      return;
    }
    if (part > 1) { // 2, 3 は無視
      if (kDebugMode) print('BLE_SCAN: [$deviceId] ⚠️ Ignoring. Invalid part $part');
      return;
    }

    // 4. 鍵の断片（HalfState）の処理
    final now = DateTime.now().millisecondsSinceEpoch;
    final key = '$seq2|$keyIdHex';

    var st = _halves[key];
    if (st == null) {
      if (kDebugMode) print('BLE_SCAN: [$key] ℹ️ Creating new state.');
      st = _HalfState(
        keyId: keyIdBytes,
        seq2: seq2,
        yParity: yp,
        firstSeenMs: now,
      );
      _halves[key] = st;
      _queue.addLast(_QueueEntry(key: key, firstSeenMs: now));
    } else {
      if (st.yParity != yp) {
        if (kDebugMode) print('BLE_SCAN: [$key] ⚠️ yParity mismatch (old=${st.yParity}, new=$yp). Resetting state.');
        st.resetParts();
        st.yParity = yp;
        st.firstSeenMs = now;
        _queue.addLast(_QueueEntry(key: key, firstSeenMs: now));
      }
    }

    if (part == 0) {
      if (kDebugMode) print('BLE_SCAN: [$key] ℹ️ Storing part 0 (front).');
      st.front16 = body16; // 16B
    } else {
      if (kDebugMode) print('BLE_SCAN: [$key] ℹ️ Storing part 1 (back).');
      st.back16 = body16; // 16B
    }

    // 5. 鍵の結合処理 (★ 2パートチェック)
    if (st.front16 != null && st.back16 != null) {
      if (kDebugMode) print('BLE_SCAN: [$key] 🔥 Both parts received. Attempting merge...');

      final firstByte = 0x02 | (st.yParity & 0x01);

      // ★ 33B = [0x02/03 (1B)] + [Front (16B)] + [Back (16B)]
      final merged = Uint8List.fromList([
        firstByte,
        ...st.front16!,
        ...st.back16!,
      ]);

      final bool isValid = isValidCompressedPubkey(merged);
      if (kDebugMode) print('BLE_SCAN: [$key] Merged key (${merged.length}B): ${_bytesToHex(merged)}');
      if (kDebugMode) print('BLE_SCAN: [$key] Validation (length 33B): $isValid');

      if (!isValid) {
        _halves.remove(key);
        return;
      }

      // ★★★ ハッシュ検証 (誤結合防止) ★★★
      final receivedHash = st.keyId;
      final calculatedHash = _getKeyHashId(merged);

      bool isHashValid = listEquals(receivedHash, calculatedHash);
      if (kDebugMode) {
        print('BLE_SCAN: [$key] Hash Validation: $isHashValid (Received: ${_bytesToHex(receivedHash)}, Calc: ${_bytesToHex(calculatedHash)})');
      }

      if (isValid && isHashValid) {
        try {
          if (kDebugMode) print('BLE_SCAN: [$key] 💾 Inserting into DB...');
          await EcdKeysDao.instance.insertCollected(
            pubkey33: merged,
            ts: now,
            latE6: 0,
            lonE6: 0,
          );
          if (kDebugMode) {
            print('BLE_SCAN: [$key] ✅ DB insert success.');
          }
        } catch (e) {
          if (kDebugMode) print('BLE_SCAN: [$key] ❌ DB insert failed: $e');
        }
      }

      _halves.remove(key);
      if (kDebugMode) print('BLE_SCAN: [$key] 🧹 State cleared after processing.');
    }

    _gcSweep();
  }

  void _gcSweep() {
    final now = DateTime.now().millisecondsSinceEpoch;
    while (_queue.isNotEmpty) {
      final head = _queue.first;
      if ((now - head.firstSeenMs) >= _halfTtl.inMilliseconds) {
        final removedKey = _queue.removeFirst().key;
        if (_halves.remove(removedKey) != null) {
          if (kDebugMode) print('BLE_SCAN: [$removedKey] 🗑️ GC Sweep: Removed expired half-state.');
        }
      } else {
        break;
      }
    }
  }
}

// ★ 2パート保持
class _HalfState {
  _HalfState({
    required this.keyId,
    required this.seq2,
    required this.yParity,
    required this.firstSeenMs,
  });

  final Uint8List keyId; // 4B
  final int seq2;
  int yParity;
  int firstSeenMs;

  Uint8List? front16; // 16B
  Uint8List? back16; // 16B

  void resetParts() {
    front16 = null;
    back16 = null;
  }
}

class _QueueEntry {
  _QueueEntry({required this.key, required this.firstSeenMs});
  final String key;
  final int firstSeenMs;
}