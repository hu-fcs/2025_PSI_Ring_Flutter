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

  Future<void> start() async {
    if (_isScanning) return;
    _isScanning = true;

    // スキャン開始（UUIDフィルタ無し＝全受信）
    _sub = _ble
        .scanForDevices(
      withServices: const [], // manufacturerDataだけ使うため UUID フィルタ無し
      scanMode: ScanMode.lowLatency,
      requireLocationServicesEnabled: false,
    )
        .listen(_onDiscover, onError: (e, st) {
      if (kDebugMode) print('❌ scan error: $e');
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
  }

  // -------------------- internal --------------------

  void _onDiscover(DiscoveredDevice d) async {
    final md = d.manufacturerData;
    if (md.isEmpty) return;

    // 期待フォーマット: [1B header] + 16B body
    if (md.length < 1 + 16) return;

    final header = md[0];
    final body16 = Uint8List.fromList(md.sublist(1, 17));

    final seq2 = BleHdr.parseSeq2(header);     // 0..3
    final part = BleHdr.parsePart(header);     // 0=front,1=back
    final yp   = BleHdr.parseYParity(header);  // 0/1
    final ver  = BleHdr.parseVer(header);      // 0..15

    if (ver != BleHdr.currentVer) {
      // 将来拡張：受理バージョンを広げたい場合は条件を変更
      if (kDebugMode) print('ℹ️ ignore different ver=$ver from ${d.id}');
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final key = '${d.id}|$seq2';

    var st = _halves[key];
    if (st == null) {
      st = _HalfState(
        deviceId: d.id,
        seq2: seq2,
        yParity: yp,
        firstSeenMs: now,
      );
      _halves[key] = st;
      _queue.addLast(_QueueEntry(key: key, firstSeenMs: now));
    } else {
      // yParity が食い違う場合は、古い方を捨ててリセット（端末側の鍵が切り替わった可能性）
      if (st.yParity != yp) {
        st.front16 = null;
        st.back16 = null;
        st.yParity = yp;
        st.firstSeenMs = now;
        _queue.addLast(_QueueEntry(key: key, firstSeenMs: now));
      }
    }

    if (part == 0) {
      st.front16 = body16;
    } else {
      st.back16 = body16;
    }

    // そろったら結合
    if (st.front16 != null && st.back16 != null) {
      final firstByte = 0x02 | (st.yParity & 0x01); // 0x02 or 0x03
      final merged = Uint8List.fromList([
        firstByte,
        ...st.front16!,
        ...st.back16!,
      ]);

      if (isValidCompressedPubkey(merged)) {
        try {
          await EcdKeysDao.instance.insertCollected(
            pubkey33: merged,
            ts: now,   // debug_page が秒精度なら (now ~/ 1000) に変更
            latE6: 0,  // ecd_keys が NOT NULL なら 0 を入れておく
            lonE6: 0,
          );
          if (kDebugMode) {
            print('✅ saved to ecd_keys from ${d.id} seq2=$seq2 (len=${merged.length})');
          }
        } catch (e) {
          if (kDebugMode) print('❌ DB insert failed: $e');
        }
      } else {
        if (kDebugMode) print('⚠️ invalid merged key from ${d.id}');
      }

      // 片付け（この seq2 の片割れを破棄）
      _halves.remove(key);
      // Queue からの削除は怠惰に：GCスイープ時に存在確認してスキップ
    }

    // 入力トリガで軽く掃除（過剰ならコメントアウト可）
    _gcSweep();
  }

  void _gcSweep() {
    final now = DateTime.now().millisecondsSinceEpoch;
    while (_queue.isNotEmpty) {
      final head = _queue.first;
      if ((now - head.firstSeenMs) >= _halfTtl.inMilliseconds) {
        _queue.removeFirst();
        _halves.remove(head.key);
      } else {
        break;
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
