import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';
import 'package:zxing2/zxing2.dart';

class OnboardingQrPayload {
  final String serverBaseUrl;
  final String clientToken;
  final String gatewayToken;

  const OnboardingQrPayload({
    required this.serverBaseUrl,
    required this.clientToken,
    required this.gatewayToken,
  });

  static OnboardingQrPayload parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      throw const FormatException('QR content is empty');
    }

    if (text.startsWith('{')) {
      return _parseJsonPayload(text);
    }

    return _parseCompactPayload(text);
  }

  static OnboardingQrPayload _parseJsonPayload(String text) {
    final json = jsonDecode(text);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Invalid JSON onboarding payload');
    }
    final server = json['serverBaseUrl']?.toString().trim() ?? '';
    final clientToken = json['clientToken']?.toString().trim() ?? '';
    final gatewayToken = json['gatewayToken']?.toString().trim() ?? '';
    _validate(server, clientToken, gatewayToken);
    return OnboardingQrPayload(
      serverBaseUrl: server,
      clientToken: clientToken,
      gatewayToken: gatewayToken,
    );
  }

  static OnboardingQrPayload _parseCompactPayload(String text) {
    final parts = text.split('|');
    if (parts.length < 4 || parts[0].trim() != 'RMS1') {
      throw const FormatException('Unsupported onboarding QR format');
    }

    final server = parts[1].trim();
    final clientToken = parts[2].trim();
    final gatewayToken = parts[3].trim();
    _validate(server, clientToken, gatewayToken);
    return OnboardingQrPayload(
      serverBaseUrl: server,
      clientToken: clientToken,
      gatewayToken: gatewayToken,
    );
  }

  static void _validate(String server, String clientToken, String gatewayToken) {
    final uri = Uri.tryParse(server);
    final validScheme = uri != null && (uri.scheme == 'https' || uri.scheme == 'http') && (uri.host.isNotEmpty || uri.hasAuthority);
    if (!validScheme) {
      throw const FormatException('Invalid serverBaseUrl in onboarding payload');
    }
    if (clientToken.isEmpty) {
      throw const FormatException('Missing client token in onboarding payload');
    }
    if (gatewayToken.isEmpty) {
      throw const FormatException('Missing gateway token in onboarding payload');
    }
  }
}

String decodeQrTextFromImageBytes(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('Unsupported image format');
  }

  final rotations = <num>[0, 90, 180, 270];
  Object? lastError;
  for (final angle in rotations) {
    final candidate = angle == 0 ? decoded : img.copyRotate(decoded, angle: angle);
    final rgba = candidate.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba).buffer.asInt32List();
    final source = RGBLuminanceSource(candidate.width, candidate.height, rgba);
    final bitmap = BinaryBitmap(HybridBinarizer(source));
    try {
      final result = QRCodeReader().decode(bitmap);
      final text = result.text.trim();
      if (text.isNotEmpty) {
        return text;
      }
    } catch (e) {
      lastError = e;
    }
  }

  throw FormatException('QR code not found in image: ${lastError ?? "unknown"}');
}
