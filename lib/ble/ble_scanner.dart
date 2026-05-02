// lib/ble/ble_scanner.dart
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:pointycastle/export.dart' as pc;

import 'ble_constants.dart';
import 'ecd_keys_dao.dart';
import '../db/friends_dao.dart';
   // Random.secure()
import 'dart:math';
import '../key_management_service.dart';
import '../native_key_service.dart';

class BleScanner {
  StreamSubscription<List<ScanResult>>? _sub;
  Timer? _gcTimer;

  /// 友達ニックネームにマッチした & 認証結果を UI に通知するためのコールバック
  void Function(String friendLabel, bool authenticated)? onFriendDetected;
  /// ★追加：Challengeを広告で送ってほしい
  void Function(Uint8List targetKeyId4, int challengeId, Uint8List nonce16, Uint8List verifierId4)?
  onNeedAdvertiseChallenge;

  /// ★追加：Signature(64B)を広告で送ってほしい
  void Function(Uint8List targetKeyId4, int challengeId, Uint8List signature64, Uint8List verifierId4)?
  onNeedAdvertiseSignature;

  // ================================
  // ★ 追加：同一友達の連続通知を抑制
  // ================================
  final Map<String, int> _lastNotifiedMs = {};
  static const Duration _notifyCooldown = Duration(seconds: 20);
  static const int _companyId = 0xFFFF;

  bool _isScanning = false;
  bool get isScanning => _isScanning;

  static const Duration _halfTtl = Duration(minutes: 10);

  final Map<String, _HalfState> _halves = {};
  final Queue<_QueueEntry> _queue = Queue<_QueueEntry>();
  // ===== 認証用 state =====
  final _rng = Random.secure();
  final _kms = KeyManagementService();
  final _native = NativeKeyService();

  final Map<String, Uint8List> _peerPubkeyByKeyId = {}; // keyIdHex -> pubkey33
  final Map<String, int> _lastChallengeSentMsByKeyId = {};
  final Map<String, _PendingChallenge> _pendingChallenges = {};
  final Map<String, _SigCollect> _sigCollect = {};
  final Map<String, int> _handledInboundChallengeMs = {};
  final Map<String, int> _authOkUntilMsByKeyId = {};

  static const Duration _challengeCooldown = Duration(seconds: 3);
  static const Duration _challengeTtl = Duration(seconds: 10);
  static const Duration _authOkTtl = Duration(seconds: 30);


  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Uint8List _getKeyHashId(Uint8List key33) {
    final digest = pc.SHA256Digest();
    final hash = digest.process(key33);
    return hash.sublist(0, 4);
  }

  // ===== 認証: 共通キー生成 =====
  String _pendingKey(String keyIdHex, Uint8List verifierId4, int challengeId) {
    return '$keyIdHex|${_bytesToHex(verifierId4)}|$challengeId';
  }

  /// 署名・検証に使う「チャレンジバイト列」を固定フォーマットで構成
  /// ※prefixはドメイン分離（別用途の署名と混ざらない）目的
  Uint8List _buildChallengeBytes(
      Uint8List targetKeyId4,
      int challengeId,
      Uint8List nonce16,
      Uint8List verifierId4,
      ) {
    const prefix = <int>[0x42, 0x4C, 0x45, 0x41, 0x55, 0x54, 0x48, 0x01]; // "BLEAUTH"+0x01
    return Uint8List.fromList([
      ...prefix,
      ...targetKeyId4,
      challengeId & 0xFF,
      ...nonce16,
      ...verifierId4,
    ]);
  }

  /// ver=6で友達候補が見つかったときに、challengeを1回だけ投げる（連発防止つき）
  void _maybeSendChallenge({
    required Uint8List targetKeyId4,
    required String targetKeyIdHex,
    required Uint8List peerPubkey33,
    required List<String> friendLabels,
  }) {
    if (onNeedAdvertiseChallenge == null) return;

    final now = DateTime.now().millisecondsSinceEpoch;

    // 直近で認証OKなら再チャレンジしない
    final okUntil = _authOkUntilMsByKeyId[targetKeyIdHex] ?? 0;
    if (now < okUntil) return;

    // チャレンジ連発防止（cooldown）
    final lastSent = _lastChallengeSentMsByKeyId[targetKeyIdHex] ?? 0;
    if (now - lastSent < _challengeCooldown.inMilliseconds) return;

    // 既にpendingがあるなら追加で投げない
    final hasPending = _pendingChallenges.keys.any((k) => k.startsWith('$targetKeyIdHex|'));
    if (hasPending) return;

    final challengeId = _rng.nextInt(256);
    final nonce16 = Uint8List.fromList(List<int>.generate(16, (_) => _rng.nextInt(256)));
    final verifierId4 = Uint8List.fromList(List<int>.generate(4, (_) => _rng.nextInt(256)));

    final pKey = _pendingKey(targetKeyIdHex, verifierId4, challengeId);

    _pendingChallenges[pKey] = _PendingChallenge(
      targetKeyId4: Uint8List.fromList(targetKeyId4),
      targetKeyIdHex: targetKeyIdHex,
      challengeId: challengeId,
      nonce16: nonce16,
      verifierId4: verifierId4,
      createdMs: now,
      peerPubkey33: peerPubkey33,
      friendLabels: List<String>.from(friendLabels),
    );

    _peerPubkeyByKeyId[targetKeyIdHex] = peerPubkey33;
    _lastChallengeSentMsByKeyId[targetKeyIdHex] = now;

    onNeedAdvertiseChallenge!.call(targetKeyId4, challengeId, nonce16, verifierId4);
  }

  /// ver=7 Challenge受信 → 自分の現在鍵ID宛てなら署名して ver=8 を広告に積む
  Future<void> _handleInboundChallenge({
    required Uint8List targetKeyId4,
    required String targetKeyIdHex,
    required int challengeId,
    required Uint8List nonce16,
    required Uint8List verifierId4,
  }) async {
    if (onNeedAdvertiseSignature == null) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final pKey = _pendingKey(targetKeyIdHex, verifierId4, challengeId);

    // 同じ challenge を短時間に何回も署名しない（リプレイ耐性/負荷対策）
    final lastHandled = _handledInboundChallengeMs[pKey];
    if (lastHandled != null && (now - lastHandled) < _challengeTtl.inMilliseconds) {
      return;
    }

    // 自分の最新鍵ペア（秘密鍵で署名する）
    final kp = await _kms.getLatestKeyPair();
    if (kp == null) return;

    // 自分の公開鍵から keyId を作って、宛先(targetKeyId4) と一致するか確認
    final ownKeyId4 = _getKeyHashId(kp.publicKey);
    if (!listEquals(ownKeyId4, targetKeyId4)) return;

    final challengeBytes = _buildChallengeBytes(targetKeyId4, challengeId, nonce16, verifierId4);

    // ECDSA署名（64B: r||s を想定）
    final sig64 = _native.signChallenge(kp.privateKey, challengeBytes);
    if (sig64 == null || sig64.lengthInBytes != 64) return;

    _handledInboundChallengeMs[pKey] = now;
    onNeedAdvertiseSignature!.call(targetKeyId4, challengeId, sig64, verifierId4);
  }

  /// ver=8 Signature断片受信 → 4片揃ったら verify して authenticated=true を通知
  Future<void> _handleInboundSignature({
    required Uint8List targetKeyId4,
    required String targetKeyIdHex,
    required int challengeId,
    required int partIndex,
    required Uint8List sigPart16,
    required Uint8List verifierId4,
  }) async {
    if (partIndex < 0 || partIndex > 3) return;
    if (sigPart16.lengthInBytes != 16) return;

    final pKey = _pendingKey(targetKeyIdHex, verifierId4, challengeId);

    final collect = _sigCollect.putIfAbsent(pKey, () => _SigCollect());
    collect.setPart(partIndex, sigPart16);

    if (!collect.isComplete) return;

    final pending = _pendingChallenges[pKey];
    if (pending == null) {
      _sigCollect.remove(pKey);
      return;
    }

    // TTL超過なら失効扱い
    final now = DateTime.now().millisecondsSinceEpoch;
    if ((now - pending.createdMs) >= _challengeTtl.inMilliseconds) {
      _pendingChallenges.remove(pKey);
      _sigCollect.remove(pKey);
      return;
    }

    final pubkey = _peerPubkeyByKeyId[targetKeyIdHex] ?? pending.peerPubkey33;
    final challengeBytes = _buildChallengeBytes(
      pending.targetKeyId4,
      pending.challengeId,
      pending.nonce16,
      pending.verifierId4,
    );

    final sig64 = collect.assemble();
    final ok = _native.verifyChallenge(pubkey, challengeBytes, sig64);

    if (ok) {
      // 認証OKは一定時間キャッシュして、無駄なchallengeを減らす
      _authOkUntilMsByKeyId[targetKeyIdHex] = now + _authOkTtl.inMilliseconds;

      for (final label in pending.friendLabels) {
        onFriendDetected?.call(label, true);
      }
    }

    _pendingChallenges.remove(pKey);
    _sigCollect.remove(pKey);
  }

  // --------------------------------------------------------
  // START SCAN (flutter_blue_plus 2.0.2 compatible)
  // --------------------------------------------------------
  Future<void> start() async {
    if (_isScanning) return;
    _isScanning = true;

    if (kDebugMode) print('BLE_SCAN: 🚀 startScan() called.');

    // 念のため停止 (修正: .instance を削除)
    await FlutterBluePlus.stopScan();

    // ★ 新 API：startScan は void (修正: .instance を削除)
    await FlutterBluePlus.startScan(
      androidScanMode: AndroidScanMode.lowLatency,
    );

    // ★ 結果は scanResults から取得
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

    // (修正: .instance を削除)
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
    // 最新版では remoteId.str で正しいですが、
    // もし古いバージョンを使っている場合は r.device.id.id になる可能性があります
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

    final seq2 = BleHdr.parseSeq2(header);
    final part = BleHdr.parsePart(header);
    final yp = BleHdr.parseYParity(header);
    final ver = BleHdr.parseVer(header);

    final now = DateTime.now().millisecondsSinceEpoch;

    // ===== ver=7 Challenge =====
    if (ver == BleHdr.verChallenge) {
      // layout: [2]=hdr, [3..6]=targetKeyId4, [7]=challengeId, [8..23]=nonce16, [24..27]=verifierId4
      final challengeId = fullPayload[7];
      final nonce16 = Uint8List.fromList(fullPayload.sublist(8, 24));
      final verifierId4 = Uint8List.fromList(fullPayload.sublist(24, 28));
      await _handleInboundChallenge(
        targetKeyId4: keyIdBytes,
        targetKeyIdHex: keyIdHex,
        challengeId: challengeId,
        nonce16: nonce16,
        verifierId4: verifierId4,
      );
      _gcSweep();
      return;
    }

    // ===== ver=8 Signature =====
    if (ver == BleHdr.verSignature) {
      // layout: [2]=hdr, [3..6]=targetKeyId4, [7]=challengeId, [8]=partIndex, [9..24]=sigPart16, [25..28]=verifierId4
      final challengeId = fullPayload[7];
      final partIndex = fullPayload[8];
      final sigPart16 = Uint8List.fromList(fullPayload.sublist(9, 25));
      final verifierId4 = Uint8List.fromList(fullPayload.sublist(25, 29));
      await _handleInboundSignature(
        targetKeyId4: keyIdBytes,
        targetKeyIdHex: keyIdHex,
        challengeId: challengeId,
        partIndex: partIndex,
        sigPart16: sigPart16,
        verifierId4: verifierId4,
      );
      _gcSweep();
      return;
    }

    // ===== ver=6 Pubkey fragments（従来） =====
    if (ver != BleHdr.currentVer) return;
    if (part > 1) return;

    // ver=6 のみ body16 を読む
    final body16 = Uint8List.fromList(fullPayload.sublist(7, 23));

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
        try {
          // ① friend_nicknames に一致する友達ラベルを検索
          final labels = await FriendsDao.instance.findFriendLabelsByPubkey(merged);

          // pubkey を keyId で保持（署名検証で使う）
          _peerPubkeyByKeyId[keyIdHex] = merged;

          // まずは候補として通知（authenticated=false）
          for (final friendLabel in labels) {
            final last = _lastNotifiedMs[friendLabel];
            final nowMs = now;

            final canNotify = (last == null) ||
                ((nowMs - last) >= _notifyCooldown.inMilliseconds);

            if (canNotify) {
              _lastNotifiedMs[friendLabel] = nowMs;
              onFriendDetected?.call(friendLabel, false);
            }
          }

          // 未認証なら challenge を投げる（labelsが空でない場合だけ）
          if (labels.isNotEmpty) {
            _maybeSendChallenge(
              targetKeyId4: keyIdBytes,
              targetKeyIdHex: keyIdHex,
              peerPubkey33: merged,
              friendLabels: labels,
            );
          }

          await EcdKeysDao.instance.insertCollected(
            pubkey33: merged,
            tms: now,
            latE6: 0,
            lonE6: 0,
          );
        } catch (_) {}
      }

      _halves.remove(key);
    }

    _gcSweep();
  }

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
    // ===== 認証用 state 掃除 =====
    _authOkUntilMsByKeyId.removeWhere((_, until) => now >= until);

    _handledInboundChallengeMs.removeWhere(
          (_, ts) => (now - ts) >= _challengeTtl.inMilliseconds,
    );

    // pending challenge の期限切れ
    final expiredKeys = <String>[];
    _pendingChallenges.forEach((k, p) {
      if ((now - p.createdMs) >= _challengeTtl.inMilliseconds) expiredKeys.add(k);
    });
    for (final k in expiredKeys) {
      _pendingChallenges.remove(k);
      _sigCollect.remove(k);
    }

    _sigCollect.removeWhere((_, c) => (now - c.firstSeenMs) >= _challengeTtl.inMilliseconds);
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

class _PendingChallenge {
  _PendingChallenge({
    required this.targetKeyId4,
    required this.targetKeyIdHex,
    required this.challengeId,
    required this.nonce16,
    required this.verifierId4,
    required this.createdMs,
    required this.peerPubkey33,
    required this.friendLabels,
  });

  final Uint8List targetKeyId4;
  final String targetKeyIdHex;
  final int challengeId;
  final Uint8List nonce16;
  final Uint8List verifierId4;
  final int createdMs;

  final Uint8List peerPubkey33;
  final List<String> friendLabels;
}

class _SigCollect {
  _SigCollect() : firstSeenMs = DateTime.now().millisecondsSinceEpoch;

  final int firstSeenMs;
  final List<Uint8List?> _parts = List<Uint8List?>.filled(4, null);

  void setPart(int idx, Uint8List part16) {
    if (idx < 0 || idx > 3) return;
    _parts[idx] = part16;
  }

  bool get isComplete => _parts.every((p) => p != null);

  Uint8List assemble() {
    return Uint8List.fromList([
      ..._parts[0]!,
      ..._parts[1]!,
      ..._parts[2]!,
      ..._parts[3]!,
    ]);
  }
}
