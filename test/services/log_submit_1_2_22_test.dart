// Log submit to our GitHub via the Cloudflare Worker (1.2.22 §66 U1) —
// failing-first.
//
// The repo is public, so the submit path must redact on-device before
// anything leaves: known identifiers gathered from the registry
// (names, URLs, usernames, passwords, tokens, profile names), plus
// pattern rules (emails, username= params, non-allowlist hosts, vault
// blobs, home-dir usernames, the shared manager's rules). The Worker
// receives nothing unredacted and files the issue; the app never talks
// to GitHub directly and no token ships in the app.
//
// Synthetic credentials only — never the real login, never real panel
// values. The fake panel host below is the same placeholder the other
// IPTV tests use.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/services/log_submit_service.dart';
import 'package:plezy/utils/log_redaction_manager.dart';
import 'package:plezy/utils/media_server_http_client.dart';

import '../test_helpers/prefs.dart';

const _testPassword = 'pa' 'ss';
const _createdAtMs = 1700000000000;
const _workerEndpoint = 'https://worker.example.test/submit';
const _issueUrl = 'https://github.com/cartchai/plentv/issues/123';

MediaServerHttpClient _fakeClient({
  required void Function(http.Request request) onRequest,
  int status = 201,
  String body = '{"issueUrl": "$_issueUrl", "issueNumber": 123}',
}) {
  final client = MediaServerHttpClient(
    client: MockClient((request) async {
      onRequest(request);
      return http.Response(body, status, headers: {'content-type': 'application/json'});
    }),
  );
  return client;
}

Future<void> _seedRegistry(AppDatabase db) async {
  await ConnectionRegistry(db).upsert(
    XtreamConnection(
      id: 'trex',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: _testPassword,
      createdAt: DateTime.fromMillisecondsSinceEpoch(_createdAtMs),
    ),
  );
  await ProfileRegistry(db).upsert(
    Profile.local(
      id: 'profile-1',
      displayName: 'Main',
      pinHash: 'hash-1',
      sortOrder: 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(_createdAtMs),
    ),
  );
  await ProfileConnectionRegistry(db).upsert(
    ProfileConnection(
      profileId: 'profile-1',
      connectionId: 'trex',
      userToken: 'token-123',
      userIdentifier: 'user-1',
      isDefault: true,
      tokenAcquiredAt: DateTime.fromMillisecondsSinceEpoch(_createdAtMs),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
  });

  tearDown(LogRedactionManager.clearTrackedValues);

  group('redactDiagnosticLogForSubmit', () {
    test('R1: allowlist hosts survive, provider host is masked', () {
      const log =
          'Poster https://image.tmdb.org/t/p/w500/x.jpg loaded\n'
          'Feed https://panel.example.com:8080/xmltv.php?username=user&password=pass downloaded';
      final redacted = redactDiagnosticLogForSubmit(log);
      expect(redacted, contains('https://image.tmdb.org/t/p/w500/x.jpg'));
      expect(redacted, isNot(contains('panel.example.com')));
      expect(redacted, contains('https://[REDACTED_HOST]/xmltv.php'));
    });

    test('R2: username/password query params are stripped', () {
      const log =
          'GET https://panel.example.com:8080/player_api.php?username=testuser&password=testpass123';
      final redacted = redactDiagnosticLogForSubmit(log);
      expect(redacted, isNot(contains('testuser')));
      expect(redacted, isNot(contains('testpass123')));
      expect(redacted, contains('username=[REDACTED]'));
      expect(redacted, contains('password=[REDACTED]'));
    });

    test('R3: email addresses are stripped', () {
      final redacted = redactDiagnosticLogForSubmit('Signed in as me@example.com');
      expect(redacted, isNot(contains('me@example.com')));
      expect(redacted, contains('[REDACTED]'));
    });

    test('R4: extras strip bare mentions of known identifiers', () {
      final redacted = redactDiagnosticLogForSubmit(
        'Profile Main signed in with token-123',
        extraSensitiveValues: const ['Main', 'token-123'],
      );
      expect(redacted, isNot(contains('Main')));
      expect(redacted, isNot(contains('token-123')));
    });

    test('R5: Bearer token, vault blob and URL userinfo are stripped', () {
      const log =
          'Authorization: Bearer abc123token\n'
          'Stored enc:v1:abc123+/=xyz\n'
          'Fetched https://user:pass123@example.com/list.m3u';
      final redacted = redactDiagnosticLogForSubmit(log);
      expect(redacted, isNot(contains('abc123token')));
      expect(redacted, isNot(contains('enc:v1:')));
      expect(redacted, isNot(contains('pass123')));
      expect(redacted, isNot(contains('user:pass123@')));
    });

    test('R6: IPv4 addresses are masked by the shared manager', () {
      final redacted = redactDiagnosticLogForSubmit('Server at 192.0.2.55 refused');
      expect(redacted, isNot(contains('192.0.2.55')));
    });

    test('R7: values registered with the shared manager are stripped', () {
      LogRedactionManager.registerServer('https://plex.example.com:32400', 'plex-token-xyz');
      final redacted = redactDiagnosticLogForSubmit(
        'Plex https://plex.example.com:32400/library token plex-token-xyz',
      );
      expect(redacted, isNot(contains('plex.example.com')));
      expect(redacted, isNot(contains('plex-token-xyz')));
    });

    test('R8: desktop home-directory usernames are stripped', () {
      final redacted = redactDiagnosticLogForSubmit(
        'Log at /home/someuser/.config/plezy/debug.log and C:\\Users\\someuser\\plezy\\log.txt',
      );
      expect(redacted, isNot(contains('someuser')));
      expect(redacted, contains('/home/[REDACTED]'));
    });

    test('R9: a player_api URL is masked host and params together', () {
      const log = 'https://panel.example.com:8080/player_api.php?username=testuser&password=testpass123';
      final redacted = redactDiagnosticLogForSubmit(log);
      expect(redacted, isNot(contains('panel.example.com')));
      expect(redacted, isNot(contains('testuser')));
      expect(redacted, isNot(contains('testpass123')));
    });
  });

  group('constrainDiagnosticPayload', () {
    test('unchanged below the budget', () {
      const header = '== Summary ==\n';
      const logs = 'one\ntwo';
      expect(
        constrainDiagnosticPayload(header: header, logs: logs, maxBytes: 128),
        '$header$logs',
      );
    });

    test('over budget keeps the header and the newest lines', () {
      const header = '== Summary ==\n';
      final logs = List.generate(20, (i) => 'line $i').join('\n');
      final trimmed = constrainDiagnosticPayload(header: header, logs: logs, maxBytes: 60);
      expect(trimmed, startsWith(header));
      expect(trimmed, contains('line 19'));
      expect(trimmed, isNot(contains('line 0\n')));
      expect(utf8.encode(trimmed).length, lessThanOrEqualTo(60));
    });
  });

  test('buildLogSubmitBody wraps the log in a fence with a footer', () {
    const log = '== Summary ==\n---\nline one\nline two';
    final body = buildLogSubmitBody(log);
    expect(body, startsWith('```\n'));
    expect(body, contains('line one'));
    expect(body, contains('redacted on this device before sending'));
  });

  group('submitDiagnosticLog', () {
    test('S1: posts redacted JSON to the Worker and returns the issue', () async {
      http.Request? request;
      final client = _fakeClient(onRequest: (r) => request = r);
      addTearDown(client.close);

      const log =
          '== Summary ==\n---\nwidget submit seed\n'
          'Feed https://panel.example.com:8080/xmltv.php downloaded';
      final issue = await submitDiagnosticLog(
        title: 'PlenTV debug log 2026-11-16',
        logText: log,
        sensitiveValues: const ['panel.example.com'],
        client: client,
        endpointOverride: _workerEndpoint,
      );

      expect(issue.url, _issueUrl);
      expect(issue.number, 123);
      expect(request!.method, 'POST');
      expect(request!.url, Uri.parse(_workerEndpoint));
      final contentType = request!.headers.entries
          .singleWhere((entry) => entry.key.toLowerCase() == 'content-type')
          .value;
      expect(contentType, startsWith('application/json'));
      final posted = jsonDecode(request!.body) as Map<String, dynamic>;
      expect(posted['title'], 'PlenTV debug log 2026-11-16');
      final postedBody = posted['body'] as String;
      expect(postedBody, contains('widget submit seed'));
      expect(postedBody, isNot(contains('panel.example.com')));
      expect(utf8.encode(postedBody).length, lessThanOrEqualTo(maxLogSubmitBytes));
    });

    test('S2: a non-2xx answer throws', () async {
      final client = _fakeClient(onRequest: (_) {}, status: 500, body: 'boom');
      addTearDown(client.close);
      await expectLater(
        submitDiagnosticLog(
          title: 't',
          logText: 'l',
          client: client,
          endpointOverride: _workerEndpoint,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('S2b: a non-2xx answer with a decodable body throws too', () async {
      final client = _fakeClient(onRequest: (_) {}, status: 500, body: '{"error":"boom"}');
      addTearDown(client.close);
      await expectLater(
        submitDiagnosticLog(
          title: 't',
          logText: 'l',
          client: client,
          endpointOverride: _workerEndpoint,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('S3: no endpoint configured throws without calling the client', () async {
      var called = false;
      final client = _fakeClient(onRequest: (_) => called = true);
      addTearDown(client.close);
      await expectLater(
        submitDiagnosticLog(title: 't', logText: 'l', client: client, endpointOverride: ''),
        throwsA(isA<StateError>()),
      );
      expect(called, isFalse);
    });

    test('S4: collectSensitiveValues gathers the registry identifiers', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _seedRegistry(db);

      final values = await collectSensitiveValuesForLogSubmit(db);
      expect(values, contains('Trex'));
      expect(values, contains('https://panel.example.com:8080'));
      expect(values, contains('panel.example.com'));
      expect(values, contains('user'));
      expect(values, contains(_testPassword));
      expect(values, contains('Main'));
      expect(values, contains('token-123'));
      expect(values, contains('user-1'));

      // And those values, used as extras, strip a log that names them.
      const log = 'Trex https://panel.example.com:8080 user Main token-123';
      expect(redactDiagnosticLogForSubmit(log, extraSensitiveValues: values), isNot(contains('Trex')));
      expect(redactDiagnosticLogForSubmit(log, extraSensitiveValues: values), isNot(contains('token-123')));
    });
  });
}
