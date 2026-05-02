import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import 'database_helper.dart';
import '../key_management_service.dart'; // SlotNickname を使う

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
    required List<SlotNickname> schedule,
  }) async {
    if (schedule.isEmpty) return;

    final db = await _db();
    final batch = db.batch();

    for (final s in schedule) {
      final startSec = s.slotStart.millisecondsSinceEpoch ~/ 1000;
      final endSec =
          startSec + s.slotDuration.inMilliseconds ~/ 1000;

      batch.insert(
        'friend_nicknames',
        {
          'friend_id': friendId,
          'pubkey_ecd': s.pubkey33,
          'slot_start': startSec,
          'slot_end': endSec,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
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
