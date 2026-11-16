// Direct OAuth (MAL + AniList, 1.3.23, FORK §66 U2) — failing-first.
//
// The device talks to each provider itself now; the relay is gone. These
// tests pin the authorize-URL shape (MAL PKCE `plain`, AniList grant),
// the code parsing (bare code vs full redirect link, state mismatch),
// and the token-exchange request/response handling for both services.
// Synthetic credentials only — the client IDs are empty in tests (no
// registration baked in), so the exchange tests drive `exchangeCode`
// directly with a mock HTTP client.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/trackers/anilist/anilist_auth_service.dart';
import 'package:plezy/services/trackers/anilist/anilist_constants.dart';
import 'package:plezy/services/trackers/direct_oauth_flow.dart';
import 'package:plezy/services/trackers/mal/mal_auth_service.dart';
import 'package:plezy/services/trackers/mal/mal_constants.dart';
import 'package:plezy/services/trackers/tracker_constants.dart';
import 'package:plezy/services/trackers/tracker_exceptions.dart';

void main() {
  group('authorize URLs', () {
    test('MAL uses PKCE plain with the verifier as the challenge', () {
      final url = buildMalAuthorizeUrl(
        clientId: 'test-client',
        redirectUri: 'plezy://oauth/mal',
        state: 'state-123',
        codeVerifier: 'verifier-abc',
      );
      expect(url.scheme, 'https');
      expect(url.host, 'myanimelist.net');
      expect(url.path, '/v1/oauth2/authorize');
      expect(url.queryParameters['response_type'], 'code');
      expect(url.queryParameters['client_id'], 'test-client');
      expect(url.queryParameters['code_challenge'], 'verifier-abc');
      expect(url.queryParameters['code_challenge_method'], 'plain');
      expect(url.queryParameters['redirect_uri'], 'plezy://oauth/mal');
      expect(url.queryParameters['state'], 'state-123');
    });

    test('AniList uses the authorization-code grant', () {
      final url = buildAnilistAuthorizeUrl(
        clientId: 'test-client',
        redirectUri: 'plezy://oauth/anilist',
        state: 'state-456',
      );
      expect(url.scheme, 'https');
      expect(url.host, 'anilist.co');
      expect(url.path, '/api/v2/oauth/authorize');
      expect(url.queryParameters['response_type'], 'code');
      expect(url.queryParameters['client_id'], 'test-client');
      expect(url.queryParameters['redirect_uri'], 'plezy://oauth/anilist');
      expect(url.queryParameters['state'], 'state-456');
      expect(url.queryParameters.containsKey('code_challenge'), isFalse);
    });

    test('redirect URIs are the plezy scheme the app receives', () {
      expect(MalConstants.redirectUri, 'plezy://oauth/mal');
      expect(AnilistConstants.redirectUri, 'plezy://oauth/anilist');
    });
  });

  group('PKCE verifier and state', () {
    test('verifier is 64 unreserved chars and differs every time', () {
      final a = generateCodeVerifier();
      final b = generateCodeVerifier();
      expect(a.length, 64);
      expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(a), isTrue);
      expect(a, isNot(b));
    });

    test('state is 32 hex chars and differs every time', () {
      final a = generateState();
      final b = generateState();
      expect(a.length, 32);
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(a), isTrue);
      expect(a, isNot(b));
    });
  });

  group('parseOAuthReturn', () {
    test('bare code is accepted without state verification', () {
      final parsed = parseOAuthReturn('AbC123xYz-._~99', expectedState: 'state-1');
      expect(parsed, isNotNull);
      expect(parsed!.code, 'AbC123xYz-._~99');
      expect(parsed.stateVerified, isFalse);
    });

    test('full plezy redirect link with matching state is accepted', () {
      final parsed = parseOAuthReturn(
        'plezy://oauth/mal?code=CODE12345&state=state-1',
        expectedState: 'state-1',
      );
      expect(parsed, isNotNull);
      expect(parsed!.code, 'CODE12345');
      expect(parsed.stateVerified, isTrue);
    });

    test('state mismatch is rejected', () {
      expect(
        parseOAuthReturn('plezy://oauth/mal?code=CODE12345&state=other', expectedState: 'state-1'),
        isNull,
      );
    });

    test('full https redirect link is accepted', () {
      final parsed = parseOAuthReturn(
        'https://example.invalid/callback?code=CODE67890&state=state-1',
        expectedState: 'state-1',
      );
      expect(parsed, isNotNull);
      expect(parsed!.code, 'CODE67890');
    });

    test('garbage, empty and too-short values are rejected', () {
      expect(parseOAuthReturn('', expectedState: 'state-1'), isNull);
      expect(parseOAuthReturn('   ', expectedState: 'state-1'), isNull);
      expect(parseOAuthReturn('short', expectedState: 'state-1'), isNull);
      expect(parseOAuthReturn('not a code!', expectedState: 'state-1'), isNull);
      expect(parseOAuthReturn('https://example.invalid/callback', expectedState: 'state-1'), isNull);
    });
  });

  group('DirectOAuthStart', () {
    DirectOAuthStart start() => DirectOAuthStart(
      service: TrackerService.mal,
      url: 'https://myanimelist.net/v1/oauth2/authorize?client_id=x',
      redirectUri: 'plezy://oauth/mal',
      state: 'state-1',
    );

    test('submitCode completes the wait once, then refuses', () async {
      final s = start();
      expect(s.submitCode('CODE12345'), isTrue);
      expect(s.codeSubmitted, isTrue);
      expect(await s.codeFuture, 'CODE12345');
      expect(s.submitCode('OTHERCODE'), isFalse);
    });

    test('submitCode rejects a state-mismatched link and keeps waiting', () {
      final s = start();
      expect(s.submitCode('plezy://oauth/mal?code=CODE12345&state=nope'), isFalse);
      expect(s.codeSubmitted, isFalse);
      expect(s.submitCode('CODE12345'), isTrue);
    });

    test('cancel completes the wait with null', () async {
      final s = start();
      s.cancel();
      expect(await s.codeFuture, isNull);
    });
  });

  group('waitForOAuthCode', () {
    test('returns the submitted code', () async {
      final s = DirectOAuthStart(
        service: TrackerService.anilist,
        url: 'https://anilist.co/api/v2/oauth/authorize?client_id=x',
        redirectUri: 'plezy://oauth/anilist',
        state: 'state-9',
      );
      final waiting = waitForOAuthCode(s);
      expect(s.submitCode('ANILISTCODE1'), isTrue);
      expect(await waiting, 'ANILISTCODE1');
    });

    test('returns null when the cancel future completes first', () async {
      final s = DirectOAuthStart(
        service: TrackerService.mal,
        url: 'https://example.invalid/auth',
        redirectUri: 'plezy://oauth/mal',
        state: 'state-9',
      );
      final cancel = Completer<void>();
      final waiting = waitForOAuthCode(s, onCancel: cancel.future);
      cancel.complete();
      expect(await waiting, isNull);
    });
  });

  group('token exchange', () {
    test('MAL exchange posts the code + verifier and builds the session', () async {
      Map<String, String>? seenBody;
      final service = MalAuthService(
        httpClient: MockClient((request) async {
          seenBody = request.bodyFields;
          return http.Response(
            json.encode({
              'access_token': 'mal-access',
              'refresh_token': 'mal-refresh',
              'expires_in': 3600,
              'token_type': 'Bearer',
            }),
            200,
          );
        }),
      );
      addTearDown(service.dispose);

      final session = await service.exchangeCode(code: 'auth-code-1', codeVerifier: 'verifier-1');
      expect(seenBody?['grant_type'], 'authorization_code');
      expect(seenBody?['code'], 'auth-code-1');
      expect(seenBody?['code_verifier'], 'verifier-1');
      expect(seenBody?.containsKey('client_id'), isTrue);
      expect(session.accessToken, 'mal-access');
      expect(session.refreshToken, 'mal-refresh');
      expect(session.expiresAt, isNotNull);
    });

    test('MAL exchange failure is a plain status error, never permanent', () async {
      final service = MalAuthService(
        httpClient: MockClient((_) async => http.Response('{"error":"invalid_grant"}', 400)),
      );
      addTearDown(service.dispose);

      TrackerAuthException? thrown;
      try {
        await service.exchangeCode(code: 'stale-code', codeVerifier: 'verifier-1');
      } on TrackerAuthException catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.service, TrackerService.mal);
      expect(thrown.statusCode, 400);
      expect(thrown.isPermanent, isFalse);
      expect(thrown.message, contains('HTTP 400'));
    });

    test('AniList exchange posts the secret and builds a refresh-less session', () async {
      Map<String, String>? seenBody;
      final service = AnilistAuthService(
        httpClient: MockClient((request) async {
          seenBody = request.bodyFields;
          return http.Response(
            json.encode({'access_token': 'anilist-access', 'token_type': 'Bearer', 'expires_in': 31536000}),
            200,
          );
        }),
      );
      addTearDown(service.dispose);

      final session = await service.exchangeCode(code: 'auth-code-2');
      expect(seenBody?['grant_type'], 'authorization_code');
      expect(seenBody?['code'], 'auth-code-2');
      expect(seenBody?.containsKey('client_id'), isTrue);
      expect(seenBody?.containsKey('client_secret'), isTrue);
      expect(seenBody?['redirect_uri'], 'plezy://oauth/anilist');
      expect(session.accessToken, 'anilist-access');
      expect(session.refreshToken, isNull);
      expect(session.expiresAt, isNotNull);
    });

    test('AniList exchange failure is a plain status error', () async {
      final service = AnilistAuthService(
        httpClient: MockClient((_) async => http.Response('{"error":"invalid_grant"}', 400)),
      );
      addTearDown(service.dispose);

      await expectLater(
        service.exchangeCode(code: 'stale-code'),
        throwsA(
          isA<TrackerAuthException>()
              .having((e) => e.service, 'service', TrackerService.anilist)
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.isPermanent, 'isPermanent', false),
        ),
      );
    });

    test('authorize reports not-configured while the registrations are missing', () async {
      // No PLEZTV_MAL_CLIENT_ID / PLEZTV_ANILIST_* dart-define in tests.
      expect(MalAuthService.isConfigured, isFalse);
      expect(AnilistAuthService.isConfigured, isFalse);
      final mal = MalAuthService();
      addTearDown(mal.dispose);
      final anilist = AnilistAuthService();
      addTearDown(anilist.dispose);
      await expectLater(
        mal.authorize(onCodeReady: (_) => fail('must not build a URL')),
        throwsA(
          isA<TrackerAuthException>().having((e) => e.isPermanent, 'isPermanent', true),
        ),
      );
      await expectLater(
        anilist.authorize(onCodeReady: (_) => fail('must not build a URL')),
        throwsA(
          isA<TrackerAuthException>().having((e) => e.isPermanent, 'isPermanent', true),
        ),
      );
    });
  });
}
