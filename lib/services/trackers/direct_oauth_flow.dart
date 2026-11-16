import 'dart:async';
import 'dart:math';

import 'tracker_constants.dart';

/// Direct (no-proxy) OAuth authorization-code flow for MAL + AniList
/// (1.3.23, FORK §66 U2).
///
/// The old flow ran through the app maker's relay (`/auth`): the device
/// asked the relay for a QR URL and long-polled it for tokens. The relay is
/// gone — the device now talks to each provider itself:
///
/// * MAL: authorization-code + PKCE (`code_challenge_method=plain` only),
///   public client, no secret. Refresh stays direct, as before.
/// * AniList: authorization-code grant, client secret bundled in the app —
///   the same threat model the codebase already accepts for Trakt
///   (`lib/services/trackers/trakt/trakt_constants.dart`).
///
/// The code reaches the device one of two ways, and the dialog supports
/// both: a `plezy://oauth/<service>?code=...&state=...` deep link (the
/// browser redirects back into the app on phones/desktops), or the user
/// pasting the code — or the whole redirect link — into the dialog's code
/// box (the TV path, where there is no browser to redirect from).
class DirectOAuthStart {
  DirectOAuthStart({
    required this.service,
    required this.url,
    required this.redirectUri,
    required this.state,
  });

  /// Which tracker this sign-in is for.
  final TrackerService service;

  /// Authorize URL: encoded in the QR code, opened by the browser button.
  final String url;

  /// Exact redirect URI the provider sends the code to. This string must
  /// match what our MAL / AniList app registration has on file, or the
  /// provider refuses the authorize request.
  final String redirectUri;

  /// Random per-attempt value, echoed back by the provider. A returned
  /// state that does not match is rejected (see [submitCode]).
  final String state;

  final Completer<String?> _code = Completer<String?>();

  /// Completes with the authorization code (or null when cancelled).
  Future<String?> get codeFuture => _code.future;

  /// True once a code was accepted (or the wait was cancelled).
  bool get codeSubmitted => _code.isCompleted;

  /// Accepts a bare authorization code, or the full redirect link
  /// (`plezy://oauth/<service>?code=...&state=...`) pasted in whole.
  /// Returns true when the code was accepted. A value that does not parse,
  /// or a link whose state does not match this attempt's, returns false
  /// and leaves the wait running so the user can try again.
  bool submitCode(String raw) {
    if (_code.isCompleted) return false;
    final parsed = parseOAuthReturn(raw, expectedState: state);
    if (parsed == null) return false;
    _code.complete(parsed.code);
    return true;
  }

  /// Abandons the wait (Cancel). The authorize call returns null.
  void cancel() {
    if (!_code.isCompleted) _code.complete(null);
  }
}

/// Waits for the authorization code, or null when the user cancels
/// ([shouldCancel] flips true, or [onCancel] completes first).
Future<String?> waitForOAuthCode(
  DirectOAuthStart start, {
  bool Function()? shouldCancel,
  Future<void>? onCancel,
}) async {
  if (shouldCancel?.call() ?? false) return null;
  final cancelSentinel = Object();
  final cancelFuture = onCancel?.then((_) => cancelSentinel);
  final raced = await Future.any<Object?>([start.codeFuture, ?cancelFuture]);
  if (identical(raced, cancelSentinel)) return null;
  return raced as String?;
}

/// Parses what the user pasted (or what the deep link delivered) into an
/// authorization code. Returns null when the value does not parse, or when
/// a link carries a state that does not match [expectedState] — a code
/// from another attempt must never be exchanged here.
///
/// A bare code carries no state, so it cannot be verified that way; it is
/// accepted on its shape alone and the provider rejects it at exchange
/// time if it belongs to another attempt.
({String code, bool stateVerified})? parseOAuthReturn(
  String raw, {
  required String expectedState,
}) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final uri = Uri.tryParse(text);
  if (uri != null &&
      (uri.scheme == 'plezy' || uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.queryParameters.containsKey('code')) {
    final code = uri.queryParameters['code']!;
    final state = uri.queryParameters['state'];
    if (state != null && state != expectedState) return null;
    if (!_looksLikeCode(code)) return null;
    return (code: code, stateVerified: state != null);
  }
  if (!_looksLikeCode(text)) return null;
  return (code: text, stateVerified: false);
}

bool _looksLikeCode(String value) =>
    value.length >= 8 &&
    value.length <= 512 &&
    RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(value);

/// PKCE code verifier for MAL (43–128 chars from the unreserved set).
/// MAL only supports `code_challenge_method=plain`, so the challenge sent
/// in the authorize URL is the verifier itself.
String generateCodeVerifier() {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  final random = Random.secure();
  return List.generate(64, (_) => chars[random.nextInt(chars.length)]).join();
}

/// Random per-attempt state (32 hex chars).
String generateState() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// MAL authorize URL (authorization-code + PKCE, `plain` challenge).
Uri buildMalAuthorizeUrl({
  required String clientId,
  required String redirectUri,
  required String state,
  required String codeVerifier,
}) => Uri.https('myanimelist.net', '/v1/oauth2/authorize', {
  'response_type': 'code',
  'client_id': clientId,
  'code_challenge': codeVerifier,
  'code_challenge_method': 'plain',
  'redirect_uri': redirectUri,
  'state': state,
});

/// AniList authorize URL (authorization-code grant).
Uri buildAnilistAuthorizeUrl({
  required String clientId,
  required String redirectUri,
  required String state,
}) => Uri.https('anilist.co', '/api/v2/oauth/authorize', {
  'client_id': clientId,
  'redirect_uri': redirectUri,
  'response_type': 'code',
  'state': state,
});
