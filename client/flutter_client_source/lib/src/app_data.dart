import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

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

class AppServerProfile {
  final String id;
  final String name;
  final String serverBaseUrl;
  final String deviceId;
  final String password;
  final int updatedAt;

  const AppServerProfile({
    required this.id,
    required this.name,
    required this.serverBaseUrl,
    required this.deviceId,
    required this.password,
    required this.updatedAt,
  });

  AppServerProfile copyWith({
    String? id,
    String? name,
    String? serverBaseUrl,
    String? deviceId,
    String? password,
    int? updatedAt,
  }) {
    return AppServerProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      serverBaseUrl: serverBaseUrl ?? this.serverBaseUrl,
      deviceId: deviceId ?? this.deviceId,
      password: password ?? this.password,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

enum AndroidLauncherIconMode {
  defaultMode('default'),
  light('light'),
  dark('dark');

  final String persistedValue;

  const AndroidLauncherIconMode(this.persistedValue);

  static AndroidLauncherIconMode fromPersisted(String? value) {
    switch ((value ?? '').trim().toLowerCase()) {
      case 'light':
        return AndroidLauncherIconMode.light;
      case 'dark':
        return AndroidLauncherIconMode.dark;
      default:
        return AndroidLauncherIconMode.defaultMode;
    }
  }
}

class AppSettingsStore {
  String serverBaseUrl = 'https://127.0.0.1:5001';
  String deviceId = 'android-arm64-gateway';
  String password = '';
  ThemeMode themeMode = ThemeMode.system;
  AndroidLauncherIconMode androidLauncherIconMode = AndroidLauncherIconMode.defaultMode;
  String activeProfileId = 'default';
  List<AppServerProfile> profiles = const [];

  sqlite.Database? _db;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  static const String _profilePasswordSecureKeyPrefix = 'profile_password_v1_';

  static bool isLikelyTlsCertificateIssue(Object error) {
    final text = error.toString().toLowerCase();
    const keywords = <String>[
      'handshakeexception',
      'handshake',
      'certificate',
      'x509',
      'tls',
      'ssl',
      'secure socket',
      'certificateverifyfailed',
    ];
    return keywords.any(text.contains);
  }

  static String iosSystemCertificateHint({required bool isZh}) {
    if (isZh) {
      return '请在 iOS 系统中安装并信任 server-cert.cer：先安装描述文件，再到 设置 > 通用 > 关于本机 > 证书信任设置 启用完全信任。';
    }
    return 'Install and trust server-cert.cer in iOS system settings (install profile first, then enable full trust under Settings > General > About > Certificate Trust Settings).';
  }

  Future<void> load() async {
    final db = await _openDb();
    _ensureSchema(db);

    themeMode = _parseThemeMode(_readSetting(db, 'themeMode') ?? 'system');
    androidLauncherIconMode = AndroidLauncherIconMode.fromPersisted(_readSetting(db, 'androidLauncherIconMode'));
    _bootstrapProfilesIfMissing(db);

    activeProfileId = _readSetting(db, 'activeProfileId') ?? activeProfileId;
    profiles = await _readProfiles(db);

    if (profiles.isEmpty) {
      _bootstrapProfilesIfMissing(db);
      profiles = await _readProfiles(db);
    }

    final active = profiles.firstWhere(
      (p) => p.id == activeProfileId,
      orElse: () => profiles.first,
    );

    if (active.id != activeProfileId) {
      activeProfileId = active.id;
      _writeSetting(db, 'activeProfileId', activeProfileId);
    }

    serverBaseUrl = active.serverBaseUrl;
    deviceId = active.deviceId;
    password = active.password;
  }

  Future<void> save() async {
    final db = await _openDb();
    _ensureSchema(db);

    final now = DateTime.now().millisecondsSinceEpoch;
    final current = profiles.firstWhere(
      (p) => p.id == activeProfileId,
      orElse: () => AppServerProfile(
        id: activeProfileId,
        name: 'Profile',
        serverBaseUrl: serverBaseUrl,
        deviceId: deviceId,
        password: password,
        updatedAt: now,
      ),
    );

    await upsertProfile(
      current.copyWith(
        serverBaseUrl: serverBaseUrl,
        deviceId: deviceId,
        password: password,
        updatedAt: now,
      ),
      setActive: true,
    );

    _writeSetting(db, 'themeMode', themeMode.name);
    _writeSetting(db, 'androidLauncherIconMode', androidLauncherIconMode.persistedValue);
    _writeSetting(db, 'activeProfileId', activeProfileId);
  }

  Future<void> saveThemeMode(ThemeMode mode) async {
    themeMode = mode;
    final db = await _openDb();
    _ensureSchema(db);
    _writeSetting(db, 'themeMode', mode.name);
  }

  Future<void> upsertProfile(AppServerProfile profile, {bool setActive = false}) async {
    final db = await _openDb();
    _ensureSchema(db);

    final normalized = profile.copyWith(
      name: profile.name.trim().isEmpty ? 'Profile' : profile.name.trim(),
      serverBaseUrl: profile.serverBaseUrl.trim(),
      deviceId: profile.deviceId.trim(),
      password: profile.password.trim(),
      updatedAt: profile.updatedAt <= 0 ? DateTime.now().millisecondsSinceEpoch : profile.updatedAt,
    );

    final persistedPassword = await _persistProfilePassword(normalized.id, normalized.password) ? '' : normalized.password;
    db.execute(
      '''
      INSERT INTO profiles(id, name, server_base_url, device_id, password, updated_at)
      VALUES(?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name,
        server_base_url = excluded.server_base_url,
        device_id = excluded.device_id,
        password = excluded.password,
        updated_at = excluded.updated_at;
      ''',
      [normalized.id, normalized.name, normalized.serverBaseUrl, normalized.deviceId, persistedPassword, normalized.updatedAt],
    );

    profiles = await _readProfiles(db);

    if (setActive) {
      activeProfileId = normalized.id;
      _writeSetting(db, 'activeProfileId', activeProfileId);
      serverBaseUrl = normalized.serverBaseUrl;
      deviceId = normalized.deviceId;
      password = normalized.password;
    }
  }

  Future<void> activateProfile(String profileId) async {
    final db = await _openDb();
    _ensureSchema(db);
    final next = profiles.firstWhere(
      (p) => p.id == profileId,
      orElse: () => profiles.first,
    );
    activeProfileId = next.id;
    serverBaseUrl = next.serverBaseUrl;
    deviceId = next.deviceId;
    password = next.password;
    _writeSetting(db, 'activeProfileId', activeProfileId);
  }

  void _ensureSchema(sqlite.Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS settings(
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS profiles(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        server_base_url TEXT NOT NULL,
        device_id TEXT NOT NULL,
        password TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_profiles_updated_at ON profiles(updated_at DESC);');
  }

  void _bootstrapProfilesIfMissing(sqlite.Database db) {
    final countRow = db.select('SELECT COUNT(1) AS c FROM profiles LIMIT 1;');
    final count = (countRow.first['c'] as num?)?.toInt() ?? 0;
    if (count > 0) return;

    final legacyServer = _readSetting(db, 'serverBaseUrl') ?? serverBaseUrl;
    final legacyDevice = _readSetting(db, 'deviceId') ?? deviceId;
    final legacyPassword = _readSetting(db, 'password') ?? password;
    final now = DateTime.now().millisecondsSinceEpoch;

    db.execute(
      'INSERT OR REPLACE INTO profiles(id, name, server_base_url, device_id, password, updated_at) VALUES(?, ?, ?, ?, ?, ?);',
      ['default', '默认配置', legacyServer, legacyDevice, legacyPassword, now],
    );
    _writeSetting(db, 'activeProfileId', 'default');
    _writeSetting(db, 'password', '');
  }

  Future<List<AppServerProfile>> _readProfiles(sqlite.Database db) async {
    final rows = db.select(
      'SELECT id, name, server_base_url, device_id, password, updated_at FROM profiles ORDER BY updated_at DESC, id ASC;',
    );

    final legacyProfiles = rows
        .map(
          (r) => AppServerProfile(
            id: r['id']?.toString() ?? '',
            name: r['name']?.toString() ?? 'Profile',
            serverBaseUrl: r['server_base_url']?.toString() ?? '',
            deviceId: r['device_id']?.toString() ?? '',
            password: r['password']?.toString() ?? '',
            updatedAt: (r['updated_at'] as num?)?.toInt() ?? 0,
          ),
        )
        .where((p) => p.id.isNotEmpty)
        .toList();

    return _resolveProfilePasswords(db, legacyProfiles);
  }

  Future<List<AppServerProfile>> _resolveProfilePasswords(sqlite.Database db, List<AppServerProfile> source) async {
    if (source.isEmpty) {
      return const [];
    }

    final result = <AppServerProfile>[];
    final legacyIdsToClear = <String>{};

    for (final profile in source) {
      final securePassword = await _readProfilePassword(profile.id);
      if (securePassword != null && securePassword.isNotEmpty) {
        if (profile.password.trim().isNotEmpty) {
          legacyIdsToClear.add(profile.id);
        }
        result.add(profile.copyWith(password: securePassword));
        continue;
      }

      final legacyPassword = profile.password.trim();
      if (legacyPassword.isNotEmpty) {
        final persisted = await _persistProfilePassword(profile.id, legacyPassword);
        if (persisted) {
          legacyIdsToClear.add(profile.id);
        }
      }
      result.add(profile.copyWith(password: legacyPassword));
    }

    if (legacyIdsToClear.isNotEmpty) {
      for (final id in legacyIdsToClear) {
        db.execute('UPDATE profiles SET password = ? WHERE id = ?;', ['', id]);
      }
    }

    return result;
  }

  String _profilePasswordSecureKey(String profileId) => '$_profilePasswordSecureKeyPrefix$profileId';

  Future<String?> _readProfilePassword(String profileId) async {
    try {
      return await _secureStorage.read(key: _profilePasswordSecureKey(profileId));
    } catch (_) {
      return null;
    }
  }

  Future<bool> _persistProfilePassword(String profileId, String passwordText) async {
    try {
      final normalized = passwordText.trim();
      if (normalized.isEmpty) {
        await _secureStorage.delete(key: _profilePasswordSecureKey(profileId));
      } else {
        await _secureStorage.write(key: _profilePasswordSecureKey(profileId), value: normalized);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  String? _readSetting(sqlite.Database db, String key) {
    final rows = db.select('SELECT value FROM settings WHERE key = ?', [key]);
    if (rows.isEmpty) return null;
    return rows.first['value']?.toString();
  }

  void _writeSetting(sqlite.Database db, String key, String value) {
    db.execute('INSERT OR REPLACE INTO settings(key, value) VALUES(?, ?);', [key, value]);
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

    final context = SecurityContext(withTrustedRoots: true);
    final file = await trustedCertificateFile();
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      context.setTrustedCertificatesBytes(bytes);
    }
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
  final String profileId;
  sqlite.Database? _db;
  bool _initialized = false;

  LocalDatabase({required this.profileId});

  Future<void> init() async {
    if (_initialized) return;
    final file = await _dbFile(profileId);
    await file.parent.create(recursive: true);
    _db = sqlite.sqlite3.open(file.path);
    _ensureSchema(_db!);
    _initialized = true;
  }

  Future<void> close() async {
    if (_db == null) return;
    _db!.dispose();
    _db = null;
    _initialized = false;
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

Future<File> _dbFile(String profileId) async {
  final base = await _appPrivateBaseDir();
  final safeId = profileId.trim().isEmpty
      ? 'default'
      : profileId.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  return File(p.join(base, 'client_private_$safeId.sqlite'));
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
