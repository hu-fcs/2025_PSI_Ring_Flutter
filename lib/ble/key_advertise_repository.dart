// lib/ble/key_advertise_repository.dart
import 'dart:typed_data';
import '../key_management_service.dart'; // 既存のKMSを利用
import 'ble_constants.dart';

class KeyAdvertiseRepository {
  KeyAdvertiseRepository() : _kms = KeyManagementService();
  final KeyManagementService _kms;

  /// KMSが返す 33B 圧縮公開鍵を取得 → 17B/16B に分割して返す。
  Future<BleKeyChunks> getPublicKeyForAdvertise({Duration? validity}) async {
    final Uint8List? pubKey33 = await _kms.getPublicKeyForAdvertise(
      validity: validity ?? const Duration(minutes: 10),
    );
    if (pubKey33 == null) {
      throw StateError('Failed to obtain public key from KeyManagementService.');
    }
    if (!isValidCompressedPubkey(pubKey33)) {
      throw StateError('Invalid compressed public key (expected 33 bytes starting with 0x02/0x03).');
    }

    // 33B -> front 17B (0..16), back 16B (17..32)
    final front = Uint8List.fromList(pubKey33.sublist(0, 17));
    final back  = Uint8List.fromList(pubKey33.sublist(17));
    return BleKeyChunks(front: front, back: back);
  }
}
