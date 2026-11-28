// Duplicate guard at add time (1.6.35, issue #11): re-signing in used to
// mint a fresh connection id every time, so a second "trex" row appeared
// and the old one kept feeding Live TV. After a successful probe the add
// screens now check the registry first: same host + username (Xtream) or
// same playlist URL (M3U) offers to update the existing connection
// (same id, new details) instead of silently adding a row.
//
// Failing-first: on the 1.6.34 base there is no matcher and no resolver,
// so this file does not compile there.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/iptv_connection_persistence.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/prefs.dart';

XtreamConnection _xtream({
  String id = 'trex-1',
  String name = 'Trex',
  String serverUrl = 'https://panel.example.com:8080',
  String username = 'user',
  String password = 'pass',
  DateTime? createdAt,
  List<String> hiddenCategoryIds = const [],
}) {
  return XtreamConnection(
    id: id,
    name: name,
    serverUrl: serverUrl,
    username: username,
    password: password,
    createdAt: createdAt ?? DateTime.utc(2026, 11, 26),
    hiddenCategoryIds: hiddenCategoryIds,
  );
}

M3uConnection _m3u({
  String id = 'm3u-1',
  String name = 'Playlist',
  String playlistUrl = 'https://example.test/playlist.m3u',
  String? epgUrl,
  DateTime? createdAt,
}) {
  return M3uConnection(
    id: id,
    name: name,
    playlistUrl: playlistUrl,
    epgUrl: epgUrl,
    createdAt: createdAt ?? DateTime.utc(2026, 11, 26),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => initializeDateFormatting('en'));

  group('findDuplicateIptvConnection', () {
    test('Xtream: same host + username matches, trailing slash ignored', () {
      final existing = [_xtream()];
      final candidate = _xtream(id: 'fresh-id', serverUrl: 'https://panel.example.com:8080/');

      expect(findDuplicateIptvConnection(existing: existing, candidate: candidate)?.id, 'trex-1');
    });

    test('Xtream: same host + username matches, scheme case ignored', () {
      final existing = [_xtream()];
      final candidate = _xtream(id: 'fresh-id', serverUrl: 'HTTPS://panel.example.com:8080');

      expect(findDuplicateIptvConnection(existing: existing, candidate: candidate)?.id, 'trex-1');
    });

    test('Xtream: a different username is a different connection', () {
      final existing = [_xtream()];
      final candidate = _xtream(id: 'fresh-id', username: 'other-user');

      expect(findDuplicateIptvConnection(existing: existing, candidate: candidate), isNull);
    });

    test('Xtream: a different host is a different connection', () {
      final existing = [_xtream()];
      final candidate = _xtream(id: 'fresh-id', serverUrl: 'https://other.example.com:8080');

      expect(findDuplicateIptvConnection(existing: existing, candidate: candidate), isNull);
    });

    test('M3U: the same playlist URL matches, surrounding space ignored', () {
      final existing = [_m3u()];
      final candidate = _m3u(id: 'fresh-id', playlistUrl: '  https://example.test/playlist.m3u  ');

      expect(findDuplicateIptvConnection(existing: existing, candidate: candidate)?.id, 'm3u-1');
    });

    test('M3U: a different playlist URL is a different connection', () {
      final existing = [_m3u()];
      final candidate = _m3u(id: 'fresh-id', playlistUrl: 'https://example.test/other.m3u');

      expect(findDuplicateIptvConnection(existing: existing, candidate: candidate), isNull);
    });

    test('Xtream never matches an M3U row and vice versa', () {
      expect(findDuplicateIptvConnection(existing: [_m3u()], candidate: _xtream()), isNull);
      expect(findDuplicateIptvConnection(existing: [_xtream()], candidate: _m3u()), isNull);
    });

    test('a Plex connection never matches', () {
      // A non-IPTV candidate has no duplicate by definition.
      final plex = PlexAccountConnection(
        id: 'plex-1',
        accountToken: 'token',
        clientIdentifier: 'client-1',
        accountLabel: 'Plex',
        servers: const [],
        createdAt: DateTime.utc(2026, 11, 26),
      );
      expect(findDuplicateIptvConnection(existing: [_xtream()], candidate: plex), isNull);
    });
  });

  group('resolveDuplicateIptvConnection', () {
    late AppDatabase db;
    late ConnectionRegistry connections;

    setUp(() async {
      resetSharedPreferencesForTest();
      LocaleSettings.setLocaleSync(AppLocale.en);
      db = AppDatabase.forTesting(NativeDatabase.memory());
      connections = ConnectionRegistry(db);
    });

    tearDown(() async {
      await db.close();
    });

    /// Mutable outcome holder: the resolver runs async behind the 'go'
    /// button, so the test reads [resolved]/[settled] after driving the
    /// dialog instead of from a snapshot taken before it.
    Future<_ResolverOutcome> pumpResolver(
      WidgetTester tester,
      Connection candidate,
    ) async {
      final outcome = _ResolverOutcome();
      await tester.pumpWidget(
        TranslationProvider(
          child: Provider<ConnectionRegistry>.value(
            value: connections,
            child: MaterialApp(
              home: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    outcome.resolved = await resolveDuplicateIptvConnection(context: context, candidate: candidate);
                    outcome.settled = true;
                  },
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      return outcome;
    }

    testWidgets('no duplicate returns the candidate with no dialog', (tester) async {
      final candidate = _xtream(id: 'fresh-id');

      final outcome = await pumpResolver(tester, candidate);

      expect(find.text(t.addServer.duplicateConnectionTitle), findsNothing);
      expect(outcome.settled, isTrue);
      expect(outcome.resolved?.id, 'fresh-id');
    });

    testWidgets('Update existing returns the old id with the new details', (tester) async {
      await connections.upsert(
        _xtream(hiddenCategoryIds: const ['cat-1'], createdAt: DateTime.utc(2026, 11, 26)),
      );
      final candidate = _xtream(
        id: 'fresh-id',
        name: 'Trex new name',
        password: 'new-pass',
        serverUrl: 'https://panel.example.com:8080/',
      );

      final outcome = await pumpResolver(tester, candidate);

      // The dialog is showing; nothing resolved yet.
      expect(outcome.settled, isFalse);
      expect(find.text(t.addServer.duplicateConnectionTitle), findsOneWidget);
      expect(find.textContaining('Nov 26, 2026'), findsOneWidget);

      await tester.tap(find.text(t.addServer.duplicateUpdateExisting));
      await tester.pumpAndSettle();

      expect(find.text(t.addServer.duplicateConnectionTitle), findsNothing);
      expect(outcome.settled, isTrue);
      final updated = outcome.resolved;
      expect(updated, isA<XtreamConnection>());
      expect(updated?.id, 'trex-1');
      expect((updated as XtreamConnection).password, 'new-pass');
      expect(updated.name, 'Trex new name');
      // The original row is kept: its added date and hidden categories.
      // (The DB round-trips createdAt as local time; compare by epoch.)
      expect(updated.createdAt.millisecondsSinceEpoch, DateTime.utc(2026, 11, 26).millisecondsSinceEpoch);
      expect(updated.hiddenCategoryIds, const ['cat-1']);
    });

    testWidgets('Add separate returns the candidate untouched', (tester) async {
      await connections.upsert(_xtream());
      final candidate = _xtream(id: 'fresh-id');

      final outcome = await pumpResolver(tester, candidate);

      expect(find.text(t.addServer.duplicateConnectionTitle), findsOneWidget);
      await tester.tap(find.text(t.addServer.duplicateAddSeparate));
      await tester.pumpAndSettle();

      expect(outcome.settled, isTrue);
      expect(outcome.resolved?.id, 'fresh-id');
    });

    testWidgets('Cancel returns null and leaves the registry alone', (tester) async {
      await connections.upsert(_xtream());
      final candidate = _xtream(id: 'fresh-id');

      final outcome = await pumpResolver(tester, candidate);

      expect(find.text(t.addServer.duplicateConnectionTitle), findsOneWidget);
      await tester.tap(find.text(t.common.cancel));
      await tester.pumpAndSettle();

      expect(outcome.settled, isTrue);
      expect(outcome.resolved, isNull);
      expect((await connections.list()).length, 1);
    });
  });
}

/// Mutable holder for what the resolver returned, so the test can read it
/// after driving the dialog (the resolver runs async behind the button).
class _ResolverOutcome {
  Connection? resolved;
  bool settled = false;
}
