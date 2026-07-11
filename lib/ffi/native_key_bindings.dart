// lib/ffi/native_key_bindings.dart
import 'dart:ffi' as ffi;

/// C 関数を Dart から呼び出すための FFI バインディング。
///
/// シンボル名・引数は各ヘッダ（key_derivation.h / ring_signature.h / psi.h）に合わせる。
class NativeKeyBindings {
  final ffi.Pointer<T> Function<T extends ffi.NativeType>(String symbolName)
  _lookup;

  NativeKeyBindings(ffi.DynamicLibrary dynamicLibrary)
      : _lookup = dynamicLibrary.lookup;

  // ----- Key derivation (key_derivation.h) -----

  int generate_master_key(ffi.Pointer<ffi.Uint8> outMasterKey) {
    return _generate_master_key(outMasterKey);
  }

  late final _generate_master_keyPtr =
  _lookup<ffi.NativeFunction<ffi.Int Function(ffi.Pointer<ffi.Uint8>)>>(
      'generate_master_key');
  late final _generate_master_key =
  _generate_master_keyPtr.asFunction<int Function(ffi.Pointer<ffi.Uint8>)>();

  int derive_keypair_from_timestamp(
      ffi.Pointer<ffi.Uint8> masterKey,
      int timestampMs,
      int slotMs,
      ffi.Pointer<ffi.Uint8> outPriv,
      ffi.Pointer<ffi.Uint8> outPub,
      ) {
    return _derive_keypair_from_timestamp(
      masterKey,
      timestampMs,
      slotMs,
      outPriv,
      outPub,
    );
  }

  late final _derive_keypair_from_timestampPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int Function(
              ffi.Pointer<ffi.Uint8>, // master_key
              ffi.Uint64, // timestamp_ms
              ffi.Uint64, // slot_ms
              ffi.Pointer<ffi.Uint8>, // out_priv_key_32b
              ffi.Pointer<ffi.Uint8>, // out_pub_key_33b
              )>>('derive_keypair_from_timestamp');

  late final _derive_keypair_from_timestamp =
  _derive_keypair_from_timestampPtr.asFunction<
      int Function(
          ffi.Pointer<ffi.Uint8>,
          int,
          int,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.Uint8>,
          )>();

  // ----- Ring signature (ring_signature.h) -----

  int create_ring_signature(
      ffi.Pointer<ffi.Char> msg,
      int msgLen,
      ffi.Pointer<ffi.Uint8> signerPrivKey,
      ffi.Pointer<ffi.Uint8> ringPubKeys,
      int ringSize,
      ffi.Pointer<ffi.Uint8> outSignature,
      ) {
    return _create_ring_signature(
      msg,
      msgLen,
      signerPrivKey,
      ringPubKeys,
      ringSize,
      outSignature,
    );
  }

  late final _create_ring_signaturePtr = _lookup<
      ffi.NativeFunction<
          ffi.Int Function(
              ffi.Pointer<ffi.Char>,
              ffi.Size,
              ffi.Pointer<ffi.Uint8>,
              ffi.Pointer<ffi.Uint8>,
              ffi.Int,
              ffi.Pointer<ffi.Uint8>,
              )>>('create_ring_signature');

  late final _create_ring_signature = _create_ring_signaturePtr.asFunction<
      int Function(
          ffi.Pointer<ffi.Char>,
          int,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          )>();

  int verify_ring_signature(
      ffi.Pointer<ffi.Char> msg,
      int msgLen,
      ffi.Pointer<ffi.Uint8> signature,
      ffi.Pointer<ffi.Uint8> ringPubKeys,
      int ringSize,
      ) {
    return _verify_ring_signature(
      msg,
      msgLen,
      signature,
      ringPubKeys,
      ringSize,
    );
  }

  late final _verify_ring_signaturePtr = _lookup<
      ffi.NativeFunction<
          ffi.Int Function(
              ffi.Pointer<ffi.Char>,
              ffi.Size,
              ffi.Pointer<ffi.Uint8>,
              ffi.Pointer<ffi.Uint8>,
              ffi.Int,
              )>>('verify_ring_signature');

  late final _verify_ring_signature = _verify_ring_signaturePtr.asFunction<
      int Function(
          ffi.Pointer<ffi.Char>,
          int,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.Uint8>,
          int,
          )>();

  // ----- PSI (psi.h) -----

  int psi_init() => _psi_init();
  late final _psi_initPtr =
  _lookup<ffi.NativeFunction<ffi.Int Function()>>('psi_init');
  late final _psi_init = _psi_initPtr.asFunction<int Function()>();

  void psi_cleanup() => _psi_cleanup();
  late final _psi_cleanupPtr =
  _lookup<ffi.NativeFunction<ffi.Void Function()>>('psi_cleanup');
  late final _psi_cleanup = _psi_cleanupPtr.asFunction<void Function()>();

  int ecc_single_encrypt_set(
      ffi.Pointer<ffi.Uint8> inputKeys,
      int count,
      ffi.Pointer<ffi.Uint8> secret32,
      ffi.Pointer<ffi.Uint8> outKeys,
      ) {
    return _ecc_single_encrypt_set(inputKeys, count, secret32, outKeys);
  }

  late final _ecc_single_encrypt_setPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int Function(
              ffi.Pointer<ffi.Uint8>,
              ffi.Int32,
              ffi.Pointer<ffi.Uint8>,
              ffi.Pointer<ffi.Uint8>,
              )>>('ecc_single_encrypt_set');

  late final _ecc_single_encrypt_set =
  _ecc_single_encrypt_setPtr.asFunction<
      int Function(
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.Uint8>,
          )>();

  int ecc_intersect_sets(
      ffi.Pointer<ffi.Uint8> original,
      ffi.Pointer<ffi.Uint8> myDouble,
      ffi.Pointer<ffi.Uint8> remoteDouble,
      int countA,
      int countB,
      ffi.Pointer<ffi.Uint8> result,
      ffi.Pointer<ffi.Int32> resultCount,
      ) {
    return _ecc_intersect_sets(
      original,
      myDouble,
      remoteDouble,
      countA,
      countB,
      result,
      resultCount,
    );
  }

  late final _ecc_intersect_setsPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int Function(
              ffi.Pointer<ffi.Uint8>, // original_keys
              ffi.Pointer<ffi.Uint8>, // my_double_set
              ffi.Pointer<ffi.Uint8>, // remote_double_set
              ffi.Int32, // count_a
              ffi.Int32, // count_b
              ffi.Pointer<ffi.Uint8>, // result_keys
              ffi.Pointer<ffi.Int32>, // result_count
              )>>('ecc_intersect_sets');

  late final _ecc_intersect_sets =
  _ecc_intersect_setsPtr.asFunction<
      int Function(
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.Uint8>,
          int,
          int,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.Int32>,
          )>();
  /// ECDSA チャレンジ署名 (secp256r1, 署名は r||s の 64バイト)
  ///
  /// C 側シグネチャ:
  /// int ecdsa_sign_challenge(
  ///   const uint8_t* priv_key_32b,
  ///   const uint8_t* msg,
  ///   uint32_t msg_len,
  ///   uint8_t* out_sig64
  /// );
  int ecdsa_sign_challenge(
      ffi.Pointer<ffi.Uint8> priv_key_32b,
      ffi.Pointer<ffi.Uint8> msg,
      int msg_len,
      ffi.Pointer<ffi.Uint8> out_sig64,
      ) {
    return _ecdsa_sign_challenge(
      priv_key_32b,
      msg,
      msg_len,
      out_sig64,
    );
  }

  /// ECDSA チャレンジ検証 (secp256r1, 署名は r||s の 64バイト)
  ///
  /// C 側シグネチャ:
  /// int ecdsa_verify_challenge(
  ///   const uint8_t* pub_key_33b,
  ///   const uint8_t* msg,
  ///   uint32_t msg_len,
  ///   const uint8_t* sig64
  /// );
  int ecdsa_verify_challenge(
      ffi.Pointer<ffi.Uint8> pub_key_33b,
      ffi.Pointer<ffi.Uint8> msg,
      int msg_len,
      ffi.Pointer<ffi.Uint8> sig64,
      ) {
    return _ecdsa_verify_challenge(
      pub_key_33b,
      msg,
      msg_len,
      sig64,
    );
  }
  // C: int ecdsa_sign_challenge(
  //      const uint8_t* priv_key_32b,
  //      const uint8_t* msg,
  //      uint32_t msg_len,
  //      uint8_t* out_sig64);
  late final _ecdsa_sign_challengePtr = _lookup<
      ffi.NativeFunction<
          ffi.Int Function(
              ffi.Pointer<ffi.Uint8>, // priv_key_32b
              ffi.Pointer<ffi.Uint8>, // msg
              ffi.Uint32,             // msg_len
              ffi.Pointer<ffi.Uint8>, // out_sig64 (64 bytes)
              )>>('ecdsa_sign_challenge');

  late final _ecdsa_sign_challenge =
  _ecdsa_sign_challengePtr.asFunction<
      int Function(
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          )>();

  // C: int ecdsa_verify_challenge(
  //      const uint8_t* pub_key_33b,
  //      const uint8_t* msg,
  //      uint32_t msg_len,
  //      const uint8_t* sig64);
  late final _ecdsa_verify_challengePtr = _lookup<
      ffi.NativeFunction<
          ffi.Int Function(
              ffi.Pointer<ffi.Uint8>, // pub_key_33b
              ffi.Pointer<ffi.Uint8>, // msg
              ffi.Uint32,             // msg_len
              ffi.Pointer<ffi.Uint8>, // sig64 (64 bytes)
              )>>('ecdsa_verify_challenge');

  late final _ecdsa_verify_challenge =
  _ecdsa_verify_challengePtr.asFunction<
      int Function(
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          )>();
}
