import 'dart:convert';
import '../key_management_service.dart'; // SlotNickname を使う
import 'package:grpc/grpc.dart';

import '../proto/generated/psi.pbgrpc.dart';

class PsiGrpcClient {
  ClientChannel? _channel;
  PsiServiceClient? _stub;

  bool get isConnected => _stub != null;

  Future<void> connect(String host, int port) async {
    print('[CLIENT] trying to connect to $host:$port');

    try {
      await disconnect();

      _channel = ClientChannel(
        host,
        port: port,
        options: ChannelOptions(
          credentials: ChannelCredentials.insecure(),
          idleTimeout: const Duration(seconds: 30),

          // ★ GzipCodec を登録（サーバーから gzip 受信できるようにする）
          codecRegistry: CodecRegistry(
            codecs: [
              GzipCodec(),
              IdentityCodec(),
            ],
          ),
        ),
      );

      _stub = PsiServiceClient(_channel!);
      print('[CLIENT] connect() success');
    } catch (e) {
      print('[CLIENT] connect() ERROR = $e');
      rethrow;
    }
  }

  Future<String> ping(String msg) async {
    final stub = _stub;
    if (stub == null) throw StateError('Client not connected');

    print('[CLIENT] sending ping payload: $msg');

    try {
      final resp = await stub.ping(
        PingReq()..msg = msg,

        // ★ 毎回 gzip で送信する
        options: CallOptions(
          compression: const GzipCodec(),
        ),
      );

      print('[CLIENT] got ping response: ${resp.msg}');
      return resp.msg;
    } catch (e) {
      print('[CLIENT] ping() ERROR = $e');
      rethrow;
    }
  }

  Future<List<String>> exchangeKeys(List<String> myKeysHex) async {
    if (_stub == null) throw StateError('Client not connected');

    final payload = jsonEncode({
      'type': 'key_sync',
      'keys': myKeysHex,
    });

    print('[CLIENT] exchangeKeys() sending ${myKeysHex.length} keys');

    try {
      final resp = await ping(payload);

      final json = jsonDecode(resp);
      if (json['type'] == 'key_sync_resp') {
        final list = (json['keys'] as List?) ?? const [];
        print('[CLIENT] received ${list.length} keys from server');
        return List<String>.from(list);
      }

      print('[CLIENT] unexpected response: $resp');
      return [resp];
    } catch (e) {
      print('[CLIENT] exchangeKeys ERROR = $e');
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

  /// 将来ニックネームスケジュールをサーバに送信する
  ///
  /// [ownerName]  : 相手に表示させたい自分の名前（ニックネーム）
  /// [period]     : どこまで先のニックネームか
  /// [slot]       : 1スロットの長さ（10分）
  /// [schedule]   : KeyManagementService.generateFutureNicknameList() の結果
  Future<void> sendNicknameSchedule({
    required String ownerName,
    required Duration period,
    required Duration slot,
    required List<SlotNickname> schedule,
  }) async {
    if (_stub == null) {
      throw StateError('Client not connected');
    }
    if (schedule.isEmpty) {
      return;
    }

    final slotMs = slot.inMilliseconds;
    final startMs = schedule.first.slotStart.millisecondsSinceEpoch;

    final keysHex = schedule
        .map((s) => _bytesToHex(s.pubkey33))
        .toList(growable: false);

    final payload = jsonEncode({
      'type': 'nickname_schedule',
      'owner_name': ownerName,
      'period': period.inDays == 1
          ? '1d'
          : (period.inDays == 7 ? '7d' : '${period.inDays}d'),
      'slot_ms': slotMs,
      'start_ms': startMs,
      'keys': keysHex,
    });

    print(
        '[CLIENT] sendNicknameSchedule(): ${keysHex.length} slots, period=$period slot=$slot');

    final resp = await ping(payload);

    try {
      final json = jsonDecode(resp);
      if (json is Map && json['type'] == 'nickname_schedule_ack') {
        print(
            '[CLIENT] nickname_schedule ACK: friend_id=${json['friend_id']}, received=${json['received']}');
      } else {
        print('[CLIENT] nickname_schedule unexpected resp: $resp');
      }
    } catch (_) {
      print('[CLIENT] nickname_schedule resp not JSON: $resp');
    }
  }

  String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

}
