import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';                 // ← Random.secure() のために追加
import 'package:ffi/ffi.dart';

import 'native_key_bindings.dart';

// 定数
const int pubKeyCompressedLen = 33;
const int privateKeyLen = 32;

/// Flutter側で保持する鍵ペア（KeyManagementService が利用する）
class KeyPair {
  final Uint8List privateKey;
  final Uint8List publicKey;
  KeyPair(this.privateKey, this.publicKey);
}

/// PSI・鍵導出・リング署名をまとめた FFI サービス
class NativeKeyService {
  static final NativeKeyService _instance = NativeKeyService._internal();
  factory NativeKeyService() => _instance;

  late final NativeKeyBindings _bindings;

  NativeKeyService._internal() {
    try {
      const libName = 'psiring_auth';
      DynamicLibrary dylib;

      if (Platform.isAndroid || Platform.isLinux) {
        dylib = DynamicLibrary.open('lib$libName.so');
      } else if (Platform.isWindows) {
        dylib = DynamicLibrary.open('$libName.dll');
      } else if (Platform.isMacOS || Platform.isIOS) {
        dylib = DynamicLibrary.open('lib$libName.dylib');
      } else {
        dylib = DynamicLibrary.process();
      }

      _bindings = NativeKeyBindings(dylib);

      _bindings.psi_init(); // ECC グループ初期化

      print('[NativeKeyService] Library loaded and initialized.');
    } catch (e) {
      print('❌ Failed to load native library: $e');
    }
  }

  // ============================================================
  //  1. マスターキー生成 (KeyManagementService が利用)
  // ============================================================
  Uint8List? generateMasterKey() {
    final ptr = calloc<Uint8>(privateKeyLen);
    try {
      final ok = _bindings.generate_master_key(ptr);
      if (ok == 1) {
        return Uint8List.fromList(ptr.asTypedList(privateKeyLen));
      }
      return null;
    } finally {
      calloc.free(ptr);
    }
  }

  // ============================================================
  //  2. マスターキー + timestamp → 秘密鍵・公開鍵派生
  // ============================================================
  KeyPair? deriveNewKeyPair(Uint8List masterKey, int timestampMs, int slotMs) {
    final masterPtr = calloc<Uint8>(masterKey.length);
    final privPtr = calloc<Uint8>(32);
    final pubPtr = calloc<Uint8>(33);

    try {
      masterPtr.asTypedList(masterKey.length).setAll(0, masterKey);

      final ok = _bindings.derive_keypair_from_timestamp(
        masterPtr,
        timestampMs,
        slotMs,
        privPtr,
        pubPtr,
      );

      if (ok == 1) {
        return KeyPair(
          Uint8List.fromList(privPtr.asTypedList(32)),
          Uint8List.fromList(pubPtr.asTypedList(33)),
        );
      }
      return null;
    } finally {
      calloc.free(masterPtr);
      calloc.free(privPtr);
      calloc.free(pubPtr);
    }
  }

  // ============================================================
  //  3. PSI用秘密スカラー生成（Dart側 Random.secure()）
  // ============================================================
  Uint8List generateRandomSecret() {
    final rand = Random.secure();
    final bytes = List<int>.generate(32, (_) => rand.nextInt(256));
    return Uint8List.fromList(bytes);
  }

  // ============================================================
  //  4. PSI: aP / bQ の暗号化 (ecc_single_encrypt_set)
  // ============================================================
  List<Uint8List> encryptSet(List<Uint8List> inputs, Uint8List secret) {
    final count = inputs.length;
    final flatIn = calloc<Uint8>(count * pubKeyCompressedLen);
    final flatOut = calloc<Uint8>(count * pubKeyCompressedLen);
    final secretPtr = calloc<Uint8>(privateKeyLen);

    try {
      for (int i = 0; i < privateKeyLen; i++) {
        secretPtr[i] = secret[i];
      }
      for (int i = 0; i < count; i++) {
        for (int j = 0; j < pubKeyCompressedLen; j++) {
          flatIn[i * pubKeyCompressedLen + j] = inputs[i][j];
        }
      }

      final ok = _bindings.ecc_single_encrypt_set(flatIn, count, secretPtr, flatOut);
      if (ok != 1) {
        print('❌ ecc_single_encrypt_set failed');
      }

      final result = <Uint8List>[];
      final typed = flatOut.asTypedList(count * pubKeyCompressedLen);
      for (int i = 0; i < count; i++) {
        result.add(Uint8List.fromList(
          typed.sublist(i * pubKeyCompressedLen, (i + 1) * pubKeyCompressedLen),
        ));
      }
      return result;
    } finally {
      calloc.free(flatIn);
      calloc.free(flatOut);
      calloc.free(secretPtr);
    }
  }

  // ============================================================
  //  5. PSI: 共通集合抽出 (ecc_intersect_sets)
  // ============================================================
  List<Uint8List> intersect(
      List<Uint8List> originalKeys,
      List<Uint8List> myDoubleSet,
      List<Uint8List> remoteDoubleSet) {

    final countA = originalKeys.length;
    final countB = remoteDoubleSet.length;

    final flatOrig = calloc<Uint8>(countA * pubKeyCompressedLen);
    final flatMine = calloc<Uint8>(countA * pubKeyCompressedLen);
    final flatRemote = calloc<Uint8>(countB * pubKeyCompressedLen);
    final flatResult = calloc<Uint8>(countA * pubKeyCompressedLen);
    final resultCountPtr = calloc<Int32>();

    try {
      for (int i = 0; i < countA; i++) {
        for (int j = 0; j < pubKeyCompressedLen; j++) {
          flatOrig[i * pubKeyCompressedLen + j] = originalKeys[i][j];
          flatMine[i * pubKeyCompressedLen + j] = myDoubleSet[i][j];
        }
      }
      for (int i = 0; i < countB; i++) {
        for (int j = 0; j < pubKeyCompressedLen; j++) {
          flatRemote[i * pubKeyCompressedLen + j] = remoteDoubleSet[i][j];
        }
      }

      _bindings.ecc_intersect_sets(
        flatOrig,
        flatMine,
        flatRemote,
        countA,
        countB,
        flatResult,
        resultCountPtr,
      );

      final found = resultCountPtr.value;
      final results = <Uint8List>[];

      final typed = flatResult.asTypedList(countA * pubKeyCompressedLen);
      for (int i = 0; i < found; i++) {
        results.add(Uint8List.fromList(
          typed.sublist(i * pubKeyCompressedLen, (i + 1) * pubKeyCompressedLen),
        ));
      }

      return results;

    } finally {
      calloc.free(flatOrig);
      calloc.free(flatMine);
      calloc.free(flatRemote);
      calloc.free(flatResult);
      calloc.free(resultCountPtr);
    }
  }

  // ============================================================
  //  6. リング署名 (既存のまま)
  // ============================================================
  int createRingSignature(
      Pointer<Char> msg,
      int msgLen,
      Pointer<Uint8> privateKey,
      Pointer<Uint8> ringPublicKeys,
      int ringSize,
      Pointer<Uint8> signatureOut) {
    return _bindings.create_ring_signature(
        msg, msgLen, privateKey, ringPublicKeys, ringSize, signatureOut);
  }

  int verifyRingSignature(
      Pointer<Char> msg,
      int msgLen,
      Pointer<Uint8> signature,
      Pointer<Uint8> ringPublicKeys,
      int ringSize) {
    return _bindings.verify_ring_signature(
        msg, msgLen, signature, ringPublicKeys, ringSize);
  }
}
