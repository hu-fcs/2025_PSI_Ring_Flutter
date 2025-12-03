import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'native_key_bindings.dart';

// 定数定義
const int pubKeyCompressedLen = 33;
const int privateKeyLen = 32;

/// 生成された鍵ペアを保持するヘルパークラス
class KeyPair {
  final Uint8List privateKey;
  final Uint8List publicKey;
  KeyPair(this.privateKey, this.publicKey);
}

/// C言語の関数を呼び出すためのサービスクラス (Singleton)
class NativeKeyService {
  static final NativeKeyService _instance = NativeKeyService._internal();
  factory NativeKeyService() => _instance;

  late final NativeKeyBindings _bindings;
  // ignore: unused_field
  bool _isInitialized = false;

  NativeKeyService._internal() {
    try {
      const libName = 'psiring_auth'; // CMakeで指定したライブラリ名
      DynamicLibrary dylib;

      if (Platform.isAndroid || Platform.isLinux) {
        dylib = DynamicLibrary.open('lib$libName.so');
      } else if (Platform.isWindows) {
        dylib = DynamicLibrary.open('$libName.dll');
      } else if (Platform.isMacOS) {
        dylib = DynamicLibrary.open('lib$libName.dylib');
      } else {
        dylib = DynamicLibrary.process();
      }

      _bindings = NativeKeyBindings(dylib);

      // PSI用の初期化もここで行っておく
      _bindings.psi_init();
      _isInitialized = true;
      print('[NativeKeyService] Library loaded and initialized.');

    } catch (e) {
      print('🔥 Critical Error: Failed to load native library: $e');
    }
  }

  // --- 既存メソッド ---

  Uint8List? generateMasterKey() {
    final keyPtr = calloc<Uint8>(32);
    try {
      final result = _bindings.generate_master_key(keyPtr);
      if (result == 1) {
        return Uint8List.fromList(keyPtr.asTypedList(32));
      }
      return null;
    } finally {
      calloc.free(keyPtr);
    }
  }

  KeyPair? deriveNewKeyPair(Uint8List masterKey, int timestamp, int slotMs) {
    final masterKeyPtr = calloc<Uint8>(masterKey.length);
    final privKeyPtr = calloc<Uint8>(32);
    final pubKeyPtr = calloc<Uint8>(33);

    try {
      masterKeyPtr.asTypedList(masterKey.length).setAll(0, masterKey);
      final result = _bindings.derive_keypair_from_timestamp(
        masterKeyPtr,
        timestamp,
        slotMs,
        privKeyPtr,
        pubKeyPtr,
      );
      if (result == 1) {
        return KeyPair(
          Uint8List.fromList(privKeyPtr.asTypedList(32)),
          Uint8List.fromList(pubKeyPtr.asTypedList(33)),
        );
      }
      return null;
    } finally {
      calloc.free(masterKeyPtr);
      calloc.free(privKeyPtr);
      calloc.free(pubKeyPtr);
    }
  }

  int createRingSignature(
      Pointer<Char> msg,
      int msgLen,
      Pointer<Uint8> privateKey,
      Pointer<Uint8> ringPublicKeys,
      int ringSize,
      Pointer<Uint8> signatureOut,
      ) {
    return _bindings.create_ring_signature(
      msg,
      msgLen,
      privateKey,
      ringPublicKeys,
      ringSize,
      signatureOut,
    );
  }

  int verifyRingSignature(
      Pointer<Char> msg,
      int msgLen,
      Pointer<Uint8> signature,
      Pointer<Uint8> ringPublicKeys,
      int ringSize,
      ) {
    return _bindings.verify_ring_signature(
      msg,
      msgLen,
      signature,
      ringPublicKeys,
      ringSize,
    );
  }

  // --- PSI用メソッド ---

  /// ランダムな32バイト(秘密スカラー等)を生成
  Uint8List generateRandomSecret() {
    final ptr = calloc<Uint8>(privateKeyLen);
    _bindings.generate_master_key(ptr);
    final bytes = Uint8List.fromList(ptr.asTypedList(privateKeyLen));
    calloc.free(ptr);
    return bytes;
  }

  /// PSIデモ用: 鍵リストを生成 (圧縮形式33バイトのリスト)
  List<Uint8List> generateKeysForPsi(int count, int realKeyIndex) {
    final masterKeyPtr = calloc<Uint8>(privateKeyLen);
    _bindings.generate_master_key(masterKeyPtr);

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final slotMs = 600000;

    final List<Uint8List> keys = [];
    final outPriv = calloc<Uint8>(privateKeyLen);
    final outPub = calloc<Uint8>(pubKeyCompressedLen);

    try {
      for (int i = 0; i < count; i++) {
        if (i == realKeyIndex) {
          _bindings.derive_keypair_from_timestamp(masterKeyPtr, nowMs, slotMs, outPriv, outPub);
          keys.add(Uint8List.fromList(outPub.asTypedList(pubKeyCompressedLen)));
        } else {
          _bindings.generate_random_dummy_key_bytes(outPub);
          keys.add(Uint8List.fromList(outPub.asTypedList(pubKeyCompressedLen)));
        }
      }
    } finally {
      calloc.free(masterKeyPtr);
      calloc.free(outPriv);
      calloc.free(outPub);
    }
    return keys;
  }

  /// 鍵セットの暗号化 / 再暗号化
  List<Uint8List> encryptSet(List<Uint8List> inputs, Uint8List secret) {
    final count = inputs.length;
    final flatInput = calloc<Uint8>(count * pubKeyCompressedLen);
    final flatOutput = calloc<Uint8>(count * pubKeyCompressedLen);
    final secretPtr = calloc<Uint8>(privateKeyLen);

    try {
      for (int i = 0; i < count; i++) {
        for (int j = 0; j < pubKeyCompressedLen; j++) {
          flatInput[i * pubKeyCompressedLen + j] = inputs[i][j];
        }
      }
      for (int i = 0; i < privateKeyLen; i++) secretPtr[i] = secret[i];

      _bindings.ecc_single_encrypt_set(flatInput, count, secretPtr, flatOutput);

      List<Uint8List> results = [];
      for (int i = 0; i < count; i++) {
        results.add(Uint8List.fromList(
            flatOutput.asTypedList(count * pubKeyCompressedLen)
                .sublist(i * pubKeyCompressedLen, (i + 1) * pubKeyCompressedLen)
        ));
      }
      return results;
    } finally {
      calloc.free(flatInput);
      calloc.free(flatOutput);
      calloc.free(secretPtr);
    }
  }

  /// 共通集合の抽出 (PSI)
  List<Uint8List> intersect(
      List<Uint8List> originalKeys,
      List<Uint8List> myDoubleSet,
      List<Uint8List> remoteDoubleSet
      ) {
    final countA = originalKeys.length;
    final countB = remoteDoubleSet.length;

    final flatOriginal = calloc<Uint8>(countA * pubKeyCompressedLen);
    final flatMyDouble = calloc<Uint8>(countA * pubKeyCompressedLen);
    final flatRemoteDouble = calloc<Uint8>(countB * pubKeyCompressedLen);
    final flatResult = calloc<Uint8>(countA * pubKeyCompressedLen);
    final resultCountPtr = calloc<Int32>();

    try {
      // データコピー
      for(int i=0; i<countA; i++) {
        for(int j=0; j<pubKeyCompressedLen; j++) {
          flatOriginal[i*pubKeyCompressedLen + j] = originalKeys[i][j];
          flatMyDouble[i*pubKeyCompressedLen + j] = myDoubleSet[i][j];
        }
      }
      for(int i=0; i<countB; i++) {
        for(int j=0; j<pubKeyCompressedLen; j++) {
          flatRemoteDouble[i*pubKeyCompressedLen + j] = remoteDoubleSet[i][j];
        }
      }

      // ★修正箇所: 第3引数に flatRemoteDouble (Pointer) を渡す
      _bindings.ecc_intersect_sets(
          flatOriginal,
          flatMyDouble,
          flatRemoteDouble, // ← ここを修正しました (元は remoteDoubleSet だった)
          countA,
          countB,
          flatResult,
          resultCountPtr
      );

      int foundCount = resultCountPtr.value;
      List<Uint8List> intersections = [];
      for (int i = 0; i < foundCount; i++) {
        intersections.add(Uint8List.fromList(
            flatResult.asTypedList(countA * pubKeyCompressedLen)
                .sublist(i * pubKeyCompressedLen, (i + 1) * pubKeyCompressedLen)
        ));
      }
      return intersections;

    } finally {
      calloc.free(flatOriginal);
      calloc.free(flatMyDouble);
      calloc.free(flatRemoteDouble);
      calloc.free(flatResult);
      calloc.free(resultCountPtr);
    }
  }
}