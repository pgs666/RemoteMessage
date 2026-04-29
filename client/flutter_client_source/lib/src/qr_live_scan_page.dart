import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class QrLiveScanPage extends StatefulWidget {
  final bool isZh;

  const QrLiveScanPage({super.key, required this.isZh});

  @override
  State<QrLiveScanPage> createState() => _QrLiveScanPageState();
}

class _QrLiveScanPageState extends State<QrLiveScanPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;

  String tr(String zh, String en) => widget.isZh ? zh : en;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue?.trim() ?? '';
      if (raw.isNotEmpty) {
        _handled = true;
        unawaited(_controller.stop());
        Navigator.of(context).pop(raw);
        return;
      }
    }
  }

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('扫码', 'Scan QR'))),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Center(
            child: IgnorePointer(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 2),
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.48),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  tr(
                    '将二维码放入取景框内自动识别',
                    'Place QR code inside the frame to scan automatically',
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
