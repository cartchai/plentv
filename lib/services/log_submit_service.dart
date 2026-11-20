import 'dart:convert';

import '../connection/connection.dart';
import '../connection/connection_registry.dart';
import '../database/app_database.dart';
import '../exceptions/media_server_exceptions.dart';
import '../profiles/profile_connection_registry.dart';
import '../profiles/profile_registry.dart';
import '../utils/log_redaction_manager.dart';
import '../utils/media_server_http_client.dart';

// 1.2.22 §66 (U1): the debug-log submit no longer posts to the upstream
// Plezy relay. It posts the log — redacted on-device first — to OUR
// Cloudflare Worker, which files it as a GitHub issue on our repo
// (cartchai/plentv) with a fine-grained PAT stored server-side. The app
// never talks to GitHub directly and no token ships in the app binary.
//
// WORKER CONTRACT (the parent deploys the Worker; the app side is this file):
//   POST {title: string, body: string} as JSON to the endpoint below.
//   The Worker files the issue and answers 201 with
//   {issueUrl: string, issueNumber: number}
//   (`html_url` / `number` are accepted as fallbacks).
//   The Worker enforces the GitHub 64 KiB body cap defensively and should
//   rate-limit the endpoint — it is public, and anyone who finds the URL
//   can file issues on the repo (the PAT is issues:write on one repo only,
//   so that is the whole blast radius).
//
// SETUP (parent): deploy the Worker, create the fine-grained PAT
// (issues:write on cartchai/plentv only, stored as a Worker secret —
// never in the app or the repo), and set the GitHub repo VARIABLE
// PLENTV_LOG_WORKER_URL to the Worker URL. CI passes it in as
// --dart-define=PLENTV_LOG_SUBMIT_URL=... (see
// .github/workflows/android-release.yml). Until the variable is set the
// endpoint is empty and the submit button explains that log submit is
// not set up in this build — nothing is posted anywhere in that state,
// and local save/copy always work.

/// Our log-submit Worker URL, injected at build time. Empty when not
/// configured (e.g. a local dev build) — see [canSubmitLogs].
const String logSubmitEndpoint = String.fromEnvironment('PLENTV_LOG_SUBMIT_URL', defaultValue: '');

/// True when a submit endpoint is configured in this build.
bool get canSubmitLogs => logSubmitEndpoint.isNotEmpty;

/// GitHub rejects issue bodies over 65,536 characters. The byte budget
/// stays below that with room for the fence and footer (UTF-8 bytes are
/// always >= characters, so a byte budget is conservative in characters).
const int maxLogSubmitBytes = 60 * 1024;

/// The created issue, as returned by the Worker.
class SubmittedLogIssue {
  const SubmittedLogIssue({required this.url, this.number});

  /// Web URL of the issue (what the user is shown and can copy).
  final String url;

  /// Issue number, when the Worker returns one.
  final int? number;
}

/// Submits a redacted diagnostic log to our Worker, which files it as a
/// GitHub issue on our repo. Returns the created issue.
///
/// [logText] is the full formatted log (device header + log lines). It is
/// redacted on-device by [redactDiagnosticLogForSubmit] and trimmed to
/// [maxLogSubmitBytes] before anything leaves the device — the Worker
/// receives nothing unredacted.
///
/// Throws [StateError] when no endpoint is configured in this build or
/// when the Worker answers with a non-2xx status or no issue link.
/// [endpointOverride] exists for tests (and for the Logs screen's seam);
/// production callers pass nothing and use [logSubmitEndpoint].
Future<SubmittedLogIssue> submitDiagnosticLog({
  required String title,
  required String logText,
  Iterable<String> sensitiveValues = const [],
  MediaServerHttpClient? client,
  String? endpointOverride,
}) async {
  final endpoint = endpointOverride ?? logSubmitEndpoint;
  if (endpoint.isEmpty) {
    throw StateError('Log submit is not configured in this build.');
  }
  final redacted = redactDiagnosticLogForSubmit(logText, extraSensitiveValues: sensitiveValues);
  final body = buildLogSubmitBody(redacted);
  // The client throws MediaServerHttpException when the answer body
  // cannot be decoded (e.g. a Cloudflare HTML error page) — fold that
  // into the same StateError the status check below throws, so callers
  // only ever see one failure type from this function.
  late final MediaServerResponse response;
  try {
    response = await (client ?? httpClient).post(
      endpoint,
      body: jsonEncode({'title': title, 'body': body}),
      headers: {'Content-Type': 'application/json'},
    );
  } on MediaServerHttpException catch (e) {
    throw StateError('Log submit failed: ${e.message}');
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw StateError('Log submit failed: HTTP ${response.statusCode}');
  }
  final data = response.data;
  final Map<String, dynamic>? map = data is Map<String, dynamic>
      ? data
      : data is String
      ? jsonDecode(data) as Map<String, dynamic>?
      : null;
  final url = map?['issueUrl'] ?? map?['html_url'];
  if (url is! String || url.isEmpty) {
    throw StateError('Log submit succeeded but returned no issue link.');
  }
  final number = map?['issueNumber'] ?? map?['number'];
  return SubmittedLogIssue(url: url, number: number is int ? number : null);
}

/// Builds the GitHub issue body for a redacted log: the log in a code
/// fence, trimmed to [maxLogSubmitBytes], plus a one-line footer saying
/// it was redacted on-device. Pure function — unit-tested.
String buildLogSubmitBody(String redactedLog, {int maxBytes = maxLogSubmitBytes}) {
  const separator = '\n---\n';
  final splitAt = redactedLog.indexOf(separator);
  final header = splitAt < 0 ? '' : redactedLog.substring(0, splitAt + separator.length);
  final logs = splitAt < 0 ? redactedLog : redactedLog.substring(splitAt + separator.length);
  final payload = constrainDiagnosticPayload(header: header, logs: logs, maxBytes: maxBytes);
  return '```\n$payload\n```\n\n_Submitted from PlenTV. The log was redacted on this device before sending._';
}

/// Trims [logs] from the front so `header + logs` fits [maxBytes], keeping
/// the header intact and never splitting a UTF-8 sequence or a log line.
/// (Moved from the deleted log-upload service; the algorithm is unchanged —
/// the Logs screen's clipboard path uses the same helper.)
String constrainDiagnosticPayload({required String header, required String logs, int maxBytes = maxLogSubmitBytes}) {
  if (maxBytes <= 0) return '';

  final headerBytes = utf8.encode(header);
  if (headerBytes.length >= maxBytes) {
    var end = maxBytes;
    while (end > 0 && end < headerBytes.length && (headerBytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return utf8.decode(headerBytes.sublist(0, end));
  }

  final logBytes = utf8.encode(logs);
  final availableLogBytes = maxBytes - headerBytes.length;
  if (logBytes.length <= availableLogBytes) return '$header$logs';

  var start = logBytes.length - availableLogBytes;
  while (start < logBytes.length && (logBytes[start] & 0xC0) == 0x80) {
    start++;
  }
  final nextLine = logBytes.indexOf(0x0A, start);
  if (nextLine >= 0 && nextLine + 1 < logBytes.length) {
    start = nextLine + 1;
  }
  return header + utf8.decode(logBytes.sublist(start));
}

/// Public, non-identifying hosts that may survive in a submitted log.
/// Mirrors the fixed endpoints in `network_security_config.xml` /
/// `CertificateTrust.fixedEndpointDomains` — plus `workers.dev`, where our
/// own submit Worker lives. Every other host in a URL is masked: provider
/// hosts, self-hosted servers, EPG sources.
const Set<String> _submitSafeHosts = {
  'plex.tv',
  'api.github.com',
  'github.com',
  'image.tmdb.org',
  'cdn.jsdelivr.net',
  'api.mdblist.com',
  'openwatch.party',
  'www.youtube.com',
  'youtube.com',
  'dontkillmyapp.com',
  'workers.dev',
};

final _emailPattern = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');

/// `username=` / `user_name=` / `email=` query parameters. The shared
/// redaction manager covers `password=` and token fields but not
/// `username=` — the Xtream login travels as
/// `player_api.php?username=...&password=...`, so the username needs its
/// own rule here (the registry-derived literal covers the value too).
final _usernameQueryParamPattern = RegExp(
  '([?&](?:username|user_name|userName|email)=)[^&\\s"\']*',
  caseSensitive: false,
);

final _urlAuthorityPattern = RegExp(r'https?://([A-Za-z0-9._-]+)(?::\d+)?', caseSensitive: false);

/// Vault-protected values (`enc:v1:...`) must never leave the device even
/// if one ever lands in a log line.
final _vaultBlobPattern = RegExp(r'enc:v1:[A-Za-z0-9+/=_-]+');

/// Desktop home-directory paths carry the OS username
/// (`/home/<name>/`, `/Users/<name>/`, `C:\Users\<name>\`).
final _unixHomeDirPattern = RegExp(r'/(home|Users)/[^/\s\\]+');
final _windowsHomeDirPattern = RegExp(r'([A-Za-z]:\\Users\\)[^\\"\s]+', caseSensitive: false);

/// Redacts a diagnostic log for public posting. Pure function —
/// unit-tested. What is stripped, in order:
///
/// 1. [extraSensitiveValues] — known identifiers gathered from the app's
///    own state by [collectSensitiveValuesForLogSubmit]: connection
///    names, server URLs + hosts, usernames, passwords, tokens, server
///    names, Plex profile display names, profile-connection tokens.
///    Literal replacement, longest first.
/// 2. Everything [LogRedactionManager] already knows: server URLs and
///    tokens registered at connect time (Plex/Jellyfin/Seerr), IPv4
///    addresses, `*.plex.direct` server hashes, `Token="..."` headers,
///    sensitive fields (`password=`, `token=`, `Authorization: Bearer
///    ...`, ...) and URL userinfo (`user:pass@host`).
/// 3. Email addresses.
/// 4. `username=` query parameters (see [_usernameQueryParamPattern]).
/// 5. Any URL host outside [_submitSafeHosts] (provider hosts,
///    self-hosted servers, EPG sources) → `https://[REDACTED_HOST]`.
/// 6. Vault blobs (`enc:v1:...`) and desktop home-directory usernames.
///
/// Residual risk, stated plainly: a bare prose mention of an identifier
/// from a connection or profile that no longer exists in the registry
/// (so it is not in [extraSensitiveValues]) and that matches no pattern
/// above could survive — e.g. a stale log line naming a deleted server.
/// The in-memory log buffer is short-lived, so that window is small;
/// if zero risk is ever required, the submit must go to a private repo.
String redactDiagnosticLogForSubmit(String text, {Iterable<String> extraSensitiveValues = const []}) {
  var redacted = text;

  final extras = extraSensitiveValues.map((value) => value.trim()).where((value) => value.length >= 3).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final value in extras) {
    redacted = redacted.replaceAll(value, '[REDACTED]');
  }

  redacted = LogRedactionManager.redact(redacted);
  redacted = redacted.replaceAll(_emailPattern, '[REDACTED]');
  redacted = redacted.replaceAllMapped(_usernameQueryParamPattern, (match) => '${match.group(1)}[REDACTED]');
  redacted = redacted.replaceAllMapped(_urlAuthorityPattern, (match) {
    final host = match.group(1)!.toLowerCase();
    final safe = _submitSafeHosts.any((safeHost) => host == safeHost || host.endsWith('.$safeHost'));
    return safe ? match.group(0)! : 'https://[REDACTED_HOST]';
  });
  redacted = redacted.replaceAll(_vaultBlobPattern, '[REDACTED]');
  redacted = redacted.replaceAllMapped(_unixHomeDirPattern, (match) => '/${match.group(1)}/[REDACTED]');
  redacted = redacted.replaceAllMapped(_windowsHomeDirPattern, (match) => '${match.group(1)}[REDACTED]');
  return redacted;
}

/// Gathers the known identifiers in [db] that must never appear in a
/// submitted log: every connection's names, server URLs (+ hosts),
/// usernames, passwords and tokens; every profile's display name; every
/// profile connection's user token + identifier. Best-effort: a registry
/// that cannot be read contributes nothing instead of failing the
/// submit — the pattern rules in [redactDiagnosticLogForSubmit] still
/// apply. All values are synthetic-safe: callers pass the live database,
/// tests pass an in-memory one seeded with fixture values.
Future<Set<String>> collectSensitiveValuesForLogSubmit(AppDatabase db) async {
  final values = <String>{};

  void add(String? value) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.length >= 3) values.add(trimmed);
  }

  void addUrl(String? url) {
    add(url);
    add(Uri.tryParse(url ?? '')?.host);
  }

  try {
    final connections = await ConnectionRegistry(db).list();
    for (final connection in connections) {
      switch (connection) {
        case PlexAccountConnection(
          :final accountToken,
          :final clientIdentifier,
          :final accountLabel,
          :final activeProfile,
          :final servers,
        ):
          add(accountToken);
          add(clientIdentifier);
          add(accountLabel);
          add(activeProfile?.title);
          add(activeProfile?.username);
          add(activeProfile?.email);
          add(activeProfile?.friendlyName);
          add(activeProfile?.uuid);
          for (final server in servers) {
            add(server.name);
            add(server.clientIdentifier);
            add(server.accessToken);
            for (final connection in server.connections) {
              addUrl(connection.uri);
              add(connection.address);
            }
          }
        case JellyfinConnection(
          :final baseUrl,
          :final baseUrls,
          :final serverName,
          :final userName,
          :final accessToken,
        ):
          addUrl(baseUrl);
          for (final url in baseUrls) {
            addUrl(url);
          }
          add(serverName);
          add(userName);
          add(accessToken);
        case XtreamConnection(:final name, :final serverUrl, :final username, :final password):
          add(name);
          addUrl(serverUrl);
          add(username);
          add(password);
        case M3uConnection(:final name, :final playlistUrl, :final epgUrl):
          add(name);
          addUrl(playlistUrl);
          addUrl(epgUrl);
      }
    }
  } catch (_) {
    // Best effort: pattern redaction still applies.
  }
  try {
    final profiles = await ProfileRegistry(db).list();
    for (final profile in profiles) {
      add(profile.displayName);
    }
  } catch (_) {
    // Best effort: pattern redaction still applies.
  }
  try {
    final profileConnections = await ProfileConnectionRegistry(db).listAll();
    for (final profileConnection in profileConnections) {
      add(profileConnection.userToken);
      add(profileConnection.userIdentifier);
    }
  } catch (_) {
    // Best effort: pattern redaction still applies.
  }
  return values;
}
