import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

void main() {
  runApp(const RemoteMessageApp());
}

class RemoteMessageApp extends StatelessWidget {
  const RemoteMessageApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RemoteMessage Client',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const MessageHomePage(),
    );
  }
}

class MessageHomePage extends StatefulWidget {
  const MessageHomePage({super.key});

  @override
  State<MessageHomePage> createState() => _MessageHomePageState();
}

class _MessageHomePageState extends State<MessageHomePage> {
  final _serverCtrl = TextEditingController(text: 'http://127.0.0.1:5000');
  final _deviceCtrl = TextEditingController(text: 'android-arm64-gateway');
  final _composerCtrl = TextEditingController();

  bool _loading = false;
  bool _initialized = false;
  String _status = 'Ready';
  String? _activePhone;
  int _lastSyncTs = 0;
  final Map<String, SmsItem> _messageById = {};

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _loadCache();
    await _syncInbox(fullSync: !_initialized);
    _initialized = true;
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

      var added = 0;
      for (final item in list) {
        if (!_messageById.containsKey(item.id)) {
          _messageById[item.id] = item;
          added++;
        }
        if (item.timestamp > _lastSyncTs) {
          _lastSyncTs = item.timestamp;
        }
      }

      if (_activePhone == null && _messageById.isNotEmpty) {
        _activePhone = _conversations.first.phone;
      }

      await _saveCache();
      setState(() {
        _status = 'Sync done, +$added new, total ${_messageById.length}';
      });
    } catch (e) {
      setState(() => _status = 'Sync failed: $e');
    } finally {
      setState(() => _loading = false);
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
      _status = 'Sending command...';
    });

    try {
      final url = Uri.parse('$server/api/client/send');
      await _postJson(url, {
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
      builder: (context) {
        return AlertDialog(
          title: const Text('New SMS'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: phoneCtrl,
                decoration: const InputDecoration(labelText: 'Phone'),
              ),
              TextField(
                controller: msgCtrl,
                decoration: const InputDecoration(labelText: 'Message'),
                maxLines: 3,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Send')),
          ],
        );
      },
    );

    if (ok != true) return;
    final phone = phoneCtrl.text.trim();
    final content = msgCtrl.text.trim();
    if (phone.isEmpty || content.isEmpty) {
      setState(() => _status = 'Phone/content required');
      return;
    }

    setState(() => _activePhone = phone);
    _composerCtrl.text = content;
    await _sendSmsToActive();
  }

  List<ConversationSummary> get _conversations {
    final map = <String, SmsItem>{};
    for (final m in _messageById.values) {
      final old = map[m.phone];
      if (old == null || old.timestamp < m.timestamp) {
        map[m.phone] = m;
      }
    }
    final list = map.entries
        .map((e) => ConversationSummary(phone: e.key, lastMessage: e.value))
        .toList();
    list.sort((a, b) => b.lastMessage.timestamp.compareTo(a.lastMessage.timestamp));
    return list;
  }

  List<SmsItem> get _activeMessages {
    final phone = _activePhone;
    if (phone == null) return [];
    final list = _messageById.values.where((m) => m.phone == phone).toList();
    list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return list;
  }

  Future<void> _loadCache() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      _lastSyncTs = (raw['lastSyncTs'] as num?)?.toInt() ?? 0;
      final arr = (raw['messages'] as List?) ?? const [];
      for (final e in arr) {
        final item = SmsItem.fromJson((e as Map).cast<String, dynamic>());
        _messageById[item.id] = item;
      }
      final active = raw['activePhone']?.toString();
      if (active != null && active.isNotEmpty) {
        _activePhone = active;
      }
      setState(() => _status = 'Cache loaded (${_messageById.length})');
    } catch (_) {
      // ignore broken cache
    }
  }

  Future<void> _saveCache() async {
    final file = await _cacheFile();
    final payload = {
      'lastSyncTs': _lastSyncTs,
      'activePhone': _activePhone,
      'messages': _messageById.values.map((e) => e.toJson()).toList(),
    };
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(payload));
  }

  Future<File> _cacheFile() async {
    late final String base;
    if (Platform.isWindows) {
      base = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    } else {
      base = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    }
    return File('$base/RemoteMessage/client_cache.json');
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
          IconButton(
            onPressed: _loading ? null : _createNewConversation,
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: 'New SMS',
          ),
          IconButton(
            onPressed: _loading ? null : () => _syncInbox(),
            icon: const Icon(Icons.refresh),
            tooltip: 'Sync',
          ),
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
                    controller: _serverCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Server',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _deviceCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Device ID',
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
                    width: 280,
                    child: Card(
                      child: _conversations.isEmpty
                          ? const Center(child: Text('No conversations'))
                          : ListView.builder(
                              itemCount: _conversations.length,
                              itemBuilder: (context, index) {
                                final c = _conversations[index];
                                final selected = c.phone == _activePhone;
                                return ListTile(
                                  selected: selected,
                                  title: Text(c.phone),
                                  subtitle: Text(
                                    c.lastMessage.content,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () async {
                                    setState(() => _activePhone = c.phone);
                                    await _saveCache();
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
                            child: _activeMessages.isEmpty
                                ? const Center(child: Text('No messages'))
                                : ListView.builder(
                                    itemCount: _activeMessages.length,
                                    itemBuilder: (context, index) {
                                      final m = _activeMessages[index];
                                      final mine = m.direction == 'outbound';
                                      return Align(
                                        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                                        child: Container(
                                          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                          padding: const EdgeInsets.all(10),
                                          constraints: const BoxConstraints(maxWidth: 420),
                                          decoration: BoxDecoration(
                                            color: mine ? Colors.blue.shade100 : Colors.grey.shade200,
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                            children: [
                                              Text(m.content),
                                              const SizedBox(height: 4),
                                              Text(
                                                DateTime.fromMillisecondsSinceEpoch(m.timestamp)
                                                    .toLocal()
                                                    .toString(),
                                                style: Theme.of(context).textTheme.bodySmall,
                                              ),
                                            ],
                                          ),
                                        ),
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
                                    decoration: const InputDecoration(
                                      hintText: 'Type a message...',
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                FilledButton(
                                  onPressed: _loading ? null : _sendSmsToActive,
                                  child: const Text('Send'),
                                )
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

  ConversationSummary({required this.phone, required this.lastMessage});
}
