import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'pages/exchange_page.dart';
import 'pages/debug_page.dart';
import 'pages/scanner_page.dart';
import 'key_management_service.dart';
import 'db/database_helper.dart'; // DatabaseHelperをインポート

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // データベースとテーブルを初期化（存在しない場合のみ作成）
  await DatabaseHelper.initDatabase();

  // KeyManagementServiceを初期化して鍵生成を開始
  final keyService = KeyManagementService();
  await keyService.init();

  runApp(const MyApp());
}


// アプリ全体のルートウィジェット
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false, // DEBUGリボンを非表示
      title: '鍵交換アプリ',
      theme: ThemeData(
        fontFamily: 'NotoSansJP',
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.grey),
      ),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('ja'),
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
