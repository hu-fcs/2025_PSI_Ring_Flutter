// lib/ble/ble_constants.dart
import 'dart:typed_data';

// ★ UUID関連のインポートと定義をすべて削除
// import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

/// 1B ヘッダ： (★ 2パケット構成、ManufacturerData版)
/// bit7-6: seq2 (2bit, floor(UNIX/600) & 0b11)
/// bit5   : part (1bit, 0=front, 1=back)
/// bit4-1 : ver  (4bit, 現行=6)
/// bit0   : yParity (0x02→0, 0x03→1)
class BleHdr {
  // ★ バージョンを 6 に更新 (Manufacturer ID + 2-part + 31B payload)
  // --- ver 定義 ---
  static const int verPubkey    = 6; // 既存互換（公開鍵断片）
  static const int verChallenge = 7; // Challenge
  static const int verSignature = 8; // Signature(分割)

  // 既存コード互換のため、従来の currentVer は「公開鍵断片」を指す
  static const int currentVer = verPubkey;

  static bool isSupportedVer(int ver) =>
      ver == verPubkey || ver == verChallenge || ver == verSignature;


  static int make({
    required int seq2,   // 0..3
    required int part,   // 0=front,1=back
    required int yParity,// 0/1
    int ver = currentVer, // ★追加：指定がなければ従来通りver=6
  }) {
    final s = (seq2   & 0x03) << 6;      // bit7-6
    final p = (part   & 0x01) << 5;      // bit5
    final v = (ver  & 0x0F) << 1;  // bit4-1
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