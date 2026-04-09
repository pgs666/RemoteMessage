import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

import 'android_launcher_icon_service.dart';
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

class _MessageHomePageState extends State<MessageHomePage> with WidgetsBindingObserver {
  static const _autoRefreshInterval = Duration(seconds: 20);

  late final TextEditingController _serverCtrl;
  late final TextEditingController _deviceCtrl;
  final _searchCtrl = TextEditingController();
  final _composerCtrl = TextEditingController();
  final _composerFocusNode = FocusNode();
  final _chatScrollCtrl = ScrollController();
  final ValueNotifier<int> _uiRefreshTick = ValueNotifier(0);

  LocalDatabase? _db;
  Timer? _autoRefreshTimer;

  bool _loading = false;
  bool _syncingNow = false;
  String _search = '';
  String? _activePhone;
  String _activeProfileId = 'default';
  int _lastSyncTs = 0;
  double? _syncProgress;
  List<ConversationSummary> _conversationCache = const [];
  List<SmsItem> _activeMessageCache = const [];
  List<DeviceSimProfile> _gatewaySimProfiles = const [];
  int? _selectedSendSimSlot;

  bool _contactsLoading = false;
  bool _contactsGranted = false;
  Map<String, String> _contactNameByPhoneKey = const {};

  bool get _isZh => WidgetsBinding.instance.platformDispatcher.locale.languageCode.toLowerCase().startsWith('zh');
  String tr(String zh, String en) => _isZh ? zh : en;
  bool get _showSimSelection => _gatewaySimProfiles.length > 1;

  LocalDatabase get _localDb {
    final db = _db;
    if (db == null) {
      throw StateError('Local database is not initialized.');
    }
    return db;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _serverCtrl = TextEditingController(text: widget.settings.serverBaseUrl);
    _deviceCtrl = TextEditingController(text: widget.settings.deviceId);
    _searchCtrl.addListener(() {
      _search = _searchCtrl.text.trim().toLowerCase();
      _refreshLocalCaches();
    });
    _composerFocusNode.addListener(() {
      if (_composerFocusNode.hasFocus) {
        _scrollChatToBottomSoon();
      }
    });
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopAutoRefresh();
    _uiRefreshTick.dispose();
    _chatScrollCtrl.dispose();
    _composerFocusNode.dispose();
    _serverCtrl.dispose();
    _deviceCtrl.dispose();
    _searchCtrl.dispose();
    _composerCtrl.dispose();
    _db?.close();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _scrollChatToBottomSoon();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startAutoRefresh();
      if (_contactNameByPhoneKey.isEmpty) {
        _loadContacts();
      }
    } else if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _stopAutoRefresh();
    }
  }

  void _startAutoRefresh() {
    if (_autoRefreshTimer != null) return;
    _autoRefreshTimer = Timer.periodic(_autoRefreshInterval, (_) async {
      if (!mounted || _syncingNow) return;
      await _syncInbox(fullSync: false, interactive: false);
    });
  }

  void _stopAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _syncProgress = null;
    });

    await widget.settings.load();
    _activeProfileId = widget.settings.activeProfileId;
    _serverCtrl.text = widget.settings.serverBaseUrl;
    _deviceCtrl.text = widget.settings.deviceId;

    await _openLocalDbForProfile(_activeProfileId, clearUiFirst: false);
    await _refreshGatewaySimProfiles(interactive: false);
    await _loadContacts();
    await _syncInbox(fullSync: true, interactive: true);
    _startAutoRefresh();

    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _openLocalDbForProfile(String profileId, {required bool clearUiFirst}) async {
    if (clearUiFirst && mounted) {
      setState(() {
        _conversationCache = const [];
        _activeMessageCache = const [];
        _activePhone = null;
        _syncProgress = null;
      });
    }

    await _db?.close();
    final nextDb = LocalDatabase(profileId: profileId);
    await nextDb.init();
    _db = nextDb;
    _activeProfileId = profileId;

    _lastSyncTs = await _localDb.getMetaInt('lastSyncTs') ?? 0;
    _activePhone = await _localDb.getMetaString('activePhone');
    _selectedSendSimSlot = await _localDb.getMetaInt('selectedSendSimSlot');
    await _refreshLocalCaches();
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
    if (_db == null) return;
    final conversations = await _localDb.getConversationSummaries(search: _search);
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
        await _localDb.setMetaString('activePhone', _activePhone!);
      }
    }

    final messages = _activePhone == null ? const <SmsItem>[] : await _localDb.getMessagesByPhone(_activePhone!);
    if (!mounted) return;

    setState(() {
      _conversationCache = conversations;
      _activeMessageCache = messages;
    });
    _uiRefreshTick.value++;
    _scrollChatToBottomSoon();
  }

  Future<void> _setActivePhone(String? phone) async {
    if (_db == null) return;
    _activePhone = phone;
    if (phone != null) {
      await _localDb.setMetaString('activePhone', phone);
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
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          settings: widget.settings,
          simProfiles: _gatewaySimProfiles,
        ),
      ),
    );
    if (result == null) return;

    _serverCtrl.text = result.serverBaseUrl;
    _deviceCtrl.text = result.deviceId;
    widget.settings.serverBaseUrl = result.serverBaseUrl;
    widget.settings.deviceId = result.deviceId;
    widget.settings.password = result.password;
    widget.settings.androidLauncherIconMode = result.androidLauncherIconMode;
    widget.onThemeChanged(result.themeMode);
    await AndroidLauncherIconService.applyMode(result.androidLauncherIconMode);

    final profileChanged = result.activeProfileId != _activeProfileId;
    if (profileChanged) {
      _searchCtrl.clear();
      _search = '';
      await _openLocalDbForProfile(result.activeProfileId, clearUiFirst: true);
      await _showToastStatus(tr('已切换配置，正在加载对应短信...', 'Profile switched. Loading profile messages...'));
    }

    await _refreshGatewaySimProfiles(interactive: false);

    if (result.clearLocalDatabase) {
      await _clearLocalDatabase();
      return;
    }

    await _syncInbox(fullSync: true, interactive: true);
  }

  Future<void> _clearLocalDatabase() async {
    if (!mounted || _db == null) return;
    setState(() {
      _loading = true;
      _syncProgress = null;
    });

    try {
      await _localDb.clearAllUserData();
      _lastSyncTs = 0;
      _activePhone = null;
      _selectedSendSimSlot = _gatewaySimProfiles.isNotEmpty ? _gatewaySimProfiles.first.slotIndex : null;
      if (_selectedSendSimSlot != null) {
        await _localDb.setMetaInt('selectedSendSimSlot', _selectedSendSimSlot!);
      }
      await _refreshLocalCaches();
      if (!mounted) return;
      await _showToastStatus(tr('本地数据库已清空', 'Local database cleared'));
    } catch (e) {
      if (!mounted) return;
      await _showToastStatus('${tr('清空失败', 'Clear failed')}: $e', error: true);
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
      if (selected != null && _db != null) {
        await _localDb.setMetaInt('selectedSendSimSlot', selected);
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
    if (_syncingNow || _db == null) return;

    final server = _serverCtrl.text.trim();
    if (server.isEmpty) return;

    _syncingNow = true;
    if (interactive && mounted) {
      setState(() {
        _loading = true;
        _syncProgress = null;
      });
    }

    try {
      final since = fullSync ? 0 : _lastSyncTs;
      final url = Uri.parse('$server/api/client/inbox?sinceTs=$since&limit=10000');
      final response = await _getJson(url, password: widget.settings.password);
      final list = (jsonDecode(response) as List).map((e) => SmsItem.fromJson(e as Map<String, dynamic>)).toList();

      await _refreshGatewaySimProfiles(interactive: false);

      final added = await _localDb.upsertMessages(
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
      await _localDb.setMetaInt('lastSyncTs', _lastSyncTs);
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
    if (_db == null) return;
    await _localDb.setPinned(phone, pin);
    await _refreshLocalCaches();
    try {
      final server = _serverCtrl.text.trim();
      await _postJson(Uri.parse('$server/api/client/conversations/pin'), {
        'phone': phone,
        'pinned': pin,
      }, password: widget.settings.password);
    } catch (_) {
      // keep local pin even if remote call fails
    }
  }

  Future<void> _showConversationActions(ConversationSummary conversation) async {
    final nextPinned = await showModalBottomSheet<bool>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: Icon(conversation.pinned ? Icons.push_pin_outlined : Icons.push_pin),
                title: Text(conversation.pinned ? tr('取消置顶', 'Unpin conversation') : tr('置顶会话', 'Pin conversation')),
                onTap: () => Navigator.pop(sheetContext, !conversation.pinned),
              ),
              ListTile(
                leading: const Icon(Icons.close),
                title: Text(tr('取消', 'Cancel')),
                onTap: () => Navigator.pop(sheetContext, null),
              ),
            ],
          ),
        );
      },
    );
    if (nextPinned == null) return;
    await _setPin(conversation.phone, nextPinned);
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
      if (selected != null && _db != null) {
        await _localDb.setMetaInt('selectedSendSimSlot', selected);
      }
    }

    _activePhone = draft.phone;
    if (_db != null) {
      await _localDb.setMetaString('activePhone', draft.phone);
    }
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

  Future<void> _loadContacts() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    if (_contactsLoading) return;

    _contactsLoading = true;
    try {
      final status = await FlutterContacts.permissions.request(PermissionType.read);
      final granted = status == PermissionStatus.granted || status == PermissionStatus.limited;
      if (!granted) {
        if (!mounted) return;
        setState(() {
          _contactsGranted = false;
          _contactNameByPhoneKey = const {};
        });
        return;
      }

      final contacts = await FlutterContacts.getAll(properties: {ContactProperty.phone});
      final map = <String, String>{};
      for (final c in contacts) {
        final name = c.displayName?.trim() ?? '';
        if (name.isEmpty) continue;
        for (final phone in c.phones) {
          for (final key in _buildPhoneMatchKeys(phone.number)) {
            map.putIfAbsent(key, () => name);
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _contactsGranted = true;
        _contactNameByPhoneKey = map;
      });
      _uiRefreshTick.value++;
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _contactsGranted = false;
        _contactNameByPhoneKey = const {};
      });
    } finally {
      _contactsLoading = false;
    }
  }

  Set<String> _buildPhoneMatchKeys(String raw) {
    var normalized = raw.trim();
    if (normalized.isEmpty) return const {};
    normalized = normalized.replaceAll(RegExp(r'[^\d+]'), '');
    if (normalized.startsWith('00')) {
      normalized = '+${normalized.substring(2)}';
    }
    final digits = normalized.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isEmpty) return const {};

    final keys = <String>{digits};
    if (_isZh) {
      if (digits.startsWith('86') && digits.length > 11) {
        keys.add(digits.substring(2));
      }
      if (!digits.startsWith('86')) {
        keys.add('86$digits');
      }
      if (digits.length >= 11) {
        keys.add(digits.substring(digits.length - 11));
      }
    }
    return keys;
  }

  String _displayConversationTitle(String phone) {
    for (final key in _buildPhoneMatchKeys(phone)) {
      final name = _contactNameByPhoneKey[key];
      if (name != null && name.trim().isNotEmpty) {
        return name.trim();
      }
    }
    return phone;
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
                onLongPress: () => _showConversationActions(c),
                trailing: SizedBox(
                  width: 90,
                  child: Text(
                    _formatConversationTimestamp(c.lastMessage.timestamp),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
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
        if (_db != null) {
          await _localDb.setMetaInt('selectedSendSimSlot', value);
        }
      },
      itemBuilder: (_) => _gatewaySimProfiles
          .map((sim) => PopupMenuItem<int>(value: sim.slotIndex, child: Text(_displaySimLabel(sim.slotIndex))))
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        margin: const EdgeInsets.only(right: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(999),
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
          child: Text(
            _activePhone == null ? tr('请选择会话', 'Select conversation') : _displayConversationTitle(_activePhone!),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
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
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.symmetric(vertical: 8),
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
                        borderRadius: BorderRadius.circular(16),
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
                            _formatMessageTimestamp(m.timestamp),
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
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _composerCtrl,
                    focusNode: _composerFocusNode,
                    minLines: 1,
                    maxLines: 4,
                    decoration: InputDecoration(
                      hintText: tr('输入消息...', 'Type a message...'),
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(999),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(999),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(999),
                        borderSide: BorderSide(color: Theme.of(context).colorScheme.primary, width: 1.4),
                      ),
                      suffixIcon: _showSimSelection ? _buildSimSelectorInComposer() : null,
                      suffixIconConstraints: const BoxConstraints(minWidth: 72, maxWidth: 140),
                    ),
                    onTap: _scrollChatToBottomSoon,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _loading ? null : _sendSmsToActive,
                  style: FilledButton.styleFrom(shape: const CircleBorder(), padding: const EdgeInsets.all(14)),
                  child: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ),
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
        return tr('[排队]', '[Queued]');
      case 'dispatched':
        return tr('[网关接收]', '[Dispatching]');
      case 'sent':
        return tr('[已发送]', '[Sent]');
      case 'failed':
        return tr('[失败]', '[Failed]');
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

  String _formatMessageTimestamp(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs).toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  String _formatConversationTimestamp(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs).toLocal();
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final tomorrowStart = todayStart.add(const Duration(days: 1));

    if (!dt.isBefore(todayStart) && dt.isBefore(tomorrowStart)) {
      return MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay.fromDateTime(dt),
        alwaysUse24HourFormat: MediaQuery.maybeOf(context)?.alwaysUse24HourFormat ?? false,
      );
    }

    if (dt.year == now.year) {
      return _isZh ? '${dt.month}月${dt.day}日' : '${dt.month}/${dt.day}';
    }

    return _isZh ? '${dt.year}年${dt.month}月${dt.day}日' : '${dt.year}/${dt.month}/${dt.day}';
  }

  @override
  Widget build(BuildContext context) {
    final isMobileScreen = MediaQuery.sizeOf(context).width < 900;
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
          if (!_contactsGranted && (Platform.isAndroid || Platform.isIOS))
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  tr('联系人权限未开启，列表将显示号码。', 'Contacts permission is off, phone numbers will be shown.'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
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
      floatingActionButton: isMobileScreen
          ? FloatingActionButton(
              onPressed: _loading ? null : _openComposePage,
              tooltip: tr('新短信', 'New SMS'),
              child: const Icon(Icons.edit_rounded),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
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
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.parent._setActivePhone(widget.phone);
      widget.parent._scrollChatToBottomSoon();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(title: Text(widget.parent._displayConversationTitle(widget.phone))),
      body: widget.parent._buildChatPanel(),
    );
  }
}

