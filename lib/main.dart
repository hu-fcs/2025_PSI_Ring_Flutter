import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:io';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'pages/exchange_page.dart';
import 'pages/debug_page.dart';
import 'pages/scanner_page.dart'; // ← スキャナページを使用するためにインポート

void main() async {
  // Flutterのバインディングを初期化（非同期処理があるため必要）
  WidgetsFlutterBinding.ensureInitialized();

  // アセットから初期データベースを読み込む
  await loadPrepopulatedDatabase();

  // アプリを起動
  runApp(const MyApp());
}

// データベースを初期化して必要なテーブルを準備する
Future<void> loadPrepopulatedDatabase() async {
  final dbPath = await getDatabasesPath(); // SQLiteファイルの保存パスを取得
  final path = join(dbPath, 'my_ecd.db');

  // DBファイルが存在しない場合はアセットからコピー
  if (!await File(path).exists()) {
    final data = await rootBundle.load('assets/empty_ecd.db');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    await File(path).writeAsBytes(bytes, flush: true);
  }

  // DBを開いて必要なテーブルを追加（存在しない場合）
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

  // 初期キー情報が空ならダミーを1件挿入
  final existing = await db.query('ecd_keys');
  if (existing.isEmpty) {
    await db.insert('ecd_keys', {
      'key_ecd': List<int>.filled(17, 0xAB), // ダミーキー
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
        fontFamily: 'NotoSansJP', // ← 日本語用フォントを指定（pubspec.yaml側にも記述要）
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.grey), // カラーテーマを設定
      ),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('ja'), // ← 日本語をサポート
        Locale('en'),
      ],
      locale: const Locale('ja'), // ← 初期ロケールを日本語に設定
      initialRoute: '/', // 最初に表示するルート（ExchangePage）
      routes: {
        '/': (context) => const ExchangePage(),      // メイン画面
        '/debug': (context) => const DebugPage(),    // デバッグ画面
        '/scanner': (context) => const ScannerPage(),// QRスキャン画面
      },
    );
  }
}
