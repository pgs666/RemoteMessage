import 'dart:io';

import 'package:flutter/services.dart';

import 'app_data.dart';

class AndroidLauncherIconService {
  static const MethodChannel _channel = MethodChannel('com.remotemessage.client/icon_mode');

  static Future<void> applyMode(AndroidLauncherIconMode mode) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setLauncherIconMode', {'mode': mode.persistedValue});
    } catch (_) {
      // Ignore: icon mode switching is a non-critical UX feature.
    }
  }
}
