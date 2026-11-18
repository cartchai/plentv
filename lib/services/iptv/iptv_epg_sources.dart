import 'dart:async';
import 'dart:convert';

import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Third-party EPG sources + per-channel manual EPG assignment (PlezTV
/// 1.2.0, EPG area build 2 — TiviMate-anchored, §3.1/§3.2 of
/// RESEARCH_EPG_AREA.md).
///
/// The provider feed is implicit and never stored: Xtream = the login's
/// `xmltv.php` feed, M3U = the playlist's declared `url-tvg` / `x-tvg-url`
/// (`M3uConnection.epgUrl`) when present. Everything a user adds lives in
/// SharedPreferences under per-connection keys (same pattern as the hidden
/// channels store), so it survives refreshes and catalog syncs — a removed
/// source stays removed; the provider never silently re-enables it
/// (IPTVnator rule).
///
/// The mapping store is the escape hatch for channels no automatic match
/// can reach (the beIN case: feed id "beIN Sports 1" vs tvg-id
/// "beIN.Sports.1" vs name "beIN SPORTS 1 HD"): a manual assignment is
/// consulted before the byId/byName chain and survives refreshes/syncs.

/// One EPG source for a connection.
class IptvEpgSourceConfig {
  /// `'provider'` for the built-in feed, `'user_<uuid>'` for an added one.
  final String id;

  /// `'provider'` or `'xmltv'` (an added XMLTV URL).
  final String kind;

  /// The XMLTV URL for an added source; null for the provider feed.
  final String? url;

  /// Display name. Defaults to the URL host when the user adds a source
  /// without naming it.
  final String name;

  /// A disabled source is never fetched and never matches.
  final bool enabled;

  /// Display-only time shift for this source, in minutes. Null means
  /// "fall back to the global EPG time offset" (TiviMate model: per-source
  /// shift fixes a wrong-timezone feed without re-importing).
  final int? timeShiftMinutes;

  /// One-tap preset this source came from (1.3.28), if any — e.g.
  /// `'us-epgshare01'`. Null for hand-added sources and older ones.
  /// A preset is added once: a second add returns this source.
  final String? presetId;

  static const String providerId = 'provider';
  static const String kindProvider = 'provider';
  static const String kindXmltv = 'xmltv';

  const IptvEpgSourceConfig({
    required this.id,
    required this.kind,
    this.url,
    required this.name,
    this.enabled = true,
    this.timeShiftMinutes,
    this.presetId,
  });

  bool get isProvider => id == providerId;

  /// A fresh id for a user-added source.
  static String newUserId() => 'user_${const Uuid().v4()}';

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    if (url != null) 'url': url,
    'name': name,
    'enabled': enabled,
    if (timeShiftMinutes != null) 'timeShiftMinutes': timeShiftMinutes,
    if (presetId != null) 'presetId': presetId,
  };

  factory IptvEpgSourceConfig.fromJson(Map<String, dynamic> json) {
    final rawId = json['id'] as String? ?? '';
    final id = rawId.isEmpty ? providerId : rawId;
    final kind = json['kind'] as String? ?? (id == providerId ? kindProvider : kindXmltv);
    return IptvEpgSourceConfig(
      id: id,
      kind: kind,
      url: json['url'] as String?,
      name: json['name'] as String? ?? id,
      enabled: json['enabled'] as bool? ?? true,
      timeShiftMinutes: json['timeShiftMinutes'] as int?,
      presetId: json['presetId'] as String?,
    );
  }

  IptvEpgSourceConfig copyWith({
    String? name,
    bool? enabled,
    int? timeShiftMinutes,
    bool clearTimeShift = false,
  }) {
    return IptvEpgSourceConfig(
      id: id,
      kind: kind,
      url: url,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      timeShiftMinutes: clearTimeShift ? null : (timeShiftMinutes ?? this.timeShiftMinutes),
      presetId: presetId,
    );
  }
}

/// One-tap EPG preset (1.3.28): a live-verified public guide the user
/// can add with one tap instead of pasting a URL by hand.
class IptvEpgSourcePreset {
  /// Stable id, stamped on the source it creates (`presetId`).
  final String id;

  /// Display name.
  final String name;

  /// The XMLTV URL (may be a `.xml.gz` — the added-source path
  /// gunzips it, 1.3.28).
  final String url;

  /// Plain-words coverage note, shown under the preset. Must say what
  /// the guide covers AND what it does not — a preset must never
  /// claim to fill rows it cannot.
  final String description;

  const IptvEpgSourcePreset({required this.id, required this.name, required this.url, required this.description});
}

/// The verified presets (1.3.28).
class IptvEpgSourcePresets {
  /// The live-verified epgshare01 US guide (HTTP 200, 792 channels,
  /// 83,441 programmes, checked 2026-11-18). It fills US cable and
  /// sports rows the provider guide misses; it does NOT carry a bare
  /// national FOX / NBC / CBS / PBS channel, so it does not fill
  /// those four rows — no preset may claim otherwise.
  static const usEpgshare01 = IptvEpgSourcePreset(
    id: 'us-epgshare01',
    name: 'US guide (epgshare01)',
    url: 'https://epgshare01.online/epgshare01/epg_ripper_US2.xml.gz',
    description:
        'US cable and sports channels the provider guide misses. It does not carry the national FOX, NBC, CBS or PBS feeds, so those rows stay empty.',
  );

  static const all = [usEpgshare01];
}

/// Display state of one source's status chip (IPTVnator model — the
/// visibility TiviMate lacks).
enum IptvEpgSourceState { upToDate, needsRefresh, failed, disabled }

/// What a source did last, persisted so the settings screen shows it
/// after a restart. Facts only — the display [state] is computed from
/// them (a failure after the last success is "failed"; a success older
/// than the update interval is "needs refresh").
class IptvEpgSourceStatus {
  final DateTime? lastSuccess;
  final DateTime? lastFailure;
  final String? lastFailureReason;
  final int programs;
  final int channels;
  final int sizeBytes;
  final int? durationMs;

  /// 1.2.15 R4: the last feed download's diagnostics — programmes
  /// parsed before the window filter ([programsParsed]) vs retained
  /// after it ([programs]), feed channels declared
  /// ([channelsParsed]) vs carrying programmes ([channels]), the
  /// downloaded byte count ([bytesDownloaded], 0 on a 304), the
  /// SHA-256 of the downloaded bytes ([sha256], null on a 304), whether
  /// the server answered 304 ([notModified]), the validators it sent
  /// ([etag]/[lastModified]), and the User-Agent the request carried
  /// ([userAgent], null when none was sent).
  final int programsParsed;
  final int channelsParsed;
  final int bytesDownloaded;
  final String? sha256;
  final bool notModified;
  final String? etag;
  final String? lastModified;
  final String? userAgent;
  // 1.2.19 (L-3): whether the last download resumed a partial file,
  // and how many bytes came from it.
  final bool resumed;
  final int resumedBytes;

  const IptvEpgSourceStatus({
    this.lastSuccess,
    this.lastFailure,
    this.lastFailureReason,
    this.programs = 0,
    this.channels = 0,
    this.sizeBytes = 0,
    this.durationMs,
    this.programsParsed = 0,
    this.channelsParsed = 0,
    this.bytesDownloaded = 0,
    this.sha256,
    this.notModified = false,
    this.etag,
    this.lastModified,
    this.userAgent,
    this.resumed = false,
    this.resumedBytes = 0,
  });

  static const empty = IptvEpgSourceStatus();

  IptvEpgSourceState state({required bool enabled, Duration? ttl}) {
    if (!enabled) return IptvEpgSourceState.disabled;
    if (lastFailure != null && (lastSuccess == null || lastFailure!.isAfter(lastSuccess!))) {
      return IptvEpgSourceState.failed;
    }
    if (lastSuccess == null) return IptvEpgSourceState.needsRefresh;
    if (ttl != null && DateTime.now().difference(lastSuccess!) >= ttl) {
      return IptvEpgSourceState.needsRefresh;
    }
    return IptvEpgSourceState.upToDate;
  }

  Map<String, dynamic> toJson() => {
    if (lastSuccess != null) 'lastSuccess': lastSuccess!.toIso8601String(),
    if (lastFailure != null) 'lastFailure': lastFailure!.toIso8601String(),
    if (lastFailureReason != null) 'lastFailureReason': lastFailureReason,
    'programs': programs,
    'channels': channels,
    'sizeBytes': sizeBytes,
    if (durationMs != null) 'durationMs': durationMs,
    'programsParsed': programsParsed,
    'channelsParsed': channelsParsed,
    'bytesDownloaded': bytesDownloaded,
    if (sha256 != null) 'sha256': sha256,
    'notModified': notModified,
    if (etag != null) 'etag': etag,
    if (lastModified != null) 'lastModified': lastModified,
    if (userAgent != null) 'userAgent': userAgent,
    'resumed': resumed,
    'resumedBytes': resumedBytes,
  };

  factory IptvEpgSourceStatus.fromJson(Map<String, dynamic> json) {
    return IptvEpgSourceStatus(
      lastSuccess: DateTime.tryParse(json['lastSuccess'] as String? ?? ''),
      lastFailure: DateTime.tryParse(json['lastFailure'] as String? ?? ''),
      lastFailureReason: json['lastFailureReason'] as String?,
      programs: json['programs'] as int? ?? 0,
      channels: json['channels'] as int? ?? 0,
      sizeBytes: json['sizeBytes'] as int? ?? 0,
      durationMs: json['durationMs'] as int?,
      programsParsed: json['programsParsed'] as int? ?? 0,
      channelsParsed: json['channelsParsed'] as int? ?? 0,
      bytesDownloaded: json['bytesDownloaded'] as int? ?? 0,
      sha256: json['sha256'] as String?,
      notModified: json['notModified'] as bool? ?? false,
      etag: json['etag'] as String?,
      lastModified: json['lastModified'] as String?,
      userAgent: json['userAgent'] as String?,
      resumed: json['resumed'] as bool? ?? false,
      resumedBytes: json['resumedBytes'] as int? ?? 0,
    );
  }

  IptvEpgSourceStatus copyWith({
    DateTime? lastSuccess,
    DateTime? lastFailure,
    String? lastFailureReason,
    bool clearFailure = false,
    int? programs,
    int? channels,
    int? sizeBytes,
    int? durationMs,
    int? programsParsed,
    int? channelsParsed,
    int? bytesDownloaded,
    String? sha256,
    bool? notModified,
    String? etag,
    String? lastModified,
    String? userAgent,
    bool? resumed,
    int? resumedBytes,
  }) {
    return IptvEpgSourceStatus(
      lastSuccess: lastSuccess ?? this.lastSuccess,
      lastFailure: clearFailure ? null : (lastFailure ?? this.lastFailure),
      lastFailureReason: clearFailure ? null : (lastFailureReason ?? this.lastFailureReason),
      programs: programs ?? this.programs,
      channels: channels ?? this.channels,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      durationMs: durationMs ?? this.durationMs,
      programsParsed: programsParsed ?? this.programsParsed,
      channelsParsed: channelsParsed ?? this.channelsParsed,
      bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
      sha256: sha256 ?? this.sha256,
      notModified: notModified ?? this.notModified,
      etag: etag ?? this.etag,
      lastModified: lastModified ?? this.lastModified,
      userAgent: userAgent ?? this.userAgent,
      resumed: resumed ?? this.resumed,
      resumedBytes: resumedBytes ?? this.resumedBytes,
    );
  }
}

/// One feed download's diagnostics (1.2.15 R4): what the provider
/// actually sent for one source's feed — bytes, SHA-256, counts before
/// and after the window filter, 304-vs-200, the validators seen, the
/// User-Agent used, and when it was fetched. Recorded per download in
/// the support, shown in the Reload report, and kept in the per-source
/// status (sources screen + Logs).
class IptvEpgFeedDownload {
  final String sourceId;
  final String sourceName;
  final DateTime fetchedAt;
  final bool notModified;
  final int bytesDownloaded;
  final String? sha256;
  final int channelsParsed;
  final int channelsRetained;
  final int programsParsed;
  final int programsRetained;
  final String? etag;
  final String? lastModified;
  final String? userAgent;
  // 1.2.19 (L-3): whether this download resumed a partial file, and
  // how many bytes came from it. Defaults keep older construction
  // sites (and the 304 record, which never resumes) valid.
  final bool resumed;
  final int resumedBytes;

  const IptvEpgFeedDownload({
    required this.sourceId,
    required this.sourceName,
    required this.fetchedAt,
    required this.notModified,
    required this.bytesDownloaded,
    required this.sha256,
    required this.channelsParsed,
    required this.channelsRetained,
    required this.programsParsed,
    required this.programsRetained,
    required this.etag,
    required this.lastModified,
    required this.userAgent,
    this.resumed = false,
    this.resumedBytes = 0,
  });
}

/// The live guide's real coverage over a sample of visible channels
/// (1.2.15 R6, F10): how many sampled rows actually show programmes,
/// split by the source that served them — short-EPG, the feed by id,
/// the feed by name — vs rows with a cached empty ([none]) and rows
/// never fetched ([notFetched]). Read-only sampling of already-fetched
/// rows; no extra panel calls. Shown in the Reload report next to the
/// feed-only match count.
/// Which rows a guide-coverage sample describes (1.2.20 (d)):
/// `visible` — the rows the guide actually built (the fetch registry,
/// most-recent first); `matched` — the registry was empty, so the
/// channels the loaded feed guides match, pre-bust; `guideOrder` —
/// no guide was cached pre-bust, so the first rows in guide order
/// (the 1.2.15 behaviour).
enum IptvGuideSampleScope { visible, matched, guideOrder }

class IptvGuideCoverageSample {
  final int sampled;
  final int withPrograms;
  final int fromShortEpg;
  final int fromFeedById;
  final int fromFeedByName;

  /// 1.2.20 (c): sampled rows whose programmes mix short-EPG with feed
  /// programmes (the feed filled an untitled programme or a gap).
  final int fromMixed;
  final int none;
  final int notFetched;

  /// 1.2.20 (d): which rows this sample describes.
  final IptvGuideSampleScope scope;

  const IptvGuideCoverageSample({
    required this.sampled,
    required this.withPrograms,
    required this.fromShortEpg,
    required this.fromFeedById,
    required this.fromFeedByName,
    this.fromMixed = 0,
    required this.none,
    required this.notFetched,
    this.scope = IptvGuideSampleScope.guideOrder,
  });

  static const empty = IptvGuideCoverageSample(
    sampled: 0,
    withPrograms: 0,
    fromShortEpg: 0,
    fromFeedById: 0,
    fromFeedByName: 0,
    fromMixed: 0,
    none: 0,
    notFetched: 0,
    scope: IptvGuideSampleScope.guideOrder,
  );
}

/// The M3U `tvg-id` diagnostic's result (1.2.15 R2, diagnostic only):
/// how many of the channels with no `epg_channel_id` gain a `tvg-id`
/// from the provider's `get.php` playlist, and how many of those ids
/// are declared in the loaded feeds. No matching change follows from
/// this — the numbers decide whether one is worth building. [error]
/// is set when the playlist fetch itself failed; [feedLoaded] is false
/// when no feed was loaded to check the ids against.
/// [gainedIds] (1.3.26 §69) carries the gained pairs (channelKey ->
/// tvgId) so the dialog's Apply can write them as manual mappings —
/// without it the check could only report, never repair.
class IptvM3uTvgIdDiagnostic {
  final int checked;
  final int noId;
  final int gained;
  final int gainedInFeed;
  final bool feedLoaded;
  final String? error;
  final List<({String channelName, int streamId, String tvgId, bool inFeed})> samples;
  final Map<String, String> gainedIds;

  const IptvM3uTvgIdDiagnostic({
    required this.checked,
    required this.noId,
    required this.gained,
    required this.gainedInFeed,
    required this.feedLoaded,
    required this.error,
    required this.samples,
    this.gainedIds = const {},
  });
}

/// One EPG assignment: this channel always uses this XMLTV channel
/// id from this source. [origin] says how the mapping got here:
/// 'manual' (Assign, or the M3U tvg-id Apply) or 'guessed-affiliate' /
/// 'guessed-name' (auto-persisted by the per-channel fetch when the
/// guess tier served the row — 1.4.2: pick one and stick with it).
/// Rows written before 1.4.2 carry no origin and are all manual.
class IptvEpgMapping {
  final String xmltvId;
  final String sourceId;
  final String origin;

  const IptvEpgMapping({required this.xmltvId, required this.sourceId, this.origin = 'manual'});

  /// The match method tier 1 reports for this mapping. The detail
  /// sheet label and the Reload counts key on it, so a stored guess
  /// must not read as 'manual'.
  String get matchMethod => switch (origin) {
    'guessed-affiliate' => 'name-guess-affiliate',
    'guessed-name' => 'name-guess',
    _ => 'manual',
  };

  Map<String, dynamic> toJson() => {'xmltvId': xmltvId, 'sourceId': sourceId, 'origin': origin};

  factory IptvEpgMapping.fromJson(Map<String, dynamic> json) {
    return IptvEpgMapping(
      xmltvId: json['xmltvId'] as String? ?? '',
      sourceId: json['sourceId'] as String? ?? IptvEpgSourceConfig.providerId,
      origin: json['origin'] as String? ?? 'manual',
    );
  }
}

/// Per-connection store for EPG sources, the precedence toggle, manual
/// mappings, per-source status, and the channel-list fingerprint the
/// update-on-playlist-change check compares against. All keys are
/// per-connection (`iptv_epg_*:<connectionId>`), so one connection's
/// sources never leak into another's. Every method is best-effort on
/// corrupt data: a bad row reads as missing, never as a crash.
class IptvEpgSourcesStore {
  final String connectionId;

  IptvEpgSourcesStore(this.connectionId);

  String get _sourcesKey => 'iptv_epg_sources:$connectionId';
  String get _precedenceKey => 'iptv_epg_added_sources_first:$connectionId';
  String get _mappingKey => 'iptv_epg_mapping:$connectionId';
  String get _statusKey => 'iptv_epg_source_status:$connectionId';
  String get _fingerprintKey => 'iptv_epg_channel_fingerprint:$connectionId';

  Future<List<IptvEpgSourceConfig>> loadUserSources() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sourcesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out = <IptvEpgSourceConfig>[];
      for (final row in decoded) {
        if (row is! Map<String, dynamic>) continue;
        try {
          final source = IptvEpgSourceConfig.fromJson(row);
          // The provider feed is implicit — a stored row claiming to be
          // it is stale data, not a second provider.
          if (source.isProvider) continue;
          out.add(source);
        } catch (_) {
          // One bad row does not drop the rest.
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveUserSources(List<IptvEpgSourceConfig> sources) async {
    final prefs = await SharedPreferences.getInstance();
    final userOnly = sources.where((s) => !s.isProvider).toList(growable: false);
    await prefs.setString(_sourcesKey, jsonEncode(userOnly.map((s) => s.toJson()).toList()));
  }

  /// "Added sources take precedence over the provider guide" (IPTVnator
  /// toggle). Default off — the provider feed first, added sources fill
  /// gaps (TiviMate Premium model).
  Future<bool> loadAddedSourcesFirst() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_precedenceKey) ?? false;
  }

  Future<void> saveAddedSourcesFirst(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_precedenceKey, value);
  }

  Future<Map<String, IptvEpgMapping>> loadMappings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_mappingKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      final out = <String, IptvEpgMapping>{};
      for (final entry in decoded.entries) {
        if (entry.value is! Map<String, dynamic>) continue;
        try {
          final mapping = IptvEpgMapping.fromJson(entry.value as Map<String, dynamic>);
          if (mapping.xmltvId.isEmpty) continue;
          out[entry.key] = mapping;
        } catch (_) {
          // One bad row does not drop the rest.
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveMapping(String channelKey, IptvEpgMapping mapping) async {
    final mappings = await loadMappings();
    mappings[channelKey] = mapping;
    await _writeMappings(mappings);
  }

  /// Restores auto-matching for [channelKey].
  Future<void> clearMapping(String channelKey) async {
    final mappings = await loadMappings();
    if (mappings.remove(channelKey) == null) return;
    await _writeMappings(mappings);
  }

  /// Replace the whole mapping table (deleting a source clears every
  /// mapping that pointed at it — a deleted source must not keep
  /// matching channels).
  Future<void> saveMappings(Map<String, IptvEpgMapping> mappings) => _writeMappings(mappings);

  Future<void> _writeMappings(Map<String, IptvEpgMapping> mappings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _mappingKey,
      jsonEncode(mappings.map((key, value) => MapEntry(key, value.toJson()))),
    );
  }

  Future<Map<String, IptvEpgSourceStatus>> loadStatuses() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_statusKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      final out = <String, IptvEpgSourceStatus>{};
      for (final entry in decoded.entries) {
        if (entry.value is! Map<String, dynamic>) continue;
        try {
          out[entry.key] = IptvEpgSourceStatus.fromJson(entry.value as Map<String, dynamic>);
        } catch (_) {
          // One bad row does not drop the rest.
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveStatus(String sourceId, IptvEpgSourceStatus status) async {
    final statuses = await loadStatuses();
    statuses[sourceId] = status;
    await _writeStatuses(statuses);
  }

  /// Replace the whole status table (deleting a source drops its status
  /// row with it).
  Future<void> saveStatuses(Map<String, IptvEpgSourceStatus> statuses) => _writeStatuses(statuses);

  Future<void> _writeStatuses(Map<String, IptvEpgSourceStatus> statuses) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _statusKey,
      jsonEncode(statuses.map((key, value) => MapEntry(key, value.toJson()))),
    );
  }

  /// The channel-list fingerprint the update-on-playlist-change check
  /// compares against (see `IptvClient.iptvChannels`). Null before the
  /// first list load — the first load stores it without refreshing.
  Future<int?> loadChannelFingerprint() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_fingerprintKey);
  }

  Future<void> saveChannelFingerprint(int fingerprint) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_fingerprintKey, fingerprint);
  }

  String get _validatorsKey => 'iptv_epg_feed_validators:$connectionId';

  /// Conditional-fetch validators (1.2.2 I9) per feed [cacheKey]: the
  /// ETag / Last-Modified the server sent with the feed, sent back as
  /// If-None-Match / If-Modified-Since on the next refresh. A 304 means
  /// the feed on disk is current — no download, no re-parse. Both null
  /// when the server sends no validators (a dynamically generated
  /// xmltv.php likely sends none) — the next fetch is then
  /// unconditional, exactly as before. Corrupt rows read as empty.
  Future<({String? etag, String? lastModified})> loadValidators(String cacheKey) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_validatorsKey);
    if (raw == null || raw.isEmpty) return (etag: null, lastModified: null);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return (etag: null, lastModified: null);
      final row = decoded[cacheKey];
      if (row is! Map<String, dynamic>) return (etag: null, lastModified: null);
      return (etag: row['etag'] as String?, lastModified: row['lastModified'] as String?);
    } catch (_) {
      return (etag: null, lastModified: null);
    }
  }

  /// Store the validators from the latest feed response, replacing
  /// whatever was stored for [cacheKey] — the validators describe the
  /// current representation. Saving both null removes the row (the
  /// server sent no validators). Best-effort callers never throw on a
  /// lost validator: the next refresh just downloads in full.
  Future<void> saveValidators(String cacheKey, String? etag, String? lastModified) async {
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic> all = {};
    try {
      final raw = prefs.getString(_validatorsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) all = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // A corrupt table reads as empty; the save below replaces it.
    }
    if (etag == null && lastModified == null) {
      all.remove(cacheKey);
    } else {
      all[cacheKey] = {
        'etag': ?etag,
        'lastModified': ?lastModified,
      };
    }
    await prefs.setString(_validatorsKey, jsonEncode(all));
  }

  /// Forget every stored validator (Clear guide): a 304 against a
  /// deleted feed has no guide to reuse.
  Future<void> clearValidators() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_validatorsKey);
  }
}

/// Why a channel has no EPG (the "Channels without guide" grouping, and
/// the EPG details "why" line). A channel with no match says *why* —
/// never a bare empty row.
/// Why a channel has no EPG (the "Channels without guide" grouping, and
/// the EPG details "why" line). A channel with no match says *why* —
/// never a bare empty row.
enum IptvEpgNoGuideReason {
  noSource,
  noMatch,
  sourceFailed,
  notLoaded,

  /// The name names more than one feed channel (1.2.5 Fix 7): never a
  /// guess — the user Assigns one manually.
  ambiguous,

  /// The name names only a feed channel from another country (Fix 7).
  foreign,

  /// A feed id was identified (by id or by name) but it has no
  /// programmes in the window (Fix 7).
  matchedButNoPrograms,
}

/// One channel's EPG assignment state, for the guide long-press "EPG
/// details" view: which source serves it, which XMLTV id matched, how it
/// matched, and — when it has nothing — why.
class IptvChannelEpgDetail {
  final String channelKey;
  final String? channelName;

  /// The source that served the programmes (or the source a manual
  /// assignment points at). Null when no source serves the channel.
  final String? sourceId;
  final String? sourceName;

  /// The XMLTV channel id that matched (or was assigned).
  final String? matchedXmltvId;

  /// How it matched: `'tvg-id'`, `'name'`, or `'manual'`. Null when
  /// nothing matched.
  final String? matchMethod;

  /// Which source served this channel's programmes (1.2.8 F8): the
  /// short-EPG lookup or a feed match (by id or by name). Null when
  /// nothing served it — the details sheet shows '—'.
  final IptvEpgSource? epgSource;

  /// Programmes in the requested window.
  final int programCount;

  /// When the channel's cached entry was fetched (null when never
  /// fetched), and when it expires (null for manual-only / never).
  final DateTime? lastFetch;
  final DateTime? nextFetch;

  /// Why the channel has no guide. Null when it has programmes.
  final IptvEpgNoGuideReason? noGuideReason;

  const IptvChannelEpgDetail({
    required this.channelKey,
    this.channelName,
    this.sourceId,
    this.sourceName,
    this.matchedXmltvId,
    this.matchMethod,
    this.epgSource,
    this.programCount = 0,
    this.lastFetch,
    this.nextFetch,
    this.noGuideReason,
  });

  bool get hasGuide => programCount > 0;
}

/// One XMLTV channel id from one loaded feed, for the Assign EPG picker
/// (search is local, over these already-downloaded indexes).
class IptvEpgFeedChannel {
  final String sourceId;
  final String sourceName;
  final String xmltvId;
  final int programCount;

  /// The feed's display names for this id (1.2.5 Fix 2): the human
  /// names the picker shows and searches. Empty when the feed lists
  /// no `<channel>` element for the id.
  final List<String> displayNames;

  const IptvEpgFeedChannel({
    required this.sourceId,
    required this.sourceName,
    required this.xmltvId,
    required this.programCount,
    this.displayNames = const [],
  });
}

/// One channel with no EPG, for the "Channels without guide" overview.
class IptvChannelWithoutGuide {
  final String channelKey;
  final String channelName;
  final IptvEpgNoGuideReason reason;

  /// The feed ids the name tier could not choose between (1.2.5 Fix 7):
  /// the candidates for an `ambiguous` or `foreign` row — or the
  /// identified-but-empty ids for a `matchedButNoPrograms` row — so the
  /// user can Assign one manually. Empty for every other reason.
  final List<String> candidates;

  const IptvChannelWithoutGuide({
    required this.channelKey,
    required this.channelName,
    required this.reason,
    this.candidates = const [],
  });
}

/// What "Reload TV details" found (the recovery action for D1-poisoned
/// entries): the channel list was re-fetched and the EPG refreshed, and
/// these counts say what came back. `withGuide` counts channels whose
/// guide the downloaded feeds can serve (by id, name, or manual
/// assignment) — channels whose guide comes only from the provider's
/// per-channel lookup are counted once browsed.
/// Per-tier match counts for one Reload (1.2.5 Fix 1): how the channels
/// that got a guide got it, and — for the ones that did not — why.
/// The dialog and the Logs export print these, so a feed that loads
/// but matches nothing says which tier failed instead of only counting.
class IptvEpgMatchTiers {
  final int manual;
  final int tvgId;
  final int name;
  final int nameLoose;

  /// 1.3.29 P1-5: channels filled by the region-gated word-overlap
  /// affiliate guess ('name-guess-affiliate'). Kept apart from
  /// [name] on purpose — a guess is not a certain match, and the
  /// Reload dialog says so.
  final int affiliateGuess;

  final int ambiguous;
  final int foreign;
  final int noTvgId;
  final int tvgIdNotInFeed;
  final int matchedButNoProgrammes;

  /// 1.2.8 F2: the split of [matchedButNoProgrammes] — the feed
  /// declaring the id with zero programmes vs programmes that exist
  /// but all fall outside the Reload window. The two sum to
  /// [matchedButNoProgrammes].
  final int matchedButNoProgrammesDeclared;
  final int matchedButNoProgrammesOutsideWindow;
  final int none;

  const IptvEpgMatchTiers({
    this.manual = 0,
    this.tvgId = 0,
    this.name = 0,
    this.nameLoose = 0,
    this.affiliateGuess = 0,
    this.ambiguous = 0,
    this.foreign = 0,
    this.noTvgId = 0,
    this.tvgIdNotInFeed = 0,
    this.matchedButNoProgrammes = 0,
    this.matchedButNoProgrammesDeclared = 0,
    this.matchedButNoProgrammesOutsideWindow = 0,
    this.none = 0,
  });

  const IptvEpgMatchTiers.empty()
      : manual = 0,
        tvgId = 0,
        name = 0,
        nameLoose = 0,
        affiliateGuess = 0,
        ambiguous = 0,
        foreign = 0,
        noTvgId = 0,
        tvgIdNotInFeed = 0,
        matchedButNoProgrammes = 0,
        matchedButNoProgrammesDeclared = 0,
        matchedButNoProgrammesOutsideWindow = 0,
        none = 0;

  /// Channels that got a guide, by any tier.
  int get matched => manual + tvgId + name + nameLoose + affiliateGuess;

  /// Channels that got no guide, for any reason.
  int get unmatched => ambiguous + foreign + noTvgId + tvgIdNotInFeed + matchedButNoProgrammes + none;
}

/// One feed channel, for the Reload report's feed sample (1.2.5 Fix 1):
/// the raw feed id with the human names the feed lists for it, so the
/// user can see what the feed actually calls its channels.
class IptvEpgFeedSample {
  final String xmltvId;
  final List<String> displayNames;
  final int programCount;

  const IptvEpgFeedSample({
    required this.xmltvId,
    this.displayNames = const [],
    this.programCount = 0,
  });
}

/// One unmatched channel, for the Reload report's unmatched sample
/// (1.2.5 Fix 1): the playlist name plus the ids the matcher tried.
class IptvEpgUnmatchedSample {
  final String channelName;
  final String? epgChannelId;
  final String? tvgId;

  /// 1.2.8 F7: the blocked reason for this row ('ambiguous',
  /// 'foreign', 'no-tvg-id', 'tvg-id-not-in-feed',
  /// 'matched-but-no-programmes-declared',
  /// 'matched-but-no-programmes-outside-window', 'no-feed') — the
  /// dialog renders it next to the name.
  final String reason;

  const IptvEpgUnmatchedSample({
    required this.channelName,
    this.epgChannelId,
    this.tvgId,
    required this.reason,
  });
}

/// One feed candidate behind a foreign block (1.2.8 F9): the feed id
/// and the countries its id suffix / display-name tags name.
class IptvEpgForeignCandidate {
  final String xmltvId;
  final List<String> countries;

  const IptvEpgForeignCandidate({required this.xmltvId, this.countries = const []});
}

/// One foreign-blocked channel, for the Reload report's foreign
/// diagnostic (1.2.8 F9): the playlist name, the country the playlist
/// name claims, and the feed candidates the country gate refused.
class IptvEpgForeignSample {
  final String channelName;
  final String? playlistCountry;
  final List<IptvEpgForeignCandidate> candidates;

  const IptvEpgForeignSample({
    required this.channelName,
    this.playlistCountry,
    this.candidates = const [],
  });
}

class IptvReloadTvDetailsResult {
  final int channelsLoaded;
  final int withGuide;
  final int withoutGuide;
  final int feedChannelIds;

  /// Per-tier match counts + no-match reasons (1.2.5 Fix 1).
  final IptvEpgMatchTiers matchTiers;

  /// Up to 5 feed channels from the first loaded feed (1.2.5 Fix 1):
  /// what the feed actually calls its channels.
  final List<IptvEpgFeedSample> feedSamples;

  /// Up to 5 unmatched channels, in list order (1.2.5 Fix 1).
  final List<IptvEpgUnmatchedSample> sampleUnmatched;

  /// How many live channels carry a non-empty `epg_channel_id`
  /// (1.2.5 Fix 1): when this is 0, no tvg-id tier can ever match and
  /// the name tier is doing all the work. Null when the channel list
  /// was not re-fetched.
  final int? epgChannelIdCount;

  /// 1.2.8 F3: matches over ALL channels including hidden ones (the
  /// visible counts above are the filtered list). Null when the
  /// channel list was not re-fetched.
  final int? withGuideAllChannels;
  final int? channelsLoadedAll;

  /// 1.2.8 F2: the nearest retained programme start to now across
  /// the outside-window rows (null when no row is outside-window) —
  /// how far out the feed's schedule runs.
  final DateTime? nearestOutsideWindowProgramme;

  /// 1.2.8 F9: the first 5 foreign-blocked rows with their refused
  /// candidates, and the total count of refused candidates whose
  /// countries are all language-only codes (an "EN:"-tagged feed
  /// standing in for a US channel).
  final List<IptvEpgForeignSample> foreignSamples;
  final int foreignLanguageTaggedCandidateCount;

  /// Why the channel-list re-fetch failed, when it did (1.2.3 RC1).
  /// Null when the list loaded. The report dialog names this instead of
  /// showing nothing — a 403 is "the panel denied access", a timeout is
  /// "the panel is not answering".
  final IptvEpgFeedOutcomeKind? channelListFailureKind;

  /// URL-free short text for the list failure (see [epgFeedErrorReason]).
  final String? channelListFailureReason;

  /// One outcome per enabled source (1.2.3, the owner's follow-up): the
  /// report must name the FEED outcome, not just the channel counts —
  /// feed 403, feed timeout, feed loaded-but-matched-nothing, and feed
  /// loaded-with-matches are four different stories.
  final List<IptvEpgFeedOutcome> feedOutcomes;

  /// 1.2.15 R4: one download record per source whose feed was fetched
  /// for this Reload (bytes, SHA, 304-vs-200, User-Agent). Empty when
  /// no feed was downloaded.
  final List<IptvEpgFeedDownload> feedDownloads;

  /// 1.2.15 R6: the live guide's real coverage over the first 200
  /// visible channels, sampled before the Reload busts the per-channel
  /// cache. Null when the channel list was not re-fetched.
  final IptvGuideCoverageSample? guideCoverageSample;

  /// 1.2.20 (b): whether the Reload's end-of-load slide put the
  /// visible rows' feed programmes into the window, and why not when
  /// it did not. `reason` is a plain-words token: `'store-unavailable'`
  /// (no row store yet — first Reload after upgrade, or the build was
  /// gated), `'slide-failed'` (the slide threw), `'no-feed'` (no feed
  /// was loaded), or null when it slid (or when T0 skipped it silently
  /// — no feed is ever loaded there, so there is nothing to report).
  /// A failed/skipped slide never changes the Reload's success — the
  /// match counts above are still reported.
  final ({bool slid, int channelCount, String? reason}) windowSlide;

  const IptvReloadTvDetailsResult({
    required this.channelsLoaded,
    required this.withGuide,
    required this.withoutGuide,
    required this.feedChannelIds,
    this.channelListFailureKind,
    this.channelListFailureReason,
    this.feedOutcomes = const [],
    this.feedDownloads = const [],
    this.guideCoverageSample,
    this.matchTiers = const IptvEpgMatchTiers.empty(),
    this.feedSamples = const [],
    this.sampleUnmatched = const [],
    this.epgChannelIdCount,
    this.withGuideAllChannels,
    this.channelsLoadedAll,
    this.nearestOutsideWindowProgramme,
    this.foreignSamples = const [],
    this.foreignLanguageTaggedCandidateCount = 0,
    this.windowSlide = (slid: false, channelCount: 0, reason: null),
  });
}

/// The result of "Update now" (1.2.3 RC2): the same per-source feed
/// outcomes as a Reload, without a channel-list re-fetch — Update now
/// never touches the catalog, so no match counts, only the feed's own
/// size (see [IptvEpgFeedOutcome.matchedChannels]).
class IptvEpgUpdateNowResult {
  final List<IptvEpgFeedOutcome> feedOutcomes;

  const IptvEpgUpdateNowResult({required this.feedOutcomes});
}

/// Which source served a channel's EPG (build #17, §10) — the split the
/// guide coverage diagnostic reports. `unknown` is for entries read from
/// disk files written before this build recorded the source.
/// (Moved here from iptv_live_tv.dart in 1.2.8: the EPG detail and the
/// Reload result in this file need the type without an import cycle.)
enum IptvEpgSource {
  feedById,
  feedByName,
  shortEpg,
  none,
  unknown,

  /// 1.2.20 (c): the row mixes short-EPG programmes with feed
  /// programmes (the feed filled an untitled programme or a gap).
  /// Appended last so persisted files with the old values keep
  /// reading back (fromJson falls back to `unknown` for old values).
  mixed,
}

/// How one EPG source's feed ended up during a Reload / Update-now
/// attempt (PlezTV 1.2.3) — so the report dialog can name the feed
/// outcome instead of leaving the user to guess whether the feed
/// failed or loaded-but-matched-nothing.
enum IptvEpgFeedOutcomeKind {
  /// The feed loaded and matched at least one of this connection's
  /// channels.
  loaded,

  /// The feed loaded but matched NONE of this connection's channels
  /// (M2 — the feed is fine, the ids/names do not line up).
  loadedNoMatch,

  /// The panel denied access (HTTP 403 — and 401, same family).
  denied,

  /// The panel did not answer (timeout / connection error).
  notAnswering,

  /// The feed load was deferred because something is playing (D1b) —
  /// it never downloaded, and will retry when playback stops.
  deferred,

  /// Any other failure (reason carries the detail).
  failed,
}

/// One source's outcome inside a Reload / Update-now report.
class IptvEpgFeedOutcome {
  /// The source id (`'provider'` or a user source id).
  final String sourceId;

  /// Display name shown in the report.
  final String sourceName;

  final IptvEpgFeedOutcomeKind kind;

  /// Distinct XMLTV channel ids in the loaded feed (0 when the feed
  /// never loaded).
  final int feedChannels;

  /// How many of this connection's channels the feed can serve. Null
  /// when the channel list was not available (Update now never
  /// re-fetches it) — the report then names the feed's own size
  /// instead of a match count.
  final int? matchedChannels;

  /// Short failure text for [IptvEpgFeedOutcomeKind.denied],
  /// [IptvEpgFeedOutcomeKind.notAnswering] and
  /// [IptvEpgFeedOutcomeKind.failed]. Never contains a URL — see
  /// [epgFeedErrorReason].
  final String? reason;

  /// Programmes parsed before the I8 window filter (1.2.5 Fix 1).
  /// Null when the feed never loaded.
  final int? feedProgramsParsed;

  /// Programmes retained after the window filter (1.2.5 Fix 1) — the
  /// guide's own size. Null when the feed never loaded.
  final int? feedProgramsRetained;

  /// Distinct `<channel>` ids in the feed (1.2.5 Fix 1). Null when the
  /// feed never loaded.
  final int? feedChannelsParsed;

  const IptvEpgFeedOutcome({
    required this.sourceId,
    required this.sourceName,
    required this.kind,
    this.feedChannels = 0,
    this.matchedChannels,
    this.reason,
    this.feedProgramsParsed,
    this.feedProgramsRetained,
    this.feedChannelsParsed,
  });
}

/// Classify an EPG feed/list failure for display (PlezTV 1.2.3): a 403
/// (or 401) means the panel denied access; a timeout or connection
/// error means the panel is not answering; anything else is a plain
/// failure.
IptvEpgFeedOutcomeKind classifyEpgFeedError(Object error) {
  if (error is MediaServerAuthException) {
    return (error.statusCode == 401 || error.statusCode == 403)
        ? IptvEpgFeedOutcomeKind.denied
        : IptvEpgFeedOutcomeKind.failed;
  }
  final mapped = MediaServerHttpException.from(error);
  if (mapped.statusCode == 403) return IptvEpgFeedOutcomeKind.denied;
  if (mapped.isTransient) return IptvEpgFeedOutcomeKind.notAnswering;
  // Some paths wrap the failure as a plain error whose text still
  // names the status (e.g. a fake, or a StateError carrying the panel
  // reply). The 5-minute "failed recently" StateError carries no
  // status code and falls through to `failed`, as it should.
  if (mapped.message.contains('403')) return IptvEpgFeedOutcomeKind.denied;
  return IptvEpgFeedOutcomeKind.failed;
}

/// One report line for a feed outcome (PlezTV 1.2.3): the user must be
/// able to tell from the dialog alone whether the feed failed or
/// loaded-but-matched-nothing. Shared by the Reload report and the
/// Update-now report. [channelsTotal] is the connection's channel
/// count (0 when the list was not available — the lines then name the
/// feed's own size instead of a match count).
String epgFeedOutcomeLine(IptvEpgFeedOutcome outcome, int channelsTotal) {
  return switch (outcome.kind) {
    IptvEpgFeedOutcomeKind.loaded when outcome.matchedChannels != null => t.iptv.epgFeedOutcomeLoaded(
      source: outcome.sourceName,
      matched: outcome.matchedChannels!,
      channels: channelsTotal,
    ),
    IptvEpgFeedOutcomeKind.loaded when outcome.feedChannels == 0 => t.iptv.epgFeedOutcomeLoadedEmpty(source: outcome.sourceName),
    IptvEpgFeedOutcomeKind.loaded => t.iptv.epgFeedOutcomeLoadedFeedOnly(source: outcome.sourceName, feedChannels: outcome.feedChannels),
    IptvEpgFeedOutcomeKind.loadedNoMatch when outcome.feedChannelsParsed == 0 =>
      t.iptv.epgFeedOutcomeLoadedNoChannels(source: outcome.sourceName),
    IptvEpgFeedOutcomeKind.loadedNoMatch when outcome.feedProgramsRetained == 0 && (outcome.feedProgramsParsed ?? 0) > 0 =>
      t.iptv.epgFeedOutcomeLoadedProgramsOutsideWindow(source: outcome.sourceName, parsed: outcome.feedProgramsParsed!),
    IptvEpgFeedOutcomeKind.loadedNoMatch when outcome.feedProgramsRetained == 0 =>
      t.iptv.epgFeedOutcomeLoadedNoPrograms(source: outcome.sourceName),
    IptvEpgFeedOutcomeKind.loadedNoMatch => t.iptv.epgFeedOutcomeLoadedNoMatch(source: outcome.sourceName, channels: channelsTotal),
    IptvEpgFeedOutcomeKind.denied => t.iptv.epgFeedOutcomeDenied(source: outcome.sourceName),
    IptvEpgFeedOutcomeKind.notAnswering => t.iptv.epgFeedOutcomeNotAnswering(source: outcome.sourceName),
    IptvEpgFeedOutcomeKind.deferred => t.iptv.epgFeedOutcomeDeferred(source: outcome.sourceName),
    IptvEpgFeedOutcomeKind.failed => t.iptv.epgFeedOutcomeFailed(source: outcome.sourceName, reason: outcome.reason ?? ''),
  };
}

/// A URL-free short reason for an EPG failure (PlezTV 1.2.3): the
/// exception's own message — never [Object.toString], because a
/// [MediaServerHttpException] appends the request host+path to its
/// toString, and the panel URL must never surface in the UI (or in a
/// persisted status).
String epgFeedErrorReason(Object error) {
  // 1.2.22 §63.4: map by message text too — a timeout can arrive
  // re-wrapped (its type no longer says timeout), and the raw Dart text
  // ("Future not completed") reached the user verbatim in the 1.2.15 R2
  // check and again in the 1.2.19 log. The match is on the message, never
  // on toString for a MediaServerException (its toString appends the
  // request host+path, and the panel URL must never surface in the UI).
  final message = error is MediaServerException ? error.message : error.toString();
  final lower = message.toLowerCase();
  if (lower.contains('timed out') || lower.contains('future not completed')) {
    return t.errors.reasonTimedOut;
  }
  if (error is MediaServerException) {
    // 1.2.17: a timeout's `message` is the raw Dart text ("Future not
    // completed") — it reached the user verbatim in the 1.2.15 R2 check.
    // Map it to the plain localized phrase, like `localizedErrorReason`.
    if (error is MediaServerHttpException &&
        (error.type == MediaServerHttpErrorType.connectionTimeout ||
            error.type == MediaServerHttpErrorType.receiveTimeout)) {
      return t.errors.reasonTimedOut;
    }
    return error.message;
  }
  if (error is TimeoutException) return t.errors.reasonTimedOut;
  return error.toString();
}
