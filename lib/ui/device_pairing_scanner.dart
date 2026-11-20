import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../sync/device_pairing.dart';
import '../sync/sync_revision.dart';

class DevicePairingScanner extends StatefulWidget {
  const DevicePairingScanner({super.key});

  @override
  State<DevicePairingScanner> createState() => _DevicePairingScannerState();
}

class _DevicePairingScannerState extends State<DevicePairingScanner> {
  final _camera = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  bool _finished = false;
  String? _message;

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  void _detect(BarcodeCapture frame) {
    if (_finished || !mounted || ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    for (final barcode in frame.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;
      try {
        final pairing = DevicePairing.parse(value);
        _finished = true;
        Navigator.pop(context, pairing);
        return;
      } on SyncFailure catch (error) {
        if (_message != error.message) {
          setState(() => _message = error.message);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan pairing QR code')),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _message ??
                    'Point the camera at the QR code on the Notixer admin page.',
              ),
            ),
          ),
          Expanded(
            child: MobileScanner(
              controller: _camera,
              onDetect: _detect,
              errorBuilder: (_, _) => const Center(
                child: Text(
                  'Camera unavailable. Allow camera access or connect with a device token.',
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
