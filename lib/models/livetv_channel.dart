import 'package:json_annotation/json_annotation.dart';

import '../i18n/strings.g.dart';
import '../services/iptv/xtream_api.dart';
import '../utils/json_utils.dart';

part 'livetv_channel.g.dart';

Object? _readChannelKey(Map json, String _) =>
    json['key'] as String? ??
    json['ratingKey'] as String? ??
    json['identifier'] as String? ??
    json['id'] as String? ??
    json['channelIdentifier'] as String? ??
    '';

Object? _readChannelIdentifier(Map json, String _) =>
    json['identifier'] as String? ?? json['id'] as String? ?? json['channelIdentifier'] as String?;

Object? _readChannelTitle(Map json, String _) => json['title'] as String? ?? json['callSign'] as String?;

Object? _readChannelNumber(Map json, String _) =>
    json['number'] as String? ??
    json['channelNumber'] as String? ??
    json['channelVcn']?.toString() ??
    json['vcn']?.toString();

Object? _readFavoriteChannelId(Map json, String _) => json['id'] as String? ?? json['key'] as String? ?? '';

String favoriteChannelKey(String source, String id) => '$source\u0000$id';

String liveTvChannelScopeKey(LiveTvChannel channel) =>
    '${channel.serverId ?? ''}\u0000${channel.liveDvrKey ?? ''}\u0000${channel.key}';

List<LiveTvChannel> filterLiveTvChannelsForFavorites({
  required List<LiveTvChannel> channels,
  required bool favoritesOnly,
  required bool favoritesLoaded,
  required Iterable<FavoriteChannel> favorites,
  required String Function(LiveTvChannel channel) sourceForChannel,
}) {
  if (!favoritesOnly || !favoritesLoaded) return channels;
  if (favorites.isEmpty) return const [];
  final channelMap = {
    for (final channel in channels) favoriteChannelKey(sourceForChannel(channel), channel.key): channel,
  };

  return [for (final favorite in favorites) ?channelMap[favorite.stableKey]];
}

@JsonSerializable(createToJson: false)
class LiveTvChannel {
  @JsonKey(readValue: _readChannelKey)
  final String key;
  @JsonKey(readValue: _readChannelIdentifier)
  final String? identifier;
  final String? callSign;
  @JsonKey(readValue: _readChannelTitle)
  final String? title;
  final String? thumb;
  final String? art;
  @JsonKey(readValue: _readChannelNumber)
  final String? number;
  @JsonKey(fromJson: flexibleBool)
  final bool hd;
  final String? lineup;
  final String? slug;
  @JsonKey(fromJson: flexibleBool)
  final bool? drm;

  @JsonKey(includeFromJson: false, includeToJson: false)
  final String? serverId;
  @JsonKey(includeFromJson: false, includeToJson: false)
  final String? serverName;
  @JsonKey(includeFromJson: false, includeToJson: false)
  final String? liveDvrKey;
  @JsonKey(includeFromJson: false, includeToJson: false)
  final String? liveTvSourceTitle;
  @JsonKey(includeFromJson: false, includeToJson: false)
  final String? favoriteSource;
  @JsonKey(includeFromJson: false, includeToJson: false)
  final String? favoriteStoreKey;

  /// True when the channel offers catch-up TV (Xtream `tv_archive = 1`).
  /// Set by the IPTV client at channel-build time; never serialized.
  @JsonKey(includeFromJson: false, includeToJson: false)
  final bool hasCatchUp;

  /// How far back the channel's catch-up archive reaches, in seconds
  /// (Xtream `tv_archive_duration`, already converted to seconds by the
  /// client). Null when the channel has no archive (M3U, Plex/Jellyfin)
  /// or the duration is unknown — the guide offers catch-up whenever
  /// [hasCatchUp] is true and the programme start is inside this window
  /// (see [catchUpProgrammeInArchiveWindow]); an unknown duration fails
  /// open, and the player still clamps the offset to the session's own
  /// window ([liveTvCatchUpOffsetSeconds]). Set by the IPTV client at
  /// channel-build time; never serialized.
  @JsonKey(includeFromJson: false, includeToJson: false)
  final int? catchUpArchiveDurationSeconds;

  /// The live TV category this channel belongs to (build #17): the
  /// Xtream category id, or the M3U group title. Set by the IPTV client
  /// at channel-build time; never serialized. Null for Plex/Jellyfin/
  /// Emby channels, which have no IPTV category — they never match a
  /// selected guide category. The guide category picker filters on it.
  @JsonKey(includeFromJson: false, includeToJson: false)
  final String? categoryId;

  LiveTvChannel({
    required this.key,
    this.identifier,
    this.callSign,
    this.title,
    this.thumb,
    this.art,
    this.number,
    this.hd = false,
    this.lineup,
    this.slug,
    this.drm,
    this.serverId,
    this.serverName,
    this.liveDvrKey,
    this.liveTvSourceTitle,
    this.favoriteSource,
    this.favoriteStoreKey,
    this.hasCatchUp = false,
    this.catchUpArchiveDurationSeconds,
    this.categoryId,
  });

  factory LiveTvChannel.fromJson(Map<String, dynamic> json) => _$LiveTvChannelFromJson(json);

  /// One [LiveTvChannel] for one Xtream live stream (1.6.32): the single
  /// definition of how a stream becomes a guide channel, shared by the
  /// client's memo path and by the search index's background guide
  /// materialization — the two must agree, or the guide would show
  /// different rows depending on which path served it.
  factory LiveTvChannel.fromXtreamStream(
    XtreamLiveStream stream, {
    required String serverId,
    required String serverName,
  }) =>
      LiveTvChannel(
        key: '${stream.streamId}',
        identifier: stream.epgChannelId,
        title: stream.name,
        thumb: stream.streamIcon,
        serverId: serverId,
        serverName: serverName,
        // Visible catch-up badge in the guide (tv_archive = 1).
        hasCatchUp: stream.tvArchive,
        // Archive-window clamp (1.2.19 L-47): the guide only offers catch-up
        // for programmes inside tv_archive_duration.
        catchUpArchiveDurationSeconds: stream.tvArchive ? stream.tvArchiveDuration : null,
        // Guide category picker (build #17): the Xtream category id.
        categoryId: stream.categoryId,
      );

  LiveTvChannel copyWith({
    String? serverId,
    String? serverName,
    String? liveDvrKey,
    String? liveTvSourceTitle,
    String? favoriteSource,
    String? favoriteStoreKey,
    bool? hasCatchUp,
    int? catchUpArchiveDurationSeconds,
    String? categoryId,
  }) {
    return LiveTvChannel(
      key: key,
      identifier: identifier,
      callSign: callSign,
      title: title,
      thumb: thumb,
      art: art,
      number: number,
      hd: hd,
      lineup: lineup,
      slug: slug,
      drm: drm,
      serverId: serverId ?? this.serverId,
      serverName: serverName ?? this.serverName,
      liveDvrKey: liveDvrKey ?? this.liveDvrKey,
      liveTvSourceTitle: liveTvSourceTitle ?? this.liveTvSourceTitle,
      favoriteSource: favoriteSource ?? this.favoriteSource,
      favoriteStoreKey: favoriteStoreKey ?? this.favoriteStoreKey,
      hasCatchUp: hasCatchUp ?? this.hasCatchUp,
      catchUpArchiveDurationSeconds: catchUpArchiveDurationSeconds ?? this.catchUpArchiveDurationSeconds,
      categoryId: categoryId ?? this.categoryId,
    );
  }

  /// Display name: prefer callSign, fallback to title
  String get displayName =>
      callSign ?? title ?? (number == null ? t.liveTv.unknownChannel : t.liveTv.channelNumber(number: number!));

  /// Whether a programme starting at [beginsAtEpoch] may be offered
  /// catch-up on this channel (1.2.19 L-47, archive-window clamp): the
  /// programme must already have started, and — when the archive
  /// duration is known — its start must still lie inside the archive
  /// window (`now - tv_archive_duration`). A programme older than the
  /// window has no recording to fetch: offering catch-up for it only
  /// produces a 404 that looks like a missing recording (or, with the
  /// player's offset clamp, silently plays the wrong, newer programme).
  /// An unknown duration fails open — the player still clamps the offset
  /// to the session's own window. Pure, unit-tested.
  bool offersCatchUpForProgramStart(int beginsAtEpoch, {int? nowEpoch}) {
    final now = nowEpoch ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (!hasCatchUp || beginsAtEpoch >= now) return false;
    final window = catchUpArchiveDurationSeconds;
    if (window == null) return true;
    return beginsAtEpoch >= now - window;
  }
}

/// A channel entry in the Plex cloud favorites list.
/// Stored at `https://epg.provider.plex.tv/settings/favoriteChannels`.
@JsonSerializable(createToJson: false)
class FavoriteChannel {
  @JsonKey(defaultValue: '')
  final String source;
  @JsonKey(readValue: _readFavoriteChannelId)
  final String id;
  final String? title;
  final String? thumb;
  final String? vcn;

  FavoriteChannel({required this.source, required this.id, this.title, this.thumb, this.vcn});

  factory FavoriteChannel.fromJson(Map<String, dynamic> json) => _$FavoriteChannelFromJson(json);

  String get stableKey => favoriteChannelKey(source, id);

  Map<String, dynamic> toJson() => {
    'source': source,
    'id': id,
    if (title != null) 'title': title,
    if (thumb != null) 'thumb': thumb,
    if (vcn != null) 'vcn': vcn,
  };

  /// Create from a [LiveTvChannel] and a source URI.
  factory FavoriteChannel.fromLiveTvChannel(LiveTvChannel channel, String source) {
    return FavoriteChannel(
      source: source,
      id: channel.key,
      title: channel.title ?? channel.callSign,
      thumb: channel.thumb,
      vcn: channel.number,
    );
  }
}
