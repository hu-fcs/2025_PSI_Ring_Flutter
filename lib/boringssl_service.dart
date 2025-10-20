import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

// C: const char* SSLeay_version(int type);
typedef SsleayVersionC = Pointer<Utf8> Function(Int32 type);
typedef SsleayVersionDart = Pointer<Utf8> Function(int type);

// C: int RAND_bytes(unsigned char *buf, int num);
typedef RandBytesC = Int32 Function(Pointer<Uint8> buf, Int32 num);
typedef RandBytesDart = int Function(Pointer<Uint8> buf, int num);

/// BoringSSLライブラリと通信するためのサービスクラス
class BoringSSLService {
  late final SsleayVersionDart _ssleayVersion;
  late final RandBytesDart _randBytes;

  static const int ssleayVersionType = 0;

  BoringSSLService() {
    _loadLibrary();
  }

  /// libcrypto.soを動的に読み込み、関数をルックアップする
  void _loadLibrary() {
    final libName = Platform.isAndroid ? 'libcrypto.so' : 'crypto';
    final dylib = DynamicLibrary.open(libName);

    _ssleayVersion = dylib
        .lookup<NativeFunction<SsleayVersionC>>('SSLeay_version')
        .asFunction<SsleayVersionDart>();

    _randBytes = dylib
        .lookup<NativeFunction<RandBytesC>>('RAND_bytes')
        .asFunction<RandBytesDart>();
  }

  /// BoringSSLのバージョン文字列を取得する（旧テスト）
  String getVersion() {
    try {
      final Pointer<Utf8> versionStringPtr = _ssleayVersion(ssleayVersionType);
      final String version = versionStringPtr.toDartString();
      return version;
    } catch (e) {
      print('BoringSSL version check failed: $e');
      return 'Failed to get version';
    }
  }

  /// RAND_bytes関数をテストする（新テスト）
  String testRandomBytes() {
    // 16バイトのメモリ領域を確保
    final Pointer<Uint8> buffer = calloc<Uint8>(16);
    try {
      // CのRAND_bytes関数を呼び出す
      final int result = _randBytes(buffer, 16);

      if (result == 1) {
        // 成功！生成された乱数を16進数文字列に変換して表示
        final bytes = buffer.asTypedList(16);
        final hexString = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        return 'RAND_bytes 成功！ 生成データ: $hexString';
      } else {
        // 失敗！
        return 'RAND_bytes 失敗！ 戻り値: $result';
      }
    } catch (e) {
      return 'RAND_bytes 呼び出しで例外発生: $e';
    } finally {
      // 確保したメモリを必ず解放
      calloc.free(buffer);
    }
  }
}
