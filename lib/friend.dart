import 'package:flutter/foundation.dart';
import 'ffi/native_key_service.dart' hide privateKeyLen;
import 'key_management.dart';
import 'db/friends_dao.dart';

class FriendList extends ChangeNotifier {
  static final FriendList _instance = FriendList._internal();
  factory FriendList() => _instance;
  FriendList._internal();

  /// _idFromNicknameStr の有効期限
  DateTime? cachedUntil;
  /// ニックネームを文字列にしたものから友達のID
  Map<String, int> _idFromNicknameStr = {};
  /// 友達のIDから友達のラベル（名前）
  Map<int, String> _friendLabelFromId = {};
  String labelOf(int id) => _friendLabelFromId[id] ?? 'Unknown';

  Future<int?> getFriendByNickname(Uint8List nickname) async {
    await updateCacheOfFriends();
    final nicknameStr = nickname.hexStr();
    final friendId = _idFromNicknameStr[nicknameStr];
    return friendId; // 見つからなければnull
  }

  /// DBから読み出したキャッシュの有効期限を確認して，必要ならDBから再取得する．
  Future<void> updateCacheOfFriends() async {
    final now = DateTime.now();
    if (cachedUntil != null && cachedUntil!.isAfter(now))
      return; // 有効なキャッシュ

    // 少しマージンをとって10分前から，今日の24時まで
    final from = now.subtract(const Duration(minutes: 10));
    final to = DateTime(now.year, now.month, now.day + 1, 0, 0, 0);
    // DBのfriend_nicknamesから読み込み
    List<FriendNicknameEntry> friends = await FriendsDao.instance.findFriendsDuringPeriod(from, to);
    cachedUntil = to;

    _idFromNicknameStr.clear();
    _friendLabelFromId.clear();
    for (final friendNicknameEntry in friends) {
      _idFromNicknameStr[friendNicknameEntry.pubkeyEcd.hexStr()] = friendNicknameEntry.id;
      _friendLabelFromId[friendNicknameEntry.id] = friendNicknameEntry.label;
    }
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
