import 'dart:io';

import 'package:flutter/material.dart';

import 'android_launcher_icon_service.dart';
import 'app_data.dart';
import 'message_home_page.dart';

class RemoteMessageApp extends StatefulWidget {
  const RemoteMessageApp({super.key});

  @override
  State<RemoteMessageApp> createState() => _RemoteMessageAppState();
}

class _RemoteMessageAppState extends State<RemoteMessageApp> {
  static const String _desktopFontFamily = 'RemoteMessageDesktopFallback';
  final settings = AppSettingsStore();
  ThemeMode _themeMode = ThemeMode.system;

  bool get _useBundledDesktopFont => Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  ThemeData _buildTheme(Brightness brightness) {
    return ThemeData(
      colorSchemeSeed: Colors.blue,
      useMaterial3: true,
      brightness: brightness,
      fontFamily: _useBundledDesktopFont ? _desktopFontFamily : null,
    );
  }

  @override
  void initState() {
    super.initState();
    settings.load().then((_) async {
      await AndroidLauncherIconService.applyMode(settings.androidLauncherIconMode);
      if (!mounted) return;
      setState(() => _themeMode = settings.themeMode);
    });
  }

  Future<void> _onThemeChanged(ThemeMode mode) async {
    setState(() => _themeMode = mode);
    settings.themeMode = mode;
    await settings.save();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RemoteMessage',
      themeMode: _themeMode,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: MessageHomePage(settings: settings, onThemeChanged: _onThemeChanged),
    );
  }
}
