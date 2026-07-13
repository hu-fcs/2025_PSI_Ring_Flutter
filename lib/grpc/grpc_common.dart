// lib/grpc/grpc_common.dart

import 'dart:typed_data';
import 'package:grpc/grpc.dart';

/// gRPC の共通設定・ユーティリティ。
class GrpcCommon {
  // ----- Singleton -----

  static final GrpcCommon _instance = GrpcCommon._internal();
  factory GrpcCommon() => _instance;
  GrpcCommon._internal();

  /// 圧縮（gzip）の有効化フラグ
  bool enableGzip = false;

  // ----- TLS -----

  /// TLS を使用しないため何もしない（互換のため残す）。
  Future<void> ensureTlsAssetsLoaded() async {}

  // ----- Codec / Options -----

  CodecRegistry get codecRegistry => CodecRegistry(
    codecs: enableGzip
        ? const [GzipCodec(), IdentityCodec()]
        : const [IdentityCodec()],
  );

  ChannelOptions buildClientOptions({Duration? idleTimeout}) {
    return ChannelOptions(
      credentials: ChannelCredentials.insecure(),
      codecRegistry: codecRegistry,
      idleTimeout: idleTimeout,
    );
  }

  ServerTlsCredentials? buildServerSecurity() {
    return null;
  }

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
