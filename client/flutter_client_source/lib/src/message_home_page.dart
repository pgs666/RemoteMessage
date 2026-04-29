import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter/services.dart';

import 'android_launcher_icon_service.dart';
import 'app_data.dart';
import 'compose_message_page.dart';
import 'settings_page.dart';

enum _ChatMessageAction { delete }

class _SendMessageIntent extends Intent {
  const _SendMessageIntent();
}

class MessageHomePage extends StatefulWidget {
  final AppSettingsStore settings;
  final Future<void> Function(ThemeMode) onThemeChanged;

  const MessageHomePage({
    super.key,
    required this.settings,
    required this.onThemeChanged,
  });

  @override
  State<MessageHomePage> createState() => _MessageHomePageState();
}

class _MessageHomePageState extends State<MessageHomePage>
    with WidgetsBindingObserver {
  static const _autoRefreshInterval = Duration(seconds: 5);

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
  Future<void>? _syncInFlight;
  String _search = '';
  String? _activePhone;
  String _activeProfileId = 'default';
  int _lastSyncTs = 0;
  String _lastSyncId = '';
  double? _syncProgress;
  List<ConversationSummary> _conversationCache = const [];
  List<SmsItem> _activeMessageCache = const [];
  List<DeviceSimProfile> _gatewaySimProfiles = const [];
  int? _selectedSendSimSlot;

  bool _contactsLoading = false;
  bool _contactsGranted = false;
  bool _settingsOpening = false;
  Map<String, String> _contactNameByPhoneKey = const {};

  bool get _isZh => WidgetsBinding
      .instance
      .platformDispatcher
      .locale
      .languageCode
      .toLowerCase()
      .startsWith('zh');
  String tr(String zh, String en) => _isZh ? zh : en;
  bool get _showSimSelection => _gatewaySimProfiles.length > 1;

  String _formatErrorWithIosCertificateHint(Object error) {
    final base = error.toString();
    if (!Platform.isIOS ||
        !AppSettingsStore.isLikelyTlsCertificateIssue(error)) {
      return base;
    }
    return '$base\n${AppSettingsStore.iosSystemCertificateHint(isZh: _isZh)}';
  }

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
    final db = _db;
    _db = null;
    unawaited(db?.close() ?? Future<void>.value());
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
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _stopAutoRefresh();
    }
  }

  void _startAutoRefresh() {
    if (_autoRefreshTimer != null) return;
    _autoRefreshTimer = Timer.periodic(_autoRefreshInterval, (_) async {
      if (!mounted || _syncingNow || _syncInFlight != null) return;
      await _syncInbox(fullSync: false, interactive: false);
    });
  }

  void _stopAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
  }

  Future<void> _waitForCurrentSyncToFinish() async {
    while (true) {
      final pending = _syncInFlight;
      if (pending == null) return;
      try {
        await pending;
      } catch (_) {
        // The caller only needs the in-flight sync to stop touching the DB.
      }
    }
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _syncProgress = null;
    });

    try {
      await widget.settings.load();
      _activeProfileId = widget.settings.activeProfileId;
      _serverCtrl.text = widget.settings.serverBaseUrl;
      _deviceCtrl.text = widget.settings.deviceId;
      final settingsWarning = widget.settings.settingsLoadWarning;
      if (settingsWarning != null && settingsWarning.trim().isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(
            _showToastStatus(
              '${tr('设置读取异常', 'Settings load warning')}: $settingsWarning',
              error: true,
            ),
          );
        });
      }

      await _openLocalDbForProfile(_activeProfileId, clearUiFirst: false);
      await _refreshGatewaySimProfiles(interactive: false);
      await _loadContacts();
      await _syncInbox(fullSync: true, interactive: true);
      _startAutoRefresh();
    } catch (e) {
      if (mounted) {
        await _showToastStatus(
          '${tr('启动失败', 'Startup failed')}: ${_formatErrorWithIosCertificateHint(e)}',
          error: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _syncProgress = null;
        });
      }
    }
  }

  Future<void> _openLocalDbForProfile(
    String profileId, {
    required bool clearUiFirst,
  }) async {
    if (clearUiFirst && mounted) {
      setState(() {
        _conversationCache = const [];
        _activeMessageCache = const [];
        _activePhone = null;
        _syncProgress = null;
      });
    }

    final oldDb = _db;
    _db = null;
    await oldDb?.close();
    final nextDb = LocalDatabase(profileId: profileId);
    await nextDb.init();
    _db = nextDb;
    _activeProfileId = profileId;

    _lastSyncTs = await _localDb.getMetaInt('lastSyncTs') ?? 0;
    _lastSyncId = await _localDb.getMetaString('lastSyncId') ?? '';
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
        backgroundColor: error
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.inverseSurface,
        content: Text(
          text,
          style: TextStyle(
            color: error
                ? Theme.of(context).colorScheme.onError
                : Theme.of(context).colorScheme.onInverseSurface,
          ),
        ),
      ),
    );
  }

  Future<void> _refreshLocalCaches() async {
    final db = _db;
    if (db == null) return;
    final deviceId = _deviceCtrl.text.trim();
    final conversations = await db.getConversationSummaries(
      search: _search,
      deviceId: deviceId.isEmpty ? null : deviceId,
    );
    if (!mounted || _db != db) return;
    var nextActivePhone = _activePhone;

    if (conversations.isNotEmpty) {
      final stillExists =
          nextActivePhone != null &&
          conversations.any((c) => c.phone == nextActivePhone);
      if (!stillExists) {
        nextActivePhone = conversations.first.phone;
      }
    } else {
      nextActivePhone = null;
    }

    if (nextActivePhone != _activePhone) {
      _activePhone = nextActivePhone;
      if (_activePhone != null) {
        await db.setMetaString('activePhone', _activePhone!);
        if (!mounted || _db != db) return;
      }
    }

    final messages = _activePhone == null
        ? const <SmsItem>[]
        : await db.getMessagesByPhone(
            _activePhone!,
            deviceId: deviceId.isEmpty ? null : deviceId,
          );
    if (!mounted || _db != db) return;

    setState(() {
      _conversationCache = conversations;
      _activeMessageCache = messages;
    });
    _uiRefreshTick.value++;
    _scrollChatToBottomSoon();
  }

  Future<void> _setActivePhone(String? phone) async {
    final db = _db;
    if (db == null) return;
    _activePhone = phone;
    if (phone != null) {
      await db.setMetaString('activePhone', phone);
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
    if (_settingsOpening) return;
    _settingsOpening = true;
    _stopAutoRefresh();
    try {
      await _waitForCurrentSyncToFinish();
      await widget.settings.load();
    } catch (e) {
      _settingsOpening = false;
      _startAutoRefresh();
      if (mounted) {
        await _showToastStatus(
          '${tr('读取设置失败', 'Failed to load settings')}: ${_formatErrorWithIosCertificateHint(e)}',
          error: true,
        );
      }
      return;
    }
    if (!mounted) {
      _settingsOpening = false;
      return;
    }

    try {
      final oldDb = _db;
      _db = null;
      await oldDb?.close();
    } catch (_) {
      // The settings page owns no local-message DB work; reopen after it closes.
    }

    SettingsResult? result;
    try {
      result = await _pushSettingsPage();
    } finally {
      _settingsOpening = false;
    }
    if (!mounted) return;

    if (result == null) {
      try {
        await _openLocalDbForProfile(_activeProfileId, clearUiFirst: false);
      } catch (e) {
        await _showToastStatus(
          '${tr('打开本地数据库失败', 'Failed to open local database')}: ${_formatErrorWithIosCertificateHint(e)}',
          error: true,
        );
        return;
      } finally {
        _startAutoRefresh();
      }
      return;
    }

    _serverCtrl.text = result.serverBaseUrl;
    _deviceCtrl.text = result.deviceId;
    widget.settings.serverBaseUrl = result.serverBaseUrl;
    widget.settings.deviceId = result.deviceId;
    widget.settings.password = result.password;
    widget.settings.androidLauncherIconMode = result.androidLauncherIconMode;
    try {
      await widget.onThemeChanged(result.themeMode);
    } catch (e) {
      await _showToastStatus(
        '${tr('保存主题失败', 'Failed to save theme')}: $e',
        error: true,
      );
    }
    await AndroidLauncherIconService.applyMode(result.androidLauncherIconMode);

    final profileChanged = result.activeProfileId != _activeProfileId;
    if (profileChanged) {
      _searchCtrl.clear();
      _search = '';
    }
    try {
      await _openLocalDbForProfile(
        result.activeProfileId,
        clearUiFirst: profileChanged,
      );
    } catch (e) {
      await _showToastStatus(
        '${tr('打开本地数据库失败', 'Failed to open local database')}: ${_formatErrorWithIosCertificateHint(e)}',
        error: true,
      );
      _startAutoRefresh();
      return;
    }
    if (profileChanged) {
      await _showToastStatus(
        tr(
          '已切换配置，正在加载对应短信...',
          'Profile switched. Loading profile messages...',
        ),
      );
    }

    await _refreshGatewaySimProfiles(interactive: false);

    if (result.clearLocalDatabase) {
      try {
        await _clearLocalDatabase();
      } finally {
        _startAutoRefresh();
      }
      return;
    }

    try {
      await _syncInbox(fullSync: true, interactive: true);
    } finally {
      _startAutoRefresh();
    }
  }

  Future<SettingsResult?> _pushSettingsPage() {
    return Navigator.push<SettingsResult>(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          settings: widget.settings,
          simProfiles: _gatewaySimProfiles,
        ),
      ),
    );
  }

  Future<void> _clearLocalDatabase() async {
    final db = _db;
    if (!mounted || db == null) return;
    setState(() {
      _loading = true;
      _syncProgress = null;
    });

    try {
      await db.clearAllUserData();
      if (!mounted || _db != db) return;
      _lastSyncTs = 0;
      _lastSyncId = '';
      _activePhone = null;
      _selectedSendSimSlot = _gatewaySimProfiles.isNotEmpty
          ? _gatewaySimProfiles.first.slotIndex
          : null;
      if (_selectedSendSimSlot != null) {
        await db.setMetaInt('selectedSendSimSlot', _selectedSendSimSlot!);
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
    final db = _db;

    try {
      final response = await _getJson(
        Uri.parse(
          '$server/api/client/device-sims?deviceId=${Uri.encodeQueryComponent(device)}',
        ),
        password: widget.settings.password,
      );
      final list =
          (jsonDecode(response) as List)
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
      if (selected != null && db != null && _db == db) {
        await db.setMetaInt('selectedSendSimSlot', selected);
      }

      if (!mounted) return;
      setState(() => _gatewaySimProfiles = list);
      if (interactive) {
        await _showToastStatus(tr('已刷新 SIM 信息', 'SIM info refreshed'));
      }
    } catch (e) {
      if (!interactive || !mounted) return;
      await _showToastStatus(
        '${tr('SIM 信息刷新失败', 'SIM info refresh failed')}: ${_formatErrorWithIosCertificateHint(e)}',
        error: true,
      );
    }
  }

  Future<void> _syncInbox({
    bool fullSync = false,
    bool interactive = true,
  }) async {
    final pending = _syncInFlight;
    if (pending != null) {
      if (interactive) {
        try {
          await pending;
        } catch (_) {
          // The running sync already reported its interactive error if needed.
        }
      }
      return;
    }

    final current = _syncInboxInternal(
      fullSync: fullSync,
      interactive: interactive,
    );
    _syncInFlight = current;
    try {
      await current;
    } finally {
      if (identical(_syncInFlight, current)) {
        _syncInFlight = null;
      }
    }
  }

  Future<void> _syncInboxInternal({
    required bool fullSync,
    required bool interactive,
  }) async {
    final db = _db;
    if (_settingsOpening || db == null) return;

    final server = _serverCtrl.text.trim();
    final device = _deviceCtrl.text.trim();
    if (server.isEmpty || device.isEmpty) return;

    _syncingNow = true;
    if (interactive && mounted) {
      setState(() {
        _loading = true;
        _syncProgress = null;
      });
    }

    try {
      const pageLimit = 1000;
      var cursorTs = fullSync ? 0 : _lastSyncTs;
      var cursorId = fullSync ? '' : _lastSyncId;
      var addedTotal = 0;
      var pageCount = 0;

      while (!_settingsOpening && mounted && _db == db) {
        final url = Uri.parse(
          '$server/api/client/inbox'
          '?deviceId=${Uri.encodeQueryComponent(device)}'
          '&sinceTs=$cursorTs'
          '&afterId=${Uri.encodeQueryComponent(cursorId)}'
          '&limit=$pageLimit',
        );
        final response = await _getJson(
          url,
          password: widget.settings.password,
        );
        final list = (jsonDecode(response) as List)
            .map((e) => SmsItem.fromJson(e as Map<String, dynamic>))
            .where((e) => e.deviceId == device)
            .toList();

        if (_settingsOpening || _db != db) return;
        if (list.isEmpty) break;

        pageCount++;
        final added = await db.upsertMessages(
          list,
          onProgress: interactive
              ? (done, total) {
                  if (!mounted || _db != db) return;
                  setState(() {
                    final pageProgress = total <= 0 ? 1.0 : done / total;
                    _syncProgress = 0.1 + (pageProgress * 0.75);
                  });
                }
              : null,
        );
        addedTotal += added;

        final last = list.reduce((a, b) {
          final cursorCompare = a.syncCursorTs.compareTo(b.syncCursorTs);
          if (cursorCompare != 0) return cursorCompare > 0 ? a : b;
          return a.id.compareTo(b.id) >= 0 ? a : b;
        });
        final nextCursorTs = last.syncCursorTs;
        final nextCursorId = last.id;
        if (nextCursorTs == cursorTs && nextCursorId == cursorId) {
          throw StateError('Sync cursor did not advance.');
        }
        cursorTs = nextCursorTs;
        cursorId = nextCursorId;
        _lastSyncTs = cursorTs;
        _lastSyncId = cursorId;
        await db.setMetaInt('lastSyncTs', _lastSyncTs);
        await db.setMetaString('lastSyncId', _lastSyncId);

        if (list.length < pageLimit) break;
      }

      if (_settingsOpening || _db != db) return;
      await _refreshGatewaySimProfiles(interactive: false);
      if (_settingsOpening || _db != db) return;
      await _refreshLocalCaches();

      if (interactive && mounted) {
        final text = addedTotal > 0
            ? '${tr('同步完成', 'Sync done')}, +$addedTotal'
            : tr('同步完成，没有新消息', 'Sync done, no new messages');
        await _showToastStatus(
          pageCount > 1 ? '$text (${tr('分页', 'pages')}: $pageCount)' : text,
        );
      }
    } catch (e) {
      if (!mounted) return;
      if (interactive) {
        await _showToastStatus(
          '${tr('同步失败', 'Sync failed')}: ${_formatErrorWithIosCertificateHint(e)}',
          error: true,
        );
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
    final db = _db;
    if (db == null) return;
    await db.setPinned(phone, pin);
    await _refreshLocalCaches();
    try {
      final server = _serverCtrl.text.trim();
      await _postJson(
        Uri.parse('$server/api/client/conversations/pin'),
        {'phone': phone, 'pinned': pin},
        password: widget.settings.password,
      );
    } catch (_) {
      // keep local pin even if remote call fails
    }
  }

  Future<void> _showConversationActions(
    ConversationSummary conversation,
  ) async {
    final nextPinned = await showModalBottomSheet<bool>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: Icon(
                  conversation.pinned
                      ? Icons.push_pin_outlined
                      : Icons.push_pin,
                ),
                title: Text(
                  conversation.pinned
                      ? tr('取消置顶', 'Unpin conversation')
                      : tr('置顶会话', 'Pin conversation'),
                ),
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

  Future<void> _showMessageActions(SmsItem item) async {
    final action = await showModalBottomSheet<_ChatMessageAction>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(tr('删除短信', 'Delete message')),
                onTap: () =>
                    Navigator.pop(sheetContext, _ChatMessageAction.delete),
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
    if (action != _ChatMessageAction.delete) return;

    final confirmed = await _confirmDeleteMessageDialog();

    if (confirmed != true) return;
    await _deleteMessage(item);
  }

  Future<bool?> _confirmDeleteMessageDialog() {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(tr('删除短信', 'Delete message')),
          content: Text(
            tr(
              '确定删除这条短信吗？删除后将不会在本客户端再次显示。',
              'Delete this message? It will no longer appear on this client.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr('取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(tr('删除', 'Delete')),
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteMessage(SmsItem item) async {
    final db = _db;
    if (db == null) return;
    try {
      final deleted = await db.deleteMessageById(item.id);
      if (!deleted) {
        if (!mounted) return;
        await _showToastStatus(tr('短信不存在或已删除', 'Message already removed'));
        return;
      }
      await _refreshLocalCaches();
      if (!mounted) return;
      await _showToastStatus(tr('短信已删除', 'Message deleted'));
    } catch (e) {
      if (!mounted) return;
      await _showToastStatus('${tr('删除失败', 'Delete failed')}: $e', error: true);
    }
  }

  Future<void> _sendSmsToActive() async {
    final server = _serverCtrl.text.trim();
    final device = _deviceCtrl.text.trim();
    final phone = _activePhone?.trim() ?? '';
    final content = _composerCtrl.text.trim();
    if (server.isEmpty || device.isEmpty || phone.isEmpty || content.isEmpty) {
      await _showToastStatus(
        tr(
          '请先配置服务端并选择会话',
          'Please configure server/device and choose conversation',
        ),
        error: true,
      );
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
      await _showToastStatus(
        '${tr('发送失败', 'Send failed')}: ${_formatErrorWithIosCertificateHint(e)}',
        error: true,
      );
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
      final db = _db;
      if (selected != null && db != null) {
        await db.setMetaInt('selectedSendSimSlot', selected);
      }
    }

    _activePhone = draft.phone;
    final db = _db;
    if (db != null) {
      await db.setMetaString('activePhone', draft.phone);
    }
    _composerCtrl.text = draft.message;
    await _sendSmsToActive();
  }

  Future<String> _getJson(Uri url, {String? password}) async {
    final client = await widget.settings.createHttpClient(url, isZh: _isZh);
    try {
      final req = await client.getUrl(url);
      final secret = (password ?? '').trim();
      if (secret.isNotEmpty) {
        req.headers.set('X-Client-Token', secret);
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

  Future<void> _postJson(
    Uri url,
    Map<String, dynamic> data, {
    String? password,
  }) async {
    final client = await widget.settings.createHttpClient(url, isZh: _isZh);
    try {
      final req = await client.postUrl(url);
      req.headers.contentType = ContentType.json;
      final secret = (password ?? '').trim();
      if (secret.isNotEmpty) {
        req.headers.set('X-Client-Token', secret);
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
      final status = await FlutterContacts.permissions.request(
        PermissionType.read,
      );
      final granted =
          status == PermissionStatus.granted ||
          status == PermissionStatus.limited;
      if (!granted) {
        if (!mounted) return;
        setState(() {
          _contactsGranted = false;
          _contactNameByPhoneKey = const {};
        });
        return;
      }

      final contacts = await FlutterContacts.getAll(
        properties: {ContactProperty.phone},
      );
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
      builder: (context, unused, child) {
        final data = _conversationCache;
        if (data.isEmpty) {
          return RefreshIndicator(
            onRefresh: () => _syncInbox(fullSync: false, interactive: true),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(
                  height: 320,
                  child: Center(child: Text(tr('暂无会话', 'No conversations'))),
                ),
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
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onSecondaryTap: () => _showConversationActions(c),
                child: ListTile(
                  selected: selected,
                  leading: c.pinned
                      ? const Icon(Icons.push_pin, size: 18)
                      : null,
                  title: Text(
                    _displayConversationTitle(c.phone),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    (() {
                      final simLabel = _simLabelForMessage(c.lastMessage);
                      final statusLabel = _messageStatusPrefix(c.lastMessage);
                      final parts = <String>[
                        ?simLabel,
                        ?statusLabel,
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
                        MaterialPageRoute(
                          builder: (_) =>
                              _MobileChatPage(parent: this, phone: c.phone),
                        ),
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
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildDesktopConversationPane() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _loading ? null : _openComposePage,
              icon: const Icon(Icons.edit_rounded),
              label: Text(tr('新短信', 'New SMS')),
            ),
          ),
        ),
        Expanded(child: _buildConversationList(openChatOnTap: false)),
      ],
    );
  }

  Widget _buildSimSelectorInComposer() {
    final label = _selectedSendSimSlot == null
        ? tr('发卡', 'SIM')
        : _displaySimLabel(_selectedSendSimSlot!);
    return PopupMenuButton<int>(
      initialValue: _selectedSendSimSlot,
      onSelected: (value) async {
        setState(() => _selectedSendSimSlot = value);
        final db = _db;
        if (db != null) {
          await db.setMetaInt('selectedSendSimSlot', value);
        }
      },
      itemBuilder: (_) => _gatewaySimProfiles
          .map(
            (sim) => PopupMenuItem<int>(
              value: sim.slotIndex,
              child: Text(_displaySimLabel(sim.slotIndex)),
            ),
          )
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        margin: const EdgeInsets.only(right: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
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
            _activePhone == null
                ? tr('请选择会话', 'Select conversation')
                : _displayConversationTitle(_activePhone!),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ValueListenableBuilder<int>(
            valueListenable: _uiRefreshTick,
            builder: (context, unused, child) {
              final messages = _activeMessageCache;
              if (messages.isEmpty) {
                return Center(child: Text(tr('暂无消息', 'No messages')));
              }
              return ListView.builder(
                controller: _chatScrollCtrl,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final m = messages[index];
                  final mine = m.direction == 'outbound';
                  final simLabel = _simLabelForMessage(m);
                  final statusLine = _messageStatusLine(m);
                  return Align(
                    alignment: mine
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: GestureDetector(
                      onLongPress: () => _showMessageActions(m),
                      onSecondaryTap: () => _showMessageActions(m),
                      child: Container(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        padding: const EdgeInsets.all(10),
                        constraints: const BoxConstraints(maxWidth: 460),
                        decoration: BoxDecoration(
                          color: mine
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: mine
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.start,
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
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: m.sendStatus == 'failed'
                                          ? Theme.of(context).colorScheme.error
                                          : Theme.of(
                                              context,
                                            ).textTheme.labelSmall?.color,
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
                      fillColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHigh,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
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
                        borderSide: BorderSide(
                          color: Theme.of(context).colorScheme.primary,
                          width: 1.4,
                        ),
                      ),
                      suffixIcon: _showSimSelection
                          ? _buildSimSelectorInComposer()
                          : null,
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 72,
                        maxWidth: 140,
                      ),
                    ),
                    onTap: _scrollChatToBottomSoon,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _loading ? null : _sendSmsToActive,
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: const EdgeInsets.all(14),
                  ),
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
    final inferredSlotIndex =
        item.simSlotIndex ??
        _gatewaySimProfiles
            .where((sim) {
              final candidatePhone = sim.phoneNumber?.trim();
              return candidatePhone != null &&
                  candidatePhone.isNotEmpty &&
                  candidatePhone == targetSimPhone;
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
        alwaysUse24HourFormat:
            MediaQuery.maybeOf(context)?.alwaysUse24HourFormat ?? false,
      );
    }

    if (dt.year == now.year) {
      return _isZh ? '${dt.month}月${dt.day}日' : '${dt.month}/${dt.day}';
    }

    return _isZh
        ? '${dt.year}年${dt.month}月${dt.day}日'
        : '${dt.year}/${dt.month}/${dt.day}';
  }

  @override
  Widget build(BuildContext context) {
    final isMobileScreen = MediaQuery.sizeOf(context).width < 900;
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            const _SendMessageIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              if (!isMobileScreen && !_loading) {
                _openComposePage();
              }
              return null;
            },
          ),
          _SendMessageIntent: CallbackAction<_SendMessageIntent>(
            onInvoke: (_) {
              if (!isMobileScreen && !_loading && _composerFocusNode.hasFocus) {
                unawaited(_sendSmsToActive());
              }
              return null;
            },
          ),
        },
        child: Scaffold(
          appBar: AppBar(
            title: const Text('RemoteMessage'),
            actions: [
              IconButton(
                onPressed: _openSettings,
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
                      tr(
                        '联系人权限未开启，列表将显示号码。',
                        'Contacts permission is off, phone numbers will be shown.',
                      ),
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
                        SizedBox(
                          width: 320,
                          child: _buildDesktopConversationPane(),
                        ),
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
        ),
      ),
    );
  }
}

class _MobileChatPage extends StatefulWidget {
  final _MessageHomePageState parent;
  final String phone;

  const _MobileChatPage({required this.parent, required this.phone});

  @override
  State<_MobileChatPage> createState() => _MobileChatPageState();
}

class _MobileChatPageState extends State<_MobileChatPage> {
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
      appBar: AppBar(
        title: Text(widget.parent._displayConversationTitle(widget.phone)),
      ),
      body: widget.parent._buildChatPanel(),
    );
  }
}
