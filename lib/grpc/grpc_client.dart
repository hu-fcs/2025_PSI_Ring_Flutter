// lib/grpc/grpc_client.dart

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:grpc/grpc.dart';
import 'package:fixnum/fixnum.dart' as $fixnum show Int64;

import '../proto/generated/grpc.pbgrpc.dart';
import '../ffi/native_key_service.dart';
import '../key_management.dart';
import '../db/friends_dao.dart';
import 'grpc_common.dart';

/// gRPC クライアント（PSI + リング署名）。
class GrpcClient {
  ClientChannel? _channel;
  GrpcServiceClient? _stub;

  final NativeKeyService _keyService = NativeKeyService();
  final KeyManagementService _kms = KeyManagementService();
  final GrpcCommon _grpcCommon = GrpcCommon();

  late final Future<void> _ready;

  bool get isConnected => _stub != null;

  GrpcClient() {
    _ready = _initialize();
  }

  Future<void> _initialize() async {
    if (kDebugMode) {
      debugPrint('[GPRC CLIENT] init');
    }
  }

  Future<void> _ensureReady() async => _ready;

  // ----- Connection -----

  /// gRPCサーバに接続し，OOB (Out-of-band) 認証もする
  Future<void> connect(String host, int port, int oobNonce) async {
    await _ensureReady();

    if (kDebugMode) {
      debugPrint('[GRPC CLIENT] connect: $host:$port');
    }

    try {
      await disconnect();

      final options = _grpcCommon.buildClientOptions(
        idleTimeout: const Duration(seconds: 30),
      );
      _channel = ClientChannel(
        host,
        port: port,
        options: options,
      );

      _stub = GrpcServiceClient(_channel!);
      /* 証明書が合わない場合はここでは例外は発生しない．
         この後 outOfBandAuth() 呼び出しの時点で
         StatusCode.unavailable の GrpcError
       　message 中に CERTIFICATE_VERIFY_FAILED: self signed certificate
      */
      if (kDebugMode) {
        debugPrint('[GRPC CLIENT] connected '
            '${options.credentials.isSecure ? '(secure)' : '(insecure)'}');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[GRPC CLIENT] connect failed: $e');
        debugPrint('$st');
      }
      rethrow;
    }
    // OOB (Out-of-band) 認証
    try {
      await outOfBandAuth(oobNonce);
    } catch (e) { // 認証失敗
      await disconnect();
      rethrow;
    }
    if (kDebugMode) debugPrint('[GRPC CLIENT] authenticated');
  }

  Future<void> disconnect() async {
    try {
      await _channel?.shutdown();
    } catch (_) {}
    _channel = null;
    _stub = null;
  }

  // ----- PSI + Ring signature -----

  Future<PsiResult> executePsi() async {
    await _ensureReady();
    final stub = _stub;
    if (stub == null) throw StateError('[GRPC CLIENT] not connected');

    final totalSw = Stopwatch()
      ..start();

    // 1) 鍵読み込み（生成鍵 + 収集鍵）
    final dbSw = Stopwatch()
      ..start();
    final generated = await _kms.getAllGeneratedPublicKeys();
    final collected = await _kms.getAllCollectedPublicKeys();
    dbSw.stop();

    final myKeys = [...generated, ...collected];

    // クライアント側集合サイズ（|S_A|）
    final saKeyCount = myKeys.length;

    if (myKeys.isEmpty) {
      totalSw.stop();
      return PsiResult(
        isFamiliar: false,
        saKeyCount: 0,
        sbKeyCount: 0,
        commonKeys: const [],
        ringSize: 0,
        dbLoadTimeMs: dbSw.elapsedMilliseconds,
        psiTimeMs: 0,
        ringSelectTimeMs: 0,
        ringSigTimeMs: 0,
        totalTimeMs: totalSw.elapsedMilliseconds,
      );
    }

    // 2) PSI
    final psiSw = Stopwatch()
      ..start();

    // bQ 計算
    final mySecret = _keyService.generateRandomSecret();
    final myEncKeys = _keyService.encryptSet(myKeys, mySecret);

    // サーバと暗号化集合を交換
    final resp = await stub.exchangeKeys(
      KeyExchangeReq()
        ..encKeys.addAll(myEncKeys),
    );

    final serverEncKeys =
    resp.serverEncKeys.map((e) => Uint8List.fromList(e)).toList();
    final abQ = resp.clientReencKeys.map((e) => Uint8List.fromList(e)).toList();

    // サーバ側集合サイズ（|S_B|）
    final sbKeyCount = serverEncKeys.length;

    // abP 計算
    final abP = _keyService.encryptSet(serverEncKeys, mySecret);

    // 共通集合（クライアント側復元）
    final clientCommon = _keyService.intersect(myKeys, abQ, abP);

    await stub.finalizePsi(
      ClientFinalReq()
        ..clientReencServerKeys.addAll(abP),
    );

    psiSw.stop();
    final psiTimeMs = psiSw.elapsedMilliseconds;

    // 3) PSI による顔見知り判定（共通集合に自端末の生成鍵が含まれるか）
    final commonHex = clientCommon.map(GrpcCommon.bytesToHex).toList();
    final myGenHex = generated.map(GrpcCommon.bytesToHex).toSet();
    final familiarByPsi = commonHex
        .toSet()
        .intersection(myGenHex)
        .isNotEmpty;

    // 4) リング署名（必要時のみ）
    bool ringOk = false;
    int ringSize = 0;
    int ringSelectTimeMs = 0;
    int ringSigTimeMs = 0;

    if (familiarByPsi && clientCommon.length >= 2) {
      final result = await _runRingSignaturePhase(
        stub: stub,
        intersection: clientCommon,
      );

      ringOk = result.$1;
      ringSize = result.$2;
      ringSelectTimeMs = result.$3;
      ringSigTimeMs = result.$4;
    }

    totalSw.stop();

    return PsiResult(
      isFamiliar: familiarByPsi && ringOk,
      saKeyCount: saKeyCount,
      sbKeyCount: sbKeyCount,
      commonKeys: commonHex,
      ringSize: ringSize,
      dbLoadTimeMs: dbSw.elapsedMilliseconds,
      psiTimeMs: psiTimeMs,
      ringSelectTimeMs: ringSelectTimeMs,
      ringSigTimeMs: ringSigTimeMs,
      totalTimeMs: totalSw.elapsedMilliseconds,
    );
  }

  // ----- Ring signature phase -----

  Future<(bool, int, int, int)> _runRingSignaturePhase({
    required GrpcServiceClient stub,
    required List<Uint8List> intersection,
  }) async {
    final buildSw = Stopwatch()
      ..start();

    final signerKey = await _kms.selectSignerKeyFromIntersection(intersection);
    if (signerKey == null) {
      buildSw.stop();
      return (false, 0, buildSw.elapsedMilliseconds, 0);
    }

    final generateTimeMs = await _kms.getTimestampForKey(signerKey.publicKey);
    if (generateTimeMs == null) {
      buildSw.stop();
      return (false, 0, buildSw.elapsedMilliseconds, 0);
    }

    final challengeC = _keyService.generateRandomSecret();
    final challengeFuture = stub.exchangeChallenges(
      ClientChallenge()
        ..challengeC = challengeC,
    );

    // 同一時刻スロット内の鍵に限定してリングを構成する
    final filteredRing =
    await _kms.filterKeysBySameSlot(intersection, generateTimeMs);

    if (filteredRing.length < 2) {
      buildSw.stop();
      return (false, filteredRing.length, buildSw.elapsedMilliseconds, 0);
    }

    filteredRing.sort(GrpcCommon.comparePubKey);

    buildSw.stop();
    final ringSelectTimeMs = buildSw.elapsedMilliseconds;

    final sigSw = Stopwatch()
      ..start();

    final resp = await challengeFuture;
    final challengeS = Uint8List.fromList(resp.challengeS);

    final msgForServer = GrpcCommon.bytesToHex(challengeS);
    final msgForClient = GrpcCommon.bytesToHex(challengeC);

    final sigForServer =
    _createRingSignature(msgForServer, signerKey.privateKey, filteredRing);
    if (sigForServer == null) {
      sigSw.stop();
      return (
      false,
      filteredRing.length,
      ringSelectTimeMs,
      sigSw.elapsedMilliseconds
      );
    }

    final sigResp = await stub.exchangeRingSignatures(
      RingSignatureReq()
        ..signatureForServer = sigForServer,
    );

    final sigFromServer = Uint8List.fromList(sigResp.signatureForClient);
    final ok = _verifyRingSignature(msgForClient, sigFromServer, filteredRing);

    sigSw.stop();
    final ringSigTimeMs = sigSw.elapsedMilliseconds;

    return (ok, filteredRing.length, ringSelectTimeMs, ringSigTimeMs);
  }

  // ----- Signature -----

  Uint8List? _createRingSignature(String msgHex,
      Uint8List privKey,
      List<Uint8List> ring,) {
    final msgPtr = msgHex.toNativeUtf8().cast<Char>();
    final privPtr = calloc<Uint8>(privKey.length)
      ..asTypedList(privKey.length).setAll(0, privKey);

    const pubLen = 33;
    final ringPtr = calloc<Uint8>(pubLen * ring.length);
    final view = ringPtr.asTypedList(pubLen * ring.length);

    int offset = 0;
    for (final k in ring) {
      view.setAll(offset, k);
      offset += k.length;
    }

    final sigPtr = calloc<Uint8>((1 + ring.length) * 32);

    final rc = _keyService.createRingSignature(
      msgPtr,
      msgHex.length,
      privPtr,
      ringPtr,
      ring.length,
      sigPtr,
    );

    calloc.free(msgPtr);
    calloc.free(privPtr);
    calloc.free(ringPtr);

    if (rc != 1) {
      calloc.free(sigPtr);
      return null;
    }

    final result =
    Uint8List.fromList(sigPtr.asTypedList((1 + ring.length) * 32));

    calloc.free(sigPtr);
    return result;
  }

  bool _verifyRingSignature(String msgHex,
      Uint8List sig,
      List<Uint8List> ring,) {
    final msgPtr = msgHex.toNativeUtf8().cast<Char>();

    const pubLen = 33;
    final ringPtr = calloc<Uint8>(pubLen * ring.length);
    final view = ringPtr.asTypedList(pubLen * ring.length);

    int offset = 0;
    for (final k in ring) {
      view.setAll(offset, k);
      offset += k.length;
    }

    final sigPtr = calloc<Uint8>(sig.length)
      ..asTypedList(sig.length).setAll(0, sig);

    final rc = _keyService.verifyRingSignature(
      msgPtr,
      msgHex.length,
      sigPtr,
      ringPtr,
      ring.length,
    );

    calloc.free(msgPtr);
    calloc.free(sigPtr);
    calloc.free(ringPtr);

    return rc == 1;
  }

  Future<void> exchangeNicknameSchedule({
    required String ownerName,
    required Duration period,
    required Duration slot,
  }) async {
    final stub = _stub;
    if (stub == null) throw StateError('[GRPC CLIENT] exchangeNicknameSchedule not connected');

    // 1. 期間分の将来ニックネームを生成
    final (nicknameList, firstSlotStart) = await KeyManagementService().generateFutureNicknameList(
      firstSlotStartIn: DateTime.now(),
      period: period,
    );

    // 2. 将来ニックネームをサーバに送信．サーバ（相手）の将来ニックネームを受信
    if (kDebugMode) {
      debugPrint('[GRPC CLIENT] exchangeNicknameSchedule: client_name $ownerName, ${nicknameList.length} slots, period.inDays=${period.inDays} slot.inMS=${slot.inMilliseconds}');
    }
    final response = await stub.exchangeNicknameSchedule(
        NicknameScheduleReqResp()
          ..ownerName = ownerName
          ..periodDays = $fixnum.Int64(period.inDays)
          ..slotMs = $fixnum.Int64(slot.inMilliseconds)
          ..firstSlotMs = $fixnum.Int64(firstSlotStart.millisecondsSinceEpoch)
          ..nicknameList.addAll(nicknameList)
    );
    // 私（GRPCクライアント）に表示させたい相手（GRPCサーバ）の名前（ニックネーム）
    final remoteOwnerName = response.ownerName;
    // サーバに届いたニックネーム数の確認
    final ackLength = response.ackLength.toInt();
    if (kDebugMode) {
      debugPrint('[GRPC CLIENT] exchangeNicknameSchedule: ACK server_name $remoteOwnerName, length $ackLength slots');
    }

    // 何日先までのニックネームか（日単位）
    final remotePeriodDays = response.periodDays; // Int64
    final remotePeriodDuration = Duration(days: remotePeriodDays.toInt());
    // 一つのニックネームの有効時間（ミリ秒単位）
    final remoteSlotMs = response.slotMs;         // Int64
    final remoteSlot = Duration(milliseconds: remoteSlotMs.toInt());
    // 最初のニックネームの開始時刻（ミリ秒単位）
    final remoteFirstSlotMs = response.firstSlotMs;   // Int64
    var remoteFirstSlot = DateTime.fromMillisecondsSinceEpoch(remoteFirstSlotMs.toInt());
    // 将来ニックネームのリスト．KeyManagementService.generateFutureNicknameList() の結果
    final remoteNicknameList = response.nicknameList
        .map((bytes) => Uint8List.fromList(bytes))
        .toList(); // PbList<List<int>> を List<Uint8List> に

    // 3. サーバ（相手）の名前を friends テーブルに登録
    final friendsDao = FriendsDao.instance;
    final remoteFriendId = await friendsDao.insertFriend(label: remoteOwnerName, note: null);

    // 4. friend_nicknames テーブルにまとめて保存
    await friendsDao.insertFriendNicknames(
      friendId: remoteFriendId,
      firstSlot: remoteFirstSlot,
      slot: remoteSlot,
      nicknameList: remoteNicknameList,
    );

    // 5. 返送された名前とニックネームに対する ACK
    if (kDebugMode) {
      debugPrint('[GRPC CLIENT] exchangeNicknameSchedule: ACK back to server_name $remoteOwnerName, '
          '${remoteNicknameList.length} slots, period.inDays=${remotePeriodDuration.inDays} slot.inMS=${remoteSlot.inMilliseconds}');
    }
    // final response2 =
    await stub.exchangeNicknameScheduleAck(
        NicknameScheduleAckReq()
          ..ownerName = ownerName
          ..ackLength = $fixnum.Int64(remoteNicknameList.length)
    );
  }

  Future<void> outOfBandAuth(int oobNonce) async {
    final stub = _stub;
    if (stub == null) throw StateError('[GRPC CLIENT] not connected (OutOfBandAuth)');
    await stub.outOfBandAuth( // responseはEmptyなので確認しない
        OutOfBandAuthReq()
          ..oobNonce = $fixnum.Int64(oobNonce));
    // 認証失敗時：GgrpServer.outOfBandAuthから GrpcError.unauthenticated が throw される
  }
}