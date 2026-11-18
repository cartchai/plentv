// Control tests for PlezTV 1.4.3 C3 (403 circuit breaker) — new API only.
//
// Covers what the behavioral harness cannot reach without the new API:
// the cooldown expiry ([XtreamApi.breakerCooldown]), the manual clear
// ([clearBreaker]), the log-derived provider ([recent403Provider]) and
// the [isIn403Cooldown] getter. This file does NOT compile on the 1.4.2
// base — the API it exercises does not exist there — which is itself
// the failing-first evidence for this seam: the feature is absent.
// Run it on the fix only. No live panel: MockClient only. Credentials
// below are fake.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

XtreamApi _api({
  required http.Client client,
  Future<bool> Function()? recent403Provider,
}) {
  return XtreamApi(
    serverUrl: 'https://panel.example.com:8080',
    username: 'alice-7',
    password: 'hunter-9',
    httpClient: client,
    recent403Provider: recent403Provider,
  );
}

Matcher _is403() => isA<MediaServerHttpException>().having((e) => e.statusCode, 'statusCode', 403);

void main() {
  test('the breaker expires after the cooldown and the panel is asked again', () async {
    final previous = XtreamApi.breakerCooldown;
    XtreamApi.breakerCooldown = const Duration(milliseconds: 50);
    try {
      var requests = 0;
      final api = _api(
        client: MockClient((_) async {
          requests++;
          return http.Response('{"error": "blocked"}', 403);
        }),
      );
      await expectLater(api.getUserInfo(), throwsA(_is403()));
      await expectLater(api.getUserInfo(), throwsA(_is403()));
      expect(requests, 1, reason: 'breaker open');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await expectLater(api.getUserInfo(), throwsA(_is403()));
      expect(requests, 2, reason: 'cooldown lapsed, the panel is asked again');
    } finally {
      XtreamApi.breakerCooldown = previous;
    }
  });

  test('clearBreaker re-opens the panel immediately', () async {
    var requests = 0;
    final api = _api(
      client: MockClient((_) async {
        requests++;
        return http.Response('{"error": "blocked"}', 403);
      }),
    );
    await expectLater(api.getUserInfo(), throwsA(_is403()));
    await expectLater(api.getUserInfo(), throwsA(_is403()));
    expect(requests, 1);
    api.clearBreaker();
    await expectLater(api.getUserInfo(), throwsA(_is403()));
    expect(requests, 2, reason: 'a deliberate clear re-fires once');
  });

  test('a provider saying "recent 403" gates every call with zero panel requests', () async {
    var requests = 0;
    final api = _api(
      recent403Provider: () async => true,
      client: MockClient((_) async {
        requests++;
        return http.Response('{"user_info": {}}', 200);
      }),
    );
    expect(await api.isIn403Cooldown, isTrue);
    await expectLater(api.getUserInfo(), throwsA(_is403()));
    await expectLater(api.getXmltvFeed(), throwsA(_is403()));
    expect(requests, 0, reason: 'the log-derived breaker fires before any request');
  });

  test('a throwing provider fails open', () async {
    var requests = 0;
    final api = _api(
      recent403Provider: () async => throw StateError('log broken'),
      client: MockClient((_) async {
        requests++;
        return http.Response('{"error": "blocked"}', 403);
      }),
    );
    expect(await api.isIn403Cooldown, isFalse);
    await expectLater(api.getUserInfo(), throwsA(_is403()));
    expect(requests, 1, reason: 'a broken diagnostic must not take the server offline');
  });

  test('isIn403Cooldown tracks the breaker', () async {
    final api = _api(
      client: MockClient((_) async => http.Response('{"error": "blocked"}', 403)),
    );
    expect(await api.isIn403Cooldown, isFalse);
    await expectLater(api.getUserInfo(), throwsA(_is403()));
    expect(await api.isIn403Cooldown, isTrue);
    api.clearBreaker();
    expect(await api.isIn403Cooldown, isFalse);
  });
}
