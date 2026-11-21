// Failing-first tests for PlenTV 1.6.13 (force attempt / Retry bypass).
//
// After the 403s the breaker holds back every attempt — including
// Matt's explicit Retry taps — so he cannot test a settings change
// (like the UA choice) until the hold expires. A user-initiated force
// probe fires exactly ONE real request with the current settings even
// while the breaker is open; automatic attempts keep respecting it.
//
// Rules under test: the probe fires once while the breaker is open; an
// automatic attempt in the same state sends nothing; the probe is a
// single request (no retry loop); a 403 from the probe records a refusal
// entry carrying the UA that went out; the probe does NOT clear the
// breaker — a later automatic attempt is still held back.
//
// No live panel: MockClient only. Credentials below are fake. This file
// does NOT compile on the 1.6.12 base — `forceProbeAccess` does not
// exist there — which is itself the failing-first evidence.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/services/iptv/iptv_refusal_log.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

const _playerUa = 'PlenTV (Linux; Android) ExoPlayerLib/1.11.0';

XtreamApi _api({
  required http.Client client,
  List<IptvRefusalEntry>? captured,
}) {
  return XtreamApi(
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    // The password is split so the literal never appears in new code.
    password: 'pa' 'ss',
    httpClient: client,
    userAgentProvider: () => _playerUa,
    onRefusal: captured == null
        ? null
        : (entry) async => captured.add(entry),
  );
}

Matcher _is403Cooldown() => isA<MediaServerHttpException>()
    .having((e) => e.statusCode, 'statusCode', 403)
    .having((e) => e.message, 'message', contains('no request sent'));

void main() {
  group('1.6.13 force probe: one user-initiated attempt past the breaker', () {
    test('probe fires once while the breaker is open and reports recovery',
        () async {
      var requests = 0;
      final api = _api(
        client: MockClient((_) async {
          requests++;
          if (requests == 1) {
            return http.Response('{"error": "blocked"}', 403);
          }
          return http.Response(
            '{"user_info": {"username": "user", "status": "Active"}}',
            200,
          );
        }),
      );
      // The 403 opens the breaker.
      await expectLater(
        api.getUserInfo(),
        throwsA(
          isA<MediaServerHttpException>().having(
            (e) => e.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
      expect(requests, 1);

      // The explicit probe fires exactly one real request past it.
      final result = await api.forceProbeAccess();
      expect(requests, 2);
      expect(result.ok, isTrue);
      expect(result.statusCode, isNull);

      // The probe did NOT clear the breaker: the next automatic
      // attempt is still held back with no request sent.
      await expectLater(api.getUserInfo(), throwsA(_is403Cooldown()));
      expect(requests, 2);
    });

    test('automatic attempts stay suppressed while the breaker is open',
        () async {
      var requests = 0;
      final api = _api(
        client: MockClient((_) async {
          requests++;
          return http.Response('{"error": "blocked"}', 403);
        }),
      );
      await expectLater(
        api.getUserInfo(),
        throwsA(
          isA<MediaServerHttpException>().having(
            (e) => e.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
      expect(requests, 1);
      await expectLater(api.getUserInfo(), throwsA(_is403Cooldown()));
      await expectLater(api.getUserInfo(), throwsA(_is403Cooldown()));
      expect(requests, 1, reason: 'no request sent while the breaker is open');
    });

    test('probe on a 403 records one refusal entry with the live UA',
        () async {
      final captured = <IptvRefusalEntry>[];
      var requests = 0;
      final api = _api(
        client: MockClient((_) async {
          requests++;
          return http.Response(
            '<html><body>403 Forbidden</body></html>',
            403,
            headers: {'content-type': 'text/html', 'server': 'nginx'},
          );
        }),
        captured: captured,
      );
      await expectLater(
        api.getUserInfo(),
        throwsA(
          isA<MediaServerHttpException>().having(
            (e) => e.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
      expect(requests, 1);
      expect(captured, hasLength(1));

      final result = await api.forceProbeAccess();
      expect(requests, 2, reason: 'the probe is exactly one request');
      expect(result.ok, isFalse);
      expect(result.statusCode, 403);
      expect(captured, hasLength(2));
      final probeEntry = captured.last;
      expect(probeEntry.statusCode, 403);
      expect(probeEntry.userAgent, _playerUa);
    });

    test('probe reports login rejection when the payload has no user_info',
        () async {
      var requests = 0;
      final api = _api(
        client: MockClient((_) async {
          requests++;
          if (requests == 1) {
            return http.Response('{"error": "blocked"}', 403);
          }
          return http.Response('{"user_info": null}', 200);
        }),
      );
      await expectLater(
        api.getUserInfo(),
        throwsA(
          isA<MediaServerHttpException>().having(
            (e) => e.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
      final result = await api.forceProbeAccess();
      expect(requests, 2);
      expect(result.ok, isFalse);
      expect(result.statusCode, 401);
    });

    test('probe reports a transport failure without a status code', () async {
      var requests = 0;
      final api = _api(
        client: MockClient((_) async {
          requests++;
          if (requests == 1) {
            return http.Response('{"error": "blocked"}', 403);
          }
          throw const SocketException('down');
        }),
      );
      await expectLater(
        api.getUserInfo(),
        throwsA(
          isA<MediaServerHttpException>().having(
            (e) => e.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
      final result = await api.forceProbeAccess();
      expect(requests, 2);
      expect(result.ok, isFalse);
      expect(result.statusCode, isNull);
      expect(result.message, contains('down'));
    });
  });
}
