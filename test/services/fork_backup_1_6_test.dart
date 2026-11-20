// PlenTV 1.6 (D2) — backup format rename with dual-accept.
//
// Failing-first: on the 1.5.3 base this file fails — `buildBackupMap`
// writes `pleztv-backup`, and there is no legacy-accept path to test.
// After the fix: new backups write `plentv-backup`, old `pleztv-backup`
// files still restore, and a legacy file with a future formatVersion is
// still rejected.
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
import 'package:plezy/services/fork_backup_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers/prefs.dart';

const _testPassword = 'pa' 'ss';

XtreamConnection _xtream() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
);

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
    _setMockPackage('com.example.plentv', '1.6.0-2.26.0', '235');
  });

  tearDown(() async {
    try {
      await importDb.close();
    } catch (_) {
      // The test failed before the import database was created.
    }
  });

  Future<Map<String, dynamic>> _exportOneConnectionMap() async {
    final exportDb = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      try {
        await exportDb.close();
      } catch (_) {}
    });
    await ConnectionRegistry(exportDb).upsert(_xtream());
    final map = await ForkBackupService(exportDb).buildBackupMap();
    await exportDb.close();
    resetSharedPreferencesForTest();
    SharedPreferences.resetStatic();
    return map;
  }

  test('new backups write the plentv-backup format', () async {
    final map = await _exportOneConnectionMap();
    expect(map['format'], 'plentv-backup');
    expect(map['formatVersion'], 1);
  });

  test('new backup files take the plentv-backup filename', () async {
    final exportDb = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      try {
        await exportDb.close();
      } catch (_) {}
    });
    await ConnectionRegistry(exportDb).upsert(_xtream());
    Uint8List? captured;
    final path = await ForkBackupService(
      exportDb,
      debugDownloadsWriter: ({required String fileName, required Uint8List bytes, String mimeType = 'text/plain'}) async {
        captured = bytes;
        return 'downloads/$fileName';
      },
    ).exportToFile();
    expect(path, startsWith('downloads/plentv-backup-'));
    expect(path, endsWith('.json'));
    expect(captured, isNotNull);
    final written = jsonDecode(utf8.decode(captured!)) as Map<String, dynamic>;
    expect(written['format'], 'plentv-backup');
  });

  test('an old pleztv-backup file restores into 1.6', () async {
    final map = await _exportOneConnectionMap();
    // Rewrite the format string to the pre-1.6 one: the file a user
    // actually has on disk from 1.5.3.
    map['format'] = 'pleztv-backup';
    importDb = AppDatabase.forTesting(NativeDatabase.memory());
    final report = await ForkBackupService(importDb).applyBackupMap(map);
    expect(report.connections.restored, 1);
    expect(report.connections.skipped, 0);
    final connections = await ConnectionRegistry(importDb).list();
    expect(connections.whereType<XtreamConnection>().single.password, _testPassword);
  });

  test('a new plentv-backup file restores into 1.6', () async {
    final map = await _exportOneConnectionMap();
    importDb = AppDatabase.forTesting(NativeDatabase.memory());
    final report = await ForkBackupService(importDb).applyBackupMap(map);
    expect(report.connections.restored, 1);
    final connections = await ConnectionRegistry(importDb).list();
    expect(connections.whereType<XtreamConnection>().single.password, _testPassword);
  });

  test('a legacy file with a future formatVersion is still rejected', () async {
    final map = await _exportOneConnectionMap();
    map['format'] = 'pleztv-backup';
    map['formatVersion'] = 2;
    importDb = AppDatabase.forTesting(NativeDatabase.memory());
    await expectLater(
      () => ForkBackupService(importDb).applyBackupMap(map),
      throwsA(isA<ForkBackupException>()),
    );
  });

  test('round-trip: 1.6 export restores and re-exports the same connections', () async {
    final map1 = await _exportOneConnectionMap();
    importDb = AppDatabase.forTesting(NativeDatabase.memory());
    final report = await ForkBackupService(importDb).applyBackupMap(map1);
    expect(report.connections.restored, 1);
    final map2 = await ForkBackupService(importDb).buildBackupMap();
    expect(map2['format'], 'plentv-backup');
    expect(map2['formatVersion'], 1);
    expect(map2['connections'], map1['connections']);
  });
}
