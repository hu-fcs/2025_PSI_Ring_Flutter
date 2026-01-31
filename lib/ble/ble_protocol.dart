// lib/ble/ble_protocol.dart
import 'dart:typed_data';
import '../key_management.dart';

/// Manufacturer Specific Data に格納するヘッダ(1B)。
///
/// bit7-6: seq2    (2bit, floor(UNIX/600) の下位2bit)
/// bit5  : part    (1bit, 0=front, 1=back)
/// bit4-1: ver     (4bit, currentVer)
/// bit0  : yParity (0x02→0, 0x03→1)
class BleHdr {
  /// ペイロード仕様バージョン
  static const int currentVer = 6;

  static int make({
    required int seq2,    // 0..3
    required int part,    // 0=front, 1=back
    required int yParity, // 0/1
  }) {
    final s = (seq2 & 0x03) << 6; // bit7-6
    final p = (part & 0x01) << 5; // bit5
    final v = (currentVer & 0x0F) << 1; // bit4-1
    final y = (yParity & 0x01); // bit0
    return s | p | v | y;
  }

  static int parseSeq2(int b) => (b >> 6) & 0x03;
  static int parsePart(int b) => (b >> 5) & 0x01;
  static int parseVer(int b) => (b >> 1) & 0x0F;
  static int parseYParity(int b) => b & 0x01;
}

/// 圧縮公開鍵(33B)の軽い検証（先頭 0x02/0x03, 残り32B）。
bool isValidCompressedPubkey(Uint8List key33) {
  if (key33.length != 33) return false;
  final p = key33[0];
  return (p == 0x02 || p == 0x03);
}

/// 現在の時刻スロット(10分)に対する識別子 seq2（下位2bit, 0..3）。
int currentTenMinSeq2() {
  return (DateTime.now().millisecondsSinceEpoch ~/
      KeyManagementService().slotMs) &
  0x03;
}
