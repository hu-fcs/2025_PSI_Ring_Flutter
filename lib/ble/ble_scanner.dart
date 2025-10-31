// lib/ble/ble_scanner.dart
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'ble_constants.dart';
import 'ecd_keys_dao.dart';

/// メモリ上で front/back の片割れを管理し、揃ったら結合して ecd_keys に保存するスキャナ。
/// - manufacturerData を前提（[1Bヘッダ + 16Bボディ]）
/// - key = "$deviceId|$seq2" で片割れを保持
/// - Queue で firstSeen を管理し、10分超で自動破棄
class BleScanner {
  final _ble = FlutterReactiveBle();
  StreamSubscription<DiscoveredDevice>? _sub;
  Timer? _gcTimer;

  bool _isScanning = false;
  bool get isScanning => _isScanning;

  /// 片割れ有効期間（10分）
  static const Duration _halfTtl = Duration(minutes: 10);

  /// メモリ上の片割れ保管：key = "$deviceId|$seq2"
  final Map<String, _HalfState> _halves = {};

  /// 期限切れ掃除用の FIFO キュー
  final Queue<_QueueEntry> _queue = Queue<_QueueEntry>();

  /// ★ アドバタイザーとIDを合わせる
  static const int _companyId = 0x00E0;

  /// ★ バイト配列を16進数文字列に変換するヘルパー
  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> start() async {
    if (_isScanning) return;
    _isScanning = true;

    if (kDebugMode) print('BLE_SCAN: 🚀 スキャン開始...');

    // スキャン開始（UUIDフィルタ無し＝全受信）
    _sub = _ble
        .scanForDevices(
      withServices: const [], // manufacturerDataだけ使うため UUID フィルタ無し
      scanMode: ScanMode.lowLatency,
      requireLocationServicesEnabled: false,
    )
        .listen(_onDiscover, onError: (e, st) {
      if (kDebugMode) print('BLE_SCAN: ❌ scan error: $e');
    });

    // 1分ごとに期限切れ掃除
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
    final md = d.manufacturerData;
    final deviceId = d.id;

    // --- ここからログ追加 ---

    // 1. manufacturerData を持つデバイスをすべてログに出力
    if (md.isEmpty) {
      // mdが空のログは大量に出る可能性があるので、必要ならコメント解除
      // if (kDebugMode) print('BLE_SCAN: [$deviceId] Discovered empty md');
      return;
    }
    if (kDebugMode) {
      print('BLE_SCAN: [$deviceId] Discovered md: ${_bytesToHex(md)}');
    }

    // 2. カンパニーIDのチェック（前回の修正）
    const int expectedLength = 2 + 17; // ID 2B + Payload 17B
    if (md.length < expectedLength) {
      if (kDebugMode) print('BLE_SCAN: [$deviceId] ⚠️ Ignoring. md length ${md.length} < $expectedLength');
      return;
    }

    final int receivedId = md[0] | (md[1] << 8); // リトルエンディアン
    if (receivedId != _companyId) {
      if (kDebugMode) print('BLE_SCAN: [$deviceId] ⚠️ Ignoring. Company ID ${receivedId.toRadixString(16)} != ${_companyId.toRadixString(16)}');
      return;
    }

    if (kDebugMode) print('BLE_SCAN: [$deviceId] ✅ Company ID OK.');

    // 3. ペイロードとヘッダの解析ログ
    final header = md[2];
    final body16 = Uint8List.fromList(md.sublist(3, expectedLength));

    final seq2 = BleHdr.parseSeq2(header);
    final part = BleHdr.parsePart(header);
    final yp   = BleHdr.parseYParity(header);
    final ver  = BleHdr.parseVer(header);

    if (kDebugMode) {
      print('BLE_SCAN: [$deviceId] Parsed Hdr(0x${header.toRadixString(16)}): seq2=$seq2, part=$part, yParity=$yp, ver=$ver');
    }

    if (ver != BleHdr.currentVer) {
      if (kDebugMode) print('BLE_SCAN: [$deviceId] ⚠️ Ignoring. Version mismatch ver=$ver');
      return;
    }

    // 4. 鍵の断片（HalfState）の処理ログ
    final now = DateTime.now().millisecondsSinceEpoch;
    final key = '$seq2|$yp'; // デバイスIDと時間シーケンスでユニーク化

    var st = _halves[key];
    if (st == null) {
      if (kDebugMode) print('BLE_SCAN: [$key] ℹ️ Creating new state.');
      st = _HalfState(
        deviceId: deviceId,
        seq2: seq2,
        yParity: yp,
        firstSeenMs: now,
      );
      _halves[key] = st;
      _queue.addLast(_QueueEntry(key: key, firstSeenMs: now));
    } else {
      // yParityが食い違ったら、相手の鍵が更新されたとみなしリセット
      if (st.yParity != yp) {
        if (kDebugMode) print('BLE_SCAN: [$key] ⚠️ yParity mismatch (old=${st.yParity}, new=$yp). Resetting state.');
        st.front16 = null;
        st.back16 = null;
        st.yParity = yp;
        st.firstSeenMs = now;
        _queue.addLast(_QueueEntry(key: key, firstSeenMs: now));
      }
    }

    // 該当するpartを保存
    if (part == 0) {
      if (kDebugMode) print('BLE_SCAN: [$key] ℹ️ Storing part 0 (front).');
      st.front16 = body16;
    } else {
      if (kDebugMode) print('BLE_SCAN: [$key] ℹ️ Storing part 1 (back).');
      st.back16 = body16;
    }

    // 5. 鍵の結合処理ログ
    if (st.front16 != null && st.back16 != null) {
      if (kDebugMode) print('BLE_SCAN: [$key] 🔥 Both parts received. Attempting merge...');

      final firstByte = 0x02 | (st.yParity & 0x01); // 0x02 or 0x03
      final merged = Uint8List.fromList([
        firstByte,
        ...st.front16!,
        ...st.back16!,
      ]);

      // 6. 結合後の検証とDB保存ログ
      final bool isValid = isValidCompressedPubkey(merged);
      if (kDebugMode) print('BLE_SCAN: [$key] Merged key (${merged.length}B): ${_bytesToHex(merged)}');
      if (kDebugMode) print('BLE_SCAN: [$key] Validation result: $isValid');

      if (isValid) {
        try {
          if (kDebugMode) print('BLE_SCAN: [$key] 💾 Inserting into DB...');
          await EcdKeysDao.instance.insertCollected(
            pubkey33: merged,
            ts: now,   // ecd_keys_dao は ms のまま受け取っている
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

      // 処理完了（成功・失敗問わず）したら、このキーの断片は削除
      _halves.remove(key);
      if (kDebugMode) print('BLE_SCAN: [$key] 🧹 State cleared after processing.');
    }

    // --- ログ追加ここまで ---

    // 入力トリガで軽く掃除（過剰ならコメントアウト可）
    _gcSweep();
  }

  void _gcSweep() {
    final now = DateTime.now().millisecondsSinceEpoch;
    while (_queue.isNotEmpty) {
      final head = _queue.first;
      if ((now - head.firstSeenMs) >= _halfTtl.inMilliseconds) {
        final removedKey = _queue.removeFirst().key;
        // _halves にまだ残っていたら（＝片割れが見つからないまま期限切れ）削除
        if (_halves.remove(removedKey) != null) {
          if (kDebugMode) print('BLE_SCAN: [$removedKey] 🗑️ GC Sweep: Removed expired half-state.');
        }
      } else {
        break; // キューの先頭がまだ有効期限内なら終了
      }
    }
  }
}

class _HalfState {
  _HalfState({
    required this.deviceId,
    required this.seq2,
    required this.yParity,
    required this.firstSeenMs,
  });

  final String deviceId;
  final int seq2;
  int yParity;
  int firstSeenMs;

  Uint8List? front16;
  Uint8List? back16;
}

class _QueueEntry {
  _QueueEntry({required this.key, required this.firstSeenMs});
  final String key;
  final int firstSeenMs;
}