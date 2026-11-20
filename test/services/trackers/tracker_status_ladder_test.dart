import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/trackers/mdblist/mdblist_auth_service.dart';
import 'package:plezy/services/trackers/mdblist/mdblist_client.dart';
import 'package:plezy/services/trackers/tracker_constants.dart';
import 'package:plezy/services/trackers/tracker_exceptions.dart';
import 'package:plezy/services/trackers/tracker_session.dart';

TrackerSession _session({String refreshToken = 'refresh-old'}) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return TrackerSession(
    accessToken: 'access-old',
    refreshToken: refreshToken,
    expiresAt: now + 86400,
    createdAt: now,
    username: 'alice',
  );
}

void main() {
  group('MDBList status ladder', () {
    test('surfaces 429 as a typed rate limit carrying Retry-After', () async {
      final client = MdblistClient(
        _session(),
        onSessionInvalidated: () => fail('429 should not invalidate the session'),
        httpClient: MockClient((_) async => http.Response('slow down', 429, headers: {'retry-after': '23'})),
      );
      addTearDown(client.dispose);

      await expectLater(
        client.getUser(),
        throwsA(
          isA<TrackerRateLimitException>()
              .having((e) => e.service, 'service', TrackerService.mdblist)
              .having((e) => e.retryAfterSeconds, 'retryAfterSeconds', 23),
        ),
      );
    });

    test('propagates the refresh TrackerAuthException after a 401', () async {
      var invalidated = 0;
      final mock = MockClient((request) async {
        if (request.url.path == '/oauth/token/') {
          return http.Response(json.encode({'error': 'invalid_grant'}), 400);
        }
        return http.Response('unauthorized', 401);
      });
      final client = MdblistClient(
        _session(refreshToken: 'refresh-ladder'),
        onSessionInvalidated: () => invalidated++,
        httpClient: mock,
        authService: MdblistAuthService(httpClient: mock),
      );
      addTearDown(client.dispose);

      await expectLater(
        client.getUser(),
        throwsA(isA<TrackerAuthException>().having((e) => e.isPermanent, 'isPermanent', isTrue)),
      );
      expect(invalidated, 1);
    });

    test('a 409 is a failure on scrobble and on other requests alike', () async {
      final client = MdblistClient(
        _session(),
        onSessionInvalidated: () => fail('409 should not invalidate the session'),
        httpClient: MockClient((_) async => http.Response('conflict', 409)),
      );
      addTearDown(client.dispose);

      final conflict = isA<TrackerApiException>().having((e) => e.statusCode, 'statusCode', 409);
      await expectLater(client.scrobble('stop', const {'progress': 90}), throwsA(conflict));
      await expectLater(client.getUser(), throwsA(conflict));
    });
  });
}
