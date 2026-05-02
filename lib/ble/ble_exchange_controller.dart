// lib/ble/ble_exchange_controller.dart
import 'ble_advertiser.dart';
import 'ble_scanner.dart';

/// exchange_page のトグルから呼ぶ制御層：
/// - ON の間だけ広告＋スキャンを同時に実行
/// - 一時DBは使わず、スキャナ内のメモリ管理に任せる
class BleExchangeController {
  final _advertiser = BleAdvertiser();
  final _scanner = BleScanner();

  BleExchangeController() {
    // Scannerが「Challengeを広告で送って」と言ったら Advertiserへ渡す
    _scanner.onNeedAdvertiseChallenge =
        (targetKeyId4, challengeId, nonce16, verifierId4) {
      _advertiser.enqueueChallenge(
        targetKeyId4: targetKeyId4,
        challengeId: challengeId,
        nonce16: nonce16,
        verifierId4: verifierId4,
      );
    };

    // Scannerが「Signatureを広告で送って」と言ったら Advertiserへ渡す
    _scanner.onNeedAdvertiseSignature =
        (targetKeyId4, challengeId, signature64, verifierId4) {
      _advertiser.enqueueSignature(
        targetKeyId4: targetKeyId4,
        challengeId: challengeId,
        signature64: signature64,
        verifierId4: verifierId4,
      );
    };
  }

  bool get isRunning => _advertiser.isAdvertising && _scanner.isScanning;

  /// ExchangePage 側から「友達検出時の動作」を設定できるようにする
  set onFriendDetected(void Function(String friendLabel, bool authenticated)? cb) {
    _scanner.onFriendDetected = cb;
  }

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
