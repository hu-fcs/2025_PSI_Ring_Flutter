// lib/grpc/grpc_client.dart

import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:grpc/grpc.dart';

import '../proto/generated/grpc.pbgrpc.dart';
import '../ffi/native_key_service.dart';
import '../key_management_service.dart';
import '../db/database_helper.dart';

/// ===============================================================
/// PSI の結果（共通集合 + 顔見知り判定）
/// ===============================================================
class PsiResult {
  final List<String> commonKeys;
  final bool isFamiliar;

  PsiResult({
    required this.commonKeys,
    required this.isFamiliar,
  });
}

/// ===============================================================
///                    ECC-PSI クライアント
/// ===============================================================
class GrpcClient {
  ClientChannel? _channel;
  GrpcServiceClient? _stub;

  final NativeKeyService _keyService = NativeKeyService();
  final KeyManagementService _kms = KeyManagementService();

  late final Future<void> _ready;
  bool get isConnected => _stub != null;

  GrpcClient() {
    _ready = _initialize();
  }

  Future<void> _initialize() async {
    print('[CLIENT] === クライアント初期化開始 ===');
    print('[CLIENT] === クライアント初期化完了 ===');
  }

  Future<void> _ensureReady() async => await _ready;

  // ===============================================================
  // gRPC 接続
  // ===============================================================
  Future<void> connect(String host, int port) async {
    await _ensureReady();

    print('\n[CLIENT] === gRPC 接続開始 ===');
    print('[CLIENT] 接続先: $host:$port');

    try {
      await disconnect();

      _channel = ClientChannel(
        host,
        port: port,
        options: ChannelOptions(
          credentials: ChannelCredentials.insecure(),
          idleTimeout: const Duration(seconds: 30),
        ),
      );

      _stub = GrpcServiceClient(_channel!);
      print('[CLIENT] ✅ サーバへの接続成功');
    } catch (e) {
      print('[CLIENT] ❌ 接続失敗: $e');
      rethrow;
    }
  }

  Future<void> disconnect() async {
    try {
      await _channel?.shutdown();
    } catch (_) {}
    _channel = null;
    _stub = null;
  }

  // ===============================================================
  //               PSI + リング署名 フロー（全体）
  // ===============================================================
  Future<PsiResult> executePsi() async {
    await _ensureReady();
    final stub = _stub;
    if (stub == null) throw StateError('[CLIENT] ❌ サーバ未接続');

    print('\n[CLIENT] === PSI フロー開始 ===');

    // ------------------------------------------------------------
    // Phase1: 鍵読み込み
    // ------------------------------------------------------------
    print('[CLIENT] === Phase1: 鍵読み込み 開始 ===');

    final generated = await _kms.getAllGeneratedPublicKeys();
    final collected = await _kms.getAllCollectedPublicKeys();
    final myKeys = [...generated, ...collected];

    print('[CLIENT] 🔑 BLE鍵読み込み: generated=${generated.length}, collected=${collected.length}, total=${myKeys.length}');

    if (myKeys.isEmpty) {
      print('[CLIENT] ⚠ BLE鍵なし → PSI中止');
      return PsiResult(commonKeys: [], isFamiliar: false);
    }

    print('[CLIENT] === Phase1: 鍵読み込み 終了 ===');

    // ------------------------------------------------------------
    // Phase2: bQ 計算
    // ------------------------------------------------------------
    print('\n[CLIENT] === Phase2: bQ 計算 開始 ===');

    print('[CLIENT] 🔒 秘密値 b を生成します...');
    final mySecret = _keyService.generateRandomSecret();

    print('[CLIENT] 🔒 bQ を計算中...');
    final myEncKeys = _keyService.encryptSet(myKeys, mySecret);

    print('[CLIENT] 🔒 bQ 計算完了 (${myEncKeys.length} 件)');

    print('[CLIENT] === Phase2: bQ 計算 終了 ===');

    // ------------------------------------------------------------
    // Phase3: ExchangeKeys
    // ------------------------------------------------------------
    print('\n[CLIENT] === Phase3: ExchangeKeys 開始 ===');

    print('[CLIENT] 📤 bQ を送信します...');
    final resp = await stub.exchangeKeys(
      KeyExchangeReq()..encKeys.addAll(myEncKeys),
      options: CallOptions(compression: GzipCodec()),
    );

    final serverEncKeys =
    resp.serverEncKeys.map((e) => Uint8List.fromList(e)).toList();
    final abQ =
    resp.clientReencKeys.map((e) => Uint8List.fromList(e)).toList();

    print('[CLIENT] 📥 受信: aP=${serverEncKeys.length}, abQ=${abQ.length}');
    print('[CLIENT] === Phase3: ExchangeKeys 終了 ===');

    // ------------------------------------------------------------
    // Phase4: abP 計算
    // ------------------------------------------------------------
    print('\n[CLIENT] === Phase4: abP 計算 開始 ===');

    print('[CLIENT] 🔒 aP を受信 → abP を計算中...');
    final abP = _keyService.encryptSet(serverEncKeys, mySecret);

    print('[CLIENT] 🔒 abP 計算完了 (${abP.length} 件)');
    print('[CLIENT] === Phase4: abP 計算 終了 ===');

    // ------------------------------------------------------------
    // Phase5: PSI 共通集合
    // ------------------------------------------------------------
    print('\n[CLIENT] === Phase5: PSI 共通集合抽出 開始 ===');

    print('[CLIENT] 🔍 共通集合の抽出を開始します...');
    final clientCommon = _keyService.intersect(myKeys, abQ, abP);

    print('[CLIENT] 🎯 PSI 共通集合 = ${clientCommon.length} 件');
    for (int i = 0; i < clientCommon.length; i++) {
      print('[CLIENT]   共通[$i] = ${_hex(clientCommon[i])}');
    }

    print('[CLIENT] 📤 abP を送信（FinalizePsi）...');
    await stub.finalizePsi(
      ClientFinalReq()..clientReencServerKeys.addAll(abP),
      options: CallOptions(compression: GzipCodec()),
    );

    print('[CLIENT] 🔚 PSI(2段階) 完了');
    print('[CLIENT] === Phase5: PSI 共通集合抽出 終了 ===');

    // ------------------------------------------------------------
    // Phase6: PSI 顔見知り判定
    // ------------------------------------------------------------
    print('\n[CLIENT] === Phase6: 顔見知り判定 開始 ===');

    final commonHex = clientCommon.map(_hex).toList();
    final myGenHex = generated.map(_hex).toSet();

    final familiarByPsi =
        commonHex.toSet().intersection(myGenHex).isNotEmpty;

    print('[CLIENT] 👤 PSIベースの顔見知り判定 = $familiarByPsi');

    print('[CLIENT] === Phase6: 顔見知り判定 終了 ===');

    // ------------------------------------------------------------
    // Phase7: リング署名フェーズ
    // ------------------------------------------------------------
    bool ringOk = false;

    if (familiarByPsi && clientCommon.length >= 2) {
      print('\n[CLIENT] === Phase7: リング署名フェーズ 開始 ===');

      ringOk = await _runRingSignaturePhase(
        stub: stub,
        intersection: clientCommon,
      );

      print('[CLIENT] === Phase7: リング署名フェーズ 終了 ===');
    } else {
      print('\n[CLIENT] ⚠ PSI条件不足のためリング署名フェーズは実施しません');
    }

    // ------------------------------------------------------------
    // 最終結果
    // ------------------------------------------------------------
    final result = PsiResult(
      commonKeys: commonHex,
      isFamiliar: familiarByPsi && ringOk,
    );

    print('\n[CLIENT] === PSI + リング署名フロー終了 ===');
    print('[CLIENT] ⭐ 最終判定 isFamiliar=${result.isFamiliar}');
    print('-----------------------------------------------');

    return result;
  }

  // ===============================================================
  // 共通集合から署名者となる自分の鍵を選択
  //   - intersection に含まれる公開鍵のうち
  //   - generated_keys テーブルに存在するものだけを候補とし
  //   - expire_time が最大のものを 1 件選ぶ
  // ===============================================================
  Future<KeyPair?> _selectSignerKeyFromIntersection(
      List<Uint8List> intersection) async {
    if (intersection.isEmpty) {
      print('[CLIENT] 🔑 共通集合が空のため署名者候補なし');
      return null;
    }

    final db = await DatabaseHelper.getDatabase();

    int? bestExpire;
    Uint8List? bestSec;
    Uint8List? bestPub;

    for (final pub in intersection) {
      // generated_keys に自分が生成した鍵があるか確認
      final rows = await db.query(
        'generated_keys',
        columns: ['seckey_ecd', 'pubkey_ecd', 'expire_time'],
        where: 'pubkey_ecd = ?',
        whereArgs: [pub],
        limit: 1,
      );

      if (rows.isEmpty) continue;

      final row = rows.first;
      final sec = row['seckey_ecd'] as Uint8List?;
      final pubKey = row['pubkey_ecd'] as Uint8List?;
      final expire = row['expire_time'] as int? ?? 0;

      if (sec == null || pubKey == null) continue;

      if (bestExpire == null || expire > bestExpire) {
        bestExpire = expire;
        bestSec = sec;
        bestPub = pubKey;
      }
    }

    if (bestSec == null || bestPub == null) {
      print('[CLIENT] 🔑 共通集合内に自分の generated_keys が見つかりませんでした');
      return null;
    }

    print('[CLIENT] 🔑 共通集合から署名者鍵を選択 (expire_time=$bestExpire)');
    return KeyPair(bestSec, bestPub);
  }

  // ===============================================================
  //               リング署名フェーズ（ログ統一版）
  // ===============================================================
  Future<bool> _runRingSignaturePhase({
    required GrpcServiceClient stub,
    required List<Uint8List> intersection,
  }) async {
    print('[CLIENT] 🔗 リングメンバーをソートします...');
    final ring = [...intersection]..sort(_compare);

    print('[CLIENT] 🔗 リングサイズ = ${ring.length}（ソート済）');

    if (ring.length < 2) {
      print('[CLIENT] ❌ リングサイズ不足 → 中止');
      return false;
    }

    // 共通集合に含まれる自分の鍵の中から「最も新しいもの」を署名者として選ぶ
    final keyPair = await _selectSignerKeyFromIntersection(intersection);
    if (keyPair == null) {
      print('[CLIENT] ❌ 自身の秘密鍵が見つかりません');
      return false;
    }

    // ------------------------------------------------------------
    // Challenge 交換
    // ------------------------------------------------------------
    final challengeC = _keyService.generateRandomSecret();
    print('[CLIENT] 📤 challenge_C 送信: ${_hex(challengeC)}');

    final resp = await stub.exchangeChallenges(
      ClientChallenge()..challengeC = challengeC,
    );

    final challengeS = Uint8List.fromList(resp.challengeS);
    print('[CLIENT] 📥 challenge_S 受信: ${_hex(challengeS)}');

    final msgForServer = _hex(challengeS);
    final msgForClient = _hex(challengeC);

    // ------------------------------------------------------------
    // サーバへ送る署名生成
    // ------------------------------------------------------------
    print('[CLIENT] ✍️ サーバ向け署名生成を開始します...');
    final sigForServer =
    _createRingSignature(msgForServer, keyPair.privateKey, ring);

    if (sigForServer == null) {
      print('[CLIENT] ❌ 署名生成に失敗しました');
      return false;
    }
    print('[CLIENT] ✍️ サーバ向け署名生成完了 len=${sigForServer.length}');

    // ------------------------------------------------------------
    // サーバ署名受信
    // ------------------------------------------------------------
    print('[CLIENT] 📤 署名送信...');
    final sigResp = await stub.exchangeRingSignatures(
      RingSignatureReq()..signatureForServer = sigForServer,
    );

    final sigFromServer = Uint8List.fromList(sigResp.signatureForClient);
    print('[CLIENT] 📥 サーバ署名受信 len=${sigFromServer.length}');

    // ------------------------------------------------------------
    // 署名検証
    // ------------------------------------------------------------
    print('[CLIENT] 🔍 サーバ署名検証開始...');
    final ok = _verifyRingSignature(msgForClient, sigFromServer, ring);

    if (ok) {
      print('[CLIENT] 🎉 サーバ署名 → 正当と確認');
    } else {
      print('[CLIENT] ❌ サーバ署名 → 不正');
    }

    return ok;
  }

  // ===============================================================
  // 署名生成
  // ===============================================================
  Uint8List? _createRingSignature(
      String msgHex, Uint8List privKey, List<Uint8List> ring) {
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

  // ===============================================================
  // 署名検証
  // ===============================================================
  bool _verifyRingSignature(
      String msgHex, Uint8List sig, List<Uint8List> ring) {
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

  // ===============================================================
  // Util
  // ===============================================================
  String _hex(Uint8List b) =>
      b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

  int _compare(Uint8List a, Uint8List b) {
    for (int i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }
}
