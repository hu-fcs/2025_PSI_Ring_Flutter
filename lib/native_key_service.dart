import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'native_key_bindings.dart';

// KeyPairクラスをトップレベルに移動
class KeyPair {
  final Uint8List privateKey;
  final Uint8List publicKey;
  KeyPair(this.privateKey, this.publicKey);
}

class NativeKeyService {
  late final NativeKeyBindings _bindings;

  NativeKeyService() {
    final dylib = DynamicLibrary.open('libkey_derivation.so');
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

  KeyPair? deriveNewKeyPair(Uint8List masterKey, int timestamp) {
    final masterKeyPtr = calloc<Uint8>(masterKey.length);
    final privKeyPtr = calloc<Uint8>(32);
    final pubKeyPtr = calloc<Uint8>(65);

    try {
      masterKeyPtr.asTypedList(masterKey.length).setAll(0, masterKey);
      final result = _bindings.derive_keypair_from_timestamp(
        masterKeyPtr,
        timestamp,
        privKeyPtr,
        pubKeyPtr,
      );
      if (result == 1) {
        // KeyPairクラスを正しく呼び出す
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
}