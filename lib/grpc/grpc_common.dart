import 'dart:typed_data';
import 'package:grpc/grpc.dart';

/// ===============================================================
/// gRPC 共通設定・モデル・ユーティリティ
/// ===============================================================
class GrpcCommon {
  // ===============================
  // Singleton
  // ===============================
  static final GrpcCommon _instance = GrpcCommon._internal();
  factory GrpcCommon() => _instance;
  GrpcCommon._internal();

  // ===============================
  // 計測用フラグ
  // ===============================
  bool enableGzip = false;
  bool enableTls = false;

  // ===============================
  // CodecRegistry
  // ===============================
  CodecRegistry get codecRegistry => CodecRegistry(
    codecs: enableGzip
        ? const [GzipCodec(), IdentityCodec()]
        : const [IdentityCodec()],
  );

  // ===============================
  // Client 用 ChannelOptions
  // ===============================
  ChannelOptions buildClientOptions({Duration? idleTimeout}) {
    return ChannelOptions(
      credentials: enableTls
          ? ChannelCredentials.secure()
          : ChannelCredentials.insecure(),
      codecRegistry: codecRegistry,
      idleTimeout: idleTimeout,
    );
  }

  // ===============================
  // Server 用 TLS 設定
  // ===============================
  ServerTlsCredentials? buildServerSecurity({
    required List<int> certificate,
    required List<int> privateKey,
  }) {
    if (!enableTls) return null;
    return ServerTlsCredentials(
      certificate: certificate,
      privateKey: privateKey,
    );
  }

  // ===============================================================
  // ===== 以下：共通モデル / ユーティリティ =====
  // ===============================================================

  /// Uint8List -> hex 文字列
  static String bytesToHex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  /// 33バイト公開鍵の辞書順比較（リング署名用の正規順序）
  static int comparePubKey(Uint8List a, Uint8List b) {
    final n = a.length < b.length ? a.length : b.length;
    for (int i = 0; i < n; i++) {
      final d = a[i] - b[i];
      if (d != 0) return d;
    }
    return a.length - b.length;
  }
}

/// ===============================================================
/// PSI の結果（client / server 共通）
/// ===============================================================
class PsiResult {
  final bool isFamiliar;
  final int psiKeyCount;
  final List<String> commonKeys;
  final int ringSize;
  final int psiTimeMs;
  final int ringSigTimeMs;
  final int totalTimeMs;

  PsiResult({
    required this.isFamiliar,
    required this.psiKeyCount,
    required this.commonKeys,
    required this.ringSize,
    required this.psiTimeMs,
    required this.ringSigTimeMs,
    required this.totalTimeMs,
  });
}
