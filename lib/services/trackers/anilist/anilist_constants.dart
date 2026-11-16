/// Bundled AniList API endpoint and our own app credentials.
///
/// 1.3.23 (FORK §66 U2): sign-in is a direct authorization-code grant —
/// the device talks to AniList itself, no proxy. The client ID + secret
/// belong to OUR AniList app registration, baked in at build time
/// (`--dart-define=PLEZTV_ANILIST_CLIENT_ID=...` /
/// `--dart-define=PLEZTV_ANILIST_CLIENT_SECRET=...`); empty until the
/// registration exists, and sign-in reports "not configured" until then.
/// The redirect URI below is the exact string our AniList app must have
/// on file.
///
/// The secret ships in the binary — the same threat model the codebase
/// already accepts for Trakt (see
/// `lib/services/trackers/trakt/trakt_constants.dart`). Tokens are valid
/// for 1 year and have no refresh; users re-auth on expiry.
class AnilistConstants {
  AnilistConstants._();

  static const String clientId = String.fromEnvironment('PLEZTV_ANILIST_CLIENT_ID', defaultValue: '');

  static const String clientSecret = String.fromEnvironment(
    'PLEZTV_ANILIST_CLIENT_SECRET',
    defaultValue: '',
  );

  static const String authorizeUrl = 'https://anilist.co/api/v2/oauth/authorize';
  static const String tokenUrl = 'https://anilist.co/api/v2/oauth/token';

  /// Redirect target for the authorize flow. The app receives it as a
  /// `plezy://` deep link; on TVs the user pastes the code instead.
  static const String redirectUri = 'plezy://oauth/anilist';

  static const String apiBase = 'https://graphql.anilist.co';
  static const int catalogRowCastLimit = 6;

  static Map<String, String> headers({String? accessToken}) => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    if (accessToken != null) 'Authorization': 'Bearer $accessToken',
  };
}
