import 'dart:convert';
import 'dart:io';

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
      title: 'RemoteMessage Client',
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

  final LocalDatabase _db = LocalDatabase();
  bool _loading = false;
  String _status = 'Ready';
  String _search = '';
  String? _activePhone;
  int _lastSyncTs = 0;

  @override
  void initState() {
    super.initState();
    _serverCtrl = TextEditingController(text: widget.settings.serverBaseUrl);
    _deviceCtrl = TextEditingController(text: widget.settings.deviceId);
    _searchCtrl.addListener(() {
      setState(() => _search = _searchCtrl.text.trim().toLowerCase());
    });
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _db.init();
    _lastSyncTs = await _db.getMetaInt('lastSyncTs') ?? 0;
    _activePhone = await _db.getMetaString('activePhone');
    await _syncInbox(fullSync: true);
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
    widget.onThemeChanged(result.themeMode);
    setState(() => _status = 'Settings updated');
  }

  Future<void> _syncInbox({bool fullSync = false}) async {
    setState(() {
      _loading = true;
      _status = fullSync ? 'Loading full history...' : 'Syncing new messages...';
    });

    try {
      final server = _serverCtrl.text.trim();
      final since = fullSync ? 0 : _lastSyncTs;
      final url = Uri.parse('$server/api/client/inbox?sinceTs=$since&limit=10000');
      final response = await _getJson(url);
      final list = (jsonDecode(response) as List)
          .map((e) => SmsItem.fromJson(e as Map<String, dynamic>))
          .toList();

      int added = 0;
      for (final item in list) {
        final inserted = await _db.upsertMessage(item);
        if (inserted) added++;
        if (item.timestamp > _lastSyncTs) _lastSyncTs = item.timestamp;
      }

      await _db.setMetaInt('lastSyncTs', _lastSyncTs);

      final conversations = await _db.getConversationSummaries(search: _search);
      if (_activePhone == null && conversations.isNotEmpty) {
        _activePhone = conversations.first.phone;
        await _db.setMetaString('activePhone', _activePhone!);
      }

      setState(() {
        _status = 'Sync done, +$added new';
      });
    } catch (e) {
      setState(() => _status = 'Sync failed: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _setPin(String phone, bool pin) async {
    await _db.setPinned(phone, pin);
    setState(() {});
    try {
      final server = _serverCtrl.text.trim();
      await _postJson(Uri.parse('$server/api/client/conversations/pin'), {
        'phone': phone,
        'pinned': pin,
      });
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
      setState(() => _status = 'Please configure server/device and choose conversation');
      return;
    }

    setState(() {
      _loading = true;
      _status = 'Sending...';
    });

    try {
      await _postJson(Uri.parse('$server/api/client/send'), {
        'deviceId': device,
        'targetPhone': phone,
        'content': content,
      });
      _composerCtrl.clear();
      await _syncInbox();
      setState(() => _status = 'Message queued');
    } catch (e) {
      setState(() => _status = 'Send failed: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _createNewConversation() async {
    final phoneCtrl = TextEditingController();
    final msgCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New SMS'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'Phone')),
            TextField(controller: msgCtrl, decoration: const InputDecoration(labelText: 'Message'), maxLines: 3),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Send')),
        ],
      ),
    );

    if (ok != true) return;
    final phone = phoneCtrl.text.trim();
    final msg = msgCtrl.text.trim();
    if (phone.isEmpty || msg.isEmpty) {
      setState(() => _status = 'Phone/content required');
      return;
    }

    _activePhone = phone;
    await _db.setMetaString('activePhone', phone);
    _composerCtrl.text = msg;
    await _sendSmsToActive();
  }

  Future<List<ConversationSummary>> _conversations() {
    return _db.getConversationSummaries(search: _search);
  }

  Future<List<SmsItem>> _activeMessages() {
    final phone = _activePhone;
    if (phone == null) return Future.value(const []);
    return _db.getMessagesByPhone(phone);
  }

  Future<String> _getJson(Uri url) async {
    final client = HttpClient();
    final req = await client.getUrl(url);
    final resp = await req.close();
    final body = await utf8.decodeStream(resp);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('HTTP ${resp.statusCode}: $body');
    }
    return body;
  }

  Future<void> _postJson(Uri url, Map<String, dynamic> data) async {
    final client = HttpClient();
    final req = await client.postUrl(url);
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode(data)));
    final resp = await req.close();
    final body = await utf8.decodeStream(resp);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('HTTP ${resp.statusCode}: $body');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RemoteMessage Chat'),
        actions: [
          IconButton(onPressed: _loading ? null : _openSettings, icon: const Icon(Icons.settings), tooltip: 'Settings'),
          IconButton(onPressed: _loading ? null : _createNewConversation, icon: const Icon(Icons.add_comment_outlined), tooltip: 'New SMS'),
          IconButton(onPressed: _loading ? null : () => _syncInbox(), icon: const Icon(Icons.refresh), tooltip: 'Sync'),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Search conversation / message',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _loading ? null : () => _syncInbox(fullSync: true),
                  child: const Text('Load All'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerLeft, child: Text('Status: $_status')),
            const SizedBox(height: 8),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 320,
                    child: Card(
                      child: FutureBuilder<List<ConversationSummary>>(
                        future: _conversations(),
                        builder: (context, snap) {
                          final data = snap.data ?? const <ConversationSummary>[];
                          if (data.isEmpty) return const Center(child: Text('No conversations'));
                          return ListView.builder(
                            itemCount: data.length,
                            itemBuilder: (context, index) {
                              final c = data[index];
                              final selected = c.phone == _activePhone;
                              return ListTile(
                                selected: selected,
                                leading: c.pinned ? const Icon(Icons.push_pin, size: 18) : null,
                                title: Text(c.phone),
                                subtitle: Text(c.lastMessage.content, maxLines: 1, overflow: TextOverflow.ellipsis),
                                onTap: () async {
                                  _activePhone = c.phone;
                                  await _db.setMetaString('activePhone', c.phone);
                                  setState(() {});
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
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Card(
                      child: Column(
                        children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            child: Text(_activePhone == null ? 'Select conversation' : 'Chat with $_activePhone'),
                          ),
                          const Divider(height: 1),
                          Expanded(
                            child: FutureBuilder<List<SmsItem>>(
                              future: _activeMessages(),
                              builder: (context, snap) {
                                final messages = snap.data ?? const <SmsItem>[];
                                if (messages.isEmpty) return const Center(child: Text('No messages'));
                                return ListView.builder(
                                  itemCount: messages.length,
                                  itemBuilder: (context, index) {
                                    final m = messages[index];
                                    final mine = m.direction == 'outbound';
                                    return Align(
                                      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
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
                                            Text(m.content),
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
                                    decoration: const InputDecoration(hintText: 'Type a message...', border: OutlineInputBorder()),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                FilledButton(onPressed: _loading ? null : _sendSmsToActive, child: const Text('Send')),
                              ],
                            ),
                          )
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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
  late ThemeMode _themeMode;

  @override
  void initState() {
    super.initState();
    _serverCtrl = TextEditingController(text: widget.settings.serverBaseUrl);
    _deviceCtrl = TextEditingController(text: widget.settings.deviceId);
    _themeMode = widget.settings.themeMode;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _serverCtrl,
              decoration: const InputDecoration(labelText: 'Server Base URL', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _deviceCtrl,
              decoration: const InputDecoration(labelText: 'Device ID', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ThemeMode>(
              value: _themeMode,
              decoration: const InputDecoration(labelText: 'Theme', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: ThemeMode.system, child: Text('System')),
                DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
              ],
              onChanged: (v) => setState(() => _themeMode = v ?? ThemeMode.system),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: () async {
                widget.settings.serverBaseUrl = _serverCtrl.text.trim();
                widget.settings.deviceId = _deviceCtrl.text.trim();
                widget.settings.themeMode = _themeMode;
                await widget.settings.save();
                if (!mounted) return;
                Navigator.pop(
                  context,
                  SettingsResult(
                    serverBaseUrl: widget.settings.serverBaseUrl,
                    deviceId: widget.settings.deviceId,
                    themeMode: _themeMode,
                  ),
                );
              },
              icon: const Icon(Icons.save),
              label: const Text('Save'),
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
  final ThemeMode themeMode;
  SettingsResult({required this.serverBaseUrl, required this.deviceId, required this.themeMode});
}

class AppSettingsStore {
  String serverBaseUrl = 'http://127.0.0.1:5000';
  String deviceId = 'android-arm64-gateway';
  ThemeMode themeMode = ThemeMode.system;

  sqlite.Database? _db;

  Future<void> load() async {
    final db = await _openDb();
    _ensureSchema(db);
    serverBaseUrl = _read(db, 'serverBaseUrl') ?? serverBaseUrl;
    deviceId = _read(db, 'deviceId') ?? deviceId;
    themeMode = _parseThemeMode(_read(db, 'themeMode') ?? 'system');
  }

  Future<void> save() async {
    final db = await _openDb();
    _ensureSchema(db);
    _write(db, 'serverBaseUrl', serverBaseUrl);
    _write(db, 'deviceId', deviceId);
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
    db.execute(
      '''
      INSERT OR IGNORE INTO messages(id, device_id, phone, content, timestamp, direction)
      VALUES(?, ?, ?, ?, ?, ?);
      ''',
      [item.id, item.deviceId, item.phone, item.content, item.timestamp, item.direction],
    );
    final changes = db.select('SELECT changes() AS c;').first['c'] as int;
    return changes > 0;
  }

  Future<List<SmsItem>> getMessagesByPhone(String phone) async {
    await init();
    final rows = _db!.select(
      'SELECT id, device_id, phone, content, timestamp, direction FROM messages WHERE phone = ? ORDER BY timestamp ASC;',
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
          ),
        )
        .toList();
  }

  Future<List<ConversationSummary>> getConversationSummaries({String search = ''}) async {
    await init();
    final db = _db!;
    final pinSet = (await getPins()).toSet();
    final rows = db.select(
      'SELECT id, device_id, phone, content, timestamp, direction FROM messages ORDER BY timestamp ASC;',
    );

    final messages = rows
        .map(
          (r) => SmsItem(
            id: r['id']?.toString() ?? '',
            deviceId: r['device_id']?.toString() ?? '',
            phone: r['phone']?.toString() ?? 'unknown',
            content: r['content']?.toString() ?? '',
            timestamp: (r['timestamp'] as num?)?.toInt() ?? 0,
            direction: r['direction']?.toString() ?? 'inbound',
          ),
        )
        .toList();

    final map = <String, SmsItem>{};
    for (final m in messages) {
      if (search.isNotEmpty) {
        final hit = m.phone.toLowerCase().contains(search) || m.content.toLowerCase().contains(search);
        if (!hit) continue;
      }
      final old = map[m.phone];
      if (old == null || old.timestamp < m.timestamp) {
        map[m.phone] = m;
      }
    }

    final list = map.entries
        .map((e) => ConversationSummary(phone: e.key, lastMessage: e.value, pinned: pinSet.contains(e.key)))
        .toList();

    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.lastMessage.timestamp.compareTo(a.lastMessage.timestamp);
    });
    return list;
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

  void _ensureSchema(sqlite.Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS messages(
        id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        phone TEXT NOT NULL,
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        direction TEXT NOT NULL
      );
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_messages_phone_ts ON messages(phone, timestamp);');
    db.execute('CREATE INDEX IF NOT EXISTS idx_messages_ts ON messages(timestamp);');

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
}

class SmsItem {
  final String id;
  final String deviceId;
  final String phone;
  final String content;
  final int timestamp;
  final String direction;

  SmsItem({
    required this.id,
    required this.deviceId,
    required this.phone,
    required this.content,
    required this.timestamp,
    required this.direction,
  });

  factory SmsItem.fromJson(Map<String, dynamic> json) {
    return SmsItem(
      id: json['id']?.toString() ?? '',
      deviceId: json['deviceId']?.toString() ?? '',
      phone: json['phone']?.toString() ?? 'unknown',
      content: json['content']?.toString() ?? '',
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      direction: json['direction']?.toString() ?? 'inbound',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'deviceId': deviceId,
        'phone': phone,
        'content': content,
        'timestamp': timestamp,
        'direction': direction,
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
