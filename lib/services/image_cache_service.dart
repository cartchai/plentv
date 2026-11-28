import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:cached_network_image_ce/cached_network_image.dart'
    show FileInfo, FileResponse, FileSource, HttpInterceptor, HttpRequestData, HttpRequestHandler;
// CE's public conditional export hides the IO-only httpClientFactory parameter
// behind a narrower unsupported-platform stub.
// ignore: implementation_imports
import 'package:cached_network_image_ce/src/cache/default_cache_manager.dart' as ce_cache;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../utils/app_logger.dart';
import '../utils/media_server_http_client.dart';
import 'device_performance.dart';
import 'storage_health.dart';

final _artworkHttpClient = MediaServerHttpClient();

@visibleForTesting
int artworkRequestConcurrencyForTier({required bool reduced}) => reduced ? 3 : 6;

// Top-level fields are initialized lazily. The first artwork request happens
// after DevicePerformance has resolved the hardware tier during bootstrap.
final _artworkRequestLimiter = _RequestLimiter(artworkRequestConcurrencyForTier(reduced: DevicePerformance.isReduced));

Future<void> closeArtworkHttpClientGracefully({Duration drainTimeout = const Duration(seconds: 5)}) {
  return _artworkHttpClient.closeGracefully(drainTimeout: drainTimeout);
}

/// Shared cache manager for media-server image artwork. Used for both Plex and
/// Jellyfin artwork (the class name predates Jellyfin support — it's
/// backend-neutral).
///
/// Artwork rails are the widest fan-out in the app, so the wrapper below keeps
/// it bounded — weak TV devices must not decode a whole rail at once — while
/// the shared platform client supplies the connection pool it fans out over.
/// Image disk-cache object cap for the storage state (L-20, T1-13):
/// the normal 3,000-object cache, or 500 objects while free space is
/// low — the disk cache must not keep growing against a nearly-full
/// flash. Pure and testable; the manager reads it at construction.
@visibleForTesting
int imageDiskCacheMaxObjects({required bool lowStorage}) =>
    lowStorage ? StorageHealth.lowStorageImageCacheMaxObjects : StorageHealth.normalImageCacheMaxObjects;

/// Image disk-cache byte cap for the storage state (1.6.34, P-10):
/// the normal 512 MB cache, or 128 MB while free space is low. The
/// object cap alone cannot bound bytes — 3,000 large posters could be
/// gigabytes — so the byte cap is the binding limit when posters run
/// large. Pure and testable; the trim reads it at run time.
@visibleForTesting
int imageDiskCacheMaxBytes({required bool lowStorage}) =>
    lowStorage ? StorageHealth.lowStorageImageCacheMaxBytes : StorageHealth.normalImageCacheMaxBytes;

class PlexImageCacheManager extends ce_cache.DefaultCacheManager {
  static final PlexImageCacheManager instance = PlexImageCacheManager._();

  /// The cache directory provider (1.6.34, P-10): the byte trim lists
  /// this directory directly — CE's metadata box is private to CE.
  final ce_cache.CacheDirectoryProvider _cacheDirectoryProvider;

  PlexImageCacheManager._()
    : this.forTesting(
        httpClientFactory: () => _SharedHttpClient(_artworkHttpClient.inner, _artworkRequestLimiter),
        cacheDirectoryProvider: getApplicationCacheDirectory,
        // The cap is latched at construction: [StorageHealth.refresh]
        // runs in the startup gate before any artwork loads, so a low
        // device builds with the 500-object cap from the first download.
        // A device that fills up mid-session keeps its built cap until
        // the next cold start — [applyLowStorageCap] frees the space now
        // (see below); it cannot shrink a cap CE fixed at construction.
        maxNrOfCacheObjects: imageDiskCacheMaxObjects(lowStorage: StorageHealth.isLowFreeSpace),
      );

  @visibleForTesting
  PlexImageCacheManager.forTesting({
    required http.Client Function() httpClientFactory,
    required ce_cache.CacheDirectoryProvider cacheDirectoryProvider,
    super.maxNrOfCacheObjects = StorageHealth.normalImageCacheMaxObjects,
  }) : _cacheDirectoryProvider = cacheDirectoryProvider,
       super(
         stalePeriod: const Duration(days: 14),
         httpClientFactory: httpClientFactory,
         cacheDirectoryProvider: cacheDirectoryProvider,
         httpInterceptors: const [_ArtworkCredentialInterceptor()],
       );

  /// L-20: free the image disk cache now, when storage is low. Called
  /// from the startup gate after [StorageHealth.refresh]. A no-op when
  /// storage is healthy, so the normal path never empties the cache.
  /// This empties the cache (CE has no "trim to N objects" call — its
  /// only eviction is the construction-time cap, which a live manager
  /// cannot change); artwork re-downloads on demand, and the 500-object
  /// cap applies from the next cold start, when the manager is built
  /// after the refresh. Never throws.
  Future<void> applyLowStorageCap() async {
    if (!StorageHealth.isLowFreeSpace) return;
    try {
      await emptyCache();
    } catch (_) {
      // Best-effort: a cache that cannot be emptied is not a startup
      // failure — the construction-time cap still bounds regrowth.
    }
  }

  /// Static entry point for the startup gate: empties the shared
  /// manager's disk cache when storage is low.
  static Future<void> applyLowStorageCapIfLow() => instance.applyLowStorageCap();

  /// Byte-cap trim (1.6.34, P-10): CE evicts by OBJECT count only, so
  /// 3,000 large posters could be gigabytes. Lists the cache directory
  /// directly and deletes the least-recently-used files until the
  /// total is under the byte cap. [maxBytes] overrides the
  /// storage-state cap (tests); production always uses the cap. Never
  /// throws: a trim that cannot run leaves the cache alone, and the
  /// object cap still bounds it.
  ///
  /// Two honest limits of the file-system approach, both bounded:
  /// - CE's last-use stamp lives in its private Hive metadata, which
  ///   this layer cannot read — so "least recently used" is the file's
  ///   mtime, kept at last use by [getFileStream] below (a cache hit
  ///   touches the file). A file never read since download keeps its
  ///   download time, which is the right order for it.
  /// - Deleting a file directly leaves its Hive row behind (the row is
  ///   keyed by URL, and the filename is a one-way hash of it, so the
  ///   trim cannot map file to row). The row self-heals: CE deletes it
  ///   the next time the key is read and the file is missing. The trim
  ///   only deletes until under the cap, so the orphan count stays
  ///   small. Temp/backup files of an in-flight download are never
  ///   touched.
  Future<void> trimToByteCap({int? maxBytes}) async {
    try {
      final cap = maxBytes ?? imageDiskCacheMaxBytes(lowStorage: StorageHealth.isLowFreeSpace);
      final cacheDir = Directory('${(await _cacheDirectoryProvider()).path}/cached_network_image_ce');
      if (!await cacheDir.exists()) return;
      final files = <({File file, int bytes, DateTime modified})>[];
      await for (final entity in cacheDir.list()) {
        if (entity is! File) continue;
        if (entity.path.endsWith('.tmp') || entity.path.endsWith('.bak')) continue;
        final stat = await entity.stat();
        files.add((file: entity, bytes: stat.size, modified: stat.modified));
      }
      var totalBytes = 0;
      for (final file in files) {
        totalBytes += file.bytes;
      }
      if (totalBytes <= cap) return;
      // Least-recently-used first (mtime is kept at last use — see
      // getFileStream).
      files.sort((a, b) => a.modified.compareTo(b.modified));
      var removed = 0;
      for (final file in files) {
        if (totalBytes <= cap) break;
        try {
          await file.file.delete();
          totalBytes -= file.bytes;
          removed++;
        } catch (_) {
          // Best-effort per file: one undeletable file must not stop
          // the rest of the trim.
        }
      }
      if (removed > 0) {
        appLogger.i('IPTV: image disk cache trimmed to ${totalBytes}B (cap ${cap}B, removed $removed)');
      }
    } catch (_) {
      // Best-effort: a cache that cannot be trimmed is not a startup
      // or artwork failure — the object cap still bounds regrowth.
    }
  }

  /// Throttle for the background byte trim (1.6.34, P-10): at most one
  /// trim per interval, so a rail scroll does not re-list the cache on
  /// every artwork read. The trim itself never blocks the read — it
  /// runs in the background.
  DateTime? _lastByteTrimAt;
  static const _byteTrimMinInterval = Duration(minutes: 10);

  void _maybeTrimToByteCap() {
    final now = DateTime.now();
    if (_lastByteTrimAt != null && now.difference(_lastByteTrimAt!) < _byteTrimMinInterval) return;
    _lastByteTrimAt = now;
    unawaited(trimToByteCap());
  }

  /// Artwork URLs carry the server token in their query (see
  /// [redactArtworkUrl]), and the cache persists each entry's URL — and, with
  /// no explicit key, keys the entry by it — in plaintext metadata that
  /// outlives sign-out. Hand the cache the redacted URL and let
  /// [_ArtworkCredentialInterceptor] restore the real one for the download.
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) {
    // 1.6.34 (P-10): the byte cap is enforced in the background, at
    // most once per interval, so a long session cannot grow the cache
    // past the cap between cold starts.
    _maybeTrimToByteCap();
    final redacted = redactArtworkUrl(url);
    final stream = redacted == url
        ? super.getFileStream(url, key: key, headers: headers, withProgress: withProgress)
        : super.getFileStream(
            redacted,
            key: key ?? redacted,
            headers: {...?headers, _credentialedUrlHeader: url},
            withProgress: withProgress,
          );
    // 1.6.34 (P-10): keep the file's mtime at its last use, so the
    // byte trim above evicts least-recently-USED, not merely oldest —
    // CE's own last-use stamp lives in its private Hive metadata,
    // which this layer cannot read. A cache hit touches the file
    // (one utime, fire-and-forget — CE itself does a Hive write per
    // hit); a fresh download already carries today's mtime.
    return stream.map((response) {
      if (response is FileInfo && response.source == FileSource.Cache) {
        unawaited(_touchMtime(response.file.path));
      }
      return response;
    });
  }

  /// Best-effort mtime touch for the byte trim (1.6.34, P-10): a stale
  /// mtime only mis-orders one trim.
  static Future<void> _touchMtime(String path) async {
    try {
      await File(path).setLastModified(DateTime.now());
    } catch (_) {
      // Best-effort.
    }
  }

  @override
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  }) {
    // Plezy already requests server-sized artwork URLs. Avoid CE's disk-resize
    // path, which decodes downloaded images before writing resized PNG copies.
    return getFileStream(url, key: key, headers: headers, withProgress: withProgress);
  }
}

/// Query parameters that carry a media-server credential in artwork URLs:
/// Plex's `X-Plex-Token` and Jellyfin/Emby's `api_key`. Plex's photo
/// transcoder URLs also nest one inside their percent-encoded `url=` value.
final _artworkCredentialParam = RegExp(
  r'((?:X-Plex-Token|api_key|ApiKey)(?:=|%3D|%253D))[^&#%]+',
  caseSensitive: false,
);

/// [url] with every credential value blanked: what the artwork cache records.
@visibleForTesting
String redactArtworkUrl(String url) => url.replaceAllMapped(_artworkCredentialParam, (match) => match[1]!);

/// Request header carrying the credentialed URL from
/// [PlexImageCacheManager.getFileStream] to [_ArtworkCredentialInterceptor].
/// Never sent: the interceptor removes it.
const _credentialedUrlHeader = 'x-plezy-credentialed-url';

class _ArtworkCredentialInterceptor extends HttpInterceptor {
  const _ArtworkCredentialInterceptor();

  @override
  void onRequest(HttpRequestData request, HttpRequestHandler handler) {
    final credentialedUrl = request.headers.remove(_credentialedUrlHeader);
    if (credentialedUrl != null) request.url = credentialedUrl;
    handler.next(request);
  }
}

/// CE closes each factory-created client after a download. Wrap the app-wide
/// shared client so image requests reuse its platform transport without
/// transferring ownership of its lifecycle, and cap artwork fan-out globally.
class _SharedHttpClient extends http.BaseClient {
  final http.Client _inner;
  final _RequestLimiter _limiter;
  final Duration _unclaimedResponseTimeout;
  final Duration _stallTimeout;

  _SharedHttpClient(
    this._inner,
    this._limiter, {
    this._unclaimedResponseTimeout = const Duration(seconds: 2),
    this._stallTimeout = const Duration(seconds: 30),
  });

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final permit = await _limiter.acquire();
    var released = false;
    final abort = Completer<void>();

    void release() {
      if (released) return;
      released = true;
      permit.release();
    }

    void abortTransport() {
      if (!abort.isCompleted) abort.complete();
    }

    try {
      // CE sets no timeouts, so a server that accepts the connection but never
      // answers (or stops mid-body) would hold this slot forever, and once
      // every slot is stuck no artwork loads until restart. Give up after
      // [_stallTimeout] without progress and cancel the transfer.
      final sent = _inner.send(_abortable(request, abort.future));
      final response = await sent.timeout(
        _stallTimeout,
        onTimeout: () {
          abortTransport();
          // Transports without abort support may still answer later.
          unawaited(sent.then<void>((late) => _cancelUnclaimedBody(late.stream), onError: (Object _) {}));
          throw TimeoutException('Artwork response headers stalled', _stallTimeout);
        },
      );

      // CE's cache manager throws for any status other than 200/202 without
      // listening to the body, so _releaseWhenDone would never fire and the
      // permit would leak; six stale-thumb 404s then wedge all artwork loading
      // until restart (#1473). Release now, drain the (tiny) error body in the
      // background so the platform client reclaims the connection, and hand CE
      // an empty body it never reads anyway. Status set mirrors CE 4.6.4
      // _downloadFile; recheck if the pinned dep is ever bumped.
      if (response.statusCode != 200 && response.statusCode != 202) {
        release();
        unawaited(response.stream.drain<void>().catchError((_) {}));
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          response.statusCode,
          contentLength: 0,
          request: response.request,
          headers: response.headers,
          isRedirect: response.isRedirect,
          persistentConnection: response.persistentConnection,
          reasonPhrase: response.reasonPhrase,
        );
      }

      return http.StreamedResponse(
        _releaseWhenDone(
          response.stream,
          release,
          claimTimeout: _unclaimedResponseTimeout,
          stallTimeout: _stallTimeout,
          onStall: abortTransport,
        ),
        response.statusCode,
        contentLength: response.contentLength,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } catch (_) {
      release();
      rethrow;
    }
  }

  @override
  void close() {}
}

/// CE sends plain [http.Request]s; re-issue one as abortable so a stalled
/// transfer is cancelled at the transport instead of only being abandoned.
http.BaseRequest _abortable(http.BaseRequest request, Future<void> abortTrigger) {
  if (request is! http.Request || request is http.Abortable) return request;
  final abortable = http.AbortableRequest(request.method, request.url, abortTrigger: abortTrigger)
    ..headers.addAll(request.headers)
    ..followRedirects = request.followRedirects
    ..maxRedirects = request.maxRedirects
    ..persistentConnection = request.persistentConnection;
  if (request.bodyBytes.isNotEmpty) abortable.bodyBytes = request.bodyBytes;
  return abortable;
}

// ignore: unused-code
/// Test hook: builds the throttled artwork client with an isolated limiter.
@visibleForTesting
http.Client createArtworkHttpClientForTest(
  http.Client inner, {
  int maxConcurrent = 6,
  Duration unclaimedResponseTimeout = const Duration(seconds: 2),
  Duration stallTimeout = const Duration(seconds: 30),
}) => _SharedHttpClient(
  inner,
  _RequestLimiter(maxConcurrent),
  unclaimedResponseTimeout: unclaimedResponseTimeout,
  stallTimeout: stallTimeout,
);

Stream<List<int>> _releaseWhenDone(
  Stream<List<int>> stream,
  void Function() release, {
  required Duration claimTimeout,
  required Duration stallTimeout,
  required void Function() onStall,
}) {
  var claimed = false;
  var abandoned = false;

  // A cache request can be cancelled after response headers arrive but before
  // CE subscribes to the body (for example when a rail card is disposed).
  // An async* wrapper that is never listened to never enters its `finally`, so
  // without this guard the permit is lost permanently and artwork wedges once
  // every slot has leaked. Give CE ample time to claim the body, then release
  // the slot and cancel the orphaned transport request.
  final claimTimer = Timer(claimTimeout, () {
    if (claimed) return;
    abandoned = true;
    release();
    _cancelUnclaimedBody(stream);
  });

  return (() async* {
    if (abandoned) {
      throw http.ClientException('Artwork response body was abandoned before it was consumed');
    }
    claimed = true;
    claimTimer.cancel();
    try {
      await for (final chunk in stream.timeout(stallTimeout)) {
        yield chunk;
      }
    } on TimeoutException {
      onStall();
      rethrow;
    } finally {
      release();
    }
  })();
}

void _cancelUnclaimedBody(Stream<List<int>> stream) {
  try {
    final subscription = stream.listen((_) {}, onError: (_, _) {});
    unawaited(subscription.cancel().catchError((_) {}));
  } catch (_) {
    // The body may already have terminated while the timeout callback ran.
  }
}

class _RequestLimiter {
  final int maxConcurrent;
  final Queue<Completer<_RequestPermit>> _queue = Queue<Completer<_RequestPermit>>();
  int _active = 0;

  _RequestLimiter(this.maxConcurrent);

  Future<_RequestPermit> acquire() {
    if (_active < maxConcurrent) {
      _active++;
      return Future.value(_RequestPermit(this));
    }

    final completer = Completer<_RequestPermit>();
    _queue.add(completer);
    return completer.future;
  }

  void _release() {
    if (_queue.isNotEmpty) {
      _queue.removeFirst().complete(_RequestPermit(this));
      return;
    }
    if (_active > 0) _active--;
  }
}

class _RequestPermit {
  final _RequestLimiter _limiter;
  bool _released = false;

  _RequestPermit(this._limiter);

  void release() {
    if (_released) return;
    _released = true;
    _limiter._release();
  }
}
