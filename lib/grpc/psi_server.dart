import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:grpc/grpc.dart';

import '../proto/generated/psi.pbgrpc.dart';
import '../key_management_service.dart';
import '../db/friends_dao.dart';

class PsiServiceImpl extends PsiServiceBase {
  final KeyManagementService _keyService = KeyManagementService();

  final FriendsDao _friendsDao = FriendsDao.instance;

  String _bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  // 16進文字列を Uint8List に戻すヘルパー
  Uint8List _hexToBytes(String hex) {
    final cleaned = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    final length = cleaned.length;
    final result = Uint8List(length ~/ 2);
    for (int i = 0; i < length; i += 2) {
      final byteStr = cleaned.substring(i, i + 2);
      result[i ~/ 2] = int.parse(byteStr, radix: 16);
    }
    return result;
  }

  @override
  Future<PingResp> ping(ServiceCall call, PingReq request) async {
    print('[SERVER] ping() called');   // ★必須ログ
    final msg = request.msg;
    print('[gRPC Server] Ping received: $msg');

    try {
      final Map<String, dynamic> reqJson = jsonDecode(msg);

      if (reqJson['type'] == 'key_sync') {
        final List<dynamic> clientKeys = (reqJson['keys'] as List?) ?? const [];
        print('[gRPC Server] 🔑 Received ${clientKeys.length} keys from client');

        for (var i = 0; i < clientKeys.length; i++) {
          print('[gRPC Server]   client key[$i]: ${clientKeys[i]}');
        }

        // サーバ側の鍵を取得
        final generated = await _keyService.getAllGeneratedPublicKeys();
        final collected = await _keyService.getAllCollectedPublicKeys();
        final all = <Uint8List>[...generated, ...collected];

        final serverKeys = all.map(_bytesToHex).toList();
        print('[gRPC Server] 🔑 Sending ${serverKeys.length} keys back to client');

        for (var i = 0; i < serverKeys.length; i++) {
          print('[gRPC Server]   server key[$i]: ${serverKeys[i]}');
        }

        final respJson = jsonEncode({
          'type': 'key_sync_resp',
          'keys': serverKeys,
        });

        return PingResp()..msg = respJson;
      }
      // ===== ★ ここから nickname_schedule 処理を追加 =====
      if (reqJson['type'] == 'nickname_schedule') {
        final ownerName = (reqJson['owner_name'] as String?) ?? 'Unknown';
        final slotMs = (reqJson['slot_ms'] as int?) ?? 0;
        final startMs = (reqJson['start_ms'] as int?) ?? 0;
        final keysJson = (reqJson['keys'] as List?) ?? const [];

        if (slotMs <= 0 || startMs <= 0 || keysJson.isEmpty) {
          print(
              '[gRPC Server] nickname_schedule invalid params: slotMs=$slotMs startMs=$startMs keys=${keysJson.length}');
          return PingResp()..msg = 'nickname_schedule_invalid';
        }

        print(
            '[gRPC Server] 🔔 nickname_schedule from "$ownerName": ${keysJson.length} slots');

        // 1. friends テーブルに登録
        final friendId =
        await _friendsDao.insertFriend(label: ownerName, note: null);

        // 2. JSON から SlotNickname のリストを組み立てる
        final slotDuration = Duration(milliseconds: slotMs);
        final List<SlotNickname> schedule = [];

        for (int i = 0; i < keysJson.length; i++) {
          final hex = keysJson[i] as String;
          final pkBytes = _hexToBytes(hex);

          final slotStartMs = startMs + i * slotMs;
          final slotStart =
          DateTime.fromMillisecondsSinceEpoch(slotStartMs);

          schedule.add(SlotNickname(
            slotStart: slotStart,
            slotDuration: slotDuration,
            pubkey33: pkBytes,
          ));
        }

        // 3. friend_nicknames テーブルにまとめて保存
        await _friendsDao.insertFriendNicknames(
          friendId: friendId,
          schedule: schedule,
        );

        final respJson = jsonEncode({
          'type': 'nickname_schedule_ack',
          'friend_id': friendId,
          'received': keysJson.length,
        });

        print(
            '[gRPC Server] nickname_schedule stored: friend_id=$friendId, count=${keysJson.length}');

        return PingResp()..msg = respJson;
      }
    } catch (e) {
      print('[gRPC Server] JSON decode error: $e');
    }

    return PingResp()..msg = 'pong: $msg';
  }
}

class PsiGrpcServer {
  Server? _server;
  int? _port;

  bool get isRunning => _server != null;
  int? get port => _port;

  Future<int> start({int port = 50051}) async {
    if (_server != null) return _port!;

    final server = Server.create(
      services: [PsiServiceImpl()],
      interceptors: const <Interceptor>[],
      codecRegistry: CodecRegistry(
        codecs: [
          GzipCodec(),
          IdentityCodec(),
        ],
      ),
    );


    await server.serve(
      address: InternetAddress.anyIPv4,
      port: port,
    );

    _server = server;
    _port = server.port;

    print('[gRPC Server] started on 0.0.0.0:${_port}');
    return _port!;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _port = null;
    if (s != null) {
      await s.shutdown();
      print('[gRPC Server] stopped');
    }
  }
}
