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
  final _phoneCtrl = TextEditingController();
  final _contentCtrl = TextEditingController();

  bool _loading = false;
  String _status = 'Ready';
  List<SmsItem> _items = [];

  Future<void> _loadInbox() async {
    setState(() {
      _loading = true;
      _status = 'Loading inbox...';
    });
    try {
      final url = Uri.parse('${_serverCtrl.text.trim()}/api/client/inbox');
      final response = await _getJson(url);
      final list = (jsonDecode(response) as List)
          .map((e) => SmsItem.fromJson(e as Map<String, dynamic>))
          .toList();
      setState(() {
        _items = list.reversed.toList();
        _status = 'Inbox loaded: ${_items.length} messages';
      });
    } catch (e) {
      setState(() => _status = 'Load inbox failed: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _sendSms() async {
    final server = _serverCtrl.text.trim();
    final device = _deviceCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    final content = _contentCtrl.text.trim();
    if (server.isEmpty || device.isEmpty || phone.isEmpty || content.isEmpty) {
      setState(() => _status = 'Please fill server/device/phone/content');
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
      setState(() => _status = 'Send task queued');
      _contentCtrl.clear();
    } catch (e) {
      setState(() => _status = 'Send failed: $e');
    } finally {
      setState(() => _loading = false);
    }
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
        title: const Text('RemoteMessage Client'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _loadInbox,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh Inbox',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            TextField(
              controller: _serverCtrl,
              decoration: const InputDecoration(
                labelText: 'Server Base URL',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _deviceCtrl,
              decoration: const InputDecoration(
                labelText: 'Gateway Device ID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _phoneCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Target Phone',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _contentCtrl,
                    decoration: const InputDecoration(
                      labelText: 'SMS Content',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _loading ? null : _sendSms,
                  child: const Text('Send'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Status: $_status'),
            ),
            const SizedBox(height: 8),
            const Divider(),
            Expanded(
              child: _items.isEmpty
                  ? const Center(child: Text('No inbox messages yet.'))
                  : ListView.builder(
                      itemCount: _items.length,
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        return Card(
                          child: ListTile(
                            title: Text(item.phone),
                            subtitle: Text(item.content),
                            trailing: Text(
                              DateTime.fromMillisecondsSinceEpoch(item.timestamp)
                                  .toLocal()
                                  .toString(),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class SmsItem {
  final String phone;
  final String content;
  final int timestamp;

  SmsItem({
    required this.phone,
    required this.content,
    required this.timestamp,
  });

  factory SmsItem.fromJson(Map<String, dynamic> json) {
    return SmsItem(
      phone: json['phone']?.toString() ?? 'unknown',
      content: json['content']?.toString() ?? '',
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
    );
  }
}
