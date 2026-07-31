import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'database_helper.dart';

/// friends テーブル1行分
class FriendEntry {
  final int id;
  final String label;
  final String? note;
  final DateTime createdAt;

  FriendEntry({
    required this.id,
    required this.label,
    this.note,
    required this.createdAt,
  });

  factory FriendEntry.fromMap(Map<String, Object?> map) {
    return FriendEntry(
      id: map['id'] as int,
      label: map['label'] as String,
      note: map['note'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['created_at'] as int) * 1000,
      ),
    );
  }
}

/// friends テーブル1行分
class FriendNicknameEntry {
  final int id;
  final String label; // ユーザーの名前
  final Uint8List pubkeyEcd; // ニックネーム
  final DateTime slotStart;
  final DateTime slotEnd;

  FriendNicknameEntry({
    required this.id,
    required this.label,
    required this.pubkeyEcd,
    required this.slotStart,
    required this.slotEnd,
  });

  factory FriendNicknameEntry.fromMap(Map<String, Object?> map) {
    return FriendNicknameEntry(
      id: map['id'] as int,
      label: map['label'] as String,
      pubkeyEcd: map['pubkey_ecd'] as Uint8List,
      slotStart: DateTime.fromMillisecondsSinceEpoch(
        (map['slot_start'] as int) * 1000),
      slotEnd: DateTime.fromMillisecondsSinceEpoch(
          (map['slot_end'] as int) * 1000),
    );
  }
}

class FriendsDao {
  FriendsDao._();
  static final instance = FriendsDao._();

  Future<Database> _db() => DatabaseHelper.getDatabase();

  Future<int> insertFriend({
    required String label,
    String? note,
  }) async {
    final db = await _db();
    final id = await db.insert(
      'friends',
      {
        'label': label,
        'note': note,
        'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      },
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
    return id;
  }

  /// 将来ニックネームリストを friend_nicknames にまとめて保存
  ///
  /// [friendId] : friends.id
  /// [schedule] : KeyManagementService.generateFutureNicknameList() の結果
  Future<void> insertFriendNicknames({
    required int friendId,
    required DateTime firstSlot,
    required Duration slot,
    required List<Uint8List> nicknameList, // List<pubkey33list>
  }) async {
    if (nicknameList.isEmpty) return;

    final db = await _db();
    final batch = db.batch();

    // 秒単位の最初のニックネーム開始時刻と有効時間
    var startSec = firstSlot.millisecondsSinceEpoch ~/ 1000;
    final slotSec = slot.inMilliseconds ~/ 1000;
    // nicknameListのすべてのニックネームをデータベースに追加する
    for (int i = 0; i < nicknameList.length; i++) {
      batch.insert(
        'friend_nicknames',
        {
          'friend_id': friendId,
          'pubkey_ecd': nicknameList[i],
          'slot_start': startSec,
          'slot_end': startSec + slotSec,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      startSec += slotSec;
    }

    await batch.commit(noResult: true);
  }

  Future<List<Map<String, Object?>>> getFriendsWithActiveCount() async {
    final db = await _db();
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final rows = await db.rawQuery('''
      SELECT f.id, f.label, f.note, f.created_at,
             COUNT(fn.id) AS active_count
      FROM friends f
      LEFT JOIN friend_nicknames fn
        ON fn.friend_id = f.id
       AND fn.slot_start <= ?
       AND fn.slot_end >= ?
      GROUP BY f.id, f.label, f.note, f.created_at
      ORDER BY f.id DESC
    ''', [nowSec, nowSec]);

    return rows;
  }

  Future<List<Uint8List>> getNicknamesForFriend(int friendId) async {
    final db = await _db();
    final rows = await db.query(
      'friend_nicknames',
      columns: ['pubkey_ecd'],
      where: 'friend_id = ?',
      whereArgs: [friendId],
      orderBy: 'slot_start ASC',
    );

    return rows
        .map((e) => e['pubkey_ecd'] as Uint8List)
        .toList(growable: false);
  }

  /// friend とそのニックネームをまとめて削除
  /// friend とそのニックネームをまとめて削除
  Future<void> deleteFriend(int friendId) async {
    final db = await _db();

    await db.transaction((txn) async {
      await txn.delete('friend_nicknames', where: 'friend_id = ?', whereArgs: [friendId]);
      await txn.delete('friends', where: 'id = ?', whereArgs: [friendId]);
    });
  }

  /// 期限切れニックネーム（slot_end < now）を削除して、削除件数を返す
  Future<int> deleteExpiredFriendNicknames() async {
    final db = await _db();
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final deleted = await db.delete(
      'friend_nicknames',
      where: 'slot_end < ?',
      whereArgs: [nowSec],
    );
    return deleted;
  }

  /// いまの時刻に有効な friend_nicknames から、
  /// [pubkey33] に一致する友達ラベルを「全件」返す。
  Future<List<String>> findFriendLabelsByPubkey(Uint8List pubkey33) async {
    final db = await _db();
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final rows = await db.rawQuery('''
      SELECT f.label
      FROM friend_nicknames fn
      JOIN friends f ON fn.friend_id = f.id
      WHERE fn.pubkey_ecd = ?
        AND fn.slot_start <= ?
        AND fn.slot_end   >= ?
      ORDER BY f.id DESC
    ''', [pubkey33, nowSec, nowSec]);

    return rows.map((e) => e['label'] as String).toList(growable: false);
  }

  /// 指定した時間に有効な friend_nicknames をまとめて返す。
  /// fromとtoの間に少しでも重なるニックネームを探す。
  /// 呼び出し元でキャッシュする。
  Future<List<FriendNicknameEntry>> findFriendsDuringPeriod(DateTime from, DateTime to) async {
    final db = await _db();
    final fromSec = from.millisecondsSinceEpoch ~/ 1000;
    final toSec = to.millisecondsSinceEpoch ~/ 1000;

    final rows = await db.rawQuery('''
      SELECT *
      FROM friend_nicknames fn
      JOIN friends f ON fn.friend_id = f.id
      WHERE fn.slot_start <= ?
        AND fn.slot_end   >= ?
      ORDER BY f.id DESC
    ''', [toSec, fromSec]);

    final friendNicknameEntries = rows.map(FriendNicknameEntry.fromMap).toList();
    return friendNicknameEntries;
  }

  /// Debug用：friends 一覧 + friend_nicknames の総数
  Future<List<Map<String, Object?>>> listFriendsWithNicknameCounts() async {
    final db = await _db();

    final rows = await db.rawQuery('''
      SELECT
        f.id,
        f.label,
        f.note,
        f.created_at,
        COUNT(fn.id) AS nickname_count
      FROM friends f
      LEFT JOIN friend_nicknames fn
        ON fn.friend_id = f.id
      GROUP BY f.id, f.label, f.note, f.created_at
      ORDER BY f.id DESC
    ''');

    return rows;
  }

  /// Debug用：friend_nicknames の総件数
  Future<int> getTotalFriendNicknames() async {
    final db = await _db();
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM friend_nicknames');
    return (rows.first['c'] as int?) ?? 0;
  }
}
