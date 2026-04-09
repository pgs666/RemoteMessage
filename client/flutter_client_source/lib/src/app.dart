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
  final settings = AppSettingsStore();
  ThemeMode _themeMode = ThemeMode.system;

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
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true, brightness: Brightness.dark),
      home: MessageHomePage(settings: settings, onThemeChanged: _onThemeChanged),
    );
  }
}

