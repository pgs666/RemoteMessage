import 'dart:async';
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
      simPhoneNumber: (json['simPhoneNumber'] ?? json['sim_phone_number'])
          ?.toString(),
      simCount: toInt(json['simCount'] ?? json['sim_count']),
      sendStatus: (json['sendStatus'] ?? json['send_status'])?.toString(),
      sendErrorCode: toInt(json['sendErrorCode'] ?? json['send_error_code']),
      sendErrorMessage: (json['sendErrorMessage'] ?? json['send_error_message'])
          ?.toString(),
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

class _ProfilePasswordResult {
  final String? value;
  final bool storageFailed;

  const _ProfilePasswordResult({this.value, this.storageFailed = false});
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
  String serverBaseUrl = '';
  String deviceId = '';
  String password = '';
  ThemeMode themeMode = ThemeMode.system;
  AndroidLauncherIconMode androidLauncherIconMode =
      AndroidLauncherIconMode.defaultMode;
  String activeProfileId = 'default';
  List<AppServerProfile> profiles = const [];
  String? settingsLoadWarning;

  Future<void>? _loadInFlight;
  Future<void> _storeQueue = Future<void>.value();
  bool _secureStorageReadFailed = false;
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
    final pending = _loadInFlight;
    if (pending != null) {
      await pending;
      return;
    }

    final current = _loadInternal();
    _loadInFlight = current;
    try {
      await current;
    } finally {
      if (identical(_loadInFlight, current)) {
        _loadInFlight = null;
      }
    }
  }

  Future<void> _loadInternal() async {
    await _withSettingsStore(() async {
      settingsLoadWarning = null;
      _secureStorageReadFailed = false;
      final jsonFile = await _settingsJsonFile();
      final backupFile = _settingsBackupFile(jsonFile);
      if (await jsonFile.exists()) {
        Object? jsonReadError;
        try {
          await _readSettingsJson(jsonFile);
          if (_secureStorageReadFailed) {
            settingsLoadWarning =
                'Secure storage could not be read; saved tokens may be unavailable until the OS key store recovers.';
          }
          return;
        } catch (e) {
          jsonReadError = e;
        }

        if (await backupFile.exists()) {
          try {
            await _readSettingsJson(backupFile);
            settingsLoadWarning =
                'Settings file was unreadable; restored from backup. Original error: $jsonReadError';
            await _replaceSettingsJsonWithBackup(jsonFile, backupFile);
            return;
          } catch (_) {
            // Preserve the original JSON below and continue with in-memory defaults.
          }
        }

        final preserved = await _preserveUnreadableSettingsJson(jsonFile);
        settingsLoadWarning =
            'Settings file was unreadable and was preserved at ${preserved.path}. Original error: $jsonReadError';
        _bootstrapInMemoryDefaults();
        return;
      }
      if (await backupFile.exists()) {
        try {
          await _readSettingsJson(backupFile);
          settingsLoadWarning =
              'Settings file was missing; restored from backup.';
          await backupFile.copy(jsonFile.path);
          return;
        } catch (_) {
          // Ignore a broken backup and continue to legacy migration/defaults.
        }
      }

      try {
        final migrated = await _readLegacySqliteSettings();
        if (migrated) {
          await _writeSettingsJson(
            profiles: profiles,
            activeProfileId: activeProfileId,
            themeMode: themeMode,
            androidLauncherIconMode: androidLauncherIconMode,
          );
          return;
        }
      } catch (_) {
        // A broken legacy sqlite settings DB must not block the settings UI.
      }

      if (profiles.isEmpty) {
        _bootstrapInMemoryDefaults();
      } else {
        _applyActiveProfile(activeProfileId);
      }
      try {
        await _writeSettingsJson(
          profiles: profiles,
          activeProfileId: activeProfileId,
          themeMode: themeMode,
          androidLauncherIconMode: androidLauncherIconMode,
        );
      } catch (_) {
        // Loading can continue with in-memory settings even when persistence is temporarily unavailable.
      }
    });
  }

  Future<void> save() async {
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

    final updated = current.copyWith(
      serverBaseUrl: serverBaseUrl,
      deviceId: deviceId,
      password: password,
      updatedAt: now,
    );

    final nextProfiles = List<AppServerProfile>.from(profiles);
    final idx = nextProfiles.indexWhere((p) => p.id == updated.id);
    if (idx >= 0) {
      nextProfiles[idx] = updated;
    } else {
      nextProfiles.add(updated);
    }

    await saveProfilesAndSettings(
      profiles: nextProfiles,
      activeProfileId: updated.id,
      themeMode: themeMode,
      androidLauncherIconMode: androidLauncherIconMode,
    );
  }

  Future<void> saveThemeMode(ThemeMode mode) async {
    await _withSettingsStore(() async {
      themeMode = mode;
      await _writeSettingsJson(
        profiles: profiles,
        activeProfileId: activeProfileId,
        themeMode: themeMode,
        androidLauncherIconMode: androidLauncherIconMode,
      );
    });
  }

  Future<void> upsertProfile(
    AppServerProfile profile, {
    bool setActive = false,
  }) async {
    await _withSettingsStore(() async {
      final normalized = _normalizeProfile(
        profile,
        DateTime.now().millisecondsSinceEpoch,
      );

      final nextProfiles = List<AppServerProfile>.from(profiles);
      final idx = nextProfiles.indexWhere((p) => p.id == normalized.id);
      if (idx >= 0) {
        nextProfiles[idx] = normalized;
      } else {
        nextProfiles.add(normalized);
      }

      if (setActive) {
        activeProfileId = normalized.id;
      }

      await _writeSettingsJson(
        profiles: nextProfiles,
        activeProfileId: activeProfileId,
        themeMode: themeMode,
        androidLauncherIconMode: androidLauncherIconMode,
      );
      profiles = nextProfiles;
      _applyActiveProfile(activeProfileId);
    });
  }

  Future<void> activateProfile(String profileId) async {
    await _withSettingsStore(() async {
      if (profiles.isEmpty) {
        _bootstrapInMemoryDefaults();
      }
      final next = profiles.firstWhere(
        (p) => p.id == profileId,
        orElse: () => profiles.first,
      );
      activeProfileId = next.id;
      serverBaseUrl = next.serverBaseUrl;
      deviceId = next.deviceId;
      password = next.password;
      await _writeSettingsJson(
        profiles: profiles,
        activeProfileId: activeProfileId,
        themeMode: themeMode,
        androidLauncherIconMode: androidLauncherIconMode,
      );
    });
  }

  Future<void> saveProfilesAndSettings({
    required List<AppServerProfile> profiles,
    required String activeProfileId,
    required ThemeMode themeMode,
    required AndroidLauncherIconMode androidLauncherIconMode,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final normalized = <AppServerProfile>[];
    final seenIds = <String>{};

    for (final profile in profiles) {
      final p = _normalizeProfile(profile, now);
      if (seenIds.add(p.id)) {
        normalized.add(p);
      }
    }

    if (normalized.isEmpty) {
      normalized.add(
        AppServerProfile(
          id: 'default',
          name: 'Profile',
          serverBaseUrl: serverBaseUrl,
          deviceId: deviceId,
          password: password,
          updatedAt: now,
        ),
      );
    }

    var nextActiveProfileId = activeProfileId.trim();
    if (!normalized.any((p) => p.id == nextActiveProfileId)) {
      nextActiveProfileId = normalized.first.id;
    }

    await _withSettingsStore(() async {
      await _writeSettingsJson(
        profiles: normalized,
        activeProfileId: nextActiveProfileId,
        themeMode: themeMode,
        androidLauncherIconMode: androidLauncherIconMode,
      );
      this.themeMode = themeMode;
      this.androidLauncherIconMode = androidLauncherIconMode;
      this.activeProfileId = nextActiveProfileId;
      this.profiles = normalized;
      _applyActiveProfile(this.activeProfileId);
    });
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
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_profiles_updated_at ON profiles(updated_at DESC);',
    );
  }

  void _bootstrapProfilesIfMissing(sqlite.Database db) {
    final countRow = db.select('SELECT COUNT(1) AS c FROM profiles LIMIT 1;');
    final count = (countRow.first['c'] as num?)?.toInt() ?? 0;
    if (count > 0) return;

    final now = DateTime.now().millisecondsSinceEpoch;

    db.execute(
      'INSERT OR REPLACE INTO profiles(id, name, server_base_url, device_id, password, updated_at) VALUES(?, ?, ?, ?, ?, ?);',
      ['default', '默认配置', '', '', '', now],
    );
    _writeSetting(db, 'activeProfileId', 'default');
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

    return _resolveProfilePasswords(legacyProfiles);
  }

  Future<List<AppServerProfile>> _resolveProfilePasswords(
    List<AppServerProfile> source,
  ) async {
    if (source.isEmpty) {
      return const [];
    }

    final result = <AppServerProfile>[];

    for (final profile in source) {
      final securePassword = await _readProfilePassword(profile.id);
      if (securePassword.storageFailed) {
        _secureStorageReadFailed = true;
      }
      final password = securePassword.value;
      if (password != null && password.isNotEmpty) {
        result.add(profile.copyWith(password: password));
        continue;
      }
      result.add(profile.copyWith(password: profile.password.trim()));
    }

    return result;
  }

  String _profilePasswordSecureKey(String profileId) =>
      '$_profilePasswordSecureKeyPrefix$profileId';

  Future<_ProfilePasswordResult> _readProfilePassword(String profileId) async {
    try {
      return _ProfilePasswordResult(
        value: await _secureStorage.read(
          key: _profilePasswordSecureKey(profileId),
        ),
      );
    } catch (_) {
      return const _ProfilePasswordResult(storageFailed: true);
    }
  }

  Future<bool> _persistProfilePassword(
    String profileId,
    String passwordText,
  ) async {
    try {
      final normalized = passwordText.trim();
      if (normalized.isEmpty) {
        await _secureStorage.delete(key: _profilePasswordSecureKey(profileId));
      } else {
        await _secureStorage.write(
          key: _profilePasswordSecureKey(profileId),
          value: normalized,
        );
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
    db.execute('INSERT OR REPLACE INTO settings(key, value) VALUES(?, ?);', [
      key,
      value,
    ]);
  }

  AppServerProfile _normalizeProfile(AppServerProfile profile, int now) {
    return profile.copyWith(
      id: profile.id.trim().isEmpty ? 'default' : profile.id.trim(),
      name: profile.name.trim().isEmpty ? 'Profile' : profile.name.trim(),
      serverBaseUrl: profile.serverBaseUrl.trim(),
      deviceId: profile.deviceId.trim(),
      password: profile.password.trim(),
      updatedAt: profile.updatedAt <= 0 ? now : profile.updatedAt,
    );
  }

  void _bootstrapInMemoryDefaults() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final profile = AppServerProfile(
      id: activeProfileId.trim().isEmpty ? 'default' : activeProfileId.trim(),
      name: 'Profile',
      serverBaseUrl: serverBaseUrl.trim(),
      deviceId: deviceId.trim(),
      password: password.trim(),
      updatedAt: now,
    );
    profiles = [profile];
    activeProfileId = profile.id;
    _applyActiveProfile(activeProfileId);
  }

  void _applyActiveProfile(String profileId) {
    if (profiles.isEmpty) {
      _bootstrapInMemoryDefaults();
      return;
    }
    final active = profiles.firstWhere(
      (p) => p.id == profileId,
      orElse: () => profiles.first,
    );
    activeProfileId = active.id;
    serverBaseUrl = active.serverBaseUrl;
    deviceId = active.deviceId;
    password = active.password;
  }

  Future<void> _readSettingsJson(File file) async {
    final root = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    themeMode = _parseThemeMode(root['themeMode']?.toString() ?? 'system');
    androidLauncherIconMode = AndroidLauncherIconMode.fromPersisted(
      root['androidLauncherIconMode']?.toString(),
    );
    activeProfileId = root['activeProfileId']?.toString() ?? activeProfileId;

    final rawProfiles = root['profiles'];
    final parsedProfiles = rawProfiles is List
        ? rawProfiles
              .whereType<Map>()
              .map(
                (r) => AppServerProfile(
                  id: r['id']?.toString() ?? '',
                  name: r['name']?.toString() ?? 'Profile',
                  serverBaseUrl: r['serverBaseUrl']?.toString() ?? '',
                  deviceId: r['deviceId']?.toString() ?? '',
                  password: r['password']?.toString() ?? '',
                  updatedAt:
                      (r['updatedAt'] as num?)?.toInt() ??
                      int.tryParse(r['updatedAt']?.toString() ?? '') ??
                      0,
                ),
              )
              .where((p) => p.id.isNotEmpty)
              .toList()
        : <AppServerProfile>[];

    profiles = await _resolveProfilePasswords(parsedProfiles);
    if (profiles.isEmpty) {
      _bootstrapInMemoryDefaults();
    } else {
      _applyActiveProfile(activeProfileId);
    }
  }

  File _settingsBackupFile(File file) => File('${file.path}.bak');

  Future<void> _replaceSettingsJsonWithBackup(File file, File backup) async {
    if (await file.exists()) {
      await _preserveUnreadableSettingsJson(file);
    }
    await backup.copy(file.path);
  }

  Future<File> _preserveUnreadableSettingsJson(File file) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    var target = File('${file.path}.bad.$stamp');
    var suffix = 0;
    while (await target.exists()) {
      suffix++;
      target = File('${file.path}.bad.$stamp.$suffix');
    }
    try {
      return await file.rename(target.path);
    } catch (_) {
      await file.copy(target.path);
      return target;
    }
  }

  Future<bool> _readLegacySqliteSettings() async {
    final file = await _settingsFile();
    if (!await file.exists()) return false;
    final db = await _openSqliteDatabase(file, label: 'legacy settings');
    try {
      _ensureSchema(db);
      themeMode = _parseThemeMode(_readSetting(db, 'themeMode') ?? 'system');
      androidLauncherIconMode = AndroidLauncherIconMode.fromPersisted(
        _readSetting(db, 'androidLauncherIconMode'),
      );
      _bootstrapProfilesIfMissing(db);
      activeProfileId = _readSetting(db, 'activeProfileId') ?? activeProfileId;
      profiles = await _readProfiles(db);
      if (profiles.isEmpty) return false;
      _applyActiveProfile(activeProfileId);
      return true;
    } finally {
      db.close();
    }
  }

  Future<void> _writeSettingsJson({
    required List<AppServerProfile> profiles,
    required String activeProfileId,
    required ThemeMode themeMode,
    required AndroidLauncherIconMode androidLauncherIconMode,
  }) async {
    final normalized = <AppServerProfile>[];
    final now = DateTime.now().millisecondsSinceEpoch;
    final seenIds = <String>{};
    for (final profile in profiles) {
      final p = _normalizeProfile(profile, now);
      if (seenIds.add(p.id)) {
        normalized.add(p);
      }
    }
    if (normalized.isEmpty) {
      normalized.add(
        AppServerProfile(
          id: 'default',
          name: 'Profile',
          serverBaseUrl: serverBaseUrl,
          deviceId: deviceId,
          password: password,
          updatedAt: now,
        ),
      );
    }
    if (_secureStorageReadFailed &&
        normalized.any((profile) => profile.password.trim().isEmpty)) {
      throw StateError(
        'Secure storage is unavailable; refusing to overwrite settings to avoid losing saved tokens.',
      );
    }

    var nextActiveProfileId = activeProfileId.trim();
    if (!normalized.any((p) => p.id == nextActiveProfileId)) {
      nextActiveProfileId = normalized.first.id;
    }

    final persistedProfiles = <Map<String, dynamic>>[];
    for (final profile in normalized) {
      final secureStored = await _persistProfilePassword(
        profile.id,
        profile.password,
      );
      persistedProfiles.add({
        'id': profile.id,
        'name': profile.name,
        'serverBaseUrl': profile.serverBaseUrl,
        'deviceId': profile.deviceId,
        'password': secureStored ? '' : profile.password,
        'updatedAt': profile.updatedAt,
      });
    }

    final file = await _settingsJsonFile();
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    final backup = _settingsBackupFile(file);
    const encoder = JsonEncoder.withIndent('  ');
    await tmp.writeAsString(
      encoder.convert({
        'themeMode': themeMode.name,
        'androidLauncherIconMode': androidLauncherIconMode.persistedValue,
        'activeProfileId': nextActiveProfileId,
        'profiles': persistedProfiles,
      }),
      flush: true,
    );

    if (await backup.exists()) {
      await backup.delete();
    }
    var backupCreated = false;
    if (await file.exists()) {
      await file.rename(backup.path);
      backupCreated = true;
    }
    try {
      await tmp.rename(file.path);
    } catch (_) {
      if (backupCreated && !await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
  }

  Future<T> _withSettingsStore<T>(Future<T> Function() action) async {
    final previous = _storeQueue;
    final unlock = Completer<void>();
    _storeQueue = unlock.future;

    try {
      try {
        await previous;
      } catch (_) {
        // A failed previous operation must not permanently block later DB work.
      }

      return await action();
    } finally {
      if (!unlock.isCompleted) {
        unlock.complete();
      }
    }
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
    final scheme = url.scheme.toLowerCase();
    if (scheme == 'http') {
      if (!_isLocalDebugHttpHost(url.host)) {
        throw StateError(
          isZh
              ? 'HTTP 会明文发送客户端 token，仅允许 localhost/模拟器调试地址。请使用 HTTPS。'
              : 'HTTP sends the client token in clear text and is only allowed for localhost/emulator debug hosts. Use HTTPS.',
        );
      }
      return HttpClient();
    }
    if (scheme != 'https') {
      throw StateError(
        isZh ? '仅支持 HTTPS 地址。' : 'Only HTTPS URLs are supported.',
      );
    }

    final context = SecurityContext(withTrustedRoots: true);
    final file = await trustedCertificateFile();
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      context.setTrustedCertificatesBytes(bytes);
    }
    return HttpClient(context: context);
  }

  bool _isLocalDebugHttpHost(String host) {
    final normalized = host.trim().toLowerCase();
    return normalized == 'localhost' ||
        normalized == '::1' ||
        normalized == '10.0.2.2' ||
        normalized == '10.0.3.2' ||
        normalized.startsWith('127.');
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
  Future<void>? _initInFlight;
  Future<void> _operationQueue = Future<void>.value();
  bool _initialized = false;
  bool _closing = false;

  LocalDatabase({required this.profileId});

  Future<void> init() async {
    if (_closing) {
      throw StateError('Local database is closing.');
    }
    if (_initialized) return;
    final pending = _initInFlight;
    if (pending != null) {
      await pending;
      return;
    }

    final current = _initInternal();
    _initInFlight = current;
    try {
      await current;
    } finally {
      if (identical(_initInFlight, current)) {
        _initInFlight = null;
      }
    }
  }

  Future<void> _initInternal() async {
    if (_initialized) return;
    final file = await _dbFile(profileId);
    final db = await _openSqliteDatabase(file, label: 'local');
    try {
      _ensureSchema(db);
      _db = db;
    } catch (_) {
      db.close();
      rethrow;
    }
    _initialized = true;
  }

  Future<void> close() async {
    _closing = true;
    try {
      await _operationQueue;
    } catch (_) {
      // Closing should continue even if the previous DB operation failed.
    }
    final pending = _initInFlight;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        // Nothing to close if initialization failed.
      }
    }
    if (_db == null) return;
    _db!.close();
    _db = null;
    _initialized = false;
  }

  Future<T> _withOpenDatabase<T>(T Function(sqlite.Database db) action) async {
    final previous = _operationQueue;
    final unlock = Completer<void>();
    _operationQueue = unlock.future;

    try {
      try {
        await previous;
      } catch (_) {
        // Keep later operations usable after one failed operation.
      }
      if (_closing) {
        throw StateError('Local database is closing.');
      }
      await init();
      final db = _db;
      if (db == null) {
        throw StateError('Local database is not initialized.');
      }
      return action(db);
    } finally {
      if (!unlock.isCompleted) {
        unlock.complete();
      }
    }
  }

  Future<bool> upsertMessage(SmsItem item) async {
    return _withOpenDatabase((db) {
      if (_isMessageMarkedDeleted(db, item.id)) {
        return false;
      }
      _insertMessageIgnore(db, item);
      final inserted =
          (db.select('SELECT changes() AS c;').first['c'] as int) > 0;
      if (!inserted) {
        _updateMessageById(db, item);
      }
      return inserted;
    });
  }

  Future<int> upsertMessages(
    List<SmsItem> items, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (items.isEmpty) {
      onProgress?.call(0, 0);
      return 0;
    }

    return _withOpenDatabase((db) {
      final deletedIds = _loadDeletedMessageIdSet(
        db,
        items.map((e) => e.id).where((id) => id.isNotEmpty).toSet(),
      );
      var added = 0;
      db.execute('BEGIN IMMEDIATE;');
      try {
        for (var i = 0; i < items.length; i++) {
          final item = items[i];
          if (deletedIds.contains(item.id)) {
            if ((i + 1) % 200 == 0 || i + 1 == items.length) {
              onProgress?.call(i + 1, items.length);
            }
            continue;
          }
          _insertMessageIgnore(db, item);
          final inserted =
              (db.select('SELECT changes() AS c;').first['c'] as int) > 0;
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
    });
  }

  Future<bool> deleteMessageById(String messageId) async {
    final id = messageId.trim();
    if (id.isEmpty) return false;
    return _withOpenDatabase((db) {
      db.execute('BEGIN IMMEDIATE;');
      try {
        db.execute(
          'INSERT OR REPLACE INTO deleted_messages(id, deleted_at) VALUES(?, ?);',
          [id, DateTime.now().millisecondsSinceEpoch],
        );
        db.execute('DELETE FROM messages WHERE id = ?;', [id]);
        final deleted =
            (db.select('SELECT changes() AS c;').first['c'] as int) > 0;
        db.execute(
          'DELETE FROM pins WHERE phone NOT IN (SELECT DISTINCT phone FROM messages);',
        );
        db.execute('COMMIT;');
        return deleted;
      } catch (_) {
        db.execute('ROLLBACK;');
        rethrow;
      }
    });
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

  Future<List<SmsItem>> getMessagesByPhone(
    String phone, {
    String? deviceId,
  }) async {
    return _withOpenDatabase((db) {
      final normalizedDeviceId = deviceId?.trim();
      final rows = db.select(
        '''
        SELECT
          id, device_id, phone, content, timestamp, direction, sim_slot_index, sim_phone_number, sim_count,
          send_status, send_error_code, send_error_message, updated_at
        FROM messages
        WHERE phone = ?
          AND (? IS NULL OR device_id = ?)
        ORDER BY timestamp ASC, id ASC;
        ''',
        [
          phone,
          normalizedDeviceId?.isEmpty ?? true ? null : normalizedDeviceId,
          normalizedDeviceId?.isEmpty ?? true ? null : normalizedDeviceId,
        ],
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
    });
  }

  Future<List<ConversationSummary>> getConversationSummaries({
    String search = '',
    String? deviceId,
  }) async {
    return _withOpenDatabase((db) {
      final normalizedSearch = search.trim().toLowerCase();
      final searchLike = '%$normalizedSearch%';
      final normalizedDeviceId = deviceId?.trim();
      final deviceFilter = normalizedDeviceId?.isEmpty ?? true
          ? null
          : normalizedDeviceId;
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
        WHERE (? IS NULL OR m.device_id = ?)
        AND m.id = (
          SELECT m2.id
          FROM messages m2
          WHERE m2.phone = m.phone
            AND (? IS NULL OR m2.device_id = ?)
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
              AND (? IS NULL OR s.device_id = ?)
              AND (LOWER(s.phone) LIKE ? OR LOWER(s.content) LIKE ?)
          )
        )
        ORDER BY pinned DESC, m.timestamp DESC, m.id DESC;
        ''',
        [
          deviceFilter,
          deviceFilter,
          deviceFilter,
          deviceFilter,
          normalizedSearch,
          searchLike,
          deviceFilter,
          deviceFilter,
          searchLike,
          searchLike,
        ],
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
    });
  }

  Future<void> setPinned(String phone, bool pinned) async {
    await _withOpenDatabase((db) {
      if (pinned) {
        db.execute(
          'INSERT OR REPLACE INTO pins(phone, pinned_at) VALUES(?, ?);',
          [phone, DateTime.now().millisecondsSinceEpoch],
        );
      } else {
        db.execute('DELETE FROM pins WHERE phone = ?;', [phone]);
      }
    });
  }

  Future<List<String>> getPins() async {
    return _withOpenDatabase((db) {
      final rows = db.select('SELECT phone FROM pins ORDER BY pinned_at DESC;');
      return rows
          .map((e) => e['phone']?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
    });
  }

  Future<int?> getMetaInt(String key) async {
    return _withOpenDatabase((db) {
      final rows = db.select('SELECT value FROM meta WHERE key = ? LIMIT 1;', [
        key,
      ]);
      if (rows.isEmpty) return null;
      final v = rows.first['value']?.toString();
      return int.tryParse(v ?? '');
    });
  }

  Future<void> setMetaInt(String key, int value) async {
    await _withOpenDatabase((db) {
      db.execute('INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?);', [
        key,
        value.toString(),
      ]);
    });
  }

  Future<String?> getMetaString(String key) async {
    return _withOpenDatabase((db) {
      final rows = db.select('SELECT value FROM meta WHERE key = ? LIMIT 1;', [
        key,
      ]);
      if (rows.isEmpty) return null;
      return rows.first['value']?.toString();
    });
  }

  Future<void> setMetaString(String key, String value) async {
    await _withOpenDatabase((db) {
      db.execute('INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?);', [
        key,
        value,
      ]);
    });
  }

  Future<void> clearAllUserData() async {
    await _withOpenDatabase((db) {
      db.execute('BEGIN IMMEDIATE;');
      try {
        db.execute('DELETE FROM messages;');
        db.execute('DELETE FROM deleted_messages;');
        db.execute('DELETE FROM pins;');
        db.execute('DELETE FROM meta;');
        db.execute('COMMIT;');
      } catch (_) {
        db.execute('ROLLBACK;');
        rethrow;
      }
    });
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
    _tryAlterTable(
      db,
      'ALTER TABLE messages ADD COLUMN sim_slot_index INTEGER;',
    );
    _tryAlterTable(
      db,
      'ALTER TABLE messages ADD COLUMN sim_phone_number TEXT;',
    );
    _tryAlterTable(db, 'ALTER TABLE messages ADD COLUMN sim_count INTEGER;');
    _tryAlterTable(db, 'ALTER TABLE messages ADD COLUMN send_status TEXT;');
    _tryAlterTable(
      db,
      'ALTER TABLE messages ADD COLUMN send_error_code INTEGER;',
    );
    _tryAlterTable(
      db,
      'ALTER TABLE messages ADD COLUMN send_error_message TEXT;',
    );
    _tryAlterTable(db, 'ALTER TABLE messages ADD COLUMN updated_at INTEGER;');
    db.execute(
      'UPDATE messages SET updated_at = timestamp WHERE updated_at IS NULL OR updated_at <= 0;',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_messages_phone_ts ON messages(phone, timestamp);',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_messages_ts ON messages(timestamp);',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_messages_updated_at ON messages(updated_at);',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_messages_phone_ts_id ON messages(phone, timestamp DESC, id DESC);',
    );

    db.execute('''
      CREATE TABLE IF NOT EXISTS pins(
        phone TEXT PRIMARY KEY,
        pinned_at INTEGER NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS deleted_messages(
        id TEXT PRIMARY KEY,
        deleted_at INTEGER NOT NULL
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

  bool _isMessageMarkedDeleted(sqlite.Database db, String messageId) {
    if (messageId.trim().isEmpty) return false;
    final rows = db.select(
      'SELECT 1 AS hit FROM deleted_messages WHERE id = ? LIMIT 1;',
      [messageId],
    );
    return rows.isNotEmpty;
  }

  Set<String> _loadDeletedMessageIdSet(sqlite.Database db, Set<String> ids) {
    if (ids.isEmpty) return const {};
    final all = ids.toList(growable: false);
    final result = <String>{};
    const chunkSize = 400;
    for (var i = 0; i < all.length; i += chunkSize) {
      final end = (i + chunkSize < all.length) ? i + chunkSize : all.length;
      final chunk = all.sublist(i, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = db.select(
        'SELECT id FROM deleted_messages WHERE id IN ($placeholders);',
        chunk,
      );
      for (final row in rows) {
        final id = row['id']?.toString();
        if (id != null && id.isNotEmpty) {
          result.add(id);
        }
      }
    }
    return result;
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

Future<File> _settingsJsonFile() async {
  final base = await _appPrivateBaseDir();
  return File(p.join(base, 'settings_private.json'));
}

Future<String> _appPrivateBaseDir() async {
  try {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'RemoteMessage');
  } catch (_) {
    if (Platform.isWindows) {
      return p.join(
        Platform.environment['APPDATA'] ?? Directory.systemTemp.path,
        'RemoteMessage',
      );
    }
    return p.join(
      Platform.environment['HOME'] ?? Directory.systemTemp.path,
      '.remote_message',
    );
  }
}

Future<sqlite.Database> _openSqliteDatabase(
  File file, {
  required String label,
}) async {
  await file.parent.create(recursive: true);
  Object? lastError;
  for (var attempt = 0; attempt < 6; attempt++) {
    try {
      final db = sqlite.sqlite3.open(file.path);
      try {
        db.execute('PRAGMA busy_timeout = 5000;');
        db.execute('PRAGMA journal_mode = WAL;');
      } catch (_) {
        // These pragmas are best-effort compatibility settings.
      }
      return db;
    } catch (e) {
      lastError = e;
      await Future.delayed(Duration(milliseconds: 80 * (attempt + 1)));
    }
  }
  throw StateError(
    'Unable to open $label database at ${file.path}: $lastError',
  );
}
