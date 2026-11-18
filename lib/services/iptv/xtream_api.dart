import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../exceptions/media_server_exceptions.dart';
import '../../utils/app_logger.dart';
import '../../utils/iptv_initials.dart';
import '../../utils/json_utils.dart';
import '../../utils/media_server_timeouts.dart';
import 'iptv_refusal_log.dart';
import 'iptv_streaming_json.dart';

/// The User-Agent values the Xtream panel sees (build #20).
///
/// Trex returns HTTP 403 to PlezTV's requests while TiviMate works with the
/// same account on the same phone: the app sent no User-Agent, so the panel
/// saw Dart's default `Dart/3.13 (dart:io)` — a distinctive, non-player
/// signature. Xtream panels enforce per-user allowed-UA lists and global
/// blocked-UA patterns as a first-class feature (USER_AGENT_BAN / EMPTY_UA),
/// and `VLC` is the most widely reported accepted value for 403s. The value
/// is a setting (Settings → IPTV → Xtream User-Agent), stored as a choice
/// key + custom text in SettingsService and resolved here so every caller
/// (client, sign-in probe, tests) agrees on the wire value.
class XtreamUserAgent {
  /// The default: the most widely reported accepted value for 403s.
  static const String vlc = 'VLC';

  /// Second most reported fallback.
  static const String smarters = 'IPTVSmartersPro';

  /// Full browser UA, the third documented fallback.
  static const String browser = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)';

  /// Stored choice keys for the Settings preference.
  static const String choiceVlc = 'vlc';
  static const String choiceSmarters = 'smarters';
  static const String choiceBrowser = 'browser';
  static const String choiceCustom = 'custom';

  static const String defaultChoice = choiceVlc;

  /// Resolve a stored choice + custom text to the UA string sent on the
  /// wire. Unknown choices and a blank custom value fall back to VLC —
  /// a request must never go out with no User-Agent again.
  static String resolve(String choice, String custom) => switch (choice) {
    choiceSmarters => smarters,
    choiceBrowser => browser,
    choiceCustom => custom.trim().isEmpty ? vlc : custom.trim(),
    _ => vlc,
  };
}

/// Thrown when an unfiltered catalog response exceeds the 300 MB cap
/// (build #23, [XtreamApi.maxCatalogResponseChars]). The sync reports
/// it as 'oversize' and keeps the old index rows — a bad sync never
/// wipes good data.
class XtreamCatalogTooLargeException implements Exception {
  const XtreamCatalogTooLargeException(this.chars);

  final int chars;

  @override
  String toString() => 'Xtream catalog response too large: $chars chars';
}
/// Which catalog rows are visible (1.2.4, catalog memory): the hidden
/// sets from the connection, plus the category-id -> initial map derived
/// from the category names. Plain values only, so it crosses into a
/// [compute] isolate like [IndexWriteParams]. The rule is the same one
/// the read-time filter applies — a row is hidden by its own category
/// id, or because its category's initial is turned off — so the
/// in-isolate filter and the read-time filter can never disagree about
/// a row. A category with no initial is absent from the map: a row in
/// one is hidden only by its own id switch.
class VisibleCatalogFilter {
  const VisibleCatalogFilter({
    required this.hiddenCategoryIds,
    required this.hiddenInitials,
    required this.initialByCategoryId,
  });

  /// Per-category ids turned off (usually empty — the owner hides initials).
  final List<String> hiddenCategoryIds;

  /// Category initials turned off (the owner hides 32).
  final List<String> hiddenInitials;

  /// categoryId -> initial, derived from the category names.
  final Map<String, String> initialByCategoryId;

  /// Build from the category list (sync path: the just-fetched list).
  factory VisibleCatalogFilter.fromCategories(
    List<XtreamCategory> categories, {
    required Set<String> hiddenCategoryIds,
    required Set<String> hiddenInitials,
  }) {
    final byId = <String, String>{};
    for (final category in categories) {
      final initial = categoryInitial(category.name);
      if (initial != null) byId[category.id] = initial;
    }
    return VisibleCatalogFilter(
      hiddenCategoryIds: hiddenCategoryIds.toList(),
      hiddenInitials: hiddenInitials.toList(),
      initialByCategoryId: byId,
    );
  }

  /// Build from an id -> name map (disk path: the cached category names).
  factory VisibleCatalogFilter.fromCategoryNames(
    Map<String, String> names, {
    required Set<String> hiddenCategoryIds,
    required Set<String> hiddenInitials,
  }) {
    final byId = <String, String>{};
    for (final entry in names.entries) {
      final initial = categoryInitial(entry.value);
      if (initial != null) byId[entry.key] = initial;
    }
    return VisibleCatalogFilter(
      hiddenCategoryIds: hiddenCategoryIds.toList(),
      hiddenInitials: hiddenInitials.toList(),
      initialByCategoryId: byId,
    );
  }

  bool isHidden(String? categoryId) {
    if (categoryId != null && hiddenCategoryIds.contains(categoryId)) return true;
    final initial = categoryId == null ? null : initialByCategoryId[categoryId];
    return initial != null && hiddenInitials.contains(initial);
  }

  /// True when nothing is hidden: the visible body IS the raw body, so a
  /// disk write must not pay the isolate round trip (sending a ~40MB
  /// body across the port blocks the main isolate ~300ms at Trex scale
  /// — the build #13 bench caught it). Write the raw body straight.
  bool get isNoOp => hiddenCategoryIds.isEmpty && hiddenInitials.isEmpty;
}


/// One XMLTV feed fetch: the response body as a byte stream plus the
/// conditional-fetch outcome (1.2.2 I9). [notModified] means the server
/// answered 304 to the validators sent — there is no body to download and
/// nothing to re-parse; the caller reuses the guide it already has.
/// [etag]/[lastModified] are the response's validators (from a 200 or a
/// 304), to send back as If-None-Match / If-Modified-Since on the next
/// refresh; both are null when the server sends none, and the next fetch
/// is then unconditional, exactly as before. Whether the panel honours
/// conditional fetch is UNPROVEN — a dynamically generated xmltv.php
/// likely sends no validators at all, in which case this is a no-op and
/// the feed downloads in full every time (the old behaviour).
typedef XmltvFeedFetch = ({
  Stream<List<int>> bytes,
  bool notModified,
  String? etag,
  String? lastModified,
});

/// One XMLTV feed download straight to a file (1.2.19, L-3):
/// [bytesDownloaded] is the total bytes now held in the file (resumed
/// prefix + newly downloaded bytes); [resumedFromBytes] is how many of
/// those came from a previous partial download (0 on a fresh download);
/// [totalBytes] is the feed's full size when the server declares it
/// (Content-Range total on a 206, Content-Length on a 200), else null;
/// [sha256] is the hex SHA-256 of exactly the bytes in the file.
/// [notModified] is always false here — a resumed download sends no
/// validators, so there is no 304 to report.
typedef XmltvFeedDownload = ({
  bool notModified,
  bool resumed,
  int resumedFromBytes,
  int bytesDownloaded,
  int? totalBytes,
  String? sha256,
  String? etag,
  String? lastModified,
});

/// Minimal Xtream Codes API client (player_api.php / get.php / xmltv.php).
///
/// Xtream has no canonical spec; the shapes below are the ones this
/// provider (and the common Xtream UI panel) actually returns. Numbers
/// frequently arrive as strings, so every numeric field is read through
/// [flexibleInt]/[flexibleDouble].
///
/// Credentials travel in the query string (that is how player_api.php
/// authenticates). They are never logged: request URIs are never passed to
/// [appLogger] and no field of this class is persisted.
class XtreamApi {
  final String serverUrl;
  final String username;
  final String password;
  final http.Client _http;

  /// The default User-Agent sent on every request (build #20).
  static const String defaultUserAgent = XtreamUserAgent.vlc;

  /// Hostile-response cap (build #23, IPTVMac SyncService shape): an
  /// unfiltered catalog response larger than this is refused before
  /// parsing ([XtreamCatalogTooLargeException]), so a bad sync can't
  /// blow up storage. Counted in UTF-16 code units (≈ bytes for JSON,
  /// which is mostly ASCII).
  static const int maxCatalogResponseChars = 300000000;

  /// Fixed User-Agent for this client, when one is given.
  final String? _userAgent;

  /// Provider for the User-Agent, re-read on every request when given —
  /// the Settings-backed one in IptvClient reads the preference per
  /// request, so changing Settings → IPTV → Xtream User-Agent applies to
  /// the next request without rebuilding the client. Wins over [_userAgent].
  final String Function()? _userAgentProvider;

  /// The refusal recorder (build #27): called with a sanitized entry for
  /// every refused response and transport failure, before the throw.
  /// Null in tests and for callers that do not record.
  final Future<void> Function(IptvRefusalEntry entry)? _onRefusal;

  /// 1.4.3 C3 (403 circuit breaker): answers whether a 403 for this
  /// connection was recorded recently — the log-derived half of the
  /// breaker, provided by the client (which reads the refusal log).
  /// Null means no log to consult (sign-in probe, tests without a log)
  /// — the breaker then runs on the in-memory flag alone (fail-open).
  final Future<bool> Function()? _recent403Provider;

  /// How long after a 403 the breaker stays open (1.4.3 C3): mirrors the
  /// 5-minute refusal backoff and the 5-minute xmltv negative cache, so
  /// every "don't re-ask yet" window in the app agrees. Test-overridable
  /// (assign a shorter value in tests — restore it after).
  static Duration breakerCooldown = const Duration(minutes: 5);

  /// When this client last saw a 403, set synchronously the moment the
  /// refusal is recorded (1.4.3 C3) — the log write behind [_onRefusal]
  /// is queued and can take up to ~500 ms (network-type probe), so a
  /// burst fired in that window would otherwise slip through. The
  /// log-derived provider covers restarts and other instances; this flag
  /// covers the same-instance race. Cleared by [clearBreaker].
  DateTime? _breakerOpenedAt;

  /// True when the 403 circuit breaker is open for this client (1.4.3
  /// C3): a 403 seen in-memory within [breakerCooldown], or the
  /// log-derived provider says a recent 403 exists. Fail-open: no
  /// provider, or a provider that throws, means "not open" — a broken
  /// diagnostic must never take the server offline.
  Future<bool> get isIn403Cooldown async {
    final openedAt = _breakerOpenedAt;
    if (openedAt != null && DateTime.now().difference(openedAt) < breakerCooldown) return true;
    final provider = _recent403Provider;
    if (provider == null) return false;
    try {
      return await provider();
    } catch (_) {
      return false;
    }
  }

  /// Manually clear the breaker (1.4.3 C3): the refusals screen Clear
  /// and the Settings manual Retry call this (via the client) so a
  /// deliberate retry re-fires once instead of waiting out the window.
  /// Only clears this instance's in-memory flag; the log-derived half
  /// is cleared by the client's own manual-clear timestamp.
  void clearBreaker() {
    _breakerOpenedAt = null;
  }

  /// Throw the cooldown 403 when the breaker is open (1.4.3 C3): no
  /// panel call is made and no refusal is recorded — the panel already
  /// refused, and re-firing during a block can reset or extend it.
  /// Callers see an ordinary 403 and serve cache / the refused state,
  /// exactly as for a live 403.
  Future<void> _throwIfBreakerOpen(Uri uri) async {
    if (await isIn403Cooldown) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'Xtream access denied (403 cooldown, no request sent)',
        statusCode: 403,
        requestUri: uri,
      );
    }
  }

  /// The connection this client serves, for the recorded entry ('' when
  /// the client is a pre-connection probe — the sign-in screen).
  final String _connectionId;
  final String _connectionName;

  XtreamApi({
    required String serverUrl,
    required this.username,
    required this.password,
    http.Client? httpClient,
    this._userAgent,
    this._userAgentProvider,
    this._onRefusal,
    this._recent403Provider,
    this._connectionId = '',
    this._connectionName = '',
  }) : serverUrl = serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl,
       _http = httpClient ?? http.Client();

  /// The User-Agent for the next request: provider, then fixed value,
  /// then the VLC default. Never null, never empty.
  String get _effectiveUserAgent => _userAgentProvider?.call() ?? _userAgent ?? defaultUserAgent;

  /// The User-Agent the next request will carry (1.2.15 R4): the feed
  /// download diagnostics record it, so a panel that answers differently
  /// per client can be spotted from the Reload report.
  String get effectiveUserAgent => _effectiveUserAgent;

  void close() => _http.close();

  /// Raw response body of the most recent UNFILTERED catalog call, per
  /// dataset (build #13). The client caches this body verbatim on disk —
  /// it is exactly what the panel sent, so the disk cache re-parses
  /// through the same parsers — instead of re-encoding the parsed rows
  /// back to JSON on the UI isolate (jsonEncode of 199k VOD rows froze
  /// the UI for ~1.3s on first launch; benchmark
  /// `iptv_build13_cache_benchmark_test.dart`). Null when the last call
  /// was per-category (a per-category body is never the full catalog),
  /// when the call failed, or when a test fake overrides the getter
  /// without setting it — the client falls back to the re-encode write
  /// then. 1.2.16: the VOD/series getters stream to a file instead
  /// (see [lastVodStreamsFilePath]) and leave these null. 1.2.19 (A1):
  /// the live getter streams to a file too, so there is no retained
  /// live body any more — the field is gone; callers read
  /// [lastLiveStreamsFilePath] instead. Read synchronously right
  /// after the awaited call returns; no other call can interleave on
  /// this isolate in between.
  String? lastVodStreamsBody;
  String? lastSeriesBody;

  /// Path of the temp file the most recent UNFILTERED catalog call
  /// streamed into (1.2.16, hub-load OOM; live joined it in 1.2.19,
  /// A1), or null when the last call was per-category, failed, or came
  /// from a test fake that does not stream. The caller owns the file:
  /// move it to the disk cache or delete it (see [deleteHubTempFile]).
  /// Read synchronously right after the awaited call returns, like
  /// [lastVodStreamsBody] — the per-category crawl below clears it, so
  /// a later read sees null. The next unfiltered call deletes the
  /// previous temp dir first, so at most one stale file lingers (a
  /// diagnostics probe that ignores the path leaves one behind in the
  /// system temp dir — the OS cleans it).
  String? lastLiveStreamsFilePath;
  String? lastVodStreamsFilePath;
  String? lastSeriesFilePath;

  Uri _playerApiUri({String? action, Map<String, String>? extra}) {
    return Uri.parse('$serverUrl/player_api.php').replace(
      queryParameters: {
        'username': username,
        'password': password,
        'action': ?action,
        ...?extra,
      },
    );
  }

  /// Fetch a response body with status checks. Shared by [_getJson] and the
  /// big catalog calls, which hand the body to an isolate for parsing
  /// instead of decoding it here (see [_parseLiveStreams] etc.).
  ///
  /// Every request carries the configured User-Agent (build #20): the panel
  /// 403s the bare Dart default, so a request must never go out without one.
  ///
  /// 1.2.19 (L-24): the timeout budget is SPLIT, like
  /// [MediaServerTimeouts]: [timeout] bounds reaching the server and
  /// receiving its response headers (connect + think time), and the body
  /// then streams with a per-chunk-gap [receiveTimeout] instead of one
  /// combined budget — a slow-but-answering server no longer fails a
  /// call merely for taking a while to deliver its body. The old single
  /// `.timeout()` over send + whole-body receipt is gone.
  Future<String> _fetchBody(
    Uri uri, {
    Duration timeout = const Duration(seconds: 30),
    Duration receiveTimeout = MediaServerTimeouts.receive,
    Future<void>? abortTrigger,
  }) async {
    // 1.4.3 C3: a recent 403 means no request at all — not even one.
    await _throwIfBreakerOpen(uri);
    http.Response response;
    try {
      // Build #21: an AbortableRequest so a search section can hard-cancel
      // its in-flight requests when its budget expires (or a new keystroke
      // cancels the search) instead of abandoning the future and leaving
      // the socket running. Identical to what BaseClient.get does under
      // the hood (send + Response.fromStream). A null trigger behaves
      // exactly like the old get() — every non-search caller passes none.
      final request = http.AbortableRequest('GET', uri, abortTrigger: abortTrigger);
      request.headers['User-Agent'] = _effectiveUserAgent;
      final streamed = await _http.send(request).timeout(timeout);
      // 1.2.19 (L-24): the body receipt gets its own budget
      // ([receiveTimeout], MediaServerTimeouts.receive = 120 s) — a slow
      // header is the send timeout's job, a slow body is this one's. A
      // TOTAL receipt budget (Future.timeout on the collection), not a
      // per-chunk-gap Stream.timeout: Stream.timeout never delivers
      // under FakeAsync (proven by probe — it stalls even after
      // elapsing past the gap, as does a StreamIterator inside an
      // async* generator), and the buffered bodies here are small, so
      // a total budget is the right shape. The large streaming paths
      // keep their per-chunk-gap Stream.timeout (see [_fetchBodyToFile]
      // and [getXmltvFeed]) — their tests run in real time.
      response = await http.Response.fromStream(streamed).timeout(receiveTimeout);
    } catch (e) {
      final mapped = MediaServerHttpException.from(e, uri: uri);
      // Build #27: a transport failure is a refusal too (timeout / socket
      // error) — but a cancellation is not: a search the user abandoned
      // says nothing about the panel and must never fill the log.
      if (!mapped.isCancellation) {
        await _recordRefusal(uri: uri, statusCode: null, failureKind: _failureKindFor(mapped.type));
      }
      throw mapped;
    }
    if (response.statusCode == 401) {
      await _recordRefusal(uri: uri, statusCode: 401, failureKind: 'http', response: response);
      throw MediaServerAuthException('Xtream authentication failed', statusCode: 401);
    }
    if (response.statusCode == 403) {
      await _recordRefusal(uri: uri, statusCode: 403, failureKind: 'http', response: response);
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'Xtream access denied',
        statusCode: 403,
        requestUri: uri,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await _recordRefusal(uri: uri, statusCode: response.statusCode, failureKind: 'http', response: response);
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'Xtream request failed with HTTP ${response.statusCode}',
        statusCode: response.statusCode,
        requestUri: uri,
      );
    }
    return response.body;
  }

  /// Stream a response body straight to a file instead of buffering it
  /// as a String (1.2.10, one-parse sync, research item #2). Same
  /// request shape as [_fetchBody] (AbortableRequest + User-Agent) and
  /// the same status checks + refusal recording — only the success path
  /// differs: chunks flow into [filePath] as they arrive, so the main
  /// isolate never holds the body. The oversize cap is enforced on the
  /// streamed BYTES (the char cap in [_fetchBody] counts UTF-16 code
  /// units, ≈ bytes for JSON, which is mostly ASCII — bytes is the
  /// conservative measure for a hostile response); on oversize the
  /// partial file is deleted and [XtreamCatalogTooLargeException] is
  /// thrown, exactly as [_fetchBody] throws it. [ignoreCatalogCap]
  /// exempts a file-streaming caller from the cap (1.3.26 §69): the
  /// M3U playlist path streams to a file and buffers nothing in
  /// memory, so the cap guards nothing there — the known-legitimate
  /// 300 MB playlist would trip it — and the streaming parser bounds
  /// memory instead. Only the M3U path passes it; the JSON catalog
  /// syncs keep the cap. The send is awaited
  /// (headers) under [timeout]; the body then streams with a
  /// per-chunk-gap timeout (the [getXmltvFeed] shape), so a tens-of-MB
  /// catalog on a slow connection is not cut off for merely being slow.
  /// Any failure (transport, abort, bad status, oversize) deletes the
  /// partial file — the caller never sees a half-written catalog — UNLESS
  /// [resume] is true (1.2.19, L-3/L-4): then a transport/abort failure
  /// KEEPS the partial file, the next call sends
  /// `Range: bytes=<already-have>-`, and a 206 continues it instead of
  /// restarting from byte 0. A 200 answer (server ignores Range) or a
  /// 416 (our partial is longer than the server's copy) restarts from
  /// byte 0 instead of failing. An oversize response still deletes the
  /// partial — a hostile body must never be resumed. [onProgress] fires
  /// after every chunk with the total bytes held (including resumed
  /// bytes) and the expected total when the server declares one.
  /// Returns the resume outcome (1.3.27 §P0-1, C2): whether the
  /// download continued from a partial, from which byte, and whether
  /// the server honoured the Range the caller sent — the M3U check
  /// logs that, so the phone log says 206 (resumed) or 200 (restarted).
  Future<({bool resumed, int resumedFromBytes, bool? serverHonouredRange})> _fetchBodyToFile(
    Uri uri,
    String filePath, {
    Duration timeout = const Duration(seconds: 120),
    Future<void>? abortTrigger,
    bool resume = false,
    bool ignoreCatalogCap = false,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    // 1.4.3 C3: a recent 403 means no request at all — not even one.
    await _throwIfBreakerOpen(uri);
    // 1.2.19 (L-4): the partial file's length is the resume point. A
    // missing file reads as 0 (fresh download); sync I/O is deliberate
    // — the hub temp-file helpers use sync I/O for the same fake-async
    // reason (see [_newHubTempFile]).
    var existingBytes = 0;
    if (resume) {
      try {
        existingBytes = File(filePath).lengthSync();
      } catch (_) {
        existingBytes = 0;
      }
      if (existingBytes < 0) existingBytes = 0;
    }
    // 1.3.27 §P0-1 (C2): whether a Range was actually sent — captured
    // before the 416-restart below can reset existingBytes to 0.
    final rangeRequested = resume && existingBytes > 0;
    Future<http.StreamedResponse> send({required int fromBytes}) async {
      final request = http.AbortableRequest('GET', uri, abortTrigger: abortTrigger);
      request.headers['User-Agent'] = _effectiveUserAgent;
      if (fromBytes > 0) request.headers['Range'] = 'bytes=$fromBytes-';
      return _http.send(request);
    }

    http.StreamedResponse streamed;
    try {
      streamed = await send(fromBytes: existingBytes).timeout(timeout);
      // 1.2.19 (L-3/L-4): a resumed request that the server cannot
      // honour restarts from byte 0 instead of failing the download.
      // 416 = our partial is longer than the server's copy; a 206
      // whose Content-Range starts anywhere but [existingBytes] is a
      // server that resumed from the wrong place. Neither is a refusal
      // — the retry below is the same request, restarted.
      if (resume && existingBytes > 0) {
        final rangeStart = _rangeStart(streamed.headers['content-range']);
        final needsRestart =
            streamed.statusCode == 416 ||
            (streamed.statusCode == 206 && rangeStart != null && rangeStart != existingBytes);
        if (needsRestart) {
          try {
            await streamed.stream.listen(null).cancel();
          } catch (_) {
            // Best-effort drain; the retry is the signal.
          }
          existingBytes = 0;
          streamed = await send(fromBytes: 0).timeout(timeout);
        }
      }
    } catch (e) {
      final mapped = MediaServerHttpException.from(e, uri: uri);
      if (!mapped.isCancellation) {
        await _recordRefusal(uri: uri, statusCode: null, failureKind: _failureKindFor(mapped.type));
      }
      throw mapped;
    }
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      // Buffer only the (small) error body for the refusal record, as
      // [getXmltvFeed] does — the success path never materialises it.
      final response = await http.Response.fromStream(streamed);
      await _recordRefusal(uri: uri, statusCode: response.statusCode, failureKind: 'http', response: response);
      if (response.statusCode == 401) {
        throw MediaServerAuthException('Xtream authentication failed', statusCode: 401);
      }
      if (response.statusCode == 403) {
        throw MediaServerHttpException(
          type: MediaServerHttpErrorType.unknown,
          message: 'Xtream access denied',
          statusCode: 403,
          requestUri: uri,
        );
      }
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'Xtream request failed with HTTP ${response.statusCode}',
        statusCode: response.statusCode,
        requestUri: uri,
      );
    }
    // 1.2.19 (L-3/L-4): append only when the server actually resumed
    // (206 from the byte we asked for). A 200 answer to a resumed
    // request is a server that ignored Range — truncate and take the
    // full body from byte 0 instead of appending it onto the partial.
    final append = resume && existingBytes > 0 && streamed.statusCode == 206;
    final sink = File(filePath).openWrite(mode: append ? FileMode.append : FileMode.write);
    var bytes = append ? existingBytes : 0;
    final totalBytes = streamed.contentLength == null
        ? null
        : (append ? existingBytes + streamed.contentLength! : streamed.contentLength);
    var failed = false;
    var keepPartialOnFailure = false;
    try {
      await for (final chunk in streamed.stream.timeout(timeout)) {
        bytes += chunk.length;
        if (!ignoreCatalogCap && bytes > maxCatalogResponseChars) {
          throw XtreamCatalogTooLargeException(bytes);
        }
        sink.add(chunk);
        onProgress?.call(bytes, totalBytes);
      }
      await sink.flush();
    } catch (e) {
      failed = true;
      // 1.2.19 (L-3/L-4): a resumed download keeps its partial file on
      // a transport/abort failure so the next attempt resumes — except
      // an oversize response, which is hostile and must never be
      // resumed. A non-resumed download deletes it, as before.
      keepPartialOnFailure = resume && e is! XtreamCatalogTooLargeException;
      final mapped = e is XtreamCatalogTooLargeException ? e : MediaServerHttpException.from(e, uri: uri);
      if (mapped is MediaServerHttpException && !mapped.isCancellation) {
        await _recordRefusal(uri: uri, statusCode: null, failureKind: _failureKindFor(mapped.type));
      }
      throw mapped;
    } finally {
      await sink.close();
      // Any failure leaves a half-written file behind: delete it, so
      // the caller never sees a partial catalog — unless this was a
      // resumed download keeping its partial for the next attempt (see
      // above). The success path returns with the file intact.
      if (failed && !keepPartialOnFailure) {
        try {
          await File(filePath).delete();
        } catch (_) {
          // Best-effort cleanup; the error already thrown is the signal.
        }
      }
    }
    // 1.3.27 §P0-1 (C2): the resume outcome — [append] is true only
    // when the server actually resumed (206 from the byte asked for);
    // a 200/416 restart leaves resumed false with the Range verdict.
    return (
      resumed: append,
      resumedFromBytes: append ? existingBytes : 0,
      serverHonouredRange: rangeRequested ? streamed.statusCode == 206 : null,
    );
  }

  /// Parse the start byte out of a `Content-Range: bytes <start>-<end>/<total>`
  /// header. Null when the header is absent or unparseable — the caller
  /// treats a missing start as "trust the 206" rather than failing a
  /// download over a header it cannot read.
  static int? _rangeStart(String? contentRange) {
    if (contentRange == null) return null;
    final match = RegExp(r'bytes (\d+)-\d+/').firstMatch(contentRange);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// Hand a refusal to the recorder (build #27), if one is attached.
  /// Record-only: the exception the caller sees is unchanged, and this
  /// never throws — a diagnostic must never break the error path it
  /// observes. The URL itself is never stored ([IptvRefusalEntry.actionForUri]
  /// derives the action without host or credentials) and the body/headers
  /// are sanitized with this client's own credentials as redaction values.
  Future<void> _recordRefusal({
    required Uri uri,
    required int? statusCode,
    required String failureKind,
    http.Response? response,
  }) async {
    // 1.4.3 C3: open the breaker the moment a 403 is seen, synchronously
    // — the log write below is queued and can lag ~500 ms, and a burst
    // fired in that window must not slip through. Only 403 opens it.
    if (statusCode == 403) _breakerOpenedAt = DateTime.now();
    final onRefusal = _onRefusal;
    if (onRefusal == null) return;
    try {
      await onRefusal(
        IptvRefusalEntry(
          timestamp: DateTime.now(),
          connectionId: _connectionId,
          connectionName: _connectionName,
          action: IptvRefusalEntry.actionForUri(uri),
          statusCode: statusCode,
          failureKind: failureKind,
          headers: response == null
              ? const {}
              : IptvRefusalEntry.sanitizeHeaders(response.headers, redactValues: [username, password]),
          bodySnippet: response == null
              ? ''
              : IptvRefusalEntry.sanitizeBody(response.body, redactValues: [username, password]),
          userAgent: _effectiveUserAgent,
        ),
      );
    } catch (_) {
      // Recording is best-effort; the refusal itself still throws.
    }
  }

  static String _failureKindFor(MediaServerHttpErrorType type) => switch (type) {
    MediaServerHttpErrorType.connectionTimeout || MediaServerHttpErrorType.receiveTimeout => 'timeout',
    MediaServerHttpErrorType.connectionError => 'connection',
    MediaServerHttpErrorType.cancelled => 'cancelled',
    MediaServerHttpErrorType.unknown => 'unknown',
  };

  /// Bodies larger than this are JSON-decoded off the main isolate
  /// (1.2.19, L-24): a big series' `get_series_info` payload decoded on
  /// the UI thread freezes the detail page for the whole payload.
  static const int _offMainDecodeChars = 512 * 1024;

  Future<dynamic> _getJson(
    Uri uri, {
    Duration timeout = const Duration(seconds: 30),
    Future<void>? abortTrigger,
  }) async {
    final body = await _fetchBody(uri, timeout: timeout, abortTrigger: abortTrigger);
    try {
      // 1.2.19 (L-24): large info payloads decode in a worker isolate —
      // the main isolate never blocks on a multi-MB `jsonDecode`.
      // Small bodies keep the inline path (no isolate round trip, and
      // widget tests under fake async never pay for one).
      if (body.length > _offMainDecodeChars) {
        return await compute(_decodeJson, body);
      }
      return jsonDecode(body);
    } on FormatException catch (e) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'Xtream returned unparseable JSON: $e',
        statusCode: 200,
        requestUri: uri,
      );
    }
  }

  static List<Map<String, dynamic>> _asObjectList(dynamic decoded) {
    if (decoded is List) return decoded.whereType<Map<String, dynamic>>().toList();
    return const [];
  }

  /// Parse a catalog list so one malformed row cannot discard it
  /// (1.2.17 — same class as the series `backdrop_path` wipe, where one
  /// mistyped field dropped ~95% of the series list): each row parses
  /// independently, and dropped rows are logged with their count instead
  /// of silently vanishing. [label] names the list in the log.
  static List<T> _parseCatalogList<T>(Object? decoded, T Function(Map<String, dynamic>) parse, String label) {
    final parsed = parseFlexibleJsonListCounted(decoded, parse);
    if (parsed.dropped > 0) {
      appLogger.w('Xtream $label: dropped ${parsed.dropped} malformed rows (kept ${parsed.rows.length})');
    }
    return parsed.rows;
  }

  /// Auth probe: no action. Returns the raw `user_info` map, or null when
  /// the payload has none (login rejected).
  Future<Map<String, dynamic>?> getUserInfo() async {
    final decoded = await _getJson(_playerApiUri());
    if (decoded is Map<String, dynamic>) {
      final info = decoded['user_info'];
      if (info is Map<String, dynamic>) return info;
    }
    return null;
  }

  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async {
    final decoded = await _getJson(
      _playerApiUri(action: 'get_live_categories'),
      abortTrigger: abortTrigger,
    );
    return _parseCatalogList(_asObjectList(decoded), XtreamCategory.fromJson, 'live categories');
  }

  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async {
    final decoded = await _getJson(
      _playerApiUri(action: 'get_vod_categories'),
      abortTrigger: abortTrigger,
    );
    return _parseCatalogList(_asObjectList(decoded), XtreamCategory.fromJson, 'VOD categories');
  }

  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async {
    final decoded = await _getJson(
      _playerApiUri(action: 'get_series_categories'),
      abortTrigger: abortTrigger,
    );
    return _parseCatalogList(_asObjectList(decoded), XtreamCategory.fromJson, 'series categories');
  }

  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId != null) {
      // Per-category bodies are small; the buffered path stays.
      final body = await _fetchBody(
        _playerApiUri(action: 'get_live_streams', extra: {'category_id': categoryId}),
        timeout: const Duration(seconds: 120),
        abortTrigger: abortTrigger,
      );
      lastLiveStreamsFilePath = null;
      return compute(_parseLiveStreams, body);
    }
    // 1.2.19 (A1): the full live list is tens of thousands of rows
    // (tens of MB) — the buffered path held it several times over
    // (buffer + String + retained body + isolate-port copy) and was the
    // last whole-body catalog fetch in the app (the 1.2.18 OOM
    // diagnosis: ~10–20 MB String, ~60–120 MB transient with copies).
    // Stream straight to a temp file and parse from the file in the
    // isolate instead — the main isolate never holds the body — exactly
    // as 1.2.16 did for VOD/series. The temp file IS the raw body the
    // caller persists as the disk cache (see
    // [lastLiveStreamsFilePath]); the oversize cap is enforced on the
    // streamed bytes by [_fetchBodyToFile], and a slow-but-delivering
    // connection is not cut off at 120s total (per-chunk-gap timeout
    // instead). Parsing stays off the UI thread — decoding tens of
    // thousands of rows on the main isolate freezes the app for
    // seconds.
    deleteHubTempFile(lastLiveStreamsFilePath);
    lastLiveStreamsFilePath = null;
    final tempPath = _newHubTempFile('live');
    try {
      await getLiveStreamsToFile(filePath: tempPath, abortTrigger: abortTrigger);
      final rows = await parseLiveStreamsFile(tempPath);
      lastLiveStreamsFilePath = tempPath;
      return rows;
    } catch (_) {
      deleteHubTempFile(tempPath);
      rethrow;
    }
  }

  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId != null) {
      // Per-category bodies are small; the buffered path stays.
      final body = await _fetchBody(
        _playerApiUri(action: 'get_vod_streams', extra: {'category_id': categoryId}),
        timeout: const Duration(seconds: 120),
        abortTrigger: abortTrigger,
      );
      lastVodStreamsBody = null;
      lastVodStreamsFilePath = null;
      return compute(_parseVodStreams, body);
    }
    // 1.2.16 (hub-load OOM): the full VOD list is ~200k rows (tens of
    // MB). The buffered path held it four times over (buffer + String
    // + retained body + isolate-port copy) and OOM-killed a 2.4GB TV
    // in the Discover hub load. Stream straight to a temp file and
    // parse from the file in the isolate instead — the main isolate
    // never holds the body. The temp file IS the raw body the caller
    // persists as the disk cache (see [lastVodStreamsFilePath]); the
    // oversize cap is enforced on the streamed bytes by
    // [_fetchBodyToFile], and a slow-but-delivering connection is not
    // cut off at 120s total (per-chunk-gap timeout instead).
    deleteHubTempFile(lastVodStreamsFilePath);
    lastVodStreamsBody = null;
    lastVodStreamsFilePath = null;
    final tempPath = _newHubTempFile('vod');
    try {
      await getVodStreamsToFile(filePath: tempPath, abortTrigger: abortTrigger);
      final rows = await parseVodStreamsFile(tempPath);
      lastVodStreamsFilePath = tempPath;
      return rows;
    } catch (_) {
      deleteHubTempFile(tempPath);
      rethrow;
    }
  }

  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId != null) {
      // Per-category bodies are small; the buffered path stays.
      final body = await _fetchBody(
        _playerApiUri(action: 'get_series', extra: {'category_id': categoryId}),
        timeout: const Duration(seconds: 120),
        abortTrigger: abortTrigger,
      );
      lastSeriesBody = null;
      lastSeriesFilePath = null;
      return compute(_parseSeries, body);
    }
    // 1.2.16 (hub-load OOM): same streaming shape as [getVodStreams]
    // — the full series list is ~46k rows and the hub fetches it
    // alongside VOD, so the two buffered bodies together were the
    // transient peak that killed the TV.
    deleteHubTempFile(lastSeriesFilePath);
    lastSeriesBody = null;
    lastSeriesFilePath = null;
    final tempPath = _newHubTempFile('series');
    try {
      await getSeriesToFile(filePath: tempPath, abortTrigger: abortTrigger);
      final rows = await parseSeriesFile(tempPath);
      lastSeriesFilePath = tempPath;
      return rows;
    } catch (_) {
      deleteHubTempFile(tempPath);
      rethrow;
    }
  }

  /// Full-list catalogs streamed straight to a file (1.2.10, one-parse
  /// sync): the sync's fetch path. Unlike [getLiveStreams] /
  /// [getVodStreams] / [getSeries], these do NOT buffer the body, do
  /// NOT parse, and do NOT set [lastLiveStreamsFilePath] /
  /// [lastVodStreamsFilePath] / [lastSeriesFilePath] — the main isolate
  /// never holds the body at all. The caller passes the temp file path
  /// (the parent dir must exist); the returned path is the same file,
  /// ready for the one-parse isolate job. Full-list only — per-category
  /// bodies are small and keep the buffered getters. [resume] continues
  /// a previous partial download at [filePath] instead of restarting
  /// it (1.2.19, L-3/L-4); [onProgress] fires after every chunk.
  Future<String> getLiveStreamsToFile({
    required String filePath,
    Future<void>? abortTrigger,
    bool resume = false,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    await _fetchBodyToFile(
      _playerApiUri(action: 'get_live_streams'),
      filePath,
      abortTrigger: abortTrigger,
      resume: resume,
      onProgress: onProgress,
    );
    return filePath;
  }

  Future<String> getVodStreamsToFile({
    required String filePath,
    Future<void>? abortTrigger,
    bool resume = false,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    await _fetchBodyToFile(
      _playerApiUri(action: 'get_vod_streams'),
      filePath,
      abortTrigger: abortTrigger,
      resume: resume,
      onProgress: onProgress,
    );
    return filePath;
  }

  Future<String> getSeriesToFile({
    required String filePath,
    Future<void>? abortTrigger,
    bool resume = false,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    await _fetchBodyToFile(
      _playerApiUri(action: 'get_series'),
      filePath,
      abortTrigger: abortTrigger,
      resume: resume,
      onProgress: onProgress,
    );
    return filePath;
  }

  /// M3U playlist export for this account, streamed straight to a file
  /// (1.2.19, A2): the playlist is tens of MB, and the old whole-body text fetch
  /// buffered the whole thing as a String. Same shape as
  /// [getLiveStreamsToFile] — the caller parses from the file in an
  /// isolate (see [parseM3uFile]) and the main isolate never holds the
  /// playlist. 120 s per-chunk-gap timeout (1.2.17 R2): a slow
  /// connection that keeps delivering is not cut off for merely being
  /// slow. [resume] continues a previous partial download at
  /// [filePath] instead of restarting it (L-3/L-4 mechanism). [timeout]
  /// is the per-chunk-gap budget (120 s default); it is a parameter so
  /// tests can prove the gap semantics with a short budget.
  /// [ignoreCatalogCap] (1.3.26 §69) exempts this download from the
  /// hostile-response cap: the provider playlist is ~300 MB and the
  /// caller streams it to a file and parses it line by line, so the
  /// cap would refuse a legitimate playlist while guarding nothing.
  Future<String> getM3uToFile({
    required String filePath,
    String type = 'm3u_plus',
    String output = 'ts',
    Duration timeout = const Duration(seconds: 120),
    Future<void>? abortTrigger,
    bool resume = false,
    bool ignoreCatalogCap = false,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    final outcome = await _fetchBodyToFile(
      Uri.parse('$serverUrl/get.php').replace(
        queryParameters: {'username': username, 'password': password, 'type': type, 'output': output},
      ),
      filePath,
      timeout: timeout,
      abortTrigger: abortTrigger,
      resume: resume,
      ignoreCatalogCap: ignoreCatalogCap,
      onProgress: onProgress,
    );
    // 1.3.27 §P0-1 (C2): the phone log must say whether the server
    // honoured Range — a 200 answer restarts the playlist from byte 0
    // on every stall, and the user must be told that, not left to
    // guess why the check never finishes. Never logs the URI
    // (credentials in the query string).
    if (outcome.resumedFromBytes > 0) {
      appLogger.i('IPTV: M3U playlist download resumed from ${outcome.resumedFromBytes} bytes (HTTP 206)');
    } else if (outcome.serverHonouredRange == false) {
      appLogger.i('IPTV: M3U playlist download restarted from byte 0 — server ignored Range (HTTP 200)');
    }
    return filePath;
  }

  /// Fresh temp file for one unfiltered hub download (1.2.16). Sync
  /// creation: a mkdir is a metadata op, and the hub load must also
  /// work under testWidgets' fake async, where real async disk I/O
  /// never completes. The caller owns the returned path (see
  /// [lastVodStreamsFilePath]).
  String _newHubTempFile(String type) {
    final dir = Directory.systemTemp.createTempSync('plezy_hub_${type}_');
    return '${dir.path}/$type.json';
  }

  /// Write [body] to a fresh hub temp file and return its path (1.2.19,
  /// A1): test fakes that answer [getLiveStreams] directly use this to
  /// hand the caller the raw body as a file, exactly as the real getter
  /// does via [getLiveStreamsToFile] — the caller persists the file as
  /// the disk cache ([lastLiveStreamsFilePath]). Sync I/O, same
  /// fake-async reason as [_newHubTempFile].
  static String writeHubTempFile(String type, String body) {
    final path = '${Directory.systemTemp.createTempSync('plezy_hub_${type}_').path}/$type.json';
    File(path).writeAsStringSync(body);
    return path;
  }

  /// Best-effort delete of a hub temp file's whole temp dir (1.2.16).
  /// Each hub download gets its own fresh temp dir, so the dir holds
  /// only this file. Sync, for the same fake-async reason as
  /// [_newHubTempFile]. Never throws. A null path is a no-op.
  static void deleteHubTempFile(String? filePath) {
    if (filePath == null) return;
    try {
      final dir = Directory(filePath).parent;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {
      // Best effort; the OS cleans the system temp dir.
    }
  }

  /// Full series detail: info + per-season episode lists.
  Future<XtreamSeriesInfo> getSeriesInfo(int seriesId) async {
    final decoded = await _getJson(_playerApiUri(action: 'get_series_info', extra: {'series_id': '$seriesId'}));
    if (decoded is! Map<String, dynamic>) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'Xtream get_series_info returned an unexpected payload',
      );
    }
    return XtreamSeriesInfo.fromJson(decoded);
  }

  /// Short EPG for one stream (up to [limit] listings). Titles and
  /// descriptions arrive Base64-encoded; they are decoded here, falling
  /// back to the raw string when decoding fails.
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    final decoded = await _getJson(
      _playerApiUri(action: 'get_short_epg', extra: {'stream_id': streamId, 'limit': '$limit'}),
      timeout: timeout ?? const Duration(seconds: 30),
      abortTrigger: abortTrigger,
    );
    if (decoded is! Map<String, dynamic>) return const [];
    final listings = decoded['epg_listings'];
    // 1.2.15 R3: the panel may return `epg_listings` as a JSON object
    // (a PHP associative array keyed by programme id) instead of an
    // array — the listings are the object's values either way.
    final listingMaps = switch (listings) {
      List() => listings.whereType<Map<String, dynamic>>(),
      Map<String, dynamic>() => listings.values.whereType<Map<String, dynamic>>(),
      Map() => listings.values.whereType<Map<String, dynamic>>(),
      _ => const <Map<String, dynamic>>[],
    };
    // 1.2.17: one mistyped listing no longer drops the whole answer.
    return _parseCatalogList(listingMaps.toList(), XtreamEpgProgram.fromJson, 'short EPG');
  }

  /// Simple data table (now/next + archive flags per stream). Returned raw;
  /// callers pick what they need.
  Future<Map<String, dynamic>?> getSimpleDataTable() async {
    final decoded = await _getJson(_playerApiUri(action: 'get_simple_data_table'));
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  /// Full XMLTV guide as a byte stream (large — callers stream-parse it
  /// instead of materialising the whole body; build #26). [timeout] bounds
  /// reaching the server and each quiet gap between chunks, so a slow
  /// connection that keeps delivering still completes. The stream carries
  /// the same User-Agent and abort rules as the other text fetches: [abortTrigger]
  /// hard-cancels the request at the socket. The bytes are the response
  /// body as the transport delivers it — gzip is already decoded by the
  /// underlying HttpClient (autoUncompress), verified by the loopback gzip
  /// test in iptv_build26_epg_streaming_test.dart.
  ///
  /// 1.2.2 I9 (conditional fetch): when [etag]/[lastModified] are given
  /// they are sent as If-None-Match / If-Modified-Since. A 304 answer
  /// comes back as `notModified: true` with an empty body stream — the
  /// caller reuses its guide instead of downloading and re-parsing.
  /// [etag]/[lastModified] in the result are the response's validators
  /// (from a 200 or a 304); null when the server sends none.
  ///
  /// Resume lives in [downloadXmltvFeedToFile], not here: this method's
  /// signature is overridden by test fakes, and Dart forbids an override
  /// from omitting optional named parameters — adding resume parameters
  /// here would break every fake. The file-download method is new API
  /// no fake overrides.
  Future<XmltvFeedFetch> getXmltvFeed({
    String? etag,
    String? lastModified,
    Duration timeout = const Duration(seconds: 120),
    Future<void>? abortTrigger,
  }) async {
    final uri = Uri.parse('$serverUrl/xmltv.php?username=$username&password=$password');
    // 1.4.3 C3: a recent 403 means no request at all — not even one.
    await _throwIfBreakerOpen(uri);
    http.StreamedResponse streamed;
    try {
      // Build #28: AbortableRequest, same shape as the other fetchers —
      // see their comment. The send is awaited (headers) under the timeout; the
      // body then streams with a per-chunk-gap timeout instead of one
      // total budget, so a 150 MB feed on a slow connection is not cut
      // off for merely being slow.
      final request = http.AbortableRequest('GET', uri, abortTrigger: abortTrigger);
      request.headers['User-Agent'] = _effectiveUserAgent;
      if (etag != null) request.headers['If-None-Match'] = etag;
      if (lastModified != null) request.headers['If-Modified-Since'] = lastModified;
      streamed = await _http.send(request).timeout(timeout);
    } catch (e) {
      final mapped = MediaServerHttpException.from(e, uri: uri);
      if (!mapped.isCancellation) {
        await _recordRefusal(uri: uri, statusCode: null, failureKind: _failureKindFor(mapped.type));
      }
      throw mapped;
    }
    if (streamed.statusCode == 304) {
      // A 304 has no body by definition: the feed the caller already
      // holds is current. The response validators are the ones to send
      // next time (a server may rotate them on a 304).
      return (
        bytes: const Stream<List<int>>.empty(),
        notModified: true,
        etag: streamed.headers['etag'],
        lastModified: streamed.headers['last-modified'],
      );
    }
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      // Buffer only the (small) error body for the refusal record, as
      // the other fetchers do — the success path never materialises the body.
      final response = await http.Response.fromStream(streamed);
      await _recordRefusal(uri: uri, statusCode: response.statusCode, failureKind: 'http', response: response);
      if (response.statusCode == 401) {
        throw MediaServerAuthException('Xtream authentication failed', statusCode: 401);
      }
      if (response.statusCode == 403) {
        throw MediaServerHttpException(
          type: MediaServerHttpErrorType.unknown,
          message: 'Xtream access denied',
          statusCode: 403,
          requestUri: uri,
        );
      }
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'Xtream request failed with HTTP ${response.statusCode}',
        statusCode: response.statusCode,
        requestUri: uri,
      );
    }
    return (
      bytes: streamed.stream.timeout(timeout),
      notModified: false,
      etag: streamed.headers['etag'],
      lastModified: streamed.headers['last-modified'],
    );
  }

  /// Download the full XMLTV guide straight to [filePath], resuming a
  /// previous partial download when the file already holds bytes
  /// (1.2.19, L-3 — the feed half of the [_fetchBodyToFile] resume
  /// mechanism, as its own method because [getXmltvFeed]'s signature
  /// is overridden by test fakes and cannot grow resume parameters).
  ///
  /// When [filePath] already holds N > 0 bytes, `Range: bytes=N-` is
  /// sent: a 206 appends to the file ([resumed] true), a 200 means the
  /// server ignored Range and the file is truncated and re-downloaded
  /// in full ([resumed] false), and a 416 (our partial is longer than
  /// the server's copy) or a 206 whose Content-Range starts at the
  /// wrong byte retries once without Range. No validators are
  /// sent on a resumed fetch. The body streams with the same 120 s
  /// per-chunk-gap timeout as [getXmltvFeed], file writes are
  /// synchronous (the feed path is awaited by widget tests — the tee
  /// in `iptv_live_tv.dart` uses sync I/O for the same reason), and the
  /// SHA-256 covers exactly the bytes in the file (the existing prefix
  /// is hashed by a chunked sync read, never held whole in memory).
  /// On failure the partial file is KEPT — the next call resumes it —
  /// so the caller must not delete it on error. [onProgress] fires
  /// after every chunk with the total bytes held and the expected
  /// total when the server declares one. Whether the panel honours
  /// Range on a dynamically generated `xmltv.php` is UNPROVEN on the
  /// live panel — the 200 fallback is the behaviour when it does not.
  Future<XmltvFeedDownload> downloadXmltvFeedToFile({
    required String filePath,
    Duration timeout = const Duration(seconds: 120),
    Future<void>? abortTrigger,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    final uri = Uri.parse('$serverUrl/xmltv.php?username=$username&password=$password');
    // 1.4.3 C3: a recent 403 means no request at all — not even one.
    await _throwIfBreakerOpen(uri);
    var existingBytes = 0;
    try {
      existingBytes = File(filePath).lengthSync();
    } catch (_) {
      existingBytes = 0;
    }
    if (existingBytes < 0) existingBytes = 0;
    http.StreamedResponse streamed;
    try {
      Future<http.StreamedResponse> send({required int fromBytes}) async {
        final request = http.AbortableRequest('GET', uri, abortTrigger: abortTrigger);
        request.headers['User-Agent'] = _effectiveUserAgent;
        if (fromBytes > 0) request.headers['Range'] = 'bytes=$fromBytes-';
        return _http.send(request);
      }

      streamed = await send(fromBytes: existingBytes).timeout(timeout);
      // A 206 whose Content-Range starts anywhere but [existingBytes]
      // is a server that resumed from the wrong place — appending its
      // bytes would corrupt the file. Restart from byte 0, like the
      // 416 path and like [_fetchBodyToFile] does for catalogs. A
      // missing/unparseable Content-Range start trusts the 206.
      final wrongRangeStart = existingBytes > 0 &&
          streamed.statusCode == 206 &&
          _rangeStart(streamed.headers['content-range']) != null &&
          _rangeStart(streamed.headers['content-range']) != existingBytes;
      if ((existingBytes > 0 && streamed.statusCode == 416) || wrongRangeStart) {
        try {
          await streamed.stream.listen(null).cancel();
        } catch (_) {
          // Best-effort drain; the retry is the signal.
        }
        existingBytes = 0;
        streamed = await send(fromBytes: 0).timeout(timeout);
      }
    } catch (e) {
      final mapped = MediaServerHttpException.from(e, uri: uri);
      if (!mapped.isCancellation) {
        await _recordRefusal(uri: uri, statusCode: null, failureKind: _failureKindFor(mapped.type));
      }
      throw mapped;
    }
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      final response = await http.Response.fromStream(streamed);
      await _recordRefusal(uri: uri, statusCode: response.statusCode, failureKind: 'http', response: response);
      if (response.statusCode == 401) {
        throw MediaServerAuthException('Xtream authentication failed', statusCode: 401);
      }
      if (response.statusCode == 403) {
        throw MediaServerHttpException(
          type: MediaServerHttpErrorType.unknown,
          message: 'Xtream access denied',
          statusCode: 403,
          requestUri: uri,
        );
      }
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'Xtream request failed with HTTP ${response.statusCode}',
        statusCode: response.statusCode,
        requestUri: uri,
      );
    }
    final resumed = existingBytes > 0 && streamed.statusCode == 206;
    final totalBytes = _rangeTotal(streamed.headers['content-range']) ??
        (streamed.contentLength == null
            ? null
            : (resumed ? existingBytes + streamed.contentLength! : streamed.contentLength));
    // Hash the whole file: the resumed prefix by chunked sync read,
    // then each new chunk as it lands. Sync file I/O throughout (see
    // the method doc): the feed path runs under widget tests.
    final shaDigestSink = _Sha256Collector();
    final shaSink = crypto.sha256.startChunkedConversion(shaDigestSink);
    if (resumed) {
      final raf = File(filePath).openSync(mode: FileMode.read);
      try {
        while (true) {
          final chunk = raf.readSync(64 * 1024);
          if (chunk.isEmpty) break;
          shaSink.add(chunk);
        }
      } finally {
        try {
          raf.closeSync();
        } catch (_) {}
      }
    }
    final sink = File(filePath).openWrite(mode: resumed ? FileMode.append : FileMode.write);
    var bytes = resumed ? existingBytes : 0;
    try {
      await for (final chunk in streamed.stream.timeout(timeout)) {
        sink.add(chunk);
        shaSink.add(chunk);
        bytes += chunk.length;
        onProgress?.call(bytes, totalBytes);
      }
      await sink.flush();
      shaSink.close();
    } catch (e) {
      // The partial file is KEPT on failure (see the method doc) — a
      // stalled feed resumes instead of restarting. The file sink is
      // closed by the finally below; rethrow after recording.
      final mapped = MediaServerHttpException.from(e, uri: uri);
      if (!mapped.isCancellation) {
        await _recordRefusal(uri: uri, statusCode: null, failureKind: _failureKindFor(mapped.type));
      }
      throw mapped;
    } finally {
      try {
        await sink.close();
      } catch (_) {}
    }
    return (
      notModified: false,
      resumed: resumed,
      resumedFromBytes: resumed ? existingBytes : 0,
      bytesDownloaded: bytes,
      totalBytes: totalBytes,
      sha256: shaDigestSink.value?.toString(),
      etag: streamed.headers['etag'],
      lastModified: streamed.headers['last-modified'],
    );
  }

  /// Parse the total size out of a `Content-Range: bytes <start>-<end>/<total>`
  /// header. Null when the header is absent, unparseable, or the total is
  /// unknown (`*`).
  static int? _rangeTotal(String? contentRange) {
    if (contentRange == null) return null;
    final match = RegExp(r'bytes \d+-\d+/(\d+)').firstMatch(contentRange);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// Full XMLTV guide as a byte stream (large — callers stream-parse it
  /// instead of materialising the whole body; build #26). Implemented on
  /// top of [getXmltvFeed] so there is one network path. A first fetch
  /// has no validators, so this never 304s.
  Stream<List<int>> getXmltvStream({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async* {
    final fetch = await getXmltvFeed(timeout: timeout, abortTrigger: abortTrigger);
    yield* fetch.bytes.timeout(timeout);
  }

/// Parse helpers for the disk cache (build #11): a cached payload is the
/// same JSON the API returns, so it parses through the same isolate
/// parsers as the network path — one parse shape, no second model.
/// Categories are small (<1k rows), so they parse inline.
static Future<List<XtreamLiveStream>> parseLiveStreamsBody(String body) => compute(_parseLiveStreams, body);

static Future<List<XtreamVodStream>> parseVodStreamsBody(String body) => compute(_parseVodStreams, body);

static Future<List<XtreamSeries>> parseSeriesBody(String body) => compute(_parseSeries, body);

/// Visible-only variants (1.2.4, catalog memory): the filter runs INSIDE
/// the isolate parse, so the memo holds visible rows only — the decoded
/// JSON is still fully materialised (unavoidable), but the typed row
/// list never holds a hidden row, and neither the parse peak nor the
/// steady state pays for the ~77% of rows in turned-off categories.
/// The disk file itself is pruned separately at write time; these
/// parsers are the defence for a stale full file (written before 1.2.4,
/// or by a path that writes the raw body).
static Future<List<XtreamLiveStream>> parseLiveStreamsBodyVisible(String body, VisibleCatalogFilter filter) =>
    compute(_parseLiveStreamsVisible, _VisibleParseParams(body, filter));

static Future<List<XtreamVodStream>> parseVodStreamsBodyVisible(String body, VisibleCatalogFilter filter) =>
    compute(_parseVodStreamsVisible, _VisibleParseParams(body, filter));

static Future<List<XtreamSeries>> parseSeriesBodyVisible(String body, VisibleCatalogFilter filter) =>
    compute(_parseSeriesVisible, _VisibleParseParams(body, filter));

/// Visible-only parse from a DISK FILE (1.2.6, catalog memory, item 4):
/// the isolate reads the file itself, so the main isolate never holds
/// the tens-of-MB body and `compute` copies only the path + filter
/// across the port — the whole-body message copy that drove the bind
/// peak is gone. Same rows as [parseLiveStreamsBodyVisible] for the
/// same file content (the file IS the body the disk cache wrote).
static Future<List<XtreamLiveStream>> parseLiveStreamsFileVisible(String path, VisibleCatalogFilter filter) =>
    compute(_parseLiveStreamsFileVisible, _VisibleFileParseParams(path, filter));

static Future<List<XtreamVodStream>> parseVodStreamsFileVisible(String path, VisibleCatalogFilter filter) =>
    compute(_parseVodStreamsFileVisible, _VisibleFileParseParams(path, filter));

static Future<List<XtreamSeries>> parseSeriesFileVisible(String path, VisibleCatalogFilter filter) =>
    compute(_parseSeriesFileVisible, _VisibleFileParseParams(path, filter));

/// Full (unfiltered) parse from a DISK FILE (1.2.16, hub-load OOM):
/// the isolate reads the file itself, so the main isolate never holds
/// the tens-of-MB body — same shape as [parseVodStreamsFileVisible]
/// but WITHOUT the visible filter. The hub path's unfiltered loads
/// need the FULL rows: the first-load coverage guard runs on them
/// (hidden categories count as covered, FORK §45) and the caller
/// filters afterwards. The visible file parse cannot serve that — it
/// would make a complete load look partial whenever enough categories
/// are hidden.
static Future<List<XtreamVodStream>> parseVodStreamsFile(String path) =>
    compute(_parseVodStreamsFile, path);

static Future<List<XtreamSeries>> parseSeriesFile(String path) =>
    compute(_parseSeriesFile, path);

/// Full (unfiltered) live parse from a DISK FILE (1.2.19, A1): the
/// isolate reads the file itself, so the main isolate never holds the
/// tens-of-MB body — the live half of [parseVodStreamsFile] /
/// [parseSeriesFile], which 1.2.16 added for the hub loads.
static Future<List<XtreamLiveStream>> parseLiveStreamsFile(String path) =>
    compute(_parseLiveStreamsFile, path);

/// Visible-only disk write from a downloaded catalog file (1.2.16):
/// the isolate reads [sourcePath], filters to visible rows, and
/// writes the pruned JSON to [destPath] — the main isolate never holds
/// the body or the re-encoded string (the build #13 main-isolate
/// jsonEncode freeze). The hub path's first-load write uses this when
/// the filter hides anything; when nothing is hidden the downloaded
/// file IS the visible file and is moved instead. The destination's
/// parent dir is created here, so the caller never has to.
static Future<void> writeVodStreamsFileVisible(
  String sourcePath,
  String destPath,
  VisibleCatalogFilter filter,
) =>
    compute(_writeVodStreamsFileVisible, _VisibleFileWriteParams(sourcePath, destPath, filter));

static Future<void> writeSeriesFileVisible(
  String sourcePath,
  String destPath,
  VisibleCatalogFilter filter,
) =>
    compute(_writeSeriesFileVisible, _VisibleFileWriteParams(sourcePath, destPath, filter));

/// Visible-only live write from a downloaded catalog file (1.2.19,
/// A1): the live half of [writeVodStreamsFileVisible] /
/// [writeSeriesFileVisible] — the isolate reads [sourcePath], filters
/// to visible rows, and writes the pruned JSON to [destPath].
static Future<void> writeLiveStreamsFileVisible(
  String sourcePath,
  String destPath,
  VisibleCatalogFilter filter,
) =>
    compute(_writeLiveStreamsFileVisible, _VisibleFileWriteParams(sourcePath, destPath, filter));

/// Visible-only re-encode (1.2.4, catalog memory): decode + filter +
/// re-encode the raw body in the isolate, so the disk write gets a
/// visible-only payload without a main-isolate `jsonEncode` freeze
/// (build #13: encoding 199k VOD rows on the UI isolate froze the app
/// ~1.3s). The disk file stays a plain API payload the isolate parsers
/// read unchanged — just pruned. Used by the sync disk write and the
/// first-load fallback writes.
static Future<String> encodeLiveStreamsBodyVisible(String body, VisibleCatalogFilter filter) =>
    compute(_encodeLiveStreamsVisible, _VisibleParseParams(body, filter));

static Future<String> encodeVodStreamsBodyVisible(String body, VisibleCatalogFilter filter) =>
    compute(_encodeVodStreamsVisible, _VisibleParseParams(body, filter));

static Future<String> encodeSeriesBodyVisible(String body, VisibleCatalogFilter filter) =>
    compute(_encodeSeriesVisible, _VisibleParseParams(body, filter));

static List<XtreamCategory> parseCategoriesBody(String body) =>
    _parseCatalogList(_asObjectList(_decodeCatalogJson(body)), XtreamCategory.fromJson, 'categories');
  // -- Stream URL builders (direct play, no transcode) ---------------------

  String liveStreamUrl(String streamId) => '$serverUrl/live/$username/$password/$streamId.m3u8';

  String movieStreamUrl(String streamId, String containerExtension) {
    final ext = containerExtension.isEmpty ? 'mp4' : containerExtension;
    return '$serverUrl/movie/$username/$password/$streamId.$ext';
  }

  String seriesStreamUrl(String episodeId, String containerExtension) {
    final ext = containerExtension.isEmpty ? 'mp4' : containerExtension;
    return '$serverUrl/series/$username/$password/$episodeId.$ext';
  }

  /// Catch-up URL. [durationMinutes] is the requested window length in
  /// minutes; [start] is the programme start, formatted
  /// `YYYY-MM-DD:HH-MM` in UTC (the panel's convention).
  ///
  /// Build #16: the stamp used to carry seconds (`YYYY-MM-DD:HH-MM-SS`)
  /// and catch-up never played on the real panel — every documented
  /// source (UniPlayer catch-up spec, Dispatcharr's Xtream client, the
  /// Xtream API docs) agrees the start is `YYYY-MM-DD:HH-MM`, no seconds
  /// ("Strict `YYYY-MM-DD:HH-MM`"). A start the panel cannot parse
  /// resolves no archive segment, so mpv's open fails and the mini-player
  /// shows "Could not start the live channel".
  String timeshiftUrl({required String streamId, required int durationMinutes, required DateTime start}) {
    final utc = start.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${utc.year}-${two(utc.month)}-${two(utc.day)}:${two(utc.hour)}-${two(utc.minute)}';
    return '$serverUrl/timeshift/$username/$password/$durationMinutes/$stamp/$streamId.m3u8';
  }
}

/// Top-level catalog parsers for [compute]: the big Xtream lists are tens
/// of thousands of rows, and decoding + mapping them on the UI thread
/// freezes the app for seconds. These run on a background isolate; a
/// malformed body surfaces as the same [MediaServerHttpException] the
/// inline path used to throw, so callers see no difference.
dynamic _decodeCatalogJson(String body) {
  try {
    return jsonDecode(body);
  } on FormatException catch (e) {
    throw MediaServerHttpException(
      type: MediaServerHttpErrorType.unknown,
      message: 'Xtream returned unparseable JSON: $e',
    );
  }
}

/// Off-main-isolate JSON decode (1.2.19, L-24): `compute` needs a
/// top-level function. A [FormatException] here propagates back to the
/// caller, which maps it exactly like the inline decode.
dynamic _decodeJson(String body) => jsonDecode(body);

/// The sink half of a chunked SHA-256 (1.2.19, L-3): [Hash.startChunkedConversion]
/// takes a [Sink] of digests, and the crypto package's own `DigestSink`
/// is not exported — this collects the one digest the conversion emits
/// on close. (The feed parser in `iptv_live_tv.dart` has its own twin
/// there — the two cannot share one, they live in different libraries.)
class _Sha256Collector implements Sink<crypto.Digest> {
  crypto.Digest? value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}

/// One malformed row must not discard a whole catalog: the real provider's
/// 46k-row series list contains mistyped fields (e.g. a numeric `cover`),
/// and the old `.map(X.fromJson)` parse threw the entire list away — Movies
/// loaded while Series showed nothing. Each row parses independently now.
/// The string reads coerce mistyped values (flexibleString) instead of
/// casting, so one bad field can't drop a row either: backdrop_path
/// arrives as an array, and a bare cast dropped ~95% of the series list.
List<XtreamLiveStream> _parseLiveStreams(String body) =>
    parseFlexibleJsonList(_decodeCatalogJson(body), XtreamLiveStream.fromJson);

List<XtreamVodStream> _parseVodStreams(String body) =>
    parseFlexibleJsonList(_decodeCatalogJson(body), XtreamVodStream.fromJson);

List<XtreamSeries> _parseSeries(String body) =>
    parseFlexibleJsonList(_decodeCatalogJson(body), XtreamSeries.fromJson);

/// Message for the visible-only parsers: the body plus the filter.
/// Plain values only, like [IndexWriteParams].
class _VisibleParseParams {
  final String body;
  final VisibleCatalogFilter filter;

  const _VisibleParseParams(this.body, this.filter);
}

/// Like [parseFlexibleJsonList] but the filter runs DURING the row loop:
/// a hidden row is parsed and dropped before it can join the list, so
/// the isolate never builds the full typed list — that is what shrinks
/// the parse peak, not just the steady state. Malformed rows are dropped
/// exactly as the unfiltered parse drops them.
///
/// 1.2.6 (catalog memory, item 4): hidden rows are skipped BEFORE they
/// are parsed at all — the category id comes straight off the raw map,
/// exactly as the typed row would carry it (`category_id?.toString()`,
/// no transformation in any of the three models), so the outcome is
/// identical and the ~77% of rows in hidden categories never become
/// typed objects. The post-parse check stays as a safety net.
List<T> _parseVisibleList<T>(
  Object? value,
  T Function(Map<String, dynamic> json) parse,
  String? Function(T row) categoryIdOf,
  VisibleCatalogFilter filter,
) {
  final result = <T>[];
  for (final json in flexibleMapList(value)) {
    try {
      if (filter.isHidden(json['category_id']?.toString())) continue;
      final row = parse(json);
      if (!filter.isHidden(categoryIdOf(row))) result.add(row);
    } catch (_) {
      // A malformed row does not invalidate its siblings.
    }
  }
  return result;
}

List<XtreamLiveStream> _parseLiveStreamsVisible(_VisibleParseParams params) => _parseVisibleList(
      _decodeCatalogJson(params.body),
      XtreamLiveStream.fromJson,
      (row) => row.categoryId,
      params.filter,
    );

List<XtreamVodStream> _parseVodStreamsVisible(_VisibleParseParams params) => _parseVisibleList(
      _decodeCatalogJson(params.body),
      XtreamVodStream.fromJson,
      (row) => row.categoryId,
      params.filter,
    );

List<XtreamSeries> _parseSeriesVisible(_VisibleParseParams params) => _parseVisibleList(
      _decodeCatalogJson(params.body),
      XtreamSeries.fromJson,
      (row) => row.categoryId,
      params.filter,
    );

/// Message for the file-based visible parsers: a path plus the filter.
/// Plain values only, like [_VisibleParseParams].
class _VisibleFileParseParams {
  final String path;
  final VisibleCatalogFilter filter;

  const _VisibleFileParseParams(this.path, this.filter);
}

/// File-based visible parsers (1.2.6, item 4): same rows as the
/// body-based ones — the isolate reads the file, then runs the identical
/// in-loop filter. A missing/corrupt file throws, and the caller treats
/// that as a cache miss exactly like a corrupt body.
///
/// 1.4 (F3): the file is streamed row by row ([parseJsonArrayFile] /
/// [streamJsonArrayFile]) instead of read whole + `jsonDecode`d — the
/// tens-of-MB body String and the decoded list of maps are never
/// resident. The in-loop filter is the same as [_parseVisibleList]:
/// hidden rows are skipped before parsing (category id straight off
/// the raw map), with the post-parse check as a safety net. A truncated
/// file reports incomplete and throws exactly like the old whole-file
/// decode failing — its valid prefix never lands as a partial list.
Future<List<T>> _parseCatalogFileVisible<T>(
  String path,
  T Function(Map<String, dynamic> json) parse,
  String? Function(T row) categoryIdOf,
  VisibleCatalogFilter filter,
) async {
  final rows = <T>[];
  final result = await streamJsonArrayFile(
    path,
    onObject: (map) {
      try {
        if (filter.isHidden(map['category_id']?.toString())) return;
        final row = parse(map);
        if (!filter.isHidden(categoryIdOf(row))) rows.add(row);
      } catch (_) {
        // A malformed row does not invalidate its siblings.
      }
    },
  );
  if (!result.complete) _throwUnparseableCatalog();
  return rows;
}

/// Full (unfiltered) file parsers (1.2.16/1.2.19): same rows as the
/// body-based ones. 1.4 (F3): streamed row by row instead of whole-file
/// read + `jsonDecode` — the download already streamed to the file, and
/// now the parse does too, so a cold first-load never holds the body
/// String + the decoded maps + the typed rows at once. A truncated file
/// throws exactly like the old whole-file decode failing.
Future<List<T>> _parseCatalogFile<T>(
  String path,
  T Function(Map<String, dynamic> json) parse,
) async {
  final parsed = await parseJsonArrayFile<T>(path, parse);
  if (!parsed.complete) _throwUnparseableCatalog();
  return parsed.rows;
}

/// The corrupt-catalog throw, shared by the streaming file parsers:
/// same type + message prefix as [_decodeCatalogJson]'s throw, so
/// callers that treat an unparseable body as a cache miss / empty
/// response see no change.
Never _throwUnparseableCatalog() {
  throw MediaServerHttpException(
    type: MediaServerHttpErrorType.unknown,
    message: 'Xtream returned unparseable JSON: truncated or malformed catalog file',
  );
}

Future<List<XtreamLiveStream>> _parseLiveStreamsFileVisible(_VisibleFileParseParams params) =>
    _parseCatalogFileVisible(
      params.path,
      XtreamLiveStream.fromJson,
      (row) => row.categoryId,
      params.filter,
    );

Future<List<XtreamVodStream>> _parseVodStreamsFileVisible(_VisibleFileParseParams params) =>
    _parseCatalogFileVisible(
      params.path,
      XtreamVodStream.fromJson,
      (row) => row.categoryId,
      params.filter,
    );

Future<List<XtreamSeries>> _parseSeriesFileVisible(_VisibleFileParseParams params) =>
    _parseCatalogFileVisible(
      params.path,
      XtreamSeries.fromJson,
      (row) => row.categoryId,
      params.filter,
    );

Future<List<XtreamVodStream>> _parseVodStreamsFile(String path) =>
    _parseCatalogFile(path, XtreamVodStream.fromJson);

Future<List<XtreamLiveStream>> _parseLiveStreamsFile(String path) =>
    _parseCatalogFile(path, XtreamLiveStream.fromJson);

Future<List<XtreamSeries>> _parseSeriesFile(String path) =>
    _parseCatalogFile(path, XtreamSeries.fromJson);

/// Message for the file-based visible writers: source + destination
/// paths plus the filter. Plain values only, like [_VisibleFileParseParams].
class _VisibleFileWriteParams {
  final String sourcePath;
  final String destPath;
  final VisibleCatalogFilter filter;

  const _VisibleFileWriteParams(this.sourcePath, this.destPath, this.filter);
}

/// Shared visible-only file writer (1.4, F3): streams the source file
/// row by row and writes the visible rows incrementally to a temp file,
/// renamed into place only when the source parsed cleanly — the same
/// temp+rename atomicity as the sync's S-2 disk writer. The old shape
/// read the whole source, decoded the whole list, built the whole
/// visible list, and re-encoded it as one String; this holds one row
/// plus one 2048-row chunk (~300 KB) at a time. A truncated source
/// throws and leaves the previous disk file untouched (the temp file
/// is deleted); the caller treats that as a failed persist, never as a
/// partial catalog. The bytes are identical to the old
/// `jsonEncode(visible.map(toJson).toList())` (compact JSON, no spaces).
Future<void> _writeCatalogFileVisible<T>(
  _VisibleFileWriteParams params,
  T Function(Map<String, dynamic> json) parse,
  String? Function(T row) categoryIdOf,
  Map<String, dynamic> Function(T row) toJson,
) async {
  final dest = File(params.destPath);
  await dest.parent.create(recursive: true);
  final tmpFile = File('${params.destPath}.tmp');
  final sink = tmpFile.openWrite();
  try {
    sink.write('[');
    const chunkRows = 2048;
    final chunk = StringBuffer();
    var first = true;
    var inChunk = 0;
    final result = await streamJsonArrayFile(
      params.sourcePath,
      onObject: (map) {
        try {
          if (params.filter.isHidden(map['category_id']?.toString())) return;
          final row = parse(map);
          if (params.filter.isHidden(categoryIdOf(row))) return;
          if (!first) chunk.write(',');
          first = false;
          chunk.write(jsonEncode(toJson(row)));
          if (++inChunk >= chunkRows) {
            sink.write(chunk.toString());
            chunk.clear();
            inChunk = 0;
          }
        } catch (_) {
          // A malformed row does not invalidate its siblings.
        }
      },
    );
    if (inChunk > 0) sink.write(chunk.toString());
    sink.write(']');
    await sink.close();
    if (!result.complete) {
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {}
      _throwUnparseableCatalog();
    }
    if (await dest.exists()) await dest.delete();
    await tmpFile.rename(params.destPath);
  } catch (e) {
    try {
      await sink.close();
    } catch (_) {}
    try {
      if (await tmpFile.exists()) await tmpFile.delete();
    } catch (_) {}
    rethrow;
  }
}

Future<void> _writeVodStreamsFileVisible(_VisibleFileWriteParams params) =>
    _writeCatalogFileVisible(
      params,
      XtreamVodStream.fromJson,
      (row) => row.categoryId,
      (row) => row.toJson(),
    );

Future<void> _writeLiveStreamsFileVisible(_VisibleFileWriteParams params) =>
    _writeCatalogFileVisible(
      params,
      XtreamLiveStream.fromJson,
      (row) => row.categoryId,
      (row) => row.toJson(),
    );

Future<void> _writeSeriesFileVisible(_VisibleFileWriteParams params) =>
    _writeCatalogFileVisible(
      params,
      XtreamSeries.fromJson,
      (row) => row.categoryId,
      (row) => row.toJson(),
    );

String _encodeLiveStreamsVisible(_VisibleParseParams params) =>
    jsonEncode(_parseLiveStreamsVisible(params).map((row) => row.toJson()).toList());

String _encodeVodStreamsVisible(_VisibleParseParams params) =>
    jsonEncode(_parseVodStreamsVisible(params).map((row) => row.toJson()).toList());

String _encodeSeriesVisible(_VisibleParseParams params) =>
    jsonEncode(_parseSeriesVisible(params).map((row) => row.toJson()).toList());

class XtreamCategory {
  final String id;
  final String name;
  final String? parentId;

  const XtreamCategory({required this.id, required this.name, this.parentId});

  factory XtreamCategory.fromJson(Map<String, dynamic> json) {
    return XtreamCategory(
      id: stringOrEmpty(json['category_id']),
      // 1.2.17: coerce, don't cast — a numeric `category_name` used to
      // throw the whole category list away (same class as the series
      // `backdrop_path` wipe).
      name: flexibleString(json['category_name']) ?? '',
      parentId: json['parent_id']?.toString(),
    );
  }

  /// API-shaped map (build #11): the disk cache stores the same JSON the
  /// API returns, so a cached payload re-parses through [fromJson].
  Map<String, dynamic> toJson() => {'category_id': id, 'category_name': name, 'parent_id': parentId};
}

class XtreamLiveStream {
  final int streamId;
  final String name;
  final String? streamIcon;
  final String? epgChannelId;
  final String? categoryId;
  final bool tvArchive;
  final int tvArchiveDuration; // seconds the archive reaches back

  /// Xtream's `tv_archive_duration` is the catch-up window in DAYS
  /// (provider docs: "for how many days", example 7) — convert to seconds
  /// here so every downstream use (seek window, timeshift clamp) sees
  /// seconds. A value no panel would express in days (> 366) is already
  /// seconds and passes through unchanged.
  static int archiveDurationSeconds(int raw) => raw > 366 ? raw : raw * 24 * 3600;

  const XtreamLiveStream({
    required this.streamId,
    required this.name,
    this.streamIcon,
    this.epgChannelId,
    this.categoryId,
    this.tvArchive = false,
    this.tvArchiveDuration = 0,
  });

  factory XtreamLiveStream.fromJson(Map<String, dynamic> json) {
    return XtreamLiveStream(
      streamId: flexibleInt(json['stream_id']) ?? 0,
      name: flexibleString(json['name']) ?? '',
      streamIcon: flexibleString(json['stream_icon']),
      // 1.2.8 F1: an empty-string epg_channel_id is absent, not an id.
      epgChannelId: flexibleNonEmptyString(json['epg_channel_id']),
      categoryId: json['category_id']?.toString(),
      tvArchive: flexibleInt(json['tv_archive']) == 1,
      tvArchiveDuration: archiveDurationSeconds(flexibleInt(json['tv_archive_duration']) ?? 0),
    );
  }

  /// API-shaped map (build #11) — see [XtreamCategory.toJson].
  /// `tv_archive_duration` is stored in seconds (as held on this object):
  /// a seconds value above 366 passes through [fromJson] unchanged, so
  /// this round-trips (a 7-day archive is 604800s, not 7).
  Map<String, dynamic> toJson() => {
    'stream_id': streamId,
    'name': name,
    'stream_icon': streamIcon,
    'epg_channel_id': epgChannelId,
    'category_id': categoryId,
    'tv_archive': tvArchive ? 1 : 0,
    'tv_archive_duration': tvArchiveDuration,
  };
}

class XtreamVodStream {
  final int streamId;
  final String name;
  final String? streamIcon;
  final String? cover;
  final double? rating;
  final String? categoryId;
  final String containerExtension;
  final int? added;

  const XtreamVodStream({
    required this.streamId,
    required this.name,
    this.streamIcon,
    this.cover,
    this.rating,
    this.categoryId,
    this.containerExtension = 'mp4',
    this.added,
  });

  factory XtreamVodStream.fromJson(Map<String, dynamic> json) {
    return XtreamVodStream(
      streamId: flexibleInt(json['stream_id']) ?? 0,
      name: flexibleString(json['name']) ?? '',
      streamIcon: flexibleString(json['stream_icon']),
      cover: flexibleString(json['cover']),
      rating: flexibleDouble(json['rating']),
      categoryId: json['category_id']?.toString(),
      containerExtension: flexibleString(json['container_extension']) ?? 'mp4',
      added: flexibleInt(json['added']),
    );
  }

  /// API-shaped map (build #11) — see [XtreamCategory.toJson].
  Map<String, dynamic> toJson() => {
    'stream_id': streamId,
    'name': name,
    'stream_icon': streamIcon,
    'cover': cover,
    'rating': rating,
    'category_id': categoryId,
    'container_extension': containerExtension,
    'added': added,
  };
}

class XtreamSeries {
  final int seriesId;
  final String name;
  final String? cover;
  final String? plot;
  final String? cast;
  final String? director;
  final String? genre;
  final String? releaseDate;
  final double? rating;
  final String? categoryId;
  final String? backdropPath;
  final String? youtubeTrailer;
  final int? episodeRunTime;

  const XtreamSeries({
    required this.seriesId,
    required this.name,
    this.cover,
    this.plot,
    this.cast,
    this.director,
    this.genre,
    this.releaseDate,
    this.rating,
    this.categoryId,
    this.backdropPath,
    this.youtubeTrailer,
    this.episodeRunTime,
  });

  factory XtreamSeries.fromJson(Map<String, dynamic> json) {
    return XtreamSeries(
      seriesId: flexibleInt(json['series_id']) ?? 0,
      name: flexibleString(json['name']) ?? '',
      cover: flexibleString(json['cover']),
      plot: flexibleString(json['plot']),
      cast: flexibleString(json['cast']),
      director: flexibleString(json['director']),
      genre: flexibleString(json['genre']),
      releaseDate: flexibleString(json['releaseDate']),
      rating: flexibleDouble(json['rating']),
      categoryId: json['category_id']?.toString(),
      backdropPath: flexibleString(json['backdrop_path']),
      youtubeTrailer: flexibleString(json['youtube_trailer']),
      episodeRunTime: flexibleInt(json['episode_run_time']),
    );
  }

  /// API-shaped map (build #11) — see [XtreamCategory.toJson].
  Map<String, dynamic> toJson() => {
    'series_id': seriesId,
    'name': name,
    'cover': cover,
    'plot': plot,
    'cast': cast,
    'director': director,
    'genre': genre,
    'releaseDate': releaseDate,
    'rating': rating,
    'category_id': categoryId,
    'backdrop_path': backdropPath,
    'youtube_trailer': youtubeTrailer,
    'episode_run_time': episodeRunTime,
  };
}

class XtreamEpisode {
  final int id;
  final int episodeNum;
  final String title;
  final String containerExtension;
  final int? durationSeconds;
  final String? plot;

  const XtreamEpisode({
    required this.id,
    required this.episodeNum,
    required this.title,
    this.containerExtension = 'mp4',
    this.durationSeconds,
    this.plot,
  });

  factory XtreamEpisode.fromJson(Map<String, dynamic> json) {
    final info = json['info'] is Map<String, dynamic> ? json['info'] as Map<String, dynamic> : null;
    return XtreamEpisode(
      id: flexibleInt(json['id']) ?? 0,
      episodeNum: flexibleInt(json['episode_num']) ?? 0,
      // 1.2.17: coerce, don't cast (see [XtreamCategory.fromJson]).
      title: flexibleString(json['title']) ?? '',
      containerExtension: flexibleString(json['container_extension']) ?? 'mp4',
      durationSeconds: flexibleInt(info?['duration']),
      plot: flexibleString(info?['plot']),
    );
  }
}

class XtreamSeriesInfo {
  /// season number → episodes, in episode order.
  final Map<int, List<XtreamEpisode>> episodesBySeason;
  final Map<String, dynamic>? info;

  const XtreamSeriesInfo({required this.episodesBySeason, this.info});

  factory XtreamSeriesInfo.fromJson(Map<String, dynamic> json) {
    final episodes = <int, List<XtreamEpisode>>{};
    final raw = json['episodes'];
    if (raw is Map<String, dynamic>) {
      for (final entry in raw.entries) {
        final season = int.tryParse(entry.key);
        final list = entry.value;
        if (season == null || list is! List) continue;
        // 1.2.17: one mistyped episode no longer drops the season.
        episodes[season] = XtreamApi._parseCatalogList(list, XtreamEpisode.fromJson, 'episodes');
      }
    }
    final info = json['info'] is Map<String, dynamic> ? json['info'] as Map<String, dynamic> : null;
    return XtreamSeriesInfo(episodesBySeason: episodes, info: info);
  }
}

String _decodeBase64Text(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  try {
    return utf8.decode(base64Decode(raw));
  } catch (_) {
    return raw;
  }
}

class XtreamEpgProgram {
  final String id;
  final String title;
  final String description;
  final int startTimestamp; // epoch seconds
  final int stopTimestamp; // epoch seconds
  final String? channelId;

  const XtreamEpgProgram({
    required this.id,
    required this.title,
    required this.description,
    required this.startTimestamp,
    required this.stopTimestamp,
    this.channelId,
  });

  factory XtreamEpgProgram.fromJson(Map<String, dynamic> json) {
    // 1.2.15 R3: a listing may carry only `start`/`stop` STRING fields
    // ("2026-11-14 16:00:00") with no `start_timestamp`/`stop_timestamp`
    // — without the fallback those listings parse to epoch 0 and the
    // window filter drops them silently. The strings are the same
    // instant the epoch fields would name, so they parse as UTC.
    var startTimestamp = flexibleInt(json['start_timestamp']) ?? 0;
    if (startTimestamp == 0) startTimestamp = _epgDateTimeToEpoch(json['start']);
    var stopTimestamp = flexibleInt(json['stop_timestamp']) ?? 0;
    if (stopTimestamp == 0) stopTimestamp = _epgDateTimeToEpoch(json['stop']);
    return XtreamEpgProgram(
      id: stringOrEmpty(json['id']),
      // 1.2.17: coerce, don't cast (see [XtreamCategory.fromJson]) — a
      // numeric title used to drop the whole short-EPG answer.
      title: _decodeBase64Text(flexibleString(json['title'])),
      description: _decodeBase64Text(flexibleString(json['description'])),
      startTimestamp: startTimestamp,
      stopTimestamp: stopTimestamp,
      channelId: json['channel_id']?.toString(),
    );
  }

  /// Parse an Xtream `start`/`stop` string ("2026-11-14 16:00:00", or
  /// an ISO string) as UTC epoch seconds; 0 when unparseable.
  static int _epgDateTimeToEpoch(Object? value) {
    if (value is! String || value.isEmpty) return 0;
    try {
      final text = value.contains('T') ? value : value.replaceFirst(' ', 'T');
      final hasZone = text.endsWith('Z') || text.contains('+') || text.substring(10).contains('-');
      final parsed = DateTime.parse(hasZone ? text : '${text}Z');
      return parsed.millisecondsSinceEpoch ~/ 1000;
    } catch (_) {
      return 0;
    }
  }
}
