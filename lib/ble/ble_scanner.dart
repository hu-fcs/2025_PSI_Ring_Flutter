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

    _isScanning = false;

    if (kDebugMode) print('BLE_SCAN: 🛑 stopScan() called.');
  }

  // --------------------------------------------------------
  // DISCOVERY HANDLER
  // --------------------------------------------------------
  void _onDiscover(ScanResult r) async {
    final adv = r.advertisementData;

    if (!adv.manufacturerData.containsKey(_companyId)) return;

    final data = adv.manufacturerData[_companyId]!;
    final payload = Uint8List.fromList(data);

    if (payload.length < 31) return;

    final header = payload[0];
    final keyIdBytes = Uint8List.fromList(payload.sublist(1, 5));
    final seq2 = BleHdr.parseSeq2(header);
    final part = BleHdr.parsePart(header);
    final yParity = BleHdr.parseYParity(header);

    final body16 = Uint8List.fromList(payload.sublist(5, 21));

    final now = DateTime.now().millisecondsSinceEpoch;
    final cacheKey = '$seq2|${keyIdBytes.join()}';

    // キーの状態管理
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

    // 両パーツ揃った
    if (st.front16 != null && st.back16 != null) {
      final merged = Uint8List.fromList([
        0x02 | (st.yParity & 0x01),
        ...st.front16!,
        ...st.back16!,
      ]);

      final calculatedHash = _getKeyHashId(merged);
      if (listEquals(st.keyId, calculatedHash)) {
        // ------------------------------
        // 🔍 DBに存在確認
        // ------------------------------
        final exists = await DatabaseHelper.existsCollectedKey(merged);

        if (!exists) {
          // GPS取得（オプション）
          int latE6 = 0;
          int lonE6 = 0;
          try {
            final pos = await Geolocator.getCurrentPosition(
              desiredAccuracy: LocationAccuracy.high,
            );
            latE6 = (pos.latitude * 1e6).round();
            lonE6 = (pos.longitude * 1e6).round();
          } catch (_) {}

          // ------------------------------
          // INSERT（存在しない場合のみ）
          // ------------------------------
          final inserted = await DatabaseHelper.insertCollectedKeyIfAbsent(
            pubkey33: merged,
            tms: now,
            latE6: latE6,
            lonE6: lonE6,
          );

          if (inserted) {
            if (kDebugMode) print("BLE_SCAN: 🔑 新規鍵をDBに追加しました");

            // PSI サーバや DebugPage に通知
            KeyManagementService().notifyKeyUpdated();
          }
        } else {
          if (kDebugMode) print("BLE_SCAN: 既存鍵のためスキップ");
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
