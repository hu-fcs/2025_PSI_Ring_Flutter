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
    final pubKeyPtr = calloc<Uint8>(65);

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
          Uint8List.fromList(pubKeyPtr.asTypedList(65)),
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
}
