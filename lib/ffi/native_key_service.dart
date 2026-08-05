// lib/ffi/native_key_service.dart

import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'native_key_bindings.dart';

const int pubKeyCompressedLen = 33;
const int privateKeyLen = 32;

/// Flutter 側で扱う鍵ペア。
class NicknameKeyPair {
  final Uint8List privateKey;
  final Uint8List publicKey;
  NicknameKeyPair(this.privateKey, this.publicKey);
}

/// 鍵導出・PSI・リング署名をまとめた FFI サービス。
class NativeKeyService {
  static final NativeKeyService _instance = NativeKeyService._internal();
  factory NativeKeyService() => _instance;
  final _rand = Random.secure();

  late final NativeKeyBindings _bindings;

  NativeKeyService._internal() {
    try {
      const libName = 'psiring_auth';
      DynamicLibrary dylib;

      if (Platform.isAndroid || Platform.isLinux) {
        dylib = DynamicLibrary.open('lib$libName.so');
      } else if (Platform.isWindows) {
        dylib = DynamicLibrary.open('$libName.dll');
      } else {
        dylib = DynamicLibrary.process();
      }

      _bindings = NativeKeyBindings(dylib);

      // PSI の初期化（ECC グループ）
      _bindings.psi_init();

      if (kDebugMode) {
        debugPrint('[NativeKeyService] library loaded');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[NativeKeyService] failed to load native library: $e');
      }
    }
  }

  // ----- Key derivation -----

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

  NicknameKeyPair? deriveNewKeyPair(
      Uint8List masterKey,
      int timestampMs,
      int slotMs,
      ) {
    final masterPtr = calloc<Uint8>(masterKey.length);
    final privPtr = calloc<Uint8>(privateKeyLen);
    final pubPtr = calloc<Uint8>(pubKeyCompressedLen);

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
        return NicknameKeyPair(
          Uint8List.fromList(privPtr.asTypedList(privateKeyLen)),
          Uint8List.fromList(pubPtr.asTypedList(pubKeyCompressedLen)),
        );
      }
      return null;
    } finally {
      calloc.free(masterPtr);
      calloc.free(privPtr);
      calloc.free(pubPtr);
    }
  }

  // ----- PSI -----

  /// PSI の秘密スカラーを生成する。
  Uint8List generateRandomSecret() {
    final bytes = List<int>.generate(privateKeyLen, (_) => _rand.nextInt(256));
    return Uint8List.fromList(bytes);
  }

  /// 集合要素をスカラー倍して暗号化する（ecc_single_encrypt_set）。
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

      final ok =
      _bindings.ecc_single_encrypt_set(flatIn, count, secretPtr, flatOut);
      if (ok != 1 && kDebugMode) {
        debugPrint('[NativeKeyService] ecc_single_encrypt_set failed');
      }

      final result = <Uint8List>[];
      final typed = flatOut.asTypedList(count * pubKeyCompressedLen);
      for (int i = 0; i < count; i++) {
        result.add(
          Uint8List.fromList(
            typed.sublist(
              i * pubKeyCompressedLen,
              (i + 1) * pubKeyCompressedLen,
            ),
          ),
        );
      }
      return result;
    } finally {
      calloc.free(flatIn);
      calloc.free(flatOut);
      calloc.free(secretPtr);
    }
  }

  /// 共通集合を抽出する（ecc_intersect_sets）。
  List<Uint8List> intersect(
      List<Uint8List> originalKeys,
      List<Uint8List> myDoubleSet,
      List<Uint8List> remoteDoubleSet,
      ) {
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
        results.add(
          Uint8List.fromList(
            typed.sublist(
              i * pubKeyCompressedLen,
              (i + 1) * pubKeyCompressedLen,
            ),
          ),
        );
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

  // ----- Ring signature -----

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

  /// ECDSA チャレンジ署名 (secp256r1, 署名は r||s 形式の64バイト)
  ///
  /// [privKey32]  : 32バイトの秘密鍵
  /// [challenge]  : 任意長のチャレンジデータ（そのまま C 側で SHA-256 される想定）
  /// 戻り値      : 成功時は 64バイトの署名 (r||s)、失敗時は null
  Uint8List? signChallenge(Uint8List privKey32, Uint8List challenge) {
    if (privKey32.length != 32) {
      throw ArgumentError('privKey32 must be 32 bytes');
    }

    final privPtr = calloc<Uint8>(32);
    final msgPtr = calloc<Uint8>(challenge.length);
    final sigPtr = calloc<Uint8>(64);

    try {
      // Dart → C用バッファにコピー
      privPtr.asTypedList(32).setAll(0, privKey32);
      msgPtr.asTypedList(challenge.length).setAll(0, challenge);

      final ret = _bindings.ecdsa_sign_challenge(
        privPtr,
        msgPtr,
        challenge.length,
        sigPtr,
      );

      if (ret != 1) {
        // 署名失敗
        return null;
      }

      // 64バイトの署名 (r||s) を Dart に戻す
      return Uint8List.fromList(sigPtr.asTypedList(64));
    } finally {
      calloc.free(privPtr);
      calloc.free(msgPtr);
      calloc.free(sigPtr);
    }
  }
  /// ECDSA チャレンジ検証 (secp256r1, 署名は r||s 形式の64バイト)
  ///
  /// [pubKey33]     : 33バイト圧縮公開鍵
  /// [challenge]    : 署名時と同じチャレンジデータ
  /// [signature64]  : 64バイトの署名 (r||s)
  /// 戻り値        : 検証成功なら true, 失敗なら false
  bool verifyChallenge(
      Uint8List pubKey33,
      Uint8List challenge,
      Uint8List signature64,
      ) {
    if (pubKey33.length != 33) {
      throw ArgumentError('pubKey33 must be 33 bytes');
    }
    if (signature64.length != 64) {
      throw ArgumentError('signature64 must be 64 bytes (r||s)');
    }

    final pubPtr = calloc<Uint8>(33);
    final msgPtr = calloc<Uint8>(challenge.length);
    final sigPtr = calloc<Uint8>(64);

    try {
      pubPtr.asTypedList(33).setAll(0, pubKey33);
      msgPtr.asTypedList(challenge.length).setAll(0, challenge);
      sigPtr.asTypedList(64).setAll(0, signature64);

      final ret = _bindings.ecdsa_verify_challenge(
        pubPtr,
        msgPtr,
        challenge.length,
        sigPtr,
      );

      return ret == 1;
    } finally {
      calloc.free(pubPtr);
      calloc.free(msgPtr);
      calloc.free(sigPtr);
    }
  }

  /// OOB通信用のナンスの生成（Random.Secure()を使いまわしたいからここに追加）
  int generateOutOfBandNonce({min = 0, max = 0xffffffff}) {
    return min + _rand.nextInt(max - min + 1);
  }

}
