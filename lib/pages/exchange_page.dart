import 'package:flutter/material.dart';
import 'dart:math';

class ExchangePage extends StatefulWidget {
  const ExchangePage({super.key});

  @override
  State<ExchangePage> createState() => _ExchangePageState();
}

class _ExchangePageState extends State<ExchangePage> {
  bool isExchanging = false;
  String myId = 'ABC123'; // 本来はUUIDなど動的に生成する
  List<String> nearbyIds = ['XYZ987', 'DEF456', 'LMN321'];
  String? checkingId;

  void toggleExchange() {
    setState(() {
      isExchanging = !isExchanging;
    });
  }

  void startCheck(String targetId) {
    setState(() {
      checkingId = targetId;
    });
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('チェック中'),
        content: Text('$targetId と照合しています...'),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                checkingId = null;
              });
              Navigator.pop(context);
            },
            child: const Text('キャンセル'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('鍵交換画面'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bug_report),
            tooltip: 'デバッグへ',
            onPressed: () => Navigator.pushNamed(context, '/debug'),
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            ElevatedButton.icon(
              onPressed: toggleExchange,
              icon: Icon(isExchanging ? Icons.stop : Icons.play_arrow),
              label: Text(isExchanging ? '停止' : '開始'),
              style: ElevatedButton.styleFrom(
                backgroundColor: isExchanging ? Colors.red : Colors.green,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                const Text('あなたの識別ID: ',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text(myId),
              ],
            ),
            const SizedBox(height: 20),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('近くの識別ID一覧:',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: nearbyIds.length,
                itemBuilder: (context, index) {
                  final id = nearbyIds[index];
                  return ListTile(
                    leading: const Icon(Icons.person),
                    title: Text(id),
                    trailing: ElevatedButton(
                      onPressed: () => startCheck(id),
                      child: const Text('チェック'),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
