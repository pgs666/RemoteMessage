import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'app_data.dart';

class SettingsResult {
  final String serverBaseUrl;
  final String deviceId;
  final String password;
  final ThemeMode themeMode;
  final bool clearLocalDatabase;

  const SettingsResult({
    required this.serverBaseUrl,
    required this.deviceId,
    required this.password,
    required this.themeMode,
    this.clearLocalDatabase = false,
  });
}

class SettingsPage extends StatefulWidget {
  final AppSettingsStore settings;

  const SettingsPage({super.key, required this.settings});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _serverCtrl;
  late final TextEditingController _deviceCtrl;
  late final TextEditingController _passwordCtrl;
  late ThemeMode _themeMode;
  String _certStatus = '';
  bool _certBusy = false;

  bool get _isZh => WidgetsBinding.instance.platformDispatcher.locale.languageCode.toLowerCase().startsWith('zh');
  String tr(String zh, String en) => _isZh ? zh : en;

  @override
  void initState() {
    super.initState();
    _serverCtrl = TextEditingController(text: widget.settings.serverBaseUrl);
    _deviceCtrl = TextEditingController(text: widget.settings.deviceId);
    _passwordCtrl = TextEditingController(text: widget.settings.password);
    _themeMode = widget.settings.themeMode;
    _reloadCertStatus();
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _deviceCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _reloadCertStatus() async {
    final file = await widget.settings.trustedCertificateFile();
    final exists = await file.exists();
    if (!mounted) return;
    setState(() {
      _certStatus = exists
          ? tr('已导入服务器证书（HTTPS 仅信任该证书）', 'Server certificate imported (HTTPS trusts only this cert).')
          : tr('未导入服务器证书。使用 HTTPS 前请先导入 server-cert.cer', 'No server certificate imported. Import server-cert.cer before using HTTPS.');
    });
  }

  Future<void> _importServerCertificate() async {
    setState(() => _certBusy = true);
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: 'certificate',
            extensions: ['cer', 'crt', 'pem', 'der'],
            mimeTypes: ['application/x-x509-ca-cert', 'application/pkix-cert', 'application/octet-stream', 'text/plain'],
            uniformTypeIdentifiers: ['public.x509-certificate', 'public.data'],
          ),
        ],
        confirmButtonText: tr('导入', 'Import'),
      );
      if (file == null) return;

      final bytes = await file.readAsBytes();
      await widget.settings.importTrustedCertificate(bytes);
      if (!mounted) return;
      setState(() {
        _certStatus = '${tr('证书已导入：', 'Certificate imported: ')}${file.name}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _certStatus = '${tr('证书导入失败', 'Certificate import failed')}: $e');
    } finally {
      if (mounted) {
        setState(() => _certBusy = false);
      }
    }
  }

  Future<void> _saveAndClose({bool clearLocalDatabase = false}) async {
    widget.settings.serverBaseUrl = _serverCtrl.text.trim();
    widget.settings.deviceId = _deviceCtrl.text.trim();
    widget.settings.password = _passwordCtrl.text.trim();
    widget.settings.themeMode = _themeMode;
    await widget.settings.save();
    if (!mounted) return;
    Navigator.pop(
      context,
      SettingsResult(
        serverBaseUrl: widget.settings.serverBaseUrl,
        deviceId: widget.settings.deviceId,
        password: widget.settings.password,
        themeMode: _themeMode,
        clearLocalDatabase: clearLocalDatabase,
      ),
    );
  }

  Future<void> _confirmClearLocalDatabase() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('清空本地数据库', 'Clear local database')),
        content: Text(
          tr(
            '将清除当前客户端所有本地消息、置顶和同步进度。是否继续？',
            'This will remove all local messages, pins, and sync progress on this client. Continue?',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('取消', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('清空', 'Clear'))),
        ],
      ),
    );

    if (confirmed == true) {
      await _saveAndClose(clearLocalDatabase: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('设置', 'Settings'))),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _serverCtrl,
              decoration: InputDecoration(labelText: tr('服务器地址', 'Server Base URL'), border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _deviceCtrl,
              decoration: InputDecoration(labelText: tr('设备 ID', 'Device ID'), border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordCtrl,
              obscureText: true,
              decoration: InputDecoration(labelText: tr('密码', 'Password'), border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ThemeMode>(
              value: _themeMode,
              decoration: InputDecoration(labelText: tr('主题', 'Theme'), border: const OutlineInputBorder()),
              items: [
                DropdownMenuItem(value: ThemeMode.system, child: Text(tr('跟随系统', 'System'))),
                DropdownMenuItem(value: ThemeMode.light, child: Text(tr('浅色', 'Light'))),
                DropdownMenuItem(value: ThemeMode.dark, child: Text(tr('深色', 'Dark'))),
              ],
              onChanged: (v) => setState(() => _themeMode = v ?? ThemeMode.system),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _certBusy ? null : _importServerCertificate,
              icon: _certBusy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.file_open),
              label: Text(tr('导入服务器证书', 'Import Server Certificate')),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _confirmClearLocalDatabase,
              icon: const Icon(Icons.delete_forever_outlined),
              label: Text(tr('清空本地数据库', 'Clear local database')),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(_certStatus, style: Theme.of(context).textTheme.bodyMedium),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _saveAndClose,
              icon: const Icon(Icons.save),
              label: Text(tr('保存', 'Save')),
            ),
          ],
        ),
      ),
    );
  }
}
