import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:convert/convert.dart' as convert;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import '../boringssl_service.dart';
import '../db/database_helper.dart';
import '../key_management_service.dart';
import '../native_key_service.dart';

// Isolateで実行するためのトップレベル関数 (変更なし)
Future<Map<String, dynamic>> _runRingSignatureInIsolate(Map<String, dynamic> args) async {
  final nativeKeyService = NativeKeyService();
  final stopwatch = Stopwatch()..start();
  final String message = args['message'];
  final Uint8List privateKey = args['privateKey'];
  final List<Uint8List> ringPublicKeys = args['ringPublicKeys'];
  final int ringSize = ringPublicKeys.length;
  final msgPtr = message.toNativeUtf8().cast<Char>();
  final privKeyPtr = calloc<Uint8>(privateKey.length)..asTypedList(privateKey.length).setAll(0, privateKey);
  final totalRingKeyLength = ringPublicKeys.fold<int>(0, (sum, list) => sum + list.length);
  final ringKeysPtr = calloc<Uint8>(totalRingKeyLength);
  int offset = 0;
  for (final key in ringPublicKeys) {
    ringKeysPtr.asTypedList(totalRingKeyLength).setRange(offset, offset + key.length, key);
    offset += key.length;
  }
  final signatureOutPtr = calloc<Uint8>((1 + ringSize) * 32);
  try {
    final creationResult = nativeKeyService.createRingSignature(
        msgPtr, message.length, privKeyPtr, ringKeysPtr, ringSize, signatureOutPtr);
    if (creationResult != 1) {
      return {'success': false, 'error': '署名の作成に失敗しました。'};
    }
    final verificationResult = nativeKeyService.verifyRingSignature(
        msgPtr, message.length, signatureOutPtr, ringKeysPtr, ringSize);
    stopwatch.stop();
    return {
      'success': true,
      'isVerified': verificationResult == 1,
      'signatureHex': convert.hex.encode(signatureOutPtr.asTypedList((1 + ringSize) * 32)),
      'elapsedTimeMs': stopwatch.elapsedMilliseconds,
    };
  } finally {
    calloc.free(msgPtr);
    calloc.free(privKeyPtr);
    calloc.free(ringKeysPtr);
    calloc.free(signatureOutPtr);
  }
}


class DebugPage extends StatefulWidget {
  const DebugPage({super.key});

  @override
  State<DebugPage> createState() => _DebugPageState();
}

class _DebugPageState extends State<DebugPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final KeyManagementService _keyManager = KeyManagementService();
  final BoringSSLService _boringSSLService = BoringSSLService();
  final TextEditingController _dummyCountController =
  TextEditingController(text: '5');
  bool _isVerifying = false;
  // ★★★ 進捗を整数(件数)で管理するように変更 ★★★
  final ValueNotifier<int> _progressCountNotifier = ValueNotifier(0);


  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _dummyCountController.dispose();
    _progressCountNotifier.dispose();
    super.dispose();
  }

  // --- データベース操作 ---
  Future<List<Map<String, dynamic>>> _fetchLimitedKeys(String tableName) async {
    final db = await DatabaseHelper.getDatabase();
    final orderByColumn = tableName == 'generated_keys' ? 'id' : 'ts';
    return db.query(tableName, orderBy: '$orderByColumn DESC', limit: 100);
  }

  Future<int> _fetchTotalKeyCount(String tableName) async {
    final db = await DatabaseHelper.getDatabase();
    final result = await db.rawQuery('SELECT COUNT(*) FROM $tableName');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> _deleteAllKeys(String tableName) async {
    final db = await DatabaseHelper.getDatabase();
    await db.delete(tableName);
    setState(() {});
  }

  // --- ダミーデータ操作 ---
  Future<void> _generateAndInsertSingleDummyCollectedKey() async {
    final keyPair = _keyManager.generateDummyKeyPair();
    if (keyPair == null) return;
    final random = Random();
    final db = await DatabaseHelper.getDatabase();
    await db.insert('ecd_keys', {
      'key_ecd': keyPair.publicKey,
      'lat': 34000000 + random.nextInt(1000000),
      'lon': 135000000 + random.nextInt(1000000),
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
  }

  Future<void> _insertDummyCollectedKey() async {
    await _generateAndInsertSingleDummyCollectedKey();
    setState(() {});
  }

  // ★★★ プログレス表示のロジックを修正 ★★★
  Future<void> _insertMultipleDummyCollectedKeys(int count) async {
    if (count <= 0) return;

    // SnackBarを表示
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: ValueListenableBuilder<int>(
          valueListenable: _progressCountNotifier,
          builder: (context, currentCount, child) {
            // 中央揃えにするためにRowでラップ
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('ダミー鍵を追加中... ($currentCount/$count)'),
              ],
            );
          },
        ),
        duration: Duration(seconds: (count * 0.1).ceil() + 5), // 処理時間に応じて表示時間を調整
      ),
    );

    // 1件ずつ追加しながらプログレスを更新
    for (int i = 0; i < count; i++) {
      await _generateAndInsertSingleDummyCollectedKey();
      // UIが更新されるように少し待機 (UIのフリーズを防ぐ)
      await Future.delayed(Duration.zero);
      // Notifierを更新してSnackBarを再描画
      _progressCountNotifier.value = i + 1;
    }

    // 完了後にUIを更新
    setState(() {});
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('✅ $count件のダミー収集鍵を挿入しました。')),
    );
    _progressCountNotifier.value = 0; // プログレスをリセット
  }


  Future<void> _insertDummyGeneratedKey() async {
    final keyPair = _keyManager.generateDummyKeyPair();
    if (keyPair == null) return;
    final db = await DatabaseHelper.getDatabase();
    await db.insert('generated_keys', {
      'seckey_ecd': keyPair.privateKey,
      'pubkey_ecd': keyPair.publicKey,
      'generate_time': DateTime.now().millisecondsSinceEpoch,
      'expire_time':
      DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch,
    });
    setState(() {});
  }

  // --- マスターキー操作 (変更なし) ---
  Future<void> _deleteMasterKey() async {
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

  // --- 機能検証ロジック (変更なし) ---
  void _testRandBytes() {
    try {
      final result = _boringSSLService.testRandomBytes();
      _showResultDialog(
        title: 'BoringSSL RAND_bytes テスト',
        isSuccess: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('正常にランダムなバイト列が生成されました。'),
            const SizedBox(height: 8),
            SelectableText(
              result,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      );
    } catch (e) {
      _showResultDialog(
        title: 'BoringSSL RAND_bytes テスト',
        isSuccess: false,
        content: Text('エラー: $e'),
      );
    }
  }

  Future<void> _performRingSignatureAndVerify() async {
    if (_isVerifying) return;
    setState(() {
      _isVerifying = true;
    });

    try {
      final signerKeyPair = await _keyManager.getLatestKeyPair();
      if (signerKeyPair == null) {
        _showErrorSnackbar('署名用の鍵ペアが見つかりませんでした。');
        return;
      }
      final collectedKeys = await _keyManager.getAllCollectedPublicKeys();
      final ringPublicKeys = <Uint8List>[...collectedKeys];
      if (!ringPublicKeys.any((key) => listEquals(key, signerKeyPair.publicKey))) {
        ringPublicKeys.add(signerKeyPair.publicKey);
      }
      if (ringPublicKeys.length < 2) {
        _showErrorSnackbar('リング署名には最低2つの鍵が必要です。');
        return;
      }

      final args = {
        'message': 'This is a test message for ring signature',
        'privateKey': signerKeyPair.privateKey,
        'ringPublicKeys': ringPublicKeys,
      };

      final result = await compute(_runRingSignatureInIsolate, args);

      if (result['success'] == true) {
        _showSignatureResultDialog(
          result['signatureHex'],
          result['isVerified'],
          result['elapsedTimeMs'],
        );
      } else {
        _showErrorSnackbar(result['error'] ?? '不明なエラーが発生しました。');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isVerifying = false;
        });
      }
    }
  }

  // --- ヘルパー関数 (ダイアログ) ---
  void _showErrorSnackbar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _showResultDialog({required String title, required bool isSuccess, required Widget content}) {
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
                        color: isSuccess ? Colors.green.shade700 : Colors.red.shade700,
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

  void _showSignatureResultDialog(String signatureHex, bool isVerified, int elapsedTimeMs) {
    if (!mounted) return;

    final displayedSignature = signatureHex.length > 500
        ? '${signatureHex.substring(0, 500)}...'
        : signatureHex;

    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('リング署名 結果'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(
                  isVerified ? Icons.check_circle : Icons.cancel,
                  color: isVerified ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 8),
                Text(
                  isVerified ? '検証成功' : '検証失敗',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                      color: isVerified ? Colors.green : Colors.red),
                ),
              ]),
              const SizedBox(height: 8),
              Text(
                '処理時間: $elapsedTimeMs ms',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Divider(height: 16),
              SizedBox(
                height: 150,
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('署名データ (Hex):'),
                      const SizedBox(height: 8),
                      SelectableText(
                        displayedSignature,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ],
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

  // --- UI構築ヘルパー (変更なし) ---
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
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 40, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
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

  Widget _buildVerificationTab() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _testRandBytes,
              icon: const Icon(Icons.science_outlined),
              label: const Text('BoringSSLのRAND_bytesをテスト'),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _isVerifying ? null : _performRingSignatureAndVerify,
              icon: _isVerifying
                  ? Container(
                width: 24,
                height: 24,
                padding: const EdgeInsets.all(2.0),
                child: const CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 3,
                ),
              )
                  : const Icon(Icons.edit_document),
              label: Text(_isVerifying ? '検証中...' : 'リング署名を作成・検証'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurple,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
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
        final records = (snapshot.data?[1] as List<Map<String, dynamic>>?) ?? [];

        return Column(
          children: [
            if (isGenerated) ...[
              _buildMasterKeyCard(),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.center, children: [
                  ElevatedButton(onPressed: _insertDummyGeneratedKey, child: const Text('ダミー追加')),
                  ElevatedButton(
                    onPressed: () => _deleteAllKeys('generated_keys'),
                    child: const Text('全削除'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade100),
                  ),
                ]),
              ),
            ] else ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.center, children: [
                  ElevatedButton(onPressed: _insertDummyCollectedKey, child: const Text('ダミー追加')),
                  ElevatedButton(onPressed: _showAddMultipleDummiesDialog, child: const Text('複数追加')),
                  ElevatedButton(
                    onPressed: () => _deleteAllKeys('ecd_keys'),
                    child: const Text('全削除'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade100),
                  ),
                ]),
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
                _buildKeyListTab('ecd_keys', false),
                _buildKeyListTab('generated_keys', true),
                _buildVerificationTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
