import 'dart:async';

import 'package:flutter/foundation.dart';
import "package:bluetooth_low_energy/bluetooth_low_energy.dart";
import 'ffi/native_key_service.dart' hide privateKeyLen;
import 'key_management.dart';
import 'db/friends_dao.dart';

/// friends テーブル1行分
class Friend {
  final int id;
  final String label;
  final String? note;
  final DateTime createdAt;
  Peripheral? _peripheral; // 相互認証した相手のBLEペリフェラル
  Central? _central; // 相互認証した相手のBLEセントラル

  /// データベースから読み込むときのコンストラクタ
  Friend({
    required this.id,
    required this.label,
    this.note,
    required this.createdAt,
  });

  set peripheral(Peripheral? value) {
    _peripheral = value;
    FriendList().notifyListenersTwice(); // UIに通知
  }
  Peripheral? get peripheral => _peripheral;

  set central(Central? value) {
    _central = value;
    FriendList().notifyListenersTwice(); // UIに通知
  }
  Central? get central => _central;

  /// データベースから読み込むときの関数
  factory Friend.fromMap(Map<String, Object?> map) {
    return Friend(
      id: map['id'] as int,
      label: map['label'] as String,
      note: map['note'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['created_at'] as int) * 1000,
      ),
    );
  }
}

class FriendList extends ChangeNotifier {
  static final FriendList _instance = FriendList._internal();
  factory FriendList() => _instance;
  FriendList._internal();

  /// _idFromNicknameStr の有効期限
  DateTime? cachedUntil;
  /// ニックネームを文字列にしたものから友達インスタンス
  Map<String, Friend> _friendfromNicknameStr = {};
  /// 友達のIDから友達のラベル（名前）
  Map<int, String> _friendLabelFromId = {};
  String labelOf(int id) => _friendLabelFromId[id] ?? 'Unknown';

  /// 友達リストのキャッシュ
  List<Friend> _friendList = [];
  List<Friend> get friendList => _friendList;
  Map<int, Friend> _friendFromId = {};

  Future<Friend?> getFriendByNickname(Uint8List nickname) async {
    await updateCacheOfFriends();
    final nicknameStr = nickname.hexStr();
    final friend = _friendfromNicknameStr[nicknameStr];
    return friend; // 見つからなければnull
  }

  /// DBから読み出したキャッシュの有効期限を確認して，必要ならDBから再取得する．
  Future<void> updateCacheOfFriends({bool force = false}) async {
    final now = DateTime.now();
    if (cachedUntil != null && cachedUntil!.isAfter(now) && ! force)
      return; // 有効なキャッシュ

    // DBから友達リストを取得してキャッシュする
    _friendList = await FriendsDao.instance.getFriends();
    _friendFromId.clear();
    for (final friend in _friendList) {
      _friendFromId[friend.id] = friend;
    }

    // 少しマージンをとって10分前から，今日の24時までのニックネームをDBから取得する．
    final from = now.subtract(const Duration(minutes: 10));
    final to = DateTime(now.year, now.month, now.day + 1, 0, 0, 0);
    // DBのfriend_nicknamesから読み込み
    List<FriendNicknameEntry> friends = await FriendsDao.instance.findFriendsDuringPeriod(from, to);

    _friendfromNicknameStr.clear();
    for (final friendNicknameEntry in friends) {
      _friendfromNicknameStr[friendNicknameEntry.pubkeyEcd.hexStr()] = _friendFromId[friendNicknameEntry.id]!;
    }
    cachedUntil = to;
    notifyListeners();
  }

  /// スロット時間経過後にnotifyListeners()をもう一度呼ぶためのタイマー
  Timer? _notifyTimer;
  /// notifyListeners()を呼び出し時とスロット時間経過後の二回呼び出す
  void notifyListenersTwice() {
    notifyListeners();
    _notifyTimer?.cancel();
    _notifyTimer = Timer(KeyManagementService().slot * 1.1, () {
      notifyListeners();
      _notifyTimer = null;
    });
  }
}

class DummyFriend {
  DummyFriend({
    required this.name,
    required this.intMasterKey,
  });

  final String name;
  final int intMasterKey;
  final _nicknameOfTheDay = Set<Uint8List>();
  DateTime? _today;

  /// 今日のニックネームを生成して，containsが呼ばれたときに探すだけにする．
  void fillNicknameOfTheDay() {
    // 雑だが，曜日が一緒なら生成済みとみなす．年月日を比べるのが正しい
    final now = DateTime.now();
    if (_today != null && _today!.weekday == now.weekday) {
      return;
    }
    _today = now;

    // マスターキーを整数（8バイト）から生成．PSIアプリとは違う作り方．
    ByteData bd = ByteData(privateKeyLen);
    bd.setInt64(0, intMasterKey, Endian.big);
    Uint8List masterKey = bd.buffer.asUint8List();

    // 今日のニックネームを計算．
    // ニックネームの生成は KeyManagementService._updateCurrentKeyPair と同様
    // 計算時間は 2000ニックネームで 0.1秒程度 (SONY J9110 Androind 11)
    final _nativeKeyService = NativeKeyService();
    _nicknameOfTheDay.clear();
    final slot = KeyManagementService().slot;
    final slotMs = slot.inMilliseconds;
    var time = now;
    while (time.weekday == now.weekday) {
      final keyPair = _nativeKeyService.deriveNewKeyPair(
          masterKey, time.millisecondsSinceEpoch, slotMs);
      if (keyPair != null) {
        _nicknameOfTheDay.add(keyPair.publicKey);
      }
      time = time.add(slot);
    }
    // 10くらい翌日のニックネームも生成しておく
  }

  //Uint8Listはcontainで比較できない（涙）bool contains(Uint8List nickname)=> _nicknameOfTheDay.contains(nickname);
  bool contains(Uint8List nickname) {
    for (final friendNickname in _nicknameOfTheDay) {
      if (listEquals(nickname, friendNickname)) {
        return true;
      }
    }
    return false;
  }
}
