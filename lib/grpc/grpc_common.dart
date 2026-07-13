// lib/grpc/grpc_common.dart

import 'dart:typed_data';
import 'package:grpc/grpc.dart';
import 'package:flutter/services.dart' show rootBundle;

/// gRPC の共通設定・ユーティリティ。
class GrpcCommon {
  /// シングルトン
  static final GrpcCommon _instance = GrpcCommon._internal();
  factory GrpcCommon() => _instance;
  GrpcCommon._internal() {
    isInitialized = _initialize(); // await GrpcCommon().isInitialized で初期化完了を待つ
  }

  /// 自己証明書
  late final Uint8List _crtBytes;
  /// 自己証明書の鍵
  late final Uint8List _keyBytes;

  /// 自己証明書を読み込みを await _isLoaded で待つ
  late final Future<void> isInitialized;
  Future<void> _initialize() async {
    final crtData = await rootBundle.load('assets/grpc/server.crt');
    _crtBytes = crtData.buffer.asUint8List();

    final keyData = await rootBundle.load('assets/grpc/server.key');
    _keyBytes = keyData.buffer.asUint8List();
  }

  /// 圧縮（gzip）の有効化フラグ
  bool enableGzip = false;

  // ----- Codec / Options -----

  CodecRegistry get codecRegistry => CodecRegistry(
    codecs: enableGzip
        ? const [GzipCodec(), IdentityCodec()]
        : const [IdentityCodec()],
  );

  // 呼び出し元は await GrpcCommon().isInitialized; で初期化を待つこと
  ChannelOptions buildClientOptions({Duration? idleTimeout}) {
    final channelCredentials = ChannelCredentials.secure(
        certificates: _crtBytes,
        authority: 'application.local'
    );
    return ChannelOptions(
        credentials: channelCredentials, // ChannelCredentials.insecure(),
        codecRegistry: codecRegistry,
        idleTimeout: idleTimeout,
    );
  }

  ServerTlsCredentials get serverTlsCredentials => ServerTlsCredentials(
    certificate: _crtBytes,
    privateKey: _keyBytes,
  ); // 読み出し元で await GrpcCommon().isInitialized; で初期化を待つこと

  // ----- Utils -----

  /// Uint8List を hex 文字列へ変換する。
  static String bytesToHex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  /// 公開鍵(33B)の辞書順比較（リング署名用の正規順序）。
  static int comparePubKey(Uint8List a, Uint8List b) {
    final n = a.length < b.length ? a.length : b.length;
    for (int i = 0; i < n; i++) {
      final d = a[i] - b[i];
      if (d != 0) return d;
    }
    return a.length - b.length;
  }
}

/// PSI の結果（client/server 共通）。
class PsiResult {
  final bool isFamiliar;

  /// 集合サイズ |S_A|, |S_B|
  final int saKeyCount;
  final int sbKeyCount;

  /// 互換用（= |S_A| + |S_B|）
  int get psiKeyCount => saKeyCount + sbKeyCount;

  final List<String> commonKeys;
  final int ringSize;

  final int dbLoadTimeMs;
  final int psiTimeMs;

  final int ringSelectTimeMs;
  final int ringSigTimeMs;
  final int totalTimeMs;

  PsiResult({
    required this.isFamiliar,
    required this.saKeyCount,
    required this.sbKeyCount,
    required this.commonKeys,
    required this.ringSize,
    required this.dbLoadTimeMs,
    required this.psiTimeMs,
    required this.ringSelectTimeMs,
    required this.ringSigTimeMs,
    required this.totalTimeMs,
  });
}
