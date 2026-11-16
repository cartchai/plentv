import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../utils/abortable_http_request.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/platform_http_client_stub.dart'
    if (dart.library.io) '../../../utils/platform_http_client_io.dart'
    as platform;
import '../direct_oauth_flow.dart';
import '../tracker_constants.dart';
import '../tracker_exceptions.dart';
import '../tracker_session.dart';
import 'anilist_constants.dart';

/// AniList authentication — direct authorization-code grant
/// (1.3.23, FORK §66 U2). No proxy: the device talks to AniList itself.
///
/// New sessions need our own AniList app registration (client ID + secret
/// baked in at build time via `PLEZTV_ANILIST_CLIENT_ID` /
/// `PLEZTV_ANILIST_CLIENT_SECRET`); until they exist, [authorize] reports
/// "not configured" instead of failing. Tokens are valid for 1 year and
/// have no refresh; users re-auth on expiry.
class AnilistAuthService {
  /// True once our AniList app registration is baked into the build.
  static bool get isConfigured =>
      AnilistConstants.clientId.isNotEmpty && AnilistConstants.clientSecret.isNotEmpty;

  final http.Client _http;

  AnilistAuthService({http.Client? httpClient}) : _http = httpClient ?? platform.createPlatformClient();

  void dispose() => _http.close();

  /// Starts a direct sign-in: builds the authorize URL, hands it to
  /// [onCodeReady] for the QR/browser dialog, then waits for the code the
  /// user pastes (or the deep link delivers) and exchanges it with our
  /// client secret. Returns null when the user cancels.
  Future<TrackerSession?> authorize({
    required void Function(DirectOAuthStart) onCodeReady,
    bool Function()? shouldCancel,
    Future<void>? onCancel,
  }) async {
    if (!isConfigured) {
      throw const TrackerAuthException(
        service: TrackerService.anilist,
        message: 'AniList sign-in is not configured in this build (no client ID/secret)',
        isPermanent: true,
      );
    }
    final state = generateState();
    final start = DirectOAuthStart(
      service: TrackerService.anilist,
      url: buildAnilistAuthorizeUrl(
        clientId: AnilistConstants.clientId,
        redirectUri: AnilistConstants.redirectUri,
        state: state,
      ).toString(),
      redirectUri: AnilistConstants.redirectUri,
      state: state,
    );
    onCodeReady(start);
    final code = await waitForOAuthCode(start, shouldCancel: shouldCancel, onCancel: onCancel);
    if (code == null) return null;
    if (shouldCancel?.call() ?? false) return null;
    return exchangeCode(code: code, abortTrigger: onCancel);
  }

  /// Exchanges an authorization code for a session (the second half of
  /// [authorize]; a seam so tests can drive the exchange directly).
  Future<TrackerSession> exchangeCode({required String code, Future<void>? abortTrigger}) async {
    final res = await sendAbortableHttpRequest(
      _http,
      'POST',
      Uri.parse(AnilistConstants.tokenUrl),
      body: {
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': AnilistConstants.clientId,
        'client_secret': AnilistConstants.clientSecret,
        'redirect_uri': AnilistConstants.redirectUri,
      },
      timeout: TrackerConstants.authRequestTimeout,
      abortTrigger: abortTrigger,
      operation: 'AniList token exchange',
    );
    if (res.statusCode != 200) {
      // A wrong/expired code is a 400 — the user just signs in again.
      // Never permanent: the credentials themselves are fine.
      appLogger.w('AniList: token exchange failed (HTTP ${res.statusCode})');
      throw TrackerAuthException(
        service: TrackerService.anilist,
        message: 'AniList sign-in failed: HTTP ${res.statusCode}',
        statusCode: res.statusCode,
      );
    }
    return TrackerSession.fromTokenResponse(
      TrackerService.anilist,
      json.decode(res.body) as Map<String, dynamic>,
    );
  }
}
