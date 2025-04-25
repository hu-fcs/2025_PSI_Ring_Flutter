import 'package:flutter/material.dart';
import '../db/database_helper.dart';

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

  Future<List<Map<String, dynamic>>> fetchCollectedKeys() async {
    final db = await DatabaseHelper.getDatabase();
    return db.query('ecd_keys');
  }

  Future<List<Map<String, dynamic>>> fetchGeneratedKeys() async {
    final db = await DatabaseHelper.getDatabase();
    return db.query('generated_keys');
  }

  Future<void> insertDummyCollectedKey() async {
    final db = await DatabaseHelper.getDatabase();
    await db.insert('ecd_keys', {
      'key_ecd': List<int>.generate(17, (i) => (i + DateTime.now().second) % 256),
      'lat': 34567890,
      'lon': 13512345,
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    setState(() {});
  }

  Future<void> insertDummyGeneratedKey() async {
    final db = await DatabaseHelper.getDatabase();
    await db.insert('generated_keys', {
      'seckey_ecd': List<int>.generate(17, (i) => (100 + i + DateTime.now().second) % 256),
      'pubkey_ecd': List<int>.generate(16, (i) => (200 - i - DateTime.now().second) % 256),
      'generate_time': DateTime.now().millisecondsSinceEpoch,
      'expire_time': DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch,
    });
    setState(() {});
  }

  Future<void> deleteAllCollectedKeys() async {
    final db = await DatabaseHelper.getDatabase();
    await db.delete('ecd_keys');
    setState(() {});
  }

  Future<void> deleteAllGeneratedKeys() async {
    final db = await DatabaseHelper.getDatabase();
    await db.delete('generated_keys');
    setState(() {});
  }

  String shortHex(List<int> bytes) {
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
    return hex.length > 5 ? '${hex.substring(0, 5)}...' : hex;
  }

  String formatTime(dynamic unixTimeMs, {bool isSecond = false}) {
    final millis = isSecond ? unixTimeMs * 1000 : unixTimeMs;
    final dt = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toLocal();
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String toDMS(double decimalDegree, {required bool isLatitude}) {
    final direction = isLatitude
        ? (decimalDegree >= 0 ? 'N' : 'S')
        : (decimalDegree >= 0 ? 'E' : 'W');

    final absDeg = decimalDegree.abs();
    final deg = absDeg.floor();
    final minDecimal = (absDeg - deg) * 60;
    final min = minDecimal.floor();
    final sec = ((minDecimal - min) * 60).toStringAsFixed(2);

    return "$deg° $min′ $sec″ $direction";
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

            if (isGenerated) {
              final secKey = row['seckey_ecd'] as List<int>;
              final pubKey = row['pubkey_ecd'] as List<int>;
              final genTime = formatTime(row['generate_time']);
              final expTime = formatTime(row['expire_time']);

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sec: ${shortHex(secKey)}   Pub: ${shortHex(pubKey)}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '生成: $genTime   期限: $expTime',
                        style: const TextStyle(fontSize: 14),
                      ),
                    ],
                  ),
                ),
              );
            } else {
              final key = row['key_ecd'] as List<int>;
              final latDecimal = row['lat'] / 1e6;
              final lonDecimal = row['lon'] / 1e6;
              final ts = formatTime(row['ts'], isSecond: true);

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Text(
                          'Key: ${shortHex(key)}',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: Colors.blueGrey,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('緯度', style: TextStyle(fontWeight: FontWeight.bold)),
                                Text(toDMS(latDecimal, isLatitude: true)),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('経度', style: TextStyle(fontWeight: FontWeight.bold)),
                                Text(toDMS(lonDecimal, isLatitude: false)),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('取得', style: TextStyle(fontWeight: FontWeight.bold)),
                                Text(ts),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }
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
                    OverflowBar(
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
                    OverflowBar(
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
