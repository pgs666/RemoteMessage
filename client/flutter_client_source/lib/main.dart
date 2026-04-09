import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  runApp(const RemoteMessageApp());
}

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
    settings.load().then((_) {
      setState(() => _themeMode = settings.themeMode);
    });
  }

  void _onThemeChanged(ThemeMode mode) async {
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
      home: MessageHomePage(
        settings: settings,
        onThemeChanged: _onThemeChanged,
      ),
    );
  }
}

class MessageHomePage extends StatefulWidget {
  final AppSettingsStore settings;
  final ValueChanged<ThemeMode> onThemeChanged;

  const MessageHomePage({
    super.key,
    required this.settings,
    required this.onThemeChanged,
  });

  @override
  State<MessageHomePage> createState() => _MessageHomePageState();
}

class _MessageHomePageState extends State<MessageHomePage> {
  late final TextEditingController _serverCtrl;
  late final TextEditingController _deviceCtrl;
  final _searchCtrl = TextEditingController();
  final _composerCtrl = TextEditingController();
  final _chatScrollCtrl = ScrollController();
  final ValueNotifier<int> _uiRefreshTick = ValueNotifier(0);

  final LocalDatabase _db = LocalDatabase();
  bool _loading = false;
  bool _syncingNow = false;
  String _status = 'Ready';
  String _search = '';
  String? _activePhone;
  int _lastSyncTs = 0;
  double? _syncProgress;
  Timer? _autoRefreshTimer;
  Timer? _searchDebounceTimer;
  List<ConversationSummary> _conversationCache = const [];
  List<SmsItem> _activeMessageCache = const [];
  List<DeviceSimProfile> _gatewaySimProfiles = const [];
  int? _selectedSendSimSlot;

  bool get _isZh => WidgetsBinding.instance.platformDispatcher.locale.languageCode.toLowerCase().startsWith('zh');
  String tr(String zh, String en) => _isZh ? zh : en;

  @override
  void initState() {
    super.initState();
    _serverCtrl = TextEditingController(text: widget.settings.serverBaseUrl);
    _deviceCtrl = TextEditingController(text: widget.settings.deviceId);
    _searchCtrl.addListener(() {
      _searchDebounceTimer?.cancel();
      _searchDebounceTimer = Timer(const Duration(milliseconds: 250), () {
        _search = _searchCtrl.text.trim().toLowerCase();
        _refreshLocalCaches();
      });
    });
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _status = tr('初始化中...', 'Initializing...');
      _syncProgress = null;
    });

    await widget.settings.load();
    _serverCtrl.text = widget.settings.serverBaseUrl;
    _deviceCtrl.text = widget.settings.deviceId;
    await _db.init();
    _lastSyncTs = await _db.getMetaInt('lastSyncTs') ?? 0;
    _activePhone = await _db.getMetaString('activePhone');
    _selectedSendSimSlot = await _db.getMetaInt('selectedSendSimSlot');
    await _refreshLocalCaches();
    await _refreshGatewaySimProfiles(interactive: false);
    await _syncInbox(fullSync: true, interactive: true);
    _startAutoRefresh();
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _refreshLocalCaches() async {
    final conversations = await _db.getConversationSummaries(search: _search);
    var nextActivePhone = _activePhone;

    if (conversations.isNotEmpty) {
      final stillExists = nextActivePhone != null && conversations.any((c) => c.phone == nextActivePhone);
      if (!stillExists) {
        nextActivePhone = conversations.first.phone;
      }
    } else {
      nextActivePhone = null;
    }

    if (nextActivePhone != _activePhone) {
      _activePhone = nextActivePhone;
      if (_activePhone != null) {
        await _db.setMetaString('activePhone', _activePhone!);
      }
    }

    final messages = _activePhone == null ? const <SmsItem>[] : await _db.getMessagesByPhone(_activePhone!);
    if (!mounted) return;

    setState(() {
      _conversationCache = conversations;
      _activeMessageCache = messages;
    });
    _uiRefreshTick.value++;
    _scrollChatToBottomSoon();
  }

  Future<void> _setActivePhone(String? phone) async {
    _activePhone = phone;
    if (phone != null) {
      await _db.setMetaString('activePhone', phone);
    }
    await _refreshLocalCaches();
  }

  void _startAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || _loading || _syncingNow) return;
      _syncInbox(interactive: false);
    });
  }

  void _scrollChatToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_chatScrollCtrl.hasClients) return;
      _chatScrollCtrl.animateTo(
        _chatScrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _openSettings() async {
    final result = await Navigator.push<SettingsResult>(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsPage(settings: widget.settings),
      ),
    );
    if (result == null) return;

    _serverCtrl.text = result.serverBaseUrl;
    _deviceCtrl.text = result.deviceId;
    widget.settings.password = result.password;
    widget.onThemeChanged(result.themeMode);
    setState(() => _status = tr('设置已更新', 'Settings updated'));
    _startAutoRefresh();
    await _refreshGatewaySimProfiles(interactive: false);
    if (result.clearLocalDatabase) {
      await _clearLocalDatabase();
      return;
    }
    await _syncInbox(fullSync: true, interactive: true);
  }

  Future<void> _clearLocalDatabase() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _syncProgress = null;
      _status = tr('正在清空本地数据库...', 'Clearing local database...');
    });

    try {
      await _db.clearAllUserData();
      _lastSyncTs = 0;
      _activePhone = null;
      _selectedSendSimSlot = _gatewaySimProfiles.isNotEmpty ? _gatewaySimProfiles.first.slotIndex : null;
      if (_selectedSendSimSlot != null) {
        await _db.setMetaInt('selectedSendSimSlot', _selectedSendSimSlot!);
      }
      await _refreshLocalCaches();
      if (!mounted) return;
      setState(() => _status = tr('本地数据库已清空', 'Local database cleared'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '${tr('清空失败', 'Clear failed')}: $e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _refreshGatewaySimProfiles({bool interactive = false}) async {
    final server = _serverCtrl.text.trim();
    final device = _deviceCtrl.text.trim();
    if (server.isEmpty || device.isEmpty) return;

    try {
      final response = await _getJson(
        Uri.parse('$server/api/client/device-sims?deviceId=${Uri.encodeQueryComponent(device)}'),
        password: widget.settings.password,
      );
      final list = (jsonDecode(response) as List)
          .map((e) => DeviceSimProfile.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.slotIndex.compareTo(b.slotIndex));

      final allowedSlotIndexes = list.map((e) => e.slotIndex).toSet();
      int? selected = _selectedSendSimSlot;
      if (selected != null && !allowedSlotIndexes.contains(selected)) {
        selected = null;
      }
      if (selected == null && list.isNotEmpty) {
        selected = list.first.slotIndex;
      }
      _selectedSendSimSlot = selected;
      if (selected != null) {
        await _db.setMetaInt('selectedSendSimSlot', selected);
      }

      if (!mounted) return;
      setState(() {
        _gatewaySimProfiles = list;
        if (interactive) {
          _status = tr('已刷新 SIM 信息', 'SIM info refreshed');
        }
      });
    } catch (e) {
      if (!interactive || !mounted) return;
      setState(() => _status = '${tr('SIM 信息刷新失败', 'SIM info refresh failed')}: $e');
    }
  }

  Future<void> _syncInbox({bool fullSync = false, bool interactive = true}) async {
    if (_syncingNow) return;

    final server = _serverCtrl.text.trim();
    if (server.isEmpty) return;

    _syncingNow = true;
    if (interactive && mounted) {
      setState(() {
        _loading = true;
        _syncProgress = null;
        _status = fullSync ? tr('加载完整历史中...', 'Loading full history...') : tr('正在同步新消息...', 'Syncing new messages...');
      });
    }

    try {
      final since = fullSync ? 0 : _lastSyncTs;
      final url = Uri.parse('$server/api/client/inbox?sinceTs=$since&limit=10000');
      final response = await _getJson(url, password: widget.settings.password);
      final list = (jsonDecode(response) as List)
          .map((e) => SmsItem.fromJson(e as Map<String, dynamic>))
          .toList();

      await _refreshGatewaySimProfiles(interactive: false);

      if (interactive && mounted) {
        setState(() {
          _syncProgress = list.isEmpty ? 1 : 0.1;
          _status = tr('正在写入本地消息...', 'Applying messages locally...');
        });
      }

      final added = await _db.upsertMessages(
        list,
        onProgress: interactive
            ? (done, total) {
                if (!mounted) return;
                setState(() {
                  _syncProgress = total <= 0 ? 1 : 0.1 + ((done / total) * 0.75);
                  _status = tr('正在写入本地消息... $done/$total', 'Applying messages locally... $done/$total');
                });
              }
            : null,
      );

      for (final item in list) {
        final cursorTs = item.syncCursorTs;
        if (cursorTs > _lastSyncTs) _lastSyncTs = cursorTs;
      }

      await _db.setMetaInt('lastSyncTs', _lastSyncTs);

      if (interactive && mounted) {
        setState(() {
          _syncProgress = 0.92;
          _status = tr('刷新会话中...', 'Refreshing conversations...');
        });
      }

      await _refreshLocalCaches();

      if (!mounted) return;
      setState(() {
        if (interactive) {
          _status = added > 0
              ? '${tr('同步完成', 'Sync done')}, +$added'
              : tr('同步完成，没有新消息', 'Sync done, no new messages');
          _syncProgress = 1;
        } else if (added > 0) {
          _status = '${tr('已自动同步新消息', 'Auto-synced new messages')}, +$added';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '${tr('同步失败', 'Sync failed')}: $e');
    } finally {
      _syncingNow = false;
      if (interactive && mounted) {
        setState(() {
          _loading = false;
          _syncProgress = null;
        });
      }
    }
  }

  Future<void> _setPin(String phone, bool pin) async {
    await _db.setPinned(phone, pin);
    await _refreshLocalCaches();
    try {
      final server = _serverCtrl.text.trim();
      await _postJson(Uri.parse('$server/api/client/conversations/pin'), {
        'phone': phone,
        'pinned': pin,
      }, password: widget.settings.password);
    } catch (_) {
      // ignore remote failure; local pin still works
    }
  }

  Future<void> _sendSmsToActive() async {
    final server = _serverCtrl.text.trim();
    final device = _deviceCtrl.text.trim();
    final phone = _activePhone?.trim() ?? '';
    final content = _composerCtrl.text.trim();
    if (server.isEmpty || device.isEmpty || phone.isEmpty || content.isEmpty) {
      setState(() => _status = tr('请先配置服务器/设备并选择会话', 'Please configure server/device and choose conversation'));
      return;
    }

    setState(() {
      _loading = true;
      _status = tr('发送中...', 'Sending...');
    });

    try {
      await _postJson(Uri.parse('$server/api/client/send'), {
        'deviceId': device,
        'targetPhone': phone,
        'content': content,
        if (_showSimSelection) 'simSlotIndex': _selectedSendSimSlot,
      }, password: widget.settings.password);
      _composerCtrl.clear();
      await _syncInbox(interactive: true);
      setState(() => _status = tr('消息已进入队列', 'Message queued'));
    } catch (e) {
      setState(() => _status = '${tr('发送失败', 'Send failed')}: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _createNewConversationLegacy() async {
    final phoneCtrl = TextEditingController();
    final msgCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('新短信', 'New SMS')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: phoneCtrl, decoration: InputDecoration(labelText: tr('号码', 'Phone'))),
            TextField(controller: msgCtrl, decoration: InputDecoration(labelText: tr('内容', 'Message')), maxLines: 3),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('取消', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('发送', 'Send'))),
        ],
      ),
    );

    if (ok != true) return;
    final phone = phoneCtrl.text.trim();
    final msg = msgCtrl.text.trim();
    if (phone.isEmpty || msg.isEmpty) {
      setState(() => _status = tr('号码和内容不能为空', 'Phone/content required'));
      return;
    }

    _activePhone = phone;
    await _db.setMetaString('activePhone', phone);
    _composerCtrl.text = msg;
    await _sendSmsToActive();
  }

  Future<void> _createNewConversation() async {
    final phoneCtrl = TextEditingController();
    final msgCtrl = TextEditingController();
    var selectedSimSlot = _selectedSendSimSlot ?? (_gatewaySimProfiles.isNotEmpty ? _gatewaySimProfiles.first.slotIndex : null);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(tr('新短信', 'New SMS')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: phoneCtrl, decoration: InputDecoration(labelText: tr('号码', 'Phone'))),
                const SizedBox(height: 8),
                TextField(controller: msgCtrl, decoration: InputDecoration(labelText: tr('内容', 'Message')), maxLines: 3),
                if (_showSimSelection) ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    value: selectedSimSlot,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: tr('发送卡', 'SIM'),
                    ),
                    items: _gatewaySimProfiles
                        .map(
                          (sim) => DropdownMenuItem<int>(
                            value: sim.slotIndex,
                            child: Text(_displaySimLabel(sim.slotIndex)),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => setDialogState(() => selectedSimSlot = value),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('取消', 'Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('发送', 'Send'))),
          ],
        ),
      ),
    );

    if (ok != true) return;
    final phone = phoneCtrl.text.trim();
    final msg = msgCtrl.text.trim();
    if (phone.isEmpty || msg.isEmpty) {
      setState(() => _status = tr('号码和内容不能为空', 'Phone/content required'));
      return;
    }

    if (_showSimSelection) {
      final allowedSlots = _gatewaySimProfiles.map((e) => e.slotIndex).toSet();
      if (selectedSimSlot != null && !allowedSlots.contains(selectedSimSlot)) {
        selectedSimSlot = null;
      }
      _selectedSendSimSlot = selectedSimSlot;
      if (selectedSimSlot != null) {
        await _db.setMetaInt('selectedSendSimSlot', selectedSimSlot!);
      }
    }

    _activePhone = phone;
    await _db.setMetaString('activePhone', phone);
    _composerCtrl.text = msg;
    await _sendSmsToActive();
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

  Future<void> _postJson(Uri url, Map<String, dynamic> data, {String? password}) async {
    final client = await widget.settings.createHttpClient(url, isZh: _isZh);
    try {
      final req = await client.postUrl(url);
      req.headers.contentType = ContentType.json;
      if ((password ?? '').trim().isNotEmpty) {
        req.headers.set('X-Password', password!.trim());
      }
      req.add(utf8.encode(jsonEncode(data)));
      final resp = await req.close();
      final body = await utf8.decodeStream(resp);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('HTTP ${resp.statusCode}: $body');
      }
    } finally {
      client.close(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 900;
    return Scaffold(
      appBar: AppBar(
        title: const Text('RemoteMessage'),
        actions: [
          IconButton(onPressed: _loading ? null : _openSettings, icon: const Icon(Icons.settings), tooltip: tr('设置', 'Settings')),
          IconButton(onPressed: _loading ? null : _createNewConversation, icon: const Icon(Icons.add_comment_outlined), tooltip: tr('新短信', 'New SMS')),
          IconButton(onPressed: _loading ? null : () => _syncInbox(), icon: const Icon(Icons.refresh), tooltip: tr('同步', 'Sync')),
        ],
      ),
      body: isMobile ? _buildMobileBody() : _buildDesktopBody(),
    );
  }

  Widget _buildStatusBlock() {
    final showProgress = _loading || _syncProgress != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${tr('状态', 'Status')}: $_status'),
        if (_gatewaySimProfiles.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            _buildGatewaySimSummary(),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (showProgress) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(value: _syncProgress),
        ],
      ],
    );
  }

  Widget _buildTopBar() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              labelText: tr('搜索会话 / 内容', 'Search conversation / message'),
              prefixIcon: Icon(Icons.search),
              border: const OutlineInputBorder(),
            ),
            onTapOutside: (_) => FocusScope.of(context).unfocus(),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _loading ? null : () => _syncInbox(fullSync: true),
          child: Text(tr('加载全部', 'Load All')),
        ),
      ],
    );
  }

  Widget _buildDesktopBody() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          _buildTopBar(),
          const SizedBox(height: 8),
          _buildStatusBlock(),
          const SizedBox(height: 8),
          Expanded(
            child: Row(
              children: [
                SizedBox(width: 320, child: _buildConversationList(onMobileTap: false)),
                const SizedBox(width: 8),
                Expanded(child: _buildChatPanel()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileBody() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          _buildTopBar(),
          const SizedBox(height: 8),
          _buildStatusBlock(),
          const SizedBox(height: 8),
          Expanded(child: _buildConversationList(onMobileTap: true)),
        ],
      ),
    );
  }

  Widget _buildConversationList({required bool onMobileTap}) {
    return Card(
      child: ValueListenableBuilder<int>(
        valueListenable: _uiRefreshTick,
        builder: (context, _, __) {
          final data = _conversationCache;
          if (data.isEmpty) return Center(child: Text(tr('暂无会话', 'No conversations')));
          return ListView.builder(
            itemCount: data.length,
            itemBuilder: (context, index) {
              final c = data[index];
              final selected = c.phone == _activePhone;
              return ListTile(
                selected: selected,
                leading: c.pinned ? const Icon(Icons.push_pin, size: 18) : null,
                title: Text(c.phone),
                subtitle: Text(
                  (() {
                    final simLabel = _simLabelForMessage(c.lastMessage);
                    final statusLabel = _messageStatusPrefix(c.lastMessage);
                    final parts = <String>[
                      if (simLabel != null) simLabel,
                      if (statusLabel != null) statusLabel,
                      c.lastMessage.content,
                    ];
                    return parts.join(' · ');
                  })(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () async {
                  await _setActivePhone(c.phone);
                  if (onMobileTap && context.mounted) {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => MobileChatPage(parent: this, phone: c.phone)),
                    );
                  }
                },
                trailing: IconButton(
                  icon: Icon(c.pinned ? Icons.push_pin : Icons.push_pin_outlined),
                  onPressed: () => _setPin(c.phone, !c.pinned),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildChatPanel() {
    return Card(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            child: Text(_activePhone == null ? tr('请选择会话', 'Select conversation') : '${tr('聊天对象', 'Chat with')} $_activePhone'),
          ),
          const Divider(height: 1),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: _uiRefreshTick,
              builder: (context, _, __) {
                final messages = _activeMessageCache;
                if (messages.isEmpty) return Center(child: Text(tr('暂无消息', 'No messages')));
                return ListView.builder(
                  controller: _chatScrollCtrl,
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final m = messages[index];
                    final mine = m.direction == 'outbound';
                    final simLabel = _simLabelForMessage(m);
                    final statusLine = _messageStatusLine(m);
                    return Align(
                      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: GestureDetector(
                        onLongPress: () => _showSimPhoneDialog(m),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          padding: const EdgeInsets.all(10),
                          constraints: const BoxConstraints(maxWidth: 460),
                          decoration: BoxDecoration(
                            color: mine
                                ? Theme.of(context).colorScheme.primaryContainer
                                : Theme.of(context).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                            children: [
                              if (simLabel != null) ...[
                                Text(
                                  simLabel,
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                                const SizedBox(height: 4),
                              ],
                              Text(m.content),
                              if (statusLine != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  statusLine,
                                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: m.sendStatus == 'failed'
                                        ? Theme.of(context).colorScheme.error
                                        : Theme.of(context).textTheme.labelSmall?.color,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 4),
                              Text(
                                DateTime.fromMillisecondsSinceEpoch(m.timestamp).toLocal().toString(),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                if (_showSimSelection) ...[
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 96, maxWidth: 120),
                    child: DropdownButtonFormField<int>(
                      value: _selectedSendSimSlot,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        labelText: tr('发送卡', 'SIM'),
                      ),
                      items: _gatewaySimProfiles
                          .map(
                            (sim) => DropdownMenuItem<int>(
                              value: sim.slotIndex,
                              child: Text(_displaySimLabel(sim.slotIndex)),
                            ),
                          )
                          .toList(),
                      onChanged: _loading
                          ? null
                          : (value) async {
                              setState(() => _selectedSendSimSlot = value);
                              if (value != null) {
                                await _db.setMetaInt('selectedSendSimSlot', value);
                              }
                            },
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: TextField(
                    controller: _composerCtrl,
                    decoration: InputDecoration(hintText: tr('输入消息...', 'Type a message...'), border: const OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _loading ? null : _sendSmsToActive, child: Text(tr('发送', 'Send'))),
              ],
            ),
          )
        ],
      ),
    );
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _searchDebounceTimer?.cancel();
    _uiRefreshTick.dispose();
    _chatScrollCtrl.dispose();
    _serverCtrl.dispose();
    _deviceCtrl.dispose();
    _searchCtrl.dispose();
    _composerCtrl.dispose();
    super.dispose();
  }

  bool get _showSimSelection => _gatewaySimProfiles.length > 1;

  String _buildGatewaySimSummary() {
    return _gatewaySimProfiles.map((sim) {
      final label = _displaySimLabel(sim.slotIndex);
      final num = sim.phoneNumber?.trim();
      if (num == null || num.isEmpty) return label;
      return '$label: $num';
    }).join('    ');
  }

  String _displaySimLabel(int slotIndex) {
    return tr('卡${slotIndex + 1}', 'SIM ${slotIndex + 1}');
  }

  String? _simLabelForMessage(SmsItem item) {
    final targetSimPhone = item.simPhoneNumber?.trim();
    final inferredSlotIndex = item.simSlotIndex ?? _gatewaySimProfiles
        .where((sim) {
          final candidatePhone = sim.phoneNumber?.trim();
          return candidatePhone != null && candidatePhone.isNotEmpty && candidatePhone == targetSimPhone;
        })
        .map((sim) => sim.slotIndex)
        .cast<int?>()
        .firstWhere((slot) => slot != null, orElse: () => null);
    if (inferredSlotIndex == null) return null;
    final simCount = item.simCount ?? _gatewaySimProfiles.length;
    if (simCount <= 1 && _gatewaySimProfiles.length <= 1) {
      return null;
    }
    return _displaySimLabel(inferredSlotIndex);
  }

  String? _messageStatusPrefix(SmsItem item) {
    if (item.direction != 'outbound') return null;
    switch (item.sendStatus) {
      case 'queued':
        return '[Queued]';
      case 'dispatched':
        return '[Dispatching]';
      case 'sent':
        return '[Sent]';
      case 'failed':
        return '[Failed]';
      default:
        return null;
    }
  }

  String? _messageStatusLine(SmsItem item) {
    if (item.direction != 'outbound') return null;
    String? statusText;
    switch (item.sendStatus) {
      case 'queued':
        statusText = tr('状态：排队中', 'Status: queued');
        break;
      case 'dispatched':
        statusText = tr('状态：网关已接收', 'Status: dispatched');
        break;
      case 'sent':
        statusText = tr('状态：已发送', 'Status: sent');
        break;
      case 'failed':
        statusText = tr('状态：发送失败', 'Status: failed');
        break;
      default:
        statusText = null;
        break;
    }
    if (statusText == null) return null;
    final detail = item.sendErrorMessage?.trim();
    if (item.sendStatus == 'failed' && detail != null && detail.isNotEmpty) {
      return '$statusText ($detail)';
    }
    return statusText;
  }

  Future<void> _showSimPhoneDialog(SmsItem item) async {
    final phone = item.simPhoneNumber?.trim();
    if (phone == null || phone.isEmpty) return;
    final label = _simLabelForMessage(item) ?? tr('号码', 'Number');
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label),
        content: SelectableText(phone),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('关闭', 'Close')),
          ),
        ],
      ),
    );
  }
}

class DeviceSimProfile {
  final int slotIndex;
  final int? subscriptionId;
  final String? displayName;
  final String? phoneNumber;
  final int? simCount;

  DeviceSimProfile({
    required this.slotIndex,
    this.subscriptionId,
    this.displayName,
    this.phoneNumber,
    this.simCount,
  });

  factory DeviceSimProfile.fromJson(Map<String, dynamic> json) {
    return DeviceSimProfile(
      slotIndex: (json['slotIndex'] as num?)?.toInt() ?? 0,
      subscriptionId: (json['subscriptionId'] as num?)?.toInt(),
      displayName: json['displayName']?.toString(),
      phoneNumber: json['phoneNumber']?.toString(),
      simCount: (json['simCount'] as num?)?.toInt(),
    );
  }
}

class MobileChatPage extends StatefulWidget {
  final _MessageHomePageState parent;
  final String phone;
  const MobileChatPage({super.key, required this.parent, required this.phone});

  @override
  State<MobileChatPage> createState() => _MobileChatPageState();
}

class _MobileChatPageState extends State<MobileChatPage> {
  @override
  Widget build(BuildContext context) {
    widget.parent._activePhone = widget.phone;
    return Scaffold(
      appBar: AppBar(title: Text(widget.phone)),
      body: widget.parent._buildChatPanel(),
    );
  }
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

  Future<void> _reloadCertStatus() async {
    final file = await widget.settings.trustedCertificateFile();
    final exists = await file.exists();
    if (!mounted) return;
    setState(() {
      _certStatus = exists
          ? tr('已导入服务器证书，HTTPS 将仅信任该证书', 'Server certificate imported. HTTPS will trust only this certificate.')
          : tr('未导入服务器证书；使用 HTTPS 前请先导入 server-cert.cer', 'No server certificate imported. Import server-cert.cer before using HTTPS.');
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
      await _reloadCertStatus();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${tr('证书已导入：', 'Certificate imported: ')}${file.name}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _certStatus = '${tr('证书导入失败', 'Certificate import failed')}: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${tr('证书导入失败', 'Certificate import failed')}: $e')),
      );
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
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('清空', 'Clear')),
          ),
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
              child: Text(
                _certStatus,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _saveAndClose,
              icon: const Icon(Icons.save),
              label: Text(tr('保存', 'Save')),
            )
          ],
        ),
      ),
    );
  }
}

class SettingsResult {
  final String serverBaseUrl;
  final String deviceId;
  final String password;
  final ThemeMode themeMode;
  final bool clearLocalDatabase;
  SettingsResult({
    required this.serverBaseUrl,
    required this.deviceId,
    required this.password,
    required this.themeMode,
    this.clearLocalDatabase = false,
  });
}

class AppSettingsStore {
  String serverBaseUrl = 'https://127.0.0.1:5001';
  String deviceId = 'android-arm64-gateway';
  String password = '';
  ThemeMode themeMode = ThemeMode.system;

  sqlite.Database? _db;

  Future<void> load() async {
    final db = await _openDb();
    _ensureSchema(db);
    serverBaseUrl = _read(db, 'serverBaseUrl') ?? serverBaseUrl;
    deviceId = _read(db, 'deviceId') ?? deviceId;
    password = _read(db, 'password') ?? password;
    themeMode = _parseThemeMode(_read(db, 'themeMode') ?? 'system');
  }

  Future<void> save() async {
    final db = await _openDb();
    _ensureSchema(db);
    _write(db, 'serverBaseUrl', serverBaseUrl);
    _write(db, 'deviceId', deviceId);
    _write(db, 'password', password);
    _write(db, 'themeMode', themeMode.name);
  }

  void _ensureSchema(sqlite.Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS settings(
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
  }

  String? _read(sqlite.Database db, String key) {
    final rows = db.select('SELECT value FROM settings WHERE key = ?', [key]);
    if (rows.isEmpty) return null;
    return rows.first['value']?.toString();
  }

  void _write(sqlite.Database db, String key, String value) {
    db.execute(
      'INSERT OR REPLACE INTO settings(key, value) VALUES(?, ?);',
      [key, value],
    );
  }

  Future<sqlite.Database> _openDb() async {
    if (_db != null) return _db!;
    final file = await _settingsFile();
    await file.parent.create(recursive: true);
    _db = sqlite.sqlite3.open(file.path);
    return _db!;
  }

  Future<File> trustedCertificateFile() async {
    final base = await _appPrivateBaseDir();
    return File(p.join(base, 'trusted_server_cert.cer'));
  }

  Future<void> importTrustedCertificate(Uint8List bytes) async {
    final normalized = _normalizeCertificateBytes(bytes);
    final context = SecurityContext(withTrustedRoots: false);
    context.setTrustedCertificatesBytes(normalized);
    final file = await trustedCertificateFile();
    await file.parent.create(recursive: true);
    await file.writeAsBytes(normalized, flush: true);
  }

  Future<HttpClient> createHttpClient(Uri url, {required bool isZh}) async {
    if (!url.scheme.toLowerCase().startsWith('https')) {
      return HttpClient();
    }

    final file = await trustedCertificateFile();
    if (!await file.exists()) {
      throw Exception(
        isZh
            ? '当前为 HTTPS 连接，请先在设置中导入 server-cert.cer'
            : 'HTTPS is enabled. Please import server-cert.cer in Settings first.',
      );
    }

    final bytes = await file.readAsBytes();
    final context = SecurityContext(withTrustedRoots: false);
    context.setTrustedCertificatesBytes(bytes);
    return HttpClient(context: context);
  }

  Uint8List _normalizeCertificateBytes(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    if (text.contains('-----BEGIN CERTIFICATE-----')) {
      return Uint8List.fromList(utf8.encode(text));
    }

    final b64 = base64Encode(bytes);
    final buffer = StringBuffer('-----BEGIN CERTIFICATE-----\n');
    for (var i = 0; i < b64.length; i += 64) {
      final end = (i + 64 < b64.length) ? i + 64 : b64.length;
      buffer.writeln(b64.substring(i, end));
    }
    buffer.write('-----END CERTIFICATE-----\n');
    return Uint8List.fromList(utf8.encode(buffer.toString()));
  }

  ThemeMode _parseThemeMode(String text) {
    switch (text) {
      case 'dark':
        return ThemeMode.dark;
      case 'light':
        return ThemeMode.light;
      default:
        return ThemeMode.system;
    }
  }
}

class LocalDatabase {
  sqlite.Database? _db;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    final file = await _dbFile();
    await file.parent.create(recursive: true);
    _db = sqlite.sqlite3.open(file.path);
    _ensureSchema(_db!);
    _initialized = true;
  }

  Future<bool> upsertMessage(SmsItem item) async {
    await init();
    final db = _db!;
    _insertMessageIgnore(db, item);
    final inserted = (db.select('SELECT changes() AS c;').first['c'] as int) > 0;
    if (!inserted) {
      _updateMessageById(db, item);
    }
    return inserted;
  }

  Future<int> upsertMessages(List<SmsItem> items, {void Function(int done, int total)? onProgress}) async {
    await init();
    if (items.isEmpty) {
      onProgress?.call(0, 0);
      return 0;
    }

    final db = _db!;
    var added = 0;
    db.execute('BEGIN IMMEDIATE;');
    try {
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        _insertMessageIgnore(db, item);
        final inserted = (db.select('SELECT changes() AS c;').first['c'] as int) > 0;
        if (inserted) {
          added++;
        } else {
          _updateMessageById(db, item);
        }
        if ((i + 1) % 200 == 0 || i + 1 == items.length) {
          onProgress?.call(i + 1, items.length);
        }
      }
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
    return added;
  }

  void _insertMessageIgnore(sqlite.Database db, SmsItem item) {
    db.execute(
      '''
      INSERT OR IGNORE INTO messages(
        id, device_id, phone, content, timestamp, direction, sim_slot_index, sim_phone_number, sim_count,
        send_status, send_error_code, send_error_message, updated_at
      )
      VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
      [
        item.id,
        item.deviceId,
        item.phone,
        item.content,
        item.timestamp,
        item.direction,
        item.simSlotIndex,
        item.simPhoneNumber,
        item.simCount,
        item.sendStatus,
        item.sendErrorCode,
        item.sendErrorMessage,
        item.updatedAt ?? item.timestamp,
      ],
    );
  }

  void _updateMessageById(sqlite.Database db, SmsItem item) {
    db.execute(
      '''
      UPDATE messages
      SET
        device_id = ?,
        phone = ?,
        content = ?,
        timestamp = ?,
        direction = ?,
        sim_slot_index = ?,
        sim_phone_number = ?,
        sim_count = ?,
        send_status = ?,
        send_error_code = ?,
        send_error_message = ?,
        updated_at = ?
      WHERE id = ?;
      ''',
      [
        item.deviceId,
        item.phone,
        item.content,
        item.timestamp,
        item.direction,
        item.simSlotIndex,
        item.simPhoneNumber,
        item.simCount,
        item.sendStatus,
        item.sendErrorCode,
        item.sendErrorMessage,
        item.updatedAt ?? item.timestamp,
        item.id,
      ],
    );
  }

  Future<List<SmsItem>> getMessagesByPhone(String phone) async {
    await init();
    final rows = _db!.select(
      '''
      SELECT
        id, device_id, phone, content, timestamp, direction, sim_slot_index, sim_phone_number, sim_count,
        send_status, send_error_code, send_error_message, updated_at
      FROM messages
      WHERE phone = ?
      ORDER BY timestamp ASC;
      ''',
      [phone],
    );
    return rows
        .map(
          (r) => SmsItem(
            id: r['id']?.toString() ?? '',
            deviceId: r['device_id']?.toString() ?? '',
            phone: r['phone']?.toString() ?? 'unknown',
            content: r['content']?.toString() ?? '',
            timestamp: (r['timestamp'] as num?)?.toInt() ?? 0,
            direction: r['direction']?.toString() ?? 'inbound',
            simSlotIndex: (r['sim_slot_index'] as num?)?.toInt(),
            simPhoneNumber: r['sim_phone_number']?.toString(),
            simCount: (r['sim_count'] as num?)?.toInt(),
            sendStatus: r['send_status']?.toString(),
            sendErrorCode: (r['send_error_code'] as num?)?.toInt(),
            sendErrorMessage: r['send_error_message']?.toString(),
            updatedAt: (r['updated_at'] as num?)?.toInt(),
          ),
        )
        .toList();
  }

  Future<List<ConversationSummary>> getConversationSummaries({String search = ''}) async {
    await init();
    final db = _db!;
    final normalizedSearch = search.trim().toLowerCase();
    final searchLike = '%$normalizedSearch%';
    final rows = db.select(
      '''
      SELECT
        m.id,
        m.device_id,
        m.phone,
        m.content,
        m.timestamp,
        m.direction,
        m.sim_slot_index,
        m.sim_phone_number,
        m.sim_count,
        m.send_status,
        m.send_error_code,
        m.send_error_message,
        m.updated_at,
        CASE WHEN p.phone IS NULL THEN 0 ELSE 1 END AS pinned
      FROM messages m
      LEFT JOIN pins p ON p.phone = m.phone
      WHERE m.id = (
        SELECT m2.id
        FROM messages m2
        WHERE m2.phone = m.phone
        ORDER BY m2.timestamp DESC, m2.id DESC
        LIMIT 1
      )
      AND (
        ? = ''
        OR LOWER(m.phone) LIKE ?
        OR EXISTS (
          SELECT 1
          FROM messages s
          WHERE s.phone = m.phone
            AND (LOWER(s.phone) LIKE ? OR LOWER(s.content) LIKE ?)
        )
      )
      ORDER BY pinned DESC, m.timestamp DESC, m.id DESC;
      ''',
      [normalizedSearch, searchLike, searchLike, searchLike],
    );

    return rows
        .map(
          (r) => ConversationSummary(
            phone: r['phone']?.toString() ?? 'unknown',
            pinned: ((r['pinned'] as num?)?.toInt() ?? 0) == 1,
            lastMessage: SmsItem(
              id: r['id']?.toString() ?? '',
              deviceId: r['device_id']?.toString() ?? '',
              phone: r['phone']?.toString() ?? 'unknown',
              content: r['content']?.toString() ?? '',
              timestamp: (r['timestamp'] as num?)?.toInt() ?? 0,
              direction: r['direction']?.toString() ?? 'inbound',
              simSlotIndex: (r['sim_slot_index'] as num?)?.toInt(),
              simPhoneNumber: r['sim_phone_number']?.toString(),
              simCount: (r['sim_count'] as num?)?.toInt(),
              sendStatus: r['send_status']?.toString(),
              sendErrorCode: (r['send_error_code'] as num?)?.toInt(),
              sendErrorMessage: r['send_error_message']?.toString(),
              updatedAt: (r['updated_at'] as num?)?.toInt(),
            ),
          ),
        )
        .toList();
  }

  Future<void> setPinned(String phone, bool pinned) async {
    await init();
    if (pinned) {
      _db!.execute(
        'INSERT OR REPLACE INTO pins(phone, pinned_at) VALUES(?, ?);',
        [phone, DateTime.now().millisecondsSinceEpoch],
      );
    } else {
      _db!.execute('DELETE FROM pins WHERE phone = ?;', [phone]);
    }
  }

  Future<List<String>> getPins() async {
    await init();
    final rows = _db!.select('SELECT phone FROM pins ORDER BY pinned_at DESC;');
    return rows.map((e) => e['phone']?.toString() ?? '').where((e) => e.isNotEmpty).toList();
  }

  Future<int?> getMetaInt(String key) async {
    await init();
    final rows = _db!.select('SELECT value FROM meta WHERE key = ? LIMIT 1;', [key]);
    if (rows.isEmpty) return null;
    final v = rows.first['value']?.toString();
    return int.tryParse(v ?? '');
  }

  Future<void> setMetaInt(String key, int value) async {
    await init();
    _db!.execute('INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?);', [key, value.toString()]);
  }

  Future<String?> getMetaString(String key) async {
    await init();
    final rows = _db!.select('SELECT value FROM meta WHERE key = ? LIMIT 1;', [key]);
    if (rows.isEmpty) return null;
    return rows.first['value']?.toString();
  }

  Future<void> setMetaString(String key, String value) async {
    await init();
    _db!.execute('INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?);', [key, value]);
  }

  Future<void> clearAllUserData() async {
    await init();
    final db = _db!;
    db.execute('BEGIN IMMEDIATE;');
    try {
      db.execute('DELETE FROM messages;');
      db.execute('DELETE FROM pins;');
      db.execute('DELETE FROM meta;');
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _ensureSchema(sqlite.Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS messages(
        id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        phone TEXT NOT NULL,
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        direction TEXT NOT NULL,
        sim_slot_index INTEGER,
        sim_phone_number TEXT,
        sim_count INTEGER,
        send_status TEXT,
        send_error_code INTEGER,
        send_error_message TEXT,
        updated_at INTEGER NOT NULL
      );
    ''');
    _tryAlterTable(db, 'ALTER TABLE messages ADD COLUMN sim_slot_index INTEGER;');
    _tryAlterTable(db, 'ALTER TABLE messages ADD COLUMN sim_phone_number TEXT;');
    _tryAlterTable(db, 'ALTER TABLE messages ADD COLUMN sim_count INTEGER;');
    _tryAlterTable(db, 'ALTER TABLE messages ADD COLUMN send_status TEXT;');
    _tryAlterTable(db, 'ALTER TABLE messages ADD COLUMN send_error_code INTEGER;');
    _tryAlterTable(db, 'ALTER TABLE messages ADD COLUMN send_error_message TEXT;');
    _tryAlterTable(db, 'ALTER TABLE messages ADD COLUMN updated_at INTEGER;');
    db.execute('UPDATE messages SET updated_at = timestamp WHERE updated_at IS NULL OR updated_at <= 0;');
    db.execute('CREATE INDEX IF NOT EXISTS idx_messages_phone_ts ON messages(phone, timestamp);');
    db.execute('CREATE INDEX IF NOT EXISTS idx_messages_ts ON messages(timestamp);');
    db.execute('CREATE INDEX IF NOT EXISTS idx_messages_updated_at ON messages(updated_at);');
    db.execute('CREATE INDEX IF NOT EXISTS idx_messages_phone_ts_id ON messages(phone, timestamp DESC, id DESC);');

    db.execute('''
      CREATE TABLE IF NOT EXISTS pins(
        phone TEXT PRIMARY KEY,
        pinned_at INTEGER NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS meta(
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
  }

  void _tryAlterTable(sqlite.Database db, String sql) {
    try {
      db.execute(sql);
    } catch (_) {
      // ignore existing column errors
    }
  }
}

class SmsItem {
  final String id;
  final String deviceId;
  final String phone;
  final String content;
  final int timestamp;
  final String direction;
  final int? simSlotIndex;
  final String? simPhoneNumber;
  final int? simCount;
  final String? sendStatus;
  final int? sendErrorCode;
  final String? sendErrorMessage;
  final int? updatedAt;

  SmsItem({
    required this.id,
    required this.deviceId,
    required this.phone,
    required this.content,
    required this.timestamp,
    required this.direction,
    this.simSlotIndex,
    this.simPhoneNumber,
    this.simCount,
    this.sendStatus,
    this.sendErrorCode,
    this.sendErrorMessage,
    this.updatedAt,
  });

  int get syncCursorTs {
    final updated = updatedAt ?? 0;
    return updated > timestamp ? updated : timestamp;
  }

  factory SmsItem.fromJson(Map<String, dynamic> json) {
    int? toInt(dynamic value) {
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '');
    }

    return SmsItem(
      id: json['id']?.toString() ?? '',
      deviceId: json['deviceId']?.toString() ?? '',
      phone: json['phone']?.toString() ?? 'unknown',
      content: json['content']?.toString() ?? '',
      timestamp: toInt(json['timestamp']) ?? 0,
      direction: json['direction']?.toString() ?? 'inbound',
      simSlotIndex: toInt(json['simSlotIndex'] ?? json['sim_slot_index']),
      simPhoneNumber: (json['simPhoneNumber'] ?? json['sim_phone_number'])?.toString(),
      simCount: toInt(json['simCount'] ?? json['sim_count']),
      sendStatus: (json['sendStatus'] ?? json['send_status'])?.toString(),
      sendErrorCode: toInt(json['sendErrorCode'] ?? json['send_error_code']),
      sendErrorMessage: (json['sendErrorMessage'] ?? json['send_error_message'])?.toString(),
      updatedAt: toInt(json['updatedAt'] ?? json['updated_at']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'deviceId': deviceId,
        'phone': phone,
        'content': content,
        'timestamp': timestamp,
        'direction': direction,
        'simSlotIndex': simSlotIndex,
        'simPhoneNumber': simPhoneNumber,
        'simCount': simCount,
        'sendStatus': sendStatus,
        'sendErrorCode': sendErrorCode,
        'sendErrorMessage': sendErrorMessage,
        'updatedAt': updatedAt,
      };
}

class ConversationSummary {
  final String phone;
  final SmsItem lastMessage;
  final bool pinned;

  const ConversationSummary({
    required this.phone,
    required this.lastMessage,
    this.pinned = false,
  });
}

Future<File> _dbFile() async {
  final base = await _appPrivateBaseDir();
  return File(p.join(base, 'client_private.sqlite'));
}

Future<File> _settingsFile() async {
  final base = await _appPrivateBaseDir();
  return File(p.join(base, 'settings_private.sqlite'));
}

Future<String> _appPrivateBaseDir() async {
  try {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'RemoteMessage');
  } catch (_) {
    if (Platform.isWindows) {
      return p.join(Platform.environment['APPDATA'] ?? Directory.systemTemp.path, 'RemoteMessage');
    }
    return p.join(Platform.environment['HOME'] ?? Directory.systemTemp.path, '.remote_message');
  }
}
