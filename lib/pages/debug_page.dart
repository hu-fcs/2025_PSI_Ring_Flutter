// lib/pages/debug_page.dart

import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:async'; // ★ StreamSubscription 用に必要
import 'package:convert/convert.dart' as convert;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';

import '../ble/ble_scanner.dart';
import '../boringssl_service.dart';
import '../db/database_helper.dart';
import '../key_management_service.dart';
import '../ffi/native_key_service.dart';


// ================================================================
// Isolateで実行する関数 (変更なし)
// ================================================================
Future<Map<String, dynamic>> _runRingSignatureInIsolate(Map<String, dynamic> args) async {
  final nativeKeyService = NativeKeyService();
  final stopwatch = Stopwatch()..start();

  final String message = args['message'];
  final Uint8List privateKey = args['privateKey'];
  final List<Uint8List> ringPublicKeys = args['ringPublicKeys'];
  final int ringSize = ringPublicKeys.length;

  final msgPtr = message.toNativeUtf8().cast<Char>();
  final privKeyPtr = calloc<Uint8>(privateKey.length)
    ..asTypedList(privateKey.length).setAll(0, privateKey);

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



// ================================================================
// DebugPage
// ================================================================
class DebugPage extends StatefulWidget {
  const DebugPage({super.key});

  @override
  State<DebugPage> createState() => _DebugPageState();
}


class _DebugPageState extends State<DebugPage> with SingleTickerProviderStateMixin {

  late TabController _tabController;

  final KeyManagementService _keyManager = KeyManagementService();
  final BoringSSLService _boringSSLService = BoringSSLService();

  final TextEditingController _dummyCountController =
  TextEditingController(text: '5');

  bool _isVerifying = false;
  final ValueNotifier<int> _progressCountNotifier = ValueNotifier(0);

  // ★ hot reload 対応：DB更新通知購読用
  StreamSubscription<void>? _keyUpdateSub;


  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);

    // ★ BLE由来の鍵が更新されたら DebugPage UI を自動更新
    _keyUpdateSub = _keyManager.onKeyUpdated.listen((_) {
      if (mounted) {
        print('[DebugPage] 🔄 Key updated — refreshing UI');
        setState(() {}); // UI を再描画
      }
    });
  }


  @override
  void dispose() {
    _keyUpdateSub?.cancel(); // ★購読解除
    _tabController.dispose();
    _dummyCountController.dispose();
    _progressCountNotifier.dispose();
    super.dispose();
  }




  // ================================================================
  // データベース操作
  // ================================================================
  Future<List<Map<String, dynamic>>> _fetchLimitedKeys(String tableName) async {
    final db = await DatabaseHelper.getDatabase();
    final order = tableName == 'generated_keys' ? 'id' : 'receive_time';
    return db.query(tableName, orderBy: '$order DESC', limit: 100);
  }

  Future<int> _fetchTotalKeyCount(String tableName) async {
    final db = await DatabaseHelper.getDatabase();
    final result = await db.rawQuery('SELECT COUNT(*) FROM $tableName');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> _deleteAllKeys(String tableName) async {
    final db = await DatabaseHelper.getDatabase();
    await db.delete(tableName);

    // 🔥 収集した鍵を全削除したら BLE キャッシュをリセットする
    if (tableName == 'collected_keys') {
      BleScanner.clearCollectedCache();
      if (kDebugMode) print('DebugPage: 🧹 cache cleared due to collected_keys deletion');
    }

    setState(() {});
  }



  // ================================================================
  // ダミーデータ操作（変更なし）
  // ================================================================
  Future<void> _generateAndInsertSingleDummyCollectedKey() async {
    final keyPair = _keyManager.generateDummyKeyPair();
    if (keyPair == null) return;
    final random = Random();
    final db = await DatabaseHelper.getDatabase();
    await db.insert('collected_keys', {
      'pubkey_ecd': keyPair.publicKey,
      'lat': 34000000 + random.nextInt(1000000),
      'lon': 135000000 + random.nextInt(1000000),
      'receive_time': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> _insertDummyCollectedKey() async {
    await _generateAndInsertSingleDummyCollectedKey();
    setState(() {});
  }

  Future<void> _insertMultipleDummyCollectedKeys(int count) async {
    if (count <= 0) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('追加中...')),
    );
    for (int i = 0; i < count; i++) {
      await _generateAndInsertSingleDummyCollectedKey();
      _progressCountNotifier.value = i + 1;
    }
    setState(() {});
  }


  Future<void> _insertDummyGeneratedKey() async {
    final keyPair = _keyManager.generateDummyKeyPair();
    if (keyPair == null) return;
    final db = await DatabaseHelper.getDatabase();
    await db.insert('generated_keys', {
      'seckey_ecd': keyPair.privateKey,
      'pubkey_ecd': keyPair.publicKey,
      'generate_time': DateTime.now().millisecondsSinceEpoch,
      'expire_time': DateTime.now().add(Duration(minutes: 10)).millisecondsSinceEpoch,
    });
    setState(() {});
  }


  Future<void> _deleteMasterKey() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('マスターキー削除'),
        content: Text('元に戻せません。削除しますか？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('キャンセル')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text('削除')),
        ],
      ),
    );

    if (confirm == true) {
      await _keyManager.deleteMasterKey();
      setState(() {});
    }
  }

  // --- 機能検証ロジック ---
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

  /// バイト配列を完全な16進数文字列に変換する
  String _fullHex(List<int>? bytes) {
    if (bytes == null || bytes.isEmpty) return 'N/A';
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
  }

  /// 収集した鍵（1つ）を詳細表示するダイアログ
  void _showFullKeyDialog(BuildContext context, String title, List<int>? keyBytes) {
    if (keyBytes == null) return;
    final String fullHexKey = _fullHex(keyBytes);
    _showFullStringDialog(context, title, fullHexKey);
  }

  /// ★★★ マスターキー(String)表示用のダイアログを汎用化 ★★★
  void _showFullStringDialog(BuildContext context, String title, String? content) {
    if (content == null || content.isEmpty) {
      _showErrorSnackbar("キーがありません。");
      return;
    }

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
                SelectableText(
                  content,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('閉じる'),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      },
    );
  }

  /// 生成した鍵ペア（2つ）を詳細表示するダイアログ
  void _showGeneratedKeyDialog(BuildContext context, List<int>? pubKeyBytes, List<int>? secKeyBytes) {
    final String fullHexPub = _fullHex(pubKeyBytes);
    final String fullHexSec = _fullHex(secKeyBytes);

    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('生成済み鍵ペア'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('公開鍵 (Public Key):', style: TextStyle(fontWeight: FontWeight.bold)),
                SelectableText(
                  fullHexPub,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
                const SizedBox(height: 16),
                const Text('秘密鍵 (Secret Key):', style: TextStyle(fontWeight: FontWeight.bold)),
                SelectableText(
                  fullHexSec,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('閉じる'),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      },
    );
  }


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

  String _formatTime(dynamic unixTimeMs) {
    if (unixTimeMs == null) return "N/A";
    final dt = DateTime.fromMillisecondsSinceEpoch(unixTimeMs);
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

  Widget _buildMasterKeyCard() {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      color: Colors.indigo.shade50,
      elevation: 4,
      // InkWell を Card の子にして、Card の外観（影や丸み）を維持する
      child: FutureBuilder<String?>(
        future: _keyManager.getMasterKeyBase64(),
        builder: (context, snapshot) {
          final String? masterKeyBase64 = snapshot.data;

          return InkWell(
            borderRadius: BorderRadius.circular(12.0), // Cardの丸みに合わせる
            onTap: () {
              if (snapshot.connectionState == ConnectionState.done && masterKeyBase64 != null) {
                // タップしたら、新しく作った汎用ダイアログを呼び出す
                _showFullStringDialog(context, '🔑 マスターキー (Base64)', masterKeyBase64);
              } else if (snapshot.connectionState == ConnectionState.done) {
                _showErrorSnackbar("マスターキーはまだ保存されていません。");
              }
            },
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 40, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    // ★★★ mainAxisSize: MainAxisSize.min, を削除 ★★★
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
                      // FutureBuilder の中身は snapshot を利用して表示
                      if (snapshot.connectionState == ConnectionState.waiting)
                        const SizedBox(height: 20, child: LinearProgressIndicator())
                      else if (masterKeyBase64 != null)
                        SelectionArea(
                          child: Text(
                            masterKeyBase64,
                            style: const TextStyle(fontFamily: 'monospace'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        )
                      else
                        const Text('保存されていません', style: TextStyle(color: Colors.grey)),
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
        },
      ),
    );
  }

  Widget _buildVerificationTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ★ 追加：スロット選択UI
          _buildSlotSelector(),

          const SizedBox(height: 24),

          ElevatedButton.icon(
            onPressed: _testRandBytes,
            icon: const Icon(Icons.science_outlined),
            label: const Text('BoringSSLのRAND_bytesをテスト'),
          ),
          const SizedBox(height: 24),

          ElevatedButton.icon(
            onPressed: _isVerifying ? null : _performRingSignatureAndVerify,
            icon: _isVerifying
                ? Container(
              width: 24,
              height: 24,
              padding: const EdgeInsets.all(2),
              child: const CircularProgressIndicator(
                strokeWidth: 3,
                color: Colors.white,
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
    );
  }

  Widget _buildSlotSelector() {
    int current = _keyManager.slotMs;

    Widget buildSlotButton(String label, int value) {
      final bool selected = (current == value);

      return OutlinedButton(
        style: OutlinedButton.styleFrom(
          backgroundColor: selected ? Colors.blue : Colors.grey.shade200,
          foregroundColor: selected ? Colors.white : Colors.black87,
          side: BorderSide(
            color: selected ? Colors.blue : Colors.grey,
            width: selected ? 2 : 1,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
        onPressed: () {
          setState(() {
            _keyManager.slotMs = value;
          });
        },
        child: Text(label, style: const TextStyle(fontSize: 14)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "現在のスロット時間: ${_keyManager.slotMs} ms",
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          children: [
            buildSlotButton("10分", 10 * 60 * 1000),
            buildSlotButton("1分", 1 * 60 * 1000),
            buildSlotButton("1秒", 1000),
          ],
        ),
      ],
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
                    onPressed: () => _deleteAllKeys('collected_keys'),
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
                    child: InkWell( // Card の中身を InkWell で包む
                      borderRadius: BorderRadius.circular(12.0), // Card の丸みに合わせる
                      onTap: () {
                        // タップ時の動作
                        if (isGenerated) {
                          _showGeneratedKeyDialog(
                            context,
                            row['pubkey_ecd'] as List<int>?,
                            row['seckey_ecd'] as List<int>?,
                          );
                        } else {
                          _showFullKeyDialog(
                            context,
                            '収集した鍵',
                            row['pubkey_ecd'] as List<int>?,
                          );
                        }
                      },
                      child: Padding( // 元々 Card が持っていた Padding を InkWell の子にする
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
                              child: Text('Key: ${_shortHex(row['pubkey_ecd'] as List<int>?, length: 20)}',
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
                                Text(_formatTime(row['receive_time'])),
                              ])),
                            ]),
                          ],
                        ),
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
                _buildKeyListTab('collected_keys', false),
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