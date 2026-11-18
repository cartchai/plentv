// Failing-first tests for PlezTV 1.4.3 C3 (403 circuit breaker).
//
// Proves: after the panel answers 403 once, this client makes NO further
// panel call for five minutes — every send path (JSON API, catalog file
// streaming, guide feed, feed download-to-file) throws a 403 without
// touching the network and without recording another refusal. 429, 5xx
// and transport failures do NOT open the breaker. On the 1.4.2 base
// these tests fail behaviorally: every call re-fires (the request count
// grows with every call) because there is no breaker. This file uses
// only the pre-existing XtreamApi constructor, so it compiles on the
// base and fails on behavior, not on a missing symbol. No live panel:
// MockClient only. Credentials below are fake.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/services/iptv/iptv_refusal_log.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

XtreamApi _api({
  required http.Client client,
  List<IptvRefusalEntry>? captured,
}) {
  return XtreamApi(
    serverUrl: 'https://panel.example.com:8080',
    username: 'alice-7',
    password: 'hunter-9',
    httpClient: client,
    onRefusal: captured == null ? null : (entry) async => captured.add(entry),
  );
}

Matcher _is403() => isA<MediaServerHttpException>().having((e) => e.statusCode, 'statusCode', 403);

void main() {
  test('after a 403, further JSON API calls make no panel request and record no new refusal', () async {
    final captured = <IptvRefusalEntry>[];
    var requests = 0;
    final api = _api(
      captured: captured,
      client: MockClient((_) async {
        requests++;
        return http.Response('{"error": "blocked"}', 403);
      }),
    );
    await expectLater(api.getUserInfo(), throwsA(_is403()));
    expect(requests, 1);
    expect(captured, hasLength(1));
    expect(captured.single.statusCode, 403);
    await expectLater(api.getUserInfo(), throwsA(_is403()));
    await expectLater(api.getLiveCategories(), throwsA(_is403()));
    expect(requests, 1, reason: 'no panel call after the first 403');
    expect(captured, hasLength(1), reason: 'the cooldown throw records no refusal');
  });

  test('after a 403, the guide feed makes no panel request', () async {
    final captured = <IptvRefusalEntry>[];
    var requests = 0;
    final api = _api(
      captured: captured,
      client: MockClient((_) async {
        requests++;
        return http.Response('{"error": "blocked"}', 403);
      }),
    );
    await expectLater(api.getUserInfo(), throwsA(_is403()));
    expect(requests, 1);
    await expectLater(api.getXmltvFeed(), throwsA(_is403()));
    expect(requests, 1, reason: 'the feed shares the breaker with the API');
    expect(captured, hasLength(1));
  });

  test('after a 403, the feed download-to-file makes no panel request', () async {
    final captured = <IptvRefusalEntry>[];
    var requests = 0;
    final api = _api(
      captured: captured,
      client: MockClient((_) async {
        requests++;
        return http.Response('{"error": "blocked"}', 403);
      }),
    );
    await expectLater(api.getUserInfo(), throwsA(_is403()));
    final dir = Directory.systemTemp.createTempSync('pleztv-143-c3-');
    try {
      await expectLater(
        api.downloadXmltvFeedToFile(filePath: '${dir.path}/feed.xml'),
        throwsA(_is403()),
      );
      expect(requests, 1, reason: 'the file download shares the breaker');
      expect(captured, hasLength(1));
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('after a 403, a catalog file-stream makes no panel request', () async {
    final captured = <IptvRefusalEntry>[];
    var requests = 0;
    final api = _api(
      captured: captured,
      client: MockClient((_) async {
        requests++;
        return http.Response('{"error": "blocked"}', 403);
      }),
    );
    await expectLater(api.getUserInfo(), throwsA(_is403()));
    final dir = Directory.systemTemp.createTempSync('pleztv-143-c3-');
    try {
      await expectLater(
        api.getVodStreamsToFile(filePath: '${dir.path}/vod.json'),
        throwsA(_is403()),
      );
      expect(requests, 1, reason: 'the catalog stream shares the breaker');
      expect(captured, hasLength(1));
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('429 does not open the breaker', () async {
    final captured = <IptvRefusalEntry>[];
    var requests = 0;
    final api = _api(
      captured: captured,
      client: MockClient((_) async {
        requests++;
        return http.Response('Slow down', 429);
      }),
    );
    await expectLater(api.getUserInfo(), throwsA(isA<MediaServerHttpException>()));
    await expectLater(api.getUserInfo(), throwsA(isA<MediaServerHttpException>()));
    expect(requests, 2, reason: 'a 429 is rate-limiting, not a refusal');
    expect(captured, hasLength(2));
  });

  test('500 does not open the breaker', () async {
    var requests = 0;
    final api = _api(
      client: MockClient((_) async {
        requests++;
        return http.Response('Server error', 500);
      }),
    );
    await expectLater(api.getUserInfo(), throwsA(isA<MediaServerHttpException>()));
    await expectLater(api.getUserInfo(), throwsA(isA<MediaServerHttpException>()));
    expect(requests, 2, reason: 'a 5xx is transient, not a refusal');
  });

  test('a transport failure does not open the breaker', () async {
    var requests = 0;
    final api = _api(
      client: MockClient((_) async {
        requests++;
        throw const SocketException('connection failed');
      }),
    );
    await expectLater(api.getUserInfo(), throwsA(isA<MediaServerHttpException>()));
    await expectLater(api.getUserInfo(), throwsA(isA<MediaServerHttpException>()));
    expect(requests, 2, reason: 'the panel never answered, so nothing refused us');
  });

  test('a fresh client instance without a log provider is fail-open', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('{"error": "blocked"}', 403);
    });
    final first = _api(client: client);
    await expectLater(first.getUserInfo(), throwsA(_is403()));
    expect(requests, 1);
    // A new instance shares no in-memory flag with the first. In
    // production the log-derived provider is what shares the breaker
    // across instances; without one, fail-open is the safe default.
    final second = _api(client: client);
    await expectLater(second.getUserInfo(), throwsA(_is403()));
    expect(requests, 2);
  });

  test('the cooldown throw names itself and records nothing', () async {
    final captured = <IptvRefusalEntry>[];
    var requests = 0;
    final api = _api(
      captured: captured,
      client: MockClient((_) async {
        requests++;
        return http.Response('{"error": "blocked"}', 403);
      }),
    );
    await expectLater(api.getUserInfo(), throwsA(_is403()));
    Object? cooldownError;
    try {
      await api.getUserInfo();
    } catch (e) {
      cooldownError = e;
    }
    expect(cooldownError, isA<MediaServerHttpException>());
    expect((cooldownError as MediaServerHttpException).statusCode, 403);
    expect(cooldownError.message, contains('cooldown'));
    expect(requests, 1);
    expect(captured, hasLength(1));
  });
}
