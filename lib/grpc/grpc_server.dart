// lib/grpc/grpc_server.dart

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:grpc/grpc.dart';
import 'package:fixnum/fixnum.dart' as $fixnum show Int64;

import '../proto/generated/grpc.pbgrpc.dart';
import '../ffi/native_key_service.dart';
import '../key_management.dart';
import '../db/friends_dao.dart';
import 'grpc_common.dart';

/// gRPC サーバ実装（PSI + リング署名）。
class GrpcServiceImpl extends GrpcServiceBase {
  final NativeKeyService _keyService = NativeKeyService();
  final KeyManagementService _kms = KeyManagementService();

  late final Future<void> _ready;

  // OOB (out-of-band) クライアント認証ためのナンス
  late final int _oobNance;
  int get oobNance => _oobNance;
  bool _oobDone = false;
  int _oobFailedCount = 0; // サーバ
  static final _oobFailedMax = 3; // 3回失敗したらサーバ終了

  // PSI 状態
  late Uint8List _mySecret;
  List<Uint8List> _myKeys = [];
  List<Uint8List> _myEncKeys = [];
  List<String> _myGeneratedKeysHex = [];

  List<Uint8List> _serverAbQ = [];
  List<Uint8List> _lastIntersection = [];

  // 直近セッションの集合サイズ（|S_A|, |S_B|）
  int _lastSaKeyCount = 0; // client keys
  int get _sbKeyCount => _myKeys.length; // server keys

  Uint8List? _lastChallengeC;
  Uint8List? _lastChallengeS;
  Future<Uint8List>? _serverSignatureFuture;

  Future<_RingSelection>? _ringSelectionFuture;
  _RingSelection? _ringSelection;

  final _psiEventController = StreamController<PsiResult>.broadcast();
  Stream<PsiResult> get onPsiFinished => _psiEventController.stream;

  final _ringAuthController = StreamController<PsiResult>.broadcast();
  Stream<PsiResult> get onRingAuthenticated => _ringAuthController.stream;

  final void Function({String reason}) onShutdownRequested;

  GrpcServiceImpl({required this.onShutdownRequested}) {
    _ready = _initialize();

    // 鍵更新を検知したら PSI 用の鍵セットを再構築する
    _kms.onKeyUpdated.listen((_) async {
      if (kDebugMode) {
        debugPrint('[GRPC SERVER] keys updated; reload PSI set');
      }
      await _reloadKeys();
    });
  }

  // ----- Init -----

  Future<void> _initialize() async {
    if (kDebugMode) {
      debugPrint('[GRPC SERVER] init');
    }
    _mySecret = _keyService.generateRandomSecret();
    await _reloadKeys();

    _oobNance = _keyService.generateOutOfBandNance(min: 100, max: 999); // QRコード
  }

  Future<void> _reloadKeys() async {
    final generated = await _kms.getAllGeneratedPublicKeys();
    final collected = await _kms.getAllCollectedPublicKeys();

    _myKeys = [...generated, ...collected];
    _myGeneratedKeysHex = generated.map(GrpcCommon.bytesToHex).toList();

    _myEncKeys = _keyService.encryptSet(_myKeys, _mySecret);

    if (kDebugMode) {
      debugPrint(
        '[GRPC SERVER] keys loaded: generated=${generated.length}, collected=${collected.length}',
      );
    }
  }

  Future<void> _ensureReady() async => _ready;

  // ----- PSI: exchangeKeys -----

  @override
  Future<KeyExchangeResp> exchangeKeys(
      ServiceCall call,
      KeyExchangeReq request,
      ) async {
    if (! _oobDone) throw GrpcError.failedPrecondition('確認コード未送信');
    await _ensureReady();

    // クライアント側集合サイズ（|S_A|）
    _lastSaKeyCount = request.encKeys.length;

    final bQ = request.encKeys.map(Uint8List.fromList).toList();
    _serverAbQ = _keyService.encryptSet(bQ, _mySecret);

    return KeyExchangeResp()
      ..serverEncKeys.addAll(_myEncKeys)
      ..clientReencKeys.addAll(_serverAbQ);
  }

  // ----- PSI: finalizePsi -----

  @override
  Future<PsiDone> finalizePsi(
      ServiceCall call,
      ClientFinalReq req,
      ) async {
    if (! _oobDone) throw GrpcError.failedPrecondition('確認コード未送信');
    await _ensureReady();

    final clientAbP = req.clientReencServerKeys.map(Uint8List.fromList).toList();

    final intersection = _computeIntersection(clientAbP);
    _lastIntersection = intersection;

    final commonHex = intersection.map(GrpcCommon.bytesToHex).toList();

    // 共通集合に生成鍵が含まれるかで判定する
    final familiar =
        commonHex.toSet().intersection(_myGeneratedKeysHex.toSet()).isNotEmpty;

    _psiEventController.add(
      PsiResult(
        isFamiliar: familiar,
        saKeyCount: _lastSaKeyCount,
        sbKeyCount: _sbKeyCount,
        commonKeys: commonHex,
        ringSize: 0,
        // サーバ側は UI 通知用のため計測値は保持しない
        dbLoadTimeMs: 0,
        psiTimeMs: 0,
        ringSelectTimeMs: 0,
        ringSigTimeMs: 0,
        totalTimeMs: 0,
      ),
    );

    _lastChallengeC = null;
    _lastChallengeS = null;
    _serverSignatureFuture = null;

    _ringSelection = null;
    _ringSelectionFuture = null;
    if (_lastIntersection.isNotEmpty) {
      _ringSelectionFuture = _computeRingSelectionAsync(_lastIntersection);
    }

    return PsiDone();
  }

  // ----- Ring signature: exchangeChallenges -----

  @override
  Future<ServerChallenge> exchangeChallenges(
      ServiceCall call,
      ClientChallenge req,
      ) async {
    if (! _oobDone) throw GrpcError.failedPrecondition('確認コード未送信');
    await _ensureReady();
    if (_lastIntersection.isEmpty) {
      throw GrpcError.failedPrecondition('PSI intersection empty');
    }

    _lastChallengeC = Uint8List.fromList(req.challengeC);
    _lastChallengeS = _keyService.generateRandomSecret();

    _ringSelectionFuture ??= _computeRingSelectionAsync(_lastIntersection);

    return ServerChallenge()..challengeS = _lastChallengeS!;
  }

  // ----- Ring selection (server) -----

  Future<_RingSelection> _computeRingSelectionAsync(
      List<Uint8List> intersection,
      ) async {
    final signer = await _kms.selectSignerKeyFromIntersection(intersection);
    if (signer == null) {
      throw GrpcError.failedPrecondition('No signer key');
    }

    final signerTime = await _kms.getTimestampForKey(signer.publicKey);
    if (signerTime == null) {
      throw GrpcError.failedPrecondition('No signer timestamp');
    }

    // 同一時刻スロット内の鍵に限定してリングを構成する
    final ring = await _kms.filterKeysBySameSlot(intersection, signerTime);
    if (ring.length < 2) {
      throw GrpcError.failedPrecondition('Ring too small');
    }

    ring.sort(GrpcCommon.comparePubKey);

    return _RingSelection(
      signer: signer,
      ring: ring,
    );
  }

  // ----- Ring signature (server) -----

  Future<Uint8List> _computeServerSignatureAsync() async {
    if (kDebugMode) {
      debugPrint('[GRPC SERVER] create ring signature');
    }

    final sel = _ringSelection ?? await _ringSelectionFuture!;
    _ringSelection = sel;

    final ring = sel.ring;
    final signer = sel.signer;

    final msgHex = GrpcCommon.bytesToHex(_lastChallengeC!);

    const pubLen = 33;
    final msgPtr = msgHex.toNativeUtf8().cast<Char>();
    final ringPtr = calloc<Uint8>(pubLen * ring.length);
    final ringView = ringPtr.asTypedList(pubLen * ring.length);

    int offset = 0;
    for (final k in ring) {
      ringView.setAll(offset, k);
      offset += k.length;
    }

    final privPtr = calloc<Uint8>(signer.privateKey.length)
      ..asTypedList(signer.privateKey.length).setAll(0, signer.privateKey);

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
      throw GrpcError.internal('Server signature failed');
    }

    final sig = Uint8List.fromList(sigPtr.asTypedList((1 + ring.length) * 32));
    calloc.free(sigPtr);

    return sig;
  }

  // ----- Ring signature: exchangeRingSignatures -----

  @override
  Future<RingSignatureResp> exchangeRingSignatures(
      ServiceCall call,
      RingSignatureReq request,
      ) async {
    if (! _oobDone) throw GrpcError.failedPrecondition('確認コード未送信');
    await _ensureReady();

    final sigFromClient = Uint8List.fromList(request.signatureForServer);

    _serverSignatureFuture ??= _computeServerSignatureAsync();
    final sigForClient = await _serverSignatureFuture!;

    unawaited(_verifyClientSignatureLater(sigFromClient));

    // サーバ終了
    Future.delayed(const Duration(milliseconds: 100), () {
      onShutdownRequested(reason: '正常終了');
    });

    return RingSignatureResp()..signatureForClient = sigForClient;
  }

  // ----- Ring signature (client verify) -----

  Future<void> _verifyClientSignatureLater(Uint8List clientSig) async {
    final sel = _ringSelection ?? await _ringSelectionFuture!;
    _ringSelection = sel;

    final ring = sel.ring;

    final msgHex = GrpcCommon.bytesToHex(_lastChallengeS!);

    const pubLen = 33;
    final ringPtr = calloc<Uint8>(pubLen * ring.length);
    final ringView = ringPtr.asTypedList(pubLen * ring.length);

    int offset = 0;
    for (final k in ring) {
      ringView.setAll(offset, k);
      offset += k.length;
    }

    final sigPtr = calloc<Uint8>(clientSig.length)
      ..asTypedList(clientSig.length).setAll(0, clientSig);

    final msgPtr = msgHex.toNativeUtf8().cast<Char>();

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

    if (rc == 1) {
      _ringAuthController.add(
        PsiResult(
          isFamiliar: true,
          saKeyCount: _lastSaKeyCount,
          sbKeyCount: _sbKeyCount,
          commonKeys: _lastIntersection.map(GrpcCommon.bytesToHex).toList(),
          ringSize: ring.length,
          dbLoadTimeMs: 0,
          psiTimeMs: 0,
          ringSelectTimeMs: 0,
          ringSigTimeMs: 0,
          totalTimeMs: 0,
        ),
      );
    }

    _lastChallengeC = null;
    _lastChallengeS = null;
    _serverSignatureFuture = null;
    _ringSelectionFuture = null;
    _ringSelection = null;
  }

  // ----- Intersection -----

  List<Uint8List> _computeIntersection(List<Uint8List> clientAbP) {
    final abQSet = _serverAbQ.map(GrpcCommon.bytesToHex).toSet();
    final result = <Uint8List>[];

    final n =
    clientAbP.length < _myKeys.length ? clientAbP.length : _myKeys.length;

    for (int i = 0; i < n; i++) {
      if (abQSet.contains(GrpcCommon.bytesToHex(clientAbP[i]))) {
        result.add(_myKeys[i]);
      }
    }
    return result;
  }

  @override
  Future<NicknameScheduleReqResp> exchangeNicknameSchedule(
      ServiceCall call, NicknameScheduleReqResp request) async {
    if (! _oobDone) throw GrpcError.failedPrecondition('確認コード未送信');

    // 相手（GRPCサーバ）に表示させたい自分（GRPCクライアント）の名前（ニックネーム）
    final ownerName = request.ownerName;   // String
    // 何日先までのニックネームか（日単位）
    final periodDays = request.periodDays; // Int64
    final period = Duration(days: periodDays.toInt());
    // 一つのニックネームの有効時間（ミリ秒単位）
    final slotMs = request.slotMs;         // Int64
    final slot = Duration(milliseconds: slotMs.toInt());
    // 最初のニックネームの開始時刻（ミリ秒単位）
    final firstSlotMs = request.firstSlotMs;   // Int64
    var firstSlot = DateTime.fromMillisecondsSinceEpoch(firstSlotMs.toInt());
    // 将来ニックネームのリスト．KeyManagementService.generateFutureNicknameList() の結果
    final nicknameList = request.nicknameList
        .map((bytes) => Uint8List.fromList(bytes))
        .toList(); // PbList<List<int>> を List<Uint8List> に

    if (kDebugMode) {
      debugPrint('[GRPC SERVER] exchangeNicknameSchedule: client_name $ownerName, '
          '${nicknameList.length} slots, period.inDays=${period.inDays} slot.inMS=${slot.inMilliseconds}');
    }

    // 1. friends テーブルに登録
    final friendsDao = FriendsDao.instance;
    final friendId = await friendsDao.insertFriend(label: ownerName, note: null);

    // 2. friend_nicknames テーブルにまとめて保存
    await friendsDao.insertFriendNicknames(
      friendId: friendId,
      firstSlot: firstSlot,
      slot: slot,
      nicknameList: nicknameList,
    );

    // ToDo: クラアント側と同じように．ユーザに通知する．
    // クライアント側は SnackBar(content: Text('共有しました：${_selectedPeriod.label}（${period.inDays}日）')),
    // SnackBarにこだわる必要はないと思う．

    // 3. 返送する将来ニックネームを計算する
    final (localNicknameList, _) = await _kms.generateFutureNicknameList(
        firstSlotStartIn: firstSlot, period: period);

    return NicknameScheduleReqResp()
        ..ownerName = '仮の名前 GPRC' // ToDo: 自分の名前を取得する
        ..periodDays = periodDays
        ..slotMs = slotMs
        ..firstSlotMs = firstSlotMs
        ..nicknameList.addAll(localNicknameList)
        ..ackLength = $fixnum.Int64(nicknameList.length);
    // throw UnimplementedError();
  }

  @override
  Future<NicknameScheduleAckResp> exchangeNicknameScheduleAck(
      ServiceCall call, NicknameScheduleAckReq request) async {
    if (! _oobDone) throw GrpcError.failedPrecondition('確認コード未送信');

    // 相手（GRPCサーバ）に表示させたい自分（GRPCクライアント）の名前（ニックネーム）
    final ownerName = request.ownerName;   // String
    // クライアントに届いたニックネーム数の確認
    final ackLength = request.ackLength.toInt();
    if (kDebugMode) {
      debugPrint('[GRPC SERVER] exchangeNicknameSchedule: ACK client_name $ownerName, length $ackLength slots');
    }

    return NicknameScheduleAckResp();
    //throw UnimplementedError();
  }

  @override
  Future<Empty> outOfBandAuth(ServiceCall call, OutOfBandAuthReq request) async {
    final receivedOobNance = request.oobNance.toInt();
    if (_oobNance != receivedOobNance) {
      // 確認コードを _oobFailedMax 回間違ったらサーバを終了
      _oobFailedCount += 1;
      if (_oobFailedCount >= _oobFailedMax) {
        Future.delayed(const Duration(milliseconds: 100), () {
          onShutdownRequested(reason: '$_oobFailedCount failed attempts');
        });
        if (kDebugMode) {
          debugPrint('[GRPC SERVER] Shutdown server after $_oobFailedCount failed attempts');
        }
      }
      throw GrpcError.unauthenticated('正しい確認コードを入力してください');
    }
    _oobDone = true;
    return Empty();
  }
}

class _RingSelection {
  final KeyPair signer;
  final List<Uint8List> ring;

  const _RingSelection({
    required this.signer,
    required this.ring,
  });
}

/// gRPC サーバ管理。
class GrpcServer extends ChangeNotifier {
  Server? _server;
  Server? get server => _server;
  int? _port;
  String? _reason;
  String? get reason => _reason;

  late GrpcServiceImpl service;

  final GrpcCommon _grpcCommon = GrpcCommon();

  bool get isRunning => _server != null;
  int get oobNance => service.oobNance;

  Future<int> start({int port = 50051}) async {
    if (_server != null) return _port!;

    service = GrpcServiceImpl(
      onShutdownRequested: ({String? reason}) async {
        _reason = reason;
        await stop();
      }
    );
    await service._ready;

    final s = Server.create(
      services: [service],
      codecRegistry: _grpcCommon.codecRegistry,
    );

    await _grpcCommon.isInitialized;
    await s.serve(
      address: InternetAddress.anyIPv4,
      port: port,
      security: _grpcCommon.serverTlsCredentials,
    );

    _server = s;
    _port = s.port;

    if (kDebugMode) {
      debugPrint('[SERVER] started: $_port');
    }
    return _port!; // notifyListeners()にはしてない
  }

  Future<void> stop() async {
    final s = _server;
    _server = null; // shutdown前にnullにする
    _port = null;
    if (s != null) await s.shutdown();
    notifyListeners();
  }
}
