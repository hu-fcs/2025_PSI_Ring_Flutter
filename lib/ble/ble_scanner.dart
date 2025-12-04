// lib/ble/ble_scanner.dart
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pointycastle/export.dart' as pc;

import '../db/database_helper.dart';
import '../key_management_service.dart';
import 'ble_constants.dart';

class BleScanner {
  StreamSubscription<List<ScanResult>>? _sub;
  Timer? _gcTimer;

  static const int _companyId = 0xFFFF;

  bool _isScanning = false;
  bool get isScanning => _isScanning;

  static const Duration _halfTtl = Duration(minutes: 10);

  final Map<String, _HalfState> _halves = {};
  final Queue<_QueueEntry> _queue = Queue<_QueueEntry>();

  // 🔥 グローバルキャッシュ（static に変更）
  static final Set<String> _globalCacheKeys = {};

  // 🔥 現在のスロット
  static int _currentSlot = -1;

  // 外部（DebugPage 等）からキャッシュクリア
  static void clearCollectedCache() {
    _globalCacheKeys.clear();
    if (kDebugMode) print("BLE_SCAN: 🧹 collected key cache cleared (manual)");
  }

  int _calcSlot(int timestampMs, int slotMillis) {
    return timestampMs ~/ slotMillis;
  }

  Uint8List _getKeyHashId(Uint8List key33) {
    final digest = pc.SHA256Digest();
    final hash = digest.process(key33);
    return hash.sublist(0, 4);
  }

  // --------------------------------------------------------
  // START SCAN
  // --------------------------------------------------------
  Future<void> start() async {
    if (_isScanning) return;
    _isScanning = true;

    if (kDebugMode) print('BLE_SCAN: 🚀 startScan() called.');

    await FlutterBluePlus.stopScan();

    await FlutterBluePlus.startScan(
      androidScanMode: AndroidScanMode.lowLatency,
    );

    // 🔥 スキャン開始時、現在スロットを初期化しておく
    final now = DateTime.now().millisecondsSinceEpoch;
    final slotMillis = 10 * 60 * 1000;
    _currentSlot = _calcSlot(now, slotMillis);

    _sub = FlutterBluePlus.scanResults.listen(
          (results) {
        for (final r in results) {
          _onDiscover(r);
        }
      },
      onError: (e) {
        if (kDebugMode) print('BLE_SCAN: scanResults error: $e');
      },
    );

    _gcTimer = Timer.periodic(const Duration(minutes: 1), (_) => _gcSweep());
  }

  // --------------------------------------------------------
  // STOP SCAN
  // --------------------------------------------------------
  Future<void> stop() async {
    if (!_isScanning) return;

    await FlutterBluePlus.stopScan();
    await _sub?.cancel();
    _sub = null;

    _gcTimer?.cancel();
    _gcTimer = null;

    _halves.clear();
    _queue.clear();
    _globalCacheKeys.clear(); // 🔥 キャッシュもリセット

    _isScanning = false;

    if (kDebugMode) print('BLE_SCAN: 🛑 stopScan() called.');
  }

  // --------------------------------------------------------
  // DISCOVERY HANDLER
  // --------------------------------------------------------
  void _onDiscover(ScanResult r) async {
    final adv = r.advertisementData;
    if (!adv.manufacturerData.containsKey(_companyId)) return;

    final payload = Uint8List.fromList(adv.manufacturerData[_companyId]!);
    if (payload.length < 31) return;

    final header = payload[0];
    final keyIdBytes = Uint8List.fromList(payload.sublist(1, 5));
    final seq2 = BleHdr.parseSeq2(header);
    final part = BleHdr.parsePart(header);
    final yParity = BleHdr.parseYParity(header);
    final body16 = Uint8List.fromList(payload.sublist(5, 21));

    final now = DateTime.now().millisecondsSinceEpoch;
    final slotMillis = 10 * 60 * 1000;
    final slot = _calcSlot(now, slotMillis);

    // 🔥 スロット変化 → キャッシュクリア
    if (slot != _currentSlot) {
      _globalCacheKeys.clear();
      _currentSlot = slot;
      if (kDebugMode) print("BLE_SCAN: 🔄 time slot changed → cache reset");
    }

    final cacheKey = '$seq2|${keyIdBytes.join()}';

    // ------------------------------
    // 片割れ管理
    // ------------------------------
    var st = _halves[cacheKey];
    if (st == null) {
      st = _HalfState(
        keyId: keyIdBytes,
        seq2: seq2,
        yParity: yParity,
        firstSeenMs: now,
      );
      _halves[cacheKey] = st;
      _queue.addLast(_QueueEntry(key: cacheKey, firstSeenMs: now));
    }

    if (part == 0) st.front16 = body16;
    if (part == 1) st.back16 = body16;

    // ------------------------------
    // 両パーツ揃った
    // ------------------------------
    if (st.front16 != null && st.back16 != null) {
      final merged = Uint8List.fromList([
        0x02 | (st.yParity & 0x01),
        ...st.front16!,
        ...st.back16!,
      ]);

      final calculatedHash = _getKeyHashId(merged);
      if (listEquals(st.keyId, calculatedHash)) {
        final hex = merged.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

        // 1️⃣ キャッシュチェック
        if (_globalCacheKeys.contains(hex)) {
          _halves.remove(cacheKey);
          return;
        }

        // 2️⃣ DB チェック
        final exists = await DatabaseHelper.existsCollectedKey(merged);
        if (exists) {
          _globalCacheKeys.add(hex);
          _halves.remove(cacheKey);
          return;
        }

        // 3️⃣ 新規 → GPS取得
        int latE6 = 0;
        int lonE6 = 0;
        try {
          final pos = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high,
          );
          latE6 = (pos.latitude * 1e6).round();
          lonE6 = (pos.longitude * 1e6).round();
        } catch (_) {}

        // 4️⃣ DB Insert
        final inserted = await DatabaseHelper.insertCollectedKeyIfAbsent(
          pubkey33: merged,
          tms: now,
          latE6: latE6,
          lonE6: lonE6,
        );

        if (inserted) {
          if (kDebugMode) print("BLE_SCAN: 🔑 新規鍵をDBに追加しました");
          _globalCacheKeys.add(hex);
          KeyManagementService().notifyKeyUpdated();
        }
      }

      _halves.remove(cacheKey);
    }

    _gcSweep();
  }

  // --------------------------------------------------------
  // GC SWEEP
  // --------------------------------------------------------
  void _gcSweep() {
    final now = DateTime.now().millisecondsSinceEpoch;
    while (_queue.isNotEmpty) {
      final head = _queue.first;
      if ((now - head.firstSeenMs) >= _halfTtl.inMilliseconds) {
        _halves.remove(_queue.removeFirst().key);
      } else {
        break;
      }
    }
  }
}

// =====================================================================

class _HalfState {
  _HalfState({
    required this.keyId,
    required this.seq2,
    required this.yParity,
    required this.firstSeenMs,
  });

  final Uint8List keyId;
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
