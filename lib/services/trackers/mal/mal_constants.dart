/// MAL `/anime/ranking` types used by the Explore catalog rows.
enum MalRankingType {
  airing,
  bypopularity;

  String get queryValue => name;
}

/// Bundled MyAnimeList API endpoints and our own public client ID.
///
/// 1.3.23 (FORK §66 U2): sign-in is direct — the device talks to MAL
/// itself, no proxy. The client ID belongs to OUR MAL app registration,
/// baked in at build time (`--dart-define=PLEZTV_MAL_CLIENT_ID=...`);
/// empty until the registration exists, and sign-in reports "not
/// configured" until then. The redirect URI below is the exact string our
/// MAL app must have on file.
///
/// Sessions created under the old (proxy) client ID need one re-sign-in:
/// their refresh tokens were issued to the old app, and MAL will not
/// refresh them under ours.
class MalConstants {
  MalConstants._();

  static const String clientId = String.fromEnvironment('PLEZTV_MAL_CLIENT_ID', defaultValue: '');

  static const String authorizeUrl = 'https://myanimelist.net/v1/oauth2/authorize';

  /// Redirect target for the authorize flow. The app receives it as a
  /// `plezy://` deep link; on TVs the user pastes the code instead.
  static const String redirectUri = 'plezy://oauth/mal';

  static const String apiBase = 'https://api.myanimelist.net/v2';
  static const String tokenUrl = 'https://myanimelist.net/v1/oauth2/token';

  static Map<String, String> headers({String? accessToken}) => {
    'Accept': 'application/json',
    if (accessToken != null) 'Authorization': 'Bearer $accessToken',
  };
}
