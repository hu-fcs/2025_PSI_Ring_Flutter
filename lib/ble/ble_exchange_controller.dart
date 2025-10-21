// lib/ble/ble_exchange_controller.dart
import 'ble_advertiser.dart';
import 'ble_scanner.dart';

/// exchange_page のトグルから呼ぶ制御層：
/// - ON の間だけ広告＋スキャンを同時に実行
/// - 一時DBは使わず、スキャナ内のメモリ管理に任せる
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
