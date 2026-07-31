// lib/main.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'db/database_helper.dart';
import 'key_management.dart';
import 'pages/debug_page.dart';
import 'pages/exchange_page.dart';
import 'pages/scanner_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // デスクトップ環境では sqflite の FFI 実装を使用する
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // DB を初期化する
  await DatabaseHelper.getDatabase();

  // マスターキーを初期化する
  final keyService = KeyManagementService();
  await keyService.init();

  // Android フォアグラウンド サービスを使う（flutter_foreground_task パッケージ）
  // FlutterForegroundTask.initCommunicationPort();

  runApp(const MyApp());
}

/// アプリ全体のルートウィジェット
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
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
