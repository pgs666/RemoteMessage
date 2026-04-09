import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'app_data.dart';

class SettingsResult {
  final String serverBaseUrl;
  final String deviceId;
  final String password;
  final ThemeMode themeMode;
  final String activeProfileId;
  final AndroidLauncherIconMode androidLauncherIconMode;
  final bool clearLocalDatabase;

  const SettingsResult({
    required this.serverBaseUrl,
    required this.deviceId,
    required this.password,
    required this.themeMode,
    required this.activeProfileId,
    required this.androidLauncherIconMode,
    this.clearLocalDatabase = false,
  });
}

class GatewayOnlineStatus {
  final String deviceId;
  final int? lastSeenAt;
  final bool isOnline;
  final int onlineWindowMs;
  final int checkedAt;

  const GatewayOnlineStatus({
    required this.deviceId,
    required this.lastSeenAt,
    required this.isOnline,
    required this.onlineWindowMs,
    required this.checkedAt,
  });

  factory GatewayOnlineStatus.fromJson(Map<String, dynamic> json) {
    int? toInt(dynamic value) {
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '');
    }

    return GatewayOnlineStatus(
      deviceId: json['deviceId']?.toString() ?? '',
      lastSeenAt: toInt(json['lastSeenAt']),
      isOnline: json['isOnline'] == true,
      onlineWindowMs: toInt(json['onlineWindowMs']) ?? 120000,
      checkedAt: toInt(json['checkedAt']) ?? DateTime.now().millisecondsSinceEpoch,
    );
  }
}

class SettingsPage extends StatefulWidget {
  final AppSettingsStore settings;
  final List<DeviceSimProfile> simProfiles;

  const SettingsPage({
    super.key,
    required this.settings,
    required this.simProfiles,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _profileNameCtrl;
  late final TextEditingController _serverCtrl;
  late final TextEditingController _deviceCtrl;
  late final TextEditingController _passwordCtrl;
  late ThemeMode _themeMode;
  late AndroidLauncherIconMode _androidLauncherIconMode;

  late List<AppServerProfile> _profiles;
  late String _activeProfileId;
  late final String _initialProfileId;

  String _certStatus = '';
  bool _certBusy = false;
  bool _gatewayStatusBusy = false;
  GatewayOnlineStatus? _gatewayOnlineStatus;
  String? _gatewayOnlineStatusError;

  bool get _isZh => WidgetsBinding.instance.platformDispatcher.locale.languageCode.toLowerCase().startsWith('zh');
  String tr(String zh, String en) => _isZh ? zh : en;

  @override
  void initState() {
    super.initState();

    _profiles = List<AppServerProfile>.from(widget.settings.profiles);
    if (_profiles.isEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      _profiles = [
        AppServerProfile(
          id: 'default',
          name: tr('默认配置', 'Default Profile'),
          serverBaseUrl: widget.settings.serverBaseUrl,
          deviceId: widget.settings.deviceId,
          password: widget.settings.password,
          updatedAt: now,
        ),
      ];
    }

    _activeProfileId = widget.settings.activeProfileId;
    if (!_profiles.any((p) => p.id == _activeProfileId)) {
      _activeProfileId = _profiles.first.id;
    }
    _initialProfileId = _activeProfileId;

    _profileNameCtrl = TextEditingController();
    _serverCtrl = TextEditingController();
    _deviceCtrl = TextEditingController();
    _passwordCtrl = TextEditingController();
    _themeMode = widget.settings.themeMode;
    _androidLauncherIconMode = widget.settings.androidLauncherIconMode;

    _loadProfileIntoForm(_activeProfileId);
    _reloadCertStatus();
    _refreshGatewayOnlineStatus(interactive: false);
  }

  @override
  void dispose() {
    _profileNameCtrl.dispose();
    _serverCtrl.dispose();
    _deviceCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  AppServerProfile _profileById(String id) {
    return _profiles.firstWhere((p) => p.id == id, orElse: () => _profiles.first);
  }

  void _loadProfileIntoForm(String profileId) {
    final p = _profileById(profileId);
    _profileNameCtrl.text = p.name;
    _serverCtrl.text = p.serverBaseUrl;
    _deviceCtrl.text = p.deviceId;
    _passwordCtrl.text = p.password;
  }

  void _applyFormToActiveProfile() {
    final idx = _profiles.indexWhere((p) => p.id == _activeProfileId);
    if (idx < 0) return;
    final old = _profiles[idx];
    _profiles[idx] = old.copyWith(
      name: _profileNameCtrl.text.trim().isEmpty ? tr('未命名配置', 'Unnamed Profile') : _profileNameCtrl.text.trim(),
      serverBaseUrl: _serverCtrl.text.trim(),
      deviceId: _deviceCtrl.text.trim(),
      password: _passwordCtrl.text.trim(),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _switchProfile(String? profileId) async {
    if (profileId == null || profileId == _activeProfileId) return;
    setState(() {
      _applyFormToActiveProfile();
      _activeProfileId = profileId;
      _loadProfileIntoForm(_activeProfileId);
    });
    await _refreshGatewayOnlineStatus(interactive: false);
  }

  Future<void> _addProfileDialog() async {
    final nameCtrl = TextEditingController(text: tr('新配置', 'New Profile'));
    final serverCtrl = TextEditingController(text: _serverCtrl.text.trim());
    final deviceCtrl = TextEditingController(text: _deviceCtrl.text.trim());
    final passwordCtrl = TextEditingController(text: _passwordCtrl.text.trim());

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('添加配置', 'Add Profile')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: InputDecoration(labelText: tr('配置名称', 'Profile Name')),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: serverCtrl,
                decoration: InputDecoration(labelText: tr('服务器地址', 'Server Base URL')),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: deviceCtrl,
                decoration: InputDecoration(labelText: tr('设备 ID', 'Device ID')),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: passwordCtrl,
                obscureText: true,
                decoration: InputDecoration(labelText: tr('密码', 'Password')),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('取消', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('添加', 'Add'))),
        ],
      ),
    );

    if (confirmed != true) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'profile_$now';
    final profile = AppServerProfile(
      id: id,
      name: nameCtrl.text.trim().isEmpty ? tr('新配置', 'New Profile') : nameCtrl.text.trim(),
      serverBaseUrl: serverCtrl.text.trim(),
      deviceId: deviceCtrl.text.trim(),
      password: passwordCtrl.text.trim(),
      updatedAt: now,
    );

    setState(() {
      _applyFormToActiveProfile();
      _profiles = [profile, ..._profiles];
      _activeProfileId = id;
      _loadProfileIntoForm(_activeProfileId);
    });

    await _refreshGatewayOnlineStatus(interactive: false);
  }

  Future<void> _reloadCertStatus() async {
    final file = await widget.settings.trustedCertificateFile();
    final exists = await file.exists();
    if (!mounted) return;
    setState(() {
      _certStatus = exists
          ? tr('已导入服务器证书（在系统信任基础上追加信任）', 'Server certificate imported (added on top of system CAs).')
          : tr(
              '未导入服务器证书。HTTPS 默认信任公开 CA 证书；如使用自签证书请导入 server-cert.cer',
              'No custom certificate imported. HTTPS trusts public CAs by default; import server-cert.cer only for self-signed servers.',
            );
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

  Future<String> _getJson(Uri url, {String? password}) async {
    final client = await widget.settings.createHttpClient(url, isZh: _isZh);
    try {
      final req = await client.getUrl(url);
      if ((password ?? '').trim().isNotEmpty) {
        req.headers.set('X-Password', password!.trim());
      }
      final resp = await req.close();
      final body = await utf8.decodeStream(resp);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('HTTP ${resp.statusCode}: $body');
      }
      return body;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _refreshGatewayOnlineStatus({bool interactive = false}) async {
    final server = _serverCtrl.text.trim();
    final device = _deviceCtrl.text.trim();
    final password = _passwordCtrl.text.trim();
    if (server.isEmpty || device.isEmpty) {
      if (!mounted) return;
      setState(() {
        _gatewayOnlineStatus = null;
        _gatewayOnlineStatusError = tr('请先填写服务器地址和设备 ID', 'Please fill server URL and device ID first');
      });
      return;
    }

    setState(() {
      _gatewayStatusBusy = true;
      _gatewayOnlineStatusError = null;
    });

    try {
      final uri = Uri.parse('$server/api/client/gateways/${Uri.encodeComponent(device)}/online');
      final body = await _getJson(uri, password: password);
      final parsed = GatewayOnlineStatus.fromJson(jsonDecode(body) as Map<String, dynamic>);
      if (!mounted) return;
      setState(() {
        _gatewayOnlineStatus = parsed;
        _gatewayOnlineStatusError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _gatewayOnlineStatus = null;
        _gatewayOnlineStatusError = '$e';
      });
      if (interactive) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${tr('获取网关状态失败', 'Failed to fetch gateway status')}: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _gatewayStatusBusy = false);
      }
    }
  }

  Future<void> _saveAndClose({bool clearLocalDatabase = false}) async {
    _applyFormToActiveProfile();

    for (final p in _profiles) {
      await widget.settings.upsertProfile(p, setActive: false);
    }
    await widget.settings.activateProfile(_activeProfileId);

    final active = _profileById(_activeProfileId);
    widget.settings.serverBaseUrl = active.serverBaseUrl;
    widget.settings.deviceId = active.deviceId;
    widget.settings.password = active.password;
    widget.settings.themeMode = _themeMode;
    widget.settings.androidLauncherIconMode = _androidLauncherIconMode;
    await widget.settings.save();

    if (!mounted) return;
    Navigator.pop(
      context,
      SettingsResult(
        serverBaseUrl: active.serverBaseUrl,
        deviceId: active.deviceId,
        password: active.password,
        themeMode: _themeMode,
        activeProfileId: _activeProfileId,
        androidLauncherIconMode: _androidLauncherIconMode,
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

  String _simLabel(int slotIndex) => tr('卡${slotIndex + 1}', 'SIM ${slotIndex + 1}');

  String _formatDateTime(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs).toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  Widget _buildGatewayOnlineStatusRow() {
    final status = _gatewayOnlineStatus;
    final isOnline = status?.isOnline ?? false;
    final bgColor = status == null
        ? Theme.of(context).colorScheme.surfaceContainerHighest
        : isOnline
            ? Colors.green.withValues(alpha: 0.14)
            : Theme.of(context).colorScheme.errorContainer;
    final fgColor = status == null
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : isOnline
            ? Colors.green.shade800
            : Theme.of(context).colorScheme.onErrorContainer;
    final statusText = _gatewayStatusBusy
        ? tr('状态检测中…', 'Checking...')
        : status == null
            ? tr('状态未知', 'Unknown')
            : status.isOnline
                ? tr('网关在线', 'Gateway Online')
                : tr('网关离线', 'Gateway Offline');
    final lastSeenText = status?.lastSeenAt == null
        ? null
        : '${tr('最近心跳', 'Last seen')}: ${_formatDateTime(status!.lastSeenAt!)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    status == null ? Icons.help_outline : (isOnline ? Icons.check_circle : Icons.error_outline),
                    size: 16,
                    color: fgColor,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    statusText,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fgColor),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: tr('刷新网关状态', 'Refresh gateway status'),
              onPressed: _gatewayStatusBusy ? null : () => _refreshGatewayOnlineStatus(interactive: true),
              icon: _gatewayStatusBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        if (lastSeenText != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(lastSeenText, style: Theme.of(context).textTheme.bodySmall),
          ),
        if (_gatewayOnlineStatusError != null && _gatewayOnlineStatusError!.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${tr('状态信息', 'Status detail')}: ${_gatewayOnlineStatusError!.trim()}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }

  Widget _buildSimInfoCard() {
    final sims = [...widget.simProfiles]..sort((a, b) => a.slotIndex.compareTo(b.slotIndex));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('网关号码信息', 'Gateway SIM Numbers'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _buildGatewayOnlineStatusRow(),
            const SizedBox(height: 8),
            if (sims.isEmpty)
              Text(tr('暂无 SIM 信息，请先返回首页刷新。', 'No SIM info yet. Please refresh from home page first.')),
            for (final sim in sims)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.sim_card, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${_simLabel(sim.slotIndex)}${sim.displayName == null || sim.displayName!.trim().isEmpty ? '' : ' · ${sim.displayName!.trim()}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      (sim.phoneNumber?.trim().isNotEmpty ?? false) ? sim.phoneNumber!.trim() : tr('未读取', 'Unknown'),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profileSwitched = _activeProfileId != _initialProfileId;

    return Scaffold(
      appBar: AppBar(title: Text(tr('设置', 'Settings'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    DropdownButtonFormField<String>(
                      value: _activeProfileId,
                      decoration: InputDecoration(
                        labelText: tr('当前配置', 'Active Profile'),
                        border: const OutlineInputBorder(),
                      ),
                      items: _profiles
                          .map(
                            (p) => DropdownMenuItem<String>(
                              value: p.id,
                              child: Text(p.name, overflow: TextOverflow.ellipsis),
                            ),
                          )
                          .toList(),
                      onChanged: _switchProfile,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _addProfileDialog,
                            icon: const Icon(Icons.add),
                            label: Text(tr('添加配置', 'Add Profile')),
                          ),
                        ),
                      ],
                    ),
                    if (profileSwitched)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            tr('保存后将切换配置并清空当前列表，加载目标配置短信。', 'Saving will switch profile, clear current list, and load the selected profile messages.'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _profileNameCtrl,
              decoration: InputDecoration(labelText: tr('配置名称', 'Profile Name'), border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
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
            _buildSimInfoCard(),
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
            if (Platform.isAndroid) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<AndroidLauncherIconMode>(
                value: _androidLauncherIconMode,
                decoration: InputDecoration(
                  labelText: tr('安卓桌面图标', 'Android Launcher Icon'),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem(
                    value: AndroidLauncherIconMode.defaultMode,
                    child: Text(tr('默认', 'Default')),
                  ),
                  DropdownMenuItem(
                    value: AndroidLauncherIconMode.light,
                    child: Text(tr('浅色图标', 'Light Icon')),
                  ),
                  DropdownMenuItem(
                    value: AndroidLauncherIconMode.dark,
                    child: Text(tr('深色图标', 'Dark Icon')),
                  ),
                ],
                onChanged: (v) => setState(() => _androidLauncherIconMode = v ?? AndroidLauncherIconMode.defaultMode),
              ),
            ],
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
            Text(_certStatus, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saveAndClose,
                icon: const Icon(Icons.save),
                label: Text(tr('保存', 'Save')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
