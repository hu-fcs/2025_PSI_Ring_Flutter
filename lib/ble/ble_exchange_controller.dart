// lib/ble/ble_exchange_controller.dart

import 'ble_advertiser.dart';
import 'ble_scanner.dart';

/// BLE による仮名の広告・収集をまとめて制御する。
///
/// 有効化中は広告(Advertiser)とスキャン(Scanner)を同時に動作させる。
/// 収集結果の一時保存は行わず，スキャナ側のメモリ管理に委ねる。
class BleExchangeController {
  final _advertiser = BleAdvertiser();
  final _scanner = BleScanner();

  bool get isRunning => _advertiser.isAdvertising && _scanner.isScanning;

  Future<void> toggleExchange() async {
    if (isRunning) {
      await _scanner.stop();
      await _advertiser.stop();
    } else {
      await _advertiser.start();
      await _scanner.start();
    }
  }
}
