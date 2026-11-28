import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;

import '../connection/connection.dart';
import '../exceptions/media_server_exceptions.dart';
import '../media/artist_discography.dart';
import '../media/download_resolution.dart';
import '../media/ids.dart';
import '../media/iptv_playlist_fingerprint.dart';

export '../media/iptv_playlist_fingerprint.dart' show iptvPlaylistFingerprint, iptvPlaylistRowHash;
import '../media/library_change_event.dart';
import '../media/library_filter_result.dart';
import '../media/library_genre.dart';
import '../media/library_query.dart';
import '../media/live_tv_support.dart';
import '../media/lyrics.dart';
import '../media/media_backend.dart';
import '../media/media_file_info.dart';
import '../media/media_hub.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_library.dart';
import '../media/media_person.dart';
import '../media/media_playlist.dart';
import '../media/media_role.dart';
import '../media/media_server_client.dart';
import '../media/media_sort.dart';
import '../media/media_source_info.dart';
import '../media/media_version.dart';
import '../media/playback_report_metadata.dart';
import '../media/server_capabilities.dart';
import '../models/livetv_channel.dart';
import '../services/api_cache.dart';
import '../services/base_shared_preferences_service.dart';
import '../services/device_performance.dart';
import '../services/iptv/iptv_catalog_cache.dart';
import '../services/iptv/iptv_call_pacer.dart';
import '../services/iptv/iptv_epg_sources.dart';
import '../services/lowend/epg_cadence_log.dart';
import '../services/lowend/phase_rss_sampler.dart';
import '../services/iptv/panel_reachability_store.dart';
import '../services/iptv/catalog_sync_foreground_service.dart';
import '../services/iptv/iptv_playback_activity.dart';
import '../services/iptv/iptv_heavy_work_gate.dart';
import '../services/iptv/iptv_search_index.dart';
import '../services/iptv/xtream_transport.dart';
import '../services/iptv/warp_tunnel_service.dart';
import '../services/iptv/metered_network.dart';
import '../services/settings_service.dart';
import '../services/storage_health.dart';
import '../services/playback_initialization_types.dart';
import '../utils/connectivity_link_type.dart';
import '../services/scrub_preview_source.dart';
import '../utils/app_logger.dart';
import '../utils/external_ids.dart';
import '../utils/iptv_initials.dart';
import '../utils/library_content_notifier.dart';
import '../utils/media_server_http_client.dart' show AbortController;
import 'iptv_live_tv.dart';
import 'watch_progress.dart';
import '../services/iptv/iptv_item_favorites_repository.dart';
import '../services/iptv/iptv_refusal_log.dart';
import '../services/iptv/iptv_resume_repository.dart';
import '../services/iptv/http_file_download.dart';
import '../services/iptv/m3u_parser.dart';
import '../services/iptv/xtream_api.dart';

/// One provider category (a Trex grouping) with its item count, for the
/// Categories tab that replaces Collections for IPTV libraries.
class IptvCategory {
  final String id;
  final String name;
  final int? itemCount;

  const IptvCategory({required this.id, required this.name, this.itemCount});
}

/// IPTV client: M3U playlists and Xtream Codes accounts behind the neutral
/// [MediaServerClient] surface.
///
/// The provider catalog is huge (tens of thousands of live channels,
/// hundreds of thousands of VOD rows), so nothing here ever hands the whole
/// catalog to the UI at once: libraries page through [LibraryPage], search
/// is client-side over a lazily loaded in-memory list, and live channels
/// are served only through [liveTv].
///
/// Only one stream may be open at a time on this account. This client never
/// opens a stream itself — [getPlaybackInitialization] and
/// [LiveTvSupport.startPlayback] hand out URLs and the player opens exactly
/// one of them. No prefetching, no preview probing.

/// Thrown by [_IptvClient._waitForIdleUnlessAborted] when the background
/// playback check finds a stream playing (build v1.0.13, R4, D4). Unlike
/// the foreground wait, a background run never waits for idle — it bails
/// so WorkManager can retry.
class _BackgroundPlaybackActive implements Exception {
  const _BackgroundPlaybackActive();
}

// The playlist fingerprint lives in iptv_playlist_fingerprint.dart
// (1.4.5 F0): it must be process-stable, so it is FNV-1a over UTF-8
// bytes in its own pure-Dart module — see the file for why
// Object.hash can never be used here. Re-exported above so existing
// importers keep working.

/// One type's download result (1.6.34, P-04): the fetch phase runs the
/// due types in parallel, so a fetch returns its outcome instead of
/// writing the shared [rows]/[skipped] maps directly. A null
/// [skipReason] means the download landed ([categories] +
/// [catalogFilePath] are set); a set reason means the type was skipped
/// in the fetch ('oversize' / 'failed') and the write phase records it
/// without writing. Cancellation is never an outcome — it rethrows, so
/// an aborted sync still aborts instead of returning a partial result
/// with a spurious 'failed'.
typedef _TypeFetchOutcome = ({
  String type,
  List<XtreamCategory>? categories,
  String? catalogFilePath,
  int fetchMs,
  int requests,
  String? skipReason,
  bool isTransportError,
});

class IptvClient implements MediaServerClient {
  /// The connection this client serves. Replaced only via
  /// [updateConnection] (build #17): a filter toggle re-binds the same
  /// connection with new filter state, and the client keeps its warm
  /// catalogs instead of being replaced with a cold one. The catalogs
  /// belong to the data source (server + credentials), not to the
  /// filter — filtering happens at read time — so they stay valid.
  Connection connection;

  IptvClient.m3u({required M3uConnection m3uConnection}) : connection = m3uConnection;
  IptvClient.xtream({required XtreamConnection xtreamConnection}) : connection = xtreamConnection;

  factory IptvClient.forConnection(Connection connection) {
    // Test seam: when set, the factory's client is used instead of a fresh
    // one — widget tests point it at a client backed by a fake API, so
    // screens that create their own client (the initials checklist) can
    // load catalogs without the network. Always null in production;
    // tests must clear it in tearDown.
    final debugFactory = debugClientFactory;
    if (debugFactory != null) return debugFactory(connection);
    return switch (connection) {
      M3uConnection() => IptvClient.m3u(m3uConnection: connection),
      XtreamConnection() => IptvClient.xtream(xtreamConnection: connection),
      _ => throw UnsupportedError('IptvClient cannot wrap ${connection.runtimeType}'),
    };
  }

  /// Swap the served connection for [next] (build #17): a filter toggle
  /// (or a display-only edit) re-binds the same connection, and the
  /// client keeps its warm in-memory catalogs, its in-flight loads, and
  /// its disk-cache handles instead of re-paying all three warm-ups
  /// (parse alone is ~1.3–1.5 s at Trex scale, before network, health
  /// probe and tab/guide reloads — that cascade is the toggle lag).
  ///
  /// Only the filter/display fields may differ. Throws [ArgumentError]
  /// when the id or the data source differs (Xtream: server URL /
  /// username / password; M3U: playlist URL / EPG URL) — the caller must
  /// replace the client instead, because the warm catalogs belong to the
  /// old data source. The lazily-built [_xtreamApi] stays valid because
  /// the data source is unchanged.
  void updateConnection(Connection next) {
    if (next.id != connection.id) {
      throw ArgumentError('IptvClient.updateConnection: id changed (${connection.id} -> ${next.id})');
    }
    if (!_sameDataSource(connection, next)) {
      throw ArgumentError('IptvClient.updateConnection: data source changed for ${connection.id}');
    }
    final oldHiddenIds = _hiddenCategories;
    final oldHiddenInitials = _hiddenCategoryInitials;
    connection = next;
    // 1.2.4 (catalog memory): the memos hold visible rows only, so a
    // filter change re-derives them from disk in the background — no
    // network, and no toggle lag (the stale memos keep serving until
    // the re-warm lands and notifies; build #17's instant toggle is
    // preserved). Rows still on disk come back instantly; rows pruned
    // from disk come back only after a re-sync — the categories screen
    // says so with a Refresh action when a toggle un-hides a pruned
    // category.
    if (_isXtream &&
        (!setEquals(oldHiddenIds, _hiddenCategories) ||
            !setEquals(oldHiddenInitials, _hiddenCategoryInitials))) {
      // 1.6.32, option 6: the filter changed — a new generation, so a
      // guide load already in flight does not mistake the re-derive
      // completion for this change as a second change.
      _filterGeneration++;
      // 1.6.32, option 2: a hide-only change (the hidden sets only
      // grew — nothing was un-hidden) can filter the cached guide list
      // in Dart instead of invalidating it and re-reading 26k rows.
      final hideOnly = _hiddenCategories.containsAll(oldHiddenIds) &&
          _hiddenCategoryInitials.containsAll(oldHiddenInitials);
      unawaited(_rederiveMemosFromDisk(hideOnly: hideOnly));
    }
  }

  /// Re-derive the visible memos from disk after a filter toggle
  /// (1.2.4): re-run the private disk warm-ups with force — NOT the
  /// public warm-ups, which would also re-fire the FTS seed (a toggle
  /// must not re-seed the index). The stale memos keep serving until
  /// the re-warm lands; the notification then reloads the tabs with
  /// the fresh memos. A category hidden after its rows landed is
  /// dropped from the memos; a category un-hidden while its rows are
  /// still on disk comes back with no network at all.
  ///
  /// 1.2.11: only the memos that are actually loaded (or loading) are
  /// re-derived — the index path re-reads with the new hidden sets and
  /// needs no re-derive, so a toggle with no memo loaded does no work
  /// at all and never loads a memo just to re-derive it.
  ///
  /// 1.6.32: the toggle-time re-derive is where the freeze lived — the
  /// guide rebuild ran synchronously on the UI thread while the memos
  /// re-parsed in the background. The re-derive now (option 2) filters
  /// the cached guide list in Dart on a hide-only toggle, and
  /// (option 9) drops the VOD/series memos instead of re-deriving
  /// them — the index path serves those reads with the new hidden
  /// sets, and the next memo-path read re-warms from disk on demand.
  /// 1.6.34 (P-08): the live memo is re-derived even while a sync
  /// runs elsewhere or memory is hot (the old options 3 and 7 skips
  /// are gone) — see the note inside.
  Future<void> _rederiveMemosFromDisk({bool hideOnly = false}) async {
    // 1.6.32, option 2: a hide-only toggle filters the cached guide
    // list in Dart instead of invalidating it and re-reading 26k rows
    // from SQLite — the cached list is the visible set, and hiding
    // only removes rows from it. The key→index map is rebuilt from
    // the filtered list, and the C-1 stamps stay: the index
    // generation did not change, so a later iptvChannels() over this
    // same index serves the filtered list without a re-read. An
    // un-hide still invalidates — the hidden rows are not in the
    // cached list to filter back in.
    if (hideOnly && _cachedGuideChannels != null) {
      final liveCategoryNames = await _liveCategoryNames();
      final filtered = _cachedGuideChannels!
          .where((c) => !_isHiddenCategory(c.categoryId, liveCategoryNames[c.categoryId]))
          .toList(growable: false);
      _cachedGuideChannels = filtered;
      _cachedGuideChannelIndex = {
        for (var i = 0; i < filtered.length; i++) filtered[i].key: i,
      };
    } else {
      // 1.2.18 C-1: a filter change changes the index-path list, so the
      // cached guide list goes with the memos.
      _invalidateGuideChannelCache();
    }
    // 1.6.34 (P-08): the live memo is re-derived even while a catalog
    // sync is running in another isolate or memory is hot — the old
    // skips left it stale after an un-hide until the next cool toggle
    // or sync, so un-hidden rows did not come back (the guide's cold
    // fallback reads the memo). The re-derive reads the DISK file, not
    // the index, so it cannot fight the sync's SQLite writes; it pays
    // a main-isolate parse at a bad time, and while memory is hot that
    // parse may itself be evicted — the tradeoff the "build
    // everything" pick accepts for a memo that is never stale. The
    // sync's own landing still drops the memos (see
    // [_refreshCatalogAfterSync]), so a re-derive racing a landing is
    // benign either way: whichever lands last, the next read is fresh
    // (and the memo-fresher check guards a memo older than the index).
    // The VOD/series memos are still only DROPPED (option 9, below),
    // never re-derived: their re-derive is the 199k-row parse the
    // freeze came from, and the index path serves those reads anyway.
    // 1.6.32, option 9: the VOD/series memos are DROPPED on a filter
    // change instead of re-derived — the same drop-not-republish shape
    // as [_refreshCatalogAfterSync]: re-deriving them deserializes up
    // to 199k rows onto the main isolate per toggle, and the index
    // path serves those reads with the new hidden sets anyway. The
    // next memo-path read re-warms from disk on demand. The category
    // futures stay — the category lists did not change, only which
    // of them are hidden. The live memo is still re-derived (26k
    // rows, and the guide's cold fallback reads it).
    if (_vodStreamsFuture != null) {
      _vodStreamsFuture = null;
      _vodById = null;
      _vodStreamsLoaded = false;
    }
    if (_seriesFuture != null) {
      _seriesFuture = null;
      _seriesById = null;
      _seriesListLoaded = false;
    }
    final futures = <Future<void>>[];
    if (_liveStreamsFuture != null) futures.add(_warmLiveCatalogFromDisk(force: true));
    if (futures.isEmpty) return;
    final future = Future.wait(futures);
    _rederiveMemosFuture = future;
    unawaited(
      future.then((_) {
        if (!_closed) notifyCatalogRefreshed(userInitiated: true);
      }),
    );
  }

  /// True when any of [categoryIds] — just un-hidden — has no rows in
  /// the re-derived memos (1.2.4): the rows were pruned from disk/index
  /// by an earlier hidden state, so only a re-sync brings them back.
  /// The caller shows the notice with a Refresh action. Rows still on
  /// disk come back in the re-derive, so this is false for them. Awaits
  /// the in-flight re-derive first, so the check reads the fresh memos.
  ///
  /// 1.2.11: when the index is warm for all three types the check reads
  /// the grouped index counts instead — no memo load, no network. The
  /// all-three-warm gate matters: a cold type's grouped count is empty
  /// for rows the disk still holds, which would wrongly report a
  /// refresh as needed, so a cold type falls back to the memo path.
  Future<bool> unhiddenCategoriesNeedRefresh(Set<String> categoryIds) async {
    if (categoryIds.isEmpty || !_isXtream) return false;
    final index = await _searchIndex();
    if (index != null) {
      final counts = index.rowCounts(connection.id);
      final allWarm = IptvSearchIndex.types.every((t) => (counts[t] ?? 0) > 0);
      if (allWarm) {
        // The check is about STORAGE, not visibility: the rows for a
        // just-un-hidden category are in the index or they were pruned
        // by an earlier hidden state. The current hidden sets must not
        // filter the count — a category still hidden at check time
        // would otherwise read as "no rows" even when its rows are
        // sitting in the index (the memo path had the same shape: it
        // asked whether the loaded rows contain the category, and the
        // caller only calls this right after un-hiding).
        for (final type in IptvSearchIndex.types) {
          final grouped = index.countByCategoryGrouped(
            connection.id,
            type,
            hiddenIds: const {},
            hiddenInitials: const {},
          );
          if (categoryIds.any((id) => (grouped[id] ?? 0) > 0)) return false;
        }
        return true;
      }
    }
    await _rederiveMemosFuture;
    final live = await _liveStreams();
    final vod = await _vodStreams();
    final series = await _seriesList();
    return !live.any((s) => categoryIds.contains(s.categoryId)) &&
        !vod.any((s) => categoryIds.contains(s.categoryId)) &&
        !series.any((s) => categoryIds.contains(s.categoryId));
  }

  /// True when a favourite/resume snapshot's item needs a catalog
  /// refresh to come back (1.2.4): the snapshot's category is currently
  /// VISIBLE, but the item does not resolve from the memo or the index
  /// — so it was pruned by an earlier hidden state, and a re-sync would
  /// bring it back (or prove it left the panel). False when the category
  /// is still hidden (correctly pruned — no refresh would help) or the
  /// snapshot has no category (a legacy row saved before 1.2.4 recorded
  /// none). [kind] is the snapshot kind ('movie' | 'series' | 'live' |
  /// 'episode') — it picks which category-name map resolves the name.
  Future<bool> itemNeedsCatalogRefresh({
    required String id,
    required String kind,
    required String? categoryId,
  }) async {
    if (categoryId == null || !_isXtream) return false;
    final categoryName = await _categoryNameFor(kind, categoryId);
    if (isCategoryHidden(categoryId, categoryName)) return false;
    // 1.2.17: a first load against a failing panel (fresh install, no
    // disk cache) throws here — the notice is a convenience, never a
    // failure: fail closed (no notice) instead of throwing.
    try {
      return await fetchItem(id) == null;
    } catch (e) {
      appLogger.w('IPTV: refresh check for $id could not resolve: $e');
      return false;
    }
  }

  /// Category name for a snapshot kind (1.2.4): the episode kind shares
  /// the series map. Null when the name cannot be resolved — the caller
  /// then judges by the id switch only.
  Future<String?> _categoryNameFor(String kind, String categoryId) async {
    try {
      final names = switch (kind) {
        'movie' => await _vodCategoryNames(),
        'series' || 'episode' => await _seriesCategoryNames(),
        'live' => await _liveCategoryNames(),
        _ => const <String, String>{},
      };
      return names[categoryId];
    } catch (_) {
      return null;
    }
  }

  static bool _sameDataSource(Connection a, Connection b) {
    if (a is XtreamConnection && b is XtreamConnection) {
      return a.serverUrl == b.serverUrl && a.username == b.username && a.password == b.password;
    }
    if (a is M3uConnection && b is M3uConnection) {
      return a.playlistUrl == b.playlistUrl && a.epgUrl == b.epgUrl;
    }
    return false;
  }

  @visibleForTesting
  static IptvClient Function(Connection connection)? debugClientFactory;

  bool get _isXtream => connection is XtreamConnection;
  XtreamConnection get _xtream => connection as XtreamConnection;
  M3uConnection get _m3u => connection as M3uConnection;

  /// User-given library name (the base [Connection] type has no `name`).
  String get _name => switch (connection) {
    M3uConnection(:final name) => name,
    XtreamConnection(:final name) => name,
    _ => connection.displayName,
  };

  /// Country/region filter list (only the IPTV connection types carry it).
  List<String> get _hiddenCategoryIdList => switch (connection) {
    M3uConnection(:final hiddenCategoryIds) => hiddenCategoryIds,
    XtreamConnection(:final hiddenCategoryIds) => hiddenCategoryIds,
    _ => const [],
  };

  XtreamApi? _api;

  XtreamApi get _xtreamApi {
    if (_api != null) return _api!;
    // 1.6.15 (WARP tunnel): register the panel host with the tunnel
    // service before any request goes out on it, so the host-aware
    // proxy (artwork, shared platform client) knows this host is
    // provider traffic. The Xtream transport itself uses the
    // unconditional provider proxy, so its requests never leak direct
    // for a host that was never registered.
    final panelHost = Uri.tryParse(_xtream.serverUrl)?.host ?? '';
    if (panelHost.isNotEmpty) {
      WarpTunnelService.instance.registerProviderHost(panelHost);
    }
    return _api = XtreamApi(
    serverUrl: _xtream.serverUrl,
    username: _xtream.username,
    password: _xtream.password,
    // 1.6.13 (R1: Cronet behind Super Spoof): the transport reads the
    // master toggle per request — flipping Settings → Advanced →
    // Super Spoof switches the Xtream requests between Dart's client
    // and Chrome's network stack without rebuilding the client (or
    // restarting the app). The background isolate has no SettingsService,
    // so its provider reads OFF and the sync keeps Dart's client.
    // 1.6.13 (H1: IPv4-preference): the transport also reads the
    // IPv4-preference per request — flipping Settings → Advanced →
    // Prefer IPv4 switches the Xtream requests to the IPv4-only Dart
    // client. IPv4 wins over Cronet when both are on.
    // 1.6.14 (unified spoof): the transport is a Super Spoof
    // sub-setting of its own (Dart / IPv4-only / Cronet / Platform
    // (Android)) — the master no longer bundles Cronet in with the UA
    // mimic. The transport choice is re-read per request like the
    // toggles, so flipping it applies to the next request.
    // 1.6.15 (WARP tunnel): the transport also reads the tunnel per
    // request — while it is on, Cronet is forced off (it has no proxy
    // API) and the other transports ride the local proxy.
    httpClient: XtreamTransportClient(
      superSpoofOn: _superSpoofOn,
      preferIpv4On: _preferIpv4On,
      transportChoice: _superSpoofTransport,
      tunnelOn: _tunnelOn,
    ),
    // Build #20: the User-Agent is re-read from Settings on every request,
    // so changing Settings → IPTV → Xtream User-Agent applies to the next
    // request without rebuilding the client (or restarting the app).
    userAgentProvider: _userAgentProviderOverride ?? _xtreamUserAgent,
    // 1.6.11 (Super Spoof): the headers piece, re-read per request like
    // the UA — flipping the toggle applies to the next request without
    // rebuilding the client (or restarting the app).
    mimicHeadersProvider: _mimicHeadersProviderOverride ?? _superSpoofHeaders,
    // 1.6.12 (MPEG-TS live streams): re-read per URL build like the UA —
    // flipping Settings → Advanced → Request live TV as MPEG-TS applies
    // to the next channel open without rebuilding the client.
    preferTsProvider: _preferTsProviderOverride ?? _preferTs,
    // Build #27: every refused response and transport failure is handed
    // to the refusal log (Settings → IPTV → Connection refusals) with
    // its headers and body — the 403 the app used to discard is the
    // diagnostic. Record-only: the exception the caller sees is
    // unchanged, and no request is added.
    onRefusal: (entry) => IptvRefusalLog.instance.record(entry),
    // 1.4.3 C3: the 403 circuit breaker reads the same log — a 403
    // recorded for this connection within the cooldown window means
    // every panel call site stands down instead of re-firing.
    recent403Provider: _isIn403Cooldown,
    connectionId: connection.id,
    connectionName: _name,
  );
  }

  /// Override for the Xtream User-Agent provider (build v1.0.13, R4):
  /// the background isolate has no SettingsService, so the callback
  /// resolves the user's UA from SharedPreferences directly and hands
  /// it in here before the first request. Must be set before the lazy
  /// [_xtreamApi] builds; the override wins over [_xtreamUserAgent].
  String Function()? _userAgentProviderOverride;

  /// See [_userAgentProviderOverride].
  set userAgentProvider(String Function() provider) => _userAgentProviderOverride = provider;

  /// Override for the Super Spoof headers provider (1.6.11): the
  /// background isolate has no SettingsService, so the callback resolves
  /// the headers piece from SharedPreferences directly and hands it in
  /// here before the first request. Must be set before the lazy
  /// [_xtreamApi] builds; the override wins over [_superSpoofHeaders].
  bool Function()? _mimicHeadersProviderOverride;

  /// See [_mimicHeadersProviderOverride].
  set mimicHeadersProvider(bool Function() provider) => _mimicHeadersProviderOverride = provider;

  /// Override for the MPEG-TS live-stream provider (1.6.12): tests hand
  /// the switch in here before the first URL build; the override wins
  /// over [_preferTs].
  bool Function()? _preferTsProviderOverride;

  /// See [_preferTsProviderOverride].
  set preferTsProvider(bool Function() provider) => _preferTsProviderOverride = provider;

  /// The User-Agent the next request will carry, exposed for callers that
  /// fetch without an [XtreamApi] (1.6.12): the M3U feed fetch wears the
  /// same identity instead of Dart's default — an M3U playlist's guide
  /// URL is usually the same provider. Same value [_xtreamApi] uses.
  static String get effectiveUserAgent => _xtreamUserAgent();

  /// The configured Xtream User-Agent for this client's requests (build
  /// #20), with Super Spoof applied (1.6.11): when the master toggle is
  /// on and the UA piece picks a name, the mimic value wins over the
  /// normal choice — one toggle, whole disguise. 1.6.14: the mimic list
  /// is the same list as the base choice, Custom included, and the
  /// custom text is one shared pref — picking Custom in either list
  /// sends the same text. Falls back to the player default when
  /// Settings is not initialized yet (tests) or the stored choice is
  /// unknown — a request must never go out with no User-Agent.
  static String _xtreamUserAgent() {
    final fallback = _normalXtreamUserAgent();
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return fallback;
    return XtreamSuperSpoof.resolveUserAgent(
      masterOn: settings.read(SettingsService.iptvSuperSpoof),
      userAgentChoice: settings.read(SettingsService.iptvSuperSpoofUserAgent),
      customUserAgent: settings.read(SettingsService.iptvXtreamUserAgentCustom),
      fallbackUserAgent: fallback,
    );
  }

  /// The normal Xtream User-Agent choice, without Super Spoof.
  static String _normalXtreamUserAgent() {
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return XtreamUserAgent.player;
    return XtreamUserAgent.resolve(
      settings.read(SettingsService.iptvXtreamUserAgent),
      settings.read(SettingsService.iptvXtreamUserAgentCustom),
    );
  }

  /// Super Spoof (1.6.13 R1): the master toggle is on — the transport
  /// reads it per request, so flipping it switches the Xtream requests
  /// between Dart's client and Cronet. False when Settings is not
  /// initialized (tests, background isolate) — the requests stay on Dart.
  static bool _superSpoofOn() {
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return false;
    return settings.read(SettingsService.iptvSuperSpoof);
  }

  /// Super Spoof (1.6.14): the transport sub-setting — which network
  /// stack the Xtream requests ride while the master is on. False when
  /// Settings is not initialized (tests) — the requests stay on Dart.
  /// The stored choice itself (default 'cronet', the master rode
  /// Cronet since 1.6.13); the transport applies the master gate and
  /// the Prefer IPv4 win per request.
  static String _superSpoofTransport() {
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return SettingsService.iptvSuperSpoofTransport.defaultValue;
    return settings.read(SettingsService.iptvSuperSpoofTransport);
  }

  /// Prefer IPv4 (1.6.13 H1): the IPv4-preference is on — the transport
  /// reads it per request, so flipping it switches the Xtream requests
  /// to the IPv4-only Dart client. False when Settings is not
  /// initialized (tests, background isolate) — the requests stay on the
  /// plain Dart client.
  static bool _preferIpv4On() {
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return false;
    return settings.read(SettingsService.iptvPreferIpv4);
  }

  /// WARP tunnel (1.6.15): the tunnel is up — the transport reads it
  /// per request, so while it is on, Cronet is forced off (it has no
  /// proxy API) and the other transports ride the local proxy. False
  /// when the tunnel is off (the default) — the requests go out exactly
  /// as before.
  static bool _tunnelOn() => WarpTunnelService.instance.isOn;

  /// Super Spoof (1.6.11): the headers piece is active — master toggle
  /// on and the headers sub-setting on. False when Settings is not
  /// initialized (tests) — the mimic never leaks into a test that never
  /// asked for it.
  static bool _superSpoofHeaders() {
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return false;
    return settings.read(SettingsService.iptvSuperSpoof) &&
        settings.read(SettingsService.iptvSuperSpoofHeaders);
  }

  /// Super Spoof (1.6.11): the streams piece is active — master toggle
  /// on and the streams sub-setting on.
  static bool _superSpoofStreams() {
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return false;
    return settings.read(SettingsService.iptvSuperSpoof) &&
        settings.read(SettingsService.iptvSuperSpoofStreams);
  }

  /// MPEG-TS live streams (1.6.12): Settings → Advanced → Request live TV
  /// as MPEG-TS. False when Settings is not initialized (tests) — HLS
  /// stays the default unless the switch is on.
  static bool _preferTs() {
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return false;
    return settings.read(SettingsService.iptvLiveTs);
  }

  /// The User-Agent for stream/artwork opens: the spoof-aware value when
  /// the streams piece is on, the normal choice when it is off — the
  /// piece decides whether the disguise applies here at all.
  static String _streamUserAgent() {
    if (!_superSpoofStreams()) return _normalXtreamUserAgent();
    return _xtreamUserAgent();
  }

  /// Headers for a direct (non-API) fetch from this panel — stream opens
  /// and artwork — under the Super Spoof pieces (1.6.11): the mimic UA
  /// when the UA piece picks one (and the streams piece is on), plus the
  /// generic Accept and the keep-alive line when the headers piece is
  /// on too (1.6.14: the keep-alive line is the exactly-one-header gap
  /// between Dart and the platform stack).
  static Map<String, String> _directFetchHeaders() {
    final headers = <String, String>{'User-Agent': _streamUserAgent()};
    if (_superSpoofStreams() && _superSpoofHeaders()) {
      headers['Accept'] = XtreamSuperSpoof.acceptHeader;
      headers['Connection'] = XtreamSuperSpoof.connectionHeaderValue;
    }
    return headers;
  }

  /// Public view of the Xtream API for the live-TV support (EPG fetches).
  XtreamApi get xtreamApi => _xtreamApi;

  /// The tvg-id of the M3U entry behind [channelKey] (the key IS the tvg-id
  /// when the entry has one), or null when the channel has no tvg-id or is
  /// not an M3U channel. The EPG layer matches XMLTV `<programme>` rows
  /// against this id.
  String? tvgIdForChannelKey(String channelKey) => _m3uChannelByKey[channelKey]?.tvgId;

  /// The tvg-id (`epg_channel_id`) of the Xtream channel behind
  /// [channelKey], for matching the xmltv.php feed (some panels use the
  /// stream id as the XMLTV channel id, so the guide path also tries the
  /// key itself). Null when the channel is not a known Xtream channel.
  String? epgChannelIdForChannelKey(String channelKey) => _xtreamChannelByKey[channelKey]?.epgChannelId;

  /// The display name of a live channel by its key (build #17, §10) —
  /// the EPG name-fallback match. Xtream: the stream name; M3U: the
  /// entry name. Null when the key is unknown.
  String? channelNameForChannelKey(String channelKey) {
    if (_isXtream) return _xtreamChannelByKey[channelKey]?.name;
    return _m3uChannelByKey[channelKey]?.name;
  }

  /// Test-only override for the Xtream API, so unit tests can stub the
  /// catalog instead of hitting the network. Production code never sets this.
  @visibleForTesting
  set testXtreamApi(XtreamApi api) => _api = api;

  /// The M3U playlist client (1.6.28 G4): built through the tunnel
  /// proxy, so the M3U health HEAD rides the tunnel when it is on and
  /// goes direct when it is off — like the Xtream health branch beside
  /// it. The proxy is resolved per request from the live tunnel state,
  /// so a long-lived client follows tunnel on/off transitions.
  http.Client _http = WarpTunnelService.instance.proxiedHttpClient();
  final Object _authSessionId = Object();

  /// Test-only override for the HTTP client, so unit tests can serve a
  /// canned M3U playlist instead of hitting the network. Production code
  /// never sets this.
  @visibleForTesting
  set testHttpClient(http.Client client) => _http = client;
  bool _offline = false;
  late final IptvLiveTvSupport _liveTv = IptvLiveTvSupport(this);

  // In-memory catalog caches (lazy; the provider lists are large).
  Future<List<XtreamLiveStream>>? _liveStreamsFuture;
  Future<List<XtreamVodStream>>? _vodStreamsFuture;
  Future<List<XtreamSeries>>? _seriesFuture;

  /// By-id index for the memoized series list (A8): lookups used to
  /// linearly scan the whole list (46,461 series on this provider) on
  /// every call. Built once from the loaded list (see [_seriesByIdMap]),
  /// cleared wherever the memo is cleared — never served across a
  /// catalog clear or reload.
  Map<int, XtreamSeries>? _seriesById;

  /// By-id index for the memoized VOD list (1.6.11 P10): same shape as
  /// [_seriesById] — the movie branch of [fetchItem] used to linearly
  /// scan the whole memo (199k rows on this provider) on every
  /// cold-index detail open. Built once from the loaded list (see
  /// [_vodByIdMap]), cleared wherever the memo is cleared.
  Map<int, XtreamVodStream>? _vodById;

  /// The in-flight toggle re-derive (1.2.4, see
  /// [_rederiveMemosFromDisk]): [unhiddenCategoriesNeedRefresh] awaits
  /// it so the check reads the fresh memos, not the stale ones.
  Future<void>? _rederiveMemosFuture;

  // Disk catalog cache (build #11): raw API payloads under the app
  // documents directory, per connection — a cold start reads these
  // instead of re-fetching tens of thousands of rows. See
  // [_readDiskCatalog] / [_refreshCatalogViaSyncIfDue].
  static const _catalogCache = IptvCatalogDiskCache();

  /// Generation guard for background refreshes: bumped by
  /// [clearCatalogCache], so a refresh started before a clear can never
  /// resurrect the cleared catalog (memory or disk).
  int _catalogGeneration = 0;

  /// Whether a FULL catalog load has completed with rows (build #9 Task 1).
  /// A future that is merely in flight — or that resolved empty — does not
  /// count: the Enter path reads the memoized list only when it is loaded,
  /// else the disk file (R2.3) — it never awaits a load that may take
  /// minutes on a 46k-row catalog.
  bool _vodStreamsLoaded = false;
  bool _seriesListLoaded = false;
  bool _liveStreamsLoaded = false;

  /// Where the last catalog load came from (build #18): 'disk', 'network'
  /// or 'crawl'. The search diagnostics render it, so a poisoned disk is
  /// visible on the phone: a disk list written from a per-category crawl
  /// lacks every category hidden when it was written. '' before any load.
  String _vodLoadSource = '';
  String _seriesLoadSource = '';
  String _liveLoadSource = '';

  /// Rows published so far by an in-flight per-category crawl (build #13):
  /// [_loadVodStreams]/[_loadSeries] append each batch as it lands, so a
  /// cold search can read rows long before the whole catalog completes —
  /// the crawl's partial progress used to be invisible to search, which
  /// is why a cold search on a slow connection returned [] although the
  /// match existed on the panel. Cleared when the full load completes
  /// (the memoized list subsumes them) and by [clearCatalogCache]. The
  /// covered-category sets record what the crawl already fetched.
  final List<XtreamVodStream> _vodPartialRows = [];
  final List<XtreamSeries> _seriesPartialRows = [];
  final Set<String> _vodCrawledCategoryIds = {};
  final Set<String> _seriesCrawledCategoryIds = {};

  /// Readout for the LAST search run on this client (build #13): the
  /// query, the scope, and per section which source supplied the results
  /// and how long each leg took. The IPTV settings diagnostics row shows
  /// it, so one screenshot settles where a search dies instead of a
  /// fourth guessed fix. Null until the first search.
  IptvSearchDiagnostics? _lastSearchDiagnostics;

  /// The last search's readout, for the on-device diagnostics row.
  IptvSearchDiagnostics? get lastSearchDiagnostics => _lastSearchDiagnostics;

  /// Matches the last search found but the hidden-category filter
  /// removed, for one library (build #17): the search screen's empty
  /// state tells the user the filter hid them instead of showing a bare
  /// "No results". 0 when there was no search yet, or when the library
  /// is not one of this connection's movies/series libraries.
  int lastSearchHiddenMatchesForLibrary(String libraryId) {
    final diagnostics = _lastSearchDiagnostics;
    if (diagnostics == null) return 0;
    if (libraryId == _seriesLibraryId) return diagnostics.series.hiddenMatches;
    if (libraryId == _moviesLibraryId) return diagnostics.movies.hiddenMatches;
    if (libraryId == _liveLibraryId) return diagnostics.live.hiddenMatches;
    return 0;
  }

  /// The letter-group initials that hid the last search's matches, for
  /// one library (v1.1.0): the search screen's empty state names the
  /// hiding group instead of only counting. Empty when there was no
  /// search yet, when nothing was hidden, or when the library is not
  /// one of this connection's libraries.
  List<String> lastSearchHiddenGroupsForLibrary(String libraryId) {
    final diagnostics = _lastSearchDiagnostics;
    if (diagnostics == null) return const [];
    if (libraryId == _seriesLibraryId) return diagnostics.series.hiddenInitials;
    if (libraryId == _moviesLibraryId) return diagnostics.movies.hiddenInitials;
    if (libraryId == _liveLibraryId) return diagnostics.live.hiddenInitials;
    return const [];
  }

  // -- Local search index (build #23) -------------------------------------
  //
  // The whole catalog is synced once into a local SQLite FTS5 trigram
  // index ([IptvSearchIndex]), and search queries it instead of the
  // provider — zero panel requests during a search when the index is
  // warm. The index is derived/rebuildable cache data in its own file,
  // so it can never touch the main database; a broken index just reads
  // as cold and the search falls back to the disk/sync paths (R2.3).
  //
  // The index is opened lazily (first search/sync/seed) and shared by
  // the client's search, sync and seed paths. Writes (sync + disk seed)
  // run in a background isolate via compute and are serialized by
  // [_runIndexWrite] — the seed and the sync never write at once.

  Future<IptvSearchIndex?>? _searchIndexFuture;
  IptvSearchIndex? _searchIndexInstance;

  /// L-33: true while this client runs a background-isolate sync — its
  /// index connection is a second reader beside the compute() writer,
  /// so it opens with the small writer cache + a 2 s busy timeout
  /// instead of the full read budget. Only set by
  /// [syncSearchIndexForBackground]; a background client is
  /// single-purpose, so it is never unset.
  bool _backgroundSyncIndex = false;

  /// True once [close] has run: in-flight seeds/syncs must not touch
  /// the notifier (or re-open the index) after teardown.
  bool _closed = false;

  /// The single in-flight index write (seed or sync), if any. A second
  /// writer joins this future instead of starting its own — the seed
  /// (warm-up) and the sync (bind/manual refresh) serialize through it.
  Future<void>? _indexWriteInFlight;

  /// Types whose cold-search seed is already in flight (1.2.18 C-5):
  /// a second keystroke while the seed runs must not queue another
  /// seed behind it — the first seed warms the type for all later
  /// keystrokes.
  final Set<String> _coldSearchSeedInFlight = {};

  /// The index state the search screen's catalog-health line and the
  /// settings cache-size row read. Updated when the index opens, when a
  /// seed/sync starts, and when one lands.
  final ValueNotifier<IptvSearchIndexState> searchIndexStateNotifier =
      ValueNotifier(const IptvSearchIndexState.empty());

  /// The current index state (same value as [searchIndexStateNotifier]).
  IptvSearchIndexState get searchIndexState => searchIndexStateNotifier.value;

  /// The index, opened on first use. Null when this client is M3U (no
  /// VOD/series catalog to index — its playlist search is already
  /// local-only) or when the index is disabled for tests.
  Future<IptvSearchIndex?> _searchIndex() {
    final existing = _searchIndexFuture;
    if (existing != null) return existing;
    final future = () async {
      if (_closed) return null;
      if (!_isXtream || IptvSearchIndex.debugDisableDisk || IptvCatalogDiskCache.debugDisableDisk) return null;
      try {
        final index = await IptvSearchIndex.open(lowMemory: _backgroundSyncIndex);
        _searchIndexInstance = index;
        _refreshSearchIndexState();
        return index;
      } catch (e) {
        appLogger.w('IPTV: search index unavailable, search falls back to disk/sync: $e');
        return null;
      }
    }();
    _searchIndexFuture = future;
    return future;
  }

  /// Re-read the index meta (row counts + last sync) into the notifier.
  /// Never throws — a broken index reads as empty. No-op after [close]
  /// (an in-flight seed/sync's finally must not touch a disposed
  /// notifier).
  void _refreshSearchIndexState({bool syncing = false, bool seeding = false}) {
    if (_closed) return;
    final index = _searchIndexInstance;
    if (index == null) return;
    try {
      searchIndexStateNotifier.value = IptvSearchIndexState(
        rowCounts: index.rowCounts(connection.id),
        lastSync: index.lastSync(connection.id),
        syncing: syncing,
        seeding: seeding,
      );
    } catch (e) {
      appLogger.w('IPTV: search index state unreadable', error: e);
    }
  }

  /// Run [work] as the single index write (seed or sync). A second
  /// caller waits for the in-flight write, then runs its own work (and
  /// re-checks the warm/interval state then — the first write may have
  /// made it unnecessary). The seed (warm-up) and the sync (bind/manual
  /// refresh) serialize through this, so they can never write the index
  /// at once. Callers already inside a write call the private work
  /// functions directly, never this — re-entering the mutex would
  /// deadlock.
  Future<T> _runIndexWrite<T>(Future<T> Function() work) async {
    while (_indexWriteInFlight != null) {
      await _indexWriteInFlight;
    }
    final future = work();
    _indexWriteInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_indexWriteInFlight, future)) _indexWriteInFlight = null;
    }
  }

  /// A future that completes when the current index write (seed or sync)
  /// finishes, or immediately when none is running. Tests await this
  /// after a warm-up instead of sleeping for the background seed.
  @visibleForTesting
  Future<void> get searchIndexReady => _indexWriteInFlight ?? Future.value();

  /// Seed the index from the disk catalog (build #23, the upgrade path).
  /// The warm-ups call this fire-and-forget: on the first run after
  /// upgrading to 1.0.6 the disk catalog already holds the full lists,
  /// so the index is warm within seconds with NO network at all, and
  /// search is local-only from the first search. A type that is already
  /// warm is skipped (the sync owns refreshes); a type with no disk
  /// file is skipped (the sync fetches it). The isolate refuses a
  /// partial / category-less source (see [IndexWriteResult]), so a
  /// crawl-shaped disk file can never seed an incomplete index — the
  /// type stays cold and the Enter-time sync fetches it (R2.3).
  ///
  /// Build v1.0.10 (M1): the seed stamps each type with its disk file's
  /// real fetchedAt, not now — the sync that follows reads the stamp to
  /// decide whether the type is due, so a stale disk must still sync
  /// instead of being stamped fresh and skipped for a week.
  Future<void> seedSearchIndexFromDisk() => _runIndexWrite(_seedSearchIndexFromDisk);

  Future<void> _maybeSeedSearchIndexFromDisk() => _runIndexWrite(_seedSearchIndexFromDisk);

  Future<void> _seedSearchIndexFromDisk() async {
    if (!_isXtream) return;
    final index = await _searchIndex();
    if (index == null) return;
    _refreshSearchIndexState(seeding: true);
    try {
      for (final type in IptvSearchIndex.types) {
        await _seedSearchIndexTypeFromDisk(type, refreshState: false);
      }
    } finally {
      _refreshSearchIndexState();
    }
  }

  /// Seed ONE type's index from its disk catalog (1.2.11): the per-type
  /// body of [_seedSearchIndexFromDisk], so the bind warm-up can seed
  /// one type at a time (serialized, in browse order) and Reload can
  /// force a re-seed of live after it rewrites the disk file. A type
  /// that is already warm is skipped unless [force] is set. Returns the
  /// isolate's result (null when skipped) so Reload can tell whether
  /// its forced re-seed landed. [refreshState] re-reads the index meta
  /// into the notifier when the seed finishes — on by default (the bind
  /// warm-up and Reload call this directly); the loop passes false
  /// because it refreshes once for all three types.
  Future<IndexWriteResult?> _seedSearchIndexTypeFromDisk(
    String type, {
    bool force = false,
    bool refreshState = true,
  }) async {
    if (!_isXtream) return null;
    final index = await _searchIndex();
    if (index == null) return null;
    if (!force && (index.rowCounts(connection.id)[type] ?? 0) > 0) return null;
    final dbPath = await IptvSearchIndex.dbFilePath();
    final dataset = _diskDatasetFor(type);
    final catDataset = _diskCategoryDatasetFor(type);
    // 1.2.6 (catalog memory, item 4): the seed passes FILE PATHS to the
    // isolate — the isolate reads the files itself, so the main isolate
    // never holds the tens-of-MB bodies and `compute` copies only
    // paths. The file's modification time IS its fetched time (same
    // semantics as the read's fetchedAt).
    final catalogPath = await _catalogCache.filePath(connection.id, dataset);
    final categoriesPath = await _catalogCache.filePath(connection.id, catDataset);
    if (catalogPath == null || categoriesPath == null) return null;
    try {
      final catalogStat = await File(catalogPath).stat();
      final categoriesStat = await File(categoriesPath).stat();
      if (catalogStat.size == 0 || categoriesStat.size == 0) return null;
      final result = await IptvHeavyWorkGate.instance.run(
        () => compute(
          writeIndexTypeInBackground,
          IndexWriteParams(
            dbPath: dbPath,
            connectionId: connection.id,
            type: type,
            catalogBody: '',
            categoryBody: '',
            catalogFilePath: catalogPath,
            categoryFilePath: categoriesPath,
            // Build v1.0.10 (M1): the disk file's real age, not now —
            // stamping now told the sync this type was just synced, so
            // a days-old disk was never refreshed for a week.
            syncStampMs: catalogStat.modified.millisecondsSinceEpoch,
            // 1.2.4 (catalog memory): the seed lands VISIBLE rows from
            // whatever the disk file holds — a visible-only disk file
            // (written by a 1.2.4 sync) covers only visible categories,
            // so it lands as a cold partial and stays due for the sync
            // to complete; a pre-1.2.4 full disk file lands complete.
            // The sets go through the prune switch ([pruneHiddenCatalogRows]):
            // with it off the seed lands the full rows (Instant search).
            hiddenCategoryIds: _pruneHiddenCategoryIds.toList(),
            hiddenCategoryInitials: _pruneHiddenCategoryInitials.toList(),
          ),
        ),
        // 1.2.18 S-4b: trim before the isolate job starts (at
        // job-start time, inside the gate — not at queue time).
        onStart: () => _trimCachesIfHot('index seed'),
      );
      if (result.skippedReason != null) {
        appLogger.i(
          'IPTV: search index seed skipped $type (${result.skippedReason}) — the sync will fetch it',
        );
      } else if (result.partial) {
        // Series fix (v1.0.16): same cold-type rule as the sync —
        // the partial disk file lands, and the type stays due so the
        // sync completes it.
        appLogger.i(
          'IPTV: search index seed landed $type partial (${result.rowCount} rows, ${result.coveredCategories}/${result.totalCategories} categories) - the sync will complete it',
        );
      }
      return result;
    } catch (e) {
      appLogger.w('IPTV: search index seed failed for $type', error: e);
      return null;
    } finally {
      if (refreshState) _refreshSearchIndexState();
    }
  }

  /// Seed [type]'s search index from its disk catalog in the
  /// background, once (1.2.18 C-5 — seed-then-search): an as-you-type
  /// search with a cold index kicks this off and answers the current
  /// keystroke from the disk scan as before; once the seed lands, the
  /// next keystroke takes the warm FTS path instead of RegExp-scanning
  /// the full disk rows again (a no-match needle scanned all 199k VOD
  /// rows per keystroke). Serialized with the sync through
  /// [_runIndexWrite]; a type already warm (or with no disk file) is
  /// skipped by the seed itself. Never throws; fire-and-forget.
  void _kickColdSearchSeed(String type) {
    if (!_isXtream || !_coldSearchSeedInFlight.add(type)) return;
    unawaited(() async {
      try {
        await _runIndexWrite(
          () => _seedSearchIndexTypeFromDisk(type),
        );
      } catch (e) {
        // The seed itself never throws, but _runIndexWrite can (it
        // resolves the database path before the seed runs) — swallow
        // it here so a failed kick can never surface as an unhandled
        // async error in the caller (a search keystroke).
        appLogger.w('IPTV: cold-search seed kick failed for $type', error: e);
      } finally {
        _coldSearchSeedInFlight.remove(type);
      }
    }());
  }

  // -- Disk-paged browse (1.2.11) ----------------------------------------
  //
  // Browse, hubs and the guide read pages from the search index instead
  // of the memoized catalog lists, so the ~90-150MB memo heap is gone
  // for those paths: the index is the store, the memo is only the cold
  // fallback (index cold/unavailable) and the Reload-fresh live list
  // (see [_liveReloadStamp]). Every helper below returns null when the
  // index is cold for its type and the caller falls back to the memo
  // path unchanged — a broken index reads as cold, never as an error.

  /// True when any catalog memo is loaded (1.2.11 test seam): the
  /// disk-paged browse must leave every memo null, so a browse that
  /// loads one is observable without a new hook in the production
  /// code. The flags are the load markers the loaders themselves set.
  @visibleForTesting
  bool get debugAnyMemoLoaded => _liveStreamsLoaded || _vodStreamsLoaded || _seriesListLoaded;

  /// The index when it holds rows for [type], else null — the caller
  /// falls back to the memo path. A type with 0 indexed rows is cold
  /// even when the index file exists (never synced, or a deliberate
  /// all-hidden land — the latter reads as cold here and the memo path
  /// serves the same empty set from disk, so the fallback is safe).
  Future<IptvSearchIndex?> _warmIndexForType(String type) async {
    final index = await _searchIndex();
    if (index == null) return null;
    if ((index.rowCounts(connection.id)[type] ?? 0) <= 0) return null;
    return index;
  }

  /// One browse page from the index (1.2.11): the rows + the filtered
  /// total, or null when the index is cold for [type]. The hidden sets
  /// are the connection's RAW sets (the display filter, same as the
  /// memo path's [_isHiddenCategory]) — a toggle is picked up on the
  /// next read with no re-derive. Also fires the index due check, so a
  /// stale index still re-syncs in the background like the memo path
  /// did ([_refreshCatalogViaSyncIfDue] reads the index's lastSync).
  Future<({List<IptvSearchIndexRow> rows, int total})?> _indexBrowsePage(
    String type, {
    String? categoryId,
    int offset = 0,
    int? limit,
    String? search,
    String? nameStartsWith,
  }) async {
    // 1.2.19 L-37: the browse page size is per-tier (50 / 100 / 150 /
    // 200 / 200). An explicit limit (whole-category loads) still wins.
    limit ??= DevicePerformance.browsePageSize;
    final index = await _warmIndexForType(type);
    if (index == null) return null;
    _refreshCatalogViaSyncIfDue(type);
    final rows = index.listByCategory(
      connection.id,
      type,
      categoryId: categoryId,
      offset: offset,
      limit: limit,
      search: search,
      nameStartsWith: nameStartsWith,
      hiddenIds: _hiddenCategories,
      hiddenInitials: _hiddenCategoryInitials,
    );
    final total = index.countByCategory(
      connection.id,
      type,
      categoryId: categoryId,
      search: search,
      nameStartsWith: nameStartsWith,
      hiddenIds: _hiddenCategories,
      hiddenInitials: _hiddenCategoryInitials,
    );
    return (rows: rows, total: total);
  }

  /// All rows of one type from the index, in provider order, read in
  /// bounded pages (1.2.11): the live guide genuinely needs every
  /// row at once, so it pages through the index instead of holding a
  /// memo — the list is transient to the call, not a heap the client
  /// keeps. Null when the index is cold. (1.6.11 P4 deleted the
  /// whole-list hub builders that used to share this.)
  Future<List<IptvSearchIndexRow>?> _indexAllRows(String type) async {
    final index = await _warmIndexForType(type);
    if (index == null) return null;
    _refreshCatalogViaSyncIfDue(type);
    final rows = <IptvSearchIndexRow>[];
    var offset = 0;
    while (true) {
      final page = index.listByCategory(
        connection.id,
        type,
        offset: offset,
        limit: 5000,
        hiddenIds: _hiddenCategories,
        hiddenInitials: _hiddenCategoryInitials,
      );
      if (page.isEmpty) break;
      rows.addAll(page);
      offset += page.length;
      if (page.length < 5000) break;
    }
    return rows;
  }

  /// When Reload published a fresh live memo (1.2.11): Reload rewrites
  /// the disk file and the memo but NOT the index (pre-existing) — the
  /// index is stale until the forced live re-seed lands, so the guide
  /// must keep serving the fresh memo until the index catches up. The
  /// stamp is the Reload time; it clears itself once the index's live
  /// lastSync reaches it (the re-seed stamps the fresh disk file's
  /// mtime) or the memo is dropped. Null outside a Reload window.
  DateTime? _liveReloadStamp;

  /// The index state the guide's playlist-change fingerprint was last
  /// computed over (1.2.11): a repeated guide call over an unchanged
  /// index skips the 26k-row hash, the way the memo path skipped it on
  /// a memo hit. Null until the first index-path guide load.
  DateTime? _lastGuideIndexLastSync;
  int? _lastGuideIndexRowCount;

  /// The hidden sets the fingerprint was last computed over (1.6.32,
  /// option 4): a hide-only change must not trigger the fingerprint +
  /// EPG decision — the playlist did not change, only its visibility
  /// did. When the index changed AND the hidden sets changed since
  /// the last fingerprint, the fingerprint is skipped this load (the
  /// playlist-change check resumes on the next index change, one sync
  /// cycle later at most).
  Set<String>? _lastGuideHiddenIds;
  Set<String>? _lastGuideHiddenInitials;

  /// Cached guide-order channel list + key→index map (1.2.18 C-1):
  /// `iptvChannels()` rebuilt the whole 26k-row list from SQLite on
  /// every guide fetch; the index's live stamp + row count say whether
  /// the index changed, so an unchanged index serves the same list
  /// instead of re-paying the paging + materialization. Invalidated
  /// whenever the in-memory catalogs are dropped or the hidden filter
  /// changes (both also clear [_xtreamChannelByKey], so the cached
  /// list and the key map can never disagree).
  List<LiveTvChannel>? _cachedGuideChannels;
  Map<String, int>? _cachedGuideChannelIndex;
  DateTime? _cachedGuideIndexLastSync;
  int? _cachedGuideIndexRowCount;

  void _invalidateGuideChannelCache() {
    _cachedGuideChannels = null;
    _cachedGuideChannelIndex = null;
    _cachedGuideIndexLastSync = null;
    _cachedGuideIndexRowCount = null;
  }

  /// True when the live memo is fresher than the index (1.2.11): a
  /// Reload is in flight and its re-seed has not landed yet. The guide
  /// serves the memo then; every other path serves the index.
  Future<bool> _liveMemoFresherThanIndex() async {
    final stamp = _liveReloadStamp;
    if (stamp == null || !_liveStreamsLoaded) return false;
    final index = await _searchIndex();
    final lastSync = index?.lastSync(connection.id)[IptvSearchIndex.typeLive];
    if (lastSync != null && !lastSync.isBefore(stamp)) {
      // The re-seed landed: the index caught up, the flag is spent.
      _liveReloadStamp = null;
      return false;
    }
    return true;
  }

  static String _diskDatasetFor(String type) => switch (type) {
        IptvSearchIndex.typeLive => IptvCatalogDiskCache.liveDataset,
        IptvSearchIndex.typeMovie => IptvCatalogDiskCache.vodDataset,
        _ => IptvCatalogDiskCache.seriesDataset,
      };

  static String _diskCategoryDatasetFor(String type) => switch (type) {
        IptvSearchIndex.typeLive => IptvCatalogDiskCache.liveCategoriesDataset,
        IptvSearchIndex.typeMovie => IptvCatalogDiskCache.vodCategoriesDataset,
        _ => IptvCatalogDiskCache.seriesCategoriesDataset,
      };

  /// SharedPreferences key holding the start time (epoch ms) of a catalog
  /// sync currently running in ANOTHER isolate (build v1.0.13, R4, D5).
  /// The UI isolate and the background job both write it for the duration
  /// of a sync and clear it when done, so the other side can yield
  /// instead of duplicating the 6 requests. Best-effort: a crash leaves
  /// a stale stamp, which ages out after [syncRunningStampStaleAfter].
  static const String syncRunningStampPrefsKey = 'iptv_catalog_sync_running_since_ms';

  /// A running stamp older than this is dead (the run crashed or was
  /// killed) and must not block syncs forever.
  static const Duration syncRunningStampStaleAfter = Duration(minutes: 30);

  /// True when another isolate started a catalog sync recently enough
  /// that this isolate should yield. Never throws — an unreadable prefs
  /// store reads as "nobody is syncing".
  static Future<bool> isSyncRunningElsewhere() async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      final stampMs = prefs.getInt(syncRunningStampPrefsKey);
      if (stampMs == null) return false;
      final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(stampMs));
      return age < syncRunningStampStaleAfter;
    } catch (e) {
      appLogger.w('IPTV: running stamp unreadable', error: e);
      return false;
    }
  }

  static Future<void> _writeSyncRunningStamp() async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.setInt(syncRunningStampPrefsKey, DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      appLogger.w('IPTV: running stamp unwritable', error: e);
    }
  }

  static Future<void> _clearSyncRunningStamp() async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.remove(syncRunningStampPrefsKey);
    } catch (e) {
      appLogger.w('IPTV: running stamp unclearable', error: e);
    }
  }

  /// The current catalog schema (v1.1.0): index + disk files hold the
  /// FULL catalog, filtered only at read time. A stored version below
  /// this means the files were written by the v1.0.16 lossy schema and
  /// the next sync re-fetches every type once to repair them.
  static const _currentCatalogSchemaVersion = 2;

  /// SharedPreferences key for the catalog schema version (v1.1.0,
  /// Option B): which schema the stored index + disk files were written
  /// under, per connection. Version 2 is the first schema whose index +
  /// disk hold the FULL catalog; version 1 (or absent) is the v1.0.16
  /// lossy schema, whose files were written visible-only and must be
  /// re-fetched once (the schema repair).
  String get _catalogSchemaPrefsKey => 'iptv_catalog_schema_v:${connection.id}';

  /// The catalog schema version the last completed sync stamped, or 0
  /// before any sync (no baseline — the repair runs on the first sync),
  /// or -1 when the version cannot be read at all. The -1 is not "old":
  /// in a raw background isolate the prefs channel is unavailable, so
  /// the read throws and the version is UNKNOWN — forcing a repair on
  /// inconclusive evidence would re-fetch the whole catalog on every
  /// background run and break the R4 due check (the probe pin). The
  /// repair fires only on positive evidence (a readable version < 2).
  /// Never throws.
  Future<int> _readCatalogSchemaVersion() async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      return prefs.getInt(_catalogSchemaPrefsKey) ?? 0;
    } catch (e) {
      appLogger.w('IPTV: catalog schema version unreadable', error: e);
      return -1;
    }
  }

  /// Record the catalog schema version as synced (v1.1.0): called only
  /// after a sync loop completes cleanly, never on abort — an aborted
  /// run must not claim the repair is done. Never throws.
  Future<void> _writeCatalogSchemaVersion(int version) async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.setInt(_catalogSchemaPrefsKey, version);
    } catch (e) {
      appLogger.w('IPTV: catalog schema version unwritable', error: e);
    }
  }

  /// The index's lastSync per type at the moment the memoized catalog was
  /// populated (build v1.0.13, R4, test 6). A background-isolate sync
  /// writes the index + disk while this client is warm; when the stamp
  /// advances past the recorded one the memo is stale and must be
  /// dropped. A type that never synced stamps the epoch, so the first
  /// real sync invalidates the memo.
  final Map<String, DateTime> _memoSyncStamp = {};

  /// True when [e] is a transport failure (the panel did not answer at
  /// all), as opposed to a refusal or a bad payload (build v1.0.13, R4,
  /// D9). Only transport failures are worth a background retry.
  static bool _isTransportError(Object e) =>
      e is MediaServerHttpException &&
      (e.type == MediaServerHttpErrorType.connectionError ||
          e.type == MediaServerHttpErrorType.connectionTimeout ||
          e.type == MediaServerHttpErrorType.receiveTimeout);

  /// Hours between catalog syncs (Settings → IPTV, default once a week,
  /// 0 = manual only). Falls back to weekly when Settings is not
  /// initialized yet (tests).
  int _catalogSyncIntervalHours() {
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return SettingsService.iptvCatalogSyncIntervalHours.defaultValue;
    return settings.read(SettingsService.iptvCatalogSyncIntervalHours);
  }

  /// Sync the whole catalog into the local search index (build #23).
  /// Fetches each type's category list + unfiltered catalog from the
  /// panel (6 requests total — the only panel traffic search ever
  /// causes), applies the sync-time guards as one choke point, and
  /// replaces that type's index rows atomically. The guards (OpenTV
  /// `replaceCatalogue` + IPTVMac SyncService, generalising build #19's
  /// P5a): an empty response keeps the old rows; a partial response
  /// (fewer than half the indexed rows, when the index has rows) keeps
  /// the old rows; a response over the 300 MB cap is refused before
  /// parsing; a write never deletes all rows. A type whose interval has
  /// not elapsed is skipped ('up-to-date') unless [force] (manual
  /// refresh). [onProgress] drives the "refreshing Trex details" popup;
  /// [abort] (the popup's Cancel) stops the sync between types — types
  /// already synced stay synced.
  /// 1.2.19, L-14 — the survival-tier series rule, pure for tests: on
  /// T0 a series sync runs only on Wi-Fi AND charging. Series is the
  /// largest catalog (46k rows) and the tier cannot afford it on mobile
  /// data or on battery. Every other tier always allows series.
  @visibleForTesting
  static bool seriesSyncAllowedForTier(DeviceTier tier, {required bool onWifi, required bool charging}) {
    if (tier != DeviceTier.survival) return true;
    return onWifi && charging;
  }

  /// The live inputs to [seriesSyncAllowedForTier] for this device.
  /// Wi-Fi comes from connectivity_plus. Charging has NO signal in the
  /// tree yet (no battery_plus dependency — pubspec is owned by the
  /// parent this round — and no battery platform channel), so it reads
  /// false until one lands: until then series is skipped on T0 even on
  /// Wi-Fi. Conservative by design; the pure rule above is what is
  /// tested. Never throws.
  Future<bool> _seriesSyncAllowedOnSurvivalTier() async {
    if (!DevicePerformance.isSurvivalMode) return true;
    var onWifi = false;
    try {
      onWifi = (await Connectivity().checkConnectivity()).hasWifiOrEthernet;
    } catch (_) {
      onWifi = false;
    }
    return seriesSyncAllowedForTier(DeviceTier.survival, onWifi: onWifi, charging: false);
  }

  /// 1.6.34 (P-15): on T0/T1 a COLD series type is DEFERRED on first
  /// run instead of synced with live + movies — series is the largest
  /// catalog (46k rows) and the low tiers cannot afford it in the
  /// first-run window. The follow-up syncs it in the background after
  /// the first frame; it still lands. Warm series (already landed
  /// once) is never deferred. Pure for tests.
  @visibleForTesting
  static bool shouldDeferSeriesFirstRun({required DeviceTier tier, required bool seriesCold}) {
    if (!seriesCold) return false;
    return tier == DeviceTier.survival || tier == DeviceTier.low;
  }

  /// Delay before the deferred-series follow-up runs (1.6.34, P-15):
  /// long enough for the first frame to land and the UI to settle
  /// after the first-run sync. Test-overridable.
  @visibleForTesting
  static Duration deferredSeriesFollowUpDelay = const Duration(seconds: 5);

  /// Run the series sync deferred by P-15 (1.6.34): waits for the
  /// first frame to land, then syncs series in the background. The
  /// follow-up run does not defer series again, so the deferred series
  /// actually lands instead of deferring forever. Best-effort: a
  /// failed follow-up leaves series cold, and the next bind/manual
  /// sync picks it up (the deferral only fires on a cold first run).
  Future<void> _syncDeferredSeriesFollowUp() async {
    await Future<void>.delayed(deferredSeriesFollowUpDelay);
    try {
      await _runIndexWrite(
        () => _syncSearchIndex(
          force: false,
          retryTransportErrors: false,
          cancelOnBackground: false,
          deferSeriesFirstRun: false,
          scheduleDeferredSeriesFollowUp: false,
        ),
      );
    } catch (_) {
      // Best-effort (see above).
    }
  }

  Future<IptvSearchSyncResult> syncSearchIndex({
    bool force = false,
    void Function(IptvSearchSyncProgress)? onProgress,
    AbortController? abort,
  }) async {
    if (!_isXtream) return const IptvSearchSyncResult(rows: {}, skipped: {});
    // R2.4: a forced sync is a manual refresh (or the Enter path) — the
    // user asked explicitly, so a transport-closed fetch is retried once.
    // A background/interval sync (force: false) never retries.
    // 1.6.11 (background sync): a user-initiated sync is NOT cancelled
    // when the app backgrounds — locking the phone mid-load used to
    // abort the fetch and report the load "failed".
    // 1.6.34 (P-02): a forced (manual) sync must not re-download the
    // whole catalog while a bind sync is already running — the double
    // download the refresh-lag paper ranked first. When a sync is in
    // flight (same isolate, or another isolate's stamp), join it
    // instead: wait for it to land, then re-evaluate per type
    // non-forced, so types it just landed read up-to-date and only
    // still-due types fetch. A manual tap while nothing is running
    // still forces, exactly as before. The join is bounded (a stale
    // stamp or a run longer than the bound fails open to the old
    // forced shape) and abort-aware (Cancel stops the wait).
    var joinedSync = false;
    if (force) {
      joinedSync = await _joinInFlightSync(abort: abort, onProgress: onProgress);
    }
    return _runIndexWrite(
      () => _syncSearchIndex(
        force: force && !joinedSync,
        onProgress: onProgress,
        abort: abort,
        retryTransportErrors: force,
        cancelOnBackground: false,
      ),
    );
  }

  /// Wait for a catalog sync already in flight to land, so the caller
  /// can re-evaluate per type instead of re-downloading (1.6.34,
  /// P-02). Returns true when a sync was joined: a same-isolate
  /// [_ensureSyncedInFlight] run was awaited (to completion, failure,
  /// or the bound — the caller's non-forced re-evaluation runs behind
  /// the index-write mutex either way, so types the run landed are
  /// still skipped), or another isolate's running stamp cleared.
  /// Returns false when nothing was running, or when the stamp wait
  /// hit its bound (fail open — the caller proceeds forced). Throws
  /// when the caller cancels mid-wait. Emits a 'waiting' progress
  /// event per type so the manual dialog's rows say what is happening
  /// instead of spinning silently.
  static const Duration _joinInFlightSyncBound = Duration(minutes: 15);

  Future<bool> _joinInFlightSync({
    AbortController? abort,
    void Function(IptvSearchSyncProgress)? onProgress,
  }) async {
    final inFlight = _ensureSyncedInFlight;
    if (inFlight != null) {
      try {
        await Future.any([
          inFlight,
          Future<void>.delayed(_joinInFlightSyncBound),
          if (abort != null) abort.trigger,
        ]);
        abort?.throwIfAborted();
        return true;
      } catch (_) {
        // The in-flight run failed — it still ran, so the caller's
        // non-forced re-evaluation is correct for the types it
        // landed; the failed ones stay due. An abort rethrows below.
        abort?.throwIfAborted();
        return true;
      }
    }
    if (!await isSyncRunningElsewhere()) return false;
    for (final type in IptvSearchIndex.types) {
      onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'waiting'));
    }
    appLogger.i('IPTV: manual sync joining the sync already running');
    final deadline = DateTime.now().add(_joinInFlightSyncBound);
    while (await isSyncRunningElsewhere()) {
      if (DateTime.now().isAfter(deadline)) {
        appLogger.w('IPTV: manual sync join timed out — proceeding forced');
        return false;
      }
      abort?.throwIfAborted();
      await Future.any([
        Future<void>.delayed(const Duration(seconds: 1)),
        if (abort != null) abort.trigger,
      ]);
      abort?.throwIfAborted();
    }
    return true;
  }

  /// Background-isolate entry point for the periodic catalog sync (build
  /// v1.0.13, R4). Same engine as [syncSearchIndex], but: the interval
  /// comes from the caller (a background isolate has no SettingsService),
  /// cold types are skipped (D8 — a type with no index rows has no user
  /// waiting on it, and the job must not pay for a first sync the user
  /// never asked for), the playback check reads the SharedPreferences
  /// mirror (D4 — the in-memory activity is a fresh idle instance in a
  /// background isolate), and a transport failure is reported per type
  /// (D9) so the caller can decide whether the run is worth retrying.
  /// Never retries a transport error (the WorkManager backoff is the
  /// retry). A playback bail returns the partial result with
  /// [IptvSearchSyncResult.playbackAborted] set.
  Future<IptvSearchSyncResult> syncSearchIndexForBackground({
    int? intervalHours,
    AbortController? abort,
    Future<bool> Function()? isPlaybackActive,
  }) {
    if (!_isXtream) return Future.value(const IptvSearchSyncResult(rows: {}, skipped: {}));
    // L-33: this client lives in the background isolate — its index
    // connection is the small-cache reader beside the compute()
    // writer (see [_searchIndex]).
    _backgroundSyncIndex = true;
    return _runIndexWrite(
      () => _syncSearchIndex(
        force: false,
        abort: abort,
        retryTransportErrors: false,
        intervalHoursOverride: intervalHours,
        skipColdTypes: true,
        backgroundPlaybackCheck: isPlaybackActive,
        scheduleDeferredSeriesFollowUp: false,
      ),
    );
  }

  /// R2.4: retry a panel fetch ONCE on a transport error only — the
  /// panel closing the connection mid-download ("Connection closed while
  /// receiving data", the series failure in the owner's logs) is worth one
  /// re-ask after a short backoff. Never retries timeouts (the panel is
  /// not answering at all), 4xx, oversize, or empty responses — and only
  /// when [retry] is true (forced syncs: manual refresh, Enter). The
  /// backoff is abort-aware: a background cancel during the 2 s wait
  /// stops the sync instead of re-fetching into a dead run. A second
  /// failure throws, and the caller records the type 'failed' as usual.
  Future<T> _fetchWithTransportRetry<T>(
    Future<T> Function() fetch, {
    required bool retry,
    required AbortController abort,
  }) async {
    try {
      return await fetch();
    } on MediaServerHttpException catch (e) {
      if (!retry || e.type != MediaServerHttpErrorType.connectionError) rethrow;
      await Future.any([
        Future<void>.delayed(const Duration(seconds: 2)),
        abort.trigger,
      ]);
      abort.throwIfAborted();
      return await fetch();
    }
  }

  /// 1.6.34 (P-04): at most two type downloads run at once, and fetch
  /// starts are paced 200 ms apart — the no-hammering ceiling (user,
  /// 2026-11-20). The writes stay sequential (live, then movies, then
  /// series) so live still lands first and the heavy-work gate never
  /// holds two parses at once. Consts, not tunables: the cap must
  /// never be raised by a caller or a test.
  static const int syncFetchConcurrency = 2;
  static const Duration syncFetchStartPacing = Duration(milliseconds: 200);

  /// Download one type's catalog (1.6.34, P-04): the per-type fetch
  /// block of [_syncSearchIndex], extracted so the fetch phase can run
  /// it for several types at once. Categories + catalog download,
  /// streamed straight to the type's resume file — the main isolate
  /// never holds the body. Per-call state only (its own resume path,
  /// its own progress closure), so concurrent fetches do not share
  /// mutable state; the [XtreamApi] download calls take an explicit
  /// file path and per-type fields. Returns the outcome; never throws
  /// except on cancellation.
  Future<_TypeFetchOutcome> _fetchTypeCatalog({
    required String type,
    required AbortController abort,
    required bool retryTransportErrors,
    void Function(IptvSearchSyncProgress)? onProgress,
  }) async {
    onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'fetching'));
    // 1.6.34 (P-05): per-type fetch timing — categories + catalog
    // download together; the write timing is measured in the write
    // phase below.
    final fetchSw = Stopwatch()..start();
    // R4: panel requests attempted (categories + catalog per type
    // that reaches the fetch). A forced sync's R2.4 retry re-fetches
    // without incrementing.
    var requests = 0;
    try {
      // R2.4: each fetch gets its own retry (categories and catalog
      // separately) — retrying the whole per-type block would cost
      // +2 requests instead of +1.
      requests++;
      final categories = await _fetchWithTransportRetry(
        () => _fetchCategoriesFor(type, abort),
        retry: retryTransportErrors,
        abort: abort,
      );
      final tempPath = _syncResumePath(type);
      // 1.6.11 (background sync): download byte progress, throttled
      // to ~1 s / 5% so the dialog and the foreground-service
      // notification move without a setState per chunk.
      var lastByteReportMs = 0;
      var lastByteReported = 0;
      void reportDownloadProgress(int received, int? total) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final totalKnown = total != null && total > 0;
        final crossedPercent = totalKnown && (received * 20 ~/ total) != (lastByteReported * 20 ~/ total);
        if (nowMs - lastByteReportMs < 1000 && !crossedPercent) return;
        lastByteReportMs = nowMs;
        lastByteReported = received;
        onProgress?.call(
          IptvSearchSyncProgress(
            type: type,
            phase: 'fetching',
            receivedBytes: received,
            totalBytes: total,
          ),
        );
      }

      switch (type) {
        case IptvSearchIndex.typeLive:
          requests++;
          await _fetchWithTransportRetry(
            () => _xtreamApi.getLiveStreamsToFile(
              filePath: tempPath,
              abortTrigger: abort.trigger,
              resume: true,
              onProgress: reportDownloadProgress,
            ),
            retry: retryTransportErrors,
            abort: abort,
          );
        case IptvSearchIndex.typeMovie:
          requests++;
          await _fetchWithTransportRetry(
            () => _xtreamApi.getVodStreamsToFile(
              filePath: tempPath,
              abortTrigger: abort.trigger,
              resume: true,
              onProgress: reportDownloadProgress,
            ),
            retry: retryTransportErrors,
            abort: abort,
          );
        default:
          requests++;
          await _fetchWithTransportRetry(
            () => _xtreamApi.getSeriesToFile(
              filePath: tempPath,
              abortTrigger: abort.trigger,
              resume: true,
            ),
            retry: retryTransportErrors,
            abort: abort,
          );
      }
      fetchSw.stop();
      return (
        type: type,
        categories: categories,
        catalogFilePath: tempPath,
        fetchMs: fetchSw.elapsedMilliseconds,
        requests: requests,
        skipReason: null,
        isTransportError: false,
      );
    } on XtreamCatalogTooLargeException {
      fetchSw.stop();
      // 1.6.34 (P-05): the fetch died before any bytes landed.
      appLogger.i('IPTV: catalog sync fetch for $type refused as oversize after ${fetchSw.elapsedMilliseconds}ms');
      return (
        type: type,
        categories: null,
        catalogFilePath: null,
        fetchMs: fetchSw.elapsedMilliseconds,
        requests: requests,
        skipReason: 'oversize',
        isTransportError: false,
      );
    } catch (e) {
      fetchSw.stop();
      // Cancellation is not a fetch failure: rethrow so the sync
      // aborts instead of recording a spurious 'failed' and
      // returning a partial result.
      if (e is MediaServerHttpException && e.isCancellation) rethrow;
      appLogger.w(
        'IPTV: catalog sync fetch failed for $type after ${fetchSw.elapsedMilliseconds}ms',
        error: e,
      );
      return (
        type: type,
        categories: null,
        catalogFilePath: null,
        fetchMs: fetchSw.elapsedMilliseconds,
        requests: requests,
        skipReason: 'failed',
        isTransportError: _isTransportError(e),
      );
    }
  }

  /// Guard + write one fetched type (1.6.34, P-04): the per-type
  /// write block of [_syncSearchIndex], extracted so Phase C can
  /// chain the writes (each type's write runs when its fetch lands
  /// AND the previous type's write finished). Never throws: a
  /// fetch-skipped type is recorded and a write failure is recorded
  /// as 'failed', exactly as the old inline loop did.
  Future<void> _writeTypeOutcome({
    required String type,
    required _TypeFetchOutcome outcome,
    required IptvSearchIndex index,
    required String dbPath,
    required int nowMs,
    required Map<String, int> rows,
    required Map<String, String> skipped,
    required Set<String> partialTypes,
    required Set<String> consumedResumePaths,
    required Set<String> transportFailed,
    void Function(IptvSearchSyncProgress)? onProgress,
  }) async {
    if (outcome.skipReason != null) {
      if (outcome.isTransportError) transportFailed.add(type);
      skipped[type] = outcome.skipReason!;
      onProgress?.call(
        IptvSearchSyncProgress(type: type, phase: 'skipped', reason: outcome.skipReason),
      );
      return;
    }
    // A landed outcome always carries both — enforced by
    // [_fetchTypeCatalog]'s success return.
    final categories = outcome.categories!;
    final catalogFilePath = outcome.catalogFilePath!;

    // Sync-time guards (the choke point): empty keeps the old rows;
    // partial (< half the indexed rows, when the index has rows)
    // keeps the old rows — a partial list must never overwrite a
    // good index (the P5a class). 1.2.10: the partial guard runs
    // inside the one-parse isolate job now — it parses once and
    // compares its own visible count against the indexed visible
    // count, so the main isolate never needs the parsed list. The
    // main isolate keeps only the cheap pre-check: a zero-byte
    // file is an empty response without an isolate round trip (a
    // file that cannot be read is treated the same — the isolate
    // would refuse it as empty anyway). 1.2.4: the comparison is
    // VISIBLE-against-visible — the index holds visible rows only
    // now, so comparing the full fetch against the visible land
    // would never fire (a half-catalog fetch would pass as complete
    // and clobber a good index). The denominator is the rows the
    // index holds for categories visible RIGHT NOW (not the count
    // from the last sync): when the hidden set grew since, the
    // stored count includes rows that are hidden now, and comparing
    // the fresh visible fetch against it would cry partial on a
    // complete fetch and leave the type due forever.
    final catalogPath = catalogFilePath;
    var catalogBytes = 0;
    try {
      catalogBytes = await File(catalogPath).length();
    } catch (_) {
      catalogBytes = 0;
    }
    if (catalogBytes == 0) {
      skipped[type] = 'empty-response';
      onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'empty-response'));
      return;
    }
    final visibleIndexed = index.visibleRowCount(
      connection.id,
      type,
      _pruneHiddenCategoryIds,
      _pruneHiddenCategoryInitials,
    );
    onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'writing'));
    // 1.6.34 (P-05): per-type write timing — started inside the
    // gate callback so queue time is not counted as write time.
    final writeSw = Stopwatch();
    try {
      final result = await IptvHeavyWorkGate.instance.run(
        () async {
          writeSw.start();
          try {
            return await compute(
              writeIndexTypeInBackground,
              IndexWriteParams(
            dbPath: dbPath,
            connectionId: connection.id,
            type: type,
            // 1.2.10 (one-parse sync): the isolate reads the streamed
            // file itself — the body is never copied across the port
            // (the seed path has done this since 1.2.6; the sync
            // joins it). catalogBody is ignored when the path is set.
            catalogBody: '',
            catalogFilePath: catalogPath,
            categoryBody: jsonEncode(categories.map((c) => c.toJson()).toList()),
            syncStampMs: nowMs,
            // The row-count partial guard's denominator (see above).
            visibleIndexed: visibleIndexed,
            // The visible disk file's destination — the isolate
            // writes it after a complete land.
            diskFilePath: await _catalogCache.writeFilePath(
              connection.id,
              _diskDatasetFor(type),
            ),
            // 1.2.4 (catalog memory, the owner's prune decision): the
            // isolate lands VISIBLE rows only and deletes the
            // hidden rows it already holds for this connection.
            // The sets go through the prune switch ([pruneHiddenCatalogRows]).
            hiddenCategoryIds: _pruneHiddenCategoryIds.toList(),
            hiddenCategoryInitials: _pruneHiddenCategoryInitials.toList(),
              ),
            );
          } finally {
            writeSw.stop();
          }
        },
        // 1.2.18 S-4b: trim before the isolate job starts (at
        // job-start time, inside the gate — not at queue time).
        onStart: () => _trimCachesIfHot('catalog sync'),
      );
      // 1.2.19 (L-4): the isolate job read the file — a later run
      // must fetch it fresh, not resume a consumed file.
      consumedResumePaths.add(catalogPath);
      if (result.skippedReason != null) {
        skipped[type] = result.skippedReason!;
        onProgress?.call(
          IptvSearchSyncProgress(type: type, phase: 'skipped', reason: result.skippedReason),
        );
        // Series fix (v1.0.16): the numbers that separate a
        // panel-truncated list (C1: dropped 0) from a parse-dropped
        // one (C3: dropped > 0) on the next failure.
        if (result.skippedReason == 'partial-kept') {
          appLogger.i(
            'IPTV: catalog sync skipped $type as partial-kept (covered ${result.coveredCategories}/${result.totalCategories} categories, ${result.droppedRows} rows dropped in parse, ${result.hiddenSkipped} in hidden categories)',
          );
        }
        return;
      }
      rows[type] = result.rowCount;
      // 1.6.34 (P-05): per-type timing + bytes — download ms +
      // catalog bytes + write ms. The categories fetch is small
      // and untracked; the catalog file is the download.
      appLogger.i(
        'IPTV: catalog sync $type downloaded ${catalogBytes}B in ${outcome.fetchMs}ms, wrote ${result.rowCount} rows in ${result.batches} batches in ${writeSw.elapsedMilliseconds}ms',
      );
      if (result.partial) {
        partialTypes.add(type);
        appLogger.i(
          'IPTV: catalog sync landed $type partial (${result.rowCount} rows, ${result.coveredCategories}/${result.totalCategories} categories, ${result.droppedRows} rows dropped in parse) - the type stays due for refetch, the disk catalog is untouched',
        );
      } else if (result.hiddenSkipped > 0) {
        appLogger.i(
          'IPTV: catalog sync landed $type (${result.rowCount} rows, ${result.hiddenSkipped} in hidden categories — pruned at write time, not stored)',
        );
      }
      // Build #23 (startup rule): the sync is the ONLY catalog
      // fetcher, so it also refreshes the disk catalog the browse
      // screens and the warm-ups read from (raw body + category
      // list), and drops the memoized futures so the session sees
      // the fresh rows without a restart (1.2.18 S-2: the memo is
      // re-derived from the fresh disk file on demand, not
      // republished from the isolate). A guarded-out sync leaves
      // both the disk file and the index untouched. A disk-write
      // failure never fails the sync — the index is the primary
      // store.
      //
      // Series fix (v1.0.16): a partial land is INDEX-ONLY — it
      // never overwrites the disk catalog and never publishes into
      // the memoized catalog (P5a: a 635-row partial list must not
      // clobber a 46,527-row good disk file). The disk file only
      // ever gets complete lists; the next sync (the type stays
      // due) refreshes it when the panel answers in full.
      if (!result.partial) {
        // 1.2.10 (one-parse sync): the visible disk file was already
        // written by the isolate job (complete lands only) — the
        // main isolate only writes the small category file and
        // drops the memo so the next consumer re-derives it from
        // the fresh disk file (1.2.18 S-2). The listing consumers
        // still filter hidden categories at read time (defence for
        // a stale full memo), and a direct id resolve
        // (favourite/resume) falls back to the index. A disk-write
        // failure is flagged on the result and never fails the
        // sync — the index is the primary store.
        if (result.diskWriteFailed) {
          appLogger.w('IPTV: catalog sync disk write failed for $type (index land stands)');
        }
        try {
          await _catalogCache.write(
            connection.id,
            _diskCategoryDatasetFor(type),
            jsonEncode(categories.map((c) => c.toJson()).toList()),
          );
        } catch (e) {
          appLogger.w('IPTV: catalog sync category write failed for $type', error: e);
        }
        _refreshCatalogAfterSync(type, categories);
      }
      onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'done', rows: result.rowCount, partial: result.partial));
    } catch (e) {
      appLogger.w('IPTV: catalog sync write failed for $type', error: e);
      skipped[type] = 'failed';
      onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'failed'));
    }
  }

  Future<IptvSearchSyncResult> _syncSearchIndex({
    required bool force,
    void Function(IptvSearchSyncProgress)? onProgress,
    AbortController? abort,
    bool retryTransportErrors = false,
    int? intervalHoursOverride,
    bool skipColdTypes = false,
    Future<bool> Function()? backgroundPlaybackCheck,
    // 1.6.11 (background sync): when false, this run is NOT registered
    // for background cancellation — the user started it, so locking the
    // phone or switching apps must not abort it. The caller's own
    // Cancel still aborts via the controller directly. Defaults true:
    // the WorkManager path is governed by the platform's onTaskStopped
    // instead, and any future opportunistic caller keeps the old shape.
    bool cancelOnBackground = true,
    // 1.6.34 (P-15): when false, a cold series type syncs in this run
    // instead of deferring — the deferred-series follow-up's escape
    // hatch, so the follow-up actually lands series. Defaults true.
    bool deferSeriesFirstRun = true,
    // 1.6.34 (P-15): when false, this run never schedules the
    // deferred-series follow-up — the background sync entry point
    // opts out (a background job must not pay for a first sync).
    // Defaults true: the bind and manual paths schedule it.
    bool scheduleDeferredSeriesFollowUp = true,
  }) async {
    // L-20: refuse the sync outright below 200 MB free, before any
    // fetch, temp dir, or index touch — a sync that fails mid-write
    // leaves a torn catalog and a torn index, and the panel calls are
    // wasted on a run that cannot land. Every type reports the same
    // 'storage-full' skip (the existing skip vocabulary — the manual
    // refresh dialog and the background last-run record both render
    // it), and the progress callbacks fire so the dialog's rows stop
    // spinning. A forced (manual) sync is refused too: the user asked
    // for a sync, not for a torn catalog. Unknown free space fails
    // open (see StorageHealth) — in a background isolate the channel
    // is absent, so the caller ([IptvBackgroundSync]) refuses from the
    // persisted verdict instead.
    if (await StorageHealth.freeBytes().then((free) => free != null && free < StorageHealth.refuseSyncThresholdBytes)) {
      for (final type in IptvSearchIndex.types) {
        onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'storage-full'));
      }
      return const IptvSearchSyncResult(rows: {}, skipped: {
        IptvSearchIndex.typeLive: 'storage-full',
        IptvSearchIndex.typeMovie: 'storage-full',
        IptvSearchIndex.typeSeries: 'storage-full',
      });
    }
    final index = await _searchIndex();
    if (index == null) {
      return const IptvSearchSyncResult(rows: {}, skipped: {
        IptvSearchIndex.typeLive: 'failed',
        IptvSearchIndex.typeMovie: 'failed',
        IptvSearchIndex.typeSeries: 'failed',
      });
    }
    // 1.6.34 (P-05): per-type timing + bytes for the sync path — the
    // data every other sync decision needs (P-03 vs P-04, batch sizes,
    // tunnel vs write bottleneck). Logged per type below and summed in
    // the run summary; the Streamer refresh log alone cannot separate
    // download time from write time.
    final runSw = Stopwatch()..start();
    final rows = <String, int>{};
    final skipped = <String, String>{};
    final transportFailed = <String>{};
    // Series fix (v1.0.16): types that landed a partial list on a cold
    // index — searchable now, still due for refetch. Not a failure.
    final partialTypes = <String>{};
    // 1.6.34 (P-15): set when the loop defers series on first run —
    // the follow-up is scheduled after the loop.
    var seriesDeferred = false;
    // R4: panel requests attempted (categories + catalog per type that
    // reaches the fetch). Exact on the background path (no retries); a
    // forced sync's R2.4 retry re-fetches without incrementing.
    var attempts = 0;
    // R4: the background isolate has no SettingsService, so the caller
    // hands the interval in directly.
    final intervalHours = intervalHoursOverride ?? _catalogSyncIntervalHours();
    final dbPath = await IptvSearchIndex.dbFilePath();
    // 1.2.19 (L-4): the metered guard is read ONCE per run, not per
    // type — a channel + connectivity probe per type would triple the
    // cost. The Wi-Fi-only preference is read from the shared prefs
    // cache (no SettingsService in a background isolate — same rule as
    // the interval above).
    final deferLargeOnMetered = await _deferLargeDownloadsOnMetered();
    // 1.2.19 (L-4): resume paths for the run's streamed catalog files
    // — each type's partial lives at a STABLE path outside any per-run
    // temp dir, so a killed run's partial survives for the next run to
    // resume instead of restarting from byte 0. Paths the isolate job
    // consumed are deleted in the finally below; a path that was never
    // consumed (aborted run, failed fetch) is deliberately LEFT — that
    // is the resume point.
    final consumedResumePaths = <String>{};
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // 1.2.4 (catalog memory, the owner's prune decision — supersedes the
    // v1.1.0 Option B "disk stays full" split, FORK §45): the stored
    // catalog schema. Version 2 is the first schema whose index + disk
    // files hold the FULL catalog (the v1.0.16 write-time skip wrote
    // visible rows only, so a pre-1.1.0 index/disk is lossy: un-hiding
    // a group could not bring back rows that were never written).
    // Version 2 stays current under 1.2.4 — the prune needs NO repair:
    // a pre-1.2.4 full index/disk is a SUPERSET, not a lossy store, so
    // the memos filter it at read time until the next sync prunes it,
    // and search filters hidden rows at read time too. When the stored
    // version is below 2 the next sync re-fetches every type once —
    // the repair — and the version is stamped only on a clean run
    // (same D1 rule as the old hidden fingerprint: a failed/empty/
    // oversize/partial-kept leg, or a transport failure, leaves the
    // version unstamped so the next sync retries the repair). A
    // hidden-set change does not force a sync for the memos:
    // [updateConnection] re-derives them from disk in the background,
    // no network. Rows already pruned from disk/index come back only
    // after a re-sync — the categories screen says so with a Refresh
    // action when a toggle un-hides a pruned category.
    final storedSchemaVersion = await _readCatalogSchemaVersion();
    // -1 means unreadable (raw isolate): no repair without evidence.
    final schemaRepair =
        storedSchemaVersion >= 0 &&
        storedSchemaVersion < _currentCatalogSchemaVersion;
    // Build #28: every sync owns an AbortController. 1.6.11: only
    // a background-cancellable run registers it in
    // [_activeBackgroundAborts] — a user-initiated sync must survive
    // the app backgrounding (screen off / app switch), so its
    // controller stays out of [cancelBackgroundWork]'s reach. The
    // caller's own Cancel still aborts via the controller directly.
    abort ??= AbortController();
    if (cancelOnBackground) _activeBackgroundAborts.add(abort);
    // 1.6.11 (background sync): a surviving run holds a foreground
    // service (dataSync) + partial wake lock for its duration, so
    // Android keeps the process alive and its network up while the
    // phone is locked. Best-effort: no channel on iOS/desktop/tests
    // means no service, and the Dart-side survival above still holds
    // while the process lives.
    final useForegroundService = !cancelOnBackground;
    if (useForegroundService) {
      await CatalogSyncForegroundService.instance.start(title: 'Catalog sync: $_name');
    }
    // Progress reaches the dialog AND the foreground-service
    // notification through this one wrapper.
    final baseOnProgress = onProgress;
    if (useForegroundService) {
      onProgress = (p) {
        unawaited(
          CatalogSyncForegroundService.instance.update(
            type: p.type,
            phase: p.phase,
            rows: p.rows,
            receivedBytes: p.receivedBytes,
            totalBytes: p.totalBytes,
          ),
        );
        baseOnProgress?.call(p);
      };
    }
    _refreshSearchIndexState(syncing: true);
    // R4 (D5): mark this sync as running so a concurrent run in another
    // isolate yields instead of duplicating the 6 requests. Cleared in
    // the finally below; a crash leaves a stamp that ages out in 30 min.
    await _writeSyncRunningStamp();
    try {
      // 1.6.34 (P-04): the three type downloads run in parallel (hard
      // cap 2, 200 ms pacing between starts) while the writes stay
      // sequential in live -> movies -> series order, so live still
      // lands first (P-14). Phase A decides which types are due (the
      // checks are cheap and read state this run does not change
      // before the writes, so deciding up front is equivalent to
      // deciding per type); Phase B downloads the due types; Phase C
      // guards + writes + refreshes in order.
      final dueTypes = <String>[];
      for (final type in IptvSearchIndex.types) {
        abort.throwIfAborted();
        final lastSync = index.lastSync(connection.id)[type];
        final indexedCount = index.rowCounts(connection.id)[type] ?? 0;
        // 1.2.4: a stamped land with 0 rows is a DELIBERATE empty land
        // (every category hidden) — not a cold type. The due check is
        // the stamp, not the row count, or an all-hidden type would
        // re-sync on every bind.
        if (!force && !schemaRepair && intervalHours > 0 && lastSync != null) {
          final ageHours = DateTime.now().difference(lastSync).inHours;
          if (ageHours < intervalHours) {
            skipped[type] = 'up-to-date';
            onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'up-to-date'));
            continue;
          }
        }
        if (!force && !schemaRepair && intervalHours == 0 && lastSync != null) {
          // Manual-only interval and the index already has rows: only
          // an explicit manual refresh (force) syncs.
          skipped[type] = 'up-to-date';
          onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'up-to-date'));
          continue;
        }
        if (skipColdTypes && indexedCount == 0 && lastSync == null) {
          // Build v1.0.13 (R4, D8): the background job never pays for a
          // first sync — a type with no index rows has no user waiting
          // on it, and the foreground bind/manual refresh owns first
          // syncs. Skipping is not a failure: the type stays cold until
          // the user opens it.
          skipped[type] = 'cold';
          onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'cold'));
          continue;
        }
        // 1.2.19, L-14: on the survival tier (T0) a sync skips series —
        // live + VOD only — unless on Wi-Fi AND charging. A policy
        // skip, not a failure: 'tier-skipped' is excluded from
        // [IptvSearchSyncResult.hasFailure], and the dialog maps it to
        // plain words. The check runs only when series is actually due
        // (the up-to-date/cold skips above already continued).
        if (type == IptvSearchIndex.typeSeries && !await _seriesSyncAllowedOnSurvivalTier()) {
          skipped[type] = 'tier-skipped';
          onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'tier-skipped'));
          continue;
        }
        // 1.6.34 (P-15): on T0/T1 a cold series type is DEFERRED on
        // first run — live + movies land now, series follows in the
        // background after the first frame. A deferral, not a failure:
        // 'deferred' is excluded from
        // [IptvSearchSyncResult.hasFailure], and the dialog maps it to
        // plain words. The check runs only when series is actually due
        // (the up-to-date/cold skips above already continued) and the
        // tier rule above allowed it.
        if (deferSeriesFirstRun &&
            type == IptvSearchIndex.typeSeries &&
            shouldDeferSeriesFirstRun(
              tier: DevicePerformance.currentTier,
              seriesCold: indexedCount == 0 && lastSync == null,
            )) {
          skipped[type] = 'deferred';
          onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'deferred'));
          seriesDeferred = true;
          continue;
        }
        // 1.2.19 (L-4/L-42): metered guard — a large type is deferred
        // on a metered link when the user turned on Wi-Fi-only large
        // downloads. A forced (manual) refresh is the user asking
        // explicitly, so it is not gated. The deferral is recorded in
        // the last-run tile ("sync incomplete — will finish on Wi-Fi")
        // instead of failing the type.
        if (deferLargeOnMetered && !force) {
          skipped[type] = 'metered-deferred';
          onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'metered-deferred'));
          continue;
        }
        dueTypes.add(type);
      }
      // Phase B — download the due types in parallel (1.6.34, P-04):
      // at most [syncFetchConcurrency] fetches run at once, starts are
      // paced [syncFetchStartPacing] apart, and the playback park runs
      // before each fetch START — the same park the old per-type loop
      // ran before each type's fetch, so a fetch still never starts
      // while a stream is playing. The starter drains every launched
      // fetch before an abort/bail propagates, so no un-awaited fetch
      // can error later.
      // The fetch futures, index-aligned with [dueTypes] (the starter
      // appends in due order): Phase C awaits each type's own future.
      final fetchFutures = <Future<_TypeFetchOutcome>>[];
      if (dueTypes.isNotEmpty) {
        try {
          final active = <Future<_TypeFetchOutcome>>{};
          DateTime? lastFetchStart;
          for (final type in dueTypes) {
            // Build #28: background work waits while a stream is
            // playing. A forced (manual) refresh is the user asking
            // explicitly, so it is not gated. Otherwise the sync
            // pauses before a fetch starts and resumes when playback
            // stops — it is not abandoned. The abort races the wait,
            // so a background cancel still stops a sync that is
            // parked on playback.
            if (!force) {
              await _waitForIdleUnlessAborted(abort, backgroundPlaybackCheck: backgroundPlaybackCheck);
            }
            while (active.length >= syncFetchConcurrency) {
              await Future.any(active.map((f) => f.then((_) {}).catchError((_) {})));
            }
            if (lastFetchStart != null) {
              final sinceLastStart = DateTime.now().difference(lastFetchStart);
              if (sinceLastStart < syncFetchStartPacing) {
                final remaining = syncFetchStartPacing - sinceLastStart;
                await Future.any([
                  Future<void>.delayed(remaining),
                  abort.trigger,
                ]);
                abort.throwIfAborted();
              }
            }
            lastFetchStart = DateTime.now();
            final fetchFuture = _fetchTypeCatalog(
              type: type,
              abort: abort,
              retryTransportErrors: retryTransportErrors,
              onProgress: onProgress,
            );
            active.add(fetchFuture);
            // Both paths remove the slot — and the derived future
            // never errors (both callbacks swallow), so `unawaited`
            // cannot surface a late fetch error as unhandled.
            unawaited(
              fetchFuture.then<void>(
                (_) => active.remove(fetchFuture),
                onError: (_) => active.remove(fetchFuture),
              ),
            );
            fetchFutures.add(fetchFuture);
          }
          // The fetches settle in Phase C: each type's write step
          // awaits its own fetch future, so a slow type never holds
          // back an earlier type's landing (P-14).
        } catch (e) {
          // Every launched fetch must settle before the abort/bail
          // propagates — a late fetch error after this point would
          // surface as an unhandled async error.
          await Future.wait(fetchFutures.map((f) => f.then((_) {}).catchError((_) {})));
          rethrow;
        }
      }
      // Phase C — guard + write, chained in live -> movies ->
      // series order (1.6.34, P-04): a type's write runs as soon as
      // its fetch lands AND the previous type's write finished, so
      // live still lands first (P-14) even though the fetches
      // overlap — the writes stay sequential and the heavy-work gate
      // never holds two parses at once.
      if (dueTypes.isNotEmpty) {
        final writeFutures = <Future<void>>[];
        // The step closure cannot use the promoted `abort` (promotion
        // does not survive a closure capture) — capture the non-null
        // controller once.
        final abortController = abort;
        try {
          for (var i = 0; i < dueTypes.length; i++) {
            final type = dueTypes[i];
            final fetchFuture = fetchFutures[i];
            Future<void> step() async {
              final outcome = await fetchFuture;
              attempts += outcome.requests;
              if (i > 0) await writeFutures[i - 1];
              abortController.throwIfAborted();
              await _writeTypeOutcome(
                type: type,
                outcome: outcome,
                index: index,
                dbPath: dbPath,
                nowMs: nowMs,
                rows: rows,
                skipped: skipped,
                partialTypes: partialTypes,
                consumedResumePaths: consumedResumePaths,
                transportFailed: transportFailed,
                onProgress: onProgress,
              );
            }
            writeFutures.add(step());
          }
          await Future.wait(writeFutures);
        } catch (e) {
          // A step that threw early (abort, or the previous step's
          // abort) never awaited its fetch — drain every launched
          // fetch so a late fetch error cannot surface as unhandled.
          await Future.wait(fetchFutures.map((f) => f.then((_) {}).catchError((_) {})));
          rethrow;
        }
      }
      // v1.1.0 (Option B, D1 rule carried over): stamp the catalog
      // schema version ONLY when the run actually completed. A type
      // skipped 'failed', 'empty-response', 'oversize' or
      // 'partial-kept' kept its old rows with a recent lastSync, so
      // stamping would make the next bind skip it as up-to-date and
      // the repair would never happen — the lossy rows would stay
      // until the weekly interval lapsed, with no indication why. The
      // partial-kept trigger is the one the owner's panel hits every day
      // (it persistently returns partial series lists); the transport
      // trigger is the one his flaky panel hits right now.
      // Deliberately NOT the hasFailure mirror: 'cold' does not block
      // (a cold type has no rows and no lastSync, so it stays due and
      // its first fetch lands the full rows), and 'partial-kept' DOES
      // block (see above). An aborted run never reaches here, so it
      // cannot claim the repair is done either.
      final repairApplied = !skipped.values.any(
        (reason) =>
            reason == 'failed' ||
            reason == 'empty-response' ||
            reason == 'oversize' ||
            reason == 'partial-kept' ||
            reason == 'metered-deferred',
      ) && transportFailed.isEmpty;
      if (repairApplied) {
        await _writeCatalogSchemaVersion(_currentCatalogSchemaVersion);
      } else {
        appLogger.w(
          'IPTV: catalog sync did not complete cleanly (skipped=$skipped transportFailed=$transportFailed) - the catalog schema version is not updated, so the next sync retries the repair',
        );
      }
      // 1.6.34 (P-05): run summary — total wall-clock + per-type
      // rows/skips, so the first-run sync has one line to quote.
      runSw.stop();
      appLogger.i(
        'IPTV: catalog sync finished in ${runSw.elapsedMilliseconds}ms (rows=$rows skipped=$skipped requests=$attempts)',
      );
      if (seriesDeferred && scheduleDeferredSeriesFollowUp) {
        // 1.6.34 (P-15): the deferred series still lands — in the
        // background, after the first frame, without competing with
        // the UI the first run just painted. Scheduled here, after
        // the loop completed normally: an aborted run never reaches
        // this line, so a cancelled sync never schedules a follow-up.
        unawaited(_syncDeferredSeriesFollowUp());
      }
      return IptvSearchSyncResult(rows: rows, skipped: skipped, transportFailedTypes: transportFailed, requests: attempts, partialTypes: partialTypes);
    } on _BackgroundPlaybackActive {
      // R4 (D4): playback started mid-run — bail with the partial
      // result; the caller maps it to a retry, and the types already
      // synced stay synced.
      runSw.stop();
      appLogger.i(
        'IPTV: catalog sync aborted by playback after ${runSw.elapsedMilliseconds}ms (rows=$rows skipped=$skipped)',
      );
      return IptvSearchSyncResult(
        rows: rows,
        skipped: skipped,
        transportFailedTypes: transportFailed,
        playbackAborted: true,
        requests: attempts,
      );
    } finally {
      // L-29: checkpoint the WAL on sync completion (and, via the
      // per-type writer checkpoints, periodically while a sync runs
      // >5 min) — the WAL never grows unbounded across runs. Cheap
      // when the WAL is already folded; skipped when one ran <5 min
      // ago on this connection.
      index.checkpointIfStale();
      // 1.2.19 (L-4): delete only the resume files the isolate job
      // consumed. A file that was never consumed (aborted run, failed
      // fetch) stays — it is the next run's resume point. The OS
      // reclaims the system temp dir if a leftover is never resumed.
      for (final path in consumedResumePaths) {
        try {
          final file = File(path);
          if (file.existsSync()) file.deleteSync();
        } catch (_) {
          // Best-effort cleanup.
        }
      }
      _activeBackgroundAborts.remove(abort);
      await _clearSyncRunningStamp();
      _refreshSearchIndexState();
      if (useForegroundService) {
        await CatalogSyncForegroundService.instance.stop();
      }
    }
  }

  /// Test-only override for the resume directory (1.2.19 L-4): when
  /// set, [_syncResumePath] builds the stable per-type resume path
  /// under this directory instead of the shared system temp dir. The
  /// stable path is shared by every sync of the same connection id, so
  /// concurrent test processes using one connection id would truncate
  /// and delete each other's resume files mid-sync (the D1/D2
  /// full-suite failure). On device there is only one app process and
  /// the R4 running-stamp serializes syncs, so production needs no
  /// isolation — this seam exists for the test host only.
  static Directory Function()? debugResumeDirectoryProvider;

  /// Stable per-type resume path for the catalog sync (1.2.19, L-4):
  /// the partial file lives at a path derived from the connection id
  /// (base64url, no padding — ids are arbitrary strings) + the type,
  /// in the system temp dir, so a killed run's partial survives for
  /// the next run to resume instead of restarting from byte 0. The OS
  /// may purge the system temp dir; a missing partial just means a
  /// fresh download. The `plezy_resume_` prefix is deliberate — the
  /// one-parse tests' leak detector watches `plezy_sync_*` (per-run
  /// temp dirs, always deleted), and a resume point is intentionally
  /// LEFT behind on failure, so it must not match that detector.
  /// Sync I/O (a path computation, not a read).
  String _syncResumePath(String type) {
    final safeId = base64Url.encode(utf8.encode(connection.id)).replaceAll('=', '');
    final base = debugResumeDirectoryProvider?.call() ?? Directory.systemTemp;
    return '${base.path}/plezy_resume_${safeId}_$type.json';
  }

  /// True when this run must defer large types to an unmetered link
  /// (1.2.19, L-4/L-42): the user turned on Wi-Fi-only large
  /// downloads AND the active link is metered. Delegates to
  /// [MeteredNetwork.largeDownloadsDeferred] (shared prefs cache read
  /// — no SettingsService in a background isolate). Never throws —
  /// an unreadable state reads as "do not defer" (failing open: the
  /// working path is mobile data).
  Future<bool> _deferLargeDownloadsOnMetered() async {
    return MeteredNetwork.largeDownloadsDeferred();
  }

  /// Wait until no stream is playing (build #28), or throw when [abort]
  /// fires first. Background panel work calls this before starting a
  /// fetch, so it never stacks on top of viewing traffic on a
  /// one-connection line. The wait is raced against the abort trigger:
  /// a sync parked on playback still stops when the app backgrounds.
  /// (The parked `waitForIdle` listener self-cleans at the next
  /// `markIdle` when the abort wins the race.)
  Future<void> _waitForIdleUnlessAborted(
    AbortController? abort, {
    Future<bool> Function()? backgroundPlaybackCheck,
  }) async {
    // R4 (D4): in a background isolate the in-memory activity is a fresh
    // (idle) instance, so the check reads the SharedPreferences mirror
    // instead — and the job never WAITS for idle, it bails so WorkManager
    // can retry. The foreground path keeps waiting (build #28).
    final backgroundCheck = backgroundPlaybackCheck;
    if (backgroundCheck != null) {
      if (await backgroundCheck()) throw const _BackgroundPlaybackActive();
      return;
    }
    final activity = IptvPlaybackActivity.instance;
    if (!activity.isPlaying) return;
    final trigger = abort?.trigger;
    if (trigger == null) {
      await activity.waitForIdle();
      return;
    }
    await Future.any([activity.waitForIdle(), trigger]);
    abort?.throwIfAborted();
  }

  /// Drop a memoized catalog when the index was written out-of-band after
  /// it was populated (build v1.0.13, R4): a background-isolate sync
  /// writes the DB + disk while this client is warm, and the memo would
  /// otherwise serve stale rows until restart. The stamp is the index's
  /// lastSync for the type; a newer stamp means the memo predates a sync.
  /// The check is one small SQLite query on an already-open index — no
  /// panel traffic. Never throws; on any failure the memo is kept.
  Future<void> _invalidateMemoIfIndexAdvanced(String type) async {
    if (_closed) return;
    final stamp = _memoSyncStamp[type];
    if (stamp == null) return;
    try {
      final index = await _searchIndex();
      if (index == null) return;
      final current = index.lastSync(connection.id)[type];
      if (current == null || !current.isAfter(stamp)) return;
      switch (type) {
        case IptvSearchIndex.typeLive:
          _liveStreamsFuture = null;
          _liveStreamsLoaded = false;
          _liveCategoriesFuture = null;
          _liveCategoryNamesFuture = null;
        case IptvSearchIndex.typeMovie:
          _vodStreamsFuture = null;
          _vodById = null;
          _vodStreamsLoaded = false;
          _vodCategoriesFuture = null;
          _vodCategoryNamesFuture = null;
        default:
          _seriesFuture = null;
          _seriesById = null;
          _seriesListLoaded = false;
          _seriesCategoriesFuture = null;
          _seriesCategoryNamesFuture = null;
      }
      _memoSyncStamp.remove(type);
    } catch (e) {
      appLogger.w('IPTV: memo stamp check failed for $type', error: e);
    }
  }

  /// Record the index's lastSync for [type] as the memo's stamp, so a
  /// later background run is detectable. A type that never synced stamps
  /// the epoch, so the first real sync invalidates the memo.
  Future<void> _recordMemoStamp(String type) async {
    if (_closed) return;
    try {
      final index = await _searchIndex();
      _memoSyncStamp[type] =
          index?.lastSync(connection.id)[type] ?? DateTime.fromMillisecondsSinceEpoch(0);
    } catch (e) {
      appLogger.w('IPTV: memo stamp record failed for $type', error: e);
    }
  }

  /// After a sync lands a type (1.2.18 S-2, build #23's publish
  /// replaced): the memo is DROPPED, not republished — the isolate
  /// returns counts only, and the next memo consumer re-derives the
  /// rows from the fresh disk file on demand (browse/hubs/guide are
  /// index-first since 1.2.11, so they never wait for the memo; the
  /// Enter-search getters fall back to disk when the memo is empty).
  /// Dropping instead of republishing removes the 80–200 MB port
  /// return + rebuild peak and the post-sync main-isolate stall. The
  /// synced categories ARE published (small), the load source resets
  /// (no memo is loaded), and the views are told the catalog changed,
  /// exactly as before. The memo's stamp goes with it — a stale stamp
  /// would tell the freshness check a memo exists that does not.
  ///
  /// Build v1.0.10 (M5): the synced categories are published too — the
  /// index is the single source for them (the sync just wrote this same
  /// list into the index's category table), so the memoized category
  /// futures copy from it and the derived id -> name maps are cleared
  /// to re-derive from the fresh lists. Before, a sync left the pre-
  /// sync category names in place until restart, so the hidden-category
  /// filter and the title-prefix strip used stale names. The library
  /// views are told the catalog changed (the old background refresh did
  /// this after its swap; the sync is the refresh now).
  void _refreshCatalogAfterSync(String type, List<XtreamCategory> categories) {
    switch (type) {
      case IptvSearchIndex.typeLive:
        _liveStreamsFuture = null;
        _liveStreamsLoaded = false;
        _liveLoadSource = '';
        _liveCategoriesFuture = Future.value(categories);
        _liveCategoryNamesFuture = null;
      case IptvSearchIndex.typeMovie:
        _vodStreamsFuture = null;
        _vodById = null;
        _vodStreamsLoaded = false;
        _vodLoadSource = '';
        _vodCategoriesFuture = Future.value(categories);
        _vodCategoryNamesFuture = null;
      default:
        _seriesFuture = null;
        _seriesById = null;
        _seriesListLoaded = false;
        _seriesLoadSource = '';
        _seriesCategoriesFuture = Future.value(categories);
        _seriesCategoryNamesFuture = null;
    }
    _memoSyncStamp.remove(type);
    // The Live TV guide subscribes to the same notifier: it must only
    // reload for live rows / live categories. A VOD- or series-only
    // sync landing used to rebuild the whole 55k-channel guide and
    // re-fetch EPG for the visible channels (build #14, SA-4 partial),
    // so the event carries which catalog actually changed.
    notifyCatalogRefreshed(liveCatalogChanged: type == IptvSearchIndex.typeLive);
  }

  Future<List<XtreamCategory>> _fetchCategoriesFor(String type, AbortController? abort) {
    return switch (type) {
      IptvSearchIndex.typeLive => _xtreamApi.getLiveCategories(abortTrigger: abort?.trigger),
      IptvSearchIndex.typeMovie => _xtreamApi.getVodCategories(abortTrigger: abort?.trigger),
      _ => _xtreamApi.getSeriesCategories(abortTrigger: abort?.trigger),
    };
  }

  /// Make sure the search index is populated and fresh (build #23).
  /// Called at bind ([MultiServerManager.addIptvConnection]): seeds the
  /// index from the disk catalog when it is cold, then runs the network
  /// sync when the interval has elapsed. Fire-and-forget — binding must
  /// not wait for a catalog sync. A manual refresh calls
  /// [syncSearchIndex] with force: true instead.
  ///
  /// Build v1.0.11 (R2.3): coalesced — a second caller while one run is
  /// in flight joins the SAME future instead of starting a second sync
  /// (the #29 tester nit: a racing double trigger cost 8 requests
  /// instead of 6; the index-write mutex alone still let the second run
  /// re-fetch a type the first run had just marked failed). Returns the
  /// in-flight run so a caller can await it (the Enter path kicks it
  /// off fire-and-forget and reads the disk meanwhile).
  Future<void>? _ensureSyncedInFlight;

  Future<void> ensureSearchIndexSynced({bool retryTransportErrors = false}) {
    if (!_isXtream) return Future.value();
    final existing = _ensureSyncedInFlight;
    if (existing != null) return existing;
    final future = _runIndexWrite(() async {
      // R4 (D5): another isolate is already syncing — yield instead of
      // duplicating the 6 requests. Best-effort (a stamp written after
      // this check still races), and the in-flight coalescing above
      // covers the same-isolate case. The stamp read runs CONCURRENTLY
      // with the seed: the read may pay a first-load cost on the prefs
      // cache, and awaiting it serially before the seed delayed the
      // sync's first fetch past a search's return (build18 D4). The
      // seed does not depend on the stamp, so the two overlap; the
      // yield decision still gates the fetch loop below.
      final stampElsewhereFuture = isSyncRunningElsewhere();
      await _seedSearchIndexFromDisk();
      if (await stampElsewhereFuture) return;
      // 1.6.11 (background sync): same survival as the manual path —
      // this is the post-restore first sync, and it must not die when
      // the phone locks mid-load.
      await _syncSearchIndex(
        force: false,
        onProgress: null,
        abort: null,
        retryTransportErrors: retryTransportErrors,
        cancelOnBackground: false,
      );
    });
    _ensureSyncedInFlight = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_ensureSyncedInFlight, future)) _ensureSyncedInFlight = null;
      }).catchError((Object _) {}),
    );
    return future;
  }
  Future<List<XtreamCategory>>? _vodCategoriesFuture;
  Future<List<XtreamCategory>>? _seriesCategoriesFuture;
  Future<List<XtreamCategory>>? _liveCategoriesFuture;
  Future<List<M3uEntry>>? _m3uEntriesFuture;

  // Category-name lookups (id -> name), for stripping the provider's
  // category tag from display titles. Fail open to {} when the list
  // cannot be fetched — titles just keep their prefixes.
  Future<Map<String, String>>? _vodCategoryNamesFuture;
  Future<Map<String, String>>? _seriesCategoryNamesFuture;
  Future<Map<String, String>>? _liveCategoryNamesFuture;

  // Favourited VOD/series items (id -> snapshot), persisted per
  // connection. Loaded lazily; setFavorite updates the cached map so
  // browse/search/detail all agree without re-reading prefs.
  IptvItemFavoritesRepository _itemFavoritesRepository =
      const SharedPreferencesIptvItemFavoritesRepository();
  Future<Map<String, IptvFavoriteItem>>? _favoriteItemsFuture;

  /// Test-only override for the favourites repository, so unit tests can
  /// share one store across client instances. Production code never sets
  /// this.
  @visibleForTesting
  set testItemFavoritesRepository(IptvItemFavoritesRepository repository) {
    _itemFavoritesRepository = repository;
    _favoriteItemsFuture = null;
  }

  /// Prefs key for this connection's favourited VOD/series items.
  String get _itemFavoritesKey => 'iptv_fav_items:${connection.id}';

  Future<Map<String, IptvFavoriteItem>> _favoriteItems() =>
      _favoriteItemsFuture ??= _itemFavoritesRepository.read(key: _itemFavoritesKey);

  /// Build #25: max resume entries per connection (OpenTV's
  /// `observeRecent` default). Oldest-first eviction on insert, so the
  /// store stays ~6 KB.
  static const int _maxResumeEntries = 30;

  /// Build #25: the 5-second anti-clutter floor (OpenTV saves only when
  /// `pos > 5_000`; IPTVnator only lists an item after it "actually
  /// played for a couple of seconds"). A report below this never creates
  /// a row, so streams that fail right away don't clutter Continue
  /// Watching.
  static const int _resumeRecordFloorMs = 5000;

  // Resume positions for VOD movies / episodes (id -> snapshot),
  // persisted per connection. Same shape as the favourites store:
  // loaded lazily; the report methods update the cached map so browse /
  // search / detail all agree without re-reading prefs.
  IptvResumeRepository _resumeRepository =
      const SharedPreferencesIptvResumeRepository();
  Future<Map<String, IptvResumeItem>>? _resumeItemsFuture;

  /// Test-only override for the resume repository, so unit tests can
  /// share one store across client instances. Production code never sets
  /// this.
  @visibleForTesting
  set testResumeRepository(IptvResumeRepository repository) {
    _resumeRepository = repository;
    _resumeItemsFuture = null;
  }

  /// Prefs key for this connection's resume positions.
  String get _resumeKey => 'iptv_resume:${connection.id}';

  Future<Map<String, IptvResumeItem>> _resumeItems() =>
      _resumeItemsFuture ??= _resumeRepository.read(key: _resumeKey);

  /// Best-effort display snapshot (title / poster / library) for the
  /// item currently playing, stashed in [getPlaybackInitialization] —
  /// the one place the full item passes through the client at playback
  /// time. The report methods only receive an id, so without this the
  /// stored snapshot would have no title. Purely in-memory and bounded;
  /// a restart loses nothing the catalog re-resolution cannot refill.
  final Map<
    String,
    ({
      String? title,
      String? thumbPath,
      String? libraryId,
      String? parentId,
      String? parentTitle,
      // 1.4.6 G1: the show link for episodes (see IptvResumeItem).
      String? grandparentId,
      String? grandparentTitle,
      // 1.6.11 X9: the show poster, so the snapshot keeps the still
      // fallback when the episode leaves the catalog.
      String? grandparentThumbPath,
      // 1.2.4: the playing item's category id, so the resume row records
      // it (see IptvResumeItem) — the report methods only receive an id.
      String? categoryId,
    })
  >
  _resumeSnapshots = {};

  /// Monotonic last-viewed clock: two stops in the same millisecond must
  /// still order deterministically (newest first), so the clock never
  /// goes backwards within this client.
  int _lastResumeTimestampMs = 0;

  /// Concurrent per-category fallback batch size (Task 8): the panel
  /// answers per-category calls even when the unfiltered call returns [].
  /// 4, not 16 (1.6.12, request discipline): 16 was the sweep's reach
  /// (build #13 — at 8 the sweep missed a match in category 120 inside
  /// its 900ms deadline), but R2.3 deleted the sweep, so the reach
  /// rationale is dead and the crawl is the only user of this size. 4
  /// matches the short-EPG tier cap for panel calls (see
  /// [DevicePerformance.shortEpgFanOut]) — the largest burst the
  /// codebase already allows against the panel — and with the 200ms
  /// gap between batches below, a Trex-scale crawl (150 categories)
  /// still finishes in ~8s in-harness and ~20s at 300ms per call, with
  /// rows publishing per batch so the hub fills progressively. A
  /// per-start pacer at the panel's documented 6–8 req/s flood limit
  /// would have been stricter (5/s), but 150 requests at 5/s is 30s
  /// per crawl and the existing Trex-scale tests do two crawls inside a
  /// 30s timeout — the rate cap and the cold-load time cannot both be
  /// met, so the guard is a bounded burst plus the gap, and the
  /// break-on-refusal in the loops is the backstop (a refusal stops the
  /// crawl at once and the 5-minute breaker blocks further calls).
  static const int _catalogFallbackBatchSize = 4;

  /// Gap between cold-catalog per-category crawl batches (1.6.12,
  /// request discipline): after each batch lands, the crawl waits this
  /// long before starting the next batch, so the batches do not run
  /// back-to-back. Shared by the VOD and series crawls (both go through
  /// the same cold-load path); the live loader has no per-category
  /// crawl. The short-EPG path keeps its own strict 200ms pacer
  /// ([IptvCallPacer]) — its counts are small, so the rate cap costs
  /// nothing there.
  Duration _catalogCrawlBatchGap = const Duration(milliseconds: 200);

  /// Test override for the crawl batch gap — a zero gap keeps crawl
  /// tests fast; the default spaces real loads.
  @visibleForTesting
  set catalogCrawlBatchGap(Duration gap) => _catalogCrawlBatchGap = gap;

  /// Build #21 — the search burst cap. Retained after R2.3 deleted the
  /// sweep: the sections make no panel requests, so no search request
  /// acquires a permit today — the semaphore stays wired through
  /// [_searchItemsInner] so a future search path that needs the panel
  /// reuses this cap instead of inventing a new one. The sizing history
  /// below still applies to any per-category fetching. Before #21, each
  /// section ran 32 concurrent category calls, so a cold search put ~96
  /// requests on a panel that allows 1 connection.
  ///
  /// Why 8: the sweep must still reach the last category ("|EN| TOP
  /// SERIES", 237th of 237) inside the 49s sweep deadline at realistic
  /// per-call latency — that is build #19's heal guarantee, and the
  /// P4-fast probe (1s per call, 232 categories to sweep) is the test
  /// of it. Cap 4 fails it: 232 / 4 x 1s = 58s > 49s, so the heal
  /// misses Game of Thrones on a slow panel. Cap 8 passes it: 232 / 8
  /// x 1s = 29s, with 20s of margin. 8 is the top of the owner's low-end
  /// range (4-8) and the smallest cap that keeps the heal working at
  /// 1s per call; the in-harness reach test proves it at 250ms and
  /// 500ms per call too. A slower panel (6s per call, the P4-slow
  /// stress case) cannot be swept inside the deadline at any cap the owner's
  /// range allows — the unfiltered load, which runs outside the cap, is
  /// the primary path then. 8 is still a 12x cut from the old ~96
  /// concurrent requests, and 4x down from the old per-section 32.
  /// (Build #17's 32 existed only to cover the list inside the deadline
  /// at 6s per call — a degraded panel — and that is exactly the volume
  /// that reads as abuse.)
  static const int _searchBurstCap = 8;

  /// The burst cap, for tests: assert the max in-flight sweep requests
  /// against this, not a literal, so a cap change stays honest.
  @visibleForTesting
  static int get searchBurstCap => _searchBurstCap;

  /// The search-wide burst semaphore (build #21): one per client, shared
  /// by the three sections of every search on this client. Retained after
  /// R2.3 deleted the sweep — the sections make no panel requests, so no
  /// search request acquires a permit today; the semaphore stays wired so
  /// a future search path that needs the panel reuses the cap. A permit
  /// is released when its call lands (or aborts); a permit is never held
  /// past the section budget.
  final _SearchRequestSemaphore _searchBurst = _SearchRequestSemaphore(_searchBurstCap);

  /// Consecutive transient health-probe failures (build #21). A single
  /// timeout / 429 / 5xx / socket error must not flip the server offline
  /// — the panel is slow or throttling, not gone — so the offline verdict
  /// needs this many in a row. Probes are event-driven (resume, manual
  /// reconnect, connectivity change), not periodic, so 3 means three
  /// separate triggers agreed, not one slow probe under a burst.
  static const int _transientFailuresBeforeOffline = 3;

  int _consecutiveTransientHealthFailures = 0;

  /// The in-flight health probe, if one is running (1.6.25 Q-7).
  /// Concurrent [checkHealth] callers share this future instead of
  /// firing a second probe at the same panel.
  Future<HealthStatus>? _inFlightHealthCheck;

  /// The last health verdict this client published (build #21). A
  /// transient probe failure returns this instead of offline, so the app
  /// keeps the last-known state while the panel struggles.
  HealthStatus _lastHealthStatus = HealthStatus.online;

  /// The line's connection limit (build #28), cached from the panel's
  /// `user_info.max_connections` the one time the client calls
  /// `getUserInfo()` — the health probe. Null until the probe has run
  /// (or the panel did not report it): unknown.
  int? _maxConnections;

  /// The connection limit the panel last reported, or null when unknown.
  int? get maxConnections => _maxConnections;

  /// True when this line allows one stream at a time — or when the
  /// limit is unknown (build #28). A one-connection line is the common
  /// Xtream shape, and the wait-for-release cost is bounded by the
  /// player stop completing (usually tens of milliseconds), so waiting
  /// when unsure is the safe default: opening the next stream before
  /// the old one is released stacks two streams on the only session
  /// and the panel answers 458.
  bool get isSingleConnection => _maxConnections == null || _maxConnections == 1;

  /// How long after a recorded 403 the health probe stays backed off
  /// (build #28) — the boards' "wait 5 min with everything closed"
  /// advice, as a duration. Test-overridable.
  @visibleForTesting
  static Duration refusalProbeBackoff = const Duration(minutes: 5);

  /// The refusal log this client consults before probing (build #28).
  /// Defaults to the app-wide singleton; tests inject a log backed by
  /// fake prefs.
  IptvRefusalLog _refusalLog = IptvRefusalLog.instance;

  @visibleForTesting
  set testRefusalLog(IptvRefusalLog log) => _refusalLog = log;

  /// Searches currently in flight on this client (build #21). A health
  /// probe that fires while one is running is deferred, not dropped (see
  /// [_deferredHealthProbe]).
  int _activeSearchCount = 0;

  /// The section AbortControllers of the searches currently in flight on
  /// this client (build #21, close-after-use). [cancelActiveSearches]
  /// aborts every controller in this set, which hard-cancels the
  /// sections' in-flight requests (the sockets close via
  /// AbortableRequest) so a search the user has walked away from — app
  /// backgrounded, connection torn down — stops talking to the panel.
  /// A controller is added when its search starts and removed when the
  /// search's sections all settle; aborting a controller that already
  /// settled is a no-op, so a stale entry is harmless but they are
  /// removed promptly to keep the set bounded.
  final Set<AbortController> _activeSearchAborts = {};

  /// AbortControllers for background panel work currently in flight on
  /// this client (build #28): the weekly index sync and the stale-disk
  /// catalog refreshes. [cancelBackgroundWork] triggers every controller
  /// in this set when the app backgrounds, so work nobody is watching
  /// stops talking to the panel. A controller is added when its job
  /// starts and removed when the job settles; aborting one that already
  /// settled is a no-op. The set never grows past the concurrent
  /// background jobs (6 catalog refreshes + 1 sync).
  final Set<AbortController> _activeBackgroundAborts = <AbortController>{};

  /// A health probe arrived while a search was in flight (build #21).
  /// Cleared when the deferred probe fires, once, after the search ends.
  bool _deferredHealthProbe = false;

  /// The first health check of this client's life has waited for the
  /// WARP tunnel restore to settle (1.6.18 — see [checkHealth]). One
  /// shot: later checks await an already-settled restore, which costs
  /// nothing, so only the first call needs the flag.
  bool _startupTunnelGateDone = false;

  /// Called once, coalesced, when a deferred health probe fires (build
  /// #21): the search has ended and the probe that arrived mid-search
  /// should run now. Set by [MultiServerManager] when it binds the
  /// client; null in tests and for clients the manager never bound. The
  /// manager re-probes this one connection and applies the verdict.
  void Function(IptvClient client)? onDeferredHealthProbe;

  /// Per-section time budget for [searchItems] (build #8 Task 1): a section
  /// that misses its budget returns [] for that search while its catalog
  /// fetch keeps running in the background and warms the cache, so the other
  /// section's results are never held hostage — and the next search finds
  /// the slow section. 50s sits inside the aggregation's 60s IPTV leg
  /// deadline with room for ranking. Tests shrink it.
  @visibleForTesting
  static Duration searchSectionBudget = const Duration(seconds: 50);

  /// Live-channel stream info by channel key (populated by [iptvChannels]).
  final Map<String, XtreamLiveStream> _xtreamChannelByKey = {};
  final Map<String, M3uEntry> _m3uChannelByKey = {};

  /// The FULL live-channel list (including hidden categories/groups)
  /// from the last [refreshLiveChannelsFromNetwork] — 1.2.8 F3. The
  /// published list ([iptvChannels]) and the disk file / live memo hold
  /// visible rows only (the 1.2.7 Low-RAM invariant); Reload needs the
  /// unfiltered list so its match counts can cover hidden channels too.
  /// Set only by a refresh (Reload); null before the first refresh or
  /// when the refresh failed. Retains the hidden rows (~10MB at Trex
  /// scale) until the next refresh — a deliberate, documented cost of
  /// the Reload report, not of normal browsing.
  List<LiveTvChannel>? fullLiveChannelsFromLastRefresh;

  static const String liveLibrarySuffix = 'live';
  static const String moviesLibrarySuffix = 'movies';
  static const String seriesLibrarySuffix = 'series';

  String _libraryId(String suffix) => 'iptv:${connection.id}:$suffix';

  /// Internal attribution id for M3U channel items (fetchItem/searchItems).
  /// It is NOT a library anymore — fetchLibraries never returns it — so
  /// the library picker never shows a Live TV row.
  String get _liveLibraryId => _libraryId(liveLibrarySuffix);
  String get _moviesLibraryId => _libraryId(moviesLibrarySuffix);
  String get _seriesLibraryId => _libraryId(seriesLibrarySuffix);

  Set<String> get _hiddenCategories => _hiddenCategoryIdList.toSet();

  /// Filter generation (1.6.32, option 6): bumped every time the hidden
  /// filter changes in [updateConnection]. The guide's reload
  /// coalescing uses it to tell a re-derive completion (same
  /// generation — the in-flight load already covers this change) from
  /// a NEW toggle that landed while a load was running (new
  /// generation — one more reload is genuinely due).
  int _filterGeneration = 0;

  /// The current filter generation — see [_filterGeneration].
  int get filterGeneration => _filterGeneration;

  /// ONE switch for the 1.2.4 catalog prune (the owner's two-mode decision,
  /// 2026-11-13 ~14:19 EST): the app will have "Low RAM" (on by default
  /// for a first install — visible-only memos, pruned disk cache +
  /// search index) and "Instant search" (opt-in, with a disclaimer that
  /// it uses more RAM and a larger cache file — full disk cache,
  /// instant search/un-hide/guide). The mode setting itself is a
  /// Catalog storage mode (1.2.7, two modes — the owner, 2026-11-13 ~14:19
  /// EST): "Low RAM" (default, first install) prunes hidden rows from
  /// the memos, disk cache and search index; "Instant search" (opt-in)
  /// keeps the full catalog. The mode flips the ONE prune switch below;
  /// a mode switch restores/prunes the full cache via a forced re-sync
  /// (the sync publish + disk write filter through the switch — see
  /// FORK §45 and the 1.2.4 T5 test), so the prune is reversible by
  /// sync, never baked in as irreversible scattered logic. Every
  /// STORAGE filter (memos, disk file, search index) reads the hidden
  /// sets through [_pruneHiddenCategoryIds] /
  /// [_pruneHiddenCategoryInitials] below — never the raw hidden sets —
  /// so the mode build flips one flag, not six call sites.
  ///
  /// The DISPLAY filter ([_isHiddenCategory] and the search/browse
  /// read-time filters) deliberately stays on the raw hidden sets:
  /// hidden categories stay hidden on screen in BOTH modes; the switch
  /// only decides what is STORED.
  static const String catalogModeLowRam = 'lowRam';
  static const String catalogModeInstantSearch = 'instantSearch';

  /// Apply a stored mode value to the prune switch. Unknown values fall
  /// back to Low RAM (pruning on) — a corrupt or future value must never
  /// silently switch the app to the full catalog.
  static void applyCatalogMode(String mode) {
    pruneHiddenCatalogRows = mode != catalogModeInstantSearch;
  }

  static bool pruneHiddenCatalogRows = true;

  /// The hidden sets the storage prune actually applies: the user's
  /// hidden sets in Low RAM mode, empty in Instant search mode
  /// (nothing is pruned, the full catalog is stored).
  Set<String> get _pruneHiddenCategoryIds =>
      pruneHiddenCatalogRows ? _hiddenCategories : const <String>{};

  /// Same as [_pruneHiddenCategoryIds], for category initials.
  Set<String> get _pruneHiddenCategoryInitials =>
      pruneHiddenCatalogRows ? _hiddenCategoryInitials : const <String>{};

  /// Category-initial filter list (only the IPTV connection types carry
  /// it). Build #15, item 5 renamed the storage to `hiddenCategoryIds` /
  /// `hiddenCategoryInitials` with a one-time migration from the build
  /// #6–#14 keys — the values are the same category initials, the keys
  /// are new so the tainted history (build #10 reused the old key with a
  /// new meaning, no migration) cannot repeat.
  List<String> get _hiddenCategoryInitialsList => switch (connection) {
    M3uConnection(:final hiddenCategoryInitials) => hiddenCategoryInitials,
    XtreamConnection(:final hiddenCategoryInitials) => hiddenCategoryInitials,
    _ => const [],
  };

  Set<String> get _hiddenCategoryInitials => _hiddenCategoryInitialsList.toSet();

  /// True when the category with [categoryId] and display [categoryName]
  /// is hidden — by its own switch, or because its category initial is
  /// turned off (build #10 redesign: "Category initials", not "Name
  /// initials"). A category with no initial is only hidden by its own
  /// switch. Items are hidden if and only if their category is hidden;
  /// item names are never filtered — the build #8 name filter hid nearly
  /// every item (the owner hid 161 of 171 initials) while the categories
  /// stayed listed, which emptied every series category and broke search.
  bool _isHiddenCategory(String? categoryId, String? categoryName) {
    if (categoryId != null && _hiddenCategories.contains(categoryId)) return true;
    final initial = categoryInitial(categoryName);
    return initial != null && _hiddenCategoryInitials.contains(initial);
  }

  /// The visible-only filter for one catalog type (1.2.4, catalog
  /// memory): the same rule as [_isHiddenCategory], packaged for the
  /// isolate parsers and the disk writes — a row is hidden by its own
  /// category id, or because its category's initial is turned off.
  /// Built from the disk category names (the warm-up / disk / first-load
  /// paths) or from a just-fetched category list (the sync path), so
  /// the filter and the read-time filter can never disagree about a row.
  Future<VisibleCatalogFilter> _visibleCatalogFilterFor(String type) async {
    final names = await switch (type) {
      IptvSearchIndex.typeLive => _liveCategoryNamesFromDisk(),
      IptvSearchIndex.typeMovie => _vodCategoryNamesFromDisk(),
      _ => _seriesCategoryNamesFromDisk(),
    };
    // The storage filter goes through the prune switch
    // ([pruneHiddenCatalogRows]): with it off the memos hold the full
    // catalog (Instant search) and the disk file stays full.
    return VisibleCatalogFilter.fromCategoryNames(
      names,
      hiddenCategoryIds: _pruneHiddenCategoryIds,
      hiddenInitials: _pruneHiddenCategoryInitials,
    );
  }

  /// Visible rows from a just-fetched list (1.2.4): the sync publish +
  /// disk write filter the fetched rows with the filter built from the
  /// fetched categories — the categories are the fresh truth, so a
  /// category renamed on the panel filters by its new name.
  List<T> _visibleRows<T>(List<T> rows, String? Function(T row) categoryIdOf, VisibleCatalogFilter filter) =>
      rows.where((row) => !filter.isHidden(categoryIdOf(row))).toList();

  /// Public read of [_isHiddenCategory] (v1.0.16): the guide category
  /// submenu resolves the channel's category state through this, so the
  /// menu and the guide rows can never disagree about what is hidden.
  bool isCategoryHidden(String? categoryId, String? categoryName) => _isHiddenCategory(categoryId, categoryName);

  /// M3U groups ARE the categories (the group title is both id and name),
  /// so a group is hidden by its own switch or its category initial.
  bool _isHiddenGroup(String? groupTitle) => _isHiddenCategory(groupTitle, groupTitle);

  @override
  ServerId get serverId => ServerId(connection.id);

  @override
  String? get serverName => _name;

  @override
  MediaBackend get backend => connection.kind;

  @override
  ServerCapabilities get capabilities => const ServerCapabilities(
    liveTv: true,
    liveTvDvr: false,
    videoTranscoding: false,
    richHubs: false,
    numericUserRating: false,
    userFavorites: true,
    continueWatchingRemoval: true,
    externalSubtitleSearch: false,
    richMetadataEdit: false,
    scrubThumbnails: false,
    folderGrouping: false,
    instantMix: false,
    libraryChangeEvents: false,
  );

  @override
  Object get authenticationSessionId => _authSessionId;

  @override
  void close() {
    // Idempotent: tests (and the manager's graceful close) can close
    // the same client twice (explicit close + tearDown) — disposing the
    // notifier twice throws, so the second close is a no-op.
    if (_closed) return;
    _closed = true;
    _api?.close();
    _http.close();
    // Build #23: close the search index connection (the file stays —
    // it is the synced catalog, re-opened on the next bind).
    _searchIndexInstance?.close();
    _searchIndexInstance = null;
    _searchIndexFuture = null;
    searchIndexStateNotifier.dispose();
  }

  /// Cancel every search currently in flight on this client (build #21,
  /// close-after-use — the owner: "should the connection have a close
  /// function so it stops talking after?"). Aborts each in-flight
  /// section's controller, which hard-cancels its requests (the sockets
  /// close via AbortableRequest) so no further panel traffic is
  /// generated for a search the user has walked away from. Called when
  /// the app backgrounds ([MultiServerManager.cancelActiveIptvSearches],
  /// wired in main.dart) and when a connection is torn down. Safe to
  /// call with no search in flight (no-op). The client stays usable
  /// afterwards — only the in-flight searches are cancelled, not the
  /// connection itself (use [close] to tear the connection down).
  /// NOTE: the background catalog crawl is NOT cancelled by this — it
  /// is a bounded batch walk (16 per batch) that populates the disk
  /// cache, and it only runs when the unfiltered load returns []; it
  /// finishes on its own and never re-runs for the same catalog.
  void cancelActiveSearches() {
    for (final abort in _activeSearchAborts.toList()) {
      abort.abort();
    }
  }

  /// Stop background panel work on this client (build #28): the weekly
  /// index sync, the stale-disk catalog refreshes, and the in-flight
  /// EPG fetches. Called when the app backgrounds
  /// ([MultiServerManager.cancelActiveIptvBackgroundWork], wired in
  /// main.dart next to [cancelActiveSearches]) and when a connection is
  /// torn down. Safe to call with nothing in flight (no-op). The client
  /// stays usable afterwards — only the in-flight background jobs are
  /// cancelled, not the connection itself (use [close] to tear the
  /// connection down). A sync parked on playback (see
  /// [_waitForIdleUnlessAborted]) stops too — its wait races the abort.
  void cancelBackgroundWork() {
    for (final abort in _activeBackgroundAborts.toList()) {
      abort.abort();
    }
    _liveTv.cancelBackgroundWork();
  }

  /// Drop the in-memory catalog caches so the next browse/guide load
  /// re-fetches channels, movies and series from the provider (the
  /// "Refresh playlists" action in IPTV settings). An in-flight fetch is
  /// not cancelled; its result is simply discarded. The disk cache is
  /// deleted too (build #11) — a refresh that only cleared memory would
  /// just re-read the same stale files — and the library views are told
  /// the catalog changed so the visible tab reloads with fresh data.
  /// A background refresh started before this call is dropped by the
  /// generation guard, so it can never resurrect the cleared catalog.
  void clearCatalogCache() {
    _catalogGeneration++;
    _liveStreamsFuture = null;
    _vodStreamsFuture = null;
    _vodById = null;
    _seriesFuture = null;
    _seriesById = null;
    _vodStreamsLoaded = false;
    _seriesListLoaded = false;
    _liveStreamsLoaded = false;
    _vodPartialRows.clear();
    _seriesPartialRows.clear();
    _vodCrawledCategoryIds.clear();
    _seriesCrawledCategoryIds.clear();
    _vodCategoriesFuture = null;
    _seriesCategoriesFuture = null;
    _liveCategoriesFuture = null;
    _m3uEntriesFuture = null;
    _vodCategoryNamesFuture = null;
    _seriesCategoryNamesFuture = null;
    _liveCategoryNamesFuture = null;
    _favoriteItemsFuture = null;
    _seriesInfoFutures.clear();
    _seasonEpisodeItemsCache.clear();
    _vodInfoFutures.clear();
    _xtreamChannelByKey.clear();
    _invalidateGuideChannelCache();
    _m3uChannelByKey.clear();
    unawaited(_catalogCache.clear(connection.id));
    // Build #23: the search index is derived from the catalog, so a
    // clear rebuilds it too — the next search falls back to the
    // disk/sync paths until the next sync seeds it again. The index
    // file itself is NOT deleted (the rows are, per connection), so the
    // schema and the other connections' rows survive.
    unawaited(_clearSearchIndex());
    // A manual clear is the user's own action: the tabs must refresh
    // promptly, not at the pacer cooldown's trailing edge (build #14).
    notifyCatalogRefreshed(userInitiated: true);
  }

  /// Drop the in-memory catalogs under memory pressure (1.2.4, item
  /// 1): null the three memo futures + loaded flags + partials +
  /// category futures + channel maps + series-info futures, so the
  /// whole memo heap is collectable and the next browse/search re-reads
  /// from disk (no network). A RELIEF VALVE, not a refresh — unlike
  /// [clearCatalogCache] it deletes NO disk/index data, bumps NO
  /// generation, and sends NO notification: the UI keeps serving from
  /// disk on the next load, and nothing the user sees changes except
  /// the memory footprint. Wired to [didHaveMemoryPressure] and the
  /// RSS watchdog (see main.dart).
  void dropCatalogFromMemory() {
    _liveStreamsFuture = null;
    _vodStreamsFuture = null;
    _vodById = null;
    _seriesFuture = null;
    _seriesById = null;
    _vodStreamsLoaded = false;
    _seriesListLoaded = false;
    _liveStreamsLoaded = false;
    _vodPartialRows.clear();
    _seriesPartialRows.clear();
    _vodCrawledCategoryIds.clear();
    _seriesCrawledCategoryIds.clear();
    _vodCategoriesFuture = null;
    _seriesCategoriesFuture = null;
    _liveCategoriesFuture = null;
    _vodCategoryNamesFuture = null;
    _seriesCategoryNamesFuture = null;
    _liveCategoryNamesFuture = null;
    _seriesInfoFutures.clear();
    _seasonEpisodeItemsCache.clear();
    _vodInfoFutures.clear();
    _xtreamChannelByKey.clear();
    _invalidateGuideChannelCache();
    _m3uChannelByKey.clear();
    // 1.6.11 P6: the M3U live-entries list survived the drop, so part
    // of the browsing heap stayed resident through trim / watchdog /
    // background drops. Re-reads from the disk cache file on next use
    // (no network), same as the other memos.
    _m3uEntriesFuture = null;
  }

  /// Drop the in-memory EPG guide under memory pressure (1.2.4, item
  /// 1) — delegates to [IptvLiveTvSupport.dropEpgFromMemory]. Kept
  /// separate from [dropCatalogFromMemory] so the manager can drop
  /// both in one pass (see [MultiServerManager.dropIptvCachesFromMemory]).
  void dropEpgFromMemory() => _liveTv.dropEpgFromMemory();

  /// Memory stats for the pressure/watchdog telemetry (1.2.18 S-4c):
  /// which memos are resident + the guide's retained programmes and
  /// short-EPG entries. Row/byte counts for the memos do not exist
  /// (the futures hold no sync size), so the loaded flags are the
  /// honest proxy — the RSS-after number is the proof of the trim.
  ({bool liveMemoLoaded, bool vodMemoLoaded, bool seriesMemoLoaded, int epgCacheEntries, int retainedFeedPrograms})
      get memoryStats => (
            liveMemoLoaded: _liveStreamsLoaded,
            vodMemoLoaded: _vodStreamsLoaded,
            seriesMemoLoaded: _seriesListLoaded,
            epgCacheEntries: _liveTv.epgCacheEntries,
            retainedFeedPrograms: _liveTv.retainedFeedPrograms,
          );

  /// Public trim entry for [MultiServerManager.trimIptvCachesIfHot]
  /// (1.2.18 S-10): the playback-start trim runs through the manager,
  /// which loops every connection.
  void trimCachesIfHot(String job, {bool after = false}) => _trimCachesIfHot(job, after: after);

  /// Pre-emptive trim before a heavy job (1.2.18 S-4b): the image
  /// cache goes only when RSS is already above half the watchdog
  /// threshold; the oldest half of the guide's short-EPG cache goes
  /// UNCONDITIONALLY on every call ([trimEpgCacheBeyondWindow] evicts
  /// to 32 entries regardless of RSS — the "when hot" name covers the
  /// image half only), so the spike starts with headroom. (1.2.18
  /// S-4b; the same helper serves the post-parse trim in the live-TV
  /// support — see [IptvLiveTvSupport._trimCachesIfHot].) Logged so
  /// the next dump proves the trim happened.
  void _trimCachesIfHot(String job, {bool after = false}) {
    final imageTrimmed = IptvHeavyWorkGate.trimImageCacheBeforeHeavyJob();
    final epgEvicted = _liveTv.trimEpgCacheBeyondWindow();
    if (imageTrimmed || epgEvicted > 0) {
      appLogger.i(
        'IPTV: cache trim ${after ? 'after' : 'before'} $job (image cache cleared: $imageTrimmed, short-EPG entries evicted: $epgEvicted)',
      );
    }
  }

  /// Clear the disk catalog + search index rows for this connection
  /// (build #23): called by the manager when it replaces the client
  /// for a data-source change (new server URL / credentials), so the new
  /// client never serves the old source's data. Awaited before the
  /// warm-ups — the new client starts cold and the background sync
  /// fetches the new source. Unlike [clearCatalogCache] this deletes the
  /// index rows even when this client never opened the index (the rows
  /// belong to the connection id, shared across client instances).
  Future<void> clearCatalogForNewDataSource() async {
    await _catalogCache.clear(connection.id);
    final index = await _searchIndex();
    if (index != null) {
      await _runIndexWrite(() => index.deleteConnection(connection.id));
      _refreshSearchIndexState();
    }
  }

  Future<void> _clearSearchIndex() async {
    // Only when the index was already opened: opening it just to delete
    // rows that cannot exist yet would create the file for nothing.
    final index = _searchIndexInstance;
    if (index == null) return;
    await _runIndexWrite(() => index.deleteConnection(connection.id));
    _refreshSearchIndexState();
  }

  /// Tell the app's library views that this connection's catalog changed
  /// (build #11): the Libraries/Home tabs already listen to
  /// [LibraryContentNotifier] for server pushes, so a background refresh
  /// landing (or a manual clear) reuses their paced, scroll-aware reload
  /// — visible tabs update in place, hidden ones reload when next shown.
  /// The Live TV guide listens to it too (build #13). Public so the
  /// manager can fire it when a rebind replaces this client: without it
  /// a filter toggle shows stale lists until a restart.
  ///
  /// [userInitiated] marks the change as the user's own action (a filter
  /// toggle / connection edit rebind, a manual playlist refresh) so
  /// consumers bypass the [RefreshPacer] cooldown for it (build #14).
  /// Background refresh landings leave it false and stay paced.
  ///
  /// [liveCatalogChanged] marks whether the change can affect the live-TV
  /// catalog; the Live TV guide ignores events that are false (build #14,
  /// SA-4 partial). Defaults to true — a clear, a rebind and an M3U
  /// refresh all touch live channels.
  void notifyCatalogRefreshed({bool userInitiated = false, bool liveCatalogChanged = true}) {
    LibraryContentNotifier().notifyChanged(
      LibraryChangeEvent(
        serverId: ServerId(connection.id),
        itemsUpdated: true,
        userInitiated: userInitiated,
        liveCatalogChanged: liveCatalogChanged,
      ),
    );
  }

  @override
  LibraryEventChannel? createLibraryEventChannel() => null;

  @override
  bool get isOfflineMode => _offline;

  @override
  void setOfflineMode(bool offline) => _offline = offline;

  @override
  ApiCache get cache => ApiCache.forBackend(backend);

  /// Headers for direct-play stream opens from this panel (build #22):
  /// the same configured Xtream User-Agent the API client sends, so the
  /// stream carries one identity with the catalog calls instead of
  /// mpv/ffmpeg's default. Re-read per access (like [_xtreamUserAgent]),
  /// so a Settings change applies to the next open. Applies to Xtream and
  /// M3U alike — both serve streams from the provider. Super Spoof
  /// (1.6.11) applies here too when the streams piece is on.
  @override
  Map<String, String> get streamHeaders => _directFetchHeaders();

  /// Headers for artwork fetches from this panel (build #22): posters and
  /// channel logos carry the same configured Xtream User-Agent instead of
  /// 'PlenTV'. Read by [MediaImageHelper.artworkHeadersFor]. Super Spoof
  /// (1.6.11) applies here too when the streams piece is on.
  Map<String, String> get artworkHeaders => _directFetchHeaders();

  @override
  double get watchedThreshold => 0.9;

  /// Build #25 (trap T4): the stop report IS the watched-mark for IPTV
  /// — [reportPlaybackStopped] deletes a resume entry at/above the
  /// threshold — so the tracker must not also issue an explicit
  /// [markWatched] on every finished stop (it would call the local-only
  /// no-op path and claim the server acknowledged a mark that never
  /// happened). With this true, the tracker settles the watch from the
  /// stop report alone and only emits the local watched event.
  @override
  bool get marksWatchedOnPlaybackStopped => true;

  @override
  LiveTvSupport get liveTv => _liveTv;

  /// True when the refusal log holds a 403 for this connection recorded
  /// within [XtreamApi.breakerCooldown] (1.4.3 C3 — the 403 circuit
  /// breaker, shared by the health probe and every panel call site).
  /// Only a 403 (access denied) opens the breaker — a 429 is
  /// rate-limiting, not a refusal, and the probe is how the app learns
  /// the panel recovered. A log that cannot be loaded says nothing, so
  /// the probe runs (fail-open: a broken log must not take the server
  /// offline). The check is best-effort by construction: a refusal
  /// recorded fire-and-forget a moment earlier may not have persisted
  /// yet, so one probe can slip through — one call, not a sweep. The
  /// API client's in-memory flag covers that same-instance race; this
  /// log half covers restarts and other instances. A manual clear
  /// ([clear403Cooldown]) after a 403 means the owner deliberately
  /// re-asked — 403s at or before it do not open the breaker.
  DateTime? _breakerClearedAt;

  Future<bool> _isIn403Cooldown() async {
    // 1.4.3 G3: the API's in-memory flag is set the moment a 403 is
    // seen; the log write behind it can lag ~500 ms (its network
    // probe), and a guard that only reads the log would miss a
    // refusal that just happened — the row that just failed with
    // the feed's "failed recently" StateError would not be marked
    // refused. The flag is this client's own API instance, so it
    // cannot leak across connections; a manual clear resets it
    // (see [clear403Cooldown]). The flag-only read (not the API's
    // full isIn403Cooldown, whose provider fallback calls back
    // into this method) keeps it recursion-free.
    if (_api?.isBreakerOpenInMemory ?? false) return true;
    try {
      await _refusalLog.ensureLoaded();
    } catch (_) {
      return false;
    }
    final cutoff = DateTime.now().subtract(XtreamApi.breakerCooldown);
    final clearedAt = _breakerClearedAt;
    return _refusalLog.entriesNotifier.value.any(
      (e) =>
          e.connectionId == connection.id &&
          e.statusCode == 403 &&
          e.timestamp.isAfter(cutoff) &&
          (clearedAt == null || e.timestamp.isAfter(clearedAt)),
    );
  }

  /// Whether the 403 circuit breaker is open for this connection
  /// (1.4.3 C3). The guide tab (sweep, row retry) and the detail
  /// screens (seasons retry) read this instead of re-firing the panel.
  Future<bool> get isIn403Cooldown => _isIn403Cooldown();

  /// Manually clear the 403 circuit breaker (1.4.3 C3): the refusals
  /// screen Clear (via the log) and the Settings manual Retry call
  /// this so a deliberate retry re-fires once instead of waiting out
  /// the window. Clears this client's in-memory flag (via the API
  /// client) and stamps the manual clear so log entries at or before
  /// it stop opening the breaker.
  void clear403Cooldown() {
    _breakerClearedAt = DateTime.now();
    _api?.clearBreaker();
  }

  /// One user-initiated force probe (1.6.13): a single real request
  /// with the current settings, fired even while the 403 breaker is
  /// open — the detail-page Retry and the refusals-screen Test call
  /// this so an explicit tap can check whether a settings change lifted
  /// the block. M3U connections have no Xtream API to probe, so they
  /// report not-ok with no status. The probe never clears the breaker
  /// itself: the caller clears it only when the probe proves the panel
  /// answers (see the detail-page Retry), so a failed probe leaves the
  /// hold exactly as it was.
  Future<({bool ok, int? statusCode, String? message})>
  forceProbeAccess() {
    if (!_isXtream) {
      return Future.value((
        ok: false,
        statusCode: null,
        message: 'Not an Xtream connection',
      ));
    }
    return _xtreamApi.forceProbeAccess();
  }

  /// True when the refusal log holds a 403 for this connection recorded
  /// within [refusalProbeBackoff] (build #28) — the health-probe half
  /// of the 403 circuit breaker (1.4.3 C3 delegates to the shared
  /// check, so the probe and the call sites agree about the window).
  /// Whether this connection has a recent 403 in the refusal log
  /// (build #28 — the health-probe guard). Log-only, with the
  /// [refusalProbeBackoff] window: the log write lags a 403 by ~500 ms
  /// (its network probe), and that lag is load-bearing — a probe fired
  /// immediately after a 403 still runs and publishes its own verdict
  /// (build #20's accessDenied, build #21's 401→authError). The guard
  /// only bites once the entry lands, for later resumes. This is
  /// deliberately NOT the 1.4.3 breaker check: the in-memory flag
  /// would close the lag window and the probe would return the
  /// last-known verdict (which defaults to online) instead of the
  /// verdict the probe itself would publish.
  Future<bool> _hasRecentRefusal() async {
    try {
      await _refusalLog.ensureLoaded();
    } catch (_) {
      return false;
    }
    final cutoff = DateTime.now().subtract(refusalProbeBackoff);
    return _refusalLog.entriesNotifier.value.any(
      (e) => e.connectionId == connection.id && e.statusCode == 403 && e.timestamp.isAfter(cutoff),
    );
  }

  @override
  Future<HealthStatus> checkHealth() async {
    // 1.6.18: the first health check of this client's life waits for
    // the WARP tunnel restore to settle when the toggle is on. On a
    // cold start the restore runs after the first frame while binding
    // probes the panel in the same window, so without this the first
    // probe goes out direct and 403s — then arms the 5-minute refusal
    // backoff (the 1.6.17 phone log: first request 74 ms before
    // tunnel-on).
    // 1.6.30 (P0.3/F3): the gate now FAILS CLOSED through the shared
    // [WarpTunnelService.waitForTunnelReady]. The old comment ("the
    // gate must never take the health check down with it") is
    // superseded: proceeding costs a 403 + backoff, worse than one
    // skipped probe cycle. When the toggle is on but the tunnel is
    // still starting after the bound, return the last-known verdict
    // with no panel call — the same shape as the refusal and
    // unreachable early returns directly below.
    if (!_startupTunnelGateDone) {
      _startupTunnelGateDone = true;
      final ready = await WarpTunnelService.instance.waitForTunnelReady();
      if (!ready) {
        bool tunnelStillStarting = false;
        try {
          tunnelStillStarting =
              WarpTunnelService.instance.toggleOn && !WarpTunnelService.instance.isOn;
        } catch (_) {
          // Settings unreadable: proceed as before.
        }
        if (tunnelStillStarting) {
          appLogger.d('IPTV health probe skipped: tunnel still starting, cached verdict');
          return _lastHealthStatus;
        }
      }
    }
    // 1.2.19, L-23: a panel remembered unreachable on this network is
    // not re-probed — return the last-known verdict with no panel call
    // (same shape as the refusal guard below). The verdict lasts 24 h,
    // a network change re-probes, and Settings → IPTV offers a manual
    // Retry. The lookup is a cached-prefs read, never a network call.
    if (await PanelReachabilityStore.isUnreachable(connectionId: connection.id)) {
      appLogger.d('IPTV health probe skipped: panel remembered unreachable on this network');
      return _lastHealthStatus;
    }
    // Build #28: after a refusal, do not re-probe the panel on every
    // resume. A refused `player_api.php` call counts toward the panel's
    // flood limit, so a probe that lands on a panel that just refused
    // us feeds the very block it is trying to measure. While the
    // refusal log holds a 403 for this connection recorded within
    // [refusalProbeBackoff], return the last-known verdict with no
    // panel call. After the window, probe normally. A fresh sign-in
    // bypasses this (different path — the user explicitly asked).
    if (await _hasRecentRefusal()) {
      // 1.6.18: say so in the log — before this the cached return
      // logged the same "health check failed" line at the caller as a
      // fresh 403, so the 1.6.17 phone log's :42/:50 "accessDenied"
      // lines looked like live refusals when no request went out at all.
      appLogger.d(
        'IPTV health probe skipped: cached verdict (403 within ${refusalProbeBackoff.inMinutes} min backoff, no panel call)',
      );
      return _lastHealthStatus;
    }
    // Build #21: a probe that fires while a search is in flight is
    // deferred, not dropped. The search is already exercising the panel,
    // and a concurrent probe just adds a request to a busy line. Return
    // the last-known verdict with no request; the probe runs once,
    // coalesced, when the search ends (see [_fireDeferredHealthProbe]).
    if (_activeSearchCount > 0) {
      _deferredHealthProbe = true;
      appLogger.d('IPTV health probe deferred: search in flight, cached verdict');
      return _lastHealthStatus;
    }
    // 1.6.25 Q-7: coalesce concurrent probes — two callers racing a slow
    // panel used to fire two probes (two panel requests, and the second
    // one's streak write could land on the first one's verdict). The
    // first caller runs the probe; later callers share its future and
    // get the same verdict. The cheap cached returns above (tunnel gate,
    // unreachable, refusal, search-deferred) stay outside the guard:
    // they cost no request and must still answer immediately.
    if (_inFlightHealthCheck != null) return _inFlightHealthCheck!;
    final probe = _probeHealth();
    _inFlightHealthCheck = probe;
    try {
      return await probe;
    } finally {
      _inFlightHealthCheck = null;
    }
  }

  /// The panel probe itself, extracted so [checkHealth] can coalesce
  /// concurrent callers onto one in-flight probe (1.6.25 Q-7).
  Future<HealthStatus> _probeHealth() async {
    if (_isXtream) {
      try {
        final info = await _xtreamApi.getUserInfo();
        if (info == null) return _publishHealth(HealthStatus.authError);
        // Build #28: cache the line's connection limit from the one
        // `getUserInfo()` the client makes — the zap path and the
        // pre-tune gate read it (see [isSingleConnection]). A reply
        // without the field leaves the previous value alone.
        final maxConnections = int.tryParse('${info['max_connections']}');
        if (maxConnections != null) _maxConnections = maxConnections;
        return _publishHealth(HealthStatus.online);
      } on MediaServerAuthException {
        return _publishHealth(HealthStatus.authError);
      } on MediaServerHttpException catch (e) {
        if (e.statusCode == 403) return _publishHealth(HealthStatus.accessDenied);
        // A cancelled probe says nothing about the server — and it is
        // not a failure, so it does not advance the transient streak.
        if (e.isCancellation) return _lastHealthStatus;
        // Build #21: timeouts, 429s and 5xx are transient — the panel is
        // slow or throttling, not gone. They need N in a row before the
        // server is published offline (see [_recordTransientHealthFailure]).
        if (e.isTransient || e.statusCode == 429 || (e.statusCode != null && e.statusCode! >= 500)) {
          // 1.2.19, L-23: only a network-shaped failure (timeout / socket
          // error — the panel never answered) can record an unreachable
          // verdict. A 429/5xx answered, so there is no blackhole wait to
          // skip.
          return _recordTransientHealthFailure(networkShaped: e.isTransient);
        }
        // Any other 4xx (400/404/405/410...) is NOT definitive (1.6.25
        // Q-2): a 404 can be a transient panel state, and publishing
        // offline on the first one dropped Trex on a single bad probe.
        // They count as strikes instead — three in a row still publishes
        // offline, so a genuinely wrong URL goes offline, just not on
        // the first probe. A 4xx answered, so it never records the
        // panel-unreachable verdict (networkShaped is false for an
        // HTTP verdict, same as the 429/5xx branch above).
        return _recordTransientHealthFailure(networkShaped: e.isTransient);
      } catch (e) {
        appLogger.d('IPTV health probe failed', error: e);
        // Not an HTTP verdict at all (defensive: getUserInfo only throws
        // the two typed exceptions above). A network-shaped failure is
        // transient; anything else publishes offline.
        if (MediaServerHttpException.from(e).isTransient) {
          return _recordTransientHealthFailure(networkShaped: true);
        }
        return _publishHealth(HealthStatus.offline);
      }
    }
    try {
      final response = await _http.head(Uri.parse(_m3u.playlistUrl)).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) return _publishHealth(HealthStatus.online);
      if (response.statusCode == 401) return _publishHealth(HealthStatus.authError);
      if (response.statusCode == 403) return _publishHealth(HealthStatus.accessDenied);
      if (response.statusCode == 429 || response.statusCode >= 500) return _recordTransientHealthFailure();
      // 1.6.25 Q-2: any other 4xx counts as a strike, like the Xtream
      // path above — a single 404 must not publish offline on its own.
      if (response.statusCode >= 400 && response.statusCode < 500) return _recordTransientHealthFailure();
      return _publishHealth(HealthStatus.offline);
    } catch (e) {
      appLogger.d('IPTV health probe failed', error: e);
      if (MediaServerHttpException.from(e).isTransient) {
        return _recordTransientHealthFailure(networkShaped: true);
      }
      return _publishHealth(HealthStatus.offline);
    }
  }

  /// Publish a definitive health verdict: reset the transient streak and
  /// remember the verdict as the last-known state (build #21).
  HealthStatus _publishHealth(HealthStatus status) {
    _consecutiveTransientHealthFailures = 0;
    _lastHealthStatus = status;
    return status;
  }

  /// Record one transient health-probe failure (build #21): a timeout,
  /// 429, 5xx or socket error. Returns the last-known verdict until the
  /// streak reaches [_transientFailuresBeforeOffline], then publishes
  /// offline — the panel has failed three separate probes in a row, so
  /// it is down, not merely slow.
  ///
  /// 1.2.19, L-23: when the streak that publishes offline was
  /// network-shaped ([networkShaped] — timeouts / socket errors, the
  /// panel never answered), remember the panel unreachable on this
  /// network so the next launch skips the 10–30 s probe wait. A 429/5xx
  /// streak is not recorded: the panel answered.
  HealthStatus _recordTransientHealthFailure({bool networkShaped = false}) {
    _consecutiveTransientHealthFailures++;
    if (_consecutiveTransientHealthFailures >= _transientFailuresBeforeOffline) {
      if (networkShaped) {
        // Fire-and-forget: the verdict is a hint, never load-bearing.
        unawaited(PanelReachabilityStore.recordUnreachable(connectionId: connection.id));
      }
      return _publishHealth(HealthStatus.offline);
    }
    return _lastHealthStatus;
  }

  /// Fire the health probe deferred during a search (build #21), once.
  /// The manager re-probes this one connection; without a manager binding
  /// there is nothing to fire and the flag just clears.
  void _fireDeferredHealthProbe() {
    if (!_deferredHealthProbe) return;
    _deferredHealthProbe = false;
    onDeferredHealthProbe?.call(this);
  }

  @override
  Future<String?> getMachineIdentifier() async => connection.id;

  // -- Catalog loading (lazy, in-memory + disk) ---------------------------

  /// Read a cached catalog payload from disk and parse it with the same
  /// parser the network path uses. Returns null (a miss) when there is no
  /// file, when it cannot be parsed, or when it parses to no rows — an
  /// empty cached catalog is never served, for the same reason an empty
  /// network result is never cached in memory (this panel returns [] for
  /// the unfiltered call at 199k rows). A corrupt file is deleted so it
  /// reads as a miss exactly once.
  Future<({List<T> rows, DateTime fetchedAt})?> _readDiskCatalog<T>(
    String dataset,
    Future<List<T>> Function(String body) parse,
  ) async {
    final cached = await _catalogCache.read(connection.id, dataset);
    if (cached == null) return null;
    try {
      final rows = await parse(cached.body);
      // 1.2.4: a successfully-parsed empty list is a VALID cached
      // catalog (every row hidden — the deliberate empty-array file,
      // FORK §45.3), not corruption: serve it, do not delete it.
      // Corruption still throws below and falls back to the network.
      // A transient empty panel answer never writes a file (the
      // first-load loaders and the sync's partial guard both skip
      // it), so an empty file on disk can only be the deliberate one.
      return (rows: rows, fetchedAt: cached.fetchedAt);
    } catch (e) {
      appLogger.w('IPTV: cached $dataset catalog unreadable; refetching', error: e);
      unawaited(_catalogCache.delete(connection.id, dataset));
      return null;
    }
  }

  /// File-path variant of [_readDiskCatalog] (1.2.6, catalog memory,
  /// item 4): the path goes to the isolate and the file is read THERE,
  /// so the main isolate never holds the tens-of-MB body and `compute`
  /// never copies it across the port — the whole-body message copy that
  /// drove the bind peak is gone. Same miss semantics as
  /// [_readDiskCatalog]: no file is null, a corrupt file is logged,
  /// deleted and null (and a successfully parsed empty list is still a
  /// valid catalog — the deliberate all-hidden file, FORK §45.3).
  Future<({List<T> rows, DateTime fetchedAt})?> _readDiskCatalogFromFile<T>(
    String dataset,
    Future<List<T>> Function(String path) parseFile,
  ) async {
    final path = await _catalogCache.filePath(connection.id, dataset);
    if (path == null) return null;
    try {
      final fetchedAt = (await File(path).stat()).modified;
      final rows = await parseFile(path);
      return (rows: rows, fetchedAt: fetchedAt);
    } catch (e) {
      appLogger.w('IPTV: cached $dataset catalog unreadable; refetching', error: e);
      unawaited(_catalogCache.delete(connection.id, dataset));
      return null;
    }
  }

  /// Best-effort disk write for freshly fetched rows, serialized back to
  /// the API's JSON shape so the cached payload re-parses through the
  /// same parsers. Fire-and-forget: awaiting a tens-of-MB write would
  /// gate the browse on file I/O. Empty results are never written.
  /// Generation-guarded: a write scheduled before a [clearCatalogCache]
  /// deletes its own file afterwards, so a late write can never resurrect
  /// a catalog the user just cleared.
  /// 1.6.11 P9: the disk write streams row-by-row through
  /// [IptvCatalogDiskCache.writeJsonArray] instead of building the
  /// whole catalog as one JSON String first — same bytes on disk, no
  /// tens-of-MB transient. Fire-and-forget + generation-guarded like
  /// [_writeDiskText]: a stale-generation write is deleted, never
  /// served.
  void _writeDiskCatalog<T>(String dataset, List<T> rows, Map<String, dynamic> Function(T row) toJson) {
    if (rows.isEmpty) return;
    final generation = _catalogGeneration;
    unawaited(
      _catalogCache.writeJsonArray(connection.id, dataset, rows, toJson).then((_) async {
        if (generation != _catalogGeneration) {
          await _catalogCache.delete(connection.id, dataset);
        }
      }),
    );
  }

  /// Same generation-guarded fire-and-forget write, for a raw text
  /// payload (the M3U playlist). See [_writeDiskCatalog].
  void _writeDiskText(String dataset, String body) {
    if (body.isEmpty) return;
    final generation = _catalogGeneration;
    unawaited(
      _catalogCache.write(connection.id, dataset, body).then((_) async {
        if (generation != _catalogGeneration) {
          await _catalogCache.delete(connection.id, dataset);
        }
      }),
    );
  }

  /// Persist a streamed hub download as the disk cache (1.2.16).
  /// Fire-and-forget + generation-guarded like [_writeDiskText]: the
  /// browse must never wait on file I/O. Nothing hidden: the temp file
  /// moves straight to the disk path (it IS the visible body).
  /// Something hidden: the isolate writes the visible-only file from
  /// it ([writeVisible]), then the temp dir is deleted. A disk-write
  /// failure never fails the load — the in-memory rows stand, and the
  /// next sync repairs the disk file.
  void _persistHubDownload(
    String dataset,
    String tempPath,
    VisibleCatalogFilter filter,
    Future<void> Function(String sourcePath, String destPath, VisibleCatalogFilter filter) writeVisible,
  ) {
    final generation = _catalogGeneration;
    unawaited(
      () async {
        try {
          final dest = await _catalogCache.writeFilePath(connection.id, dataset);
          if (dest == null) {
            // Disk disabled (widget tests): drop the temp file.
            XtreamApi.deleteHubTempFile(tempPath);
            return;
          }
          if (generation != _catalogGeneration) {
            XtreamApi.deleteHubTempFile(tempPath);
            return;
          }
          if (filter.isNoOp) {
            Directory(dest).parent.createSync(recursive: true);
            File(tempPath).renameSync(dest);
            XtreamApi.deleteHubTempFile(tempPath);
          } else {
            await writeVisible(tempPath, dest, filter);
            XtreamApi.deleteHubTempFile(tempPath);
          }
        } catch (e) {
          appLogger.w('IPTV: hub disk persist failed for $dataset', error: e);
          XtreamApi.deleteHubTempFile(tempPath);
        }
      }(),
    );
  }

  /// Build v1.0.10 (M3, one freshness rule): the browse refresh IS the
  /// sync. After serving disk rows, fire [ensureSearchIndexSynced] when
  /// this type is due under the sync interval — the sync fetches the
  /// catalog + categories once, under the guards, and writes disk +
  /// index together, so one fetch feeds both stores and a partial panel
  /// answer can never clobber a good disk file through a side door.
  /// When the type is not due (or the interval is manual-only) nothing
  /// is fetched: the disk file's age follows the index's last sync, not
  /// a separate 24 h clock. The due check is coarse (the sync itself
  /// re-checks per type and skips what is up-to-date), and several
  /// browse loads firing at once serialize through the index-write
  /// mutex — the second run finds everything up-to-date and fetches
  /// nothing. The sync keeps build #28's gating (it waits for idle
  /// while a stream is playing and is cancellable on backgrounding),
  /// and the seed that runs first stamps the disk's real age (M1), so
  /// the due check here reads true ages.
  ///
  /// This replaces [_refreshCatalogInBackground] (deleted with it): the
  /// old side door bypassed the sync guards, never wrote the index, and
  /// had no partial guard for live at all (M4 — the sync's guard covers
  /// live too).
  void _refreshCatalogViaSyncIfDue(String type) {
    if (!_isXtream) return;
    unawaited(
      () async {
        final index = await _searchIndex();
        if (index == null) return;
        final intervalHours = _catalogSyncIntervalHours();
        if (intervalHours == 0) return; // Manual-only: no automatic refresh.
        final lastSync = index.lastSync(connection.id)[type];
        // 1.2.4: the stamp is the freshness signal, not the row count —
        // a stamped land with 0 rows is a deliberate empty land (every
        // category hidden), and treating it as due would re-sync on
        // every browse load.
        final due = lastSync == null ||
            DateTime.now().difference(lastSync).inHours >= intervalHours;
        if (due) unawaited(ensureSearchIndexSynced());
      }(),
    );
  }

  Future<List<XtreamLiveStream>> _liveStreams() async {
    await _invalidateMemoIfIndexAdvanced(IptvSearchIndex.typeLive);
    final cached = _liveStreamsFuture;
    if (cached != null) return cached;
    final future = _loadLiveStreamsCached().catchError((Object e) {
      _liveStreamsFuture = null;
      throw e;
    });
    _liveStreamsFuture = future;
    final result = await future;
    // An empty result is never cached: a transient empty payload must
    // not poison every later view until restart (same rule as VOD/series).
    if (result.isEmpty) {
      _liveStreamsFuture = null;
    } else {
      _liveStreamsLoaded = true;
    }
    await _recordMemoStamp(IptvSearchIndex.typeLive);
    return result;
  }

  /// Disk first (build #11): a cached live list is served immediately;
  /// a due one is served and refreshed by the sync (build v1.0.10, one
  /// freshness rule — the sync interval, not a separate 24 h clock).
  /// No disk cache (first run, cleared, corrupt) falls back to the
  /// network fetch.
  Future<List<XtreamLiveStream>> _loadLiveStreamsCached() async {
    // 1.2.4 (catalog memory): the memo AND the disk file hold visible
    // rows only — the parse filters inside the isolate, so a disk file
    // written before 1.2.4 (full catalog) is pruned at read time. The
    // filter is built from the disk category names; on a first launch
    // before the sync lands those names may not exist yet, so
    // hidden-by-initial rows can briefly slip into the memo — the sync
    // publish + next sync prune heal it (see FORK §45).
    final filter = await _visibleCatalogFilterFor(IptvSearchIndex.typeLive);
    final disk = await _readDiskCatalogFromFile<XtreamLiveStream>(
      IptvCatalogDiskCache.liveDataset,
      (path) => XtreamApi.parseLiveStreamsFileVisible(path, filter),
    );
    if (disk != null) {
      _liveLoadSource = 'disk';
      _refreshCatalogViaSyncIfDue(IptvSearchIndex.typeLive);
      return disk.rows;
    }
    final rows = await _xtreamApi.getLiveStreams();
    _liveLoadSource = 'network';
    final visible = _visibleRows(rows, (r) => r.categoryId, filter);
    // 1.2.19 (A1): the load streamed to a temp file — the file IS the
    // raw body, so persist it without ever holding it as a String (see
    // [_persistHubDownload]). A test fake with no file falls back to
    // the direct encode (test scale).
    final rawFilePath = _xtreamApi.lastLiveStreamsFilePath;
    if (visible.isNotEmpty) {
      if (rawFilePath != null) {
        _persistHubDownload(
          IptvCatalogDiskCache.liveDataset,
          rawFilePath,
          filter,
          XtreamApi.writeLiveStreamsFileVisible,
        );
      } else {
        _writeDiskCatalog(IptvCatalogDiskCache.liveDataset, visible, (r) => r.toJson());
      }
    } else if (rows.isNotEmpty) {
      // 1.2.4: the panel answered in full but EVERY row is hidden —
      // write the deliberate empty-array file (same rule as the sync,
      // FORK §45.3). No file means every cold start re-fetches from
      // the network, and a dead network throws instead of serving the
      // (empty) cached catalog. A transient empty answer (rows empty)
      // still writes nothing.
      _writeDiskText(IptvCatalogDiskCache.liveDataset, '[]');
      XtreamApi.deleteHubTempFile(rawFilePath);
    }
    return visible;
  }

  Future<List<XtreamVodStream>> _vodStreams() async {
    await _invalidateMemoIfIndexAdvanced(IptvSearchIndex.typeMovie);
    final cached = _vodStreamsFuture;
    if (cached != null) return cached;
    final future = _loadVodStreamsCached().catchError((Object e) {
      _vodStreamsFuture = null;
      _vodById = null;
      throw e;
    });
    _vodStreamsFuture = future;
    final result = await future;
    // The full list subsumes the crawl's partial rows — drop them so a
    // later search reads the memoized list, not a stale snapshot.
    _vodPartialRows.clear();
    _vodCrawledCategoryIds.clear();
    // An empty result is never cached: a transient empty payload (this
    // panel returns [] for the unfiltered call at 199k rows) must not
    // poison every later view until restart.
    if (result.isEmpty) {
      _vodStreamsFuture = null;
      _vodById = null;
    } else {
      _vodStreamsLoaded = true;
    }
    await _recordMemoStamp(IptvSearchIndex.typeMovie);
    return result;
  }

  /// Coverage guard for first-load disk writes (series fix, v1.0.16):
  /// an unfiltered list covering fewer than half the categories is a
  /// partial panel answer, not the catalog — serve it in memory, never
  /// persist it as the complete disk file (the P5a poison: a partial
  /// write bakes the filter into storage, and the seed then refuses the
  /// file forever). Mirrors the isolate write's 0.5 threshold. The
  /// [complete] flag alone cannot tell: a non-empty unfiltered answer
  /// can still be a partial one. Fail-closed: when the category list
  /// cannot be read, the rows are served but not persisted.
  Future<bool> _coversEnoughCategories(String type, Iterable<String> rowCategoryIds) async {
    List<XtreamCategory> categories;
    try {
      categories = await switch (type) {
        IptvSearchIndex.typeLive => _liveCategories(),
        IptvSearchIndex.typeMovie => _vodCategories(),
        _ => _seriesCategories(),
      };
    } catch (e) {
      appLogger.w('IPTV: category list unavailable for first-load guard ($type)', error: e);
      return false;
    }
    if (categories.isEmpty) return false;
    // v1.1.0 (Option B): the denominator counts ALL categories — a
    // fetch covering the whole catalog is complete even when most
    // categories are hidden, and hidden rows count toward the covered
    // set (they are in the disk file now, filtered at read time).
    final allIds = {for (final c in categories) c.id};
    final covered = rowCategoryIds.toSet().intersection(allIds);
    final ok = covered.length / allIds.length >= 0.5;
    if (!ok) {
      appLogger.i(
        'IPTV: partial unfiltered $type load not persisted (covered ${covered.length}/${allIds.length} categories)',
      );
    }
    return ok;
  }

  /// Disk first (build #11); the network load (with its per-category
  /// fallback) runs only on a miss, and the merged rows are written to
  /// disk — so a panel whose unfiltered call returns [] still gets a
  /// cached catalog from the fallback per-category crawl.
  ///
  /// Build #18: the disk write happens ONLY when the load came from the
  /// unfiltered call. A crawl has no single raw body, and persisting a
  /// merged partial could clobber a full disk file — the exact poison
  /// that made Trex series search return [] on the phone (the VOD loader
  /// has the same shape). Crawl rows are served in memory, never written.
  Future<List<XtreamVodStream>> _loadVodStreamsCached() async {
    // 1.2.4 (catalog memory): the memo AND the disk file hold visible
    // rows only — the disk parse filters inside the isolate (a file
    // written before 1.2.4 is pruned at read time), and the network
    // return is filtered below. The coverage guard still runs on the
    // FULL rows: it asks whether the panel answered in full, and a
    // hidden category still counts as covered there.
    final filter = await _visibleCatalogFilterFor(IptvSearchIndex.typeMovie);
    final disk = await _readDiskCatalogFromFile<XtreamVodStream>(
      IptvCatalogDiskCache.vodDataset,
      (path) => XtreamApi.parseVodStreamsFileVisible(path, filter),
    );
    if (disk != null) {
      _vodLoadSource = 'disk';
      _refreshCatalogViaSyncIfDue(IptvSearchIndex.typeMovie);
      return disk.rows;
    }
    // 1.2.16 (hub timeout fallback): a failed network load serves the
    // last-known-good disk rows instead of an empty home. The disk
    // read above missed (no file yet, or a corrupt file was just
    // deleted), but a concurrent sync may have landed one since, so
    // re-check rather than assuming the miss still holds. A miss here
    // still throws — there is genuinely nothing to serve.
    final ({List<XtreamVodStream> rows, bool complete, String? rawFilePath}) loaded;
    try {
      loaded = await _loadVodStreams(filter);
    } catch (e) {
      final retry = await _readDiskCatalogFromFile<XtreamVodStream>(
        IptvCatalogDiskCache.vodDataset,
        (path) => XtreamApi.parseVodStreamsFileVisible(path, filter),
      );
      if (retry != null) {
        _vodLoadSource = 'disk-stale';
        _refreshCatalogViaSyncIfDue(IptvSearchIndex.typeMovie);
        return retry.rows;
      }
      rethrow;
    }
    _vodLoadSource = loaded.complete ? 'network' : 'crawl';
    final visible = _visibleRows(loaded.rows, (r) => r.categoryId, filter);
    if (loaded.complete &&
        await _coversEnoughCategories(
          IptvSearchIndex.typeMovie,
          loaded.rows.map((r) => r.categoryId).whereType<String>(),
        )) {
      // 1.2.4: the disk file holds visible rows only (the owner's prune
      // decision). The write encodes off-thread — see the live loader
      // (and its no-op shortcut: nothing hidden, raw body straight
      // to disk, no isolate round trip). 1.2.16: when the load streamed
      // to a temp file, the file IS the raw body — persist it without
      // ever holding it as a String (see [_persistHubDownload]). The
      // raw-body branches below stay for test fakes and any caller
      // without a file.
      final rawBody = _xtreamApi.lastVodStreamsBody;
      if (visible.isNotEmpty) {
        if (loaded.rawFilePath != null) {
          _persistHubDownload(
            IptvCatalogDiskCache.vodDataset,
            loaded.rawFilePath!,
            filter,
            XtreamApi.writeVodStreamsFileVisible,
          );
        } else if (rawBody != null && rawBody.isNotEmpty) {
          if (filter.isNoOp) {
            _writeDiskText(IptvCatalogDiskCache.vodDataset, rawBody);
          } else {
            unawaited(
              XtreamApi.encodeVodStreamsBodyVisible(rawBody, filter)
                  .then((body) => _writeDiskText(IptvCatalogDiskCache.vodDataset, body))
                  .catchError((Object e) {
                appLogger.w('IPTV: visible disk encode failed for VOD', error: e);
              }),
            );
          }
        } else {
          _writeDiskCatalog(IptvCatalogDiskCache.vodDataset, visible, (r) => r.toJson());
        }
      } else if (loaded.rows.isNotEmpty) {
        // 1.2.4: complete load, every row hidden — the deliberate
        // empty-array file (same rule as the sync, FORK §45.3).
        _writeDiskText(IptvCatalogDiskCache.vodDataset, '[]');
        XtreamApi.deleteHubTempFile(loaded.rawFilePath);
      }
    } else {
      // Not persisted (partial load, or the crawl): the temp file is
      // not the disk cache — drop it.
      XtreamApi.deleteHubTempFile(loaded.rawFilePath);
    }
    return visible;
  }

  /// Unfiltered first (the fast path when the panel answers); when it
  /// returns [], fall back to a per-category fetch — the panel answers
  /// per-category calls even when the unfiltered call is empty.
  ///
  /// Returns whether the rows came from the unfiltered call ([complete])
  /// or the per-category crawl: crawl rows must never be persisted as
  /// the catalog (build #18) — see [_loadVodStreamsCached]. 1.2.4: the
  /// crawl publishes visible rows only into [_vodPartialRows] (the
  /// caller filters the unfiltered return too), so the memo never holds
  /// a hidden row from either path.
  /// 1.2.16: the record also carries [rawFilePath] — the temp file the
  /// unfiltered call streamed into (null for a fake api, or when the
  /// unfiltered answer was empty and the crawl ran instead). The
  /// caller persists it as the disk cache or deletes it; see
  /// [_loadVodStreamsCached].
  Future<({List<XtreamVodStream> rows, bool complete, String? rawFilePath})> _loadVodStreams(
    VisibleCatalogFilter filter,
  ) async {
    final all = await _xtreamApi.getVodStreams();
    // Read NOW: the per-category crawl below clears the stash (a
    // per-category body is never the full catalog — same rule as
    // lastVodStreamsBody).
    final rawFilePath = _xtreamApi.lastVodStreamsFilePath;
    if (all.isNotEmpty) return (rows: all, complete: true, rawFilePath: rawFilePath);
    // The unfiltered answer was empty: its temp file can never be the
    // disk cache (a transient empty answer never writes a file), so
    // drop it before the crawl.
    XtreamApi.deleteHubTempFile(rawFilePath);
    final categories = await _vodCategories().catchError((Object e) {
      appLogger.w('IPTV: VOD category list unavailable for fallback: $e');
      return const <XtreamCategory>[];
    });
    // v1.1.0 (Option B): the crawl fetches ALL categories — hidden ones
    // too. Rows are still never persisted (build #18); the read-time
    // filter hides them, and the next full sync re-fetches in one call.
    final wanted = categories.toList(growable: false);
    if (wanted.isEmpty) return (rows: const <XtreamVodStream>[], complete: false, rawFilePath: null);
    final out = <XtreamVodStream>[];
    final seen = <int>{};
    // Publish each batch as it lands (build #13): a cold search reads
    // [_vodPartialRows] instead of waiting for the whole crawl, and the
    // sweep skips categories this crawl already covered. Generation-
    // guarded — a clear mid-crawl must not publish stale rows.
    final generation = _catalogGeneration;
    for (var i = 0; i < wanted.length; i += _catalogFallbackBatchSize) {
      // 1.6.12 (request discipline): stop the crawl the moment the panel
      // refuses — the breaker is open, so the remaining categories would
      // only throw cooldown 403s. Serve what landed so far.
      if (_xtreamApi.isBreakerOpenInMemory) break;
      final end = (i + _catalogFallbackBatchSize).clamp(0, wanted.length);
      final batch = wanted.sublist(i, end);
      final results = await Future.wait(
        batch.map(
          (c) async {
            return _xtreamApi.getVodStreams(categoryId: c.id).catchError((Object e) {
              appLogger.w('IPTV: VOD category ${c.id} unavailable: $e');
              return const <XtreamVodStream>[];
            });
          },
        ),
      );
      final fresh = <XtreamVodStream>[];
      for (final rows in results) {
        for (final row in rows) {
          if (!seen.add(row.streamId)) continue;
          // 1.2.4: a hidden row never joins the crawl's rows — the
          // partial publish is a memo, and memos hold visible rows only.
          if (filter.isHidden(row.categoryId)) continue;
          out.add(row);
          fresh.add(row);
        }
      }
      if (generation == _catalogGeneration && fresh.isNotEmpty) {
        _vodPartialRows.addAll(fresh);
        _vodCrawledCategoryIds.addAll(batch.map((c) => c.id));
      }
      // 1.6.12 (request discipline): space the batches — a Trex-scale
      // crawl is ~40 batches, and running them back-to-back is the burst
      // the old 16-way batch was. No gap after the last batch.
      if (i + _catalogFallbackBatchSize < wanted.length) {
        await Future<void>.delayed(_catalogCrawlBatchGap);
      }
    }
    return (rows: out, complete: false, rawFilePath: null);
  }

  Future<List<XtreamSeries>> _seriesList() async {
    await _invalidateMemoIfIndexAdvanced(IptvSearchIndex.typeSeries);
    final cached = _seriesFuture;
    if (cached != null) return cached;
    final future = _loadSeriesCached().catchError((Object e) {
      _seriesFuture = null;
      _seriesById = null;
      throw e;
    });
    _seriesFuture = future;
    final result = await future;
    // The full list subsumes the crawl's partial rows — see [_vodStreams].
    _seriesPartialRows.clear();
    _seriesCrawledCategoryIds.clear();
    if (result.isEmpty) {
      _seriesFuture = null;
      _seriesById = null;
    } else {
      _seriesListLoaded = true;
    }
    await _recordMemoStamp(IptvSearchIndex.typeSeries);
    return result;
  }

  /// The by-id index for the memoized series list (A8). The list itself
  /// is the source of truth; the map is built once from it and rebuilt
  /// after any memo clear (every clear site nulls [_seriesById]).
  Future<Map<int, XtreamSeries>> _seriesByIdMap() async {
    final list = await _seriesList();
    return _seriesById ??= {for (final series in list) series.seriesId: series};
  }

  /// O(1) VOD lookup by id (1.6.11 P10): same pattern as
  /// [_seriesByIdMap].
  Future<Map<int, XtreamVodStream>> _vodByIdMap() async {
    final rows = await _vodStreams();
    return _vodById ??= {for (final row in rows) row.streamId: row};
  }

  /// Test seam: the VOD by-id map, null until the memo has loaded.
  @visibleForTesting
  Map<int, XtreamVodStream>? get debugVodStreamsById => _vodById;

  /// Disk first (build #11), same shape as [_loadVodStreamsCached]: the
  /// startup warm-up ([warmUpSeriesCatalog]) now reads the disk copy, so
  /// the second search after app start finds a warm catalog without ever
  /// touching the network when the cache is fresh.
  ///
  /// Build #18: the disk write happens ONLY when the load came from the
  /// unfiltered call. A crawl's rows are missing every hidden category,
  /// so persisting them bakes the filter into storage — the poison that
  /// made Trex series search return [] on the phone. Crawl rows are
  /// served in memory, never written.
  Future<List<XtreamSeries>> _loadSeriesCached() async {
    // 1.2.4 (catalog memory): visible-only memo + disk — see
    // [_loadVodStreamsCached]. The coverage guard still runs on the
    // full rows (whether the panel answered in full).
    final filter = await _visibleCatalogFilterFor(IptvSearchIndex.typeSeries);
    final disk = await _readDiskCatalogFromFile<XtreamSeries>(
      IptvCatalogDiskCache.seriesDataset,
      (path) => XtreamApi.parseSeriesFileVisible(path, filter),
    );
    if (disk != null) {
      _seriesLoadSource = 'disk';
      _refreshCatalogViaSyncIfDue(IptvSearchIndex.typeSeries);
      return disk.rows;
    }
    // 1.2.16 (hub timeout fallback): a failed network load serves the
    // last-known-good disk rows instead of an empty home — see
    // [_loadVodStreamsCached].
    final ({List<XtreamSeries> rows, bool complete, String? rawFilePath}) loaded;
    try {
      loaded = await _loadSeries(filter);
    } catch (e) {
      final retry = await _readDiskCatalogFromFile<XtreamSeries>(
        IptvCatalogDiskCache.seriesDataset,
        (path) => XtreamApi.parseSeriesFileVisible(path, filter),
      );
      if (retry != null) {
        _seriesLoadSource = 'disk-stale';
        _refreshCatalogViaSyncIfDue(IptvSearchIndex.typeSeries);
        return retry.rows;
      }
      rethrow;
    }
    _seriesLoadSource = loaded.complete ? 'network' : 'crawl';
    final visible = _visibleRows(loaded.rows, (r) => r.categoryId, filter);
    if (loaded.complete &&
        await _coversEnoughCategories(
          IptvSearchIndex.typeSeries,
          loaded.rows.map((r) => r.categoryId).whereType<String>(),
        )) {
      // 1.2.4: the disk file holds visible rows only (the owner's prune
      // decision). The write encodes off-thread — see the live loader
      // (and its no-op shortcut: nothing hidden, raw body straight
      // to disk, no isolate round trip). 1.2.16: when the load streamed
      // to a temp file, the file IS the raw body — see
      // [_loadVodStreamsCached] and [_persistHubDownload].
      final rawBody = _xtreamApi.lastSeriesBody;
      if (visible.isNotEmpty) {
        if (loaded.rawFilePath != null) {
          _persistHubDownload(
            IptvCatalogDiskCache.seriesDataset,
            loaded.rawFilePath!,
            filter,
            XtreamApi.writeSeriesFileVisible,
          );
        } else if (rawBody != null && rawBody.isNotEmpty) {
          if (filter.isNoOp) {
            _writeDiskText(IptvCatalogDiskCache.seriesDataset, rawBody);
          } else {
            unawaited(
              XtreamApi.encodeSeriesBodyVisible(rawBody, filter)
                  .then((body) => _writeDiskText(IptvCatalogDiskCache.seriesDataset, body))
                  .catchError((Object e) {
                appLogger.w('IPTV: visible disk encode failed for series', error: e);
              }),
            );
          }
        } else {
          _writeDiskCatalog(IptvCatalogDiskCache.seriesDataset, visible, (r) => r.toJson());
        }
      } else if (loaded.rows.isNotEmpty) {
        // 1.2.4: complete load, every row hidden — the deliberate
        // empty-array file (same rule as the sync, FORK §45.3).
        _writeDiskText(IptvCatalogDiskCache.seriesDataset, '[]');
        XtreamApi.deleteHubTempFile(loaded.rawFilePath);
      }
    } else {
      // Not persisted (partial load, or the crawl): the temp file is
      // not the disk cache — drop it.
      XtreamApi.deleteHubTempFile(loaded.rawFilePath);
    }
    return visible;
  }

  /// Same empty-unfiltered fallback as [_loadVodStreams], for series.
  ///
  /// Returns whether the rows came from the unfiltered call ([complete])
  /// or the per-category crawl: crawl rows must never be persisted as
  /// the catalog (build #18) — see [_loadSeriesCached]. 1.2.4: the
  /// crawl publishes visible rows only into [_seriesPartialRows] (the
  /// caller filters the unfiltered return too). 1.2.16: the record also
  /// carries [rawFilePath] — see [_loadVodStreams].
  Future<({List<XtreamSeries> rows, bool complete, String? rawFilePath})> _loadSeries(
    VisibleCatalogFilter filter,
  ) async {
    final all = await _xtreamApi.getSeries();
    // Read NOW: the per-category crawl below clears the stash (see
    // [_loadVodStreams]).
    final rawFilePath = _xtreamApi.lastSeriesFilePath;
    if (all.isNotEmpty) return (rows: all, complete: true, rawFilePath: rawFilePath);
    // The unfiltered answer was empty: its temp file can never be the
    // disk cache, so drop it before the crawl.
    XtreamApi.deleteHubTempFile(rawFilePath);
    final categories = await _seriesCategories().catchError((Object e) {
      appLogger.w('IPTV: series category list unavailable for fallback: $e');
      return const <XtreamCategory>[];
    });
    // v1.1.0 (Option B): the crawl fetches ALL categories — hidden ones
    // too. Rows are still never persisted (build #18); the read-time
    // filter hides them, and the next full sync re-fetches in one call.
    final wanted = categories.toList(growable: false);
    if (wanted.isEmpty) return (rows: const <XtreamSeries>[], complete: false, rawFilePath: null);
    final out = <XtreamSeries>[];
    final seen = <int>{};
    // Publish each batch as it lands (build #13) — see [_loadVodStreams].
    final generation = _catalogGeneration;
    for (var i = 0; i < wanted.length; i += _catalogFallbackBatchSize) {
      // 1.6.12 (request discipline): stop on a refusal — see [_loadVodStreams].
      if (_xtreamApi.isBreakerOpenInMemory) break;
      final end = (i + _catalogFallbackBatchSize).clamp(0, wanted.length);
      final batch = wanted.sublist(i, end);
      final results = await Future.wait(
        batch.map(
          (c) async {
            return _xtreamApi.getSeries(categoryId: c.id).catchError((Object e) {
              appLogger.w('IPTV: series category ${c.id} unavailable: $e');
              return const <XtreamSeries>[];
            });
          },
        ),
      );
      final fresh = <XtreamSeries>[];
      for (final rows in results) {
        for (final row in rows) {
          if (!seen.add(row.seriesId)) continue;
          // 1.2.4: a hidden row never joins the crawl's rows — see
          // [_loadVodStreams].
          if (filter.isHidden(row.categoryId)) continue;
          out.add(row);
          fresh.add(row);
        }
      }
      if (generation == _catalogGeneration && fresh.isNotEmpty) {
        _seriesPartialRows.addAll(fresh);
        _seriesCrawledCategoryIds.addAll(batch.map((c) => c.id));
      }
      // 1.6.12 (request discipline): space the batches — see
      // [_loadVodStreams]. No gap after the last batch.
      if (i + _catalogFallbackBatchSize < wanted.length) {
        await Future<void>.delayed(_catalogCrawlBatchGap);
      }
    }
    return (rows: out, complete: false, rawFilePath: null);
  }

  Future<List<M3uEntry>> _m3uEntries() {
    return _m3uEntriesFuture ??= _loadM3uEntriesCached().catchError((Object e) {
      _m3uEntriesFuture = null;
      throw e;
    });
  }

  /// Disk first (build #11): the playlist is parsed from its disk file
  /// inside the isolate ([parseM3uFile] streams it line by line), so the
  /// main isolate never holds the playlist text and no whole-body copy
  /// crosses the isolate port — the provider's ~300 MB playlist used to
  /// spike RSS ~600 MB here (1.5.3 N1). A stale playlist is served and
  /// refreshed in the background.
  Future<List<M3uEntry>> _loadM3uEntriesCached() async {
    final diskPath = await _catalogCache.filePath(connection.id, IptvCatalogDiskCache.m3uDataset);
    if (diskPath != null) {
      try {
        final entries = await IptvHeavyWorkGate.instance.run(
          () => compute(parseM3uFile, diskPath),
          onStart: () => _trimCachesIfHot('M3U parse'),
        );
        if (entries.isNotEmpty) {
          final fetchedAt = (await File(diskPath).stat()).modified;
          if (IptvCatalogDiskCache.isStale(fetchedAt)) _refreshM3uEntriesInBackground();
          return entries;
        }
        unawaited(_catalogCache.delete(connection.id, IptvCatalogDiskCache.m3uDataset));
      } catch (e) {
        appLogger.w('IPTV: cached M3U playlist unreadable; refetching', error: e);
        unawaited(_catalogCache.delete(connection.id, IptvCatalogDiskCache.m3uDataset));
      }
    }
    final destination = await _catalogCache.writeFilePath(connection.id, IptvCatalogDiskCache.m3uDataset);
    if (destination == null) {
      // No disk destination (cache disabled / storage low): stream to a
      // system-temp file and parse from there — the old whole-body
      // fallback held the playlist as a String (~600 MB of UTF-16 for
      // a ~300 MB playlist) exactly when the device was already
      // stressed. The temp file is deleted after the parse.
      final tempDir = await Directory.systemTemp.createTemp('plezy_m3u_low_space_');
      final tempPath = '${tempDir.path}/playlist.m3u';
      try {
        final receivedBytes = await downloadHttpResponseToFile(
          _http,
          Uri.parse(_m3u.playlistUrl),
          tempPath,
        );
        if (receivedBytes == 0) return const <M3uEntry>[];
        // Awaited (not returned) on purpose: a bare `return` of the
        // future would run the `finally` below — deleting the temp
        // file — before the isolate finished parsing it.
        final entries = await IptvHeavyWorkGate.instance.run(
          () => compute(parseM3uFile, tempPath),
          onStart: () => _trimCachesIfHot('M3U parse'),
        );
        return entries;
      } finally {
        try {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        } catch (_) {
          // Best-effort: a leftover temp dir is swept by the OS.
        }
      }
    }
    final freshPath = await _downloadM3uPlaylistToFile(destination, _catalogGeneration);
    if (freshPath == null) return const <M3uEntry>[];
    return IptvHeavyWorkGate.instance.run(
      () => compute(parseM3uFile, freshPath),
      onStart: () => _trimCachesIfHot('M3U parse'),
    );
  }

  /// Stream the playlist straight to [destination] (1.5.3 N1): the
  /// download lands in a temp file beside the cache file and is renamed
  /// into place only on success, so a failed download leaves the
  /// previous disk copy untouched — a partial file must never parse as a
  /// truncated playlist. Returns the cache path, or null when the
  /// download was empty or a clear landed mid-download ([generation]
  /// moved on — the temp file is dropped instead of resurrecting the
  /// cache). Callers treat null as "nothing fresh landed".
  Future<String?> _downloadM3uPlaylistToFile(String destination, int generation) async {
    final tempPath = '$destination.tmp-${DateTime.now().microsecondsSinceEpoch}';
    final receivedBytes = await downloadHttpResponseToFile(_http, Uri.parse(_m3u.playlistUrl), tempPath);
    if (receivedBytes == 0 || generation != _catalogGeneration) {
      await File(tempPath).delete();
      return null;
    }
    await File(tempPath).rename(destination);
    return destination;
  }

  void _refreshM3uEntriesInBackground() {
    final generation = _catalogGeneration;
    unawaited(
      _refreshM3uEntries(generation).catchError((Object e) {
        appLogger.w('IPTV: background M3U playlist refresh failed', error: e);
      }),
    );
  }

  Future<void> _refreshM3uEntries(int generation) async {
    final destination = await _catalogCache.writeFilePath(connection.id, IptvCatalogDiskCache.m3uDataset);
    if (destination == null || generation != _catalogGeneration) return;
    final path = await _downloadM3uPlaylistToFile(destination, generation);
    if (generation != _catalogGeneration || path == null) return;
    _m3uEntriesFuture = Future.value(
      await IptvHeavyWorkGate.instance.run(
        () => compute(parseM3uFile, path),
        onStart: () => _trimCachesIfHot('M3U parse'),
      ),
    );
    notifyCatalogRefreshed();
  }

  /// The category lists for the Categories screen (build #15, item 5) —
  /// disk-first, shared with the guide and browse, so opening the screen
  /// never calls the provider API again when the catalog is already warm.
  /// A failed list throws; the screen treats each section independently
  /// instead of losing the whole screen to one bad list.
  Future<List<XtreamCategory>> liveCategories() => _liveCategories();
  Future<List<XtreamCategory>> vodCategories() => _vodCategories();
  Future<List<XtreamCategory>> seriesCategories() => _seriesCategories();

  /// The live TV categories the user has NOT turned off (build #17): the
  /// guide category picker's entries. Filtered by the SAME
  /// [_isHiddenCategory] rule as the guide rows ([iptvChannels] drops
  /// hidden categories), so the picker and the guide can never drift
  /// apart — a hidden category never appears in the picker, and every
  /// picker entry has visible channels. M3U groups are (id, name) pairs
  /// with the group title as both.
  Future<List<({String id, String name})>> visibleLiveCategories() async {
    if (_isXtream) {
      final categories = await liveCategories();
      return categories
          .where((c) => !_isHiddenCategory(c.id, c.name))
          .map((c) => (id: c.id, name: c.name))
          .toList(growable: false);
    }
    final groups = await m3uGroups();
    return groups
        .where((g) => !_isHiddenGroup(g))
        .map((g) => (id: g, name: g))
        .toList(growable: false);
  }

  /// The M3U group titles (the playlist's categories), distinct and
  /// sorted, for the Categories screen. Reads the cached playlist entries,
  /// so no second download.
  Future<List<String>> m3uGroups() async {
    final groups = <String>{};
    for (final entry in await _m3uEntries()) {
      final group = entry.groupTitle?.trim();
      if (group != null && group.isNotEmpty) groups.add(group);
    }
    final sorted = groups.toList(growable: false)
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return sorted;
  }

  Future<List<XtreamCategory>> _liveCategories() async {
    final cached = _liveCategoriesFuture;
    if (cached != null) return cached;
    final future = _loadLiveCategoriesCached().catchError((Object e) {
      _liveCategoriesFuture = null;
      throw e;
    });
    _liveCategoriesFuture = future;
    return future;
  }

  /// Disk first (build #11), same shape as the other category lists.
  Future<List<XtreamCategory>> _loadLiveCategoriesCached() async {
    final disk = await _readDiskCatalog<XtreamCategory>(
      IptvCatalogDiskCache.liveCategoriesDataset,
      (body) async => XtreamApi.parseCategoriesBody(body),
    );
    if (disk != null) {
      _refreshCatalogViaSyncIfDue(IptvSearchIndex.typeLive);
      return disk.rows;
    }
    final rows = await _xtreamApi.getLiveCategories();
    _writeDiskCatalog(IptvCatalogDiskCache.liveCategoriesDataset, rows, (r) => r.toJson());
    return rows;
  }

  Future<List<XtreamCategory>> _vodCategories() async {
    final cached = _vodCategoriesFuture;
    if (cached != null) return cached;
    final future = _loadVodCategoriesCached().catchError((Object e) {
      _vodCategoriesFuture = null;
      throw e;
    });
    _vodCategoriesFuture = future;
    return future;
  }

  /// Disk first (build #11), same shape as [_loadLiveCategoriesCached].
  Future<List<XtreamCategory>> _loadVodCategoriesCached() async {
    final disk = await _readDiskCatalog<XtreamCategory>(
      IptvCatalogDiskCache.vodCategoriesDataset,
      (body) async => XtreamApi.parseCategoriesBody(body),
    );
    if (disk != null) {
      _refreshCatalogViaSyncIfDue(IptvSearchIndex.typeMovie);
      return disk.rows;
    }
    final rows = await _xtreamApi.getVodCategories();
    _writeDiskCatalog(IptvCatalogDiskCache.vodCategoriesDataset, rows, (r) => r.toJson());
    return rows;
  }

  Future<List<XtreamCategory>> _seriesCategories() async {
    final cached = _seriesCategoriesFuture;
    if (cached != null) return cached;
    final future = _loadSeriesCategoriesCached().catchError((Object e) {
      _seriesCategoriesFuture = null;
      throw e;
    });
    _seriesCategoriesFuture = future;
    return future;
  }

  /// Disk first (build #11), same shape as [_loadLiveCategoriesCached].
  Future<List<XtreamCategory>> _loadSeriesCategoriesCached() async {
    final disk = await _readDiskCatalog<XtreamCategory>(
      IptvCatalogDiskCache.seriesCategoriesDataset,
      (body) async => XtreamApi.parseCategoriesBody(body),
    );
    if (disk != null) {
      _refreshCatalogViaSyncIfDue(IptvSearchIndex.typeSeries);
      return disk.rows;
    }
    final rows = await _xtreamApi.getSeriesCategories();
    _writeDiskCatalog(IptvCatalogDiskCache.seriesCategoriesDataset, rows, (r) => r.toJson());
    return rows;
  }

  /// Category id -> name for VOD, for stripping the provider's category
  /// tag from display titles. Fails open to {} — titles just keep their
  /// prefixes when the list cannot be fetched. 1.2.11: the index's
  /// category table answers first when warm (no disk read, no panel
  /// round trip); the disk/network path is the cold fallback.
  Future<Map<String, String>> _vodCategoryNames() async {
    final cached = _vodCategoryNamesFuture;
    if (cached != null) return cached;
    final future = _indexCategoryNames(IptvSearchIndex.typeMovie).then((names) async {
      if (names != null) return names;
      try {
        final categories = await _vodCategories();
        return {for (final c in categories) c.id: c.name};
      } catch (e) {
        _vodCategoryNamesFuture = null;
        appLogger.w('IPTV: VOD category names unavailable: $e');
        return const <String, String>{};
      }
    });
    _vodCategoryNamesFuture = future;
    return future;
  }

  /// Category id -> name from the index when it is warm for [type]
  /// (1.2.11), else null — the caller falls back to its disk/network
  /// path. Never throws: a broken index reads as cold.
  Future<Map<String, String>?> _indexCategoryNames(String type) async {
    try {
      final index = await _warmIndexForType(type);
      if (index == null) return null;
      return index.categoryNames(connection.id, type);
    } catch (e) {
      appLogger.w('IPTV: index category names unreadable', error: e);
      return null;
    }
  }

  /// Category id -> name for series, same fail-open contract as
  /// [_vodCategoryNames].
  Future<Map<String, String>> _seriesCategoryNames() async {
    final cached = _seriesCategoryNamesFuture;
    if (cached != null) return cached;
    final future = _indexCategoryNames(IptvSearchIndex.typeSeries).then((names) async {
      if (names != null) return names;
      try {
        final categories = await _seriesCategories();
        return {for (final c in categories) c.id: c.name};
      } catch (e) {
        _seriesCategoryNamesFuture = null;
        appLogger.w('IPTV: series category names unavailable: $e');
        return const <String, String>{};
      }
    });
    _seriesCategoryNamesFuture = future;
    return future;
  }

  /// Category id -> name for live TV, same fail-open contract as
  /// [_vodCategoryNames]. The Live TV list needs it so a channel is
  /// hidden exactly when its category is hidden (build #10 redesign).
  Future<Map<String, String>> _liveCategoryNames() async {
    final cached = _liveCategoryNamesFuture;
    if (cached != null) return cached;
    final future = _indexCategoryNames(IptvSearchIndex.typeLive).then((names) async {
      if (names != null) return names;
      try {
        final categories = await _liveCategories();
        return {for (final c in categories) c.id: c.name};
      } catch (e) {
        _liveCategoryNamesFuture = null;
        appLogger.w('IPTV: live category names unavailable: $e');
        return const <String, String>{};
      }
    });
    _liveCategoryNamesFuture = future;
    return future;
  }

  // -- Disk-only reads for the Enter path (R2.3) ------------------------
  // The submit path must never fetch from the panel outside the one
  // coalesced sync — the plain loaders fall back to the network on a
  // disk miss, which would add requests outside the sync and break the
  // "exactly 6". These helpers read local data only and are never
  // memoized into the shared futures (a disk miss here must not poison
  // a later network-backed lookup with an empty map).

  /// Category names from the memoized future when it exists, else the
  /// disk categories file, else {} — never the panel.
  Future<Map<String, String>> _vodCategoryNamesFromDisk() async {
    final cached = _vodCategoryNamesFuture;
    if (cached != null) return cached;
    final disk = await _readDiskCatalog<XtreamCategory>(
      IptvCatalogDiskCache.vodCategoriesDataset,
      (body) async => XtreamApi.parseCategoriesBody(body),
    );
    return disk == null ? const <String, String>{} : {for (final c in disk.rows) c.id: c.name};
  }

  /// Same as [_vodCategoryNamesFromDisk], for series.
  Future<Map<String, String>> _seriesCategoryNamesFromDisk() async {
    final cached = _seriesCategoryNamesFuture;
    if (cached != null) return cached;
    final disk = await _readDiskCatalog<XtreamCategory>(
      IptvCatalogDiskCache.seriesCategoriesDataset,
      (body) async => XtreamApi.parseCategoriesBody(body),
    );
    return disk == null ? const <String, String>{} : {for (final c in disk.rows) c.id: c.name};
  }

  /// Same as [_vodCategoryNamesFromDisk], for live TV.
  Future<Map<String, String>> _liveCategoryNamesFromDisk() async {
    final cached = _liveCategoryNamesFuture;
    if (cached != null) return cached;
    final disk = await _readDiskCatalog<XtreamCategory>(
      IptvCatalogDiskCache.liveCategoriesDataset,
      (body) async => XtreamApi.parseCategoriesBody(body),
    );
    return disk == null ? const <String, String>{} : {for (final c in disk.rows) c.id: c.name};
  }

  /// Catalog rows for the Enter path: the memoized list when loaded,
  /// else the disk file, else the crawl's published partial rows —
  /// never a network fetch. The source labels the diagnostics
  /// ('disk' / 'crawl' / the memoized load's own source); 'syncing'
  /// means nothing local exists yet and the kicked-off sync is fetching
  /// it — the screen re-runs the search when that sync lands.
  Future<({List<XtreamVodStream> rows, String source})> _vodRowsForEnterSearch() async {
    if (_vodStreamsLoaded && _vodStreamsFuture != null) {
      return (rows: await _vodStreamsFuture!, source: _vodLoadSource);
    }
    // 1.2.4 (catalog memory): the disk fallback parses VISIBLE rows
    // only — a pre-1.2.4 full disk file is pruned at read time, a
    // 1.2.4 visible-only file passes through unchanged. The full
    // parser here used to scan all 200k rows (77% hidden) on every
    // cold Enter search before the warm-up landed.
    final filter = await _visibleCatalogFilterFor(IptvSearchIndex.typeMovie);
    final disk = await _readDiskCatalogFromFile<XtreamVodStream>(
      IptvCatalogDiskCache.vodDataset,
      (path) => XtreamApi.parseVodStreamsFileVisible(path, filter),
    );
    if (disk != null) return (rows: disk.rows, source: 'disk');
    if (_vodPartialRows.isNotEmpty) return (rows: List.of(_vodPartialRows), source: 'crawl');
    return (rows: const <XtreamVodStream>[], source: 'syncing');
  }

  /// Same as [_vodRowsForEnterSearch], for series.
  Future<({List<XtreamSeries> rows, String source})> _seriesRowsForEnterSearch() async {
    if (_seriesListLoaded && _seriesFuture != null) {
      return (rows: await _seriesFuture!, source: _seriesLoadSource);
    }
    // 1.2.4 (catalog memory): visible-only disk fallback (see
    // [_vodRowsForEnterSearch]).
    final filter = await _visibleCatalogFilterFor(IptvSearchIndex.typeSeries);
    final disk = await _readDiskCatalogFromFile<XtreamSeries>(
      IptvCatalogDiskCache.seriesDataset,
      (path) => XtreamApi.parseSeriesFileVisible(path, filter),
    );
    if (disk != null) return (rows: disk.rows, source: 'disk');
    if (_seriesPartialRows.isNotEmpty) return (rows: List.of(_seriesPartialRows), source: 'crawl');
    return (rows: const <XtreamSeries>[], source: 'syncing');
  }

  /// Same as [_vodRowsForEnterSearch], for live TV (no crawl source —
  /// the live loader never publishes partial rows).
  Future<({List<XtreamLiveStream> rows, String source})> _liveRowsForEnterSearch() async {
    if (_liveStreamsLoaded && _liveStreamsFuture != null) {
      return (rows: await _liveStreamsFuture!, source: _liveLoadSource);
    }
    // 1.2.4 (catalog memory): visible-only disk fallback (see
    // [_vodRowsForEnterSearch]).
    final filter = await _visibleCatalogFilterFor(IptvSearchIndex.typeLive);
    final disk = await _readDiskCatalogFromFile<XtreamLiveStream>(
      IptvCatalogDiskCache.liveDataset,
      (path) => XtreamApi.parseLiveStreamsFileVisible(path, filter),
    );
    if (disk != null) return (rows: disk.rows, source: 'disk');
    return (rows: const <XtreamLiveStream>[], source: 'syncing');
  }

  /// Strips a leading "`<categoryName> - `" from a display title, but only
  /// when it duplicates the item's OWN category — the provider bakes its
  /// category tag into names (e.g. "NF - Alice" in the NF category). A
  /// prefix from another category is left alone, and a title that would
  /// be left empty keeps its original form. Case-insensitive.
  @visibleForTesting
  static String stripCategoryPrefix(String title, String? categoryName) {
    if (categoryName == null || categoryName.isEmpty) return title;
    final prefix = '$categoryName - ';
    if (title.length <= prefix.length) return title;
    if (!title.toLowerCase().startsWith(prefix.toLowerCase())) return title;
    final stripped = title.substring(prefix.length);
    return stripped.isEmpty ? title : stripped;
  }

  // -- Libraries -----------------------------------------------------------

  @override
  Future<List<MediaLibrary>> fetchLibraries() async {
    // Live TV is NOT a library: channels are served only through liveTv
    // (the Live TV tab). Only on-demand catalogs become libraries, so the
    // library picker never shows a "Live TV" row. M3U has no on-demand
    // catalog, so it exposes no libraries at all.
    //
    // The Movies and Series libraries are ALWAYS listed for an Xtream
    // connection (build #13): a filter hides content, it must never delete
    // the library row itself. The old "omit this library when ALL its
    // categories are disabled" probe did exactly that — one "Hide all
    // groups" tap in the edit screen made both libraries vanish from the
    // Libraries tab while Live TV kept working, and the only way back was
    // the edit screen. It also cost two provider round trips (up to 5s)
    // on every library fetch, which the build #11 disk cache made fast
    // enough to actually complete — the probe used to fail open on a slow
    // network and hide the libraries once the cache landed. Disabled
    // categories are still hidden from browse/search/guide by the
    // content-level filters (_moviesItems/_seriesItems/_isHiddenCategory);
    // an all-disabled library simply shows its empty state.
    final name = _name;
    final libraries = <MediaLibrary>[];
    if (_isXtream) {
      libraries.add(
        MediaLibrary(
          id: _moviesLibraryId,
          backend: backend,
          title: '$name — Movies',
          kind: MediaKind.movie,
          serverId: connection.id,
          serverName: name,
        ),
      );
      libraries.add(
        MediaLibrary(
          id: _seriesLibraryId,
          backend: backend,
          title: '$name — Series',
          kind: MediaKind.show,
          serverId: connection.id,
          serverName: name,
        ),
      );
    }
    return libraries;
  }

  /// Release year from a provider date string (`'1997-08-13'`, `'2008'`).
  /// Null when the date is missing or malformed. (1.6.10 M0)
  static int? _parseYear(String? value) {
    final text = value?.trim();
    if (text == null || text.length < 4) return null;
    return int.tryParse(text.substring(0, 4));
  }

  /// Comma-separated provider list (`'Animation, Comedy'`) as a trimmed
  /// list, or null when the value is missing or empty. (1.6.10 M0)
  static List<String>? _splitCommaList(String? value) {
    if (value == null) return null;
    final parts = value.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? null : parts;
  }

  /// Cast names as [MediaRole]s (name only — the provider sends no
  /// character or photo). (1.6.10 M0)
  static List<MediaRole>? _castRoles(String? cast) {
    final names = _splitCommaList(cast);
    if (names == null) return null;
    return names.map((name) => MediaRole(tag: name)).toList();
  }

  MediaItem _movieItem(
    XtreamVodStream stream, {
    bool isFavorite = false,
    String? categoryName,
    IptvResumeItem? resume,
    // 1.6.10 M1: full detail from `get_vod_info` (memoized, detail open
    // only). Null on the grid path — the grid never fetches it, so
    // browsing costs nothing extra.
    XtreamVodInfo? vodInfo,
  }) {
    final url = _xtreamApi.movieStreamUrl('${stream.streamId}', stream.containerExtension);
    final durationSecs = vodInfo?.durationSecs;
    final trailer = vodInfo?.youtubeTrailer;
    // 1.6.11 X6: the player-measured duration wins — the provider's
    // runtime is only the fallback when the player never reported one.
    final measuredMs = resume?.durationMs;
    return MediaItem.xtream(
      id: 'movie:${stream.streamId}',
      kind: MediaKind.movie,
      title: stripCategoryPrefix(stream.name, categoryName),
      summary: vodInfo?.plot,
      thumbPath: stream.cover ?? stream.streamIcon,
      backdropPaths: vodInfo?.backdropPaths,
      year: _parseYear(vodInfo?.releaseDate),
      genres: _splitCommaList(vodInfo?.genre),
      directors: _splitCommaList(vodInfo?.director),
      roles: _castRoles(vodInfo?.cast),
      // 1.6.11 X5: the `get_vod_info` rating and country win over the
      // catalog row's bare star; the row stays the fallback.
      rating: vodInfo?.rating ?? stream.rating,
      countries: _splitCommaList(vodInfo?.country),
      streamUrl: url,
      categoryId: stream.categoryId,
      libraryId: _moviesLibraryId,
      libraryTitle: '$_name — Movies',
      serverId: connection.id,
      serverName: _name,
      isFavorite: isFavorite,
      // 1.6.10 M1: the trailer id rides in `raw` — the trailer button
      // itself is M4, so nothing renders it yet.
      raw: trailer == null ? null : {'youtubeTrailer': trailer},
      // Build #25: the catalog carries no movie duration, so the stored
      // position AND duration both come from the player's report.
      // 1.6.10 M1: `get_vod_info` supplies the runtime when the player
      // has not reported one yet. 1.6.11 X6: a measured duration (above
      // zero) always beats the provider value.
      durationMs: (measuredMs != null && measuredMs > 0)
          ? measuredMs
          : (durationSecs == null ? null : durationSecs * 1000),
      viewOffsetMs: resume?.positionMs,
      lastViewedAt: resume?.updatedAtMs,
    );
  }

  MediaItem _seriesItem(XtreamSeries series, {bool isFavorite = false, String? categoryName}) {
    // 1.6.11 X8: the full backdrop array, not just the first URL.
    final backdropPath = series.backdropPath;
    final backdrops = series.backdropPaths ?? (backdropPath == null ? null : [backdropPath]);
    final trailer = series.youtubeTrailer;
    final episodeRunTime = series.episodeRunTime;
    return MediaItem.xtream(
      id: 'series:${series.seriesId}',
      kind: MediaKind.show,
      title: stripCategoryPrefix(series.name, categoryName),
      summary: series.plot,
      thumbPath: series.cover,
      // 1.6.10 M0: the provider fields the catalog row already owns —
      // backdrop, genres, cast, director, year, episode runtime, and
      // the trailer id (in `raw`; the trailer button itself is M4).
      // `episode_run_time` is MINUTES (Xtream docs), not seconds.
      backdropPaths: backdrops,
      year: _parseYear(series.releaseDate),
      genres: _splitCommaList(series.genre),
      directors: _splitCommaList(series.director),
      roles: _castRoles(series.cast),
      durationMs: episodeRunTime == null ? null : episodeRunTime * 60 * 1000,
      rating: series.rating,
      categoryId: series.categoryId,
      libraryId: _seriesLibraryId,
      libraryTitle: '$_name — Series',
      serverId: connection.id,
      serverName: _name,
      isFavorite: isFavorite,
      raw: trailer == null ? null : {'youtubeTrailer': trailer},
    );
  }

  /// Test seam (1.4.6 G1): builds one episode item from raw series/episode
  /// data without touching the network — the production path is
  /// `fetchItem('episode:<seriesId>:<episodeId>')`, which needs a live
  /// panel. The builder itself is pure (seriesStreamUrl is string
  /// concatenation), so this delegate exercises the exact production code.
  @visibleForTesting
  MediaItem debugEpisodeItem(
    XtreamSeries series,
    XtreamEpisode episode,
    int season, {
    String? seriesCategoryName,
  }) =>
      _episodeItem(series, episode, season, seriesCategoryName: seriesCategoryName);

  MediaItem _episodeItem(
    XtreamSeries series,
    XtreamEpisode episode,
    int season, {
    bool isFavorite = false,
    String? seriesCategoryName,
    IptvResumeItem? resume,
  }) {
    final url = _xtreamApi.seriesStreamUrl('${episode.id}', episode.containerExtension);
    // 1.6.11 X8: the full series backdrop array.
    final backdropPath = series.backdropPath;
    final backdrops = series.backdropPaths ?? (backdropPath == null ? null : [backdropPath]);
    return MediaItem.xtream(
      id: 'episode:${series.seriesId}:${episode.id}',
      kind: MediaKind.episode,
      title: episode.title.isEmpty ? 'Episode ${episode.episodeNum}' : episode.title,
      summary: episode.plot,
      // 1.6.10 M0: the episode's own still is its thumbnail (the
      // Continue Watching card); the series poster/backdrop ride along
      // as the inherited art the hero and card fallbacks read.
      thumbPath: episode.movieImage,
      grandparentThumbPath: series.cover,
      grandparentBackdropPaths: backdrops,
      // 1.5.3 K1: the episode points at its per-season parent, not the
      // show — the Downloads tree and _downloadedSeasons group by
      // parentId, so a show-level parentId merged every season into one
      // row. The per-season id is the same one _seasonItem builds.
      parentId: 'season:${series.seriesId}:$season',
      // 1.4.4 F5: the show id the queue lookup filters on — without it
      // the show's downloads never match their series (the lookup
      // compares grandparentId against the bare series id).
      grandparentId: '${series.seriesId}',
      // 1.4.6 G1: Plex-shaped hierarchy titles — the Downloads tree reads
      // the show name from grandparentTitle and the season label from
      // parentTitle. Before this the series name sat in parentTitle and
      // grandparentTitle was unset, so the tree showed "Unknown Show" with
      // the series name as its season.
      grandparentTitle: stripCategoryPrefix(series.name, seriesCategoryName),
      parentTitle: 'Season $season',
      parentIndex: season,
      index: episode.episodeNum,
      durationMs: episode.durationSeconds == null ? null : episode.durationSeconds! * 1000,
      streamUrl: url,
      categoryId: series.categoryId,
      libraryId: _seriesLibraryId,
      libraryTitle: '$_name — Series',
      serverId: connection.id,
      serverName: _name,
      isFavorite: isFavorite,
      // Build #25: the episode duration stays the catalog's (the store
      // agrees with it); only the position and last-viewed stamp come
      // from the resume entry.
      viewOffsetMs: resume?.positionMs,
      lastViewedAt: resume?.updatedAtMs,
    );
  }

  /// Filtered VOD rows: hidden categories removed, query applied on the
  /// stripped title (the same text the old item-level filter matched).
  /// Returns ROWS, not items (build #13): mapping 199k rows to
  /// MediaItems on every page turn froze the UI for ~650ms; callers map
  /// only the slice they show ([_vodPageItems]).
  Future<List<XtreamVodStream>> _filteredVodRows({String? search, String? nameStartsWith}) async {
    final streams = await _vodStreams();
    final categoryNames = await _vodCategoryNames();
    final searchPattern = _searchPattern(search);
    final startsWithPattern = _startsWithPattern(nameStartsWith);
    final isHash = nameStartsWith == '#';
    return streams.where((s) {
      if (_isHiddenCategory(s.categoryId, categoryNames[s.categoryId])) return false;
      final title = stripCategoryPrefix(s.name, categoryNames[s.categoryId]);
      if (searchPattern != null && !searchPattern.hasMatch(title)) return false;
      if (nameStartsWith != null && nameStartsWith.isNotEmpty) {
        final first = title.trimLeft();
        if (isHash) {
          if (first.isNotEmpty && _alphaStart.hasMatch(first)) return false;
        } else if (startsWithPattern != null && !startsWithPattern.hasMatch(first)) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  /// Same as [_filteredVodRows], for series rows.
  Future<List<XtreamSeries>> _filteredSeriesRows({String? search, String? nameStartsWith}) async {
    final series = await _seriesList();
    final categoryNames = await _seriesCategoryNames();
    final searchPattern = _searchPattern(search);
    final startsWithPattern = _startsWithPattern(nameStartsWith);
    final isHash = nameStartsWith == '#';
    return series.where((s) {
      if (_isHiddenCategory(s.categoryId, categoryNames[s.categoryId])) return false;
      final title = stripCategoryPrefix(s.name, categoryNames[s.categoryId]);
      if (searchPattern != null && !searchPattern.hasMatch(title)) return false;
      if (nameStartsWith != null && nameStartsWith.isNotEmpty) {
        final first = title.trimLeft();
        if (isHash) {
          if (first.isNotEmpty && _alphaStart.hasMatch(first)) return false;
        } else if (startsWithPattern != null && !startsWithPattern.hasMatch(first)) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  /// Case-insensitive substring pattern for a browse search, built once
  /// per filter call — never per row (see [_appendMovieMatches]).
  static RegExp? _searchPattern(String? search) {
    final s = search?.trim();
    if (s == null || s.isEmpty) return null;
    return RegExp(RegExp.escape(s), caseSensitive: false);
  }

  /// Case-insensitive "starts with" pattern for a browse initial filter.
  static RegExp? _startsWithPattern(String? nameStartsWith) {
    if (nameStartsWith == null || nameStartsWith.isEmpty || nameStartsWith == '#') return null;
    return RegExp('^${RegExp.escape(nameStartsWith)}', caseSensitive: false);
  }

  static final RegExp _alphaStart = RegExp(r'^[A-Za-z]');

  /// Map one page of VOD rows to items — only the rows on the page are
  /// mapped, never the whole catalog.
  Future<List<MediaItem>> _vodPageItems(List<XtreamVodStream> rows, int offset, int limit) async {
    final favorites = await _favoriteItems();
    final resume = await _resumeItems();
    final categoryNames = await _vodCategoryNames();
    final start = offset.clamp(0, rows.length);
    final end = (offset + limit).clamp(0, rows.length);
    return rows
        .sublist(start, end)
        .map(
          (s) => _movieItem(
            s,
            isFavorite: favorites.containsKey('movie:${s.streamId}'),
            categoryName: categoryNames[s.categoryId],
            resume: resume['movie:${s.streamId}'],
          ),
        )
        .toList();
  }

  /// Same as [_vodPageItems], for series rows.
  Future<List<MediaItem>> _seriesPageItems(List<XtreamSeries> rows, int offset, int limit) async {
    final favorites = await _favoriteItems();
    final categoryNames = await _seriesCategoryNames();
    final start = offset.clamp(0, rows.length);
    final end = (offset + limit).clamp(0, rows.length);
    return rows
        .sublist(start, end)
        .map(
          (s) => _seriesItem(
            s,
            isFavorite: favorites.containsKey('series:${s.seriesId}'),
            categoryName: categoryNames[s.categoryId],
          ),
        )
        .toList();
  }

  MediaHub _recommendedHub({
    required String libraryId,
    required String title,
    required String type,
    required List<MediaItem> all,
    required int limit,
    // Full filtered count (build #13): callers now pass only the first
    // `limit` items (mapping 199k to take 20 froze the UI), so `size`
    // and `more` must come from the catalog count, not the passed list.
    // Defaults to the passed list for callers that still pass it all.
    int? totalCount,
  }) {
    final items = all.take(limit).toList();
    final total = totalCount ?? all.length;
    return MediaHub(
      id: 'iptv:$libraryId:recommended',
      title: title,
      type: type,
      items: items,
      size: total,
      more: total > items.length,
      libraryId: libraryId,
      serverId: connection.id,
      serverName: _name,
    );
  }

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async {
    if (!_isXtream) return const LibraryPage(items: [], totalCount: 0);
    abort?.throwIfAborted();
    if (libraryId == _moviesLibraryId) {
      // 1.2.11: the page comes from the index (no memo load); the memo
      // path below is the cold fallback only.
      final page = await _indexBrowsePage(
        IptvSearchIndex.typeMovie,
        offset: query.offset,
        limit: query.limit,
        search: query.search,
        nameStartsWith: query.nameStartsWith,
      );
      if (page != null) {
        final items = await _vodPageItems(
          page.rows.map((r) => r.toVodStream()).toList(growable: false),
          0,
          page.rows.length,
        );
        return LibraryPage(
          items: items,
          totalCount: page.total,
          offset: query.offset.clamp(0, page.total),
        );
      }
      final rows = await _filteredVodRows(search: query.search, nameStartsWith: query.nameStartsWith);
      final items = await _vodPageItems(rows, query.offset, query.limit);
      return LibraryPage(items: items, totalCount: rows.length, offset: query.offset.clamp(0, rows.length));
    }
    if (libraryId == _seriesLibraryId) {
      final page = await _indexBrowsePage(
        IptvSearchIndex.typeSeries,
        offset: query.offset,
        limit: query.limit,
        search: query.search,
        nameStartsWith: query.nameStartsWith,
      );
      if (page != null) {
        final items = await _seriesPageItems(
          page.rows.map((r) => r.toSeries()).toList(growable: false),
          0,
          page.rows.length,
        );
        return LibraryPage(
          items: items,
          totalCount: page.total,
          offset: query.offset.clamp(0, page.total),
        );
      }
      final rows = await _filteredSeriesRows(search: query.search, nameStartsWith: query.nameStartsWith);
      final items = await _seriesPageItems(rows, query.offset, query.limit);
      return LibraryPage(items: items, totalCount: rows.length, offset: query.offset.clamp(0, rows.length));
    }
    return const LibraryPage(items: [], totalCount: 0);
  }

  @override
  Future<LibraryFilterResult> fetchLibraryFiltersWithValues(String libraryId, {MediaKind? libraryKind}) async {
    return LibraryFilterResult.empty;
  }

  /// Provider categories for a library, with item counts — VOD categories
  /// in Movies, series categories in TV/Series. This is what the
  /// Categories tab (which replaces Collections for IPTV) lists. Disabled
  /// categories are omitted. An unknown library id, or M3U (no on-demand
  /// libraries), returns no categories. The counts fail open to null when
  /// the catalog cannot be fetched; a category-list failure throws so the
  /// tab shows its retryable error state.
  Future<List<IptvCategory>> iptvCategoriesForLibrary(String libraryId) async {
    if (!_isXtream) return const [];
    if (libraryId == _moviesLibraryId) {
      // 1.2.11: the counts come from one grouped index query (no memo
      // load) and the category list from the index's category table
      // when warm; the memo path is the cold fallback only. A category
      // with no visible rows reads as a null count, exactly as the
      // memo path's map lookup did.
      final index = await _warmIndexForType(IptvSearchIndex.typeMovie);
      if (index != null) {
        _refreshCatalogViaSyncIfDue(IptvSearchIndex.typeMovie);
        final counts = index.countByCategoryGrouped(
          connection.id,
          IptvSearchIndex.typeMovie,
          hiddenIds: _hiddenCategories,
          hiddenInitials: _hiddenCategoryInitials,
        );
        return index
            .categoryNames(connection.id, IptvSearchIndex.typeMovie)
            .entries
            .where((e) => !_isHiddenCategory(e.key, e.value))
            .map((e) => IptvCategory(id: e.key, name: e.value, itemCount: counts[e.key]))
            .toList();
      }
      final categories = await _vodCategories();
      final streams = await _vodStreams().catchError((Object e) {
        appLogger.w('IPTV: VOD catalog unavailable for category counts: $e');
        return const <XtreamVodStream>[];
      });
      final counts = <String, int>{};
      for (final stream in streams) {
        final id = stream.categoryId;
        if (id != null) counts[id] = (counts[id] ?? 0) + 1;
      }
      return categories
          .where((c) => !_isHiddenCategory(c.id, c.name))
          .map((c) => IptvCategory(id: c.id, name: c.name, itemCount: counts[c.id]))
          .toList();
    }
    if (libraryId == _seriesLibraryId) {
      final index = await _warmIndexForType(IptvSearchIndex.typeSeries);
      if (index != null) {
        _refreshCatalogViaSyncIfDue(IptvSearchIndex.typeSeries);
        final counts = index.countByCategoryGrouped(
          connection.id,
          IptvSearchIndex.typeSeries,
          hiddenIds: _hiddenCategories,
          hiddenInitials: _hiddenCategoryInitials,
        );
        return index
            .categoryNames(connection.id, IptvSearchIndex.typeSeries)
            .entries
            .where((e) => !_isHiddenCategory(e.key, e.value))
            .map((e) => IptvCategory(id: e.key, name: e.value, itemCount: counts[e.key]))
            .toList();
      }
      final categories = await _seriesCategories();
      final series = await _seriesList().catchError((Object e) {
        appLogger.w('IPTV: series catalog unavailable for category counts: $e');
        return const <XtreamSeries>[];
      });
      final counts = <String, int>{};
      for (final s in series) {
        final id = s.categoryId;
        if (id != null) counts[id] = (counts[id] ?? 0) + 1;
      }
      return categories
          .where((c) => !_isHiddenCategory(c.id, c.name))
          .map((c) => IptvCategory(id: c.id, name: c.name, itemCount: counts[c.id]))
          .toList();
    }
    return const [];
  }

  /// Detected category initials for this connection (build #8 Task 4,
  /// redesigned build #10): the initials that keep repeating across the
  /// connection's CATEGORY names — live, VOD and series — most-common
  /// first. Only initials at or above [iptvInitialRepeatThreshold] are
  /// offered as toggles; one-off prefixes are never offered. The count
  /// on each row is the number of CATEGORIES carrying that initial.
  ///
  /// Xtream needs only the three category lists now — the old version
  /// loaded the whole live/VOD/series catalogs just to count item-name
  /// prefixes, which is also why opening the section was slow on a cold
  /// connection. M3U has no category endpoint, so its initials come from
  /// the playlist's group titles. Call it lazily, on expand.
  Future<List<IptvInitial>> iptvInitials() async {
    final names = <String>[];
    if (_isXtream) {
      final liveCategories = await _liveCategories().catchError((Object e) {
        appLogger.w('IPTV: live category list unavailable for initials: $e');
        return const <XtreamCategory>[];
      });
      names.addAll(liveCategories.map((c) => c.name));
      final vodCategories = await _vodCategories();
      names.addAll(vodCategories.map((c) => c.name));
      final seriesCategories = await _seriesCategories();
      names.addAll(seriesCategories.map((c) => c.name));
    } else {
      final entries = await _m3uEntries();
      for (final entry in entries) {
        final group = entry.groupTitle;
        if (group != null) names.add(group);
      }
    }
    return initialsMeetingThreshold(countCategoryInitials(names));
  }

  /// Sequential bind warm-up (1.2.6, catalog memory, item 3; 1.2.11
  /// disk-paged browse): the bind used to fire the three warm-ups +
  /// the FTS seed CONCURRENTLY at startup — four isolates, each holding
  /// a whole-body copy, spiking RSS ~279MB at Trex scale (M2 probe).
  /// Now the warm-ups run one at a time, in browse order: live first
  /// (the guide needs it), then the first frame, then VOD + series
  /// only when RSS leaves room — a pressured device skips them and the
  /// index stays cold for those types, so each loads on demand from
  /// disk instead (the cold fallback). 1.2.11: a warm-up no longer
  /// loads the memo at all — it seeds that type's search index from
  /// the disk catalog, and browse/search/guide read the index. The
  /// sync ([ensureSearchIndexSynced]) runs AFTER the warm-ups, chained
  /// by the caller ([MultiServerManager.addIptvConnection]), never
  /// racing them. [waitForFirstFrame] is false in tests (no frame loop
  /// there).
  Future<void> warmUpCatalogsSequentially({bool waitForFirstFrame = true}) async {
    if (!_isXtream) return;
    _bindPhaseLog.clear();
    try {
      await _seedSearchIndexTypeFromDisk(IptvSearchIndex.typeLive);
      _bindPhaseLog.add('live');
      // 1.5.3 N4: one RSS sample per seed — the trace had no sample
      // between the seeds, so the seed split inside the bind was
      // invisible (maxRss is a lifetime high-water mark).
      PhaseRssSampler.instance.sample('bind-seed-live');
      if (waitForFirstFrame) {
        await _waitForFirstFrame();
        _bindPhaseLog.add('first-frame');
      }
      if (_bindRssTooHigh()) {
        _bindPhaseLog.add('deferred-memory');
        appLogger.i(
          'IPTV: bind warm-up deferred VOD/series (RSS ${ProcessInfo.currentRss >> 20}MB) — on-demand load',
        );
        return;
      }
      await _seedSearchIndexTypeFromDisk(IptvSearchIndex.typeMovie);
      _bindPhaseLog.add('vod');
      PhaseRssSampler.instance.sample('bind-seed-vod');
      await _seedSearchIndexTypeFromDisk(IptvSearchIndex.typeSeries);
      _bindPhaseLog.add('series');
      PhaseRssSampler.instance.sample('bind-seed-series');
    } catch (e) {
      appLogger.w('IPTV: sequential bind warm-up failed', error: e);
    }
  }

  /// Bind-phase log for [warmUpCatalogsSequentially]: the phases that
  /// ran, in order (`live`, `first-frame`, `vod`, `series` — or
  /// `deferred-memory` when the RSS gate skipped VOD/series). Tests
  /// assert the order; production never reads it.
  final List<String> _bindPhaseLog = [];

  /// The phases [warmUpCatalogsSequentially] ran, in order. Test-only.
  @visibleForTesting
  List<String> get bindPhaseLog => List.unmodifiable(_bindPhaseLog);

  /// First frame, or give up after 500ms. In production the splash
  /// frame lands in milliseconds, so this is effectively immediate; in
  /// unit tests there is no frame loop, so the timeout bounds the wait
  /// instead of hanging the test.
  Future<void> _waitForFirstFrame() async {
    try {
      await SchedulerBinding.instance.endOfFrame.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {},
      );
    } catch (_) {
      // No binding / no frame — proceed; the warm-ups are still
      // serialized, which is the part that cuts the peak.
    }
  }

  /// True when RSS is already high enough that warming the two big
  /// catalogs (VOD + series) would push the device toward a memory
  /// kill. The budget is half the RSS-watchdog threshold — the same
  /// per-tier table main.dart evicts at (L-8, one table, never a local
  /// copy of the formula): on a T1 TV that is ~165 MB, on the Fold
  /// ~768 MB. Tests force the gate with [debugBindWarmRssBudgetBytes].
  bool _bindRssTooHigh() {
    final budget = debugBindWarmRssBudgetBytes ?? _bindWarmBudgetBytes();
    return ProcessInfo.currentRss > budget;
  }

  /// 1.2.19 L-8: half of [DevicePerformance.watchdogThresholdBytes].
  static int _bindWarmBudgetBytes() => DevicePerformance.bindWarmBudgetBytes;

  /// Test-only override for the bind warm-up RSS budget (bytes). Null
  /// (default) computes it from device RAM; 0 always defers VOD/series.
  @visibleForTesting
  static int? debugBindWarmRssBudgetBytes;

  /// Warms the series catalog in the background (build #10): starts the
  /// unfiltered series load without awaiting it, so the NEXT search finds
  /// a warm catalog. Called at startup bind (see
  /// MultiServerManager.addIptvConnection). A load already in flight is
  /// shared, so repeated calls are free; a failed load logs and the next
  /// search retries it. Series only — movies search already works and
  /// warming the 199k-row VOD catalog on every rebind is unnecessary cost.
  void warmUpSeriesCatalog() {
    if (!_isXtream) return;
    // 1.2.11 (disk-paged browse): the warm-up ONLY seeds the search
    // index from the disk catalog (fire-and-forget, once per client —
    // the three warm-ups share one seed through the index-write
    // mutex). On the first run after upgrading, the disk already holds
    // the full lists, so the index is warm within seconds with no
    // network at all. The memo is no longer loaded here: browse/search/
    // guide read the index, and a cold index falls back to the memo/
    // disk path on demand. Disk only — the warm-up NEVER fetches from
    // the panel. The only catalog traffic is the weekly sync
    // (ensureSearchIndexSynced) and a manual refresh.
    unawaited(_maybeSeedSearchIndexFromDisk());
  }

  /// Same warm-up for the VOD catalog (build #13): the first Movies
  /// browse/search after app start otherwise races the 199k-row load.
  void warmUpVodCatalog() {
    if (!_isXtream) return;
    // 1.2.11: seed-only — see [warmUpSeriesCatalog].
    unawaited(_maybeSeedSearchIndexFromDisk());
  }

  /// Same warm-up for the live catalog (build #13): the first Live TV
  /// search after app start otherwise races the 55k-row load.
  void warmUpLiveCatalog() {
    if (!_isXtream) return;
    // 1.2.11: seed-only — see [warmUpSeriesCatalog].
    unawaited(_maybeSeedSearchIndexFromDisk());
  }

  /// Disk-only live warm-up (build #23, startup rule). 1.2.4:
  /// visible-only parse — the memo holds visible rows only, so a disk
  /// file written before 1.2.4 (full catalog) is pruned at read time.
  /// [force] is the toggle re-derive ([_rederiveMemosFromDisk]):
  /// re-parse and swap the memo even when one is loaded, so the stale
  /// memo keeps serving until the fresh one lands. 1.6.32: the VOD and
  /// series disk warm-ups are gone — the toggle re-derive drops those
  /// memos instead of re-parsing them (option 9), and the lazy path
  /// re-warms them on demand — so this live warm-up is the only disk
  /// warm-up left.
  Future<void> _warmLiveCatalogFromDisk({bool force = false}) async {
    if (!force && _liveStreamsLoaded) return;
    final filter = await _visibleCatalogFilterFor(IptvSearchIndex.typeLive);
    final disk = await _readDiskCatalogFromFile<XtreamLiveStream>(
      IptvCatalogDiskCache.liveDataset,
      (path) => XtreamApi.parseLiveStreamsFileVisible(path, filter),
    );
    if (disk == null) return;
    _liveStreamsFuture = Future.value(disk.rows);
    _liveStreamsLoaded = true;
    _liveLoadSource = 'disk';
    _memoSyncStamp[IptvSearchIndex.typeLive] = disk.fetchedAt;
  }

  /// On-device series catalog diagnostics (build #10, diagnosis
  /// recommendation 6): what the owner's phone can report about the series
  /// catalog in one screenshot — the unfiltered row count, the series
  /// category count, per-category row counts for the first few categories
  /// (direct get_series calls, which directly settle (g)), and how many
  /// initials/categories are turned off. Shown in the IPTV settings
  /// screen.
  ///
  /// Build #13: probes DIRECTLY, each call bounded by a short timeout.
  /// The old version awaited the full [_seriesList()] crawl, so on the
  /// exact phone that needs the readout — a (g)-shape panel whose crawl
  /// takes minutes — it never answered. `unfilteredSeriesRows` is now
  /// literally the rows the unfiltered get_series returned (0 on a
  /// (g) panel), not the crawled total.
  Future<IptvCatalogDiagnostics> seriesCatalogDiagnostics() async {
    const probeTimeout = Duration(seconds: 10);
    final unfiltered = await _xtreamApi
        .getSeries()
        .timeout(probeTimeout, onTimeout: () => const <XtreamSeries>[])
        .catchError((Object e) {
          appLogger.w('IPTV: series catalog probe failed for diagnostics: $e');
          return const <XtreamSeries>[];
        });
    final categories = await _seriesCategories()
        .timeout(probeTimeout, onTimeout: () => const <XtreamCategory>[])
        .catchError((Object e) {
          appLogger.w('IPTV: series category list unavailable for diagnostics: $e');
          return const <XtreamCategory>[];
        });
    final perCategory = <String, int>{};
    for (final category in categories.take(3)) {
      final probe = await _xtreamApi
          .getSeries(categoryId: category.id)
          .timeout(probeTimeout, onTimeout: () => const <XtreamSeries>[])
          .catchError((Object e) {
            appLogger.w('IPTV: series probe for ${category.id} failed: $e');
            return const <XtreamSeries>[];
          });
      perCategory['${category.name} (${category.id})'] = probe.length;
    }
    return IptvCatalogDiagnostics(
      unfilteredSeriesRows: unfiltered.length,
      seriesCategoryCount: categories.length,
      perCategorySeriesRows: perCategory,
      hiddenCategoryInitialsCount: _hiddenCategoryInitials.length,
      hiddenCategoriesCount: _hiddenCategories.length,
    );
  }

  /// A hidden category (its own switch, or its category initial turned
  /// off) returns [] without loading the catalog — the tab never lists
  /// it, so reaching here with a hidden id means a stale deep link. A hidden
  /// category (its own switch, or its category initial turned off) returns
  /// [] without loading the catalog — the tab never lists it, so reaching
  /// here with a hidden id means a stale deep link.
  Future<List<MediaItem>> iptvItemsForCategory(String libraryId, String categoryId) async {
    if (!_isXtream) return const [];
    if (libraryId == _moviesLibraryId) {
      final categoryNames = await _vodCategoryNames();
      if (_isHiddenCategory(categoryId, categoryNames[categoryId])) return const [];
      // 1.2.11: the category's rows come from the index in pages (no
      // memo load); the memo path is the cold fallback only.
      final indexRows = await _indexBrowsePage(
        IptvSearchIndex.typeMovie,
        categoryId: categoryId,
        offset: 0,
        limit: 5000,
      );
      if (indexRows != null) {
        // A category over one page is re-read page by page below; the
        // common case (under the page size) lands in this one call.
        final rows = <IptvSearchIndexRow>[...indexRows.rows];
        var offset = rows.length;
        while (offset < indexRows.total) {
          final next = await _indexBrowsePage(
            IptvSearchIndex.typeMovie,
            categoryId: categoryId,
            offset: offset,
            limit: 5000,
          );
          if (next == null || next.rows.isEmpty) break;
          rows.addAll(next.rows);
          offset += next.rows.length;
        }
        final favorites = await _favoriteItems();
        final resume = await _resumeItems();
        return rows
            .map((r) => r.toVodStream())
            .map(
              (s) => _movieItem(
                s,
                isFavorite: favorites.containsKey('movie:${s.streamId}'),
                categoryName: categoryNames[s.categoryId],
                resume: resume['movie:${s.streamId}'],
              ),
            )
            .toList();
      }
      final streams = await _vodStreams();
      final favorites = await _favoriteItems();
      final resume = await _resumeItems();
      return streams
          .where((s) => s.categoryId == categoryId)
          .map(
            (s) => _movieItem(
              s,
              isFavorite: favorites.containsKey('movie:${s.streamId}'),
              categoryName: categoryNames[s.categoryId],
              resume: resume['movie:${s.streamId}'],
            ),
          )
          .toList();
    }
    if (libraryId == _seriesLibraryId) {
      final categoryNames = await _seriesCategoryNames();
      if (_isHiddenCategory(categoryId, categoryNames[categoryId])) return const [];
      final indexRows = await _indexBrowsePage(
        IptvSearchIndex.typeSeries,
        categoryId: categoryId,
        offset: 0,
        limit: 5000,
      );
      if (indexRows != null) {
        final rows = <IptvSearchIndexRow>[...indexRows.rows];
        var offset = rows.length;
        while (offset < indexRows.total) {
          final next = await _indexBrowsePage(
            IptvSearchIndex.typeSeries,
            categoryId: categoryId,
            offset: offset,
            limit: 5000,
          );
          if (next == null || next.rows.isEmpty) break;
          rows.addAll(next.rows);
          offset += next.rows.length;
        }
        final favorites = await _favoriteItems();
        return rows
            .map((r) => r.toSeries())
            .map(
              (s) => _seriesItem(
                s,
                isFavorite: favorites.containsKey('series:${s.seriesId}'),
                categoryName: categoryNames[s.categoryId],
              ),
            )
            .toList();
      }
      final series = await _seriesList();
      final favorites = await _favoriteItems();
      return series
          .where((s) => s.categoryId == categoryId)
          .map(
            (s) => _seriesItem(
              s,
              isFavorite: favorites.containsKey('series:${s.seriesId}'),
              categoryName: categoryNames[s.categoryId],
            ),
          )
          .toList();
    }
    return const [];
  }

  @override
  Future<List<MediaSort>> fetchSortOptions(String libraryId, {String? libraryType}) async => [];

  @override
  Future<List<LibraryGenre>> fetchLibraryGenres(String libraryId, {required MediaKind libraryKind}) {
    // Genres tab is Plex/Jellyfin only in 1.5 (upstream 2.26.0): IPTV
    // libraries never offer the tab (see visibleLibraryTabs), so this is
    // a compile stub matching the other unsupported-operation stubs below.
    throw UnsupportedError('IPTV: fetchLibraryGenres not supported');
  }

  @override
  Future<void> refreshLibraryMetadata(String libraryId) {
    throw UnsupportedError('IPTV: refreshLibraryMetadata not supported');
  }

  @override
  Future<void> scanLibrary(String libraryId) {
    throw UnsupportedError('IPTV: scanLibrary not supported');
  }

  /// One catalog row by id, from the search index (1.2.4, catalog
  /// memory): the id-resolution fallback for [fetchItem] when the
  /// visible-only memo misses — a favourite/resume hidden after it was
  /// saved still opens until a sync prunes the row from the index.
  /// Null when the index is unavailable or the row was pruned.
  Future<IptvSearchIndexRow?> _resolveIndexRow(String type, int streamId) async {
    try {
      final index = await _searchIndex();
      return index?.resolveById(connection.id, type, streamId);
    } catch (e) {
      appLogger.w('IPTV: index resolve failed for $type:$streamId', error: e);
      return null;
    }
  }

  @override
  // 1.6.11 X2/X3: [skipVodInfo] returns the base item without awaiting
  // `get_vod_info` — the catalog row already has title/poster/rating,
  // which is all a card (or a detail page's first paint) needs. A
  // black-holed provider must not hold the home screen (one call per
  // CW row, sequentially) or a detail open for the 30 s response
  // budget. The enriching call still goes through `_vodInfo`.
  Future<MediaItem?> fetchItem(String id, {bool skipVodInfo = false}) async {
    if (!_isXtream) {
      // M3U: channel items are keyed `m3u:<tvg-id or name>`.
      if (id.startsWith('m3u:')) {
        final entries = await _m3uEntries();
        final key = id.substring(4);
        final entry = entries.where((e) => (e.tvgId ?? e.name) == key).firstOrNull;
        if (entry == null) return null;
        return MediaItem.m3u(
          id: id,
          kind: MediaKind.unknown,
          title: entry.name,
          thumbPath: entry.tvgLogo,
          streamUrl: entry.url,
          epgChannelId: entry.tvgId,
          categoryId: entry.groupTitle,
          libraryId: _liveLibraryId,
          libraryTitle: '$_name — Live TV',
          serverId: connection.id,
          serverName: _name,
        );
      }
      return null;
    }
    final parts = id.split(':');
    if (parts.length < 2) return null;
    switch (parts[0]) {
      case 'movie':
        final streamId = int.tryParse(parts[1]);
        if (streamId == null) return null;
        // 1.2.11: the index answers first (a point lookup — no memo
        // load for one detail screen); the memo is the fallback for a
        // cold index. 1.2.4: a favourite/resume hidden after it was
        // saved still opens, from the index (which holds the row until
        // a sync prunes it). After a pruning sync the index misses too
        // and this returns null, as before.
        var stream = (await _resolveIndexRow(IptvSearchIndex.typeMovie, streamId))?.toVodStream();
        stream ??= (await _vodByIdMap())[streamId];
        if (stream == null) return null;
        final movieFavorites = await _favoriteItems();
        final movieResume = await _resumeItems();
        final vodCategoryNames = await _vodCategoryNames();
        // 1.6.10 M1: one memoized `get_vod_info` per movie detail open
        // (zero on revisit). A failure leaves the base item — the page
        // still opens with title/poster/rating.
        XtreamVodInfo? vodInfo;
        if (!skipVodInfo) {
          try {
            vodInfo = await _vodInfo(stream.streamId);
          } catch (_) {
            vodInfo = null;
          }
        }
        return _movieItem(
          stream,
          isFavorite: movieFavorites.containsKey('movie:${stream.streamId}'),
          categoryName: vodCategoryNames[stream.categoryId],
          resume: movieResume['movie:${stream.streamId}'],
          vodInfo: vodInfo,
        );
      case 'series':
        final seriesId = int.tryParse(parts[1]);
        if (seriesId == null) return null;
        // 1.2.11: index first — see 'movie' above.
        var found = (await _resolveIndexRow(IptvSearchIndex.typeSeries, seriesId))?.toSeries();
        found ??= (await _seriesByIdMap())[seriesId];
        if (found == null) return null;
        final seriesFavorites = await _favoriteItems();
        final seriesCategoryNames = await _seriesCategoryNames();
        // 1.6.11 X1: the show header was blank exactly where 1.6.10 was
        // meant to fill it — fetch the memoized info (one call on first
        // open, zero on revisit) and fill the row's blanks from it.
        final seriesInfo = await _seriesInfo(seriesId);
        final filled = found.withInfoGapsFilled(seriesInfo.info);
        return _seriesItem(
          filled,
          isFavorite: seriesFavorites.containsKey('series:${filled.seriesId}'),
          categoryName: seriesCategoryNames[filled.categoryId],
        );
      case 'live':
        // Build #13: live search results are keyed `live:<streamId>`.
        final liveStreamId = int.tryParse(parts[1]);
        if (liveStreamId == null) return null;
        // 1.2.11: index first — see 'movie' above.
        var liveFound = (await _resolveIndexRow(IptvSearchIndex.typeLive, liveStreamId))?.toLiveStream();
        liveFound ??= (await _liveStreams()).where((s) => s.streamId == liveStreamId).firstOrNull;
        if (liveFound == null) return null;
        final liveCategoryNames = await _liveCategoryNames();
        return _liveChannelItem(liveFound, categoryName: liveCategoryNames[liveFound.categoryId]);
      case 'season':
        // 1.5.3 K1: a season id ('season:<seriesId>:<n>') resolves to the
        // synthetic season item, so _fetchAndStoreParentMetadata can store
        // real season rows for IPTV downloads. Before this there was no
        // season case, so the parent lookup always returned null.
        if (parts.length < 3) return null;
        final seasonSeriesId = int.tryParse(parts[1]);
        final seasonNum = int.tryParse(parts[2]);
        if (seasonSeriesId == null || seasonNum == null) return null;
        var seasonSeries = (await _resolveIndexRow(IptvSearchIndex.typeSeries, seasonSeriesId))?.toSeries();
        seasonSeries ??= (await _seriesByIdMap())[seasonSeriesId];
        if (seasonSeries == null) return null;
        final seasonInfo = await _seriesInfo(seasonSeriesId);
        final seasonEpisodes = seasonInfo.episodesBySeason[seasonNum];
        if (seasonEpisodes == null) return null;
        final seasonCategoryNames = await _seriesCategoryNames();
        // 1.6.11 X1: same one-line fill as the series case — the info
        // is already in hand, so zero new calls.
        final filledSeasonSeries = seasonSeries.withInfoGapsFilled(seasonInfo.info);
        return _seasonItem(
          filledSeasonSeries,
          seasonNum,
          seasonEpisodes.length,
          seriesCategoryName: seasonCategoryNames[filledSeasonSeries.categoryId],
        );
      case 'episode':
        if (parts.length < 3) return null;
        final seriesId = int.tryParse(parts[1]);
        final episodeId = int.tryParse(parts[2]);
        if (seriesId == null || episodeId == null) return null;
        // 1.6.11 P2: the memoized info — the raw call paid a second full
        // `get_series_info` + parse per detail open with a resumed episode.
        final info = await _seriesInfo(seriesId);
        for (final seasonEntry in info.episodesBySeason.entries) {
          final episode = seasonEntry.value.where((e) => e.id == episodeId).firstOrNull;
          if (episode == null) continue;
          // 1.2.11: index first for the series row — see 'movie' above.
          var series = (await _resolveIndexRow(IptvSearchIndex.typeSeries, seriesId))?.toSeries();
          series ??= (await _seriesByIdMap())[seriesId];
          if (series == null) return null;
          // 1.6.10 M0: the info block is already fetched above — fill
          // the list row's blanks from it at zero new calls.
          series = series.withInfoGapsFilled(info.info);
          final episodeFavorites = await _favoriteItems();
          final episodeResume = await _resumeItems();
          final episodeCategoryNames = await _seriesCategoryNames();
          return _episodeItem(
            series,
            episode,
            seasonEntry.key,
            isFavorite: episodeFavorites.containsKey('episode:${series.seriesId}:${episode.id}'),
            seriesCategoryName: episodeCategoryNames[series.categoryId],
            resume: episodeResume['episode:${series.seriesId}:${episode.id}'],
          );
        }
        return null;
      default:
        return null;
    }
  }

  @override
  Future<({MediaItem? item, MediaItem? onDeckEpisode})> fetchItemWithOnDeck(
    String id, {
    void Function(MediaItem item)? onItemReady,
    bool skipVodInfo = false,
  }) async {
    final item = await fetchItem(id, skipVodInfo: skipVodInfo);
    if (item != null) onItemReady?.call(item);
    MediaItem? onDeckEpisode;
    // Build #25 (25.5): a series opens on the episode you would
    // continue — the latest-resumed episode of that series, if any.
    // Best-effort: a stale id simply leaves the episode null.
    if (item != null && item.kind == MediaKind.show) {
      try {
        final resume = await _resumeItems();
        final episodes = resume.values
            .where((e) {
              if (e.kind != 'episode') return false;
              // Legacy rows carry the show as parentId; 1.5.3 K1 moved
              // the episode parentId to the season, so match those via
              // the grandparent (bare series id, or the old 'series:'
              // form from fallback rows written before the fix).
              if (e.parentId == id) return true;
              final showId = id.startsWith('series:') ? id.substring('series:'.length) : id;
              return e.grandparentId == showId || e.grandparentId == id;
            })
            .toList()
          ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
        if (episodes.isNotEmpty) {
          onDeckEpisode = await fetchItem(episodes.first.id);
        }
      } catch (_) {
        // On-deck is a convenience, never a failure.
      }
    }
    return (item: item, onDeckEpisode: onDeckEpisode);
  }

  @override
  Future<List<MediaItem>> fetchChildren(String parentId) async {
    if (!_isXtream) return const [];
    final parts = parentId.split(':');
    if (parts.length < 2) return const [];
    // A season id ('season:<seriesId>:<n>') returns that season's
    // episodes (build #17): the detail screen fetches the selected
    // season's episodes through this id, and fetchChildrenPage slices
    // them for the season pager.
    if (parts[0] == 'season') {
      final seriesId = int.tryParse(parts[1]);
      final seasonNum = parts.length >= 3 ? int.tryParse(parts[2]) : null;
      if (seriesId == null || seasonNum == null) return const [];
      final row = (await _seriesByIdMap())[seriesId];
      if (row == null) return const [];
      final info = await _seriesInfo(seriesId);
      final seasonEpisodes = info.episodesBySeason[seasonNum];
      if (seasonEpisodes == null) return const [];
      final favorites = await _favoriteItems();
      final resume = await _resumeItems();
      final categoryNames = await _seriesCategoryNames();
      // 1.5.3 N3: reuse the mapped list while every memo it was built
      // from is still the same instance (see _seasonEpisodeItemsCache).
      // 1.6.11 P1: the check keys on the STABLE inputs — the catalog
      // row + info — never on the gap-filled copy, which
      // `withInfoGapsFilled` rebuilds fresh on every call whenever the
      // info block is non-null, so the check could never hit.
      final cacheKey = 'season:$seriesId:$seasonNum';
      final cached = _seasonEpisodeItemsCache[cacheKey];
      if (cached != null &&
          identical(cached.row, row) &&
          identical(cached.info, info) &&
          identical(cached.favorites, favorites) &&
          identical(cached.resume, resume) &&
          identical(cached.categoryNames, categoryNames)) {
        // A fresh list per call (the old code returned a fresh list
        // too): callers may sort or sublist freely, the cache stays
        // intact, and the episode objects are shared.
        return List<MediaItem>.of(cached.items, growable: false);
      }
      // 1.6.10 M0: fill the list row's blanks from the info block —
      // already fetched for the season list, so zero new calls. Applied
      // at map time, only on a cache miss.
      final series = row.withInfoGapsFilled(info.info);
      final seriesCategoryName = categoryNames[series.categoryId];
      // Sort a copy: the info object's lists are shared state (and may
      // be unmodifiable), so sorting them in place mutates the cache.
      final sorted = seasonEpisodes.toList()..sort((a, b) => a.episodeNum.compareTo(b.episodeNum));
      final items = sorted
          .map(
            (episode) => _episodeItem(
              series,
              episode,
              seasonNum,
              isFavorite: favorites.containsKey('episode:${series.seriesId}:${episode.id}'),
              seriesCategoryName: seriesCategoryName,
              resume: resume['episode:${series.seriesId}:${episode.id}'],
            ),
          )
          .toList(growable: false);
      _seasonEpisodeItemsCache[cacheKey] = _SeasonEpisodeItems(
        row: row,
        info: info,
        favorites: favorites,
        resume: resume,
        categoryNames: categoryNames,
        items: items,
      );
      return List<MediaItem>.of(items, growable: false);
    }
    if (parts[0] != 'series') return const [];
    final seriesId = int.tryParse(parts[1]);
    if (seriesId == null) return const [];
    final row = (await _seriesByIdMap())[seriesId];
    if (row == null) return const [];
    final info = await _seriesInfo(seriesId);
    // 1.6.10 M0: same info-block fallback as the season branch above.
    final series = row.withInfoGapsFilled(info.info);
    final seasons = info.episodesBySeason.keys.toList()..sort();
    // One synthetic season item per season (build #17): the detail
    // screen — and the download / sync / title-copy callers — treat
    // fetchChildren(series) as seasons. The old flat episode list made
    // every episode render as a season tab (labelled with the episode's
    // panel title, e.g. "… - S01E01") and fetching that "season"'s
    // children return [] ("No episodes found").
    final categoryNames = await _seriesCategoryNames();
    final seriesCategoryName = categoryNames[series.categoryId];
    return seasons
        .map(
          (season) => _seasonItem(
            series,
            season,
            info.episodesBySeason[season]!.length,
            seriesCategoryName: seriesCategoryName,
          ),
        )
        .toList(growable: false);
  }

  /// One synthetic season item for an Xtream series (build #17 — the
  /// panel has no season items, only per-season episode lists, so the
  /// client synthesizes them). Server/library fields are copied from the
  /// series item so the detail screen's fallbacks treat the season like
  /// a Plex season.
  MediaItem _seasonItem(
    XtreamSeries series,
    int season,
    int episodeCount, {
    String? seriesCategoryName,
  }) {
    // 1.6.11 X8: the full backdrop array, not just the first URL.
    final backdropPath = series.backdropPath;
    final backdrops = series.backdropPaths ?? (backdropPath == null ? null : [backdropPath]);
    return MediaItem.xtream(
      id: 'season:${series.seriesId}:$season',
      kind: MediaKind.season,
      title: 'Season $season',
      parentId: 'series:${series.seriesId}',
      parentTitle: stripCategoryPrefix(series.name, seriesCategoryName),
      index: season,
      leafCount: episodeCount,
      thumbPath: series.cover,
      // 1.6.10 M0: the series backdrop, so the season detail hero has
      // art instead of a black panel.
      backdropPaths: backdrops,
      categoryId: series.categoryId,
      libraryId: _seriesLibraryId,
      libraryTitle: '$_name — Series',
      serverId: connection.id,
      serverName: _name,
    );
  }

  /// Memoized series-info fetch (build #17): `fetchChildren` needs the
  /// info for the season list AND for each season's episodes, and
  /// `fetchPlayableDescendants` walks both — without memoization one
  /// series detail would pay one get_series_info per season plus one
  /// for the list. A failed fetch is evicted so a retry re-fetches.
  /// Cleared with the catalog cache.
  final Map<int, Future<XtreamSeriesInfo>> _seriesInfoFutures = {};

  /// Mapped season-episode lists (1.5.3 N3): `fetchChildren('season:…')`
  /// used to re-sort and re-map the whole season into fresh MediaItems
  /// on every call, and `fetchChildrenPage` slices that full list — so
  /// every season-pager page turn re-paid the whole-season map + sort.
  /// The mapped list is cached per season, validated against the memo
  /// identities it was built from (series row, series info, favorites,
  /// resume, category names): any of those changing — a favorite toggle,
  /// a resume write, a catalog re-seed — swaps the memo instance and
  /// the cache re-maps on the next read instead of serving stale hearts
  /// or resume positions. Cleared with the series-info futures when the
  /// catalog is dropped, so a long session cannot accumulate seasons.
  final Map<String, _SeasonEpisodeItems> _seasonEpisodeItemsCache = {};

  /// LRU caps (1.6.11 P5): the info memos are cleared only on catalog
  /// clear / memory-pressure drop, so a long browsing session
  /// accumulates one entry per distinct title opened. Evicting the
  /// oldest entry only costs a re-fetch on revisit.
  static const int _seriesInfoMemoCap = 64;
  static const int _vodInfoMemoCap = 128;

  Future<XtreamSeriesInfo> _seriesInfo(int seriesId) {
    final cached = _seriesInfoFutures[seriesId];
    if (cached != null) {
      // Refresh recency: most-recently-used stays.
      _seriesInfoFutures.remove(seriesId);
      _seriesInfoFutures[seriesId] = cached;
      return cached;
    }
    final future = _xtreamApi.getSeriesInfo(seriesId).catchError((Object e) {
      _seriesInfoFutures.remove(seriesId);
      throw e;
    });
    _seriesInfoFutures[seriesId] = future;
    while (_seriesInfoFutures.length > _seriesInfoMemoCap) {
      _seriesInfoFutures.remove(_seriesInfoFutures.keys.first);
    }
    return future;
  }

  /// Memoized movie-info fetch (1.6.10 M1): mirrors [_seriesInfo] —
  /// one `get_vod_info` per movie detail open, shared with
  /// [fetchExternalIds], so the detail page and the ratings row cost
  /// one small call between them and zero on revisit. A failed fetch
  /// is evicted so a retry re-fetches. Cleared with the catalog cache.
  final Map<int, Future<XtreamVodInfo>> _vodInfoFutures = {};

  Future<XtreamVodInfo> _vodInfo(int vodId) {
    final cached = _vodInfoFutures[vodId];
    if (cached != null) {
      _vodInfoFutures.remove(vodId);
      _vodInfoFutures[vodId] = cached;
      return cached;
    }
    final future = _xtreamApi.getVodInfo(vodId).catchError((Object e) {
      _vodInfoFutures.remove(vodId);
      throw e;
    });
    _vodInfoFutures[vodId] = future;
    while (_vodInfoFutures.length > _vodInfoMemoCap) {
      _vodInfoFutures.remove(_vodInfoFutures.keys.first);
    }
    return future;
  }

  @override
  Future<List<MediaItem>> fetchLibraryFolders(String libraryId, {void Function(List<MediaItem> itemsSoFar)? onPage}) {
    throw UnsupportedError('IPTV: fetchLibraryFolders not supported');
  }

  @override
  Future<List<MediaItem>> fetchFolderChildren(
    MediaItem folder, {
    String? libraryId,
    String? libraryTitle,
    void Function(List<MediaItem> itemsSoFar)? onPage,
  }) {
    throw UnsupportedError('IPTV: fetchFolderChildren not supported');
  }

  @override
  Future<LibraryPage<MediaItem>> fetchChildrenPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final children = await fetchChildren(parentId);
    final offset = (start ?? 0).clamp(0, children.length);
    final end = size == null ? children.length : (offset + size).clamp(0, children.length);
    return LibraryPage(items: children.sublist(offset, end), totalCount: children.length, offset: offset);
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPlayableDescendantsPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) {
    throw UnsupportedError('IPTV: fetchPlayableDescendantsPage not supported');
  }

  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId) async {
    final children = await fetchChildren(parentId);
    if (children.isEmpty) return const [];
    // A series now returns season items (build #17); the leaves callers
    // (downloads, sync, deep links, the offline queue) need the
    // episodes, so expand each season into its episodes. A season id
    // already returns episodes and passes through unchanged.
    if (children.first.kind == MediaKind.season) {
      final episodes = <MediaItem>[];
      for (final season in children) {
        episodes.addAll(await fetchChildren(season.id));
      }
      return episodes;
    }
    return children;
  }

  @override
  Future<List<MediaItem>?> fetchClientSideEpisodeQueue(String seriesId) async {
    final episodes = await fetchPlayableDescendants(seriesId);
    return episodes.isEmpty ? null : episodes;
  }

  @override
  Future<List<MediaItem>> fetchArtistAlbums(MediaItem artist) {
    throw UnsupportedError('IPTV: fetchArtistAlbums not supported');
  }

  @override
  Future<List<ArtistDiscographyGroup>> fetchArtistDiscography(MediaItem artist) {
    throw UnsupportedError('IPTV: fetchArtistDiscography not supported');
  }

  @override
  Future<List<MediaItem>> fetchAlbumTracks(String albumId) {
    throw UnsupportedError('IPTV: fetchAlbumTracks not supported');
  }

  @override
  Future<List<MediaItem>> fetchInstantMix(String itemId, {int limit = 100}) {
    throw UnsupportedError('IPTV: fetchInstantMix not supported');
  }

  @override
  Future<Lyrics?> fetchLyrics(MediaItem track) {
    throw UnsupportedError('IPTV: fetchLyrics not supported');
  }

  @override
  Future<List<MediaItem>> searchItems(
    String query, {
    int limit = 100,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
    bool onlineAllowed = false,
  }) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    abort?.throwIfAborted();
    // Build #21: track the in-flight search so a health probe that fires
    // mid-search can be deferred instead of adding a concurrent request
    // to a busy panel (see [checkHealth]). The deferred probe fires once,
    // coalesced, when the last concurrent search on this client ends.
    _activeSearchCount++;
    try {
      return await _searchItemsInner(
        needle,
        limit: limit,
        abort: abort,
        excludedLibraryIds: excludedLibraryIds,
        onlineAllowed: onlineAllowed,
      );
    } finally {
      _activeSearchCount--;
      if (_activeSearchCount == 0) _fireDeferredHealthProbe();
    }
  }

  Future<List<MediaItem>> _searchItemsInner(
    String needle, {
    required int limit,
    required AbortController? abort,
    required Set<String> excludedLibraryIds,
    required bool onlineAllowed,
  }) async {
    final searchStarted = DateTime.now();
    if (_isXtream) {
      // Build #23 — scope inversion (global first): the three sections
      // always run, and the scope is a filter over the already-fetched
      // global result (the aggregation drops rows outside the scope, and
      // the hidden-library filter drops hidden ones). The client no
      // longer skips a section for a scoped search — when the local
      // index is warm that costs nothing (three FTS queries, zero panel
      // requests), and it means a wrong scope can never hide a row the
      // index has. The [include] flag still matters for the FALLBACK
      // paths: when the index is cold for a section, an excluded section
      // is skipped instead of kicking off a sync for rows the caller
      // will drop (build #21's request minimisation stands, R2.3).
      final includeMovies = !excludedLibraryIds.contains(_moviesLibraryId);
      final includeSeries = !excludedLibraryIds.contains(_seriesLibraryId);
      // Live TV is not a real library, so it can never appear in
      // excludedLibraryIds itself — but the search screen's scope strip
      // excludes every OTHER library when a scope is active, so live
      // shows only for an unscoped search (build #13: "search in live
      // TV" was empty by construction before this — Xtream live channels
      // had no search leg at all, only M3U channels did).
      final includeLive = excludedLibraryIds.isEmpty;
      final moviesTrace = _SectionTrace();
      final seriesTrace = _SectionTrace();
      final liveTrace = _SectionTrace();
      // Sections fetch concurrently and fail open on their own: a movies
      // failure must not kill series results (and vice versa), and a cold
      // search costs max(movies, series, live), not the sum — the old sequential
      // awaits behind the 20s search leg deadline returned zero IPTV
      // results on a slow connection.
      //
      // Build #8 Task 1: each section gets its OWN `limit` of results.
      // The old merge capped the COMBINED list at `limit` movies-first, so
      // any query matching 100+ movies returned zero series — before the
      // aggregation's relevance ranking ever ran. The merged pool is at most
      // 3 * limit; the aggregation re-ranks it and caps it at its own limit,
      // so an exact series-title match now beats partial movie matches.
      //
      // Each section also races [searchSectionBudget]: a section that misses
      // it returns [] for this search — the Enter path answers from disk
      // in milliseconds, so the budget is a safety net for a stalled
      // disk read, not the 49 s sweep it used to bound (R2.3).
      // Build #21: one AbortController per section, plus the search-wide
      // burst semaphore. A new keystroke (the caller's abort) cancels all
      // three sections at once; a section's own budget timeout cancels
      // only that section — and cancelling means the sockets close, not
      // just the future being abandoned (see XtreamApi's AbortableRequest).
      // The three sections share one [_searchBurst], so the panel never
      // sees more than [_searchBurstCap] search requests in flight.
      final moviesAbort = AbortController();
      final seriesAbort = AbortController();
      final liveAbort = AbortController();
      // Build #21 (close-after-use): track the sections' controllers
      // so cancelActiveSearches() can abort an in-flight search (app
      // backgrounded, connection torn down).
      _activeSearchAborts.addAll([moviesAbort, seriesAbort, liveAbort]);
      if (abort != null) {
        unawaited(
          abort.trigger.then((_) {
            moviesAbort.abort();
            seriesAbort.abort();
            liveAbort.abort();
          }),
        );
      }
      try {
        final sections = await Future.wait([
          _searchMovies(
            needle,
            limit,
            moviesTrace,
            burst: _searchBurst,
            sectionAbort: moviesAbort,
            include: includeMovies,
            onlineAllowed: onlineAllowed,
          ).timeout(searchSectionBudget, onTimeout: () {
            // Hard-cancel the section's in-flight requests: the budget
            // expired, so the search already returned — those sockets
            // must stop, not keep downloading for a dead search.
            moviesAbort.abort();
            return moviesTrace.partialOut;
          }),
          _searchSeries(
            needle,
            limit,
            seriesTrace,
            burst: _searchBurst,
            sectionAbort: seriesAbort,
            include: includeSeries,
            onlineAllowed: onlineAllowed,
          ).timeout(searchSectionBudget, onTimeout: () {
            seriesAbort.abort();
            return seriesTrace.partialOut;
          }),
          _searchLive(
            needle,
            limit,
            liveTrace,
            burst: _searchBurst,
            sectionAbort: liveAbort,
            include: includeLive,
            onlineAllowed: onlineAllowed,
          ).timeout(searchSectionBudget, onTimeout: () {
            liveAbort.abort();
            return liveTrace.partialOut;
          }),
        ]);
        _lastSearchDiagnostics = IptvSearchDiagnostics(
          query: needle,
          scoped: excludedLibraryIds.isNotEmpty,
          totalMs: DateTime.now().difference(searchStarted).inMilliseconds,
          movies: moviesTrace.diagnostics,
          series: seriesTrace.diagnostics,
          live: liveTrace.diagnostics,
          recordedAt: DateTime.now(),
        );
        return sections.expand((items) => items).toList();
      } finally {
        _activeSearchAborts.remove(moviesAbort);
        _activeSearchAborts.remove(seriesAbort);
        _activeSearchAborts.remove(liveAbort);
      }
    }
    // M3U: the playlist is the catalog; channels surface as playable items.
    final m3uLiveTrace = _SectionTrace();
    final m3uStarted = DateTime.now();
    final m3uResults = await _searchM3uEntries(needle, limit, excludedLibraryIds, m3uLiveTrace);
    m3uLiveTrace.loadRows = m3uResults.length;
    m3uLiveTrace.loadMatches = m3uResults.length;
    m3uLiveTrace.ms = DateTime.now().difference(m3uStarted).inMilliseconds;
    final emptyTrace = _SectionTrace()..skipped = true;
    _lastSearchDiagnostics = IptvSearchDiagnostics(
      query: needle,
      scoped: excludedLibraryIds.isNotEmpty,
      totalMs: DateTime.now().difference(searchStarted).inMilliseconds,
      movies: emptyTrace.diagnostics,
      series: emptyTrace.diagnostics,
      live: m3uLiveTrace.diagnostics,
      recordedAt: DateTime.now(),
    );
    return m3uResults;
  }

  /// Append this section's matches from [rows] to [out], honouring the
  /// hidden-category filter and the query, de-duplicated by stream id (a
  /// panel may return the same row under two categories).
  /// Shared by the warm path and the cold sweep so the two cannot drift.
  /// A row that matches the query but sits in a hidden category is
  /// counted on [trace] (build #17) instead of being silently dropped —
  /// the search screen tells the user the filter hid it.
  void _appendMovieMatches(
    List<XtreamVodStream> rows,
    String needle,
    int limit,
    Map<String, IptvFavoriteItem> favorites,
    Map<String, IptvResumeItem> resume,
    Map<String, String> categoryNames,
    List<MediaItem> out,
    Set<int> seen,
    _SectionTrace trace,
  ) {
    // One case-insensitive pattern for the whole scan (build #13): the
    // old `name.toLowerCase().contains(needle)` allocated a lowercased
    // copy of every row's name — 199k allocations per search, ~130ms
    // of UI-thread work. hasMatch allocates nothing per row.
    final match = RegExp(RegExp.escape(needle), caseSensitive: false);
    for (final stream in rows) {
      if (out.length >= limit) break;
      if (!seen.add(stream.streamId)) continue;
      if (!match.hasMatch(stream.name)) continue;
      if (_isHiddenCategory(stream.categoryId, categoryNames[stream.categoryId])) {
        trace.hiddenMatches++;
        final initial = categoryInitial(categoryNames[stream.categoryId]);
        if (initial != null) trace.hiddenInitials.add(initial);
        continue;
      }
      out.add(
        _movieItem(
          stream,
          isFavorite: favorites.containsKey('movie:${stream.streamId}'),
          categoryName: categoryNames[stream.categoryId],
          resume: resume['movie:${stream.streamId}'],
        ),
      );
    }
  }

  /// Same as [_appendMovieMatches], for series rows.
  void _appendSeriesMatches(
    List<XtreamSeries> rows,
    String needle,
    int limit,
    Map<String, IptvFavoriteItem> favorites,
    Map<String, String> categoryNames,
    List<MediaItem> out,
    Set<int> seen,
    _SectionTrace trace,
  ) {
    // One case-insensitive pattern for the whole scan — see
    // [_appendMovieMatches].
    final match = RegExp(RegExp.escape(needle), caseSensitive: false);
    for (final s in rows) {
      if (out.length >= limit) break;
      if (!seen.add(s.seriesId)) continue;
      if (!match.hasMatch(s.name)) continue;
      if (_isHiddenCategory(s.categoryId, categoryNames[s.categoryId])) {
        trace.hiddenMatches++;
        final initial = categoryInitial(categoryNames[s.categoryId]);
        if (initial != null) trace.hiddenInitials.add(initial);
        continue;
      }
      out.add(
        _seriesItem(
          s,
          isFavorite: favorites.containsKey('series:${s.seriesId}'),
          categoryName: categoryNames[s.categoryId],
        ),
      );
    }
  }


  /// Search one section from the local index (build #23). Returns the
  /// section's matches when the index is warm for [type] — zero panel
  /// requests, regardless of [include] (global first; the aggregation
  /// filters by scope) — or null when the index is cold for the type,
  /// so the caller falls through to the disk/sync paths (R2.3). The
  /// category names come from the index alone (no panel round trip),
  /// and the rows are mapped back to Xtream models so the existing
  /// append builders (hidden-category filter, prefix strip, favourites)
  /// run unchanged.
  Future<List<MediaItem>?> _searchMoviesFromIndex(
    String needle,
    int limit,
    _SectionTrace trace,
    DateTime sectionStarted,
  ) async {
    final index = await _searchIndex();
    if (index == null) return null;
    final totalRows = index.rowCounts(connection.id)[IptvSearchIndex.typeMovie] ?? 0;
    if (totalRows == 0) return null;
    final favorites = await _favoriteItems();
    final resume = await _resumeItems();
    final categoryNames = index.categoryNames(connection.id, IptvSearchIndex.typeMovie);
    // L-5: the FTS rank path runs off the main isolate — a keystroke
    // never blocks the UI thread on a synchronous disk read. Stale
    // results are dropped by the search screens' generation guard.
    final rows = (await index.searchAsync(connection.id, IptvSearchIndex.typeMovie, needle, limit: limit * 2))
        .map((r) => r.toVodStream())
        .toList(growable: false);
    final out = <MediaItem>[];
    trace.partialOut = out;
    _appendMovieMatches(rows, needle, limit, favorites, resume, categoryNames, out, <int>{}, trace);
    trace.loadRows = totalRows;
    trace.loadSource = 'index';
    trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
    trace.loadMatches = out.length;
    trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
    return out;
  }

  /// Same as [_searchMoviesFromIndex], for series.
  Future<List<MediaItem>?> _searchSeriesFromIndex(
    String needle,
    int limit,
    _SectionTrace trace,
    DateTime sectionStarted,
  ) async {
    final index = await _searchIndex();
    if (index == null) return null;
    final totalRows = index.rowCounts(connection.id)[IptvSearchIndex.typeSeries] ?? 0;
    if (totalRows == 0) return null;
    final favorites = await _favoriteItems();
    final categoryNames = index.categoryNames(connection.id, IptvSearchIndex.typeSeries);
    // L-5: the FTS rank path runs off the main isolate — a keystroke
    // never blocks the UI thread on a synchronous disk read. Stale
    // results are dropped by the search screens' generation guard.
    final rows = (await index.searchAsync(connection.id, IptvSearchIndex.typeSeries, needle, limit: limit * 2))
        .map((r) => r.toSeries())
        .toList(growable: false);
    final out = <MediaItem>[];
    trace.partialOut = out;
    _appendSeriesMatches(rows, needle, limit, favorites, categoryNames, out, <int>{}, trace);
    trace.loadRows = totalRows;
    trace.loadSource = 'index';
    trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
    trace.loadMatches = out.length;
    trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
    return out;
  }

  /// Same as [_searchMoviesFromIndex], for live channels. The hidden
  /// channels set is loaded first (a prefs read, local) so
  /// [_appendLiveMatches] skips hidden channels exactly as the warm
  /// path does.
  Future<List<MediaItem>?> _searchLiveFromIndex(
    String needle,
    int limit,
    _SectionTrace trace,
    DateTime sectionStarted,
  ) async {
    final index = await _searchIndex();
    if (index == null) return null;
    final totalRows = index.rowCounts(connection.id)[IptvSearchIndex.typeLive] ?? 0;
    if (totalRows == 0) return null;
    final categoryNames = index.categoryNames(connection.id, IptvSearchIndex.typeLive);
    await _liveTv.loadHiddenChannels();
    // L-5: the FTS rank path runs off the main isolate — a keystroke
    // never blocks the UI thread on a synchronous disk read. Stale
    // results are dropped by the search screens' generation guard.
    final rows = (await index.searchAsync(connection.id, IptvSearchIndex.typeLive, needle, limit: limit * 2))
        .map((r) => r.toLiveStream())
        .toList(growable: false);
    final out = <MediaItem>[];
    trace.partialOut = out;
    _appendLiveMatches(rows, needle, limit, categoryNames, out, <int>{}, trace);
    trace.loadRows = totalRows;
    trace.loadSource = 'index';
    trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
    trace.loadMatches = out.length;
    trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
    return out;
  }

  Future<List<MediaItem>> _searchMovies(
    String needle,
    int limit,
    _SectionTrace trace, {
    required _SearchRequestSemaphore burst,
    required AbortController sectionAbort,
    required bool include,
    bool onlineAllowed = false,
  }) async {
    try {
      final sectionStarted = DateTime.now();
      // Build #23 — scope inversion (global first): the index answers
      // first — zero panel requests when warm — REGARDLESS of [include];
      // the aggregation filters by scope. The [include] flag only gates
      // the cold fallback below: an excluded section with a cold index
      // is skipped instead of kicking off a sync for rows the caller
      // will drop (build #21's request minimisation stands, R2.3). Do
      // NOT move the check above the index call — that overturns #23
      // (see the build23 scope-inversion test).
      final indexOut = await _searchMoviesFromIndex(needle, limit, trace, sectionStarted);
      if (indexOut != null) return indexOut;
      if (!include) {
        trace.skipped = true;
        trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
        return const [];
      }
      // Build v1.0.11 (R2.0 + R2.3 — cold index, local data only):
      // the index is cold for this type, so answer from the local rows
      // the app already has — the warm in-memory catalog, else the disk
      // file, else the crawl's published partial rows, else [] with the
      // syncing state. Typing and submit alike: the SEARCH RULE forbids
      // panel requests while typing, and these rows cost none. Only a
      // submit kicks off ONE coalesced sync (6 requests, the only panel
      // traffic), and the screen re-runs this search when it lands. No
      // sweep, no unfiltered load, no per-category fetch — the old cold
      // path (load-vs-sweep race + heal + disk repair) is deleted with
      // the sweep; the sync owns fetching now.
      if (onlineAllowed) unawaited(ensureSearchIndexSynced(retryTransportErrors: true));
      trace.cold = true;
      // 1.2.18 C-5: seed-then-search — warm the index in the
      // background so the next keystroke uses FTS instead of
      // RegExp-scanning the full disk rows again. This keystroke
      // still answers from the disk scan below.
      _kickColdSearchSeed(IptvSearchIndex.typeMovie);
      final favorites = await _favoriteItems();
      final resume = await _resumeItems();
      final categoryNames = await _vodCategoryNamesFromDisk();
      final diskRows = await _vodRowsForEnterSearch();
      final out = <MediaItem>[];
      trace.partialOut = out;
      final seen = <int>{};
      _appendMovieMatches(diskRows.rows, needle, limit, favorites, resume, categoryNames, out, seen, trace);
      trace.loadRows = diskRows.rows.length;
      trace.loadSource = diskRows.source;
      trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
      trace.loadMatches = out.length;
      trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
      return out;
    } catch (e) {
      appLogger.w('IPTV: movie search failed: $e');
      return const [];
    }
  }

  Future<List<MediaItem>> _searchSeries(
    String needle,
    int limit,
    _SectionTrace trace, {
    required _SearchRequestSemaphore burst,
    required AbortController sectionAbort,
    required bool include,
    bool onlineAllowed = false,
  }) async {
    try {
      final sectionStarted = DateTime.now();
      // Build #23: the local index answers first (see _searchMovies —
      // global first regardless of [include]; the flag gates the cold
      // fallback only).
      final indexOut = await _searchSeriesFromIndex(needle, limit, trace, sectionStarted);
      if (indexOut != null) return indexOut;
      if (!include) {
        trace.skipped = true;
        trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
        return const [];
      }
      // Build v1.0.11 (R2.0 + R2.3 — cold index, local data only):
      // same shape as movies — local rows only; only a submit kicks off
      // the coalesced sync.
      if (onlineAllowed) unawaited(ensureSearchIndexSynced(retryTransportErrors: true));
      trace.cold = true;
      // 1.2.18 C-5: seed-then-search — see _searchMovies.
      _kickColdSearchSeed(IptvSearchIndex.typeSeries);
      final favorites = await _favoriteItems();
      final categoryNames = await _seriesCategoryNamesFromDisk();
      final diskRows = await _seriesRowsForEnterSearch();
      final out = <MediaItem>[];
      trace.partialOut = out;
      final seen = <int>{};
      _appendSeriesMatches(diskRows.rows, needle, limit, favorites, categoryNames, out, seen, trace);
      trace.loadRows = diskRows.rows.length;
      trace.loadSource = diskRows.source;
      trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
      trace.loadMatches = out.length;
      trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
      return out;
    } catch (e) {
      appLogger.w('IPTV: series search failed: $e');
      return const [];
    }
  }

  /// Live TV search (build #13): Xtream live channels had NO search leg
  /// at all — only M3U channels were searchable — so "search in live TV"
  /// was empty by construction. Same shape as movies/series: race the
  /// unfiltered live load (disk-cached, build #11) against a per-category
  /// sweep, so a slow 55k-row load cannot hold the section hostage.
  /// Search never opens a stream (one-stream limit): results are plain
  /// items whose tap resolves through `fetchItem('live:<id>')`.
  Future<List<MediaItem>> _searchLive(
    String needle,
    int limit,
    _SectionTrace trace, {
    required _SearchRequestSemaphore burst,
    required AbortController sectionAbort,
    required bool include,
    bool onlineAllowed = false,
  }) async {
    try {
      final sectionStarted = DateTime.now();
      // Build #23: the local index answers first (see _searchMovies —
      // global first regardless of [include]; the flag gates the cold
      // fallback only).
      final indexOut = await _searchLiveFromIndex(needle, limit, trace, sectionStarted);
      if (indexOut != null) return indexOut;
      if (!include) {
        trace.skipped = true;
        trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
        return const [];
      }
      // Build v1.0.11 (R2.0 + R2.3 — cold index, local data only):
      // same shape as movies — local rows only (live has no crawl
      // source); only a submit kicks off the coalesced sync.
      if (onlineAllowed) unawaited(ensureSearchIndexSynced(retryTransportErrors: true));
      trace.cold = true;
      // 1.2.18 C-5: seed-then-search — see _searchMovies.
      _kickColdSearchSeed(IptvSearchIndex.typeLive);
      final categoryNames = await _liveCategoryNamesFromDisk();
      // Hidden channels (build #17, §9) never match in Live TV search:
      // load the set once, then [_appendLiveMatches] skips them.
      await _liveTv.loadHiddenChannels();
      final diskRows = await _liveRowsForEnterSearch();
      final out = <MediaItem>[];
      trace.partialOut = out;
      _appendLiveMatches(diskRows.rows, needle, limit, categoryNames, out, <int>{}, trace);
      trace.loadRows = diskRows.rows.length;
      trace.loadSource = diskRows.source;
      trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
      trace.loadMatches = out.length;
      trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
      return out;
    } catch (e) {
      appLogger.w('IPTV: live search failed: $e');
      return const [];
    }
  }

  /// Same as [_appendMovieMatches], for live channel rows.
  void _appendLiveMatches(
    List<XtreamLiveStream> rows,
    String needle,
    int limit,
    Map<String, String> categoryNames,
    List<MediaItem> out,
    Set<int> seen,
    _SectionTrace trace,
  ) {
    // One case-insensitive pattern for the whole scan — see
    // [_appendMovieMatches].
    final match = RegExp(RegExp.escape(needle), caseSensitive: false);
    for (final stream in rows) {
      if (out.length >= limit) break;
      if (!seen.add(stream.streamId)) continue;
      if (!match.hasMatch(stream.name)) continue;
      if (_isHiddenCategory(stream.categoryId, categoryNames[stream.categoryId])) {
        trace.hiddenMatches++;
        final initial = categoryInitial(categoryNames[stream.categoryId]);
        if (initial != null) trace.hiddenInitials.add(initial);
        continue;
      }
      // A hidden channel (build #17, §9) never matches in Live TV search.
      if (_liveTv.isHiddenChannelKey('${stream.streamId}')) continue;
      out.add(_liveChannelItem(stream, categoryName: categoryNames[stream.categoryId]));
    }
  }

  /// A live channel as a searchable/playable item: same shape as the M3U
  /// search items, but with the Xtream /live/ URL, EPG id and catch-up
  /// flags. Keyed `live:<streamId>` so [fetchItem] can resolve it.
  MediaItem _liveChannelItem(XtreamLiveStream stream, {String? categoryName}) {
    return MediaItem.xtream(
      id: 'live:${stream.streamId}',
      kind: MediaKind.unknown,
      title: stripCategoryPrefix(stream.name, categoryName),
      thumbPath: stream.streamIcon,
      streamUrl: _xtreamApi.liveStreamUrl('${stream.streamId}'),
      epgChannelId: stream.epgChannelId,
      hasArchive: stream.tvArchive,
      archiveDuration: stream.tvArchiveDuration,
      categoryId: stream.categoryId,
      libraryId: _liveLibraryId,
      libraryTitle: '$_name — Live TV',
      serverId: connection.id,
      serverName: _name,
    );
  }

  Future<List<MediaItem>> _searchM3uEntries(
    String needle,
    int limit,
    Set<String> excludedLibraryIds,
    _SectionTrace trace,
  ) async {
    if (excludedLibraryIds.contains(_liveLibraryId)) return const [];
    try {
      final entries = await _m3uEntries();
      // Hidden channels (build #17, §9) never match in Live TV search.
      await _liveTv.loadHiddenChannels();
      final out = <MediaItem>[];
      // One case-insensitive pattern for the whole scan — see
      // [_appendMovieMatches].
      final match = RegExp(RegExp.escape(needle), caseSensitive: false);
      for (final entry in entries) {
        if (out.length >= limit) break;
        if (!match.hasMatch(entry.name)) continue;
        // A hidden group (its own switch, or its category initial) hides
        // its entries from search too. Item names are never filtered.
        // A match in a hidden group is counted on the trace (v1.1.0),
        // like the Xtream append builders, so the search screen can
        // name the hiding group instead of showing a bare "No results".
        if (_isHiddenGroup(entry.groupTitle)) {
          trace.hiddenMatches++;
          final initial = categoryInitial(entry.groupTitle);
          if (initial != null) trace.hiddenInitials.add(initial);
          continue;
        }
        if (_liveTv.isHiddenChannelKey(entry.tvgId ?? entry.url)) continue;
        out.add(
          MediaItem.m3u(
            id: 'm3u:${entry.tvgId ?? entry.name}',
            kind: MediaKind.unknown,
            title: entry.name,
            thumbPath: entry.tvgLogo,
            streamUrl: entry.url,
            epgChannelId: entry.tvgId,
            categoryId: entry.groupTitle,
            libraryId: _liveLibraryId,
            libraryTitle: '$_name — Live TV',
            serverId: connection.id,
            serverName: _name,
          ),
        );
      }
      return out;
    } catch (e) {
      appLogger.w('IPTV: M3U search failed: $e');
      return const [];
    }
  }

  @override
  Future<List<MediaPerson>> searchPeople(
    String query, {
    int limit = defaultPeopleSearchLimit,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) {
    throw UnsupportedError('IPTV: searchPeople not supported');
  }

  @override
  Future<List<MediaItem>> fetchContinueWatching({int? count = 20, Set<String> excludedLibraryIds = const {}}) async {
    // Build #25: local-only resume. Rows come from the per-connection
    // resume store; each id is re-resolved against the catalog (fresh
    // titles/posters), falling back to the stored snapshot when the item
    // left the catalog. No panel requests beyond the catalog the app
    // already holds in memory / on disk.
    if (!_isXtream) return const [];
    final saved = await _resumeItems();
    if (saved.isEmpty) return const [];
    final entries = saved.values.toList()..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    final favorites = await _favoriteItems();
    final out = <MediaItem>[];
    for (final entry in entries) {
      if (entry.libraryId != null && excludedLibraryIds.contains(entry.libraryId)) continue;
      MediaItem? item;
      try {
        // 1.6.11 X2: a card needs the base item only — one `get_vod_info`
        // per row, sequentially, used to hold the home screen for up to
        // 20 × the response budget on a flaky provider.
        item = await fetchItem(entry.id, skipVodInfo: true);
      } catch (e) {
        // A catalog failure for one resume row must not kill the list —
        // the snapshot below is the fallback.
        appLogger.w('IPTV: resume ${entry.id} could not re-resolve: $e');
      }
      item ??= _resumeSnapshotItem(entry, isFavorite: favorites.containsKey(entry.id));
      if (item == null) continue;
      out.add(item);
      if (count != null && out.length >= count) break;
    }
    return out;
  }

  /// A resume entry whose item left the catalog, rendered from its
  /// stored snapshot (favorites pattern). Unknown kinds render nothing.
  MediaItem? _resumeSnapshotItem(IptvResumeItem entry, {required bool isFavorite}) {
    final kind = switch (entry.kind) {
      'movie' => MediaKind.movie,
      'episode' => MediaKind.episode,
      _ => null,
    };
    if (kind == null) return null;
    return MediaItem.xtream(
      id: entry.id,
      kind: kind,
      title: entry.title,
      thumbPath: entry.thumbPath,
      libraryId: entry.libraryId,
      libraryTitle: entry.kind == 'movie' ? '$_name — Movies' : '$_name — Series',
      parentId: entry.parentId,
      parentTitle: entry.parentTitle,
      grandparentId: entry.grandparentId,
      grandparentTitle: entry.grandparentTitle,
      // 1.6.11 X9: the show poster survives in the snapshot, so the
      // episode-still fallback still has something to fall back to.
      grandparentThumbPath: entry.grandparentThumbPath,
      durationMs: entry.durationMs,
      viewOffsetMs: entry.positionMs,
      lastViewedAt: entry.updatedAtMs,
      serverId: connection.id,
      serverName: _name,
      isFavorite: isFavorite,
    );
  }

  @override
  Future<List<MediaHub>> fetchGlobalHubs({
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    HubFetchDiagnostics? diagnostics,
  }) async {
    // Home shows one Recommended-style hub per on-demand library, titled
    // with the library name so two IPTV sources stay distinguishable.
    // M3U has no on-demand catalog, so it contributes nothing.
    if (!_isXtream) return const [];
    final hubs = <MediaHub>[];
    // Map only the first `limit` rows (build #13): the old code built
    // all 199k items to take 20 of them. 1.2.11: the rows + the total
    // come from the index (no memo load); the memo path is the cold
    // fallback only.
    final moviePage = await _indexBrowsePage(IptvSearchIndex.typeMovie, limit: limit);
    if (moviePage != null) {
      if (moviePage.rows.isNotEmpty) {
        final movies = await _vodPageItems(
          moviePage.rows.map((r) => r.toVodStream()).toList(growable: false),
          0,
          moviePage.rows.length,
        );
        hubs.add(
          _recommendedHub(
            libraryId: _moviesLibraryId,
            title: '$_name — Movies',
            type: 'movie',
            all: movies,
            limit: limit,
            totalCount: moviePage.total,
          ),
        );
      }
    } else {
      final movieRows = await _filteredVodRows();
      if (movieRows.isNotEmpty) {
        final movies = await _vodPageItems(movieRows, 0, limit);
        hubs.add(
          _recommendedHub(
            libraryId: _moviesLibraryId,
            title: '$_name — Movies',
            type: 'movie',
            all: movies,
            limit: limit,
            totalCount: movieRows.length,
          ),
        );
      }
    }
    // Fail open per section: a series catalog failure (network, malformed
    // rows) must not take the Movies hub down with it — the per-library
    // fetch path already isolates the two, so the home path must too.
    try {
      final seriesPage = await _indexBrowsePage(IptvSearchIndex.typeSeries, limit: limit);
      if (seriesPage != null) {
        if (seriesPage.rows.isNotEmpty) {
          final series = await _seriesPageItems(
            seriesPage.rows.map((r) => r.toSeries()).toList(growable: false),
            0,
            seriesPage.rows.length,
          );
          hubs.add(
            _recommendedHub(
              libraryId: _seriesLibraryId,
              title: '$_name — Series',
              type: 'show',
              all: series,
              limit: limit,
              totalCount: seriesPage.total,
            ),
          );
        }
      } else {
        final seriesRows = await _filteredSeriesRows();
        if (seriesRows.isNotEmpty) {
          final series = await _seriesPageItems(seriesRows, 0, limit);
          hubs.add(
            _recommendedHub(
              libraryId: _seriesLibraryId,
              title: '$_name — Series',
              type: 'show',
              all: series,
              limit: limit,
              totalCount: seriesRows.length,
            ),
          );
        }
      }
    } catch (e) {
      appLogger.w('IPTV: series hub skipped after catalog failure: $e');
    }
    return hubs;
  }

  @override
  Future<List<MediaHub>> fetchLibraryHubs(
    String libraryId, {
    required String libraryName,
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    MediaKind? libraryKind,
    HubFetchDiagnostics? diagnostics,
  }) async {
    // The Recommended tab renders whatever hubs come back; throwing here
    // surfaced as "Unable to load Recommended", so always return the one
    // hub the library actually has (or nothing when it has none).
    if (!_isXtream) return const [];
    if (libraryId == _moviesLibraryId) {
      // 1.2.11: the hub preview + total come from the index (no memo
      // load); the memo path is the cold fallback only.
      final page = await _indexBrowsePage(IptvSearchIndex.typeMovie, limit: limit);
      if (page != null) {
        if (page.rows.isEmpty) return const [];
        final movies = await _vodPageItems(
          page.rows.map((r) => r.toVodStream()).toList(growable: false),
          0,
          page.rows.length,
        );
        return [
          _recommendedHub(
            libraryId: libraryId,
            title: 'Recommended',
            type: 'movie',
            all: movies,
            limit: limit,
            totalCount: page.total,
          ),
        ];
      }
      final rows = await _filteredVodRows();
      if (rows.isEmpty) return const [];
      final movies = await _vodPageItems(rows, 0, limit);
      return [
        _recommendedHub(
          libraryId: libraryId,
          title: 'Recommended',
          type: 'movie',
          all: movies,
          limit: limit,
          totalCount: rows.length,
        ),
      ];
    }
    if (libraryId == _seriesLibraryId) {
      final page = await _indexBrowsePage(IptvSearchIndex.typeSeries, limit: limit);
      if (page != null) {
        if (page.rows.isEmpty) return const [];
        final series = await _seriesPageItems(
          page.rows.map((r) => r.toSeries()).toList(growable: false),
          0,
          page.rows.length,
        );
        return [
          _recommendedHub(
            libraryId: libraryId,
            title: 'Recommended',
            type: 'show',
            all: series,
            limit: limit,
            totalCount: page.total,
          ),
        ];
      }
      final rows = await _filteredSeriesRows();
      if (rows.isEmpty) return const [];
      final series = await _seriesPageItems(rows, 0, limit);
      return [
        _recommendedHub(
          libraryId: libraryId,
          title: 'Recommended',
          type: 'show',
          all: series,
          limit: limit,
          totalCount: rows.length,
        ),
      ];
    }
    return const [];
  }

  @override
  Future<List<MediaHub>> fetchRelatedHubs(String id, {int count = 10}) {
    throw UnsupportedError('IPTV: fetchRelatedHubs not supported');
  }

  @override
  Future<List<MediaItem>> fetchExtras(String id) {
    throw UnsupportedError('IPTV: fetchExtras not supported');
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPersonMediaPage(
    String personId, {
    int? start,
    int? size,
    AbortController? abort,
  }) {
    throw UnsupportedError('IPTV: fetchPersonMediaPage not supported');
  }

  @override
  Future<MediaPersonDetails> fetchPersonDetails(String personId, {AbortController? abort}) {
    throw UnsupportedError('IPTV: fetchPersonDetails not supported');
  }

  @override
  Future<List<MediaItem>> fetchMoreHubItems(String hubId, {int? limit}) async {
    // 1.6.11 P4: delegates to the paged path — the old shape built the
    // whole catalog (up to ~199k items) and sliced it. A null limit is
    // one page. The hub screen already uses the paged path for IPTV, so
    // this only ever served the replace-continuation branch, which is
    // never taken for IPTV backends.
    if (!_isXtream) return const [];
    final page = await fetchMoreHubItemsPage(hubId, size: limit ?? defaultListPageSize);
    return page.items;
  }

  @override
  Future<LibraryPage<MediaItem>> fetchMoreHubItemsPage(
    String hubId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    // Row-level paging (build #13): the page comes from the index (no
    // memo load); the memo path is the cold fallback only. 1.6.11 P4:
    // a null [size] is one page now, not "everything from offset" —
    // the old default materialized the whole catalog behind the gate.
    if (!_isXtream) return const LibraryPage(items: [], totalCount: 0);
    size ??= defaultListPageSize;
    final offset = start ?? 0;
    if (hubId.contains(_moviesLibraryId)) {
      // 1.6.34 (P-01): a category hub (`iptv:<library id>:category:<id>`,
      // built by the categories tab) pages only that category — the
      // whole-library hub has no segment and keeps the old shape.
      final categoryId = _categoryIdFromHubId(hubId);
      final page = await _indexBrowsePage(
        IptvSearchIndex.typeMovie,
        categoryId: categoryId,
        offset: offset,
        limit: size,
      );
      if (page != null) {
        final items = await _vodPageItems(
          page.rows.map((r) => r.toVodStream()).toList(growable: false),
          0,
          page.rows.length,
        );
        return LibraryPage(items: items, totalCount: page.total, offset: offset.clamp(0, page.total));
      }
      final rows = await _filteredVodRows();
      final categoryRows =
          categoryId == null ? rows : rows.where((s) => s.categoryId == categoryId).toList();
      final items = await _vodPageItems(categoryRows, offset, size);
      return LibraryPage(items: items, totalCount: categoryRows.length, offset: offset.clamp(0, categoryRows.length));
    }
    if (hubId.contains(_seriesLibraryId)) {
      final categoryId = _categoryIdFromHubId(hubId);
      final page = await _indexBrowsePage(
        IptvSearchIndex.typeSeries,
        categoryId: categoryId,
        offset: offset,
        limit: size,
      );
      if (page != null) {
        final items = await _seriesPageItems(
          page.rows.map((r) => r.toSeries()).toList(growable: false),
          0,
          page.rows.length,
        );
        return LibraryPage(items: items, totalCount: page.total, offset: offset.clamp(0, page.total));
      }
      final rows = await _filteredSeriesRows();
      final categoryRows =
          categoryId == null ? rows : rows.where((s) => s.categoryId == categoryId).toList();
      final items = await _seriesPageItems(categoryRows, offset, size);
      return LibraryPage(items: items, totalCount: categoryRows.length, offset: offset.clamp(0, categoryRows.length));
    }
    return const LibraryPage(items: [], totalCount: 0);
  }

  /// The category id encoded in a category hub id
  /// (`iptv:<library id>:category:<category id>`, built by the
  /// categories tab), or null for whole-library hubs (1.6.34, P-01).
  /// A trailing empty segment reads as no category, never as an
  /// empty-string category id.
  static String? _categoryIdFromHubId(String hubId) {
    const marker = ':category:';
    final at = hubId.indexOf(marker);
    if (at < 0) return null;
    final id = hubId.substring(at + marker.length);
    return id.isEmpty ? null : id;
  }

  // Watch state is local-only for IPTV (no server API). markWatched
  // clears the local resume entry so the item leaves Continue Watching
  // (the base-class postcondition — the detail screen's "mark watched"
  // action reaches here through WatchActions, and a no-op would leave
  // the item in the row while claiming it was marked); rate stays a
  // no-op; setFavorite persists (Task 1) so the heart sticks.
  @override
  Future<void> markWatched(MediaItem item) async {
    await _removeResumeEntry(item.id);
  }

  @override
  Future<void> markUnwatched(MediaItem item) async {}

  @override
  Future<void> removeFromContinueWatching(MediaItem item) async {
    await _removeResumeEntry(item.id);
  }

  @override
  Future<void> rate(MediaItem item, double rating) async {}

  /// Deletes the stored resume position for [id], if any. Shared by
  /// [markWatched] and [removeFromContinueWatching]: both mean "this
  /// item is no longer resumable".
  Future<void> _removeResumeEntry(String id) async {
    final current = Map<String, IptvResumeItem>.of(await _resumeItems());
    if (current.remove(id) == null) return;
    await _resumeRepository.write(_resumeKey, current);
    _resumeItemsFuture = Future.value(current);
  }

  @override
  Future<void> setFavorite(MediaItem item, bool isFavorite) async {
    // Only M3U/Xtream movies, shows and episodes can be favourited.
    // Anything else (a live channel, a track, an item from another
    // backend) is a no-op so the heart never crashes.
    final kind = switch (item) {
      M3uMediaItem(:final kind) || XtreamMediaItem(:final kind) => kind,
      _ => null,
    };
    if (kind != MediaKind.movie && kind != MediaKind.show && kind != MediaKind.episode) return;
    final current = Map<String, IptvFavoriteItem>.of(await _favoriteItems());
    if (isFavorite) {
      // 1.2.4: the category id is the precise signal for whether a
      // pruned favourite needs a refresh (see IptvFavoriteItem). It
      // lives on the IPTV variants, not the sealed base.
      final categoryId = switch (item) {
        M3uMediaItem(:final categoryId) || XtreamMediaItem(:final categoryId) => categoryId,
        _ => null,
      };
      current[item.id] = IptvFavoriteItem(
        id: item.id,
        kind: switch (kind) {
          MediaKind.movie => 'movie',
          MediaKind.show => 'show',
          MediaKind.episode => 'episode',
          _ => 'movie',
        },
        title: item.title,
        thumbPath: item.thumbPath,
        libraryId: item.libraryId,
        parentId: item.parentId,
        parentTitle: item.parentTitle,
        // 1.4.6 G1: the show link for episodes — parentTitle is the
        // season now, so the snapshot keeps the show separately.
        grandparentId: item.grandparentId,
        grandparentTitle: item.grandparentTitle,
        categoryId: categoryId,
      );
    } else {
      current.remove(item.id);
    }
    await _itemFavoritesRepository.write(_itemFavoritesKey, current);
    // Swap the cached read for the new map so browse/search/detail stamp
    // the new state without re-reading prefs.
    _favoriteItemsFuture = Future.value(current);
  }

  /// Favourited movies/series/episodes as [MediaItem]s, newest first.
  /// Each id is re-resolved against the catalog (fresh titles/posters);
  /// an item that left the catalog renders from its stored snapshot.
  Future<List<MediaItem>> favoriteItems() async {
    final saved = await _favoriteItems();
    if (saved.isEmpty) return const [];
    final out = <MediaItem>[];
    for (final snapshot in saved.values.toList().reversed) {
      final resolved = await _resolveFavoriteItem(snapshot);
      if (resolved != null) out.add(resolved);
    }
    return out;
  }

  Future<MediaItem?> _resolveFavoriteItem(IptvFavoriteItem snapshot) async {
    MediaItem? item;
    try {
      // 1.6.11 X2: same as Continue Watching — a favourite card needs
      // the base item only, not a `get_vod_info` per row.
      item = await fetchItem(snapshot.id, skipVodInfo: true);
    } catch (e) {
      // A catalog failure for one favourite must not kill the list —
      // the snapshot below is the fallback.
      appLogger.w('IPTV: favourite ${snapshot.id} could not re-resolve: $e');
    }
    if (item != null) return item;
    final kind = switch (snapshot.kind) {
      'movie' => MediaKind.movie,
      'show' => MediaKind.show,
      'episode' => MediaKind.episode,
      _ => null,
    };
    if (kind == null) return null;
    return MediaItem.xtream(
      id: snapshot.id,
      kind: kind,
      title: snapshot.title,
      thumbPath: snapshot.thumbPath,
      libraryId: snapshot.libraryId,
      parentId: snapshot.parentId,
      parentTitle: snapshot.parentTitle,
      grandparentId: snapshot.grandparentId,
      grandparentTitle: snapshot.grandparentTitle,
      isFavorite: true,
    );
  }

  @override
  Future<LibraryPage<MediaPlaylist>> fetchPlaylistsPage({
    String playlistType = 'video',
    bool? smart,
    int? start,
    int? size,
    AbortController? abort,
  }) {
    throw UnsupportedError('IPTV: fetchPlaylistsPage not supported');
  }

  @override
  Future<MediaPlaylist?> fetchPlaylistMetadata(String id) {
    throw UnsupportedError('IPTV: fetchPlaylistMetadata not supported');
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPlaylistPage(String id, {int? start, int? size, AbortController? abort}) {
    throw UnsupportedError('IPTV: fetchPlaylistPage not supported');
  }

  @override
  Future<MediaPlaylist?> createPlaylist({required String title, required List<MediaItem> items}) {
    throw UnsupportedError('IPTV: createPlaylist not supported');
  }

  @override
  Future<bool> addToPlaylist({required String playlistId, required List<MediaItem> items}) {
    throw UnsupportedError('IPTV: addToPlaylist not supported');
  }

  @override
  Future<bool> deletePlaylist(MediaPlaylist playlist) {
    throw UnsupportedError('IPTV: deletePlaylist not supported');
  }

  @override
  Future<bool> movePlaylistItem({
    required String playlistId,
    required MediaItem item,
    required int newIndex,
    required MediaItem? afterItem,
  }) {
    throw UnsupportedError('IPTV: movePlaylistItem not supported');
  }

  @override
  Future<bool> removeFromPlaylist({required String playlistId, required MediaItem item}) {
    throw UnsupportedError('IPTV: removeFromPlaylist not supported');
  }

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionsPage(
    String libraryId, {
    int? start,
    int? size,
    AbortController? abort,
  }) {
    throw UnsupportedError('IPTV: fetchCollectionsPage not supported');
  }

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionPage(
    String collectionId, {
    int? start,
    int? size,
    AbortController? abort,
    String? libraryId,
    String? libraryTitle,
  }) {
    throw UnsupportedError('IPTV: fetchCollectionPage not supported');
  }

  @override
  Future<List<CollectionMembership>> fetchCollectionMemberships(Set<String> itemIds, {AbortController? abort}) {
    throw UnsupportedError('IPTV: fetchCollectionMemberships not supported');
  }

  @override
  Future<String?> createCollection({
    required String libraryId,
    required String title,
    required List<MediaItem> items,
    MediaKind? itemKind,
  }) {
    throw UnsupportedError('IPTV: createCollection not supported');
  }

  @override
  Future<bool> addToCollection({required String collectionId, required List<MediaItem> items}) {
    throw UnsupportedError('IPTV: addToCollection not supported');
  }

  @override
  Future<bool> removeFromCollection({required String collectionId, required MediaItem item}) {
    throw UnsupportedError('IPTV: removeFromCollection not supported');
  }

  @override
  Future<bool> deleteCollection(MediaItem collection) {
    throw UnsupportedError('IPTV: deleteCollection not supported');
  }

  @override
  Future<bool> deleteMediaItem(MediaItem item) {
    throw UnsupportedError('IPTV: deleteMediaItem not supported');
  }

  @override
  Future<MediaFileInfo?> getFileInfo(MediaItem item) {
    throw UnsupportedError('IPTV: getFileInfo not supported');
  }

  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) => path ?? '';

  @override
  String externalImageUrl(String url, {int? width, int? height, bool cover = true}) => url;

  @override
  Future<ExternalIds> fetchExternalIds(String itemId) async {
    // 1.6.10 M2: movies carry their external id in `get_vod_info`
    // (memoized with the detail page — zero new calls on a revisit).
    // The ratings loader + MDBList client were already built and never
    // given an id; now they light up with no new UI. Series and
    // episodes have no provider id — their ratings wait for the M3
    // TMDB match.
    if (itemId.startsWith('movie:')) {
      final vodId = int.tryParse(itemId.substring('movie:'.length));
      if (vodId == null) return const ExternalIds();
      try {
        final info = await _vodInfo(vodId);
        return ExternalIds(tmdb: info.tmdbId, imdb: info.imdbId);
      } catch (_) {
        return const ExternalIds();
      }
    }
    return const ExternalIds();
  }

  @override
  Future<List<MediaItem>?> findByExternalIds(
    ExternalIds ids, {
    required MediaKind kind,
    List<String> titles = const [],
    int? year,
    String? plexGuid,
    ExternalSeasonRef? season,
  }) async => null;

  @override
  Future<PlaybackExtras> fetchPlaybackExtras(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
    bool forceRefresh = false,
  }) async => PlaybackExtras(chapters: const [], markers: const []);

  @override
  Future<PlaybackExtras?> fetchPlaybackExtrasFromCacheOnly(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
  }) async => null;

  @override
  Future<MediaSourceInfo?> fetchCachedMediaSourceInfo(
    String itemId, {
    int mediaIndex = 0,
    String? mediaSourceId,
    String? preferredVersionSignature,
  }) async => null;

  @override
  Future<ScrubPreviewSource?> createScrubPreviewSource({required MediaItem item, required MediaSourceInfo mediaSource}) {
    throw UnsupportedError('IPTV: createScrubPreviewSource not supported');
  }

  @override
  Future<void> reportPlaybackStarted({
    required String itemId,
    required Duration position,
    Duration? duration,
    String? playSessionId,
    String? playMethod,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {
    await _recordResumePosition(itemId: itemId, position: position, duration: duration, isStop: false);
  }

  @override
  Future<void> reportPlaybackProgress({
    required String itemId,
    required Duration position,
    required Duration duration,
    bool isPaused = false,
    String? playSessionId,
    String? playMethod,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {
    await _recordResumePosition(itemId: itemId, position: position, duration: duration, isStop: false);
  }

  @override
  Future<void> reportPlaybackStopped({
    required String itemId,
    required Duration position,
    Duration? duration,
    String? playSessionId,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    PlaybackReportMetadata report = const PlaybackReportMetadata.live(),
  }) async {
    await _recordResumePosition(itemId: itemId, position: position, duration: duration, isStop: true);
  }

  /// Build #25: the single record path for the three report methods.
  /// Local writes only — never a panel request, never throws (trap T7:
  /// a prefs failure drops the write silently instead of queuing a
  /// position for a server that doesn't exist).
  ///
  /// Rules, in order: (1) only `movie:` / `episode:` ids (live never
  /// enters the store, trap T5); (2) position below the 5 s floor
  /// records nothing (anti-clutter, trap T2); (3) no usable duration
  /// records nothing (a row without duration can never render
  /// `hasActiveProgress`, trap T1); (4) a stop at/above
  /// [watchedThreshold] (0.9) deletes the entry instead of writing it
  /// (trap T3/T4 — the stop report IS the watched-mark); (5) otherwise
  /// upsert with the reported duration and now as `lastViewedAt`.
  Future<void> _recordResumePosition({
    required String itemId,
    required Duration position,
    required Duration? duration,
    required bool isStop,
  }) async {
    try {
      final kind = itemId.startsWith('movie:')
          ? 'movie'
          : itemId.startsWith('episode:')
              ? 'episode'
              : null;
      if (kind == null) return;
      if (position.inMilliseconds < _resumeRecordFloorMs) return;
      final durationMs = duration?.inMilliseconds ?? 0;
      if (durationMs <= 0) return;
      final current = Map<String, IptvResumeItem>.of(await _resumeItems());
      if (isStop &&
          isWatchedProgress(
            positionMs: position.inMilliseconds,
            durationMs: durationMs,
            threshold: watchedThreshold,
          )) {
        if (current.remove(itemId) != null) {
          await _resumeRepository.write(_resumeKey, current);
          _resumeItemsFuture = Future.value(current);
        }
        return;
      }
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final updatedAtMs = nowMs > _lastResumeTimestampMs ? nowMs : _lastResumeTimestampMs + 1;
      _lastResumeTimestampMs = updatedAtMs;
      final stash = _resumeSnapshots[itemId];
      final parts = itemId.split(':');
      current[itemId] = IptvResumeItem(
        id: itemId,
        kind: kind,
        title: stash?.title,
        thumbPath: stash?.thumbPath,
        libraryId: stash?.libraryId ?? (kind == 'movie' ? _moviesLibraryId : _seriesLibraryId),
        parentId: stash?.parentId ?? (kind == 'episode' && parts.length >= 2 ? 'series:${parts[1]}' : null),
        parentTitle: stash?.parentTitle,
        // 1.4.6 G1: the show link for episodes. The id fallback mirrors
        // parentId above (an episode's grandparent IS its series).
        // 1.5.3 K1: the bare series id, matching _episodeItem and the
        // 1.4.4 F5 queue lookup — the old 'series:' prefix here never
        // matched either. The season is unknowable from the id alone,
        // so the parentId fallback stays show-level; the stash path
        // carries the correct season parentId.
        grandparentId: stash?.grandparentId ?? (kind == 'episode' && parts.length >= 2 ? parts[1] : null),
        grandparentTitle: stash?.grandparentTitle,
        // 1.6.11 X9: the show poster, for the still fallback.
        grandparentThumbPath: stash?.grandparentThumbPath,
        // 1.2.4: the category id is the precise signal for whether a
        // pruned resume entry needs a refresh (see IptvResumeItem).
        categoryId: stash?.categoryId,
        positionMs: position.inMilliseconds,
        durationMs: durationMs,
        updatedAtMs: updatedAtMs,
      );
      if (current.length > _maxResumeEntries) {
        final sorted = current.values.toList()..sort((a, b) => a.updatedAtMs.compareTo(b.updatedAtMs));
        for (final oldest in sorted.take(current.length - _maxResumeEntries)) {
          current.remove(oldest.id);
        }
      }
      await _resumeRepository.write(_resumeKey, current);
      _resumeItemsFuture = Future.value(current);
    } catch (e) {
      // A prefs failure drops the write silently — playback must never
      // crash or queue on a local store failure. Logged (1.6.30 G-C8)
      // so a lost resume position leaves a trace in the debug export.
      appLogger.d('IPTV resume write failed', error: e);
    }
  }

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options) async {
    final item = options.metadata;
    final streamUrl = switch (item) {
      M3uMediaItem(:final streamUrl) || XtreamMediaItem(:final streamUrl) => streamUrl,
      _ => null,
    };
    if (streamUrl == null || streamUrl.isEmpty) {
      throw PlaybackException('No playable IPTV stream for this item', reason: PlaybackFailureReason.noPlayableSource);
    }
    // Build #25: stash the playing item's display snapshot so the
    // report methods (which only receive an id) can store a titled row.
    // Movies and episodes only — live items never enter the resume
    // store. Bounded and in-memory; a restart loses nothing the catalog
    // re-resolution cannot refill.
    if (item is XtreamMediaItem && (item.kind == MediaKind.movie || item.kind == MediaKind.episode)) {
      _resumeSnapshots[item.id] = (
        title: item.title,
        thumbPath: item.thumbPath,
        libraryId: item.libraryId,
        parentId: item.parentId,
        parentTitle: item.parentTitle,
        // 1.4.6 G1: the show link for episodes (see IptvResumeItem).
        grandparentId: item.grandparentId,
        grandparentTitle: item.grandparentTitle,
        // 1.6.11 X9: the show poster rides with the snapshot.
        grandparentThumbPath: item.grandparentThumbPath,
        // 1.2.4: the series category for an episode, the movie category
        // for a movie (see _episodeItem / _movieItem).
        categoryId: item.categoryId,
      );
      if (_resumeSnapshots.length > 50) {
        _resumeSnapshots.remove(_resumeSnapshots.keys.first);
      }
    }
    final mediaInfo = MediaSourceInfo(
      videoUrl: streamUrl,
      audioTracks: const [],
      subtitleTracks: const [],
      chapters: const [],
    );
    return PlaybackInitializationResult(
      availableVersions: [MediaVersion(id: item.id)],
      videoUrl: streamUrl,
      mediaInfo: mediaInfo,
      isTranscoding: false,
      selectedMediaIndex: 0,
    );
  }

  @override
  Future<DownloadResolution> resolveDownload(MediaItem item, {int mediaIndex = 0, String? mediaSourceId}) async {
    // The direct stream URL IS the file (the same URL playback uses), so
    // a download is just a fetch of it. A show has no file, and a .m3u8
    // URL is a playlist, not a file — both resolve to null and let the
    // pipeline's existing retry-then-fail path handle them instead of
    // throwing (the old UnsupportedError is what broke movie downloads).
    final streamUrl = switch (item) {
      M3uMediaItem(:final streamUrl) || XtreamMediaItem(:final streamUrl) => streamUrl,
      _ => null,
    };
    if (streamUrl == null || streamUrl.isEmpty) return const DownloadResolution(videoUrl: null);
    final uri = Uri.tryParse(streamUrl);
    if (uri != null && uri.path.toLowerCase().endsWith('.m3u8')) {
      return const DownloadResolution(videoUrl: null);
    }
    return DownloadResolution(videoUrl: streamUrl);
  }

  @override
  Future<MediaItem> stampLibrary(MediaItem item) async => item;

  @override
  List<DownloadArtworkSpec> resolveDownloadArtwork(MediaItem item) {
    final thumb = item.thumbPath;
    if (thumb == null || thumb.isEmpty) return const [];
    final uri = Uri.tryParse(thumb);
    if (uri == null || !uri.hasScheme) return const [];
    // The absolute URL is the key (Jellyfin does the same) — provider
    // artwork URLs are unique per item, so a downloaded movie keeps its
    // poster offline.
    return [DownloadArtworkSpec(localKey: thumb, url: thumb)];
  }

  @override
  Future<ExternalPlaybackTarget?> resolveExternalPlayback(
    MediaItem item, {
    int mediaIndex = 0,
    String? mediaSourceId,
    Duration? position,
  }) async {
    final streamUrl = switch (item) {
      M3uMediaItem(:final streamUrl) || XtreamMediaItem(:final streamUrl) => streamUrl,
      _ => null,
    };
    if (streamUrl == null || streamUrl.isEmpty) return null;
    return ExternalPlaybackTarget(url: streamUrl);
  }

  // -- Live TV helpers (used by IptvLiveTvSupport) --------------------------

  /// Live channels as [LiveTvChannel]s, with stream info cached by key for
  /// [startPlayback]. The provider returns the whole list in one call;
  /// callers page it — this method itself does not slice.
  Future<List<LiveTvChannel>> iptvChannels() async {
    if (_isXtream) {
      // 1.2.11: the guide reads the live rows from the index in pages
      // (no memo load — the channel list is transient to the call), so
      // a Reload-fresh memo still wins while its re-seed is in flight
      // ([_liveMemoFresherThanIndex]) and the memo path below is the
      // cold fallback only. The fingerprint check needs to know whether
      // the index's rows may have changed since the last check — the
      // index's live stamp + row count say so, so a repeated call over
      // an unchanged index skips the 26k-row hash (the memo path's
      // `wasFresh` did the same for memo hits).
      if (await _liveMemoFresherThanIndex()) {
        final streams = await _liveStreams();
        final liveCategoryNames = await _liveCategoryNames();
        final channels = <LiveTvChannel>[];
        for (final stream in streams) {
          if (_isHiddenCategory(stream.categoryId, liveCategoryNames[stream.categoryId])) continue;
          _xtreamChannelByKey['${stream.streamId}'] = stream;
          channels.add(_liveTvChannelForStream(stream));
        }
        return channels;
      }
      final index = await _warmIndexForType(IptvSearchIndex.typeLive);
      if (index != null) {
        _refreshCatalogViaSyncIfDue(IptvSearchIndex.typeLive);
        final lastSync = index.lastSync(connection.id)[IptvSearchIndex.typeLive];
        final rowCount = index.rowCounts(connection.id)[IptvSearchIndex.typeLive] ?? 0;
        final indexStateChanged =
            _lastGuideIndexLastSync != lastSync || _lastGuideIndexRowCount != rowCount;
        // 1.2.18 C-1: an unchanged index serves the cached list — the
        // paging + 26k-row materialization below runs only when the
        // index actually changed. (An unchanged index also means no
        // fingerprint work is due: `indexStateChanged` is false.)
        if (_cachedGuideChannels != null &&
            _cachedGuideIndexLastSync == lastSync &&
            _cachedGuideIndexRowCount == rowCount) {
          return _cachedGuideChannels!;
        }
        // 1.6.32, option 4: the fingerprint is only due when the INDEX
        // changed and the hidden filter did not change with it — a
        // hide-only change is a visibility change, not a playlist
        // change, so it must not trigger the fingerprint hash or the
        // EPG refresh decision. When both changed together, the
        // fingerprint is skipped this load (the check resumes on the
        // next index change). No snapshot yet means no hidden change:
        // the first load must compute the fingerprint, or the baseline
        // is never stored.
        final hiddenChangedSinceLastGuideLoad =
            _lastGuideHiddenIds != null &&
            (!setEquals(_lastGuideHiddenIds!, _hiddenCategories) ||
                !setEquals(_lastGuideHiddenInitials ?? const {}, _hiddenCategoryInitials));
        final computeFingerprint = indexStateChanged && !hiddenChangedSinceLastGuideLoad;
        // 1.6.32, option 1: the read + materialize + fingerprint run
        // in a worker isolate — the UI thread never blocks on the
        // 26k-row rebuild that froze the TV on a category toggle (and
        // on Reload TV details). On any isolate failure (closed index,
        // busy lock) fall back to the synchronous path below (the old
        // behaviour, slow but correct).
        try {
          final materialized = await index.materializeLiveGuideAsync(
            connection.id,
            hiddenIds: _hiddenCategories,
            hiddenInitials: _hiddenCategoryInitials,
            serverId: connection.id,
            serverName: _name,
            computeFingerprint: computeFingerprint,
          );
          for (final stream in materialized.streams) {
            _xtreamChannelByKey['${stream.streamId}'] = stream;
          }
          if (indexStateChanged) {
            _lastGuideIndexLastSync = lastSync;
            _lastGuideIndexRowCount = rowCount;
            _lastGuideHiddenIds = _hiddenCategories;
            _lastGuideHiddenInitials = _hiddenCategoryInitials;
            if (materialized.fingerprint != null) {
              await _maybeRefreshEpgForPlaylistChange(materialized.fingerprint!);
            }
          }
          // 1.2.18 C-1: cache the list + key→index map for the next
          // fetch over this same index generation.
          _cachedGuideChannels = materialized.channels;
          _cachedGuideChannelIndex = {
            for (var i = 0; i < materialized.channels.length; i++) materialized.channels[i].key: i,
          };
          _cachedGuideIndexLastSync = lastSync;
          _cachedGuideIndexRowCount = rowCount;
          return materialized.channels;
        } catch (e) {
          appLogger.w('IPTV: guide isolate materialization failed, falling back to the synchronous path', error: e);
        }
        // Synchronous fallback (the pre-1.6.32 path): read + materialize
        // on the UI thread. Only reached when the isolate fails.
        final liveCategoryNames = await _liveCategoryNames();
        final rows = await _indexAllRows(IptvSearchIndex.typeLive);
        // The index could have gone cold between the warm check and the
        // read (close/teardown): fall through to the memo path then.
        if (rows != null) {
          final channels = <LiveTvChannel>[];
          for (final stream in rows.map((r) => r.toLiveStream())) {
            if (_isHiddenCategory(stream.categoryId, liveCategoryNames[stream.categoryId])) continue;
            _xtreamChannelByKey['${stream.streamId}'] = stream;
            channels.add(_liveTvChannelForStream(stream));
          }
          if (indexStateChanged) {
            _lastGuideIndexLastSync = lastSync;
            _lastGuideIndexRowCount = rowCount;
            _lastGuideHiddenIds = _hiddenCategories;
            _lastGuideHiddenInitials = _hiddenCategoryInitials;
            if (computeFingerprint) {
              await _maybeRefreshEpgForPlaylistChange(
                iptvPlaylistFingerprint(rows.map((r) => iptvPlaylistRowHash([r.streamId, r.name, r.epgChannelId]))),
              );
            }
          }
          // 1.2.18 C-1: cache the list + key→index map for the next
          // fetch over this same index generation.
          _cachedGuideChannels = channels;
          _cachedGuideChannelIndex = {
            for (var i = 0; i < channels.length; i++) channels[i].key: i,
          };
          _cachedGuideIndexLastSync = lastSync;
          _cachedGuideIndexRowCount = rowCount;
          return channels;
        }
      }
      // The fingerprint check needs to know whether this load was fresh
      // (a memo miss) — a memo hit is not a new playlist.
      final wasFresh = _liveStreamsFuture == null;
      final streams = await _liveStreams();
      final liveCategoryNames = await _liveCategoryNames();
      final channels = <LiveTvChannel>[];
      for (final stream in streams) {
        if (_isHiddenCategory(stream.categoryId, liveCategoryNames[stream.categoryId])) continue;
        _xtreamChannelByKey['${stream.streamId}'] = stream;
        channels.add(_liveTvChannelForStream(stream));
      }
      if (wasFresh) {
        await _maybeRefreshEpgForPlaylistChange(
          iptvPlaylistFingerprint(streams.map((s) => iptvPlaylistRowHash([s.streamId, s.name, s.epgChannelId]))),
        );
      }
      return channels;
    }
    final wasFresh = _m3uEntriesFuture == null;
    final entries = await _m3uEntries();
    final channels = <LiveTvChannel>[];
    for (final entry in entries) {
      // M3U categories are group titles; a hidden group hides its
      // channels from Live TV (same as Xtream's category filter above).
      if (_isHiddenGroup(entry.groupTitle)) continue;
      final key = entry.tvgId ?? entry.url;
      _m3uChannelByKey[key] = entry;
      channels.add(_liveTvChannelForM3uEntry(entry, key));
    }
    if (wasFresh) {
      await _maybeRefreshEpgForPlaylistChange(
        iptvPlaylistFingerprint(entries.map((e) => iptvPlaylistRowHash([e.tvgId, e.url, e.name]))),
      );
    }
    return channels;
  }

  /// The guide-order channel list with a key→index map (1.2.18 C-1):
  /// the guide's per-row fetch no longer rebuilds the 26k-row list and
  /// scans it with `indexWhere` — the cached list + map answer O(1).
  /// The map is only valid for the cached list; any other path (memo
  /// or cold fallback) builds it fresh from the returned list.
  Future<({List<LiveTvChannel> channels, Map<String, int> indexByKey})>
      guideChannelsWithIndex() async {
    final channels = await iptvChannels();
    var indexByKey = _cachedGuideChannelIndex;
    if (indexByKey == null || !identical(channels, _cachedGuideChannels)) {
      indexByKey = {
        for (var i = 0; i < channels.length; i++) channels[i].key: i,
      };
    }
    return (channels: channels, indexByKey: indexByKey);
  }

  /// Update-on-playlist-change (§3.3, PlezTV 1.2.0): after a FRESH live
  /// list load, compare the channel-list fingerprint against the stored
  /// one. A stored fingerprint that differs means the provider changed
  /// the playlist (added/removed/reordered channels) — refresh the EPG
  /// so the new channels get guide data. The first load stores the
  /// fingerprint without refreshing. The fingerprint is over the RAW
  /// rows, before the hidden-category filter — hiding a group never
  /// triggers a refresh. Skipped entirely when Settings isn't ready
  /// (background warm-ups) or the setting is off; the new fingerprint
  /// is always stored.
  Future<void> _maybeRefreshEpgForPlaylistChange(int fingerprint) async {
    final store = IptvEpgSourcesStore(connection.id);
    final stored = await store.loadChannelFingerprint();
    final settings = SettingsService.instanceOrNull;
    if (stored != null &&
        stored != fingerprint &&
        settings != null &&
        settings.read(SettingsService.iptvEpgUpdateOnPlaylistChange)) {
      // 1.3.24 §67 F8: the decision is logged so the next phone log
      // can say whether the playlist check fired — and with which
      // fingerprints — instead of leaving it to be inferred.
      EpgCadenceLog.recordFingerprintDecision(
        refreshed: true,
        reason: 'playlist-changed',
        stored: stored,
        fresh: fingerprint,
      );
      await _liveTv.refreshEpgCache();
    } else {
      EpgCadenceLog.recordFingerprintDecision(
        refreshed: false,
        reason: stored == null
            ? 'first-load'
            : stored == fingerprint
                ? 'unchanged'
                : settings == null
                    ? 'settings-unavailable'
                    : 'update-on-playlist-change-off',
        stored: stored,
        fresh: fingerprint,
      );
    }
    await store.saveChannelFingerprint(fingerprint);
  }

  /// One [LiveTvChannel] for one raw Xtream row — shared by
  /// [iptvChannels] and the F3 full-list capture, so the visible and
  /// the full list are built identically.
  LiveTvChannel _liveTvChannelForStream(XtreamLiveStream stream) =>
      LiveTvChannel.fromXtreamStream(stream, serverId: connection.id, serverName: _name);

  /// One [LiveTvChannel] for one M3U entry — shared by [iptvChannels]
  /// and the F3 full-list capture. [key] is `tvg-id ?? url`, the same
  /// key derivation [iptvChannels] uses.
  LiveTvChannel _liveTvChannelForM3uEntry(M3uEntry entry, String key) => LiveTvChannel(
    key: key,
    identifier: entry.tvgId,
    title: entry.name,
    thumb: entry.tvgLogo,
    serverId: connection.id,
    serverName: _name,
    // Guide category picker (build #17): an M3U channel's
    // category is its group title.
    categoryId: entry.groupTitle,
  );

  /// Re-fetch the live channel list from the provider (PlezTV 1.2.0,
  /// §3.2 — Reload TV details): Xtream re-fetches get_live_streams and
  /// rewrites the disk catalog; M3U drops its playlist cache and
  /// re-downloads. Movies and series are untouched — this is not a full
  /// catalog sync. Returns the fresh channel list and tells the library
  /// views the catalog changed. The channel-list fingerprint is stored
  /// with the fresh rows, so the next fresh load does not re-trigger an
  /// update-on-playlist-change refresh for a change already handled.
  Future<List<LiveTvChannel>> refreshLiveChannelsFromNetwork() async {
    // 1.2.8 F3: a failed refresh leaves no stale full list behind.
    fullLiveChannelsFromLastRefresh = null;
    if (_isXtream) {
      _liveStreamsFuture = null;
      _liveCategoriesFuture = null;
      _liveCategoryNamesFuture = null;
      _xtreamChannelByKey.clear();
      _invalidateGuideChannelCache();
      // 1.2.4 (rebase): Reload routes through the same filtered paths
      // as the first load — the disk file AND the published memo hold
      // visible rows only, or Reload re-grows the pruned disk file and
      // re-fills the live memo (FORK §45.8d).
      final filter = await _visibleCatalogFilterFor(IptvSearchIndex.typeLive);
      final rows = await _xtreamApi.getLiveStreams();
      // 1.2.8 F3: capture the FULL list (hidden rows included) and
      // resolve the key map for ALL rows, so Reload can count matches
      // over hidden channels. The published memo / disk file below
      // still hold visible rows only.
      fullLiveChannelsFromLastRefresh = rows.map(_liveTvChannelForStream).toList(growable: false);
      for (final row in rows) {
        _xtreamChannelByKey['${row.streamId}'] = row;
      }
      final visible = _visibleRows(rows, (r) => r.categoryId, filter);
      // 1.2.19 (A1): the load streamed to a temp file — persist it
      // without ever holding it as a String (see [_persistHubDownload]).
      // A test fake with no file falls back to the direct encode.
      final rawFilePath = _xtreamApi.lastLiveStreamsFilePath;
      if (visible.isNotEmpty) {
        if (rawFilePath != null) {
          _persistHubDownload(
            IptvCatalogDiskCache.liveDataset,
            rawFilePath,
            filter,
            XtreamApi.writeLiveStreamsFileVisible,
          );
        } else {
          _writeDiskCatalog(IptvCatalogDiskCache.liveDataset, visible, (r) => r.toJson());
        }
      } else if (rows.isNotEmpty) {
        // Panel answered in full but every row is hidden — the
        // deliberate empty-array file (same rule as the first load).
        _writeDiskText(IptvCatalogDiskCache.liveDataset, '[]');
        XtreamApi.deleteHubTempFile(rawFilePath);
      }
      _liveStreamsFuture = Future.value(visible);
      _liveStreamsLoaded = true;
      // 1.2.11: Reload publishes the memo but does NOT write the index
      // (pre-existing) — the guide must keep serving this fresh memo
      // until the index catches up, and the index must catch up: force
      // a live re-seed from the disk file Reload just wrote (the stamp
      // clears itself once the re-seed lands — see
      // [_liveMemoFresherThanIndex]). Without the re-seed the guide
      // would revert to the stale index rows on its second call after
      // a Reload, and without the stamp it would serve them on the
      // first. The re-seed is fire-and-forget: the memo serves until
      // it lands, and a partial Reload fetch is refused by the warm
      // index, which leaves the memo serving (the old behaviour).
      _liveReloadStamp = DateTime.now();
      unawaited(
        _runIndexWrite(() => _seedSearchIndexTypeFromDisk(IptvSearchIndex.typeLive, force: true)).then((
          result,
        ) {
          // The re-seed landed: the index is fresh, so the Reload memo
          // can go — the guide serves the index from now on. When the
          // warm index refuses the re-seed (a visible-only disk file
          // covering under half the categories reads as partial), the
          // flag stays and the memo keeps serving until the next sync
          // heals the index — the guide stays right either way.
          if (result != null && result.skippedReason == null) {
            _liveStreamsFuture = null;
            _liveStreamsLoaded = false;
            _liveReloadStamp = null;
          }
        }),
      );
      await IptvEpgSourcesStore(
        connection.id,
      ).saveChannelFingerprint(
        // 1.3.24 §67 F6: the saved fingerprint is over the VISIBLE
        // rows — the set the index and memo paths actually hash
        // (_liveStreams() returns visible-only; the index seed prunes
        // hidden rows). Saving the all-rows hash made every Reload
        // look like a playlist change whenever a category was hidden.
        iptvPlaylistFingerprint(visible.map((r) => iptvPlaylistRowHash([r.streamId, r.name, r.epgChannelId]))),
      );
    } else {
      _m3uEntriesFuture = null;
      await _catalogCache.delete(connection.id, IptvCatalogDiskCache.m3uDataset);
      // 1.2.8 F3: same full-list capture as Xtream above — the entries
      // fetch re-downloads the playlist once; iptvChannels() below
      // reuses the cached parse.
      final entries = await _m3uEntries();
      fullLiveChannelsFromLastRefresh = entries.map((entry) {
        final key = entry.tvgId ?? entry.url;
        _m3uChannelByKey[key] = entry;
        return _liveTvChannelForM3uEntry(entry, key);
      }).toList(growable: false);
    }
    final channels = await iptvChannels();
    notifyCatalogRefreshed(userInitiated: true);
    return channels;
  }

  /// Direct live URL for a channel key (throws when unknown).
  String liveUrlForChannelKey(String key) {
    if (_isXtream) {
      return _xtreamApi.liveStreamUrl(key);
    }
    final entry = _m3uChannelByKey[key];
    if (entry == null) throw UnsupportedError('IPTV: unknown M3U channel key $key');
    return entry.url;
  }

  /// Catch-up info for a channel key. Null when the channel has no archive
  /// (M3U never does; Xtream only when tv_archive = 1).
  ({int streamId, int archiveDurationSeconds})? archiveInfoForChannelKey(String key) {
    if (!_isXtream) return null;
    final stream = _xtreamChannelByKey[key];
    if (stream == null || !stream.tvArchive) return null;
    return (streamId: stream.streamId, archiveDurationSeconds: stream.tvArchiveDuration);
  }

  /// Catch-up URL for a channel key at [start] (programme start), with a
  /// [durationMinutes] window. Xtream only.
  String timeshiftUrlForChannelKey(String key, DateTime start, int durationMinutes) {
    return _xtreamApi.timeshiftUrl(streamId: key, durationMinutes: durationMinutes, start: start);
  }
}

/// On-device series catalog diagnostics (build #10): what the phone
/// reports about the series catalog — the unfiltered row count, the
/// series category count, per-category row counts for the first few
/// categories (direct get_series probes), and how many initials /
/// categories are turned off. A series search that still fails with a
/// healthy readout here points at timing, not at the data.
class IptvCatalogDiagnostics {
  const IptvCatalogDiagnostics({
    required this.unfilteredSeriesRows,
    required this.seriesCategoryCount,
    required this.perCategorySeriesRows,
    required this.hiddenCategoryInitialsCount,
    required this.hiddenCategoriesCount,
  });

  /// Rows the unfiltered get_series call returned (what Recommended reads).
  final int unfilteredSeriesRows;

  /// How many series categories the panel lists.
  final int seriesCategoryCount;

  /// Direct per-category get_series row counts, keyed "name (id)", for
  /// the first few series categories.
  final Map<String, int> perCategorySeriesRows;

  /// How many category initials are turned off on this connection.
  final int hiddenCategoryInitialsCount;

  /// How many categories are turned off by their own switch.
  final int hiddenCategoriesCount;
}

/// A counting semaphore shared by the three search sections of one search
/// — and by concurrent searches on the same client (build #21). It is the
/// thing that enforces [IptvClient.searchBurstCap]: a category call takes
/// a permit before it is launched and returns it when it lands (or aborts),
/// so the panel never sees more than the cap in flight, however many
/// sections or keystrokes are running.
///
/// Grant rule (single isolate, first-wins): a permit is handed to exactly
/// one waiter. [release] completes the first waiter still queued — that
/// waiter owns the permit from that moment, without [_available] moving —
/// and skips waiters whose deadline or abort already won (their completer
/// is already completed, so completing it again is a no-op). A waiter that
/// times out or aborts removes itself from the queue and owns nothing.
/// [_available] only moves when a permit is taken with no waiter queued
/// ([acquireUntil] fast path) or returned with no waiter queued ([release]).
class _SearchRequestSemaphore {
  _SearchRequestSemaphore(int permits) : _available = permits;

  int _available;
  final Queue<Completer<bool>> _waiters = Queue<Completer<bool>>();

  /// Take a permit, waiting until one is free, [deadline], or [abort]
  /// fires. Returns true when a permit was granted, false when the wait
  /// ended without one — the caller must stop, not retry.
  Future<bool> acquireUntil(DateTime deadline, AbortController? abort) async {
    if (_available > 0) {
      _available--;
      return true;
    }
    if (abort?.isAborted ?? false) return false;
    final timeLeft = deadline.difference(DateTime.now());
    if (timeLeft <= Duration.zero) return false;
    final waiter = Completer<bool>();
    _waiters.add(waiter);
    final timer = Timer(timeLeft, () {
      if (!waiter.isCompleted) waiter.complete(false);
    });
    // Abort wakes the waiter the same way (the trigger future completes
    // on abort; the isCompleted guard makes a late abort a no-op when
    // the deadline already won).
    unawaited(
      abort?.trigger.then((_) {
        if (!waiter.isCompleted) waiter.complete(false);
      }),
    );
    bool granted;
    try {
      granted = await waiter.future;
    } finally {
      timer.cancel();
    }
    if (!granted) {
      // No permit: remove ourselves from the queue (a release() that
      // already picked us up removes us first, so this is a no-op then).
      _waiters.remove(waiter);
      return false;
    }
    return true;
  }

  /// Return a permit. Hands it straight to the first waiter still queued;
  /// parks it when nobody is waiting.
  void release() {
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      if (!waiter.isCompleted) {
        waiter.complete(true);
        return;
      }
      // Already completed (deadline/abort won) — try the next waiter.
    }
    _available++;
  }
}

/// Per-section readout accumulated by one search (build #13): which
/// source supplied the matches and how long each leg took. A section's
/// methods fill their trace in as they go; [searchItems] turns the three
/// traces into the [IptvSearchDiagnostics] the settings row shows.
/// `loadRows` is -1 while the catalog load has not landed yet (so "load
/// never landed" reads differently from "load landed with 0 rows").
class _SectionTrace {
  int loadRows = -1;
  int loadMs = -1;

  /// Where the catalog rows came from (build #18): 'disk', 'network' or
  /// 'crawl'. '' when the load never landed. Rendered in the Last search
  /// row so a poisoned disk is visible on the phone.
  String loadSource = '';
  int loadMatches = 0;
  int sweepMatches = 0;
  int partialMatches = 0;

  /// Rows that matched the query but sat in a hidden category (build
  /// #17): counted, not returned, so the search screen can tell the user
  /// the filter hid them instead of showing a bare "No results".
  int hiddenMatches = 0;

  /// The letter-group initials that hid those matches (v1.1.0): the
  /// search screen names the hiding group instead of only counting.
  final hiddenInitials = <String>{};
  int ms = 0;
  bool skipped = false;

  /// The section's live result list, shared with the search so a section
  /// that runs out of budget returns what it already found instead of
  /// [] (build #13: the sweep had found the match and the 100ms margin
  /// between the 90% sweep deadline and the 100% section timeout was
  /// eaten, discarding the found match — the timeout must never throw
  /// found results away).
  List<MediaItem> partialOut = const [];

  int get returned => loadMatches + sweepMatches + partialMatches;

  /// The section's index was cold for this search (build v1.0.11, R2.0):
  /// the type had no indexed rows, so a typing search answered [] without
  /// touching the panel and a submit kicked off the sync instead. The
  /// search screen reads the same state from the index-state notifier;
  /// this is the diagnostics record of it.
  bool cold = false;

  IptvSearchSectionDiagnostics get diagnostics => IptvSearchSectionDiagnostics(
    loadRows: loadRows,
    loadMs: loadMs,
    loadSource: loadSource,
    loadMatches: loadMatches,
    sweepMatches: sweepMatches,
    partialMatches: partialMatches,
    hiddenMatches: hiddenMatches,
    hiddenInitials: hiddenInitials.toList()..sort(),
    ms: ms,
    skipped: skipped,
    cold: cold,
  );
}

/// One section of a [IptvSearchDiagnostics] readout: what the movies,
/// series or live leg saw during the last search.
class IptvSearchSectionDiagnostics {
  const IptvSearchSectionDiagnostics({
    required this.loadRows,
    required this.loadMs,
    this.loadSource = '',
    required this.loadMatches,
    required this.sweepMatches,
    required this.partialMatches,
    required this.hiddenMatches,
    this.hiddenInitials = const [],
    required this.ms,
    required this.skipped,
    this.cold = false,
  });

  /// Rows the catalog load produced (-1 when it never landed during the
  /// search, 0 when it landed empty).
  final int loadRows;

  /// Milliseconds the load took to land (-1 when it never landed).
  final int loadMs;

  /// Where the catalog rows came from (build #18): 'disk', 'network' or
  /// 'crawl'. '' when the load never landed.
  final String loadSource;

  /// Matches that came from the full catalog load.
  final int loadMatches;

  /// Matches that came from the per-category sweep.
  final int sweepMatches;

  /// Matches that came from the crawl's published partial rows.
  final int partialMatches;

  /// Rows that matched the query but were removed by the hidden-category
  /// filter (build #17) — the search screen's "matches are in categories
  /// you turned off" message reads this.
  final int hiddenMatches;

  /// The letter-group initials that hid those matches (v1.1.0) — the
  /// search screen's "matches are in the EN group, which you turned
  /// off" message reads this. Empty when nothing was hidden by a group
  /// (hidden by per-category id only).
  final List<String> hiddenInitials;

  /// Wall time of the whole section, in milliseconds.
  final int ms;

  /// True when the section was excluded (scoped search).
  final bool skipped;

  /// True when the section's index was cold for this search (build
  /// v1.0.11, R2.0): the type had no indexed rows.
  final bool cold;

  /// Matches the section returned in total.
  int get returned => loadMatches + sweepMatches + partialMatches;
}

/// On-device search diagnostics (build #13): the readout for the LAST
/// search on this connection — the query, the scope, and per section
/// which source supplied the results and how long each leg took. One
/// screenshot of the settings row settles where a search dies: a load
/// that never lands (`loadRows: -1` after ~50s) is a slow catalog, a
/// load with rows but zero matches is the filter or the match, and a
/// sweep with zero matches while the load landed empty is the panel's
/// per-category shape. Shown in the IPTV settings screen next to the
/// series catalog diagnostics.
class IptvSearchDiagnostics {
  const IptvSearchDiagnostics({
    required this.query,
    required this.scoped,
    required this.totalMs,
    required this.movies,
    required this.series,
    required this.live,
    required this.recordedAt,
  });

  /// The searched query (trimmed, lower-cased as searched).
  final String query;

  /// True when a scope was active (some libraries excluded).
  final bool scoped;

  /// Wall time of the whole search, in milliseconds.
  final int totalMs;

  /// Movies leg readout.
  final IptvSearchSectionDiagnostics movies;

  /// Series leg readout.
  final IptvSearchSectionDiagnostics series;

  /// Live TV leg readout.
  final IptvSearchSectionDiagnostics live;

  /// When the search ran.
  final DateTime recordedAt;
}

/// One cached season-episode mapping (1.5.3 N3): the mapped items plus
/// the memo instances they were built from, so a later call can tell —
/// by identity, with no extra reads — whether the mapping is still
/// current or must be rebuilt.
class _SeasonEpisodeItems {
  const _SeasonEpisodeItems({
    required this.row,
    required this.info,
    required this.favorites,
    required this.resume,
    required this.categoryNames,
    required this.items,
  });

  // 1.6.11 P1: the STABLE catalog row the items were mapped from — the
  // N3 identity check keys on this, never on the gap-filled copy.
  final XtreamSeries row;
  final XtreamSeriesInfo info;
  final Map<String, IptvFavoriteItem> favorites;
  final Map<String, IptvResumeItem> resume;
  final Map<String, String> categoryNames;
  final List<MediaItem> items;
}
