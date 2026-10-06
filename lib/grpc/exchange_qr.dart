enum ExchangeQrPurpose { psi, friend }

class ExchangeQr {
  const ExchangeQr({
    required this.purpose,
    required this.host,
    required this.port,
    required this.nonce,
  });

  final ExchangeQrPurpose purpose;
  final String host;
  final int port;
  final int nonce;

  String encode() => 'FCS:1:${purpose.name}:$host:$port:$nonce';

  factory ExchangeQr.parse(String raw) {
    final parts = raw.split(':');
    final legacy = parts.length == 4 && parts.first == 'FCS';
    if (!legacy &&
        (parts.length != 6 || parts.first != 'FCS' || parts[1] != '1')) {
      throw const FormatException('Unsupported QR format');
    }
    final purpose =
        legacy
            ? ExchangeQrPurpose.psi
            : ExchangeQrPurpose.values
                .where((p) => p.name == parts[2])
                .firstOrNull;
    final offset = legacy ? 1 : 3;
    final host = parts[offset].trim();
    final port = int.tryParse(parts[offset + 1]);
    final nonce = int.tryParse(parts[offset + 2]);
    if (purpose == null ||
        host.isEmpty ||
        port == null ||
        port < 1 ||
        port > 65535 ||
        nonce == null ||
        nonce < 100 ||
        nonce > 999) {
      throw const FormatException('Invalid QR connection');
    }
    return ExchangeQr(purpose: purpose, host: host, port: port, nonce: nonce);
  }
}
