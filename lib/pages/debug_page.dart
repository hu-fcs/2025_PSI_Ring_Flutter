import 'dart:math';
import 'package:flutter/material.dart';
import '../db/database_helper.dart';
import '../key_management_service.dart';

class DebugPage extends StatefulWidget {
  const DebugPage({super.key});

  @override
  State<DebugPage> createState() => _DebugPageState();
}

class _DebugPageState extends State<DebugPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final KeyManagementService _keyManager = KeyManagementService();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // --- データベース操作 ---
  Future<List<Map<String, dynamic>>> _fetchKeys(String tableName) async {
    final db = await DatabaseHelper.getDatabase();
    return db.query(tableName);
  }

  Future<void> _deleteAllKeys(String tableName) async {
    final db = await DatabaseHelper.getDatabase();
    await db.delete(tableName);
    setState(() {});
  }

  // --- ダミーデータ操作 ---
  Future<void> _insertDummyCollectedKey() async {
    final keyPair = _keyManager.generateDummyKeyPair();
    if (keyPair == null) {
      print("🚨 ダミー収集鍵の生成に失敗しました。");
      return;
    }

    final random = Random();
    final db = await DatabaseHelper.getDatabase();
    await db.insert('ecd_keys', {
      'key_ecd': keyPair.publicKey,
      'lat': 34000000 + random.nextInt(1000000),
      'lon': 135000000 + random.nextInt(1000000),
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    setState(() {});
    print("✅ ダミー収集鍵を挿入しました。");
  }

  Future<void> _insertDummyGeneratedKey() async {
    final keyPair = _keyManager.generateDummyKeyPair();
    if (keyPair == null) {
      print("🚨 ダミー生成鍵の生成に失敗しました。");
      return;
    }

    final db = await DatabaseHelper.getDatabase();
    await db.insert('generated_keys', {
      'seckey_ecd': keyPair.privateKey,
      'pubkey_ecd': keyPair.publicKey,
      'generate_time': DateTime.now().millisecondsSinceEpoch,
      'expire_time': DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch,
    });
    setState(() {});
    print("✅ ダミー生成鍵を挿入しました。");
  }

  // --- マスターキー操作 ---
  Future<void> _deleteMasterKey() async {
    // 削除前に確認ダイアログを表示
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('マスターキーの削除'),
        content: const Text('マスターキーを削除すると、アプリは初期状態に戻ります。よろしいですか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('削除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _keyManager.deleteMasterKey();
      setState(() {});
    }
  }

  // --- UI構築ヘルパー ---
  String _shortHex(List<int>? bytes, {int length = 10}) {
    if (bytes == null || bytes.isEmpty) return 'N/A';
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
    return hex.length > length ? '${hex.substring(0, length)}...' : hex;
  }

  String _formatTime(dynamic unixTimeMs, {bool isSecond = false}) {
    if (unixTimeMs == null) return "N/A";
    final millis = isSecond ? unixTimeMs * 1000 : unixTimeMs;
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _toDMS(double decimalDegree, {required bool isLatitude}) {
    final direction = isLatitude ? (decimalDegree >= 0 ? 'N' : 'S') : (decimalDegree >= 0 ? 'E' : 'W');
    final absDeg = decimalDegree.abs();
    final deg = absDeg.floor();
    final minDecimal = (absDeg - deg) * 60;
    final min = minDecimal.floor();
    final sec = ((minDecimal - min) * 60).toStringAsFixed(2);
    return "$deg° $min′ $sec″ $direction";
  }

  // --- ウィジェット ---
  Widget _buildMasterKeyCard() {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      color: Colors.indigo.shade50,
      elevation: 4,
      child: Stack( // アイコンを右上に配置するためにStackを使用
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 40, 12), // アイコンのスペースを確保
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min, // 高さを最小に
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    const Text('🔑 マスターキー', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 8),
                    Text('(Base64)', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  ],
                ),
                const SizedBox(height: 4),
                FutureBuilder<String?>(
                  future: _keyManager.getMasterKeyBase64(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const SizedBox(height: 20, child: LinearProgressIndicator());
                    }
                    if (snapshot.hasData && snapshot.data != null) {
                      // 1行で省略表示するための設定
                      return SelectionArea(
                        child: Text(
                          snapshot.data!,
                          style: const TextStyle(fontFamily: 'monospace'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    } else {
                      return const Text('保存されていません', style: TextStyle(color: Colors.grey));
                    }
                  },
                ),
              ],
            ),
          ),
          // 右上に配置した削除ボタン
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
  }

  Widget _buildKeyList(String tableName, bool isGenerated) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _fetchKeys(tableName),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text('データがありません'));
        }
        final records = snapshot.data!;
        return ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: records.length,
          itemBuilder: (context, index) {
            final row = records[index];
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: isGenerated
                    ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(child: Text('Pub: ${_shortHex(row['pubkey_ecd'] as List<int>?)}')),
                      Expanded(child: Text('Sec: ${_shortHex(row['seckey_ecd'] as List<int>?)}')),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: Text('生成: ${_formatTime(row['generate_time'])}')),
                      Expanded(child: Text('期限: ${_formatTime(row['expire_time'])}')),
                    ]),
                  ],
                )
                    : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Text('Key: ${_shortHex(row['key_ecd'] as List<int>?, length: 20)}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.blueGrey)),
                    ),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('緯度', style: TextStyle(fontWeight: FontWeight.bold)),
                        Text(_toDMS((row['lat'] as int) / 1e6, isLatitude: true)),
                      ])),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('経度', style: TextStyle(fontWeight: FontWeight.bold)),
                        Text(_toDMS((row['lon'] as int) / 1e6, isLatitude: false)),
                      ])),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('取得', style: TextStyle(fontWeight: FontWeight.bold)),
                        Text(_formatTime(row['ts'], isSecond: true)),
                      ])),
                    ]),
                  ],
                ),
              ),
            );
          },
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
            tabs: const [Tab(text: '収集した鍵'), Tab(text: '生成した鍵')],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                SingleChildScrollView(
                  child: Column(children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.center, children: [
                        ElevatedButton(onPressed: _insertDummyCollectedKey, child: const Text('ダミー追加')),
                        ElevatedButton(onPressed: () => _deleteAllKeys('ecd_keys'), child: const Text('収集鍵を全削除')),
                      ]),
                    ),
                    _buildKeyList('ecd_keys', false),
                  ]),
                ),
                SingleChildScrollView(
                  child: Column(children: [
                    _buildMasterKeyCard(),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.center, children: [
                        ElevatedButton(onPressed: _insertDummyGeneratedKey, child: const Text('ダミー追加')),
                        ElevatedButton(onPressed: () => _deleteAllKeys('generated_keys'), child: const Text('生成鍵を全削除')),
                      ]),
                    ),
                    _buildKeyList('generated_keys', true),
                  ]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
