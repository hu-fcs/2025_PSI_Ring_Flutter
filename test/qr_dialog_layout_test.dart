import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  for (final size in [const Size(320, 568), const Size(412, 915)]) {
    testWidgets('QR dialog lays out at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlertDialog(
              title: const Text('友達登録のQRコード'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('名前：自分の端末'),
                    Center(
                      child: SizedBox(
                        width: 200,
                        height: 200,
                        child: QrImageView(
                          data: 'FCS:1:friend:192.168.1.2:50051:123',
                          backgroundColor: Colors.white,
                        ),
                      ),
                    ),
                    const Text('IPアドレス：192.168.1.2'),
                    const Text('ポート番号：50051'),
                    const Text('確認コード：123'),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () {}, child: const Text('表示を終了')),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final qrSize = tester.getSize(find.byType(QrImageView));
      expect(qrSize.width, inInclusiveRange(1, 200));
      expect(qrSize.height, 200);
    });
  }
}
