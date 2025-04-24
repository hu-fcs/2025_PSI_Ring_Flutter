import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DebugPage extends StatefulWidget {
  const DebugPage({super.key});

  @override
  State<DebugPage> createState() => _DebugPageState();
}

class _DebugPageState extends State<DebugPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;

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

  Future<Database> getDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'my_ecd.db');
    return openDatabase(path);
  }

  Future<List<Map<String, dynamic>>> fetchCollectedKeys() async {
    final db = await getDatabase();
    return db.query('ecd_keys');
  }

  Future<List<Map<String, dynamic>>> fetchGeneratedKeys() async {
    final db = await getDatabase();
    return db.query('generated_keys');
  }

  Future<void> insertDummyCollectedKey() async {
    final db = await getDatabase();
    await db.insert('ecd_keys', {
      'key_ecd': List<int>.generate(17, (i) => i),
      'lat': 12345678,
      'lon': 87654321,
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    setState(() {});
  }

  Future<void> insertDummyGeneratedKey() async {
    final db = await getDatabase();
    await db.insert('generated_keys', {
      'seckey_ecd': List<int>.generate(17, (i) => 100 + i),
      'pubkey_ecd': List<int>.generate(16, (i) => 200 - i),
      'generate_time': DateTime.now().millisecondsSinceEpoch,
      'expire_time': DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch,
    });
    setState(() {});
  }

  Future<void> deleteAllCollectedKeys() async {
    final db = await getDatabase();
    await db.delete('ecd_keys');
    setState(() {});
  }

  Future<void> deleteAllGeneratedKeys() async {
    final db = await getDatabase();
    await db.delete('generated_keys');
    setState(() {});
  }

  Widget buildKeyList(Future<List<Map<String, dynamic>>> futureData, bool isGenerated) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: futureData,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('エラー: ${snapshot.error}'));
        }
        final records = snapshot.data!;
        if (records.isEmpty) {
          return const Center(child: Text('データがありません'));
        }

        return ListView.builder(
          itemCount: records.length,
          itemBuilder: (context, index) {
            final row = records[index];
            final hex = (isGenerated ? row['seckey_ecd'] : row['key_ecd'] as List<int>)
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join('');
            return ListTile(
              title: Text('${isGenerated ? "Secret" : "Key"}: $hex'),
              subtitle: Text(
                isGenerated
                    ? '生成: ${row['generate_time']}, 期限: ${row['expire_time']}'
                    : 'Lat: ${row['lat']}, Lon: ${row['lon']}, 時刻: ${row['ts']}',
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
      appBar: AppBar(
        title: const Text('デバッグ画面'),
      ),
      body: Column(
        children: [
          TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: '収集した鍵'),
              Tab(text: '生成した鍵'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                Column(
                  children: [
                    ButtonBar(
                      alignment: MainAxisAlignment.center,
                      children: [
                        ElevatedButton(
                          onPressed: insertDummyCollectedKey,
                          child: const Text('ダミー追加'),
                        ),
                        ElevatedButton(
                          onPressed: deleteAllCollectedKeys,
                          child: const Text('全削除'),
                        ),
                      ],
                    ),
                    Expanded(child: buildKeyList(fetchCollectedKeys(), false)),
                  ],
                ),
                Column(
                  children: [
                    ButtonBar(
                      alignment: MainAxisAlignment.center,
                      children: [
                        ElevatedButton(
                          onPressed: insertDummyGeneratedKey,
                          child: const Text('ダミー追加'),
                        ),
                        ElevatedButton(
                          onPressed: deleteAllGeneratedKeys,
                          child: const Text('全削除'),
                        ),
                      ],
                    ),
                    Expanded(child: buildKeyList(fetchGeneratedKeys(), true)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
