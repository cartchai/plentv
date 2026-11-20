import 'dart:convert';
import 'dart:io';

/// M3U / M3U8 playlist parser. Pure text in, entries out — no network.
///
/// Handles `#EXTINF` lines (`tvg-id`, `tvg-logo`, `group-title`,
/// `catchup-source`, plus any other `key="value"` attributes) followed by
/// the stream URL on the next non-comment line. `#EXTM3U` headers, `#EXTGRP`
/// lines and other comments are skipped. An entry without a following URL
/// line is dropped.
class M3uEntry {
  final String name;
  final String url;
  final String? tvgId;
  final String? tvgLogo;
  final String? groupTitle;
  final String? catchupSource;

  const M3uEntry({
    required this.name,
    required this.url,
    this.tvgId,
    this.tvgLogo,
    this.groupTitle,
    this.catchupSource,
  });
}

final _attrPattern = RegExp(r'''([\w-]+)=(?:"([^"]*)"|([^\s,]+))''');

Map<String, String> _parseAttributes(String extinfLine) {
  final attrs = <String, String>{};
  for (final match in _attrPattern.allMatches(extinfLine)) {
    final key = match.group(1);
    final value = match.group(2) ?? match.group(3);
    if (key != null && value != null) attrs[key] = value;
  }
  return attrs;
}

List<M3uEntry> parseM3u(String text) {
  final parser = _M3uLineParser();
  for (final line in text.split('\n')) {
    parser.addLine(line);
  }
  return parser.entries;
}

/// One `#EXTINF`-then-URL state machine, shared by [parseM3u] and
/// [parseM3uFile] so the two parsers can never disagree about what an
/// entry is: `#EXTINF` lines capture attributes + display name (after
/// the last comma); a bare URL line pairs with the preceding EXTINF, or
/// stands alone with its last path segment as the name; `#EXTM3U`,
/// `#EXTGRP` and other comments are skipped; an entry without a
/// following URL line is dropped.
class _M3uLineParser {
  final entries = <M3uEntry>[];
  Map<String, String>? _pendingAttrs;
  String? _pendingName;

  void addLine(String rawLine) {
    final line = rawLine.trim();
    if (line.isEmpty) return;

    if (line.startsWith('#EXTINF')) {
      _pendingAttrs = _parseAttributes(line);
      // Display name follows the last comma on the EXTINF line.
      final comma = line.lastIndexOf(',');
      _pendingName = comma >= 0 && comma < line.length - 1 ? line.substring(comma + 1).trim() : '';
      return;
    }

    if (line.startsWith('#')) return; // #EXTM3U, #EXTGRP, other comments

    // A bare URL line: pairs with the preceding EXTINF, or stands alone.
    final pending = _pendingName;
    final name = (pending != null && pending.isNotEmpty) ? pending : line.split('/').last;
    entries.add(
      M3uEntry(
        name: name,
        url: line,
        // 1.2.8 F1 (same rule as Xtream epg_channel_id): an empty
        // tvg-id="" is absent, not an id.
        tvgId: switch (_pendingAttrs?['tvg-id']) { final s? when s.isNotEmpty => s, _ => null },
        tvgLogo: _pendingAttrs?['tvg-logo'],
        groupTitle: _pendingAttrs?['group-title'],
        catchupSource: _pendingAttrs?['catchup-source'],
      ),
    );
    _pendingAttrs = null;
    _pendingName = null;
  }
}

/// Parse an M3U playlist from a DISK FILE (1.2.19, A2; 1.5.3 N1): the
/// file is read line by line inside the isolate, so neither the main
/// isolate nor the isolate ever holds the whole playlist as one String
/// — the provider playlist is ~300 MB, and the old whole-file
/// `readAsString` spiked RSS ~600 MB at that scale. Malformed UTF-8
/// bytes become the replacement character instead of failing the whole
/// parse (the old whole-file read threw on them). A top-level function
/// so it can run under `compute`.
Future<List<M3uEntry>> parseM3uFile(String path) async {
  final parser = _M3uLineParser();
  await for (final line in File(path)
      .openRead()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())) {
    parser.addLine(line);
  }
  return parser.entries;
}

/// The live stream id in an M3U entry URL
/// (`{server}/live/{user}/{pass}/{streamId}.m3u8` or `.ts`), or null
/// when the URL is not a live stream (movie/series entries and
/// anything unparseable). Only the first path segment is trusted:
/// a `live` segment anywhere else is a channel name, not a route.
/// The same rule as the support's `_liveStreamIdFromM3uUrl`, kept
/// here so the isolate parser below can use it without importing the
/// support (which would be a circular import).
int? liveStreamIdFromM3uUrl(String url) {
  Uri? uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    return null;
  }
  final segments = uri.pathSegments;
  if (segments.isEmpty || segments.first != 'live') return null;
  final last = segments.last;
  final dot = last.lastIndexOf('.');
  final idText = dot > 0 ? last.substring(0, dot) : last;
  return int.tryParse(idText);
}

/// Message for [collectM3uLiveTvgIds]: the playlist file to read, and
/// the group titles of hidden categories, whose live entries are
/// dropped before they reach the map (1.3.26 §69 — the channel loop
/// already skips hidden categories, so the map holds visible rows
/// only). A record so `compute` can carry both pieces as one message.
typedef M3uLiveTvgIdsRequest = ({String path, Set<String> hiddenGroupTitles});

/// Streaming line parser for the M3U tvg-id check (1.3.26 §69):
/// reads the playlist line by line and returns live stream-id ->
/// tvg-id pairs only — movies and series entries are dropped, as are
/// entries with no tvg-id and entries whose group-title is hidden.
/// Reuses [_parseAttributes] and the `#EXTINF`-then-URL state machine
/// of [parseM3u], so the two parsers can never disagree about what an
/// entry is. Bounded memory regardless of playlist size: one line at
/// a time plus one map entry per live channel with an id — the 300 MB
/// playlist is never held as a String or a 300k-entry list. A
/// top-level function so it can run under `compute`. Malformed UTF-8
/// bytes become the replacement character instead of failing the
/// whole check (the old whole-file read threw on them).
Future<Map<int, String>> collectM3uLiveTvgIds(M3uLiveTvgIdsRequest request) async {
  final out = <int, String>{};
  Map<String, String>? pendingAttrs;
  await for (final line in File(request.path)
      .openRead()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.startsWith('#EXTINF')) {
      pendingAttrs = _parseAttributes(trimmed);
      continue;
    }
    if (trimmed.startsWith('#')) continue; // #EXTM3U, #EXTGRP, other comments
    // A bare URL line: pairs with the preceding EXTINF, or stands alone.
    final attrs = pendingAttrs;
    pendingAttrs = null;
    // 1.2.8 F1 (same rule as Xtream epg_channel_id): an empty
    // tvg-id="" is absent, not an id.
    final tvgId = switch (attrs?['tvg-id']) {
      final s? when s.isNotEmpty => s,
      _ => null,
    };
    if (tvgId == null) continue;
    final groupTitle = attrs?['group-title'];
    if (groupTitle != null && request.hiddenGroupTitles.contains(groupTitle)) continue;
    final streamId = liveStreamIdFromM3uUrl(trimmed);
    if (streamId == null) continue;
    out[streamId] = tvgId;
  }
  return out;
}
