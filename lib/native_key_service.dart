import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'native_key_bindings.dart';

/// 生成された鍵ペアを保持するヘルパークラス
class KeyPair {
  final Uint8List privateKey;
  final Uint8List publicKey;
  KeyPair(this.privateKey, this.publicKey);
}

/// C言語の関数を呼び出すためのサービスクラス
class NativeKeyService {
  late final NativeKeyBindings _bindings;

  NativeKeyService() {
    const libName = 'psiring_auth';
    final dylib = Platform.isAndroid || Platform.isLinux
        ? DynamicLibrary.open('lib$libName.so')
        : (Platform.isWindows
        ? DynamicLibrary.open('$libName.dll')
        : DynamicLibrary.process());
    _bindings = NativeKeyBindings(dylib);
  }

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

  // --- ★ここから新しいメソッド★ ---

  /// Cの 'verify_ring_signature' 関数を呼び出す
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
// --- ★ここまで新しいメソッド★ ---
// --- ★ここから ECDSA メソッド★ ---
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
// --- ★ここまで ECDSA メソッド★ ---
}
