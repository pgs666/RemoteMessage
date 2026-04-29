import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

class OnboardingQrPayload {
  final String serverBaseUrl;
  final String clientToken;

  const OnboardingQrPayload({
    required this.serverBaseUrl,
    required this.clientToken,
  });

  static OnboardingQrPayload parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      throw const FormatException('QR content is empty');
    }

    if (!text.startsWith('{')) {
      throw const FormatException('Unsupported onboarding QR format');
    }
    return _parseJsonPayload(text);
  }

  static OnboardingQrPayload _parseJsonPayload(String text) {
    final json = jsonDecode(text);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Invalid JSON onboarding payload');
    }
    final format = json['format']?.toString().trim() ?? '';
    final role = json['role']?.toString().trim() ?? '';
    final server = json['serverBaseUrl']?.toString().trim() ?? '';
    final clientToken = json['clientToken']?.toString().trim() ?? '';
    if (format != 'RMS2' || role != 'client') {
      throw const FormatException('Unsupported onboarding QR role');
    }
    _validate(server, clientToken);
    return OnboardingQrPayload(serverBaseUrl: server, clientToken: clientToken);
  }

  static void _validate(String server, String clientToken) {
    final uri = Uri.tryParse(server);
    final validScheme =
        uri != null &&
        (uri.scheme == 'https' ||
            (uri.scheme == 'http' && _isLocalDebugHttpHost(uri.host))) &&
        (uri.host.isNotEmpty || uri.hasAuthority);
    if (!validScheme) {
      throw const FormatException(
        'Invalid serverBaseUrl in onboarding payload',
      );
    }
    if (clientToken.isEmpty) {
      throw const FormatException('Missing client token in onboarding payload');
    }
  }

  static bool _isLocalDebugHttpHost(String host) {
    final normalized = host.trim().toLowerCase();
    return normalized == 'localhost' ||
        normalized == '::1' ||
        normalized == '10.0.2.2' ||
        normalized == '10.0.3.2' ||
        normalized.startsWith('127.');
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
    final candidate = angle == 0
        ? decoded
        : img.copyRotate(decoded, angle: angle);
    final rgba = candidate
        .convert(numChannels: 4)
        .getBytes(order: img.ChannelOrder.rgba)
        .buffer
        .asInt32List();
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

  throw FormatException(
    'QR code not found in image: ${lastError ?? "unknown"}',
  );
}

Future<String> decodeQrTextFromImageBytesAsync(Uint8List bytes) {
  return compute(_decodeQrTextFromImageBytesInIsolate, bytes);
}

String _decodeQrTextFromImageBytesInIsolate(Uint8List bytes) {
  return decodeQrTextFromImageBytes(bytes);
}
