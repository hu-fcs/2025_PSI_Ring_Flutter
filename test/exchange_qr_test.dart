import 'package:flutter_test/flutter_test.dart';
import 'package:fluttersample_2025/grpc/exchange_qr.dart';

void main() {
  for (final purpose in ExchangeQrPurpose.values) {
    test('round trips ${purpose.name} connection', () {
      final qr = ExchangeQr(
        purpose: purpose,
        host: '192.168.1.2',
        port: 50051,
        nonce: 123,
      );
      final parsed = ExchangeQr.parse(qr.encode());
      expect(parsed.purpose, purpose);
      expect(parsed.host, qr.host);
      expect(parsed.port, qr.port);
      expect(parsed.nonce, qr.nonce);
    });
  }

  test('legacy padded connection is PSI', () {
    final qr = ExchangeQr.parse('FCS:192.168.1.2    :50051:123');
    expect(qr.purpose, ExchangeQrPurpose.psi);
    expect(qr.host, '192.168.1.2');
  });

  test('rejects malformed or unsupported connections', () {
    for (final raw in [
      'FCS',
      'FCS:2:friend:host:50051:123',
      'FCS:1:unknown:host:50051:123',
      'FCS:1:friend::50051:123',
      'FCS:1:friend:host:65536:123',
      'FCS:1:friend:host:abc:123',
      'FCS:1:friend:host:50051:0',
    ]) {
      expect(() => ExchangeQr.parse(raw), throwsFormatException, reason: raw);
    }
  });
}
