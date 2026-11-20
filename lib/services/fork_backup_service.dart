// Full backup / restore for the PlenTV fork (1.2.22, FORK §65).
//
// The upstream Plezy backup ([SettingsExportService]) exports only the
// portable settings registry — no connections, no logins, no EPG
// mappings, no favourites, no resume positions. This service exports
// EVERYTHING the fork stores, so a backup taken on 1.2.22 restores on a
// fresh 1.3.23 install (new package) with nothing lost.
//
// FORMAT (FROZEN v1 — do not change between 1.2.22 and 1.3.23):
//   {
//     "format": "plentv-backup", "formatVersion": 1,
//     "appVersion": "1.2.22-2.25.0", "exportedAt": "<UTC ISO-8601>",
//     "platform": "android",
//     "activeProfileId": "<profile id>" | null,
//     "prefs": { ... upstream buildExportMap prefs map ... },
//     "epgPrefs": { "<key>": <value>, ... },          // 7 EPG keys (65.1b)
//     "connections": [ { "id", "kind", "displayName", "createdAt",
//                        "lastAuthenticatedAt", "config": {...} } ],
//     "profiles": [ { "id", "kind", "displayName", "avatarThumbUrl",
//                    "pinHash"?, "parentConnectionId"?, ..., "sortOrder",
//                    "createdAt", "lastUsedAt" } ],
//     "profileConnections": [ { "profileId", "connectionId", "userToken",
//                              "userIdentifier", "isDefault",
//                              "tokenAcquiredAt", "lastUsedAt" } ],
//     "epg": { "<connectionId>": { "sources": [...],
//                                  "addedSourcesFirst": false,
//                                  "mappings": { "<channelKey>":
//                                    {"xmltvId", "sourceId"} } } },
//     "favorites": { "<connectionId>": { "channels": "<raw JSON string>",
//                                        "items": "<raw JSON string>" } },
//     "resume": { "<connectionId>": "<raw JSON string>" }
//   }
//
// Package-agnostic by construction: NO package name, NO absolute paths,
// NO device-specific paths anywhere. Settings travel by key, connections
// by id; restore writes into whatever the current app's storage is, so
// the same file restores under a different applicationId. Unknown future
// sections are ignored on import; formatVersion > 1 is rejected.
//
// SECURITY: the file contains the logins in plain text (the connections'
// configs are exported AFTER the registry reveals them, and re-protected
// on import under the fresh install's vault key). The app warns in plain
// words before exporting. The service makes no network call, ever — the
// backup is never auto-uploaded anywhere.
//
// EXCLUDED deliberately (65.2): the catalog index + disk cache + EPG feed
// cache/row store (derived — a fresh catalog sync runs after restore),
// runtime timestamps, derived EPG status/fingerprint, downloads and
// operational tables, tvos recovery state, device paths.
//
// The catalog index is NOT in the export: the trade-off is a small,
// portable file that never carries stale provider data, at the cost of
// one catalog sync after a restore (user-initiated, so it is consistent
// with the startup rule — the app still never talks to Trex at startup).
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connection/connection.dart';
import '../connection/connection_registry.dart';
import '../database/app_database.dart';
import '../media/media_backend.dart';
import '../media/media_browser_dialect.dart';
import '../profiles/profile.dart';
import '../profiles/profile_connection.dart';
import '../profiles/profile_connection_registry.dart';
import '../profiles/profile_registry.dart';
import 'base_shared_preferences_service.dart';
import 'downloads_media_store.dart';
import 'file_picker_service.dart';
import 'settings_export_service.dart';
import 'settings_service.dart';
import 'storage_service.dart';
import 'iptv/iptv_epg_sources.dart';

/// One section's restore outcome, for the plain-words summary.
class ForkBackupSectionReport {
  const ForkBackupSectionReport({
    required this.restored,
    required this.skipped,
    this.note,
  });

  final int restored;
  final int skipped;
  final String? note;
}

/// What an import restored, per section — surfaced in plain words so the
/// user can see the backup actually landed.
class ForkBackupRestoreReport {
  const ForkBackupRestoreReport({
    required this.prefs,
    required this.epgPrefs,
    required this.connections,
    required this.profiles,
    required this.profileConnections,
    required this.epg,
    required this.favorites,
    required this.resume,
    required this.activeProfileRestored,
  });

  final ImportResult prefs;
  final ForkBackupSectionReport epgPrefs;
  final ForkBackupSectionReport connections;
  final ForkBackupSectionReport profiles;
  final ForkBackupSectionReport profileConnections;
  final ForkBackupSectionReport epg;
  final ForkBackupSectionReport favorites;
  final ForkBackupSectionReport resume;
  final bool activeProfileRestored;

  int get totalRestored =>
      prefs.keysImported +
      epgPrefs.restored +
      connections.restored +
      profiles.restored +
      profileConnections.restored +
      epg.restored +
      favorites.restored +
      resume.restored;
}

class ForkBackupException implements Exception {
  const ForkBackupException(this.message);

  final String message;

  @override
  String toString() => 'ForkBackupException: $message';
}

class ForkBackupService {
  ForkBackupService(this._db, {this.debugDownloadsWriter, this.debugFilePicker});

  /// 1.6 (D2): the format string is `plentv-backup` now, but restore
  /// accepts the old `pleztv-backup` files too — renaming the format
  /// WITHOUT the dual-accept would brick every existing backup.
  static const String formatName = 'plentv-backup';
  static const String legacyFormatName = 'pleztv-backup';
  static const int formatVersion = 1;
  static const String fileExtension = 'json';

  /// The EPG preference keys the upstream portable registry does NOT
  /// cover (65.1b) — exported here as plain values. Runtime timestamps
  /// (`iptv_epg_last_updated`, `iptv_epg_last_attempt`) are excluded
  /// deliberately: they describe the last run, not the user's choices.
  static const List<Pref<Object?>> epgPrefsToBackUp = [
    SettingsService.iptvEpgDaysToLoad,
    SettingsService.iptvEpgUpdateIntervalHours,
    SettingsService.iptvEpgPastDays,
    SettingsService.iptvEpgUpdateOnStart,
    SettingsService.iptvEpgTimeOffsetMinutes,
    SettingsService.iptvEpgUpdateTimeMinutes,
    SettingsService.iptvEpgUpdateOnPlaylistChange,
  ];

  final AppDatabase _db;

  /// Test seam: replaces the Downloads write (mirrors
  /// [DownloadsMediaStore.debugWriteOverride]).
  final Future<String?> Function({required String fileName, required Uint8List bytes, String mimeType})?
  debugDownloadsWriter;

  /// Test seam: replaces the file picker on import.
  final Future<Uint8List?> Function()? debugFilePicker;

  ConnectionRegistry get _connections => ConnectionRegistry(_db);
  ProfileRegistry get _profiles => ProfileRegistry(_db);
  ProfileConnectionRegistry get _profileConnections => ProfileConnectionRegistry(_db);

  /// Builds the backup map from the current install. Pure apart from the
  /// reads; the JSON string built from it is the export file.
  Future<Map<String, dynamic>> buildBackupMap() async {
    final settings = await SettingsService.getInstance();
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final storage = await StorageService.getInstance();
    String appVersion = '';
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = info.version;
    } on PlatformException {
      // Best-effort metadata; platforms without PackageInfo still export.
    }

    final prefsMap = SettingsExportService.buildExportMap(
      prefs,
      currentUserUuid: storage.activeUserScope(),
      appVersion: appVersion,
    );

    final epgPrefs = <String, Object?>{};
    for (final pref in epgPrefsToBackUp) {
      epgPrefs[pref.key] = _readEpgPref(settings, pref);
    }

    final connections = await _connections.list();
    final profiles = await _profiles.list();
    final profileConnections = await _profileConnections.listAll();

    final connectionIds = connections.map((c) => c.id).toList();
    final epg = <String, dynamic>{};
    final favorites = <String, dynamic>{};
    final resume = <String, dynamic>{};
    for (final id in connectionIds) {
      final store = IptvEpgSourcesStore(id);
      final sources = await store.loadUserSources();
      final addedFirst = await store.loadAddedSourcesFirst();
      final mappings = await store.loadMappings();
      // A connection with no user-added sources, no mappings and the
      // default order carries nothing worth a line in the file or the
      // summary — the provider feed is implicit, and an empty store
      // restores to the same empty store. Skipping it keeps the backup
      // honest ("1 guide store" means one that actually holds data).
      if (sources.isNotEmpty || mappings.isNotEmpty || addedFirst) {
        epg[id] = {
          'sources': sources.map((s) => s.toJson()).toList(),
          'addedSourcesFirst': addedFirst,
          'mappings': mappings.map((k, v) => MapEntry(k, v.toJson())),
        };
      }
      // Same rule as the EPG stores above: a connection with no
      // favourites and no watch positions gets no entry, so the counts
      // and the summary only count connections that actually hold data.
      final favChannels = prefs.getString('iptv_fav_channels:$id');
      final favItems = prefs.getString('iptv_fav_items:$id');
      if (favChannels != null || favItems != null) {
        favorites[id] = {'channels': favChannels, 'items': favItems};
      }
      final resumeValue = prefs.getString('iptv_resume:$id');
      if (resumeValue != null) resume[id] = resumeValue;
    }

    return {
      'format': formatName,
      'formatVersion': formatVersion,
      'appVersion': appVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'platform': Platform.operatingSystem,
      'activeProfileId': storage.getActiveProfileId(),
      'prefs': prefsMap['prefs'],
      'epgPrefs': epgPrefs,
      'connections': connections.map(_connectionToBackupJson).toList(),
      'profiles': profiles.map(_profileToBackupJson).toList(),
      'profileConnections': profileConnections.map(_profileConnectionToBackupJson).toList(),
      'epg': epg,
      'favorites': favorites,
      'resume': resume,
    };
  }

  Object? _readEpgPref(SettingsService settings, Pref<Object?> pref) {
    // The seven EPG prefs are IntPref/BoolPref only; read them through the
    // typed accessors so a future type change fails loudly here, not in a
    // backup file.
    if (pref is IntPref) return settings.read(pref);
    if (pref is BoolPref) return settings.read(pref);
    throw StateError('Fork backup: unsupported EPG pref type for ${pref.key}');
  }

  Map<String, dynamic> _connectionToBackupJson(Connection connection) {
    // The registry's list() already revealed the config, so toConfigJson()
    // carries the login in plain text — that is the file's content, by
    // design (the app warns before exporting). createdAt /
    // lastAuthenticatedAt travel as epoch millis; the id travels verbatim
    // so per-connection stores keep working after restore.
    return {
      'id': connection.id,
      'kind': connection.kind.id,
      'displayName': connection.displayName,
      'createdAt': connection.createdAt.millisecondsSinceEpoch,
      'lastAuthenticatedAt': connection.lastAuthenticatedAt?.millisecondsSinceEpoch,
      'config': connection.toConfigJson(),
    };
  }

  Map<String, dynamic> _profileToBackupJson(Profile profile) {
    return switch (profile) {
      LocalProfile(:final id, :final displayName, :final avatarThumbUrl, :final pinHash, :final sortOrder, :final createdAt, :final lastUsedAt) => {
        'id': id,
        'kind': 'local',
        'displayName': displayName,
        'avatarThumbUrl': avatarThumbUrl,
        'pinHash': pinHash,
        'sortOrder': sortOrder,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'lastUsedAt': lastUsedAt?.millisecondsSinceEpoch,
      },
      PlexHomeProfile(
        :final id,
        :final displayName,
        :final avatarThumbUrl,
        :final parentConnectionId,
        :final plexHomeUserUuid,
        :final plexRestricted,
        :final plexAdmin,
        :final plexProtected,
        :final sortOrder,
        :final createdAt,
        :final lastUsedAt,
      ) => {
        'id': id,
        'kind': 'plex_home',
        'displayName': displayName,
        'avatarThumbUrl': avatarThumbUrl,
        'parentConnectionId': parentConnectionId,
        'plexHomeUserUuid': plexHomeUserUuid,
        'plexRestricted': plexRestricted,
        'plexAdmin': plexAdmin,
        'plexProtected': plexProtected,
        'sortOrder': sortOrder,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'lastUsedAt': lastUsedAt?.millisecondsSinceEpoch,
      },
    };
  }

  Map<String, dynamic> _profileConnectionToBackupJson(ProfileConnection pc) {
    // listAll() already revealed the token, so this carries it in plain
    // text (same sensitivity as the connection passwords). Empty stays
    // empty — it is the lazy-fetch sentinel, not a missing token.
    return {
      'profileId': pc.profileId,
      'connectionId': pc.connectionId,
      'userToken': pc.userToken ?? '',
      'userIdentifier': pc.userIdentifier,
      'isDefault': pc.isDefault,
      'tokenAcquiredAt': pc.tokenAcquiredAt?.millisecondsSinceEpoch,
      'lastUsedAt': pc.lastUsedAt?.millisecondsSinceEpoch,
    };
  }

  /// Serializes the current install and writes one file to Downloads via
  /// the MediaStore path (same pattern as the debug-log save), falling
  /// back to the app folder. Returns the saved path, or null when no
  /// destination worked. Never uploads anything.
  Future<String?> exportToFile() async {
    final backupMap = await buildBackupMap();
    final jsonString = const JsonEncoder.withIndent('  ').convert(backupMap);
    final bytes = Uint8List.fromList(utf8.encode(jsonString));
    final now = DateTime.now();
    final fileName =
        'plentv-backup-${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}.$fileExtension';
    final writer =
        debugDownloadsWriter ??
        (({required String fileName, required Uint8List bytes, String mimeType = 'text/plain'}) =>
            DownloadsMediaStore.writeFile(fileName: fileName, bytes: bytes, mimeType: mimeType));
    final path = await writer(fileName: fileName, bytes: bytes, mimeType: 'application/json');
    if (path != null) return path;
    return _writeToAppDocuments(fileName, bytes);
  }

  static Future<String> _writeToAppDocuments(String fileName, Uint8List bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// Picks a backup file and restores it. Returns null when the user
  /// cancels the picker. Throws [ForkBackupException] on a malformed
  /// file. Never uploads anything; the file stays on the device.
  Future<ForkBackupRestoreReport?> importFromFile() async {
    final bytes = await _pickBackupBytes();
    if (bytes == null) return null;
    return importFromBytes(bytes);
  }

  /// Restores from raw backup bytes (the picker seam for tests).
  Future<ForkBackupRestoreReport> importFromBytes(Uint8List bytes) async {
    final String contents;
    try {
      contents = utf8.decode(bytes);
    } on FormatException {
      throw const ForkBackupException('Could not read the backup file');
    }
    final Object? decoded;
    try {
      decoded = json.decode(contents);
    } on FormatException {
      throw const ForkBackupException('Invalid backup file');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ForkBackupException('Invalid backup file');
    }
    return applyBackupMap(decoded);
  }

  Future<Uint8List?> _pickBackupBytes() async {
    if (debugFilePicker != null) return debugFilePicker!();
    final picked = await FilePickerService.instance.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [fileExtension],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return null;
    final file = picked.files.first;
    final bytes = file.bytes;
    if (bytes != null) return bytes;
    if (file.path != null) return File(file.path!).readAsBytes();
    throw const ForkBackupException('Could not read the selected file');
  }

  /// Restores a backup map into this install and verifies every section
  /// by re-reading it: each section report counts the entries that
  /// actually landed (restored) and the ones that did not (skipped —
  /// malformed, unknown kind, or failed verification). Throws
  /// [ForkBackupException] when the file is not a PlenTV backup or its
  /// formatVersion is newer than this build understands.
  ///
  /// 1.6 (D2): both `plentv-backup` and the old `pleztv-backup` format
  /// strings restore — the old files are the user's only copy of their
  /// logins, and a rename that rejected them would strand every backup
  /// taken before 1.6.
  ///
  /// Order matters: connections first (everything else is keyed by
  /// connection id), then profiles and their tokens, then the active
  /// profile — restoring it is what gives the prefs import the user
  /// scope it needs on a fresh install — then prefs, EPG prefs, EPG
  /// stores, favourites, resume. A section that fails never aborts the
  /// rest; the report says what landed.
  Future<ForkBackupRestoreReport> applyBackupMap(Map<String, dynamic> data) async {
    if (data['format'] != formatName && data['format'] != legacyFormatName) {
      throw const ForkBackupException('Not a PlenTV backup file');
    }
    final version = data['formatVersion'];
    if (version is! int) {
      throw const ForkBackupException('Missing formatVersion');
    }
    if (version > formatVersion) {
      throw ForkBackupException('Unsupported backup formatVersion: $version');
    }

    final settings = await SettingsService.getInstance();
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final storage = await StorageService.getInstance();

    final connectionsReport = await _importConnections(data['connections']);
    final profilesReport = await _importProfiles(data['profiles']);
    final profileConnectionsReport = await _importProfileConnections(data['profileConnections']);

    var activeProfileRestored = false;
    final activeProfileId = data['activeProfileId'];
    if (activeProfileId is String && activeProfileId.isNotEmpty) {
      final restoredIds = (await _profiles.list()).map((p) => p.id).toSet();
      if (restoredIds.contains(activeProfileId)) {
        await storage.setActiveProfileId(activeProfileId);
        activeProfileRestored = true;
      }
    }

    final prefsResult = await _importPrefs(data['prefs'], prefs, storage);
    final epgPrefsReport = await _importEpgPrefs(data['epgPrefs'], settings);
    final epgReport = await _importEpg(data['epg']);
    final favoritesReport = await _importFavorites(data['favorites'], prefs);
    final resumeReport = await _importResume(data['resume'], prefs);

    return ForkBackupRestoreReport(
      prefs: prefsResult,
      epgPrefs: epgPrefsReport,
      connections: connectionsReport,
      profiles: profilesReport,
      profileConnections: profileConnectionsReport,
      epg: epgReport,
      favorites: favoritesReport,
      resume: resumeReport,
      activeProfileRestored: activeProfileRestored,
    );
  }

  Future<ForkBackupSectionReport> _importConnections(Object? raw) async {
    if (raw == null) return const ForkBackupSectionReport(restored: 0, skipped: 0);
    if (raw is! List) {
      return const ForkBackupSectionReport(restored: 0, skipped: 0, note: 'connections section is not a list');
    }
    var skipped = 0;
    final wanted = <String, String>{};
    for (final entry in raw) {
      try {
        final connection = _connectionFromBackupJson(entry);
        if (connection == null) {
          skipped++;
          continue;
        }
        // upsert re-protects the config under this install's vault key,
        // preserving the id so the per-connection stores keep working.
        await _connections.upsert(connection);
        wanted[connection.id] = connection.kind.id;
      } catch (_) {
        skipped++;
      }
    }
    var restored = 0;
    final liveById = {for (final c in await _connections.list()) c.id: c.kind.id};
    for (final entry in wanted.entries) {
      if (liveById[entry.key] == entry.value) {
        restored++;
      } else {
        skipped++;
      }
    }
    return ForkBackupSectionReport(restored: restored, skipped: skipped);
  }

  /// Rebuilds one connection from its backup JSON (plain config, as
  /// exported). The kind dispatch mirrors [_rowToConnection] in the
  /// registry; an unknown kind or malformed entry returns null so the
  /// import counts it skipped instead of crashing.
  Connection? _connectionFromBackupJson(Object? entry) {
    if (entry is! Map<String, dynamic>) return null;
    final id = entry['id'];
    final kindId = entry['kind'];
    final config = entry['config'];
    final createdAtMs = entry['createdAt'];
    if (id is! String || id.isEmpty || kindId is! String || config is! Map || createdAtMs is! int) {
      return null;
    }
    final lastAuthMs = entry['lastAuthenticatedAt'];
    final createdAt = DateTime.fromMillisecondsSinceEpoch(createdAtMs);
    final lastAuthenticatedAt = lastAuthMs is int ? DateTime.fromMillisecondsSinceEpoch(lastAuthMs) : null;
    final json = Map<String, Object?>.from(config);
    try {
      return switch (MediaBackend.fromId(kindId)) {
        MediaBackend.plex => PlexAccountConnection.fromConfigJson(
          id: id,
          json: json,
          createdAt: createdAt,
          lastAuthenticatedAt: lastAuthenticatedAt,
        ),
        MediaBackend.jellyfin => JellyfinConnection.fromConfigJson(
          id: id,
          json: json,
          createdAt: createdAt,
          lastAuthenticatedAt: lastAuthenticatedAt,
        ),
        MediaBackend.emby => JellyfinConnection.fromConfigJson(
          id: id,
          json: json,
          createdAt: createdAt,
          lastAuthenticatedAt: lastAuthenticatedAt,
          dialect: MediaBrowserDialect.emby,
        ),
        MediaBackend.m3u => M3uConnection.fromConfigJson(
          id: id,
          json: json,
          createdAt: createdAt,
          lastAuthenticatedAt: lastAuthenticatedAt,
        ),
        MediaBackend.xtream => XtreamConnection.fromConfigJson(
          id: id,
          json: json,
          createdAt: createdAt,
          lastAuthenticatedAt: lastAuthenticatedAt,
        ),
      };
    } on ArgumentError {
      return null;
    }
  }

  Future<ForkBackupSectionReport> _importProfiles(Object? raw) async {
    if (raw == null) return const ForkBackupSectionReport(restored: 0, skipped: 0);
    if (raw is! List) {
      return const ForkBackupSectionReport(restored: 0, skipped: 0, note: 'profiles section is not a list');
    }
    var skipped = 0;
    final wanted = <String>{};
    for (final entry in raw) {
      try {
        final profile = _profileFromBackupJson(entry);
        if (profile == null) {
          skipped++;
          continue;
        }
        await _profiles.upsert(profile);
        wanted.add(profile.id);
      } catch (_) {
        skipped++;
      }
    }
    var restored = 0;
    final liveIds = (await _profiles.list()).map((p) => p.id).toSet();
    for (final id in wanted) {
      if (liveIds.contains(id)) {
        restored++;
      } else {
        skipped++;
      }
    }
    return ForkBackupSectionReport(restored: restored, skipped: skipped);
  }

  Profile? _profileFromBackupJson(Object? entry) {
    if (entry is! Map<String, dynamic>) return null;
    final id = entry['id'];
    final kind = entry['kind'];
    final createdAtMs = entry['createdAt'];
    if (id is! String || id.isEmpty || kind is! String || createdAtMs is! int) return null;
    final createdAt = DateTime.fromMillisecondsSinceEpoch(createdAtMs);
    final lastUsedMs = entry['lastUsedAt'];
    final lastUsedAt = lastUsedMs is int ? DateTime.fromMillisecondsSinceEpoch(lastUsedMs) : null;
    final displayName = entry['displayName'] as String? ?? '';
    final avatarThumbUrl = entry['avatarThumbUrl'] as String?;
    final sortOrder = entry['sortOrder'] is int ? entry['sortOrder'] as int : 0;
    switch (kind) {
      case 'local':
        return Profile.local(
          id: id,
          displayName: displayName,
          avatarThumbUrl: avatarThumbUrl,
          pinHash: entry['pinHash'] as String?,
          sortOrder: sortOrder,
          createdAt: createdAt,
          lastUsedAt: lastUsedAt,
        );
      case 'plex_home':
        return Profile.plexHome(
          id: id,
          displayName: displayName,
          avatarThumbUrl: avatarThumbUrl,
          parentConnectionId: entry['parentConnectionId'] as String?,
          plexHomeUserUuid: entry['plexHomeUserUuid'] as String?,
          plexRestricted: entry['plexRestricted'] as bool? ?? false,
          plexAdmin: entry['plexAdmin'] as bool? ?? false,
          plexProtected: entry['plexProtected'] as bool? ?? false,
          sortOrder: sortOrder,
          createdAt: createdAt,
          lastUsedAt: lastUsedAt,
        );
      default:
        return null;
    }
  }

  Future<ForkBackupSectionReport> _importProfileConnections(Object? raw) async {
    if (raw == null) return const ForkBackupSectionReport(restored: 0, skipped: 0);
    if (raw is! List) {
      return const ForkBackupSectionReport(restored: 0, skipped: 0, note: 'profileConnections section is not a list');
    }
    var skipped = 0;
    final wanted = <String>{};
    for (final entry in raw) {
      try {
        final pc = _profileConnectionFromBackupJson(entry);
        if (pc == null) {
          skipped++;
          continue;
        }
        // upsert re-protects the token under this install's vault key.
        await _profileConnections.upsert(pc);
        wanted.add('${pc.profileId}/${pc.connectionId}');
      } catch (_) {
        skipped++;
      }
    }
    var restored = 0;
    final livePairs = (await _profileConnections.listAll()).map((p) => '${p.profileId}/${p.connectionId}').toSet();
    for (final pair in wanted) {
      if (livePairs.contains(pair)) {
        restored++;
      } else {
        skipped++;
      }
    }
    return ForkBackupSectionReport(restored: restored, skipped: skipped);
  }

  ProfileConnection? _profileConnectionFromBackupJson(Object? entry) {
    if (entry is! Map<String, dynamic>) return null;
    final profileId = entry['profileId'];
    final connectionId = entry['connectionId'];
    if (profileId is! String || profileId.isEmpty || connectionId is! String || connectionId.isEmpty) {
      return null;
    }
    final token = entry['userToken'] as String?;
    final tokenAcquiredMs = entry['tokenAcquiredAt'];
    final lastUsedMs = entry['lastUsedAt'];
    return ProfileConnection(
      profileId: profileId,
      connectionId: connectionId,
      // An empty token is the lazy-fetch sentinel, not a token — keep it
      // null so the binder re-acquires one instead of storing an empty
      // protected value.
      userToken: (token == null || token.isEmpty) ? null : token,
      userIdentifier: entry['userIdentifier'] as String? ?? '',
      isDefault: entry['isDefault'] as bool? ?? false,
      tokenAcquiredAt: tokenAcquiredMs is int ? DateTime.fromMillisecondsSinceEpoch(tokenAcquiredMs) : null,
      lastUsedAt: lastUsedMs is int ? DateTime.fromMillisecondsSinceEpoch(lastUsedMs) : null,
    );
  }

  /// The upstream prefs import, with the backup's prefs map re-wrapped
  /// in the shape it expects. When no profile is active on this install
  /// there is no user scope to re-scope the user-scoped keys under, so
  /// the settings stay untouched (counted skipped) instead of landing
  /// under a wrong scope — restoring a profile first is what normally
  /// provides the scope.
  Future<ImportResult> _importPrefs(Object? raw, SharedPreferencesWithCache prefs, StorageService storage) async {
    if (raw == null) return const ImportResult(keysImported: 0, keysSkipped: 0);
    if (raw is! Map) return const ImportResult(keysImported: 0, keysSkipped: 0);
    final uuid = storage.activeUserScope();
    if (uuid == null || uuid.isEmpty) {
      return ImportResult(keysImported: 0, keysSkipped: raw.length);
    }
    return SettingsExportService.applyImportMap(
      {'formatVersion': 1, 'prefs': Map<String, dynamic>.from(raw)},
      prefs,
      currentUserUuid: uuid,
    );
  }

  Future<ForkBackupSectionReport> _importEpgPrefs(Object? raw, SettingsService settings) async {
    if (raw == null) return const ForkBackupSectionReport(restored: 0, skipped: 0);
    if (raw is! Map) {
      return const ForkBackupSectionReport(restored: 0, skipped: 0, note: 'epgPrefs section is not an object');
    }
    var restored = 0;
    var skipped = 0;
    for (final pref in epgPrefsToBackUp) {
      if (!raw.containsKey(pref.key)) continue;
      final value = raw[pref.key];
      try {
        if (pref is IntPref && value is num) {
          await pref.writeTo(settings, value.toInt());
        } else if (pref is BoolPref && value is bool) {
          await pref.writeTo(settings, value);
        } else {
          skipped++;
          continue;
        }
        final landed = settings.read(pref);
        final want = pref is IntPref ? (value as num).toInt() : value;
        if (landed == want) {
          restored++;
        } else {
          skipped++;
        }
      } catch (_) {
        skipped++;
      }
    }
    return ForkBackupSectionReport(restored: restored, skipped: skipped);
  }

  Future<ForkBackupSectionReport> _importEpg(Object? raw) async {
    if (raw == null) return const ForkBackupSectionReport(restored: 0, skipped: 0);
    if (raw is! Map) {
      return const ForkBackupSectionReport(restored: 0, skipped: 0, note: 'epg section is not an object');
    }
    var restored = 0;
    var skipped = 0;
    for (final entry in raw.entries) {
      final connectionId = entry.key.toString();
      if (entry.value is! Map) {
        skipped++;
        continue;
      }
      final section = entry.value as Map;
      final store = IptvEpgSourcesStore(connectionId);
      try {
        final sources = <IptvEpgSourceConfig>[];
        var sourcesOk = true;
        final sourcesRaw = section['sources'];
        if (sourcesRaw is List) {
          for (final s in sourcesRaw) {
            try {
              if (s is Map<String, dynamic>) {
                sources.add(IptvEpgSourceConfig.fromJson(s));
              } else if (s is Map) {
                sources.add(IptvEpgSourceConfig.fromJson(Map<String, dynamic>.from(s)));
              } else {
                sourcesOk = false;
              }
            } catch (_) {
              sourcesOk = false;
            }
          }
        }
        await store.saveUserSources(sources);
        final addedFirst = section['addedSourcesFirst'];
        if (addedFirst is bool) await store.saveAddedSourcesFirst(addedFirst);
        final mappings = <String, IptvEpgMapping>{};
        var mappingsOk = true;
        final mappingsRaw = section['mappings'];
        if (mappingsRaw is Map) {
          for (final m in mappingsRaw.entries) {
            try {
              final v = m.value;
              if (v is Map<String, dynamic>) {
                mappings[m.key.toString()] = IptvEpgMapping.fromJson(v);
              } else if (v is Map) {
                mappings[m.key.toString()] = IptvEpgMapping.fromJson(Map<String, dynamic>.from(v));
              } else {
                mappingsOk = false;
              }
            } catch (_) {
              mappingsOk = false;
            }
          }
        }
        await store.saveMappings(mappings);
        final liveSources = await store.loadUserSources();
        final liveMappings = await store.loadMappings();
        final liveAddedFirst = await store.loadAddedSourcesFirst();
        var ok = liveSources.length == sources.length && liveMappings.length == mappings.length && sourcesOk && mappingsOk;
        if (addedFirst is bool) ok = ok && liveAddedFirst == addedFirst;
        if (ok) {
          restored++;
        } else {
          skipped++;
        }
      } catch (_) {
        skipped++;
      }
    }
    return ForkBackupSectionReport(restored: restored, skipped: skipped);
  }

  Future<ForkBackupSectionReport> _importFavorites(Object? raw, SharedPreferencesWithCache prefs) async {
    if (raw == null) return const ForkBackupSectionReport(restored: 0, skipped: 0);
    if (raw is! Map) {
      return const ForkBackupSectionReport(restored: 0, skipped: 0, note: 'favorites section is not an object');
    }
    var restored = 0;
    var skipped = 0;
    for (final entry in raw.entries) {
      final id = entry.key.toString();
      if (entry.value is! Map) {
        skipped++;
        continue;
      }
      final section = entry.value as Map;
      var ok = true;
      ok = await _importRawJsonString(prefs, 'iptv_fav_channels:$id', section['channels']) && ok;
      ok = await _importRawJsonString(prefs, 'iptv_fav_items:$id', section['items']) && ok;
      if (ok) {
        restored++;
      } else {
        skipped++;
      }
    }
    return ForkBackupSectionReport(restored: restored, skipped: skipped);
  }

  Future<ForkBackupSectionReport> _importResume(Object? raw, SharedPreferencesWithCache prefs) async {
    if (raw == null) return const ForkBackupSectionReport(restored: 0, skipped: 0);
    if (raw is! Map) {
      return const ForkBackupSectionReport(restored: 0, skipped: 0, note: 'resume section is not an object');
    }
    var restored = 0;
    var skipped = 0;
    for (final entry in raw.entries) {
      final id = entry.key.toString();
      final ok = await _importRawJsonString(prefs, 'iptv_resume:$id', entry.value);
      if (ok) {
        restored++;
      } else {
        skipped++;
      }
    }
    return ForkBackupSectionReport(restored: restored, skipped: skipped);
  }

  /// Writes a raw JSON string verbatim (or removes the key when the
  /// backup has null for it). Returns false when the value is corrupt —
  /// a bad string never crashes the import.
  Future<bool> _importRawJsonString(SharedPreferencesWithCache prefs, String key, Object? value) async {
    try {
      if (value == null) {
        await prefs.remove(key);
        return prefs.getString(key) == null;
      }
      if (value is! String) return false;
      json.decode(value);
      await prefs.setString(key, value);
      return prefs.getString(key) == value;
    } catch (_) {
      return false;
    }
  }
}
