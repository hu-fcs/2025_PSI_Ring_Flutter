// lib/ble/ble_constants.dart
import 'dart:typed_data';

/// 33B 圧縮公開鍵を 17B(front) + 16B(back) に分割したもの。
/// front[0] は 0x02/0x03（yParityビットを持つ先頭バイト）。
class BleKeyChunks {
  final Uint8List front; // 17B (pubkey[0..16])
  final Uint8List back;  // 16B (pubkey[17..32])
  BleKeyChunks({required this.front, required this.back});
}

/// 1B ヘッダ：
/// bit7-6: seq2 (2bit, floor(UNIX/600) & 0b11)
/// bit5   : part (0=front, 1=back)
/// bit4-1 : ver  (4bit, 現行=1)
/// bit0   : yParity (0x02→0, 0x03→1)
class BleHdr {
  static const int currentVer = 1;

  static int make({
    required int seq2,   // 0..3
    required int part,   // 0=front,1=back
    required int yParity,// 0/1
  }) {
    final s = (seq2   & 0x03) << 6;      // bit7-6
    final p = (part   & 0x01) << 5;      // bit5
    final v = (currentVer & 0x0F) << 1;  // bit4-1
    final y = (yParity & 0x01);          // bit0
    return s | p | v | y;
  }

  static int parseSeq2(int b)    => (b >> 6) & 0x03;
  static int parsePart(int b)    => (b >> 5) & 0x01;
  static int parseVer(int b)     => (b >> 1) & 0x0F;
  static int parseYParity(int b) =>  b       & 0x01;
}

/// 33B 圧縮公開鍵の軽い検証（先頭 0x02/0x03, 残り32B）
bool isValidCompressedPubkey(Uint8List key33) {
  if (key33.length != 33) return false;
  final p = key33[0];
  return (p == 0x02 || p == 0x03);
}

/// 10分単位の下位2bit（0..3）
int currentTenMinSeq2() {
  final unixSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return (unixSec ~/ 600) & 0x03;
}
