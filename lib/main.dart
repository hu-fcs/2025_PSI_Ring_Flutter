import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:io';

import 'pages/exchange_page.dart';
import 'pages/debug_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadPrepopulatedDatabase();
  runApp(const MyApp());
}

Future<void> loadPrepopulatedDatabase() async {
  final dbPath = await getDatabasesPath();
  final path = join(dbPath, 'my_ecd.db');

  if (!await File(path).exists()) {
    final data = await rootBundle.load('assets/empty_ecd.db');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    await File(path).writeAsBytes(bytes, flush: true);
  }

  final db = await openDatabase(path);
  await db.execute('''
    CREATE TABLE IF NOT EXISTS generated_keys (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      seckey_ecd BLOB,
      pubkey_ecd BLOB,
      generate_time INTEGER,
      expire_time INTEGER
    )
  ''');

  final existing = await db.query('ecd_keys');
  if (existing.isEmpty) {
    await db.insert('ecd_keys', {
      'key_ecd': List<int>.filled(17, 0xAB),
      'lat': 34567890,
      'lon': 135123456,
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '鍵交換アプリ',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const ExchangePage(),
        '/debug': (context) => const DebugPage(),
      },
    );
  }
}
