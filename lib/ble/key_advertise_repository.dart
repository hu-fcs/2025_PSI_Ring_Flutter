// lib/ble/key_advertise_repository.dart
import 'dart:typed_data';
import '../key_management_service.dart'; // 既存のKMSを利用
import 'ble_constants.dart';

class KeyAdvertiseRepository {
  KeyAdvertiseRepository() : _kms = KeyManagementService();
  final KeyManagementService _kms;

  /// KMSが返す 33B 圧縮公開鍵をそのまま返す (★ 処理内容を変更)
  Future<Uint8List> getPublicKeyForAdvertise({Duration? validity}) async {
    final Uint8List? pubKey33 = await _kms.getPublicKeyForAdvertise();
    if (pubKey33 == null) {
      throw StateError('Failed to obtain public key from KeyManagementService.');
    }
    if (!isValidCompressedPubkey(pubKey33)) {
      throw StateError('Invalid compressed public key (expected 33 bytes starting with 0x02/0x03).');
    }

    // 33バイトの鍵をそのまま返す
    return pubKey33;
  }
}