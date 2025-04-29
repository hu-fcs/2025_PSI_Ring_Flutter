import 'dart:convert';
import 'dart:io';
import 'dart:typed_data'; // 追加！
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'; // デスクトップ対応のため追加
import 'package:flutter_localizations/flutter_localizations.dart';

import 'pages/exchange_page.dart';
import 'pages/debug_page.dart';
import 'pages/scanner_page.dart'; // ← スキャナページを使用するためにインポート

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Windows/Linux対応：sqflite_ffiの初期化
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // アセットから初期データベースを読み込む
  await loadPrepopulatedDatabase();

  // アプリを起動
  runApp(const MyApp());
}

// データベースを初期化して必要なテーブルを準備する
Future<void> loadPrepopulatedDatabase() async {
  final dbPath = await getDatabasesPath();
  final path = join(dbPath, 'my_ecd.db');

  // DBファイルが存在しない場合はアセットからコピー
  if (!await File(path).exists()) {
    final data = await rootBundle.load('assets/empty_ecd.db');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    await File(path).writeAsBytes(bytes, flush: true);
  }

  final db = await openDatabase(path);

  // テーブル作成（存在しなければ）
  await db.execute('''
    CREATE TABLE IF NOT EXISTS generated_keys (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      seckey_ecd BLOB,
      pubkey_ecd BLOB,
      generate_time INTEGER,
      expire_time INTEGER
    )
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS ecd_keys (
      key_ecd BLOB NOT NULL,
      lat INTEGER NOT NULL,
      lon INTEGER NOT NULL,
      ts INTEGER NOT NULL
    )
  ''');

  // 初期キーが空ならダミーを挿入
  final existing = await db.query('ecd_keys');
  if (existing.isEmpty) {
    await db.insert('ecd_keys', {
      'key_ecd': Uint8List.fromList(List<int>.filled(17, 0xAB)), // ← 修正：BLOBとして保存
      'lat': 34567890,
      'lon': 135123456,
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
  }
}

// アプリ全体のルートウィジェット
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '鍵交換アプリ',
      theme: ThemeData(
        fontFamily: 'NotoSansJP', // ← 日本語フォント指定
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.grey),
      ),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('ja'), // 日本語対応
      ],
      initialRoute: '/',
      routes: {
        '/': (context) => const ExchangePage(),
        '/debug': (context) => const DebugPage(),
        '/scanner': (context) => const ScannerPage(),
      },
    );
  }
}
