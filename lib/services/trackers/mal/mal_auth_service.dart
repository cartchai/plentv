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
import 'mal_constants.dart';

/// MyAnimeList authentication — direct authorization-code + PKCE
/// (1.3.23, FORK §66 U2). No proxy: the device talks to MAL itself.
///
/// New sessions need our own MAL app registration (client ID baked in at
/// build time via `PLEZTV_MAL_CLIENT_ID`); until it exists, [authorize]
/// reports "not configured" instead of failing. Refreshes are direct
/// public-client calls against MAL's token endpoint, as before — but a
/// session created under the old (proxy) client ID cannot refresh under
/// ours, so those users sign in once more (see [MalConstants]).
class MalAuthService {
  /// MAL returns these for a terminally-invalid grant (revoked/expired refresh
  /// token); anything else (5xx, network) is transient and must not log out.
  static const Set<int> _permanentRefreshFailureStatuses = {400, 401, 403};

  /// True once our MAL app registration is baked into the build.
  static bool get isConfigured => MalConstants.clientId.isNotEmpty;

  final http.Client _http;

  MalAuthService({http.Client? httpClient}) : _http = httpClient ?? platform.createPlatformClient();

  void dispose() => _http.close();

  /// Starts a direct sign-in: builds the authorize URL (PKCE, `plain`
  /// challenge), hands it to [onCodeReady] for the QR/browser dialog, then
  /// waits for the code the user pastes (or the deep link delivers) and
  /// exchanges it. Returns null when the user cancels.
  Future<TrackerSession?> authorize({
    required void Function(DirectOAuthStart) onCodeReady,
    bool Function()? shouldCancel,
    Future<void>? onCancel,
  }) async {
    if (!isConfigured) {
      throw const TrackerAuthException(
        service: TrackerService.mal,
        message: 'MAL sign-in is not configured in this build (no client ID)',
        isPermanent: true,
      );
    }
    final state = generateState();
    final verifier = generateCodeVerifier();
    final start = DirectOAuthStart(
      service: TrackerService.mal,
      url: buildMalAuthorizeUrl(
        clientId: MalConstants.clientId,
        redirectUri: MalConstants.redirectUri,
        state: state,
        codeVerifier: verifier,
      ).toString(),
      redirectUri: MalConstants.redirectUri,
      state: state,
    );
    onCodeReady(start);
    final code = await waitForOAuthCode(start, shouldCancel: shouldCancel, onCancel: onCancel);
    if (code == null) return null;
    if (shouldCancel?.call() ?? false) return null;
    return exchangeCode(code: code, codeVerifier: verifier, abortTrigger: onCancel);
  }

  /// Exchanges an authorization code for a session (the second half of
  /// [authorize]; a seam so tests can drive the exchange directly).
  Future<TrackerSession> exchangeCode({
    required String code,
    required String codeVerifier,
    Future<void>? abortTrigger,
  }) async {
    final res = await sendAbortableHttpRequest(
      _http,
      'POST',
      Uri.parse(MalConstants.tokenUrl),
      body: {
        'client_id': MalConstants.clientId,
        'grant_type': 'authorization_code',
        'code': code,
        'code_verifier': codeVerifier,
      },
      timeout: TrackerConstants.authRequestTimeout,
      abortTrigger: abortTrigger,
      operation: 'MAL token exchange',
    );
    if (res.statusCode != 200) {
      // A wrong/expired code is a 400 invalid_grant — the user just signs
      // in again. Never permanent: the credentials themselves are fine.
      appLogger.w('MAL: token exchange failed (HTTP ${res.statusCode})');
      throw TrackerAuthException(
        service: TrackerService.mal,
        message: 'MAL sign-in failed: HTTP ${res.statusCode}',
        statusCode: res.statusCode,
      );
    }
    return TrackerSession.fromTokenResponse(TrackerService.mal, json.decode(res.body) as Map<String, dynamic>);
  }

  Future<TrackerSession> refresh(TrackerSession current) async {
    final res = await sendAbortableHttpRequest(
      _http,
      'POST',
      Uri.parse(MalConstants.tokenUrl),
      body: {
        'client_id': MalConstants.clientId,
        'grant_type': 'refresh_token',
        'refresh_token': current.requireRefreshToken(TrackerService.mal),
      },
      timeout: TrackerConstants.refreshTimeout,
      operation: 'MAL token refresh',
    );

    if (res.statusCode != 200) {
      appLogger.w('MAL: refresh failed (HTTP ${res.statusCode})');
      throw TrackerAuthException(
        service: TrackerService.mal,
        message: 'Refresh failed: HTTP ${res.statusCode}',
        statusCode: res.statusCode,
        isPermanent: _permanentRefreshFailureStatuses.contains(res.statusCode),
      );
    }
    final fresh = TrackerSession.fromTokenResponse(TrackerService.mal, json.decode(res.body) as Map<String, dynamic>);
    return fresh.copyWith(username: current.username);
  }
}
