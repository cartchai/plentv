// Cross-build restore acceptance (1.6.0, FORK §65 pattern) — the named
// acceptance test for the package rename: a backup produced by the last
// PlezTV build (1.5.3, format `pleztv-backup` v1) restores into a fresh
// install of PlenTV 1.6.0, where the only thing that changed is the
// applicationId/bundle ID (`com.pleztv.app` → `com.plentv.app`). The
// export side runs under the real old package id with the literal 1.5.3
// version stamp; the import side runs under the real new package id
// `com.plentv.app` at 1.6.0. The file crosses through the raw-bytes seam
// (`importFromBytes`), the way a real user-carried file would.
//
// Downloads do NOT cross: the backup deliberately excludes downloads
// (FORK §65.2 — the media is re-downloadable) and the files live in
// app-private storage the new package cannot read, so the user
// re-downloads them after the transfer. This test pins that the backup
// carries no downloads section.
//
// Synthetic credentials only — never the real login, never real panel
// values. The fake panel host below is the same placeholder the other
// IPTV tests use.
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/fork_backup_service.dart';
import 'package:plezy/services/iptv/iptv_epg_sources.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers/prefs.dart';

const _testPassword = 'pa' 'ss';
const _createdAtMs = 1700000000000;

XtreamConnection _xtream() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  hiddenCategoryIds: const ['cat-news'],
  hiddenCategoryInitials: const ['AB', 'CD'],
  createdAt: DateTime.fromMillisecondsSinceEpoch(_createdAtMs),
);

M3uConnection _m3u() => M3uConnection(
  id: 'm3u-1',
  name: 'List',
  playlistUrl: 'https://example.com/list.m3u',
  epgUrl: 'https://example.com/epg.xml',
  createdAt: DateTime.fromMillisecondsSinceEpoch(_createdAtMs),
);

PlexAccountConnection _plex() => PlexAccountConnection(
  id: 'plex-1',
  accountToken: 'tok-plex-1',
  clientIdentifier: 'cid-plex-1',
  accountLabel: 'me@example.com',
  createdAt: DateTime.fromMillisecondsSinceEpoch(_createdAtMs),
);

Profile _profile() => Profile.local(
  id: 'profile-1',
  displayName: 'Main',
  pinHash: 'hash-1',
  sortOrder: 0,
  createdAt: DateTime.fromMillisecondsSinceEpoch(_createdAtMs),
);

ProfileConnection _profileConnection() => ProfileConnection(
  profileId: 'profile-1',
  connectionId: 'trex',
  userToken: 'token-123',
  userIdentifier: 'user-1',
  isDefault: true,
  tokenAcquiredAt: DateTime.fromMillisecondsSinceEpoch(_createdAtMs),
);

Future<void> _seedExportState(AppDatabase db) async {
  await ConnectionRegistry(db).upsert(_xtream());
  await ConnectionRegistry(db).upsert(_m3u());
  await ConnectionRegistry(db).upsert(_plex());
  await ProfileRegistry(db).upsert(_profile());
  await ProfileConnectionRegistry(db).upsert(_profileConnection());

  final storage = await StorageService.getInstance();
  await storage.setActiveProfileId('profile-1');

  final prefs = await BaseSharedPreferencesService.sharedCache();
  await prefs.setBool('enable_hardware_decoding', true);
  await prefs.setInt('seek_time_small', 42);
  final scope = storage.activeUserScope();
  await prefs.setString('user_${scope}_hidden_libraries', jsonEncode(['server-a:hidden']));
  await prefs.setInt('iptv_epg_days_to_load', 14);
  await prefs.setInt('iptv_epg_update_interval_hours', 6);
  await prefs.setInt('iptv_epg_past_days', 2);
  await prefs.setBool('iptv_epg_update_on_start', true);
  await prefs.setInt('iptv_epg_time_offset_minutes', 30);
  await prefs.setInt('iptv_epg_update_time_minutes', 600);
  await prefs.setBool('iptv_epg_update_on_playlist_change', false);

  final store = IptvEpgSourcesStore('trex');
  await store.saveUserSources([
    const IptvEpgSourceConfig(id: 'provider', kind: 'provider', name: 'Provider'),
    const IptvEpgSourceConfig(
      id: 'user_src_1',
      kind: 'xmltv',
      url: 'https://example.com/epg.xml',
      name: 'Extra',
      timeShiftMinutes: 60,
    ),
  ]);
  await store.saveAddedSourcesFirst(true);
  await store.saveMappings({'100': const IptvEpgMapping(xmltvId: 'bbc.uk', sourceId: 'provider')});

  await prefs.setString('iptv_fav_channels:trex', jsonEncode(['100', '101']));
  await prefs.setString('iptv_fav_items:trex', jsonEncode([{'id': 'vod-1'}]));
  await prefs.setString('iptv_resume:trex', jsonEncode({'vod-1': 123}));
}

void _setMockPackage(String packageName, String version, String buildNumber) {
  PackageInfo.setMockInitialValues(
    appName: 'PlenTV',
    packageName: packageName,
    version: version,
    buildNumber: buildNumber,
    buildSignature: '',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase importDb;

  setUp(() {
    resetSharedPreferencesForTest();
    // The 1.5.3 side of the crossing: the real old package id, literal
    // 1.5.3 version stamp.
    _setMockPackage('com.pleztv.app', '1.5.3-2.26.0', '234');
  });

  tearDown(() async {
    try {
      await importDb.close();
    } catch (_) {
      // The test failed before the import database was created.
    }
  });

  test('a 1.5.3 backup file restores into a fresh 1.6.0 install under the new package id', () async {
    final exportDb = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      try {
        await exportDb.close();
      } catch (_) {
        // Already closed in the test body.
      }
    });
    await _seedExportState(exportDb);
    final map = await ForkBackupService(exportDb).buildBackupMap();

    // The file is a literal 1.5.3 v1 backup: frozen format, stamped
    // with the 1.5.3 version. 1.6.0 writes `plentv-backup`, so the old
    // format string is stamped onto the exported map to stand in for
    // the file a user actually has on disk from 1.5.3 — and 1.6.0
    // still accepts it (D2 dual-accept).
    map['format'] = 'pleztv-backup';
    expect(map['format'], 'pleztv-backup');
    expect(map['formatVersion'], 1);
    expect(map['appVersion'], '1.5.3-2.26.0');

    // Package-agnostic by construction: the file carries no package
    // name at all — neither the old id nor the new one — and no
    // absolute paths.
    final jsonString = jsonEncode(map);
    expect(jsonString, isNot(contains('com.pleztv.app')));
    expect(jsonString, isNot(contains('com.plentv.app')));
    expect(jsonString, isNot(contains('/home/')));
    expect(jsonString, isNot(contains('/data/')));
    expect(jsonString, isNot(contains('/tmp/')));
    expect(jsonString, isNot(contains('Android/data')));

    // Downloads never cross in the backup file.
    expect(map.containsKey('downloads'), isFalse);

    // Wipe: fresh database, fresh prefs, the REAL new package id —
    // the 1.6.0 shape (new applicationId, nothing carried over but
    // the file).
    await exportDb.close();
    resetSharedPreferencesForTest();
    SharedPreferences.resetStatic();
    _setMockPackage('com.plentv.app', '1.6.0-2.26.0', '235');
    importDb = AppDatabase.forTesting(NativeDatabase.memory());

    // The file crosses through the raw-bytes seam, as a real
    // user-carried file would.
    final report = await ForkBackupService(
      importDb,
    ).importFromBytes(Uint8List.fromList(utf8.encode(jsonString)));

    expect(report.connections.restored, 3, reason: 'xtream + m3u + plex');
    expect(report.connections.skipped, 0);
    expect(report.profiles.restored, 1);
    expect(report.profiles.skipped, 0);
    expect(report.profileConnections.restored, 1);
    expect(report.profileConnections.skipped, 0);
    expect(report.epg.restored, 1);
    expect(report.epg.skipped, 0);
    expect(report.favorites.restored, 1);
    expect(report.favorites.skipped, 0);
    expect(report.resume.restored, 1);
    expect(report.resume.skipped, 0);
    expect(report.epgPrefs.restored, 7);
    expect(report.epgPrefs.skipped, 0);
    expect(report.prefs.keysImported, 3, reason: '2 portable + 1 user-scoped library key');
    expect(report.activeProfileRestored, isTrue);

    // The login decrypts under the new package id.
    final connections = await ConnectionRegistry(importDb).list();
    expect(connections.map((c) => c.id).toSet(), {'trex', 'm3u-1', 'plex-1'});
    final xtream = connections.whereType<XtreamConnection>().single;
    expect(xtream.serverUrl, 'https://panel.example.com:8080');
    expect(xtream.username, 'user');
    expect(xtream.password, _testPassword);
    expect(xtream.hiddenCategoryIds, ['cat-news']);
    expect(xtream.hiddenCategoryInitials, ['AB', 'CD']);

    // Profiles + tokens + active profile.
    final profiles = await ProfileRegistry(importDb).list();
    expect(profiles, hasLength(1));
    expect(profiles.single.displayName, 'Main');
    final pcs = await ProfileConnectionRegistry(importDb).listAll();
    expect(pcs, hasLength(1));
    expect(pcs.single.userToken, 'token-123');
    expect(pcs.single.isDefault, isTrue);
    expect((await StorageService.getInstance()).getActiveProfileId(), 'profile-1');

    // EPG prefs, store, favourites and resume.
    final settings = await SettingsService.getInstance();
    expect(settings.read(SettingsService.iptvEpgDaysToLoad), 14);
    expect(settings.read(SettingsService.iptvEpgUpdateIntervalHours), 6);
    expect(settings.read(SettingsService.iptvEpgPastDays), 2);
    expect(settings.read(SettingsService.iptvEpgUpdateOnStart), isTrue);
    expect(settings.read(SettingsService.iptvEpgTimeOffsetMinutes), 30);
    expect(settings.read(SettingsService.iptvEpgUpdateTimeMinutes), 600);
    expect(settings.read(SettingsService.iptvEpgUpdateOnPlaylistChange), isFalse);
    final store = IptvEpgSourcesStore('trex');
    final sources = await store.loadUserSources();
    expect(sources, hasLength(1));
    expect(sources[0].url, 'https://example.com/epg.xml');
    final mappings = await store.loadMappings();
    expect(mappings['100']?.xmltvId, 'bbc.uk');
    expect(mappings['100']?.sourceId, 'provider');
    final prefs = await BaseSharedPreferencesService.sharedCache();
    expect(prefs.getString('iptv_fav_channels:trex'), jsonEncode(['100', '101']));
    expect(prefs.getString('iptv_resume:trex'), jsonEncode({'vod-1': 123}));
  });
}
