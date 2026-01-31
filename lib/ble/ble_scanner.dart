// lib/ble/ble_scanner.dart

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:pointycastle/export.dart' as pc;

import '../key_management_service.dart';
import 'ble_protocol.dart';

class BleScanner {
  StreamSubscription<List<ScanResult>>? _sub;
  Timer? _gcTimer;

  static const int _companyId = 0xFFFF;

  /// 断片の保持期限（時刻スロット(10分)相当）
  static const Duration _halfTtl = Duration(minutes: 10);

  bool _isScanning = false;
  bool get isScanning => _isScanning;

  final KeyManagementService _kms = KeyManagementService();

  /// keyId と seq2 をキーに断片を管理する
  final Map<String, _HalfState> _halves = {};

  /// 期限切れ掃除のための到着順キュー
  final Queue<_QueueEntry> _queue = Queue<_QueueEntry>();

  /// 同一時刻スロット内の重複を抑止するキャッシュ
  static final Set<String> _globalCacheKeys = {};
  static int _currentSlot = -1;

  /// 収集済みキャッシュを初期化する（外部から呼び出し可）
  static void clearCollectedCache() {
    _globalCacheKeys.clear();
    if (kDebugMode) {
      debugPrint('BLE_SCAN: collected key cache cleared');
    }
  }

  // ----- Start / Stop -----

  Future<void> start() async {
    if (_isScanning) return;
    _isScanning = true;

    if (kDebugMode) debugPrint('BLE_SCAN: startScan');

    await FlutterBluePlus.stopScan();
    await FlutterBluePlus.startScan(
      androidScanMode: AndroidScanMode.lowLatency,
    );

    final now = DateTime.now().millisecondsSinceEpoch;
    _currentSlot = now ~/ _kms.slotMs;

    _sub = FlutterBluePlus.scanResults.listen(
          (results) {
        for (final r in results) {
          _onDiscover(r);
        }
      },
      onError: (e) {
        if (kDebugMode) debugPrint('BLE_SCAN: scanResults error: $e');
      },
    );

    _gcTimer = Timer.periodic(
      const Duration(minutes: 1),
          (_) => _gcSweep(),
    );
  }

  Future<void> stop() async {
    if (!_isScanning) return;

    await FlutterBluePlus.stopScan();
    await _sub?.cancel();
    _sub = null;

    _gcTimer?.cancel();
    _gcTimer = null;

    _halves.clear();
    _queue.clear();
    _globalCacheKeys.clear();

    _isScanning = false;

    if (kDebugMode) debugPrint('BLE_SCAN: stopScan');
  }

  // ----- Discovery -----

  void _onDiscover(ScanResult r) async {
    final adv = r.advertisementData;
    if (!adv.manufacturerData.containsKey(_companyId)) return;

    final payload = Uint8List.fromList(
      adv.manufacturerData[_companyId]!,
    );
    if (payload.length < 31) return;

    final header = payload[0];
    final keyIdBytes = Uint8List.fromList(payload.sublist(1, 5));
    final seq2 = BleHdr.parseSeq2(header);
    final part = BleHdr.parsePart(header);
    final yParity = BleHdr.parseYParity(header);
    final body16 = Uint8List.fromList(payload.sublist(5, 21));

    final now = DateTime.now().millisecondsSinceEpoch;
    final slot = now ~/ _kms.slotMs;

    // 時刻スロット(10分)が更新されたらキャッシュを初期化する
    if (slot != _currentSlot) {
      _globalCacheKeys.clear();
      _currentSlot = slot;
      if (kDebugMode) {
        debugPrint('BLE_SCAN: slot changed; cache reset');
      }
    }

    final cacheKey = '$seq2|${keyIdBytes.join()}';

    // 断片の受信状態を更新する
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

    // 2断片が揃ったら公開鍵(33B)を復元する
    if (st.front16 != null && st.back16 != null) {
      final merged = Uint8List.fromList([
        0x02 | (st.yParity & 0x01),
        ...st.front16!,
        ...st.back16!,
      ]);

      // KeyID 検証（SHA-256(公開鍵33B)の先頭4B）
      final calculatedHash = _getKeyHashId(merged);
      if (!listEquals(st.keyId, calculatedHash)) {
        _halves.remove(cacheKey);
        return;
      }

      final hex = _bytesToHex(merged);

      // 同一時刻スロット内の重複を除外する
      if (_globalCacheKeys.contains(hex)) {
        _halves.remove(cacheKey);
        return;
      }

      // 既収集鍵はスキップする
      if (await _kms.hasCollectedKey(merged)) {
        _globalCacheKeys.add(hex);
        _halves.remove(cacheKey);
        return;
      }

      // 収集鍵として登録する
      final inserted = await _kms.insertCollectedKeyIfAbsent(
        pubkey33: merged,
        receivedAtMs: now,
      );

      if (inserted) {
        _globalCacheKeys.add(hex);
        if (kDebugMode) {
          debugPrint('BLE_SCAN: new collected key stored');
        }
      }

      _halves.remove(cacheKey);
    }

    _gcSweep();
  }

  // ----- GC -----

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

class _HalfState {
  _HalfState({
    required this.keyId,
    required this.seq2,
    required this.yParity,
    required this.firstSeenMs,
  });

  final Uint8List keyId;
  final int seq2;
  final int yParity;
  final int firstSeenMs;

  Uint8List? front16;
  Uint8List? back16;
}

class _QueueEntry {
  _QueueEntry({required this.key, required this.firstSeenMs});
  final String key;
  final int firstSeenMs;
}
