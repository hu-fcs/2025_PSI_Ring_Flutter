// lib/ble/ble_scanner.dart
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pointycastle/export.dart' as pc;

import 'ble_constants.dart';
import 'ecd_keys_dao.dart';

class BleScanner {
  StreamSubscription<List<ScanResult>>? _sub;
  Timer? _gcTimer;

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

  // --------------------------------------------------------
  // START SCAN
  // --------------------------------------------------------
  Future<void> start() async {
    if (_isScanning) return;
    _isScanning = true;

    if (kDebugMode) print('BLE_SCAN: 🚀 startScan() called.');

    // 念のため停止
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
    final deviceId = r.device.remoteId.str;

    if (!adv.manufacturerData.containsKey(_companyId)) return;

    final data = adv.manufacturerData[_companyId]!;
    final payload = Uint8List.fromList(data);

    final fullPayload = Uint8List.fromList([
      _companyId & 0xff,
      (_companyId >> 8) & 0xff,
      ...payload,
    ]);

    const expectedLength = 2 + 31;
    if (fullPayload.length < expectedLength) return;

    final receivedId = fullPayload[0] | (fullPayload[1] << 8);
    if (receivedId != _companyId) return;

    final header = fullPayload[2];
    final keyIdBytes = Uint8List.fromList(fullPayload.sublist(3, 7));
    final keyIdHex = _bytesToHex(keyIdBytes);
    final body16 = Uint8List.fromList(fullPayload.sublist(7, 23));

    final seq2 = BleHdr.parseSeq2(header);
    final part = BleHdr.parsePart(header);
    final yp = BleHdr.parseYParity(header);
    final ver = BleHdr.parseVer(header);

    if (ver != BleHdr.currentVer) return;
    if (part > 1) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final key = '$seq2|$keyIdHex';

    var st = _halves[key];
    if (st == null) {
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
        st.resetParts();
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

    // ------------------------------
    // 両方のパーツが揃った場合
    // ------------------------------
    if (st.front16 != null && st.back16 != null) {
      final merged = Uint8List.fromList([
        0x02 | (st.yParity & 0x01),
        ...st.front16!,
        ...st.back16!,
      ]);

      final valid = isValidCompressedPubkey(merged);
      final receivedHash = st.keyId;
      final calculatedHash = _getKeyHashId(merged);

      if (valid && listEquals(receivedHash, calculatedHash)) {
        // ------------------------------
        // 🔥 ここで GPS 取得
        // ------------------------------
        int latE6 = 0;
        int lonE6 = 0;

        try {
          final pos = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high,
          );

          latE6 = (pos.latitude * 1e6).round();
          lonE6 = (pos.longitude * 1e6).round();
        } catch (e) {
          // 位置情報が許可されていない or GPS OFF でも問題なし
          if (kDebugMode) print("GPS unavailable: $e");
        }

        // ------------------------------
        // DB 保存（GPS 付き）
        // ------------------------------
        try {
          await EcdKeysDao.instance.insertCollected(
            pubkey33: merged,
            tms: now,
            latE6: latE6,
            lonE6: lonE6,
          );
        } catch (_) {}
      }

      _halves.remove(key);
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
