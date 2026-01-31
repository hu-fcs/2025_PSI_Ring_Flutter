// lib/pages/debug_page.dart

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';

import '../ble/ble_scanner.dart';
import '../db/database_helper.dart';
import '../key_management_service.dart';
import '../grpc/grpc_common.dart';

class DebugPage extends StatefulWidget {
  const DebugPage({super.key});

  @override
  State<DebugPage> createState() => _DebugPageState();
}

class _DebugPageState extends State<DebugPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  final KeyManagementService _keyManager = KeyManagementService();
  final GrpcCommon _grpcCommon = GrpcCommon();

  final TextEditingController _dummyCountController =
  TextEditingController(text: '5');

  StreamSubscription<void>? _keyUpdateSub;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);

    // 鍵更新を検知したら表示を更新する
    _keyUpdateSub = _keyManager.onKeyUpdated.listen((_) {
      if (!mounted) return;
      if (kDebugMode) {
        debugPrint('[DebugPage] key updated; refresh');
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _keyUpdateSub?.cancel();
    _tabController.dispose();
    _dummyCountController.dispose();
    super.dispose();
  }

  // ----- Database helpers -----

  Future<List<Map<String, dynamic>>> _fetchLimitedKeys(String tableName) async {
    final db = await DatabaseHelper.getDatabase();
    final order = tableName == 'generated_keys' ? 'id' : 'receive_time';
    return db.query(tableName, orderBy: '$order DESC', limit: 100);
  }

  Future<int> _fetchTotalKeyCount(String tableName) async {
    final db = await DatabaseHelper.getDatabase();
    final result = await db.rawQuery('SELECT COUNT(*) FROM $tableName');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> _deleteAllKeys(String tableName) async {
    final db = await DatabaseHelper.getDatabase();
    await db.delete(tableName);

    // 収集鍵を全削除した場合はスキャン側の重複抑止キャッシュも初期化する
    if (tableName == 'collected_keys') {
      BleScanner.clearCollectedCache();
      if (kDebugMode) {
        debugPrint('[DebugPage] collected cache cleared');
      }
    }

    setState(() {});
  }

  // ----- Dummy data -----

  Future<void> _generateAndInsertSingleDummyCollectedKey() async {
    final keyPair = _keyManager.generateDummyKeyPair();
    if (keyPair == null) return;
    final db = await DatabaseHelper.getDatabase();
    await db.insert(
      'collected_keys',
      {
        'pubkey_ecd': keyPair.publicKey,
        'receive_time': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> _insertDummyCollectedKey() async {
    await _generateAndInsertSingleDummyCollectedKey();
    setState(() {});
  }

  Future<void> _insertMultipleDummyCollectedKeys(int count) async {
    if (count <= 0) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('ダミー鍵を $count 件追加中...')),
    );

    final keys = <Uint8List>[];
    for (int i = 0; i < count; i++) {
      final keyPair = _keyManager.generateDummyKeyPair();
      if (keyPair != null) {
        keys.add(keyPair.publicKey);
      }
    }

    await DatabaseHelper.insertCollectedKeysBatch(publicKeys: keys);

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('ダミー鍵の追加を完了しました。')),
    );

    setState(() {});
  }

  Future<void> _insertCommonDummyKeysFromAsset(int count) async {
    if (count <= 0) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('共通ダミー鍵を $count 件追加中...')),
    );

    final inserted = await DatabaseHelper.insertCommonDummyKeys(count: count);

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('共通ダミー鍵を $inserted 件追加しました')),
    );

    setState(() {});
  }

  Future<void> _insertDummyGeneratedKey() async {
    final keyPair = _keyManager.generateDummyKeyPair();
    if (keyPair == null) return;
    final db = await DatabaseHelper.getDatabase();
    await db.insert('generated_keys', {
      'seckey_ecd': keyPair.privateKey,
      'pubkey_ecd': keyPair.publicKey,
      'lat': null,
      'lon': null,
      'generate_time': DateTime.now().millisecondsSinceEpoch,
      'expire_time':
      DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch,
    });
    setState(() {});
  }

  Future<void> _deleteMasterKey() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('マスターキー削除'),
        content: const Text('元に戻せません。削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _keyManager.deleteMasterKey();
      setState(() {});
    }
  }

  // ----- Dialog helpers -----

  /// バイト配列を 16 進数文字列に変換する。
  String _fullHex(List<int>? bytes) {
    if (bytes == null || bytes.isEmpty) return 'N/A';
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
  }

  void _showFullKeyDialog(
      BuildContext context,
      String title,
      List<int>? keyBytes,
      int keyId,
      ) {
    if (keyBytes == null) return;
    final String fullHexKey = _fullHex(keyBytes);
    if (fullHexKey.isEmpty) {
      _showErrorSnackbar('キーがありません。');
      return;
    }

    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  fullHexKey,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ],
            ),
          ),
          actions: [
            Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  label:
                  const Text('削除', style: TextStyle(color: Colors.red)),
                  onPressed: () async {
                    await DatabaseHelper.deleteKey(
                      table: KeyTable.collected,
                      id: keyId,
                    );
                    Navigator.of(context).pop();
                    setState(() {});
                  },
                ),
                const Spacer(),
                TextButton(
                  child: const Text('閉じる'),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _showGeneratedKeyDialog(
      BuildContext context,
      List<int>? pubKeyBytes,
      List<int>? secKeyBytes,
      int keyId,
      ) {
    final String fullHexPub = _fullHex(pubKeyBytes);
    final String fullHexSec = _fullHex(secKeyBytes);

    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('生成済み鍵ペア'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '公開鍵 (Public Key):',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SelectableText(
                  fullHexPub,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
                const SizedBox(height: 16),
                const Text(
                  '秘密鍵 (Secret Key):',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SelectableText(
                  fullHexSec,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ],
            ),
          ),
          actions: [
            Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  label:
                  const Text('削除', style: TextStyle(color: Colors.red)),
                  onPressed: () async {
                    await DatabaseHelper.deleteKey(
                      table: KeyTable.generated,
                      id: keyId,
                    );
                    Navigator.of(context).pop();
                    setState(() {});
                  },
                ),
                const Spacer(),
                TextButton(
                  child: const Text('閉じる'),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _showFullStringDialog(
      BuildContext context,
      String title,
      String? content,
      ) {
    if (content == null || content.isEmpty) {
      _showErrorSnackbar('キーがありません。');
      return;
    }

    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  content,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              child: const Text('閉じる'),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      },
    );
  }

  void _showErrorSnackbar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _showResultDialog({
    required String title,
    required bool isSuccess,
    required Widget content,
  }) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      isSuccess ? Icons.check_circle : Icons.cancel,
                      color: isSuccess ? Colors.green : Colors.red,
                      size: 28,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      isSuccess ? '成功' : '失敗',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 20,
                        color: isSuccess
                            ? Colors.green.shade700
                            : Colors.red.shade700,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24),
                content,
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('OK'),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showAddMultipleDummiesDialog() async {
    return showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('ダミー収集鍵の複数追加'),
          content: TextField(
            controller: _dummyCountController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: '追加する個数',
              hintText: '例: 10',
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () {
                final count = int.tryParse(_dummyCountController.text) ?? 0;
                Navigator.of(context).pop();
                _insertMultipleDummyCollectedKeys(count);
              },
              child: const Text('追加実行'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showAddCommonDummyDialog() async {
    return showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('共通ダミー鍵を追加（assets）'),
          content: TextField(
            controller: _dummyCountController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: '追加する個数',
              hintText: '例: 1000',
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () {
                final count = int.tryParse(_dummyCountController.text) ?? 0;
                Navigator.of(context).pop();
                _insertCommonDummyKeysFromAsset(count);
              },
              child: const Text('追加実行'),
            ),
          ],
        );
      },
    );
  }

  // ----- UI helpers -----

  String _shortHex(List<int>? bytes, {int length = 10}) {
    if (bytes == null || bytes.isEmpty) return 'N/A';
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
    return hex.length > length ? '${hex.substring(0, length)}...' : hex;
  }

  String _formatTime(dynamic unixTimeMs) {
    if (unixTimeMs == null) return 'N/A';
    final dt = DateTime.fromMillisecondsSinceEpoch(unixTimeMs);
    return '${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _toDMS(double decimalDegree, {required bool isLatitude}) {
    final direction = isLatitude
        ? (decimalDegree >= 0 ? 'N' : 'S')
        : (decimalDegree >= 0 ? 'E' : 'W');
    final absDeg = decimalDegree.abs();
    final deg = absDeg.floor();
    final minDecimal = (absDeg - deg) * 60;
    final min = minDecimal.floor();
    final sec = ((minDecimal - min) * 60).toStringAsFixed(2);
    return '$deg° $min′ $sec″ $direction';
  }

  Widget _buildMasterKeyCard() {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      color: Colors.indigo.shade50,
      elevation: 4,
      child: FutureBuilder<String?>(
        future: _keyManager.getMasterKeyBase64(),
        builder: (context, snapshot) {
          final String? masterKeyBase64 = snapshot.data;

          return InkWell(
            borderRadius: BorderRadius.circular(12.0),
            onTap: () {
              if (snapshot.connectionState == ConnectionState.done &&
                  masterKeyBase64 != null) {
                _showFullStringDialog(
                  context,
                  'マスターキー (Base64)',
                  masterKeyBase64,
                );
              } else if (snapshot.connectionState == ConnectionState.done) {
                _showErrorSnackbar('マスターキーはまだ保存されていません。');
              }
            },
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 40, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          const Text(
                            'マスターキー',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '(Base64)',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      if (snapshot.connectionState == ConnectionState.waiting)
                        const SizedBox(
                          height: 20,
                          child: LinearProgressIndicator(),
                        )
                      else if (masterKeyBase64 != null)
                        SelectionArea(
                          child: Text(
                            masterKeyBase64,
                            style: const TextStyle(fontFamily: 'monospace'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        )
                      else
                        const Text(
                          '保存されていません',
                          style: TextStyle(color: Colors.grey),
                        ),
                    ],
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: IconButton(
                    icon: const Icon(Icons.delete_forever),
                    onPressed: _deleteMasterKey,
                    tooltip: 'マスターキーを削除',
                    color: Colors.red.withOpacity(0.7),
                    splashRadius: 20,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildSlotSelector() {
    final int current = _keyManager.slotMs;

    Widget label(String text) {
      return SizedBox(
        width: 80,
        child: Center(child: Text(text)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '現在のスロット時間: ${_keyManager.slotMs} ms',
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: [
            ButtonSegment(
              value: 10 * 60 * 1000,
              label: label('10分'),
            ),
            ButtonSegment(
              value: 1 * 60 * 1000,
              label: label('1分'),
            ),
            ButtonSegment(
              value: 10 * 1000,
              label: label('10秒'),
            ),
          ],
          selected: {current},
          onSelectionChanged: (selection) {
            setState(() {
              _keyManager.slotMs = selection.first;
            });
          },
        ),
      ],
    );
  }

  Widget _buildRingRangeSelector() {
    final RingSignatureRange range = _keyManager.ringRange;

    Widget label(String text) {
      return SizedBox(
        width: 80,
        child: Center(child: Text(text)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'リング署名対象期間',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        SegmentedButton<RingSignatureRange>(
          segments: [
            ButtonSegment(
              value: RingSignatureRange.slot,
              label: label('スロット'),
            ),
            ButtonSegment(
              value: RingSignatureRange.day,
              label: label('1日'),
            ),
            ButtonSegment(
              value: RingSignatureRange.all,
              label: label('全期間'),
            ),
          ],
          selected: {range},
          onSelectionChanged: (selection) {
            setState(() {
              _keyManager.ringRange = selection.first;
            });
          },
        ),
      ],
    );
  }

  Widget _buildGrpcOptionToggles() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'gRPC 通信設定',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('gzip 圧縮'),
          subtitle: const Text('アプリケーションレベル圧縮'),
          value: _grpcCommon.enableGzip,
          onChanged: (v) {
            setState(() {
              _grpcCommon.enableGzip = v;
            });
          },
        ),
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            '※ 次回の gRPC 接続から有効になります',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
      ],
    );
  }

  Widget _buildKeyListTab(String tableName, bool isGenerated) {
    final fetchData = Future.wait([
      _fetchTotalKeyCount(tableName),
      _fetchLimitedKeys(tableName),
    ]);

    return FutureBuilder<List<dynamic>>(
      future: fetchData,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('エラー: ${snapshot.error}'));
        }

        final totalCount = (snapshot.data?[0] as int?) ?? 0;
        final records =
            (snapshot.data?[1] as List<Map<String, dynamic>>?) ?? [];

        return Column(
          children: [
            if (isGenerated) ...[
              _buildMasterKeyCard(),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: _insertDummyGeneratedKey,
                      child: const Text('ダミー追加'),
                    ),
                    ElevatedButton(
                      onPressed: () => _deleteAllKeys('generated_keys'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade100,
                      ),
                      child: const Text('全削除'),
                    ),
                  ],
                ),
              ),
            ] else ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 0,
                  alignment: WrapAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: _insertDummyCollectedKey,
                      child: const Text('ダミー追加'),
                    ),
                    ElevatedButton(
                      onPressed: _showAddMultipleDummiesDialog,
                      child: const Text('複数ダミー追加'),
                    ),
                    ElevatedButton(
                      onPressed: _showAddCommonDummyDialog,
                      child: const Text('複数共通ダミー追加'),
                    ),
                    ElevatedButton(
                      onPressed: () => _deleteAllKeys('collected_keys'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade100,
                      ),
                      child: const Text('全削除'),
                    ),
                  ],
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Column(
                children: [
                  Text(
                    '現在の総鍵数: $totalCount',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (totalCount > 100)
                    Text(
                      '(最新100件のみ表示)',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            Expanded(
              child: records.isEmpty
                  ? const Center(child: Text('データがありません'))
                  : ListView.builder(
                itemCount: records.length,
                itemBuilder: (context, index) {
                  final row = records[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(
                      vertical: 4,
                      horizontal: 12,
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12.0),
                      onTap: () {
                        if (isGenerated) {
                          _showGeneratedKeyDialog(
                            context,
                            row['pubkey_ecd'] as List<int>?,
                            row['seckey_ecd'] as List<int>?,
                            row['id'] as int,
                          );
                        } else {
                          _showFullKeyDialog(
                            context,
                            '収集した鍵',
                            row['pubkey_ecd'] as List<int>?,
                            row['id'] as int,
                          );
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: isGenerated
                            ? Column(
                          crossAxisAlignment:
                          CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Pub: ${_shortHex(row['pubkey_ecd'] as List<int>?)}',
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    'Sec: ${_shortHex(row['seckey_ecd'] as List<int>?)}',
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '生成: ${_formatTime(row['generate_time'])}',
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    '期限: ${_formatTime(row['expire_time'])}',
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              (row['lat'] == null ||
                                  row['lon'] == null)
                                  ? '位置: 未取得'
                                  : '位置: '
                                  '${_toDMS((row['lat'] as int) / 1e6, isLatitude: true)} / '
                                  '${_toDMS((row['lon'] as int) / 1e6, isLatitude: false)}',
                              style: TextStyle(
                                color: (row['lat'] == null ||
                                    row['lon'] == null)
                                    ? Colors.grey
                                    : Colors.black87,
                              ),
                            ),
                          ],
                        )
                            : Column(
                          crossAxisAlignment:
                          CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Key: ${_shortHex(row['pubkey_ecd'] as List<int>?)}',
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    '取得: ${_formatTime(row['receive_time'])}',
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('デバッグ画面')),
      body: Column(
        children: [
          TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: '収集した鍵'),
              Tab(text: '生成した鍵'),
              Tab(text: '機能検証'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildKeyListTab('collected_keys', false),
                _buildKeyListTab('generated_keys', true),
                _buildVerificationTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVerificationTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSlotSelector(),
          _buildRingRangeSelector(),
          const SizedBox(height: 24),
          _buildGrpcOptionToggles(),
        ],
      ),
    );
  }
}
