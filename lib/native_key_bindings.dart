import 'dart:ffi' as ffi;

/// C言語の関数をDartから呼ぶためのバインディング定義
class NativeKeyBindings {
  final ffi.Pointer<T> Function<T extends ffi.NativeType>(String symbolName) _lookup;

  NativeKeyBindings(ffi.DynamicLibrary dynamicLibrary) : _lookup = dynamicLibrary.lookup;

  // --- 既存の Key Derivation / Ring Signature 関連 ---

  int generate_master_key(ffi.Pointer<ffi.Uint8> out_master_key_32b) {
    return _generate_master_key(out_master_key_32b);
  }
  late final _generate_master_keyPtr = _lookup<ffi.NativeFunction<ffi.Int Function(ffi.Pointer<ffi.Uint8>)>>('generate_master_key');
  late final _generate_master_key = _generate_master_keyPtr.asFunction<int Function(ffi.Pointer<ffi.Uint8>)>();

  int derive_keypair_from_timestamp(
      ffi.Pointer<ffi.Uint8> master_key,
      int timestamp_ms,
      int slot_ms,
      ffi.Pointer<ffi.Uint8> out_priv_key_32b,
      ffi.Pointer<ffi.Uint8> out_pub_key_33b,
      ) {
    return _derive_keypair_from_timestamp(
      master_key,
      timestamp_ms,
      slot_ms,
      out_priv_key_32b,
      out_pub_key_33b,
    );
  }
  late final _derive_keypair_from_timestampPtr = _lookup<ffi.NativeFunction<ffi.Int Function(ffi.Pointer<ffi.Uint8>, ffi.Uint64, ffi.Uint64, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>)>>('derive_keypair_from_timestamp');
  late final _derive_keypair_from_timestamp = _derive_keypair_from_timestampPtr.asFunction<int Function(ffi.Pointer<ffi.Uint8>, int, int, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>)>();

  int create_ring_signature(
      ffi.Pointer<ffi.Char> msg,
      int msg_len,
      ffi.Pointer<ffi.Uint8> signer_priv_key_32b,
      ffi.Pointer<ffi.Uint8> ring_pub_keys,
      int ring_size,
      ffi.Pointer<ffi.Uint8> out_signature,
      ) {
    return _create_ring_signature(msg, msg_len, signer_priv_key_32b, ring_pub_keys, ring_size, out_signature);
  }
  late final _create_ring_signaturePtr = _lookup<ffi.NativeFunction<ffi.Int Function(ffi.Pointer<ffi.Char>, ffi.Size, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Int, ffi.Pointer<ffi.Uint8>)>>('create_ring_signature');
  late final _create_ring_signature = _create_ring_signaturePtr.asFunction<int Function(ffi.Pointer<ffi.Char>, int, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>)>();

  int verify_ring_signature(
      ffi.Pointer<ffi.Char> msg,
      int msg_len,
      ffi.Pointer<ffi.Uint8> signature,
      ffi.Pointer<ffi.Uint8> ring_pub_keys,
      int ring_size,
      ) {
    return _verify_ring_signature(msg, msg_len, signature, ring_pub_keys, ring_size);
  }
  late final _verify_ring_signaturePtr = _lookup<ffi.NativeFunction<ffi.Int Function(ffi.Pointer<ffi.Char>, ffi.Size, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Int)>>('verify_ring_signature');
  late final _verify_ring_signature = _verify_ring_signaturePtr.asFunction<int Function(ffi.Pointer<ffi.Char>, int, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, int)>();


  // --- ★新規追加: PSI / ECC 関連 ---

  int psi_init() {
    return _psi_init();
  }
  late final _psi_initPtr = _lookup<ffi.NativeFunction<ffi.Int Function()>>('psi_init');
  late final _psi_init = _psi_initPtr.asFunction<int Function()>();

  void psi_cleanup() {
    _psi_cleanup();
  }
  late final _psi_cleanupPtr = _lookup<ffi.NativeFunction<ffi.Void Function()>>('psi_cleanup');
  late final _psi_cleanup = _psi_cleanupPtr.asFunction<void Function()>();

  int generate_random_dummy_key_bytes(ffi.Pointer<ffi.Uint8> out33b) {
    return _generate_random_dummy_key_bytes(out33b);
  }
  late final _generate_random_dummy_key_bytesPtr = _lookup<ffi.NativeFunction<ffi.Int Function(ffi.Pointer<ffi.Uint8>)>>('generate_random_dummy_key_bytes');
  late final _generate_random_dummy_key_bytes = _generate_random_dummy_key_bytesPtr.asFunction<int Function(ffi.Pointer<ffi.Uint8>)>();

  int ecc_single_encrypt_set(
      ffi.Pointer<ffi.Uint8> input_keys,
      int count,
      ffi.Pointer<ffi.Uint8> secret_32b,
      ffi.Pointer<ffi.Uint8> out_keys,
      ) {
    return _ecc_single_encrypt_set(input_keys, count, secret_32b, out_keys);
  }
  late final _ecc_single_encrypt_setPtr = _lookup<ffi.NativeFunction<ffi.Int Function(ffi.Pointer<ffi.Uint8>, ffi.Int32, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>)>>('ecc_single_encrypt_set');
  late final _ecc_single_encrypt_set = _ecc_single_encrypt_setPtr.asFunction<int Function(ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>)>();

  int ecc_intersect_sets(
      ffi.Pointer<ffi.Uint8> original_keys,
      ffi.Pointer<ffi.Uint8> my_double_set,
      ffi.Pointer<ffi.Uint8> remote_double_set,
      int count_a,
      int count_b,
      ffi.Pointer<ffi.Uint8> result_keys,
      ffi.Pointer<ffi.Int32> result_count,
      ) {
    return _ecc_intersect_sets(original_keys, my_double_set, remote_double_set, count_a, count_b, result_keys, result_count);
  }
  late final _ecc_intersect_setsPtr = _lookup<ffi.NativeFunction<ffi.Int Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Int32, ffi.Int32, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Int32>)>>('ecc_intersect_sets');
  late final _ecc_intersect_sets = _ecc_intersect_setsPtr.asFunction<int Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, int, int, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Int32>)>();
}