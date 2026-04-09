import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_data.dart';
import 'compose_message_page.dart';
import 'settings_page.dart';

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
  List<ConversationSummary> _conversationCache = const [];
  List<SmsItem> _activeMessageCache = const [];
  List<DeviceSimProfile> _gatewaySimProfiles = const [];
  int? _selectedSendSimSlot;

  bool get _isZh => WidgetsBinding.instance.platformDispatcher.locale.languageCode.toLowerCase().startsWith('zh');
  String tr(String zh, String en) => _isZh ? zh : en;
  bool get _showSimSelection => _gatewaySimProfiles.length > 1;

  @override
  void initState() {
    super.initState();
    _serverCtrl = TextEditingController(text: widget.settings.serverBaseUrl);
    _deviceCtrl = TextEditingController(text: widget.settings.deviceId);
    _searchCtrl.addListener(() {
      _search = _searchCtrl.text.trim().toLowerCase();
      _refreshLocalCaches();
    });
    _bootstrap();
  }

  @override
  void dispose() {
    _uiRefreshTick.dispose();
    _chatScrollCtrl.dispose();
    _serverCtrl.dispose();
    _deviceCtrl.dispose();
    _searchCtrl.dispose();
    _composerCtrl.dispose();
    super.dispose();
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
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _showToastStatus(String text, {bool error = false}) async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 88),
        duration: const Duration(seconds: 2),
        backgroundColor: error ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.inverseSurface,
        content: Text(
          text,
          style: TextStyle(color: error ? Theme.of(context).colorScheme.onError : Theme.of(context).colorScheme.onInverseSurface),
        ),
      ),
    );
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
      MaterialPageRoute(builder: (_) => SettingsPage(settings: widget.settings)),
    );
    if (result == null) return;

    _serverCtrl.text = result.serverBaseUrl;
    _deviceCtrl.text = result.deviceId;
    widget.settings.password = result.password;
    widget.onThemeChanged(result.themeMode);
    _status = tr('设置已更新', 'Settings updated');
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
      _status = tr('本地数据库已清空', 'Local database cleared');
      await _showToastStatus(_status);
    } catch (e) {
      if (!mounted) return;
      _status = '${tr('清空失败', 'Clear failed')}: $e';
      await _showToastStatus(_status, error: true);
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
      setState(() => _gatewaySimProfiles = list);
      if (interactive) {
        await _showToastStatus(tr('已刷新 SIM 信息', 'SIM info refreshed'));
      }
    } catch (e) {
      if (!interactive || !mounted) return;
      await _showToastStatus('${tr('SIM 信息刷新失败', 'SIM info refresh failed')}: $e', error: true);
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
      final list = (jsonDecode(response) as List).map((e) => SmsItem.fromJson(e as Map<String, dynamic>)).toList();

      await _refreshGatewaySimProfiles(interactive: false);

      final added = await _db.upsertMessages(
        list,
        onProgress: interactive
            ? (done, total) {
                if (!mounted) return;
                setState(() {
                  _syncProgress = total <= 0 ? 1 : 0.1 + ((done / total) * 0.75);
                });
              }
            : null,
      );

      for (final item in list) {
        final cursorTs = item.syncCursorTs;
        if (cursorTs > _lastSyncTs) _lastSyncTs = cursorTs;
      }
      await _db.setMetaInt('lastSyncTs', _lastSyncTs);
      await _refreshLocalCaches();

      if (interactive && mounted) {
        final text = added > 0 ? '${tr('同步完成', 'Sync done')}, +$added' : tr('同步完成，没有新消息', 'Sync done, no new messages');
        await _showToastStatus(text);
      }
    } catch (e) {
      if (!mounted) return;
      if (interactive) {
        await _showToastStatus('${tr('同步失败', 'Sync failed')}: $e', error: true);
      }
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
      await _showToastStatus(tr('请先配置服务端并选择会话', 'Please configure server/device and choose conversation'), error: true);
      return;
    }

    setState(() {
      _loading = true;
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
      await _showToastStatus(tr('消息已进入队列', 'Message queued'));
    } catch (e) {
      await _showToastStatus('${tr('发送失败', 'Send failed')}: $e', error: true);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _openComposePage() async {
    final draft = await Navigator.push<ComposeDraft>(
      context,
      MaterialPageRoute(
        builder: (_) => ComposeMessagePage(
          isZh: _isZh,
          simProfiles: _gatewaySimProfiles,
          selectedSimSlot: _selectedSendSimSlot,
        ),
      ),
    );
    if (draft == null) return;

    if (_showSimSelection) {
      final allowedSlots = _gatewaySimProfiles.map((e) => e.slotIndex).toSet();
      var selected = draft.simSlotIndex;
      if (selected != null && !allowedSlots.contains(selected)) {
        selected = null;
      }
      _selectedSendSimSlot = selected;
      if (selected != null) {
        await _db.setMetaInt('selectedSendSimSlot', selected);
      }
    }

    _activePhone = draft.phone;
    await _db.setMetaString('activePhone', draft.phone);
    _composerCtrl.text = draft.message;
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

  String _displayConversationTitle(String phone) {
    final idx = _conversationCache.indexWhere((c) => c.phone == phone);
    if (idx < 0) return tr('联系人', 'Contact');
    return tr('联系人 ${idx + 1}', 'Contact ${idx + 1}');
  }

  Widget _buildConversationList({required bool openChatOnTap}) {
    return ValueListenableBuilder<int>(
      valueListenable: _uiRefreshTick,
      builder: (context, _, __) {
        final data = _conversationCache;
        if (data.isEmpty) {
          return RefreshIndicator(
            onRefresh: () => _syncInbox(fullSync: false, interactive: true),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(height: 320, child: Center(child: Text(tr('暂无会话', 'No conversations')))),
              ],
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () => _syncInbox(fullSync: false, interactive: true),
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: data.length,
            itemBuilder: (context, index) {
              final c = data[index];
              final selected = c.phone == _activePhone;
              return ListTile(
                selected: selected,
                leading: c.pinned ? const Icon(Icons.push_pin, size: 18) : null,
                title: Text(_displayConversationTitle(c.phone), maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  (() {
                    final simLabel = _simLabelForMessage(c.lastMessage);
                    final statusLabel = _messageStatusPrefix(c.lastMessage);
                    final parts = <String>[
                      if (simLabel != null) simLabel,
                      if (statusLabel != null) statusLabel,
                      c.lastMessage.content,
                    ];
                    return parts.join(' | ');
                  })(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () async {
                  await _setActivePhone(c.phone);
                  if (openChatOnTap && context.mounted) {
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
          ),
        );
      },
    );
  }

  Widget _buildSimSelectorInComposer() {
    final label = _selectedSendSimSlot == null ? tr('发卡', 'SIM') : _displaySimLabel(_selectedSendSimSlot!);
    return PopupMenuButton<int>(
      initialValue: _selectedSendSimSlot,
      onSelected: (value) async {
        setState(() => _selectedSendSimSlot = value);
        await _db.setMetaInt('selectedSendSimSlot', value);
      },
      itemBuilder: (_) => _gatewaySimProfiles
          .map((sim) => PopupMenuItem<int>(value: sim.slotIndex, child: Text(_displaySimLabel(sim.slotIndex))))
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        margin: const EdgeInsets.only(right: 4),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(width: 2),
            const Icon(Icons.arrow_drop_down, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildChatPanel() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          child: Text(_activePhone == null ? tr('请选择会话', 'Select conversation') : _displayConversationTitle(_activePhone!)),
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
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      padding: const EdgeInsets.all(10),
                      constraints: const BoxConstraints(maxWidth: 460),
                      decoration: BoxDecoration(
                        color: mine ? Theme.of(context).colorScheme.primaryContainer : Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                        children: [
                          if (simLabel != null) ...[
                            Text(simLabel, style: Theme.of(context).textTheme.labelSmall),
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
              Expanded(
                child: TextField(
                  controller: _composerCtrl,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: tr('输入消息...', 'Type a message...'),
                    border: const OutlineInputBorder(),
                    suffixIcon: _showSimSelection ? _buildSimSelectorInComposer() : null,
                    suffixIconConstraints: const BoxConstraints(minWidth: 68, maxWidth: 124),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _loading ? null : _sendSmsToActive, child: Text(tr('发送', 'Send'))),
            ],
          ),
        )
      ],
    );
  }

  String _displaySimLabel(int slotIndex) {
    return tr('卡${slotIndex + 1}', 'SIM ${slotIndex + 1}');
  }

  String? _simLabelForMessage(SmsItem item) {
    final targetSimPhone = item.simPhoneNumber?.trim();
    final inferredSlotIndex = item.simSlotIndex ??
        _gatewaySimProfiles
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RemoteMessage'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _openSettings,
            icon: const Icon(Icons.settings),
            tooltip: tr('设置', 'Settings'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                labelText: tr('搜索会话 / 内容', 'Search conversation / message'),
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
              ),
              onTapOutside: (_) => FocusScope.of(context).unfocus(),
            ),
          ),
          if (_loading || _syncProgress != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: LinearProgressIndicator(value: _syncProgress),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isMobile = constraints.maxWidth < 900;
                if (isMobile) {
                  return _buildConversationList(openChatOnTap: true);
                }
                return Row(
                  children: [
                    SizedBox(width: 320, child: _buildConversationList(openChatOnTap: false)),
                    const VerticalDivider(width: 1),
                    Expanded(child: _buildChatPanel()),
                  ],
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _loading ? null : _openComposePage,
        tooltip: tr('新短信', 'New SMS'),
        child: const Icon(Icons.edit_rounded),
      ),
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
      appBar: AppBar(title: Text(widget.parent._displayConversationTitle(widget.phone))),
      body: widget.parent._buildChatPanel(),
    );
  }
}
