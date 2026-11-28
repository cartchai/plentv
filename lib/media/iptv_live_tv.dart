import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connection/connection.dart';
import '../exceptions/media_server_exceptions.dart';
import '../i18n/strings.g.dart';
import '../media/live_tv_support.dart';
import '../media/media_source_info.dart';
import '../models/livetv_capture_buffer.dart';
import '../models/livetv_channel.dart';
import '../models/livetv_program.dart';
import '../models/transcode_quality_preset.dart';
import '../services/favorite_channels_repository.dart';
import '../services/device_performance.dart';
import '../services/storage_health.dart';
import '../services/iptv/iptv_call_pacer.dart';
import '../services/iptv/iptv_epg_sources.dart';
import '../services/iptv/iptv_feed_row_store.dart';
import '../services/iptv/iptv_heavy_work_gate.dart';
import '../services/iptv/iptv_feed_refresh_activity.dart';
import '../services/iptv/iptv_playback_activity.dart';
import '../services/iptv/m3u_parser.dart';
import '../services/iptv/metered_network.dart';
import '../services/iptv/warp_tunnel_service.dart';
import '../services/iptv/xmltv_parser.dart';
import '../services/iptv/xtream_api.dart';
import '../services/lowend/epg_cadence_log.dart';
import '../services/lowend/phase_rss_sampler.dart';
import '../services/lowend/slow_op_log.dart';
import '../services/lowend/thermal_probe.dart';
import '../services/settings_service.dart';
import '../utils/app_logger.dart';
import '../utils/media_server_http_client.dart' show AbortController;
import 'iptv_client.dart';

/// The XMLTV feed download was deferred by the playback gate (build #28,
/// 1.1.2 D1b): no feed exists yet and a stream is playing. This is NOT a
/// failure and NOT a genuine empty — the fetch returns empty without
/// caching, so the channel reloads when playback stops. It extends
/// [StateError] with the same message the gate has always thrown, so
/// existing message-based handling still matches.
class _EpgFeedDeferred extends StateError {
  _EpgFeedDeferred(String cacheKey) : super('XMLTV feed for $cacheKey deferred while a stream is playing');
}

/// Guide coverage over the channels the guide has loaded EPG for (build
/// #17, §10): how many have programmes, split by the source that served
/// them, plus the tvg-id match rate over the same set — the numbers the
/// phone needs to prove the guide is fuller. `feedChannelIds` is the
/// distinct channel-id count of the last loaded XMLTV feed (0 when no
/// feed has loaded yet); it is context, not a denominator.
class IptvGuideCoverage {
  final int total;
  final int withPrograms;
  final int fromFeedById;
  final int fromFeedByName;
  final int fromShortEpg;

  /// 1.2.20 (c): rows whose programmes mix short-EPG with feed
  /// programmes (the feed filled an untitled programme or a gap).
  final int fromMixed;
  final int none;
  final int unknown;
  final int feedChannelIds;

  /// Channels with programmes per configured source id (PlezTV 1.2.0) —
  /// the per-source breakdown of the coverage diagnostic (§3.4). Only
  /// entries that recorded a source id are counted.
  final Map<String, int> bySourceId;

  const IptvGuideCoverage({
    required this.total,
    required this.withPrograms,
    required this.fromFeedById,
    required this.fromFeedByName,
    required this.fromShortEpg,
    this.fromMixed = 0,
    required this.none,
    required this.unknown,
    required this.feedChannelIds,
    this.bySourceId = const {},
  });

  const IptvGuideCoverage.empty()
    : total = 0,
      withPrograms = 0,
      fromFeedById = 0,
      fromFeedByName = 0,
      fromShortEpg = 0,
      fromMixed = 0,
      none = 0,
      unknown = 0,
      feedChannelIds = 0,
      bySourceId = const {};

  /// Share of loaded channels with programmes, 0–100 (0 when none loaded).
  int get percentWithPrograms => total == 0 ? 0 : (withPrograms * 100 / total).round();
}

/// Quality/format markers that say nothing about which channel it is
/// (jellyfin-tentacle `_MARKERS`): dropped as whole words when the name
/// is reduced to a key. A marker inside a word ("HDNet") is kept.
const _epgNameMarkers = <String>{
  'hd',
  'fhd',
  'uhd',
  'sd',
  'hq',
  'lq',
  '4k',
  '8k',
  'hdr',
  'hevc',
  'h264',
  'h265',
  'raw',
  '1080p',
  '1080i',
  '720p',
  '576i',
  '50fps',
  '60fps',
};

/// Generic words that say nothing about which channel it is (1.2.14
/// G4): dropped as whole words when the name is reduced to a key, so
/// "FOX NEWS" meets a feed entry called "FOX NEWS CHANNEL". Mirrors
/// [_epgIdentityDrop] (which drops the same two words, plus 'bk').
/// A word inside a larger word ("TV5") is kept — the split is on
/// non-alphanumerics, so "TV5" is one word. "TV 5" does reduce to "5",
/// which still needs the country gate + uniqueness to match.
const _epgNameGenericWords = <String>{'channel', 'tv'};

/// Loose-key word forms (jellyfin-tentacle `_WORD_FORMS`): only the
/// loose pass reads "sports" as "sport".
const _epgLooseWordForms = <String, String>{'sports': 'sport'};

/// Unicode folding (a hand-rolled NFKC + NFKD for the cases channel
/// names actually carry — Dart has no built-in normalization):
/// superscript letters/digits (so "ᴿᴬᵂ" reads as "RAW", a marker),
/// and accented Latin letters (so "Šiauliai" meets "Siauliai").
/// Full-width ASCII is handled by range in [_epgFoldUnicode], not
/// this map. Values are the lowercase base form; multi-letter
/// expansions ("æ" -> "ae", "ß" -> "ss") are kept as strings.
const _epgUnicodeFold = <int, String>{
  0xB2: '2',
  0xB3: '3',
  0xB9: '1',
  0xC0: 'a',
  0xC1: 'a',
  0xC2: 'a',
  0xC3: 'a',
  0xC4: 'a',
  0xC5: 'a',
  0xC6: 'ae',
  0xC7: 'c',
  0xC8: 'e',
  0xC9: 'e',
  0xCA: 'e',
  0xCB: 'e',
  0xCC: 'i',
  0xCD: 'i',
  0xCE: 'i',
  0xCF: 'i',
  0xD0: 'd',
  0xD1: 'n',
  0xD2: 'o',
  0xD3: 'o',
  0xD4: 'o',
  0xD5: 'o',
  0xD6: 'o',
  0xD8: 'o',
  0xD9: 'u',
  0xDA: 'u',
  0xDB: 'u',
  0xDC: 'u',
  0xDD: 'y',
  0xDE: 'th',
  0xDF: 'ss',
  0xE0: 'a',
  0xE1: 'a',
  0xE2: 'a',
  0xE3: 'a',
  0xE4: 'a',
  0xE5: 'a',
  0xE6: 'ae',
  0xE7: 'c',
  0xE8: 'e',
  0xE9: 'e',
  0xEA: 'e',
  0xEB: 'e',
  0xEC: 'i',
  0xED: 'i',
  0xEE: 'i',
  0xEF: 'i',
  0xF0: 'd',
  0xF1: 'n',
  0xF2: 'o',
  0xF3: 'o',
  0xF4: 'o',
  0xF5: 'o',
  0xF6: 'o',
  0xF8: 'o',
  0xF9: 'u',
  0xFA: 'u',
  0xFB: 'u',
  0xFC: 'u',
  0xFD: 'y',
  0xFE: 'th',
  0xFF: 'y',
  0x100: 'a',
  0x101: 'a',
  0x102: 'a',
  0x103: 'a',
  0x104: 'a',
  0x105: 'a',
  0x106: 'c',
  0x107: 'c',
  0x108: 'c',
  0x109: 'c',
  0x10A: 'c',
  0x10B: 'c',
  0x10C: 'c',
  0x10D: 'c',
  0x10E: 'd',
  0x10F: 'd',
  0x110: 'd',
  0x111: 'd',
  0x112: 'e',
  0x113: 'e',
  0x114: 'e',
  0x115: 'e',
  0x116: 'e',
  0x117: 'e',
  0x118: 'e',
  0x119: 'e',
  0x11A: 'e',
  0x11B: 'e',
  0x11C: 'g',
  0x11D: 'g',
  0x11E: 'g',
  0x11F: 'g',
  0x120: 'g',
  0x121: 'g',
  0x122: 'g',
  0x123: 'g',
  0x124: 'h',
  0x125: 'h',
  0x126: 'h',
  0x127: 'h',
  0x128: 'i',
  0x129: 'i',
  0x12A: 'i',
  0x12B: 'i',
  0x12C: 'i',
  0x12D: 'i',
  0x12E: 'i',
  0x12F: 'i',
  0x130: 'i',
  0x131: 'i',
  0x132: 'ij',
  0x133: 'ij',
  0x134: 'j',
  0x135: 'j',
  0x136: 'k',
  0x137: 'k',
  0x138: 'k',
  0x139: 'l',
  0x13A: 'l',
  0x13B: 'l',
  0x13C: 'l',
  0x13D: 'l',
  0x13E: 'l',
  0x13F: 'l',
  0x140: 'l',
  0x141: 'l',
  0x142: 'l',
  0x143: 'n',
  0x144: 'n',
  0x145: 'n',
  0x146: 'n',
  0x147: 'n',
  0x148: 'n',
  0x14A: 'n',
  0x14B: 'n',
  0x14C: 'o',
  0x14D: 'o',
  0x14E: 'o',
  0x14F: 'o',
  0x150: 'o',
  0x151: 'o',
  0x152: 'oe',
  0x153: 'oe',
  0x154: 'r',
  0x155: 'r',
  0x156: 'r',
  0x157: 'r',
  0x158: 'r',
  0x159: 'r',
  0x15A: 's',
  0x15B: 's',
  0x15C: 's',
  0x15D: 's',
  0x15E: 's',
  0x15F: 's',
  0x160: 's',
  0x161: 's',
  0x162: 't',
  0x163: 't',
  0x164: 't',
  0x165: 't',
  0x166: 't',
  0x167: 't',
  0x168: 'u',
  0x169: 'u',
  0x16A: 'u',
  0x16B: 'u',
  0x16C: 'u',
  0x16D: 'u',
  0x16E: 'u',
  0x16F: 'u',
  0x170: 'u',
  0x171: 'u',
  0x172: 'u',
  0x173: 'u',
  0x174: 'w',
  0x175: 'w',
  0x176: 'y',
  0x177: 'y',
  0x178: 'y',
  0x179: 'z',
  0x17A: 'z',
  0x17B: 'z',
  0x17C: 'z',
  0x17D: 'z',
  0x17E: 'z',
  0x2B0: 'h',
  0x2B2: 'j',
  0x2B3: 'r',
  0x2B7: 'w',
  0x2B8: 'y',
  0x2E1: 'l',
  0x2E2: 's',
  0x2E3: 'x',
  0x1D2C: 'a',
  0x1D2E: 'b',
  0x1D30: 'd',
  0x1D31: 'e',
  0x1D33: 'g',
  0x1D34: 'h',
  0x1D35: 'i',
  0x1D36: 'j',
  0x1D37: 'k',
  0x1D38: 'l',
  0x1D39: 'm',
  0x1D3A: 'n',
  0x1D3C: 'o',
  0x1D3E: 'p',
  0x1D3F: 'r',
  0x1D40: 't',
  0x1D41: 'u',
  0x1D42: 'w',
  0x1D43: 'a',
  0x1D47: 'b',
  0x1D48: 'd',
  0x1D49: 'e',
  0x1D4D: 'g',
  0x1D4F: 'k',
  0x1D50: 'm',
  0x1D52: 'o',
  0x1D56: 'p',
  0x1D57: 't',
  0x1D58: 'u',
  0x1D5B: 'v',
  0x1D9C: 'c',
  0x1DA0: 'f',
  0x1DBB: 'z',
  0x2070: '0',
  0x2071: 'i',
  0x2074: '4',
  0x2075: '5',
  0x2076: '6',
  0x2077: '7',
  0x2078: '8',
  0x2079: '9',
  0x207A: '+',
  0x207B: '-',
  0x207C: '=',
  0x207D: '(',
  0x207E: ')',
  0x207F: 'n',
  0x2C7D: 'v',
};

/// ISO 639-1 language codes that are no ISO 3166-1 country code
/// (jellyfin-tentacle `_LANGUAGE_ONLY`): "EN:" names English, no
/// country — so "EN: X" has no country and is never gated as foreign.
/// "uk" (the United Kingdom) and "eu" (Europe) are deliberately not
/// in this list.
const _epgLanguageOnlyCodes = <String>{
  'aa', 'ab', 'ak', 'an', 'av', 'ay', 'ce', 'cs', 'da', 'dv', 'el', 'en', 'eo', 'fa', 'ff', 'fy', 'gv', 'ha', 'he', 'hi', 'ho', 'hy', 'hz', 'ia', 'ig', 'ii', 'ik', 'iu', 'ja', 'jv', 'ka', 'kj', 'kk', 'kl', 'ko', 'ks', 'ku', 'kv', 'lg', 'ln', 'lo', 'mi', 'nb', 'nd', 'nn', 'nv', 'ny', 'oc', 'oj', 'or', 'os', 'pi', 'qu', 'rm', 'rn', 'sq', 'su', 'sw', 'ta', 'te', 'ti', 'ts', 'ty', 'ur', 'vo', 'wa', 'wo', 'xh', 'yi', 'yo', 'zh', 'zu',
};

/// Country codes the provider uses as LANGUAGE tags, not countries
/// (1.3.24 §67 F7): "AR|" is Arabic, not Argentina — 'ar' IS a valid
/// ISO 3166-1 country code, so it is deliberately NOT in
/// [_epgLanguageOnlyCodes] and [epgChannelCountry] still returns 'ar'
/// for it. The tier-5 country gate relaxes for these codes only: the
/// feed carries no in-country copy for a language-tagged channel, so
/// gating would block it forever. Only 'ar' is observed — add another
/// code only when a phone log proves the provider uses it as a
/// language tag.
const _epgProviderLanguageTags = <String>{'ar'};

/// Whether [country] (lowercase, from [epgChannelCountry]) is a
/// provider language tag rather than a real country (1.3.24 §67 F7).
bool _epgIsProviderLanguageTag(String country) => _epgProviderLanguageTags.contains(country);

/// One country, two spellings (jellyfin-tentacle `_SAME_COUNTRY`).
const _epgSameCountry = <String, String>{'uk': 'gb', 'usa': 'us'};

/// ISO 3166-1 alpha-2 country codes (1.3.30): a leading tag is only a
/// country when its code is in this set. The provider also uses
/// 2-letter codes as category prefixes — `TV|` is a category, not
/// Tuvalu — so `tv` is deliberately NOT in this set. `uk` is included
/// (the provider's spelling of GB; mapped by [_epgSameCountry]). A
/// code in [_epgLanguageOnlyCodes] still counts as a language, not a
/// country, in [epgChannelCountry]; this set only decides whether a
/// tag is a country-shaped code at all.
const _epgCountryCodes = <String>{
  'ad', 'ae', 'af', 'ag', 'ai', 'al', 'am', 'ao', 'aq', 'ar', 'as', 'at', 'au', 'aw', 'ax', 'az',
  'ba', 'bb', 'bd', 'be', 'bf', 'bg', 'bh', 'bi', 'bj', 'bl', 'bm', 'bn', 'bo', 'bq', 'br', 'bs', 'bt', 'bv', 'bw', 'by', 'bz',
  'ca', 'cc', 'cd', 'cf', 'cg', 'ch', 'ci', 'ck', 'cl', 'cm', 'cn', 'co', 'cr', 'cu', 'cv', 'cw', 'cx', 'cy', 'cz',
  'de', 'dj', 'dk', 'dm', 'do', 'dz',
  'ec', 'ee', 'eg', 'eh', 'er', 'es', 'et',
  'fi', 'fj', 'fk', 'fm', 'fo', 'fr',
  'ga', 'gb', 'gd', 'ge', 'gf', 'gg', 'gh', 'gi', 'gl', 'gm', 'gn', 'gp', 'gq', 'gr', 'gs', 'gt', 'gu', 'gw', 'gy',
  'hk', 'hm', 'hn', 'hr', 'ht', 'hu',
  'id', 'ie', 'il', 'im', 'in', 'io', 'iq', 'ir', 'is', 'it',
  'je', 'jm', 'jo', 'jp',
  'ke', 'kg', 'kh', 'ki', 'km', 'kn', 'kp', 'kr', 'kw', 'ky', 'kz',
  'la', 'lb', 'lc', 'li', 'lk', 'lr', 'ls', 'lt', 'lu', 'lv', 'ly',
  'ma', 'mc', 'md', 'me', 'mf', 'mg', 'mh', 'mk', 'ml', 'mm', 'mn', 'mo', 'mp', 'mq', 'mr', 'ms', 'mt', 'mu', 'mv', 'mw', 'mx', 'my', 'mz',
  'na', 'nc', 'ne', 'nf', 'ng', 'ni', 'nl', 'no', 'np', 'nr', 'nu', 'nz',
  'om',
  'pa', 'pe', 'pf', 'pg', 'ph', 'pk', 'pl', 'pm', 'pn', 'pr', 'ps', 'pt', 'pw', 'py',
  'qa',
  're', 'ro', 'rs', 'ru', 'rw',
  'sa', 'sb', 'sc', 'sd', 'se', 'sg', 'sh', 'si', 'sj', 'sk', 'sl', 'sm', 'sn', 'so', 'sr', 'ss', 'st', 'sv', 'sx', 'sy', 'sz',
  'tc', 'td', 'tf', 'tg', 'th', 'tj', 'tk', 'tl', 'tm', 'tn', 'to', 'tr', 'tt', 'tw', 'tz',
  'ua', 'ug', 'um', 'us', 'uy', 'uz',
  'va', 'vc', 've', 'vg', 'vi', 'vn', 'vu',
  'wf', 'ws',
  'ye', 'yt',
  'za', 'zm', 'zw',
  'uk',
};

/// Provider category prefixes that look like 2-letter country codes
/// but are not countries (1.3.30): `TV|` is a category prefix on
/// channel names, never a country — without this, a US channel named
/// `TV| ST. LOUIS, MO ...` parses its country as `tv` and every US
/// candidate ranks as foreign.
const _epgCategoryTagPrefixes = <String>{'tv'};

/// Three-letter tags the provider uses for countries (1.3.30):
/// `CND|` is Canada, `USA` is the United States. Mapped to the
/// 2-letter code before any country check.
const _epgThreeLetterCountry = <String, String>{'cnd': 'ca', 'usa': 'us'};

/// US state and Canadian province/territory codes, for a trailing
/// `, <ST>` state/province suffix on a feed id or display name
/// (1.3.30): `loc.FOX (KMSP-DT9) Minneapolis, MN` is US,
/// `ca.CHCH Hamilton, ON` is Canadian.
const _epgUsStateCodes = <String>{
  'al', 'ak', 'az', 'ar', 'ca', 'co', 'ct', 'dc', 'de', 'fl', 'ga', 'hi', 'id', 'il', 'in', 'ia', 'ks', 'ky', 'la', 'me', 'md', 'ma', 'mi', 'mn', 'ms', 'mo', 'mt', 'ne', 'nv', 'nh', 'nj', 'nm', 'ny', 'nc', 'nd', 'oh', 'ok', 'or', 'pa', 'ri', 'sc', 'sd', 'tn', 'tx', 'ut', 'vt', 'va', 'wa', 'wv', 'wi', 'wy',
};
const _epgCaProvinceCodes = <String>{
  'on', 'qc', 'bc', 'ab', 'mb', 'sk', 'ns', 'nb', 'nl', 'pe', 'yt', 'nt', 'nu',
};

/// A leading country/language tag (jellyfin-tentacle `_PREFIX_RE`,
/// extended with a dash delimiter so "US - CNN HD" strips like
/// "US: CNN HD" does — the provider shape §5 row 2 carries).
/// Two-letter codes (plus USA/EXYU/LATAM/ARAB), so a brand such as
/// "CNN: International" keeps its name. Applied after lowercasing.
final _epgPrefixRegExp = RegExp(
  r"^\s*[|\[(]?\s*(?:[a-z]{2}(?:[ /-][a-z]{2})?|usa|exyu|latam|arab)\s*(?:-\s+|[|\]):]\s*)",
);

/// A leading tier tag (jellyfin-tentacle `_TIER_RE`): "VIP:" / "NOW:".
/// Loose pass only — the main key keeps them, so "NOW: TNT SPORT 1"
/// and "TNT SPORT 1" are different names until the fallback.
final _epgTierTagRegExp = RegExp(r"^\s*[|\[(]?\s*(?:vip|now)\s*[|\]):]\s*");

/// The country a leading tag names (jellyfin-tentacle `_COUNTRY_RE`,
/// same dash extension as [_epgPrefixRegExp]). 1.3.30: the first code
/// may be 3 letters (`CND|`, `USA`, `LAT|`) — the old 2-letter-only
/// capture made every 3-letter tag invisible, so a Canadian channel
/// carried no country at all. Whether a captured code is a country,
/// a language, or neither is decided in [_epgTagCodes], not here.
final _epgCountryRegExp = RegExp(
  r"^\s*[|\[(]?\s*([a-z]{2,3})(?:[ /-]([a-z]{2,3}))?\s*(?:-\s+|[|\]):])",
);

/// A trailing country suffix on a feed id (jellyfin-tentacle
/// `_ID_COUNTRY_RE`): ".uk" / ".us" / ".de".
final _epgIdCountryRegExp = RegExp(r'\.([a-z]{2})$');

/// A trailing `, <ST>` state/province suffix on a feed id or display
/// name (1.3.30): "Minneapolis, MN" / "Hamilton, ON".
final _epgStateSuffixRegExp = RegExp(r',\s*([a-z]{2})\s*$');

/// Words that say nothing about which channel it is when deciding
/// whether one feed id's display names are one channel
/// (jellyfin-tentacle `_IDENTITY_DROP`).
const _epgIdentityDrop = <String>{'bk', 'channel', 'tv'};

/// A trailing timeshift in a space-joined word list
/// (jellyfin-tentacle `_TIMESHIFT`): "+1" / "plus 1".
final _epgTimeshiftRegExp = RegExp(r'(?:\s+plus\s+\d{1,2})+$');

/// Fold full-width ASCII, superscripts and accented letters to plain
/// ASCII (see [_epgUnicodeFold]); everything else passes through.
/// Full-width space (U+3000) becomes a plain space.
String _epgFoldUnicode(String input) {
  final out = StringBuffer();
  for (final rune in input.runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      out.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0x3000) {
      out.write(' ');
    } else {
      out.write(_epgUnicodeFold[rune] ?? String.fromCharCode(rune));
    }
  }
  return out.toString();
}

/// The name's words, reduced the jellyfin-tentacle way: compatibility
/// forms first (so the prefix/marker steps can see them), accents off,
/// "&" reads as "and", "+" as "plus", split on non-alphanumerics,
/// markers dropped as whole words. [loose] also strips a leading tier
/// tag and reads "sports" as "sport".
List<String> _epgNameWords(String name, {required bool loose}) {
  var s = _epgFoldUnicode(name).toLowerCase();
  // HTML entities (dispatcharr): decode before "&" becomes "and".
  s = s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
  // Leading "|XX| " and "XX| " tags (the 1.2.4 rules, kept).
  s = s.replaceFirst(RegExp(r'^\|[^|]*\|\s*'), '');
  s = s.replaceFirst(RegExp(r'^[^|\s][^|]{0,15}\|\s*'), '');
  if (loose) s = s.replaceFirst(_epgTierTagRegExp, '');
  s = s.replaceFirst(_epgPrefixRegExp, '');
  // A trailing "@Feed" suffix, then a ".xx" country suffix.
  s = s.replaceFirst(RegExp(r'@[^\s]*$'), '');
  s = s.replaceFirst(RegExp(r'\.[a-z]{2}$'), '');
  s = s.replaceAll('&', ' and ').replaceAll('+', ' plus ');
  final words = s
      .split(RegExp(r'[^0-9a-z]+'))
      .where((w) => w.isNotEmpty && !_epgNameMarkers.contains(w) && !_epgNameGenericWords.contains(w))
      .toList(growable: false);
  // 1.2.8 F4: zero-padded numbers fold (beIN SPORT 01/02): an
  // all-digit word with a leading zero loses the zeros, so "01" meets
  // "1" and "007" meets "7". "101" has no leading zero and "0"/"00"
  // stay "0". Applies to both keys (strict and loose).
  final folded = words.map((w) {
    if (w.length > 1 && w.startsWith('0') && w.codeUnits.every((c) => c >= 0x30 && c <= 0x39)) {
      final stripped = w.replaceFirst(RegExp(r'^0+'), '');
      return stripped.isEmpty ? '0' : stripped;
    }
    return w;
  }).toList(growable: false);
  if (!loose) return folded;
  return folded.map((w) => _epgLooseWordForms[w] ?? w).toList(growable: false);
}

/// Reduce a channel name to the key two sources can be compared on
/// (1.2.5: jellyfin-tentacle's `channel_name_key`, ported — see
/// RESEARCH_EPG_MATCHING.md §2.1/§5): strip a leading country/
/// language tag ("CA:", "CA EN:", "US - ", "|US|", "[UK]"), drop
/// quality markers as words ("HD", "FHD", "4K", "RAW", "1080p"),
/// fold accents/superscripts, read "&" as "and", drop a trailing
/// ".xx" country suffix and "@Feed" suffix, drop spaces. "US - CNN HD"
/// and "CNN.us" both reduce to "cnn"; "Comedy Central HD" and
/// "Comedy Central" both reduce to "comedycentral". No fuzzy matching:
/// the reduced strings must be exactly equal.
///
/// Deviation from the template (verified against the cloned
/// `channel_names.py`): the template's key alone does NOT meet §5 rows
/// 2, 3, 5 and 7 — its prefix regex has no dash delimiter ("US - "
/// survives) and it never strips the ".xx" country suffix ("CNN.us"
/// keeps "us"). The dash delimiter and the suffix strip are PlenTV
/// additions, and they are what the §5 table tests.
///
/// Public (not test-only): the Assign picker normalizes its search
/// with this, so typing "cnn" finds "CNN.us".
String normalizeEpgChannelName(String name) => _epgNameWords(name, loose: false).join();

/// The loose key (jellyfin-tentacle `loose_name_key`): the main key
/// with a leading tier tag ("VIP:" / "NOW:") stripped and "sports"
/// read as "sport". Fallback only — folded into the main key it would
/// join channels of different countries.
@visibleForTesting
String looseEpgChannelNameKey(String name) => _epgNameWords(name, loose: true).join();

/// The main key with "sports" read as "sport" (1.2.22 §64.2): the main
/// key alone does not fold sports→sport — only the loose key does — so
/// a playlist "SKY SPORT NEWS" and a feed "Sky Sports News" key
/// differently ("skysportnews" vs "skysportsnews") and tier 5 misses.
/// The folded form is indexed ALONGSIDE the main key (see
/// [_channelsByDisplayName]/[_channelsByNormalizedName]) and tier 5
/// queries both forms, so either spelling finds the other. The country
/// filter and the uniqueness gate still apply, so this never joins
/// channels of different countries. Unlike the loose key it does NOT
/// strip tier tags.
@visibleForTesting
String sportsFoldedEpgChannelNameKey(String name) =>
    _epgNameWords(name, loose: false).map((w) => _epgLooseWordForms[w] ?? w).join();

/// The words of [name] before the spaces are dropped (the main key).
@visibleForTesting
List<String> epgChannelNameWords(String name) => _epgNameWords(name, loose: false);

/// The words of [name] for the loose key.
@visibleForTesting
List<String> looseEpgChannelNameWords(String name) => _epgNameWords(name, loose: true);

List<String> _epgTagCodes(String name) {
  final match = _epgCountryRegExp.firstMatch(_epgFoldUnicode(name).toLowerCase());
  if (match == null) return const [];
  // 1.3.30: a captured code is only a tag when it is a known country,
  // a known language, or a known 3-letter country spelling. Anything
  // else is a brand (`FOX:`, `CNN:`), a region word (`LAT|`), or a
  // category prefix (`TV|`) — none of those is a country, and `TV|`
  // in particular must never parse as one.
  return [match.group(1), match.group(2)]
      .whereType<String>()
      .where((code) => !_epgCategoryTagPrefixes.contains(code) && (_epgCountryCodes.contains(code) || _epgLanguageOnlyCodes.contains(code) || _epgThreeLetterCountry.containsKey(code)))
      .map((code) => _epgThreeLetterCountry[code] ?? code)
      .toList(growable: false);
}

/// The leading tag's first code as a country, language codes included
/// (jellyfin-tentacle `_first_tag`).
String? _epgFirstTag(String name) {
  final codes = _epgTagCodes(name);
  if (codes.isEmpty) return null;
  return _epgSameCountry[codes[0]] ?? codes[0];
}

/// The country a provider's leading tag names: "CA EN: DISCOVERY HD"
/// -> "ca", "EN CA: X" -> "ca", "|UK| SKY ONE" -> "gb". Null without
/// a tag or with only a language ("EN: X" names English, no country).
@visibleForTesting
String? epgChannelCountry(String name) {
  for (final code in _epgTagCodes(name)) {
    if (!_epgLanguageOnlyCodes.contains(code)) return _epgSameCountry[code] ?? code;
  }
  return null;
}

/// The country a feed id's two-letter suffix names: "TNTSport1.uk" -> "gb".
/// 1.3.30: a `loc.` id is a US local station by construction, and a
/// trailing `, <ST>` state/province suffix names the country too
/// (`loc.FOX (KMSP-DT9) Minneapolis, MN` -> "us",
/// `ca.CHCH Hamilton, ON` -> "ca").
@visibleForTesting
String? epgFeedIdCountry(String feedId) {
  final folded = _epgFoldUnicode(feedId).toLowerCase();
  if (folded.startsWith('loc.')) return 'us';
  final match = _epgIdCountryRegExp.firstMatch(folded);
  if (match != null) {
    final code = match.group(1)!;
    return _epgSameCountry[code] ?? code;
  }
  return _epgStateSuffixCountry(folded);
}

/// The country a trailing `, <ST>` state/province suffix names
/// (1.3.30). Canadian provinces are unambiguous; a US state code that
/// is also an ISO country code (`CA` is California AND Canada, `AR`
/// is Arkansas AND Argentina) names nothing — neutral is safe, wrong
/// is not.
String? _epgStateSuffixCountry(String text) {
  final match = _epgStateSuffixRegExp.firstMatch(text.trim().toLowerCase());
  if (match == null) return null;
  final code = match.group(1)!;
  if (_epgCaProvinceCodes.contains(code)) return 'ca';
  if (_epgUsStateCodes.contains(code) && !_epgCountryCodes.contains(code)) return 'us';
  return null;
}

/// The countries an XMLTV channel belongs to: its id's two-letter
/// suffix and any tag its display names carry. A language tag counts
/// here, so such a channel never becomes another country's guide.
@visibleForTesting
Set<String> epgFeedChannelCountries(String feedId, List<String> displayNames) {
  final out = <String>{};
  final idCountry = epgFeedIdCountry(feedId);
  if (idCountry != null) out.add(idCountry);
  for (final name in displayNames) {
    // 1.3.30: a display name can carry the country as a trailing
    // `, <ST>` suffix too, not only as a leading tag.
    final country = _epgFirstTag(name) ?? _epgStateSuffixCountry(name);
    if (country != null) out.add(country);
  }
  return out;
}

/// Rank guide-channel candidates for the Assign EPG picker by
/// relevance to the channel being assigned (1.3.26 §69) — best
/// matches at the top, never alphabetical. The owner opened Assign
/// for a US FOX 2 and saw NL/AU/ISR/PL/FR channels first, in plain
/// alphabetical order, nothing to do with FOX 2.
///
/// The sort key, in order: (1) channel-id match — a guide channel
/// whose tvg-id matches the channel's id (exact, or a shared prefix
/// of at least 3 chars) ranks highest; (2) region correctness — a
/// candidate from the channel's country ranks above one from a
/// different country, and a candidate whose region cannot be
/// determined sits between them (neutral, not demoted); (3) name
/// word overlap — shared words between the channel name and the
/// candidate's display names + id; (4) xmltvId ascending, so the
/// order is deterministic.
///
/// Region sits above name even though the owner listed name second:
/// his own rule is that a candidate from the WRONG region must rank
/// below a region-matching candidate even if its name is closer — a
/// NL "FOX 2" with more shared words must never top a US "FOX 2".
/// An exact id match still beats region (the feed id IS the
/// channel's declared id). The channel country comes from its name
/// tag first, then its epg_channel_id / tvg-id suffix; when neither
/// carries a country the region defaults to 'us' (1.3.30 — the
/// provider feed is US-centric), as the affiliate guess does.
@visibleForTesting
List<IptvEpgFeedChannel> rankEpgFeedChannels({
  required List<IptvEpgFeedChannel> entries,
  required String channelName,
  String? channelEpgId,
  String? channelTvgId,
}) {
  final channelCountry =
      epgChannelCountry(channelName) ??
      epgFeedIdCountry(channelEpgId ?? '') ??
      epgFeedIdCountry(channelTvgId ?? '');
  // 1.3.30: the provider feed is US-centric — a channel with no
  // detectable country is treated as US, as the affiliate guess
  // already does. Without this, a `TV|`-prefixed channel (whose
  // country used to misparse as `tv`) left region neutral for every
  // candidate and the ranking fell back to alphabetical.
  final homeCountry = channelCountry ?? 'us';
  final nameWords = epgChannelNameWords(channelName).toSet();
  int idScore(IptvEpgFeedChannel entry) {
    final entryId = entry.xmltvId.toLowerCase();
    for (final id in [channelEpgId, channelTvgId]) {
      if (id == null || id.isEmpty) continue;
      final lower = id.toLowerCase();
      if (entryId == lower) return 2;
      if (_epgSharedPrefixLength(entryId, lower) >= 3) return 1;
    }
    return 0;
  }

  int regionScore(IptvEpgFeedChannel entry) {
    final countries = epgFeedChannelCountries(entry.xmltvId, entry.displayNames);
    if (countries.isEmpty) return 0;
    return countries.contains(homeCountry) ? 1 : -1;
  }

  int nameScore(IptvEpgFeedChannel entry) {
    final words = <String>{};
    for (final name in entry.displayNames) {
      words.addAll(epgChannelNameWords(name));
    }
    words.addAll(epgChannelNameWords(entry.xmltvId));
    // 1.3.30: bare numbers (a channel number) and 1-letter words say
    // nothing about which channel it is — the matcher tier already
    // treats them as meaningless. Without this, 'FOX 2' shares '2'
    // with every '… 2' channel and the ranking ties.
    return words.intersection(nameWords).where((w) => w.length >= 2 && int.tryParse(w) == null).length;
  }

  final ranked = entries.toList(growable: false);
  ranked.sort((a, b) {
    final id = idScore(b).compareTo(idScore(a));
    if (id != 0) return id;
    final region = regionScore(b).compareTo(regionScore(a));
    if (region != 0) return region;
    final name = nameScore(b).compareTo(nameScore(a));
    if (name != 0) return name;
    return a.xmltvId.toLowerCase().compareTo(b.xmltvId.toLowerCase());
  });
  return ranked;
}

/// The length of the shared prefix of two lowercased ids, in code
/// units. Used by the Assign ranking: a guide channel whose id shares
/// at least 3 leading chars with the channel's id is a prefix match.
int _epgSharedPrefixLength(String a, String b) {
  var shared = 0;
  final length = a.length < b.length ? a.length : b.length;
  while (shared < length && a.codeUnitAt(shared) == b.codeUnitAt(shared)) {
    shared++;
  }
  return shared;
}

/// True when the names are one channel's (jellyfin-tentacle
/// `_one_channel`): the same after identity reduction, or one ending
/// the other ("HISTORY" / "DISCOVERY HISTORY" is a brand prefix).
/// "LRT" / "LRT PLUS" differ at the END: two channels. A name that is
/// only a number (a channel number) is not counted.
@visibleForTesting
bool epgDisplayNamesAreOneChannel(List<String> names, {bool loose = false}) {
  final wordsOf = loose ? looseEpgChannelNameWords : epgChannelNameWords;
  final ids = <String>{};
  for (final name in names) {
    final identity = _epgIdentity(name, wordsOf);
    if (identity.isEmpty || int.tryParse(identity) != null) continue;
    ids.add(identity);
  }
  final sorted = ids.toList(growable: false)..sort((a, b) => a.length.compareTo(b.length));
  if (sorted.length <= 1) return true;
  final longest = sorted.last;
  return sorted.sublist(0, sorted.length - 1).every((i) => i.length >= 3 && longest.endsWith(i));
}

String _epgIdentity(String name, List<String> Function(String) wordsOf) {
  final words = wordsOf(name).join(' ');
  final withoutTimeshift = words.replaceFirst(_epgTimeshiftRegExp, '');
  return withoutTimeshift.split(' ').where((w) => !_epgIdentityDrop.contains(w)).join();
}

/// True when [feedId] or any of [names] carries a timeshift ("+1" /
/// "plus 1"): the plain candidate wins over a timeshifted one when a
/// name names more than one feed channel.
bool _epgHasTimeshift(String feedId, List<String> names) {
  if (_epgTimeshiftRegExp.hasMatch(epgChannelNameWords(feedId).join(' '))) return true;
  for (final name in names) {
    if (_epgTimeshiftRegExp.hasMatch(epgChannelNameWords(name).join(' '))) return true;
  }
  return false;
}

/// True when an extra word of an affiliate-guess candidate is
/// number-like (1.3.29 tier 5.5): a bare number ('4', '12'), or the
/// channel word plus a number ('fox4', 'fox12' — the id token of a
/// numbered affiliate). A topic word ('news', 'east', 'kids') is
/// never number-like, which is what keeps a bare network word from
/// guessing a same-word spinoff channel.
bool _epgExtraWordIsNumberLike(String word, Set<String> channelWords) {
  if (word.isEmpty) return false;
  if (word.codeUnits.every((c) => c >= 0x30 && c <= 0x39)) return true;
  for (final channelWord in channelWords) {
    if (channelWord.length >= 2 && word.startsWith(channelWord)) {
      final rest = word.substring(channelWord.length);
      if (rest.isNotEmpty && rest.codeUnits.every((c) => c >= 0x30 && c <= 0x39)) return true;
    }
  }
  return false;
}

/// True when a feed id is a US local-affiliate id (1.3.30): the
/// provider's `loc.` prefix, or a parenthesized US callsign
/// (`(KTVT)`, `(KMSP-DT9)`). Checked against the RAW id string — the
/// display-name words must not be able to break it. A bare
/// callsign-looking word is NOT enough: `west` in `CBS West` would
/// qualify, and bare CBS would guess CBS West.
bool _epgIsLocalAffiliateId(String feedId) {
  final id = feedId.toLowerCase();
  if (id.startsWith('loc.')) return true;
  return _epgLocalCallsignRegExp.hasMatch(id);
}

/// A parenthesized US TV callsign: K or W followed by 2-4 letters,
/// optionally with a `-suffix` (the subchannel, e.g. `-DT9`).
final _epgLocalCallsignRegExp = RegExp(r'\([kw][a-z]{2,4}(-[a-z0-9]+)?\)');

/// Live TV for IPTV connections (M3U + Xtream Codes).
///
/// Channels come from the provider's live list; playback is a direct stream
/// URL (no tune/transcode negotiation). Catch-up is available only on
/// Xtream channels with `tv_archive = 1`, via the `/timeshift/` endpoint —
/// the session synthesizes its [CaptureBuffer] from `tv_archive_duration`
/// and rebuilds the URL for a requested offset. There is no DVR surface.
/// What one channel resolved to against one loaded guide (1.2.5):
/// the match (when the guide serves the channel in the window) or
/// the reason it did not (for the Reload diagnostics and the
/// without-guide overview). A match always carries in-window
/// programmes; a non-match carries an empty programme list and the
/// reason in [blockedReason].
typedef _GuideResolution = ({
  List<LiveTvProgram> programs,
  String? matchedXmltvId,
  String? matchMethod,
  String? sourceId,
  String? blockedReason,
  List<String> blockedCandidates,
});

/// Request for [_parseXmltvFeedFile] (1.2.18 S-1): everything the
/// worker-isolate feed parse needs, all sendable across the isolate
/// port (path + window epochs + retain ids + fetch time).
class _XmltvFeedParseRequest {
  final String path;
  final int windowFromEpoch;
  final int windowToEpoch;
  final Set<String> retainIds;
  final DateTime fetchedAt;

  /// Row-store build (1.2.20 (a)): the live DB path the isolate
  /// writes to (via its tmp path), plus the generation record. All
  /// null when no store is built (in-memory fallback, low storage,
  /// or the test seam).
  final String? storeDbPath;
  final String? storeSha256;
  final int? storeXmlMtimeMs;
  final int? storeXmlSizeBytes;

  const _XmltvFeedParseRequest({
    required this.path,
    required this.windowFromEpoch,
    required this.windowToEpoch,
    required this.retainIds,
    required this.fetchedAt,
    this.storeDbPath,
    this.storeSha256,
    this.storeXmlMtimeMs,
    this.storeXmlSizeBytes,
  });
}

/// Parse the XMLTV file at [request.path] and return the built guide
/// (1.2.18 S-1): a top-level function so `compute` can run it in a
/// worker isolate — the ~25 s main-isolate parse per feed load/slide
/// is the app's biggest CPU problem (round-2 §1). The file is read in
/// 64 KB sync chunks (the same pattern as
/// [IptvLiveTvSupport._readFileInChunks]: async dart:io never
/// completes inside `testWidgets` fake async, and the worker isolate
/// is real, so sync reads are safe there). The returned guide is
/// fully sendable (plain maps/sets/lists of [XmltvProgram], [Uint8List]
/// bitmaps); the derived match indexes are built in the isolate too,
/// by the guide constructor. The parse path touches no translations
/// and no loggers, so nothing in it depends on main-isolate state.
Future<_CachedXmltvGuide> _parseXmltvFeedFile(_XmltvFeedParseRequest request) async {
  final stats = XmltvParseStats();
  final windowFrom = DateTime.fromMillisecondsSinceEpoch(request.windowFromEpoch * 1000);
  final windowTo = DateTime.fromMillisecondsSinceEpoch(request.windowToEpoch * 1000);
  final accumulator = _XmltvGuideAccumulator(
    retainIds: request.retainIds,
    windowFrom: windowFrom,
    windowTo: windowTo,
  );
  // 1.2.20 (a): the row store is built in the same isolate pass as
  // the parse — every yielded programme goes to the writer as well as
  // the accumulator, so the store costs one extra SQLite insert per
  // programme instead of a second pass over the file. A failed build
  // never fails the parse (the writer swallows its own errors and
  // [finish] reports a null byte count).
  FeedRowStoreWriter? writer;
  if (request.storeDbPath != null && request.storeSha256 != null && request.storeXmlMtimeMs != null && request.storeXmlSizeBytes != null) {
    try {
      writer = FeedRowStoreWriter.open(
        tmpDbPath: IptvFeedRowStore.tmpDbPathForDbPath(request.storeDbPath!),
        dbPath: request.storeDbPath!,
        sha256: request.storeSha256!,
        xmlMtimeMs: request.storeXmlMtimeMs!,
        xmlSizeBytes: request.storeXmlSizeBytes!,
        windowFromEpoch: request.windowFromEpoch,
        windowToEpoch: request.windowToEpoch,
        fetchedAt: request.fetchedAt,
      );
    } catch (_) {
      writer = null;
    }
  }
  ({int buildMs, int? bytes})? storeResult;
  try {
    await for (final program in parseXmltvStream(
      IptvLiveTvSupport._readFileInChunks(File(request.path)),
      windowFromEpoch: request.windowFromEpoch,
      windowToEpoch: request.windowToEpoch,
      stats: stats,
    )) {
      accumulator.add(program);
      writer?.add(program);
    }
  } catch (_) {
    // The parse failed (corrupt file): publish no store for it.
    writer?.discard();
    rethrow;
  }
  if (writer != null) {
    storeResult = writer.finish(
      programCountByChannel: accumulator.programCounts,
      programSlotsByChannel: accumulator.programSlots,
      displayNames: stats.channelDisplayNames,
      channelIdsSeen: {...stats.channelIds, ...stats.programChannelIds},
      programsParsed: stats.programsSeen,
      channelsParsed: stats.channelIds.length,
      totalProgramCount: accumulator.totalPrograms,
    );
  }
  return accumulator.build(
    fetchedAt: request.fetchedAt,
    displayNames: stats.channelDisplayNames,
    programsParsed: stats.programsSeen,
    channelsParsed: stats.channelIds.length,
    channelIdsSeen: {...stats.channelIds, ...stats.programChannelIds},
    feedStoreBuildMs: storeResult?.buildMs,
    feedStoreBytes: storeResult?.bytes,
  );
}

/// One playlist stage failure with its own accounting (1.3.27 §P0-1):
/// the reason is already formatted for the dialog, plus the bytes that
/// arrived, the resume offset, and which budget fired — so the check
/// logs the facts instead of collapsing every timeout into "the
/// connection timed out".
class _M3uCheckFailure implements Exception {
  const _M3uCheckFailure({required this.reason, required this.bytesReceived, required this.resumeOffset, required this.budget});

  /// Already formatted for the dialog (a t.iptv.epgM3uTvgId* string).
  final String reason;

  /// Total bytes held when the failure fired (including resumed bytes).
  final int bytesReceived;

  /// The byte offset this attempt resumed from (0 on a fresh download).
  final int resumeOffset;

  /// Which budget fired: 'stall' (silence) or 'parse'.
  final String budget;
}

class IptvLiveTvSupport implements LiveTvSupport {
  final IptvClient _client;
  final FavoriteChannelsRepository _favoritesRepository;

  IptvLiveTvSupport(this._client, [FavoriteChannelsRepository? favoritesRepository])
    : _favoritesRepository = favoritesRepository ?? const SharedPreferencesFavoriteChannelsRepository() {
    // D1b (1.1.2): the playback-gate deferral used to claim "it retries
    // when playback stops" while nothing listened for playback stopping
    // (isPlayingNotifier had zero listeners). This listener is the
    // missing half: when playback stops and any channel was deferred,
    // the guide version bumps so visible rows re-fetch instead of
    // showing hour blocks until the next window change.
    IptvPlaybackActivity.instance.isPlayingNotifier.addListener(_onPlaybackActivityChanged);
  }

  String get _favoritesPrefsKey => 'iptv_fav_channels:${_client.connection.id}';

  /// Per-channel hide store (build #17, §9): `iptv_hidden_channels:<connectionId>`
  /// (SharedPreferences string list, same pattern as the favourites store
  /// above). A channel is identified by the SAME key derivation as
  /// favourites — the favorite source + channel key — so hide and favorite
  /// agree on identity. Per-connection, so hiding a Trex channel never
  /// hides a Plex one. The in-memory set is loaded lazily and kept in sync
  /// by [hideChannel]/[unhideChannel]; [isHiddenChannel] reads the
  /// in-memory set (empty until [loadHiddenChannels] has run — callers
  /// load first, then filter).
  String get _hiddenChannelsPrefsKey => 'iptv_hidden_channels:${_client.connection.id}';
  final Set<String> _hiddenChannelKeys = {};
  bool _hiddenChannelsLoaded = false;

  /// AbortControllers for EPG fetches currently in flight on this
  /// support (build #28): the per-channel short-EPG calls and the
  /// whole-guide XMLTV download. [cancelBackgroundWork] triggers every
  /// controller in this set when the app backgrounds, and
  /// [cancelEpgFetchForChannel] triggers one channel's. A controller is
  /// added when its fetch starts and removed when the fetch settles;
  /// aborting one that already settled is a no-op.
  final Set<AbortController> _activeEpgAborts = <AbortController>{};

  /// The in-flight EPG fetch per channel key (build #28) — the
  /// scroll-away cancel: when a guide row leaves the viewport, the tab
  /// cancels that channel's fetch instead of letting it run to
  /// completion unobserved. The feed download is shared, so it is NOT
  /// in this map — only the per-channel short-EPG call is.
  final Map<String, AbortController> _epgAbortsByChannel = <String, AbortController>{};

  /// 1.2.22 §63.2: per-channel in-flight join for EPG fetches (the same
  /// pattern as the 1.2.20 C3 warm-start join): concurrent fetches for
  /// the same channel and window share ONE network fetch instead of
  /// each opening its own short-EPG call — the storm in the 1.2.19 log
  /// was one channel's short-EPG requests aborting 7x in 8 s. Keyed by
  /// channel key + requested window; [force] bypasses the join (an
  /// explicit retry is its own fetch).
  final Map<String, Future<List<LiveTvProgram>>> _epgFetchInFlight = <String, Future<List<LiveTvProgram>>>{};

  /// Waiters per joined fetch key — how many callers are awaiting the
  /// shared fetch. [cancelEpgFetchForChannel] decrements it; the
  /// underlying request is aborted only when the last waiter leaves.
  final Map<String, int> _epgFetchWaiters = <String, int>{};

  /// Abort timestamps per channel, pruned to the last 10 s (1.2.22
  /// §63.2): 3 aborts in 10 s starts the cooldown below.
  final Map<String, List<DateTime>> _epgAbortHistory = <String, List<DateTime>>{};

  /// When a channel's abort cooldown lifts (1.2.22 §63.2): while set and
  /// in the future, a non-forced fetch throws a cancellation instead of
  /// opening a new short-EPG call — the guide tab treats it as "not
  /// failed" and refetches on scroll-back, so the row heals itself once
  /// the window passes.
  final Map<String, DateTime> _epgAbortCooldownUntil = <String, DateTime>{};

  /// Stop every in-flight EPG fetch on this support (build #28): the
  /// per-channel short-EPG calls and the whole-guide XMLTV download.
  /// Called by [IptvClient.cancelBackgroundWork] when the app
  /// backgrounds. Safe to call with nothing in flight (no-op). A
  /// cancellation is not a failure — it is never recorded as a refusal
  /// and never poisons the feed's negative cache (see
  /// [_loadXmltvGuide]).
  void cancelBackgroundWork() {
    for (final abort in _activeEpgAborts.toList()) {
      abort.abort();
    }
  }

  /// The feed gate (1.2.12, low-end item #4; 1.2.14 G1): on low-end
  /// hardware only, the whole-guide XMLTV download + parse never
  /// starts until a row actually needs it — the guide is served by
  /// the per-channel short-EPG call alone until then. The gate opens
  /// on the FIRST short-EPG miss: reaching [_fetchFeedPrograms]
  /// means a row's short-EPG already missed (every Xtream caller has
  /// a short-EPG result first), so deferring there would assert "no
  /// guide" for a feed never consulted — the 1.2.12 bug, where a cold
  /// guide open rendered "No information available" placeholders for
  /// up to 60 s on low-end. On non-low-end hardware there is no gate
  /// at all. The gate's memory purpose survives on low-end: a guide
  /// open where short-EPG answers every visible row never downloads
  /// the feed at all. The gate is Xtream-only — M3U has no
  /// short-EPG, so its feed IS the first source and is never gated.
  /// Scrolling past the first screen (see
  /// [noteGuideScrolledPastFirstScreen]) and the short-EPG settle
  /// (see [_releaseShortEpgSlot]) also open the gate, but both are
  /// redundant after G1 — the first miss opens it first.
  bool _epgFeedGateOpen = false;

  /// 1.2.19 L-7: the survival-tier no-feed skip logs once per launch
  /// (the skip itself runs per channel — logging per channel would
  /// spam the very log the skip is trying to keep small).
  bool _loggedTierNoFeed = false;

  /// Open the feed gate. One-way latch — the gate never closes again
  /// in this launch. Post-1.2.14 there are no gate-deferred channels
  /// to wake (the gate never defers — it opens on the first miss), so
  /// this no longer bumps the guide version: the only deferred
  /// channels are playback-deferred ones, healed by
  /// [_onPlaybackActivityChanged] when playback stops.
  void _openFeedGate() {
    if (_epgFeedGateOpen) return;
    _epgFeedGateOpen = true;
  }

  /// Called by the guide tab when the user scrolls past the first
  /// screen of the guide (1.2.12): opens the feed gate. Redundant
  /// after 1.2.14 G1 (the first short-EPG miss opens it first), but
  /// kept as a harmless extra opening path.
  void noteGuideScrolledPastFirstScreen() {
    _openFeedGate();
  }

  /// Stop one channel's in-flight EPG fetch (build #28) — the
  /// scroll-away cancel. A no-op when that channel has no fetch in
  /// flight. The shared feed download is untouched: other visible rows
  /// may still need it. An M3U channel has no per-channel call (its
  /// only fetch is the shared feed), so this is a no-op for M3U — the
  /// feed is stopped only by [cancelBackgroundWork].
  void cancelEpgFetchForChannel(String channelKey) {
    // 1.2.22 §63.2: the cancel withdraws ONE waiter's interest. The
    // underlying request is aborted only when the last waiter leaves —
    // a row scrolling away must not kill a fetch the detail sheet or
    // the player is still awaiting. (M3U has no per-channel call, so
    // there is no waiter and no abort for it — the shared feed download
    // is stopped only by [cancelBackgroundWork].)
    var waitersLeft = false;
    for (final key in _epgFetchInFlight.keys.where((k) => k.startsWith('$channelKey|')).toList()) {
      final remaining = (_epgFetchWaiters[key] ?? 1) - 1;
      if (remaining > 0) {
        _epgFetchWaiters[key] = remaining;
        waitersLeft = true;
      } else {
        _epgFetchWaiters.remove(key);
      }
    }
    if (waitersLeft) return;
    _epgAbortsByChannel.remove(channelKey)?.abort();
  }

  /// Record an aborted EPG fetch for [channelKey] (1.2.22 §63.2): 3
  /// aborts inside 10 s starts a cooldown until the first abort's
  /// window passes. One warning per burst — the cooldown is logged
  /// once, when it starts.
  void _noteEpgAbort(String channelKey) {
    final now = DateTime.now();
    final history = _epgAbortHistory.putIfAbsent(channelKey, () => <DateTime>[]);
    history.add(now);
    history.removeWhere((t) => now.difference(t) > const Duration(seconds: 10));
    if (history.length >= 3) {
      final until = history.first.add(const Duration(seconds: 10));
      final existing = _epgAbortCooldownUntil[channelKey];
      if (existing == null || now.isAfter(existing)) {
        _epgAbortCooldownUntil[channelKey] = until;
        appLogger.w('IPTV EPG fetch for channel $channelKey aborted ${history.length} times in 10 s — backing off until $until');
      }
    }
  }

  /// The favorite source string, factored out of [buildFavoriteChannelSource]
  /// so the hide key uses the identical derivation.
  String get _favoriteChannelSource => 'server://${_client.connection.id}/iptv';

  /// The stored hidden-channel key for [channel] — the same derivation as
  /// its favorite key.
  String hiddenKeyForChannel(LiveTvChannel channel) => favoriteChannelKey(_favoriteChannelSource, channel.key);

  /// The stored hidden keys (for the Settings → IPTV hidden-channels list).
  /// Empty until [loadHiddenChannels] has run.
  Set<String> get hiddenChannelKeys => Set.unmodifiable(_hiddenChannelKeys);

  /// Load the hidden set from disk (no-op when already loaded).
  Future<Set<String>> loadHiddenChannels() async {
    if (_hiddenChannelsLoaded) return Set.unmodifiable(_hiddenChannelKeys);
    final prefs = await SharedPreferences.getInstance();
    _hiddenChannelKeys
      ..clear()
      ..addAll(prefs.getStringList(_hiddenChannelsPrefsKey) ?? const []);
    _hiddenChannelsLoaded = true;
    return Set.unmodifiable(_hiddenChannelKeys);
  }

  bool isHiddenChannel(LiveTvChannel channel) => _hiddenChannelKeys.contains(hiddenKeyForChannel(channel));

  /// Sync check by channel key (the part after the source separator in a
  /// stored hidden key) — the search filter's funnel, which runs after the
  /// set has been loaded.
  bool isHiddenChannelKey(String channelKey) =>
      _hiddenChannelKeys.contains(favoriteChannelKey(_favoriteChannelSource, channelKey));

  Future<void> hideChannel(LiveTvChannel channel) async {
    await loadHiddenChannels();
    if (_hiddenChannelKeys.add(hiddenKeyForChannel(channel))) await _persistHiddenChannels();
  }

  Future<void> unhideChannel(LiveTvChannel channel) async {
    await loadHiddenChannels();
    if (_hiddenChannelKeys.remove(hiddenKeyForChannel(channel))) await _persistHiddenChannels();
  }

  /// Remove a hidden entry by its channel key (the Settings list holds
  /// stored keys, not channel objects — the key is the part after the
  /// source separator).
  Future<void> unhideChannelKey(String channelKey) async {
    await loadHiddenChannels();
    if (_hiddenChannelKeys.remove(favoriteChannelKey(_favoriteChannelSource, channelKey))) {
      await _persistHiddenChannels();
    }
  }

  Future<void> unhideAllChannels() async {
    await loadHiddenChannels();
    if (_hiddenChannelKeys.isEmpty) return;
    _hiddenChannelKeys.clear();
    await _persistHiddenChannels();
  }

  Future<void> _persistHiddenChannels() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hiddenChannelsPrefsKey, _hiddenChannelKeys.toList(growable: false));
  }

  bool get _isXtream => _client.connection is XtreamConnection;

  /// Per-channel EPG, keyed by channel key. Entries cover the whole
  /// settings window ([now - pastDays, now + daysToLoad]) so scrolling the
  /// guide re-uses them until the update interval elapses.
  final Map<String, _CachedChannelEpg> _epgCache = {};

  /// Channel keys whose cached EPG was invalidated by a mapping write
  /// (1.3.27 §P0-4): a stale persisted file must not resurrect the
  /// entry before its fire-and-forget delete lands, so
  /// [_readPersistedEpg] returns null for these keys. Cleared by
  /// [_putEpgCache] when a fresh entry is written.
  final Set<String> _epgInvalidatedKeys = {};

  /// Parsed XMLTV files, keyed by EPG URL (M3U) or by a sentinel for the
  /// Xtream login's `xmltv.php` feed (see [_fetchFeedPrograms]).
  final Map<String, _CachedXmltvGuide> _xmltvCache = {};

  /// Per-generation shared guide metadata (1.4 F1), keyed by feed
  /// cacheKey + store generation fingerprint (see
  /// [_readFeedRowsFromStore]). One entry per feed generation: the raw
  /// metadata maps + the ten derived indexes, shared by every slide
  /// of that generation. Dropped with [_xmltvCache] by the relief
  /// valve ([dropEpgFromMemory]) and [clearEpgCache] — it is
  /// rebuildable cache data, a few MB per generation.
  final Map<String, _XmltvGuideMetadata> _guideMetadataCache = {};

  /// In-flight XMLTV fetches, keyed like [_xmltvCache]: the guide opens
  /// many channels at once, and they must share ONE `xmltv.php` download
  /// instead of each pulling the multi-megabyte file. The entry is removed
  /// when the fetch settles, so a later stale-cache call re-fetches.
  final Map<String, Future<_CachedXmltvGuide>> _xmltvGuideFutures = {};

  /// Slides in flight per key (1.2.18 S-6): two concurrent slides for
  /// one key used to re-parse the whole persisted feed (or download
  /// it) twice, each with its own accumulator + dedupe set. A second
  /// slide now joins the first when it covers the same ids, and waits
  /// for it (then checks coverage again) when it does not — slides
  /// for one key never run concurrently.
  final Map<String, Future<_CachedXmltvGuide>> _xmltvSlideFutures = {};

  /// Persisted-feed reads in flight per key (1.2.20 C3): the warm-start
  /// path ([_xmltvGuideForKey] with no in-memory guide) had NO join —
  /// the in-flight map above only covers downloads, and the slide map
  /// only covers slides — so N concurrent rows each started their own
  /// whole-file re-parse (the 7-parses-in-30-s storm in the owner's
  /// 2026-11-15 debug log). A second warm start now joins the first
  /// read instead of starting its own parse; the caller slides for
  /// its own ids afterwards when the shared guide's window does not
  /// cover them (cheap with the row store).
  final Map<String, Future<_CachedXmltvGuide?>> _xmltvPersistedReadFutures = {};

  /// Rows the guide actually fetched, most recent last (1.2.20 (b) +
  /// (d)): every [fetchEpgForChannel] records its channel key here,
  /// so the Reload can slide the window onto the rows on screen and
  /// the coverage sample can count the rows the guide showed instead
  /// of the first 200 in guide order. A ring buffer capped at 200
  /// entries; entries older than 60 s are dropped at read time.
  /// "Rows on screen" is the viewport plus the guide's cache extent
  /// (~1 screen beyond), not strictly the pixels on screen — the
  /// Reload dialog's wording stays honest about that.
  final List<({String channelKey, DateTime at})> _recentGuideFetches = [];

  /// Channel keys fetched in the last 60 s, most recent first,
  /// deduped, capped at [sampleSize]. The Reload slide and the
  /// coverage sample read this — never the raw list.
  List<String> _recentGuideFetchKeys({int sampleSize = 200}) {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 60));
    final seen = <String>{};
    final out = <String>[];
    for (var i = _recentGuideFetches.length - 1; i >= 0 && out.length < sampleSize; i--) {
      final entry = _recentGuideFetches[i];
      if (entry.at.isBefore(cutoff)) continue;
      if (seen.add(entry.channelKey)) out.add(entry.channelKey);
    }
    return out;
  }

  /// Test seam (1.2.20 (d)): drop the fetch registry, so a test can
  /// exercise the matched/guideOrder fallbacks without waiting out
  /// the registry's 60 s window.
  @visibleForTesting
  void debugClearRecentGuideFetches() => _recentGuideFetches.clear();

  /// Record one guide fetch (1.2.20 (b)/(d)): called by
  /// [fetchEpgForChannel] for every channel it fetches, whether the
  /// answer came from cache or the panel — the registry says which
  /// rows the guide built, not which rows re-fetched.
  void _noteGuideFetch(String channelKey) {
    _recentGuideFetches.add((channelKey: channelKey, at: DateTime.now()));
    while (_recentGuideFetches.length > 200) {
      _recentGuideFetches.removeAt(0);
    }
  }

  /// Failed XMLTV feed downloads, keyed like [_xmltvCache] (build #15,
  /// item 6): a failed feed is remembered briefly so a slow/failing feed
  /// is not re-downloaded channel by channel — rows show the existing
  /// tap-to-retry state instead until the window passes.
  final Map<String, DateTime> _xmltvFailedAt = {};

  /// Cap on concurrent per-channel `get_short_epg` calls (build #15,
  /// item 6): the guide opens many rows at once and each used to fire its
  /// own 60s call. Four in flight is enough for the first visible rows
  /// while the rest wait their turn instead of stacking timeouts.
  /// 1.2.19 L-28: per-tier fan-out — 1 on T0–T1, 2 on T2–T3, 4 on T4.
  static int get _maxShortEpgConcurrency => DevicePerformance.shortEpgFanOut;

  /// `get_short_epg` page size: the panel returns at most this many
  /// listings per call, with no total/count — so exactly this many
  /// means the answer may be truncated (1.2.1 D4) and the feed tail
  /// must fill the days the limit cut off.
  static const int _shortEpgLimit = 500;

  int _shortEpgInFlight = 0;
  final List<Completer<void>> _shortEpgWaiters = [];

  /// Paces `get_short_epg` starts (1.4.3 C1): the semaphore above
  /// bounds in-flight calls, not rate — the 05:21 log showed 12 calls
  /// in ~1.3 s (≈ 9 req/s) against a documented 6–8 req/s flood limit
  /// with only 4 in flight. One pacer per support, shared by the
  /// guide-open fan-out and the idle sweep (both go through
  /// [_fetchXtreamShortEpg]).
  final IptvCallPacer _shortEpgPacer = IptvCallPacer();

  /// First-paint budget for one channel's `get_short_epg` (build #15,
  /// item 6): a channel whose short-EPG doesn't answer quickly falls back
  /// to the cached feed slice instead of holding its row for the full
  /// 60s. Test-overridable so the timeout path stays fast to prove.
  @visibleForTesting
  static Duration shortEpgFirstPaintTimeout = const Duration(seconds: 15);

  /// How long a failed XMLTV feed download is remembered (build #15,
  /// item 6). Test-overridable.
  @visibleForTesting
  static Duration xmltvNegativeCacheTtl = const Duration(minutes: 5);

  /// Total budget for waiting behind a running catalog sync before a
  /// feed download starts (1.6.34, P-06): the ~150 MB feed must not
  /// download concurrently with the sync's downloads + FTS writes on
  /// a low-end TV. Past the budget the download starts anyway, so a
  /// crashed sync (whose stamp ages out in 30 min) never blocks the
  /// guide forever. Test-overridable so the queue stays fast to prove.
  @visibleForTesting
  static Duration catalogSyncWaitBudget = const Duration(minutes: 15);

  /// Total budget for [waitForFeedRefresh] (1.6.34, P-07): a stalled
  /// feed download must not hold the Update-now tile spinner forever.
  /// Ten minutes covers the slowest realistic feed (~150 MB on a slow
  /// link) with room; past it the wait gives up and the tile stops
  /// spinning. The download itself is NOT cancelled — the guide still
  /// lands when it finishes, and the dialog keeps polling it.
  /// Test-overridable so the stall path stays fast to prove.
  @visibleForTesting
  static Duration feedRefreshWaitBudget = const Duration(minutes: 10);

  /// True after "Clear guide" until something refreshes the guide
  /// ([refreshEpgCache] or the one start-up refresh). While set, the guide
  /// shows "No information available" hour blocks instead of refetching —
  /// otherwise Clear would be undone by the guide's lazy fetch on its
  /// next row build.
  bool _epgCleared = false;

  /// Feed downloads in flight (1.3.24 §67 F2): counted in
  /// [_startXmltvDownload] so [clearEpgCache] can defer the persisted
  /// delete instead of deleting under a feed promotion.
  int _feedJobsInFlight = 0;

  /// A persisted-EPG delete asked for while a feed job was in flight
  /// (1.3.24 §67 F2): it waits for the jobs to settle instead of
  /// racing the promotion.
  bool _epgDeleteDeferred = false;

  /// True when a feed job landed while [_epgDeleteDeferred] was set
  /// (1.3.24 §67 F2): the landed feed IS the fresh state, so the
  /// deferred delete is dropped instead of removing it.
  bool _epgDeleteDeferredLanded = false;

  /// A [refreshEpgCache] in flight (1.3.24 §67 F2): concurrent busts
  /// join this future instead of running a second delete.
  Future<void>? _refreshEpgCacheInFlight;

  /// Bumped by [clearEpgCache]; the guide watches it to reset per-channel
  /// loaded/failed state and re-fetch visible rows.
  int _epgVersion = 0;

  /// The same bump as a listenable (1.2.15 R5): the guide tab subscribes
  /// to this and rebuilds when it changes, so a bump made while the
  /// guide is already open — playback stopping, a late short-EPG answer
  /// landing — actually re-fetches the visible rows instead of waiting
  /// for the next scroll or window change. Always bump through
  /// [_bumpEpgVersion]. 1.2.17: the value is a monotonic sequence, not
  /// the version — a channel-scoped bump fires the notifier without
  /// moving [_epgVersion] (see [_bumpEpgVersion]).
  final ValueNotifier<int> epgVersionNotifier = ValueNotifier<int>(0);

  /// Monotonic bump sequence (1.2.17): every bump — whole-guide or
  /// channel-scoped — moves it, so listeners always fire.
  int _epgBumpSequence = 0;

  /// The channel key of the last channel-scoped bump, or null after a
  /// whole-guide bump — the guide tab heals just that row instead of
  /// rebuilding the whole tab (1.2.17 R5).
  String? _lastEpgBumpChannelKey;

  /// The channel key of the last channel-scoped bump, or null after a
  /// whole-guide bump.
  String? get lastEpgBumpChannelKey => _lastEpgBumpChannelKey;

  /// Bump the guide version. A null [channelKey] is a whole-guide bump
  /// (playback stop, drop, clear): the version moves and the tab
  /// rebuilds. A channel key is a scoped bump (a late short-EPG answer
  /// landing): the version does NOT move — only that row heals — but the
  /// notifier still fires so the tab's listener runs.
  void _bumpEpgVersion({String? channelKey}) {
    _lastEpgBumpChannelKey = channelKey;
    if (channelKey == null) _epgVersion++;
    epgVersionNotifier.value = ++_epgBumpSequence;
  }
  DateTime? _lastEpgUpdatedAt;
  DateTime? _lastEpgPrefWrite;
  DateTime? _lastEpgAttemptPrefWrite;

  /// Whether the 403 circuit breaker is open for this support's
  /// connection (1.4.3 C3/C2): the guide tab's sweep and row retry read
  /// this instead of re-firing the panel.
  Future<bool> get isIn403Cooldown => _client.isIn403Cooldown;

  /// Test-only override for the directory the persisted EPG cache lives
  /// in, so tests can use a temp dir instead of the app cache. Production
  /// code never sets this; reset it in tearDown when a test does.
  @visibleForTesting
  static Future<Directory> Function()? debugEpgCacheDirectoryProvider;

  /// 1.4 F1: how many times the guide's derived indexes have been built
  /// in this process (test seam — the harness asserts a slide does not
  /// raise it). Production code never reads this.
  @visibleForTesting
  static int get xmltvGuideIndexBuildCount => _XmltvGuideIndexes.buildCount;

  /// 1.4 F1: reset the index-build count (test seam — call in setUp so
  /// each test measures only its own slides).
  @visibleForTesting
  static void resetXmltvGuideIndexBuildCount() {
    _XmltvGuideIndexes.buildCount = 0;
  }

  /// Test-only: when true, the persisted EPG side is skipped entirely
  /// (mirrors `IptvCatalogDiskCache.debugDisableDisk` — real disk I/O hangs
  /// inside testWidgets' fake async zone). Production code never sets this.
  @visibleForTesting
  static bool debugDisablePersistedEpg = false;

  /// Test-only: when true, the feed parse runs on the main isolate
  /// instead of a worker isolate (1.2.18 S-1). `compute` futures need
  /// `runAsync` inside `testWidgets` fake async, and the sync test
  /// path keeps the old main-isolate behaviour. Production code never
  /// sets this.
  @visibleForTesting
  static bool debugDisableIsolateFeedParse = false;

  /// Test-only: when true, the feed parse never builds the row store
  /// (1.2.20 (a)) — the slide and warm-start paths fall back to the
  /// whole-file re-parse, exactly like the 1.2.19 base. Production
  /// code never sets this; the store-build budget test uses it to
  /// measure the parse with and without the build.
  @visibleForTesting
  static bool debugDisableFeedRowStore = false;

  /// Test-only: the call-site tag of the last feed parse (1.2.20 C3) —
  /// `download`, `warm-start`, `slide`, or `load`. Set by
  /// [_parseFeedFile] on every parse so a test can prove which path
  /// started it (the SlowOpLog line carries the same tag when the
  /// parse is slow enough to log).
  @visibleForTesting
  static String? debugLastFeedParseCaller;

  /// Test-only (1.4.4 F10): how many times the pre-parse trim actually
  /// dropped something before a heavy job (image cache cleared or
  /// short-EPG entries evicted). The trim only logs when it trims, so
  /// the count — not the log — is the proof the trim fires before the
  /// feed parse. Reset by tests in setUp; the `after` trims are not
  /// counted (they clean up after the spike, they do not prevent it).
  @visibleForTesting
  static int debugTrimBeforeHeavyJobCount = 0;

  /// Feed parses performed by this support (1.2.12 debug hook):
  /// incremented in [_loadXmltvGuide] and [_readPersistedXmltv]
  /// whenever a feed file is parsed — a window slide re-parses, so
  /// the count is the proof that the feed is NOT parsed before the
  /// first short-EPG answer (W1/W4) and that a slide costs one parse
  /// (W3).
  int _feedParseCount = 0;

  /// How many feed parses this support has performed (1.2.12).
  @visibleForTesting
  int get debugFeedParseCount => _feedParseCount;

  /// Whether the feed gate is open (1.2.12).
  @visibleForTesting
  bool get debugFeedGateOpen => _epgFeedGateOpen;

  /// How many programmes the feed windows currently retain across
  /// all loaded feeds (1.2.12): the bound assertion — this must stay
  /// at the visible-window size, not the whole feed's programme count.
  /// Also the pressure/watchdog telemetry (1.2.18 S-4c).
  int get retainedFeedPrograms =>
      _xmltvCache.values.fold(0, (sum, guide) => sum + guide.windowProgramCount);

  @visibleForTesting
  int get debugRetainedFeedPrograms => retainedFeedPrograms;

  /// How many per-channel entries the EPG cache holds (1.2.12): the
  /// cap assertion. Also the pressure/watchdog telemetry (1.2.18 S-4c).
  int get epgCacheEntries => _epgCache.length;

  @visibleForTesting
  int get debugEpgCacheSize => epgCacheEntries;

  /// Pre-emptive trim (1.2.18 S-4b): evict the OLDEST half of the
  /// short-EPG cache before a heavy job starts, keeping the most
  /// recent entries — the visible rows' answers, fetched most
  /// recently as the user scrolled. Eviction loses nothing: the
  /// persisted per-channel file is the backing store, so an evicted
  /// channel re-reads from disk on its next fetch. Returns how many
  /// entries were evicted (0 when the cache is already at/below half
  /// the cap).
  int trimEpgCacheBeyondWindow() {
    final target = _maxEpgCacheEntries ~/ 2;
    var evicted = 0;
    while (_epgCache.length > target) {
      _epgCache.remove(_epgCache.keys.first);
      evicted++;
    }
    return evicted;
  }

  /// Trim caches around a heavy job (1.2.18 S-4b/S-8b): both halves go
  /// only when RSS is already above half the watchdog threshold
  /// ([IptvHeavyWorkGate.isMemoryHot]) — the image cache and the oldest
  /// half of the short-EPG cache ([trimEpgCacheBeyondWindow] evicts to
  /// half the tier cap). Before a heavy job so the spike starts with
  /// headroom, and after a feed parse (after: true) so the spike's
  /// leftovers do not linger. When memory is fine neither half fires:
  /// evicted EPG rows re-read from persisted per-channel files on next
  /// access, so trimming when cool only buys disk re-reads. Logged so
  /// the next dump proves the trim happened.
  void _trimCachesIfHot(String job, {bool after = false}) {
    final imageTrimmed = IptvHeavyWorkGate.trimImageCacheBeforeHeavyJob();
    // A29: the EPG half used to fire unconditionally on every call —
    // one feed parse trimmed twice (before + after) even with memory
    // to spare. Same RSS gate as the image half now.
    final epgEvicted = IptvHeavyWorkGate.isMemoryHot ? trimEpgCacheBeyondWindow() : 0;
    if (imageTrimmed || epgEvicted > 0) {
      // 1.4.4 F10: count the before-job trims so a test can prove the
      // pre-parse trim fires (the log alone only appears when something
      // was there to drop).
      if (!after) debugTrimBeforeHeavyJobCount++;
      appLogger.i(
        'IPTV: cache trim ${after ? 'after' : 'before'} $job (image cache cleared: $imageTrimmed, short-EPG entries evicted: $epgEvicted)',
      );
    }
  }

  /// Store one per-channel EPG entry under the cap (1.2.12, item
  /// #4c): at most [_maxEpgCacheEntries] entries, LRU by insertion
  /// order (a re-insert marks the entry most recent). Eviction loses
  /// nothing — the persisted per-channel file is the backing store,
  /// so an evicted channel re-reads from disk on its next fetch.
  void _putEpgCache(String key, _CachedChannelEpg entry) {
    _epgInvalidatedKeys.remove(key);
    _epgCache.remove(key);
    _epgCache[key] = entry;
    while (_epgCache.length > _maxEpgCacheEntries) {
      _epgCache.remove(_epgCache.keys.first);
    }
  }

  /// Maximum per-channel entries in [_epgCache] (1.2.12, item #4c).
  /// 1.2.19 L-7: per-tier — 16 on T0, 32 on T1, 64 on T2–T4.
  static int get _maxEpgCacheEntries => DevicePerformance.epgCacheEntries;

  /// Whether the update-on-start refresh has run for this support instance
  /// (one instance per client per app launch), per channel. Build #6 used
  /// one bool for the whole support — harmless with an in-memory cache
  /// (every channel was cold at launch anyway), but with a persisted
  /// cache the first channel's refresh would have lifted the flag for
  /// every other channel, leaving their stale entries in place. One fresh
  /// fetch per channel on the first guide open is the setting's actual
  /// meaning.
  final Set<String> _startupRefreshedChannels = {};

  /// Channels whose feed was deferred by the playback gate (1.1.2 D1b):
  /// the fetch returned empty without caching. Cleared when playback
  /// stops (the listener bumps the guide version) and by
  /// [clearEpgCache].
  final Set<String> _deferredEpgChannels = {};

  /// The quiet-hour boundary this support instance already refreshed for
  /// (§3.3) — a refresh is once per boundary, not once per guide open.
  DateTime? _quietHourRefreshedFor;

  /// D1b: when playback stops, channels deferred by the gate must
  /// reload. The guide watches [epgVersion] and re-fetches visible rows
  /// when it changes — bumping it here is what makes the deferred rows
  /// heal without a window change or an Update now.
  void _onPlaybackActivityChanged() {
    if (IptvPlaybackActivity.instance.isPlaying) return;
    if (_deferredEpgChannels.isEmpty) return;
    _deferredEpgChannels.clear();
    _bumpEpgVersion();
  }

  /// Record a playback-gate deferral for [channelKey] (1.1.2 D1b).
  void _recordFeedDeferral(String channelKey) {
    _deferredEpgChannels.add(channelKey);
  }

  @override
  LiveTvDvrSupport? get dvr => null;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<List<LiveTvChannel>> fetchChannels({String? lineup}) => _client.iptvChannels();

  @override
  Future<List<LiveTvProgram>> fetchSchedule({DateTime? from, DateTime? to}) async {
    // Intentionally empty: the server-wide hook cannot name the channels the
    // guide is actually showing, and one call per channel across a 55k-row
    // catalog is not an option. The guide drives EPG lazily per visible
    // channel through [fetchEpgForChannel] instead, so only browsed channels
    // are ever fetched. See IPTV_EPG_NOTES.md.
    return const [];
  }

  /// EPG settings snapshot, read once per fetch from [SettingsService].
  static Future<_EpgSettings> _readEpgSettings() async {
    final settings = await SettingsService.getInstance();
    return _EpgSettings(
      daysToLoad: settings.read(SettingsService.iptvEpgDaysToLoad),
      updateIntervalHours: settings.read(SettingsService.iptvEpgUpdateIntervalHours),
      pastDays: settings.read(SettingsService.iptvEpgPastDays),
      updateOnStart: settings.read(SettingsService.iptvEpgUpdateOnStart),
      timeOffsetMinutes: settings.read(SettingsService.iptvEpgTimeOffsetMinutes),
    );
  }

  /// Fetch guide programs for ONE channel, for the requested window.
  ///
  /// The fetch covers the whole settings window ([now - pastDays, now +
  /// daysToLoad]) and the result is cached per channel, so scrolling the
  /// guide re-uses it until the update interval elapses. Only the slice
  /// overlapping [from, to] is returned.
  ///
  /// Build #8 Task 3: a fetch that FAILS (both sources failed) THROWS
  /// instead of returning [] — the old fail-open [] made the guide record
  /// a failed fetch as a successful empty one (loaded, placeholders, never
  /// retried), so the owner could not tell "failed" from "loaded but empty".
  /// Returning [] now means only one thing: the fetch succeeded and this
  /// channel genuinely has no programmes in the window. The guide catches
  /// the throw and marks the channel FAILED (visible retry state).
  ///
  /// 1.1.2 D1a: "both sources failed" counts a feed that FAILS as
  /// failed — a feed that loads but has nothing for the channel is the
  /// only "answering empty". A playback-gate deferral (D1b) is neither:
  /// it returns [] without caching, and reloads when playback stops.
  /// [force] bypasses the feed's 5-minute negative cache (D8) — an
  /// explicit retry is not a storm. Only an explicit force bypasses it:
  /// a plain re-fetch after a failure still respects the negative cache
  /// (see iptv_epg_cache_test: a failed feed must not be re-downloaded
  /// per channel).
  /// (1.2.1 D7) A cached entry stamped from a feed generation that has
  /// since refreshed is stale even though its own clock is fresh — it
  /// refetches from the new feed, and a failed refetch still serves the
  /// old entry (stale-while-revalidate).
  Future<List<LiveTvProgram>> fetchEpgForChannel(
    String channelKey, {
    required DateTime from,
    required DateTime to,
    bool force = false,
    // 1.2.12: bypass the feed gate — the detail sheet and the player
    // show one channel the user explicitly opened, so the feed loads
    // even when the gate is closed. The guide tab never passes this.
    bool bypassFeedGate = false,
  }) async {
    final settings = await _readEpgSettings();
    final now = DateTime.now();

    // 1.2.20 (b)/(d): the guide fetched this row — record it so the
    // Reload can slide the window onto the rows on screen and the
    // coverage sample can count them. Recorded for every fetch (cache
    // hit or panel fetch): the registry says which rows the guide
    // built.
    _noteGuideFetch(channelKey);

    // Update-on-start forces one fresh fetch per channel on the first guide
    // open after launch, even inside the interval. It also lifts a
    // "Clear guide", since the user asked for a refresh on start.
    final forceRefresh = settings.updateOnStart && !_startupRefreshedChannels.contains(channelKey);
    if (forceRefresh) _startupRefreshedChannels.add(channelKey);
    if (_epgCleared && !forceRefresh) return const <LiveTvProgram>[];
    if (forceRefresh) _epgCleared = false;

    // Build #26 (26.7): the fetch window is widened to cover the
    // REQUESTED window, not just [now - pastDays, now + daysToLoad] —
    // the day picker offers today + 7 days, but a picked day past the
    // 4-day settings window could never show data: the feed slice was
    // filtered to the settings window before the requested slice was
    // taken. The feed already holds the data; no extra download.
    var fetchFrom = now.subtract(Duration(days: settings.pastDays));
    var fetchTo = now.add(Duration(days: settings.daysToLoad));
    if (from.isBefore(fetchFrom)) fetchFrom = from;
    if (to.isAfter(fetchTo)) fetchTo = to;
    final ttl = settings.updateIntervalHours <= 0
        ? null // Manual only: the cache never expires on its own.
        : Duration(hours: settings.updateIntervalHours);

    // In-memory first, then the persisted entry: a fresh persisted entry
    // covering the requested window is served without refetching — that is
    // the whole point of persisting it. A stale entry, or one that does
    // not cover the window, falls through to a refetch below.
    final cached = _epgCache[channelKey] ?? await _readPersistedEpg(channelKey);
    if (cached != null) _putEpgCache(channelKey, cached);
    // D7: an entry stamped from a feed generation that has since been
    // superseded is stale even though its own clock is fresh — fall
    // through to a refetch, which re-maps from the new feed. The old
    // entry is kept so a failed refetch can still serve it (below).
    // 1.3.26 §69: an explicit retry (force) bypasses the servable
    // cache too — a loaded-empty row's retry must actually re-ask
    // short-EPG + feed instead of serving the cached [] straight
    // back. Only two callers pass force (the detail sheet's explicit
    // refresh and the guide tab's retry), both of which want fresh
    // data; the player passes no force and is unaffected.
    final servable = cached != null && cached.covers(from, to) && cached.isFresh(ttl) && !forceRefresh && !force;
    final generationStale = servable && _isFeedGenerationStale(cached);
    // 1.2.3 RC3: a stored entry with ZERO programmes and NO feed
    // generations is a pre-1.2.1 poisoned empty entry (1.1.1's D1
    // silent-empty path wrote [] with no generations key). It must NOT
    // count as servable — it refetches once, below, instead of serving
    // hour blocks forever with no attempt ever stamped. A legitimately
    // empty entry always carries generations from the feeds consulted
    // while fetching it, so it still serves — EXCEPT a connection with
    // no EPG source at all (M3U without an EPG URL, no added sources):
    // _fetchFeedPrograms returns [] with no generations when attempts
    // is empty, so that entry is genuine and must keep serving. The
    // gate below is that distinction (and a cancelled fetch, which also
    // writes an empty+unstamped entry, correctly refetches on revisit:
    // the cancellation meant no data was ever fetched).
    var poisoned = false;
    if (servable &&
        !generationStale &&
        cached.programs.isEmpty &&
        cached.feedGenerations.isEmpty) {
      final attempts = await _epgSourceAttempts();
      poisoned = attempts.isNotEmpty;
    }
    if (servable && !generationStale && !poisoned) {
      // 1.3.28: the serve path used to be silent, so a phone log could
      // not tell "served from cache" from "never fetched" — say so,
      // with the programme count and source, on every serve.
      appLogger.i(
        'IPTV EPG $channelKey: served from cache (${cached.programs.length} programmes, source ${cached.source.name})',
      );
      return _slice(cached.programs, from, to);
    }

    // 1.2.22 §63.2: abort cooldown — 3 aborts in 10 s means the
    // channel's fetches keep getting cancelled (scroll storm); a
    // non-forced fetch throws a cancellation instead of opening a new
    // short-EPG call, until the window passes. The guide tab treats a
    // cancellation as "not failed" and refetches on scroll-back, so
    // the row heals itself. An explicit retry (force) bypasses it.
    final cooldownUntil = _epgAbortCooldownUntil[channelKey];
    if (cooldownUntil != null && !now.isBefore(cooldownUntil)) {
      _epgAbortCooldownUntil.remove(channelKey);
    } else if (!force && cooldownUntil != null) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.cancelled,
        message: 'EPG fetch paused after repeated cancellations; retrying shortly',
      );
    }

    // 1.2.22 §63.2: per-channel in-flight join — concurrent fetches
    // for the same channel and window share one network fetch. The
    // shared future is awaited below, where a failure still serves a
    // generation-stale entry (D7) for THIS waiter.
    final joinKey = '$channelKey|${from.millisecondsSinceEpoch}|${to.millisecondsSinceEpoch}';
    final Future<List<LiveTvProgram>> networkFuture;
    if (!force) {
      final inFlight = _epgFetchInFlight[joinKey];
      if (inFlight != null) {
        _epgFetchWaiters[joinKey] = (_epgFetchWaiters[joinKey] ?? 1) + 1;
        networkFuture = inFlight;
      } else {
        networkFuture = _fetchEpgForChannelNetwork(channelKey, from, to, settings, now, fetchFrom, fetchTo, ttl, force: force, bypassFeedGate: bypassFeedGate);
        _epgFetchInFlight[joinKey] = networkFuture;
        _epgFetchWaiters[joinKey] = 1;
        // The cleanup future must swallow the shared error: whenComplete
        // rethrows it, and an unlistened errored future is reported as
        // unhandled even under unawaited — the waiters already observe
        // the error through networkFuture itself.
        unawaited(
          networkFuture
              .whenComplete(() {
                if (identical(_epgFetchInFlight[joinKey], networkFuture)) {
                  _epgFetchInFlight.remove(joinKey);
                  _epgFetchWaiters.remove(joinKey);
                }
              })
              .then<void>((_) {}, onError: (_) {}),
        );
      }
    } else {
      networkFuture = _fetchEpgForChannelNetwork(channelKey, from, to, settings, now, fetchFrom, fetchTo, ttl, force: force, bypassFeedGate: bypassFeedGate);
    }
    try {
      return await networkFuture;
    } catch (e) {
      if (generationStale) {
        // D7: the refetch after a feed refresh failed — serve the old
        // entry instead of a retry row (stale-while-revalidate: the
        // previous guide data beats nothing, and the refresh failure
        // does not invalidate it). The next fetch retries the refresh.
        appLogger.w('IPTV EPG refetch failed for channel $channelKey after a feed refresh; serving the previous entry', error: e);
        return _slice(cached.programs, from, to);
      }
      if (MediaServerHttpException.from(e).isCancellation) {
        // 1.2.22 §63.2: a cancellation is not a failure — debug only.
        // (The shared network fetch already recorded the abort once.)
        appLogger.d('IPTV EPG fetch cancelled for channel $channelKey');
        rethrow;
      }
      // The shared network fetch already logged this failure once (see
      // _fetchEpgForChannelNetwork) — rethrow without logging again, so
      // N joined waiters do not log N warnings for one failure.
      rethrow;
    }
  }

  /// The network half of [fetchEpgForChannel] (1.2.22 §63.2): the
  /// fetch that runs once per channel+window and is shared by the
  /// in-flight join. It logs a failure exactly once and records an
  /// abort exactly once — the waiters never log the shared failure
  /// again. A failed fetch THROWS (build #8 Task 3) instead of
  /// returning [].
  Future<List<LiveTvProgram>> _fetchEpgForChannelNetwork(
    String channelKey,
    DateTime from,
    DateTime to,
    _EpgSettings settings,
    DateTime now,
    DateTime fetchFrom,
    DateTime fetchTo,
    Duration? ttl, {
    bool force = false,
    bool bypassFeedGate = false,
  }) async {
    // D9: an attempt happened even when the fetch fails or returns
    // empty — record it before the fetch, so "Last attempt" certifies
    // activity while "Last updated" certifies data (stamped below,
    // only when programmes were stored).
    _noteEpgAttempt(now);
    List<LiveTvProgram> programs;
    IptvEpgSource source;
    String? fetchedSourceId;
    String? fetchedMatchedXmltvId;
    String? fetchedMatchMethod;
    Map<String, DateTime> fetchedFeedGenerations;
    // 1.2.15 R1: whether this fetch's empty follows a short-EPG
    // timeout, and the late request still running for it.
    var shortEpgTimedOut = false;
    Future<List<LiveTvProgram>>? lateShortEpg;
    try {
      final fetched = _isXtream
          ? await _fetchXtreamEpg(channelKey, settings, fetchFrom, fetchTo, ttl, force: force, bypassFeedGate: bypassFeedGate)
          : await _fetchM3uEpg(channelKey, settings, fetchFrom, fetchTo, ttl, force: force, bypassFeedGate: bypassFeedGate);
      programs = fetched.programs;
      source = fetched.source;
      fetchedSourceId = fetched.sourceId;
      fetchedMatchedXmltvId = fetched.matchedXmltvId;
      fetchedMatchMethod = fetched.matchMethod;
      fetchedFeedGenerations = fetched.feedGenerations;
      shortEpgTimedOut = fetched.shortEpgTimedOut;
      lateShortEpg = fetched.lateShortEpg;
      if (fetched.feedDeferred) {
        // D1b: the feed was deferred by the playback gate — not a
        // failure and not a genuine empty. Return [] WITHOUT caching,
        // so the next fetch after playback stops downloads the feed.
        // The deferral is recorded (see _recordFeedDeferral) so the
        // idle listener bumps the guide version and the row re-fetches.
        // 1.2.15 R1: the late short-EPG answer is still attached — a
        // deferred row heals when its listings land, with no fallback
        // entry to write if the late request settles dead.
        _attachLateShortEpg(channelKey, lateShortEpg, fetchFrom, fetchTo);
        return const <LiveTvProgram>[];
      }
      // A successful (non-deferred) fetch resolves the channel: it is
      // no longer a deferred one.
      _deferredEpgChannels.remove(channelKey);
    } catch (e) {
      if (MediaServerHttpException.from(e).isCancellation) {
        // 1.2.22 §63.2: a cancellation is not a failure — record it
        // for the abort cooldown and log it at debug, so a scroll-away
        // storm never spams the log with one warning per waiter.
        _noteEpgAbort(channelKey);
        appLogger.d('IPTV EPG fetch cancelled for channel $channelKey');
        rethrow;
      }
      // Build #8 Task 3: a failed fetch must surface (see the doc comment
      // above) — swallowing it as [] recorded failures as loaded-empty.
      // A failed fetch writes no cache entry, so a retry refetches.
      appLogger.w('IPTV EPG fetch failed for channel $channelKey', error: e);
      rethrow;
    }

    final entry = _CachedChannelEpg(programs: programs, fetchedAt: now, windowFrom: fetchFrom, windowTo: fetchTo, source: source, sourceId: fetchedSourceId, matchedXmltvId: fetchedMatchedXmltvId, matchMethod: fetchedMatchMethod, feedGenerations: fetchedFeedGenerations);
    // 1.2.15 R1: a per-channel [] that follows a short-EPG TIMEOUT is
    // not a genuine empty — the answer may still be on its way. It is
    // NOT written as a servable 24 h entry (in memory or on disk), so
    // the next guide open retries short-EPG instead of serving the
    // timeout for a day. The late handler below writes this entry once
    // the late request settles dead (a genuine empty), or replaces it
    // with the late listings when they land.
    final timeoutEmpty = programs.isEmpty && shortEpgTimedOut;
    if (!timeoutEmpty) {
      _putEpgCache(channelKey, entry);
      // Best-effort and fire-and-forget: a failed write never breaks the
      // guide — the in-memory entry above still serves this launch — and
      // awaiting the disk write here would gate the guide on file I/O.
      // (The write still happens; it just doesn't hold the fetch open.)
      unawaited(_writePersistedEpg(channelKey, entry));
    }
    _attachLateShortEpg(channelKey, lateShortEpg, fetchFrom, fetchTo, fallbackEntry: timeoutEmpty ? entry : null);
    unawaited(_pruneStalePersistedEpg(ttl));
    // D9: "Last updated" certifies DATA, not activity — stamp it only
    // when at least one programme was stored. An empty fetch (a genuine
    // empty, or a channel with no guide) leaves it alone.
    if (programs.isNotEmpty) {
      _lastEpgUpdatedAt = now;
      _noteEpgUpdated(now);
    }
    return _slice(programs, from, to);
  }

  /// Watch a timed-out short-EPG request to its end (1.2.15 R1): when
  /// its listings land, store them for the channel (see
  /// [_storeLateShortEpg]); when it settles with nothing, short-EPG is
  /// definitively dead for this fetch, so [fallbackEntry] — the feed's
  /// empty, withheld from the cache at fetch time — becomes a genuine,
  /// servable entry now. A null [lateShortEpg] is a no-op. The late
  /// future never throws (its errors map to [] where it is built), so
  /// this handler always runs to a decision.
  void _attachLateShortEpg(
    String channelKey,
    Future<List<LiveTvProgram>>? lateShortEpg,
    DateTime from,
    DateTime to, {
    _CachedChannelEpg? fallbackEntry,
  }) {
    if (lateShortEpg == null) return;
    unawaited(
      lateShortEpg.then((programs) {
        if (_epgCleared) return;
        if (programs.isNotEmpty) {
          _storeLateShortEpg(channelKey, programs, from, to);
          return;
        }
        if (fallbackEntry != null) {
          _putEpgCache(channelKey, fallbackEntry);
          unawaited(_writePersistedEpg(channelKey, fallbackEntry));
        }
      }),
    );
  }

  /// Store a late short-EPG answer for [channelKey] (1.2.15 R1): the
  /// listings the first-paint timeout gave up on, now arrived. Only
  /// when the channel has no programmes cached — a feed answer that
  /// already landed stays (the late answer fills empty rows, it does
  /// not replace served data). The guide version bump makes the visible
  /// row re-fetch and render the listings without a reopen.
  void _storeLateShortEpg(String channelKey, List<LiveTvProgram> programs, DateTime from, DateTime to) {
    if (_epgCleared) return;
    final current = _epgCache[channelKey];
    if (current != null && current.programs.isNotEmpty) return;
    final now = DateTime.now();
    final entry = _CachedChannelEpg(
      programs: programs,
      fetchedAt: now,
      windowFrom: from,
      windowTo: to,
      source: IptvEpgSource.shortEpg,
      feedGenerations: const <String, DateTime>{},
    );
    _putEpgCache(channelKey, entry);
    unawaited(_writePersistedEpg(channelKey, entry));
    _lastEpgUpdatedAt = now;
    _noteEpgUpdated(now);
    // 1.2.17: scoped bump — only this channel healed, no whole-guide
    // version move (see [_bumpEpgVersion]).
    // 1.3.26 §69: per-channel fetch-outcome logging — a heal that
    // lands after the export is otherwise invisible in the log.
    appLogger.i('IPTV EPG $channelKey: late short-epg healed with ${programs.length} programmes');
    _bumpEpgVersion(channelKey: channelKey);
  }

  /// Programmes from the EPG cache ONLY, for [channelKeys] — in-memory
  /// entries plus persisted per-channel files. Never a network fetch
  /// (build #15, item 2): the guide search sheet must not fire a
  /// `get_short_epg` per channel across the catalog. Channels with no
  /// cache entry contribute nothing here; they still match by channel
  /// name in the sheet. A stale entry is served as-is (the guide is the
  /// source of truth for freshness) as long as it covers the window.
  ///
  /// The persisted side is ONE directory listing, not one read per channel:
  /// only channels with a file are read, and only ones not already served
  /// from memory. A cache read failure never breaks search — programme
  /// results are best-effort.
  Future<Map<String, List<LiveTvProgram>>> cachedEpgForChannels(
    Set<String> channelKeys, {
    required DateTime from,
    required DateTime to,
  }) async {
    final out = <String, List<LiveTvProgram>>{};
    for (final key in channelKeys) {
      final entry = _epgCache[key];
      if (entry == null || !entry.covers(from, to)) continue;
      final slice = _slice(entry.programs, from, to);
      if (slice.isNotEmpty) out[key] = slice;
    }
    // Every requested channel already served from memory — the common case
    // after the guide warmed the cache — so no directory listing at all.
    if (out.length == channelKeys.length || debugDisablePersistedEpg) return out;
    try {
      final dir = await _epgCacheDir();
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          final key = _channelKeyFromFileName(entity.path.split('/').last);
          if (key == null || !channelKeys.contains(key) || out.containsKey(key)) continue;
          final entry = await _readPersistedEpg(key);
          if (entry == null || !entry.covers(from, to)) continue;
          _putEpgCache(key, entry);
          final slice = _slice(entry.programs, from, to);
          if (slice.isNotEmpty) out[key] = slice;
        }
      }
    } catch (_) {
      // Best-effort: in-memory results above still stand.
    }
    return out;
  }

  /// The channel key for a persisted EPG filename (`<base64url(key)>.json`
  /// — see [_fileSafe]); null when the name does not decode.
  static String? _channelKeyFromFileName(String name) {
    final base = name.endsWith('.json') ? name.substring(0, name.length - 5) : name;
    try {
      final padded = base + ('=' * ((4 - base.length % 4) % 4));
      return utf8.decode(base64Url.decode(padded));
    } catch (_) {
      return null;
    }
  }

  /// Test-only seam: seed the in-memory EPG cache for [channelKey] without
  /// touching disk or the network, so the search sheet's cache-only path
  /// can be driven directly. Production code never calls this.
  @visibleForTesting
  void debugSeedCachedEpg(
    String channelKey,
    List<LiveTvProgram> programs, {
    required DateTime from,
    required DateTime to,
    IptvEpgSource source = IptvEpgSource.unknown,
  }) {
    _putEpgCache(
      channelKey,
      _CachedChannelEpg(
        programs: programs,
        fetchedAt: DateTime.now(),
        windowFrom: from,
        windowTo: to,
        source: source,
      ),
    );
  }

  /// Persisted EPG cache: one JSON file per browsed channel, under the app
  /// cache directory (`iptv_epg/<connectionId>/<channelKey>.json`). A
  /// channel's whole settings window runs to hundreds of programs, so
  /// SharedPreferences would bloat; the cache directory is also the app's
  /// existing pattern for bulky per-item files (see ImageCacheService).
  /// Channel keys come from provider data, so the filename is
  /// base64url-encoded — never trusted raw.
  Future<Directory> _epgCacheDir() async {
    final base = await (debugEpgCacheDirectoryProvider ?? getApplicationCacheDirectory)();
    return Directory('${base.path}/iptv_epg/${_fileSafe(_client.connection.id)}');
  }

  static String _fileSafe(String value) => base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  Future<File> _epgCacheFile(String channelKey) async {
    final dir = await _epgCacheDir();
    return File('${dir.path}/${_fileSafe(channelKey)}.json');
  }

  Future<_CachedChannelEpg?> _readPersistedEpg(String channelKey) async {
    // 1.2.17: the persisted side is disabled for tests — without this
    // the awaited real async file check below never completes in
    // testWidgets fake-async and the fetch hangs before short-EPG.
    if (debugDisablePersistedEpg) return null;
    // 1.3.27 §P0-4: an invalidated key reads as a miss — its persisted
    // file is being deleted, and a stale read would resurrect the
    // empty entry the mapping write just dropped.
    if (_epgInvalidatedKeys.contains(channelKey)) return null;
    try {
      final file = await _epgCacheFile(channelKey);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return _CachedChannelEpg.fromJson(decoded);
    } catch (_) {
      // A corrupt or unreadable file reads as a miss — the channel
      // refetches and rewrites it.
      return null;
    }
  }

  Future<void> _writePersistedEpg(String channelKey, _CachedChannelEpg entry) async {
    // 1.4.4: a tombstoned key must not be re-written — a fetch's
    // fire-and-forget persist landing after an Assign/Clear invalidation
    // would otherwise resurrect the stale entry on disk (the read side
    // already guards it, but the stale file would surface after a
    // restart, once the heal's re-fetch has consumed the tombstone).
    if (_epgInvalidatedKeys.contains(channelKey)) return;
    try {
      final file = await _epgCacheFile(channelKey);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(entry.toJson()));
    } catch (e) {
      appLogger.w('IPTV EPG cache write failed for channel $channelKey', error: e);
    }
  }

  /// Delete the persisted EPG directory for one connection
  /// (`iptv_epg/<b64(id)>`) — the per-connection half of
  /// `removeIptvConnectionEverywhere`. Static so the removal routine can
  /// run without a live client for the connection. Same seams as the
  /// instance path: no-op when [debugDisablePersistedEpg], honors
  /// [debugEpgCacheDirectoryProvider]. Never throws.
  static Future<void> deletePersistedEpgForConnection(String connectionId) async {
    if (debugDisablePersistedEpg) return;
    try {
      final base = await (debugEpgCacheDirectoryProvider ?? getApplicationCacheDirectory)();
      final dir = Directory('${base.path}/iptv_epg/${_fileSafe(connectionId)}');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      appLogger.w('IPTV EPG cache delete failed', error: e);
    }
  }

  Future<void> _deletePersistedEpg() async {
    // 1.6.34: no-op when the persisted side is disabled — same seam
    // as the read/write/prune paths above. When the flag is on nothing
    // is ever persisted, so there is nothing to delete; and the real
    // async file check below never completes in `testWidgets`' fake
    // async zone (the wall the read path's comment at
    // [_readPersistedEpg] already documents), so an ungated delete
    // would park `clearEpgCache` forever in a widget test.
    await deletePersistedEpgForConnection(_client.connection.id);
  }

  /// Delete per-channel EPG files older than [ttl] (build #26, 26.6):
  /// the per-channel files were never pruned, so browsed channels
  /// accumulated forever. Best-effort and fire-and-forget — a failure
  /// never breaks the guide. Manual-only (null ttl) never prunes: the
  /// cache never expires, so neither do its files. The feed file
  /// (`feed_*.xml`) is governed by its own TTL logic and is never
  /// touched here.
  Future<void> _pruneStalePersistedEpg(Duration? ttl) async {
    if (ttl == null || debugDisablePersistedEpg) return;
    try {
      final dir = await _epgCacheDir();
      if (!await dir.exists()) return;
      final cutoff = DateTime.now().subtract(ttl);
      // Recursive: per-channel files live in a per-connection
      // subdirectory (iptv_epg/<conn>/<safe>.json) — a non-recursive
      // listing only sees the subdirectory itself, never the files.
      await for (final entity in dir.list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          if ((await entity.lastModified()).isBefore(cutoff)) await entity.delete();
        } catch (_) {
          // One unreadable file does not stop the prune.
        }
      }
    } catch (_) {
      // Best-effort: the guide never depends on the prune.
    }
  }

  /// Programs overlapping [from, to] (the guide's 6-hour window).
  static List<LiveTvProgram> _slice(List<LiveTvProgram> programs, DateTime from, DateTime to) {
    final fromEpoch = from.millisecondsSinceEpoch ~/ 1000;
    final toEpoch = to.millisecondsSinceEpoch ~/ 1000;
    return programs.where((p) => (p.endsAt ?? 0) > fromEpoch && (p.beginsAt ?? 0) < toEpoch).toList(growable: false);
  }

  /// D7: true when [entry] was mapped from a feed generation that has
  /// since been superseded — either the in-memory guide for one of its
  /// feeds is newer than the stamped generation, or a refresh is in
  /// flight for one of its feeds right now (the refetch awaits it, so
  /// the new data is not missed while the download runs). Entries from
  /// short-EPG alone (empty generations) are never stale this way, and
  /// an entry whose feed is not loaded in memory cannot be judged — it
  /// serves (a cold guide has no newer generation to compare).
  bool _isFeedGenerationStale(_CachedChannelEpg entry) {
    for (final stamp in entry.feedGenerations.entries) {
      final current = _xmltvCache[stamp.key];
      if (current != null && current.fetchedAt.isAfter(stamp.value)) return true;
      if (_xmltvGuideFutures.containsKey(stamp.key)) return true;
    }
    return false;
  }

  /// Xtream EPG, TiviMate-style (build #8 Task 3): per-channel
  /// `get_short_epg` answers FIRST for the visible channel. If it has
  /// nothing for the channel, the login's big `xmltv.php` feed is fetched
  /// (one shared fetch for the whole catalog, deduped by
  /// [_fetchFeedPrograms]) and matched by tvg-id — build #26 (R3): the
  /// feed used to start loading in the background on EVERY channel fetch,
  /// even when short-EPG answered, which downloaded + parsed ~150 MB for
  /// nobody. The old order — xmltv first — made every visible row wait on
  /// a 55k-channel file (tens of MB, up to 120s) before showing anything.
  /// A channel is never left blank by a missing or partial feed — and a
  /// fetch only THROWS when both sources fail: if either source answers
  /// (even empty), that answer stands, so a genuine empty is never
  /// misread as a failure. 1.1.2 D1a: a feed that FAILS does not count
  /// as "answering" — only a feed that LOADS but has nothing for the
  /// channel answers empty. A playback-gate deferral is neither a
  /// failure nor an answer (see [_fetchXtreamEpgWithAbort]).
  /// (1.2.1 D4) A non-empty short-EPG answer at exactly the limit is
  /// treated as possibly truncated: the feed tail fills the days the
  /// limit cut off (see [_mergeFeedIntoHoles] — the tail is the last
  /// gap, filled regardless of size when at the limit).
  Future<({List<LiveTvProgram> programs, IptvEpgSource source, bool feedDeferred, String? sourceId, String? matchedXmltvId, String? matchMethod, Map<String, DateTime> feedGenerations, bool shortEpgTimedOut, Future<List<LiveTvProgram>>? lateShortEpg})> _fetchXtreamEpg(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
    Duration? ttl, {
    bool force = false,
    bool bypassFeedGate = false,
  }) async {
    // Build #28: this channel's fetch owns an AbortController, so a row
    // that scrolls away (or the app backgrounding) stops it instead of
    // letting it run to completion unobserved. The shared feed download
    // is NOT aborted by it — other visible rows may still need it (see
    // [cancelEpgFetchForChannel]).
    final abort = AbortController();
    _epgAbortsByChannel[channelKey] = abort;
    _activeEpgAborts.add(abort);
    // 1.2.15 R1: when the first-paint timeout fires, the short-EPG
    // request stays alive in the background — the controller must stay
    // registered until that late request settles, so a scroll-away
    // cancel or the app backgrounding still aborts it. Without a late
    // request the controller is removed here as before.
    Future<List<LiveTvProgram>>? lateShortEpg;
    try {
      final result = await _fetchXtreamEpgWithAbort(channelKey, settings, from, to, ttl, abort, force: force, bypassFeedGate: bypassFeedGate);
      lateShortEpg = result.lateShortEpg;
      return result;
    } finally {
      if (lateShortEpg == null) {
        _activeEpgAborts.remove(abort);
        if (identical(_epgAbortsByChannel[channelKey], abort)) {
          _epgAbortsByChannel.remove(channelKey);
        }
      } else {
        unawaited(
          lateShortEpg.whenComplete(() {
            _activeEpgAborts.remove(abort);
            if (identical(_epgAbortsByChannel[channelKey], abort)) {
              _epgAbortsByChannel.remove(channelKey);
            }
          }),
        );
      }
    }
  }

  Future<({List<LiveTvProgram> programs, IptvEpgSource source, bool feedDeferred, String? sourceId, String? matchedXmltvId, String? matchMethod, Map<String, DateTime> feedGenerations, bool shortEpgTimedOut, Future<List<LiveTvProgram>>? lateShortEpg})> _fetchXtreamEpgWithAbort(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
    Duration? ttl,
    AbortController abort, {
    bool force = false,
    bool bypassFeedGate = false,
  }) async {
    // Build #26 (R3): the feed is fetched LAZILY — only when
    // get_short_epg misses or fails for this channel. The old code
    // started the big feed download unconditionally, in the background,
    // on every channel fetch, even when short-EPG answered the row — a
    // ~150 MB download + a whole-document parse for nobody, on every
    // stale channel visit. Concurrent misses still share ONE download:
    // [_xmltvGuideForKey] dedups in-flight fetches per key.
    List<LiveTvProgram>? shortEpg;
    bool shortEpgAtLimit = false;
    // 1.2.15 R1: whether short-EPG timed out at first paint (its
    // request still runs in the background) and that late request.
    var shortEpgTimedOut = false;
    Future<List<LiveTvProgram>>? lateShortEpg;
    try {
      final fetched = await _fetchXtreamShortEpg(channelKey, settings, from, to, abort.trigger);
      shortEpg = fetched.programs;
      shortEpgAtLimit = fetched.atLimit;
      shortEpgTimedOut = fetched.timedOut;
      lateShortEpg = fetched.latePrograms;
    } catch (e) {
      // A cancellation is not a failure — the row scrolled away or the
      // app backgrounded. Do not fall through to the feed: the fetch is
      // over, and waiting on a download nobody watches is the waste
      // this cancel exists to stop.
      if (MediaServerHttpException.from(e).isCancellation) rethrow;
      appLogger.w('IPTV: get_short_epg failed for channel $channelKey; using xmltv.php', error: e);
    }
    if (shortEpg != null && shortEpg.isNotEmpty) {
      // 1.2.20 (c): the feed fills the holes in a short-EPG answer —
      // an untitled programme (H1) or a gap (H2). The D4 tail case
      // (short-EPG at the limit, truncated) is just the last gap. A
      // cancel that landed while short-EPG answered is honoured before
      // the merge (same as the feed fallback below). The merge's guard
      // returns short EPG unchanged when the feed is not already
      // available — no download, no slide, no parse.
      abort.throwIfAborted();
      final merged = await _mergeFeedIntoHoles(
        channelKey,
        settings,
        shortEpg,
        from,
        to,
        ttl,
        shortEpgAtLimit: shortEpgAtLimit,
        force: force,
        bypassFeedGate: bypassFeedGate,
      );
      return (programs: merged.programs, source: merged.source, feedDeferred: false, sourceId: merged.sourceId, matchedXmltvId: merged.matchedXmltvId, matchMethod: merged.matchMethod, feedGenerations: merged.feedGenerations, shortEpgTimedOut: false, lateShortEpg: null);
    }
    // get_short_epg had nothing (or failed): use the feed, starting it
    // now. A feed that loads but has nothing for the channel returns
    // [] (genuine empty); a feed that FAILS throws (1.1.2 D1a) — a
    // failed feed is not a source answering empty, even when
    // get_short_epg already answered empty.
    //
    // Build #28: a cancel that landed after get_short_epg answered is
    // honoured here, before waiting on the feed — the row scrolled away
    // or the app backgrounded, and the feed is a download nobody watches.
    abort.throwIfAborted();
    try {
      final feed = await _fetchFeedPrograms(channelKey, settings, from, to, ttl, force: force, bypassFeedGate: bypassFeedGate);
      if (feed.feedDeferred) {
        // D1b (now inside the multi-source fetch): every source deferred
        // by the playback gate — not a failure and not a genuine empty.
        // Return empty without caching; the deferral is already recorded
        // by _fetchFeedPrograms, so the idle listener bumps the guide
        // version and the channel reloads when playback stops.
        return (
          programs: const <LiveTvProgram>[],
          source: IptvEpgSource.none,
          feedDeferred: true,
          sourceId: null,
          matchedXmltvId: null,
          matchMethod: null,
          feedGenerations: const <String, DateTime>{},
          shortEpgTimedOut: shortEpgTimedOut,
          lateShortEpg: lateShortEpg,
        );
      }
      return (
        programs: feed.programs,
        source: feed.source,
        feedDeferred: false,
        sourceId: feed.sourceId,
        matchedXmltvId: feed.matchedXmltvId,
        matchMethod: feed.matchMethod,
        feedGenerations: feed.feedGenerations,
        shortEpgTimedOut: shortEpgTimedOut,
        lateShortEpg: lateShortEpg,
      );
    } catch (e) {
      // A cancellation is not a failure (build #28): the app
      // backgrounded mid-download. The gate test pins the old
      // behaviour here — a cancelled feed yields an empty guide, not
      // a throw — so keep returning [] for cancellations; only a
      // genuine feed FAILURE takes the D1a rethrow below.
      if (MediaServerHttpException.from(e).isCancellation) {
        return (
          programs: const <LiveTvProgram>[],
          source: IptvEpgSource.none,
          feedDeferred: false,
          sourceId: null,
          matchedXmltvId: null,
          matchMethod: null,
          feedGenerations: const <String, DateTime>{},
          shortEpgTimedOut: shortEpgTimedOut,
          lateShortEpg: lateShortEpg,
        );
      }
      if (shortEpgTimedOut && lateShortEpg != null) {
        // 1.2.15 R1: short-EPG has NOT answered — it timed out at first
        // paint and is still running. A feed failure on top of a
        // pending answer is not "both sources failed" (D1a): return
        // the empty, uncached, and let the late answer heal the row
        // when it lands instead of stranding it in retry state.
        return (
          programs: const <LiveTvProgram>[],
          source: IptvEpgSource.none,
          feedDeferred: false,
          sourceId: null,
          matchedXmltvId: null,
          matchMethod: null,
          feedGenerations: const <String, DateTime>{},
          shortEpgTimedOut: shortEpgTimedOut,
          lateShortEpg: lateShortEpg,
        );
      }
      if (shortEpg != null) {
        // D1a: get_short_epg ANSWERED (empty) and the feed FAILED. A
        // feed that fails is not a source "answering empty" — the
        // build #8 invariant ("a fetch only throws when both sources
        // fail") is met: one source answered empty, the other failed,
        // so the fetch must surface as a failure (guide retry state),
        // not as loaded-empty hour blocks. The old code returned []
        // here and the caller cached it for the whole interval — the
        // phone symptom (every channel hour blocks, no retry state).
        if (!IptvPlaybackActivity.instance.isPlaying) {
          appLogger.w(
            'IPTV: xmltv.php fetch failed for channel $channelKey; get_short_epg already answered empty',
            error: e,
          );
        }
        rethrow;
      }
      rethrow;
    }
  }

  /// D4: short-EPG answered exactly the limit, so the tail days may be
  /// cut off — merge the feed's programmes for the window past the last
  /// short-EPG programme. The feed is consulted only for the uncovered
  /// part ([lastShortEnd, to]); a feed programme starting before the
  /// frontier is dropped, so the same show never renders twice (short
  /// and feed keys differ). A feed that fails or defers loses only the
  /// tail — the short-EPG programmes are real and still served. A
  /// cancellation is not a failure: it rethrows, like the feed fallback.
  /// Whether feed rows are already available for [channelKey]'s sources
  /// (1.2.20 (c) merge guard): the feed is in `_xmltvCache`, or a valid
  /// row store exists for the source's cache key. False means the merge
  /// must not run — no download, no slide, no parse. A row short EPG
  /// answers must never trigger a feed load. (T0 never has rows — the
  /// guard is false there, so hole-fill is off on that tier.)
  Future<bool> _feedRowsAvailableFor(String channelKey) async {
    final attempts = await _epgSourceAttempts();
    for (final attempt in attempts) {
      if (_xmltvCache[attempt.cacheKey] != null) return true;
      try {
        final xmlFile = await _xmltvFeedFile(attempt.cacheKey);
        final dbPath = IptvFeedRowStore.dbPathForXmlPath(xmlFile.path);
        if (IptvFeedRowStore.isValid(
          dbPath: dbPath,
          xmlPath: xmlFile.path,
          expectedSha256: _lastFeedDownloads[attempt.cacheKey]?.sha256,
        )) {
          return true;
        }
      } catch (_) {
        // A stat failure is a missing store — keep looking.
      }
    }
    return false;
  }

  /// Overlap in seconds between [aStart, aEnd) and [bStart, bEnd) —
  /// zero when they only touch at an edge.
  static int _overlapSeconds(int aStart, int aEnd, int bStart, int bEnd) {
    final start = aStart > bStart ? aStart : bStart;
    final end = aEnd < bEnd ? aEnd : bEnd;
    return end > start ? end - start : 0;
  }

  /// Merge feed programmes into the holes of a short-EPG answer (1.2.20
  /// (c)): an untitled programme (H1) or a gap (H2) inside an otherwise
  /// good short-EPG answer is filled from the feed, instead of the row
  /// showing "No information" when the feed knows the show. The D4 tail
  /// case (short-EPG at the limit, truncated) is just the last gap —
  /// the trailing gap is filled regardless of its size when
  /// [shortEpgAtLimit].
  ///
  /// The merge never overwrites, truncates, or re-times a TITLED
  /// short-EPG programme. The feed only fills what short EPG leaves
  /// empty or untitled. If the two sources disagree about what is on at
  /// a time short EPG has titled, short EPG wins.
  ///
  /// Untitled means the title is empty or the "Unknown Program"
  /// placeholder the short-EPG mapping stamps on a listing with no
  /// title (see [_mapShortEpgListings]) — the doc's "title.trim() is
  /// empty" never reaches the merge as an empty string, so the
  /// placeholder is the untitled marker.
  ///
  /// Returns the merged programmes, the row source (`mixed` iff at
  /// least one programme came from the feed, else `shortEpg`), and the
  /// feed's source id / matched id / match method / generations when
  /// mixed (so the merged entry is stamped and D7 staleness works).
  /// Generalises the D4 tail merge (deleted): the tail case is the last
  /// gap, and the D4 tail test must pass byte-identically against this
  /// function for the programme list.
  Future<({
    List<LiveTvProgram> programs,
    IptvEpgSource source,
    String? sourceId,
    String? matchedXmltvId,
    String? matchMethod,
    Map<String, DateTime> feedGenerations,
  })> _mergeFeedIntoHoles(
    String channelKey,
    _EpgSettings settings,
    List<LiveTvProgram> shortEpg,
    DateTime from,
    DateTime to,
    Duration? ttl, {
    required bool shortEpgAtLimit,
    bool force = false,
    bool bypassFeedGate = false,
  }) async {
    // Guard: for a NON-limit answer the feed is consulted only when
    // its rows are already available — short EPG is returned unchanged,
    // no download, no slide, no parse. The AT-LIMIT answer is exempt:
    // the old D4 tail merge fetched the feed unconditionally for a
    // truncated answer, and D4 requires that byte-identically — a
    // truncated short-EPG answer is the one case where the row is known
    // incomplete, so the feed load is the pre-existing behaviour, not
    // a new one. (Doc §4's guard, clarified: it governs H1 and
    // interior-H2; the at-limit trailing gap keeps the D4 download.)
    if (!shortEpgAtLimit && !await _feedRowsAvailableFor(channelKey)) {
      return (
        programs: shortEpg,
        source: IptvEpgSource.shortEpg,
        sourceId: null,
        matchedXmltvId: null,
        matchMethod: null,
        feedGenerations: const <String, DateTime>{},
      );
    }
    final fromEpoch = from.millisecondsSinceEpoch ~/ 1000;
    final toEpoch = to.millisecondsSinceEpoch ~/ 1000;
    // Clip + sort the short-EPG answer (the mapping already
    // window-filters, but the merge must not trust that).
    final clipped = shortEpg
        .where((p) => (p.endsAt ?? 0) > fromEpoch && (p.beginsAt ?? 0) < toEpoch)
        .toList(growable: false)
      ..sort((a, b) => (a.beginsAt ?? 0).compareTo(b.beginsAt ?? 0));
    bool isUntitled(LiveTvProgram p) =>
        p.title.trim().isEmpty || p.title == t.liveTv.unknownProgram;
    final titled = clipped.where((p) => !isUntitled(p)).toList(growable: false);
    try {
      final feed = await _fetchFeedPrograms(channelKey, settings, from, to, ttl, force: force, bypassFeedGate: bypassFeedGate);
      if (feed.feedDeferred || feed.programs.isEmpty) {
        return (
          programs: shortEpg,
          source: IptvEpgSource.shortEpg,
          sourceId: null,
          matchedXmltvId: null,
          matchMethod: null,
          feedGenerations: feed.feedGenerations,
        );
      }
      final feedPrograms = feed.programs
          .where((p) => (p.endsAt ?? 0) > fromEpoch && (p.beginsAt ?? 0) < toEpoch)
          .toList(growable: false)
        ..sort((a, b) => (a.beginsAt ?? 0).compareTo(b.beginsAt ?? 0));
      var fromFeed = 0;
      // H1 — untitled programme: replace wholesale with the best
      // overlapping feed programme (>=50% of the untitled programme's
      // duration, non-empty title; max overlap wins, ties earliest
      // start — the feed list is start-sorted, so the first max wins).
      // 1.2.22 §64.7 (F7): when the WHOLE short-EPG answer is
      // untitled there is no titled programme to protect, so the 50%
      // threshold is dropped — any titled feed programme overlapping
      // the slot (>0) wins. A partially titled answer keeps it.
      final fullyUntitled = titled.isEmpty;
      final merged = <LiveTvProgram>[];
      for (final program in clipped) {
        if (!isUntitled(program)) {
          merged.add(program);
          continue;
        }
        final start = program.beginsAt ?? 0;
        final end = program.endsAt ?? 0;
        final duration = end - start;
        LiveTvProgram? best;
        var bestOverlap = 0;
        if (duration > 0) {
          for (final candidate in feedPrograms) {
            if (candidate.title.trim().isEmpty) continue;
            final overlap = _overlapSeconds(start, end, candidate.beginsAt ?? 0, candidate.endsAt ?? 0);
            if (overlap <= 0) continue;
            if (!fullyUntitled && overlap * 2 < duration) continue;
            if (best == null || overlap > bestOverlap) {
              best = candidate;
              bestOverlap = overlap;
            }
          }
        }
        if (best != null) {
          merged.add(best);
          fromFeed++;
        } else {
          merged.add(program);
        }
      }
      // H2 — gaps: maximal sub-ranges of [from, to) covered by no
      // programme in the merged-so-far list. Interior gaps must be
      // >=10 min; the trailing gap (after the last programme) is filled
      // regardless of size when short-EPG was at the limit (D4).
      merged.sort((a, b) => (a.beginsAt ?? 0).compareTo(b.beginsAt ?? 0));
      final gaps = <({int start, int end, bool trailing})>[];
      var cursor = fromEpoch;
      for (final program in merged) {
        final start = program.beginsAt ?? 0;
        final end = program.endsAt ?? 0;
        if (start > cursor) gaps.add((start: cursor, end: start, trailing: false));
        if (end > cursor) cursor = end;
      }
      if (cursor < toEpoch) gaps.add((start: cursor, end: toEpoch, trailing: true));
      const minGapSeconds = 600;
      const minFeedOverlapSeconds = 600;
      final insertions = <LiveTvProgram>[];
      for (final gap in gaps) {
        final gapSeconds = gap.end - gap.start;
        if (!gap.trailing && gapSeconds < minGapSeconds) continue;
        if (gap.trailing && !shortEpgAtLimit && gapSeconds < minGapSeconds) continue;
        // Qualifying feed programmes: overlap the gap by >=10 min and
        // do not overlap any titled short-EPG programme. Dedupe: the
        // same show as a titled programme is never inserted.
        final qualifying = <({LiveTvProgram program, int overlap})>[];
        for (final candidate in feedPrograms) {
          final overlap = _overlapSeconds(gap.start, gap.end, candidate.beginsAt ?? 0, candidate.endsAt ?? 0);
          if (overlap < minFeedOverlapSeconds) continue;
          var overlapsTitled = false;
          var duplicate = false;
          for (final titledProgram in titled) {
            if (_overlapSeconds(titledProgram.beginsAt ?? 0, titledProgram.endsAt ?? 0, candidate.beginsAt ?? 0, candidate.endsAt ?? 0) > 0) {
              overlapsTitled = true;
              break;
            }
            if ((titledProgram.beginsAt ?? 0) == (candidate.beginsAt ?? 0) && titledProgram.title == candidate.title) {
              duplicate = true;
            }
          }
          if (overlapsTitled || duplicate) continue;
          qualifying.add((program: candidate, overlap: overlap));
        }
        // If two qualifying programmes overlap each other, keep the
        // larger gap-overlap (ties: earliest start).
        qualifying.sort((a, b) {
          final byOverlap = b.overlap.compareTo(a.overlap);
          if (byOverlap != 0) return byOverlap;
          return (a.program.beginsAt ?? 0).compareTo(b.program.beginsAt ?? 0);
        });
        for (final entry in qualifying) {
          final candidate = entry.program;
          var overlapsPicked = false;
          for (final picked in insertions) {
            if (_overlapSeconds(picked.beginsAt ?? 0, picked.endsAt ?? 0, candidate.beginsAt ?? 0, candidate.endsAt ?? 0) > 0) {
              overlapsPicked = true;
              break;
            }
          }
          if (overlapsPicked) continue;
          insertions.add(candidate);
          fromFeed++;
        }
      }
      if (fromFeed == 0) {
        return (
          programs: shortEpg,
          source: IptvEpgSource.shortEpg,
          sourceId: null,
          matchedXmltvId: null,
          matchMethod: null,
          feedGenerations: feed.feedGenerations,
        );
      }
      final result = [...merged, ...insertions];
      result.sort((a, b) => (a.beginsAt ?? 0).compareTo(b.beginsAt ?? 0));
      return (
        programs: result,
        source: IptvEpgSource.mixed,
        sourceId: feed.sourceId,
        matchedXmltvId: feed.matchedXmltvId,
        matchMethod: feed.matchMethod,
        feedGenerations: feed.feedGenerations,
      );
    } catch (e) {
      if (MediaServerHttpException.from(e).isCancellation) rethrow;
      return (
        programs: shortEpg,
        source: IptvEpgSource.shortEpg,
        sourceId: null,
        matchedXmltvId: null,
        matchMethod: null,
        feedGenerations: const <String, DateTime>{},
      );
    }
  }

  /// Programmes for one channel out of the connection's XMLTV feeds —
  /// the provider feed plus any enabled third-party sources, in priority
  /// order (PlezTV 1.2.0, §3.1). Per source: a manual assignment is
  /// tried first, then the channel's tvg-id, then its normalized name.
  /// The first source with data wins (TiviMate Premium model); the
  /// "added sources take precedence" toggle puts the added sources
  /// first. A source that fails is recorded in its status and skipped —
  /// a failed source never blocks the next one. A feed that loads but
  /// has nothing for the channel is a genuine empty; a feed that FAILS
  /// (and no source loaded) throws, like the single-feed path did
  /// (1.1.2 D1a). A playback-gate deferral on every source is neither:
  /// it returns [feedDeferred] and nothing is cached (D1b).
  /// The feed ids one channel could match, from the guide's metadata
  /// only (1.2.12): the mapping id, the tvg-id candidates (exact,
  /// folded, numeric), and the name/loose candidates for the
  /// channel's name. No rows are read — this is what the window is
  /// built from, and what [_ensureGuideWindow] checks for missing
  /// rows. [guide] may be null (before the first parse): then only
  /// the id candidates are known and the name candidates wait for
  /// the metadata.
  Set<String> _windowCandidateIds(
    _CachedXmltvGuide? guide,
    String channelKey,
    Map<String, IptvEpgMapping> mappings, {
    bool includeAffiliateGuess = true,
  }) {
    final ids = <String>{};
    final mapping = mappings[channelKey];
    if (mapping != null) ids.add(mapping.xmltvId);
    final epgChannelId = _client.epgChannelIdForChannelKey(channelKey);
    final tvgId = _client.tvgIdForChannelKey(channelKey);
    for (final id in <String?>{epgChannelId, tvgId, channelKey}) {
      if (id == null || id.isEmpty) continue;
      ids.add(id);
      if (guide != null) {
        final folded = guide.foldedChannelIds[id.toLowerCase()];
        if (folded != null) ids.add(folded);
      }
    }
    final streamId = int.tryParse(channelKey);
    if (streamId != null && streamId > 0 && guide != null) {
      final numeric = guide.numericChannelIds[streamId];
      if (numeric != null) ids.add(numeric);
    }
    if (guide != null) {
      final channelName = _client.channelNameForChannelKey(channelKey);
      if (channelName != null && channelName.isNotEmpty) {
        final key = normalizeEpgChannelName(channelName);
        if (key.isNotEmpty) ids.addAll(guide.nameCandidatesFor(key));
        final looseKey = looseEpgChannelNameKey(channelName);
        if (looseKey.isNotEmpty) ids.addAll(guide.looseCandidatesFor(looseKey));
        // 1.3.29 tier 5.5: the affiliate guess is a candidate too —
        // the window must hold the pick's rows before the match runs,
        // or the per-channel fetch picks the right id and then
        // reports it out-of-window. One id, not the whole word pool,
        // so the window cap is untouched. Neighbours skip it (their
        // own fetches ensure theirs) — see [_windowFeedIdsFor].
        if (includeAffiliateGuess) {
          final guess = _affiliateGuessFor(guide, channelName, epgChannelId, tvgId);
          if (guess != null) ids.add(guess);
        }
      }
    }
    return ids;
  }

  /// The window feed ids for a fetch of [channelKey] (1.2.12): the
  /// channel's own candidates plus the guide-order neighbours' (+/-25
  /// guide positions) candidates, capped at
  /// [_CachedXmltvGuide.maxWindowFeedIds] with the triggering
  /// channel's ids first. [guide] may be null (before the first
  /// parse) — then only id candidates are known.
  Future<Set<String>> _windowFeedIdsFor(
    String channelKey,
    _CachedXmltvGuide? guide,
    Map<String, IptvEpgMapping> mappings,
  ) async {
    final ids = _windowCandidateIds(guide, channelKey, mappings);
    try {
      // 1.2.18 C-1: the cached guide list + key→index map answer O(1)
      // instead of rebuilding the 26k-row list and scanning it per fetch.
      final guideChannels = await _client.guideChannelsWithIndex();
      final channels = guideChannels.channels;
      final index = guideChannels.indexByKey[channelKey] ?? -1;
      if (index >= 0) {
        for (var offset = 1; offset <= 25; offset++) {
          for (final i in [index - offset, index + offset]) {
            if (i < 0 || i >= channels.length) continue;
            // Neighbours are prefetch margin, not a trigger — their
            // affiliate guesses stay out (their own fetches ensure
            // theirs), so a row fetch does not pay the word-pool
            // scoring for 50 neighbours.
            ids.addAll(_windowCandidateIds(guide, channels[i].key, mappings, includeAffiliateGuess: false));
            if (ids.length >= _CachedXmltvGuide.maxWindowFeedIds) {
              return ids.take(_CachedXmltvGuide.maxWindowFeedIds).toSet();
            }
          }
        }
      }
    } catch (_) {
      // The channel list failed to load — the window is just this
      // channel's candidates; the match slides it if it needs more.
    }
    return ids.length > _CachedXmltvGuide.maxWindowFeedIds
        ? ids.take(_CachedXmltvGuide.maxWindowFeedIds).toSet()
        : ids;
  }

  /// Ensure [guide]'s window holds the rows the match for
  /// [channelKey] could need (1.2.12): when the channel's OWN
  /// candidate ids have retained programmes but no rows in the window,
  /// the window slides — the persisted feed file is re-parsed with
  /// the new window (no download), or the feed is re-downloaded when
  /// there is no persisted file. Returns the guide to match against
  /// (the same object when the window already covers the channel).
  ///
  /// Only the triggering channel's candidates can force a slide: the
  /// neighbours are prefetch margin, not a trigger — otherwise every
  /// scrolled row would extend the window by one and re-parse the
  /// feed (at Trex scale, once per row). The slide's window is still
  /// the full neighbourhood ([includeNeighbors]), so a slide covers
  /// ~50 rows before the next one is needed.
  Future<_CachedXmltvGuide> _ensureGuideWindow(
    String cacheKey,
    XmltvFeedFetcher fetchFeed,
    _CachedXmltvGuide guide,
    String channelKey,
    Map<String, IptvEpgMapping> mappings, {
    bool includeNeighbors = false,
  }) async {
    final ownIds = _windowCandidateIds(guide, channelKey, mappings);
    final missing = ownIds.where(
      (id) => guide.hasRetainedPrograms(id) && guide.rowsFor(id).isEmpty,
    ).toSet();
    if (missing.isEmpty) return guide;
    final ids = includeNeighbors
        ? await _windowFeedIdsFor(channelKey, guide, mappings)
        : ownIds;
    return _slideGuideWindow(cacheKey, fetchFeed, ids, guide.fetchedAt);
  }

  /// Slide one feed's window (1.2.12): re-parse the persisted feed
  /// file with [retainIds] (the file IS the store — no download), or
  /// re-download when there is no persisted file. The new guide
  /// replaces the cached one; a file slide keeps the original
  /// fetchedAt (same bytes, same generation), a download slide stamps
  /// now (new bytes, new generation).
  /// True when [guide] already holds rows for every id in [ids] that
  /// has retained programmes — the same coverage test
  /// [_ensureGuideWindow] uses to decide a slide is needed.
  static bool _guideCoversIds(_CachedXmltvGuide guide, Set<String> ids) =>
      ids.every((id) => !guide.hasRetainedPrograms(id) || guide.rowsFor(id).isNotEmpty);

  Future<_CachedXmltvGuide> _slideGuideWindow(
    String cacheKey,
    XmltvFeedFetcher fetchFeed,
    Set<String> retainIds,
    DateTime fetchedAt,
  ) async {
    // Join an in-flight slide for this key when it covers our ids;
    // otherwise wait for it to finish and slide after it (serialized,
    // never concurrent) — a second parse only when the first did not
    // cover what this caller needs.
    final inFlightSlide = _xmltvSlideFutures[cacheKey];
    if (inFlightSlide != null) {
      try {
        final slid = await inFlightSlide;
        if (_guideCoversIds(slid, retainIds)) return slid;
      } catch (_) {
        // The first slide failed — fall through and try our own.
      }
    }
    final future = _slideGuideWindowLocked(cacheKey, fetchFeed, retainIds, fetchedAt);
    _xmltvSlideFutures[cacheKey] = future;
    try {
      return await future;
    } finally {
      _xmltvSlideFutures.removeWhere((key, value) => key == cacheKey && identical(value, future));
    }
  }

  Future<_CachedXmltvGuide> _slideGuideWindowLocked(
    String cacheKey,
    XmltvFeedFetcher fetchFeed,
    Set<String> retainIds,
    DateTime fetchedAt,
  ) async {
    // 1.2.20 (a): the store answers the slide first — an indexed
    // lookup (tens of ms) instead of a whole-file re-parse. The
    // re-parse below is the fallback for a missing/corrupt store.
    final slideStopwatch = Stopwatch()..start();
    final fromStore = await _readFeedRowsFromStore(
      cacheKey,
      retainIds: retainIds,
      fetchedAt: fetchedAt,
    );
    if (fromStore != null) {
      _xmltvCache[cacheKey] = fromStore;
      EpgCadenceLog.recordWindowSlide(
        sourceKey: cacheKey,
        programsRetained: fromStore.totalProgramCount,
        durationMs: slideStopwatch.elapsedMilliseconds,
        source: 'store',
      );
      return fromStore;
    }
    final slid = await _readPersistedXmltv(cacheKey, retainIds: retainIds, fetchedAtOverride: fetchedAt, caller: 'slide');
    if (slid != null) {
      _xmltvCache[cacheKey] = slid;
      // L-44: a slide re-parses the persisted file — a re-parse, not a
      // re-download. The slide count is the cadence context.
      EpgCadenceLog.recordWindowSlide(
        sourceKey: cacheKey,
        programsRetained: slid.totalProgramCount,
        durationMs: slideStopwatch.elapsedMilliseconds,
        source: 'parse',
      );
      return slid;
    }
    return _startXmltvDownload(cacheKey, fetchFeed, retainIds: retainIds);
  }

  /// Store-only window slide (1.2.20 (b)): the Reload's end-of-load
  /// slide. Returns the slid guide, or null when no valid store
  /// exists — the Reload NEVER falls back to a re-parse slide (its
  /// hard rule is to never get slower), so a null means "slide
  /// skipped", not "slide failed, try the slow path".
  Future<_CachedXmltvGuide?> _slideGuideWindowFromStore(
    String cacheKey,
    Set<String> retainIds,
    DateTime fetchedAt,
  ) async {
    final slideStopwatch = Stopwatch()..start();
    final fromStore = await _readFeedRowsFromStore(
      cacheKey,
      retainIds: retainIds,
      fetchedAt: fetchedAt,
    );
    if (fromStore == null) return null;
    _xmltvCache[cacheKey] = fromStore;
    EpgCadenceLog.recordWindowSlide(
      sourceKey: cacheKey,
      programsRetained: fromStore.totalProgramCount,
      durationMs: slideStopwatch.elapsedMilliseconds,
      source: 'store',
    );
    return fromStore;
  }

  /// Slide the Reload's end-of-load window (1.2.20 (b)): after the
  /// match loop, the window already holds the feed rows for the rows
  /// the user is looking at, so the guide opens with programmes on it
  /// instead of filling in minutes later.
  ///
  /// The rows come from the visible-row registry (most-recent first,
  /// deduped); when the registry is empty, the first screen (the first
  /// `maxWindowFeedIds` channels in guide order) is slid instead. The
  /// slide is ONE store lookup with the union of the rows' candidate
  /// feed ids, capped at `maxWindowFeedIds` — not one
  /// `_ensureGuideWindow` per key (each would replace the window with
  /// that key's ids, so only the last key's rows would survive).
  /// The store is the only source: when no valid store exists the
  /// slide is skipped entirely (never a re-parse inside the Reload —
  /// the hard rule), and the result says so. A failed/skipped slide
  /// never changes the Reload's success.
  Future<({bool slid, int channelCount, String? reason})> _slideReloadWindow(
    _LoadedEpgFeeds outcome,
    List<LiveTvChannel>? channels,
    Map<String, IptvEpgMapping> mappings,
  ) async {
    // T0: no feed is ever loaded, so there is nothing to slide — skip
    // silently; the existing no-feed dialog lines already cover it.
    final maxIds = _CachedXmltvGuide.maxWindowFeedIds;
    if (maxIds == 0) return (slid: false, channelCount: 0, reason: null);
    if (outcome.loaded.isEmpty) return (slid: false, channelCount: 0, reason: 'no-feed');
    // The rows to prepare: the registry, or the first screen when it
    // is empty (the guide was never opened, or >60 s since the last
    // fetch).
    var keys = _recentGuideFetchKeys();
    if (keys.isEmpty) {
      if (channels == null || channels.isEmpty) return (slid: false, channelCount: 0, reason: null);
      keys = channels.take(maxIds).map((c) => c.key).toList(growable: false);
    }
    // The union of the rows' candidate feed ids, capped at the tier cap.
    final firstGuide = outcome.loaded.first.guide;
    final ids = <String>{};
    for (final key in keys) {
      ids.addAll(_windowCandidateIds(firstGuide, key, mappings));
      if (ids.length >= maxIds) break;
    }
    final retainIds = ids.length > maxIds ? ids.take(maxIds).toSet() : ids;
    // Skip the slide entirely when no loaded feed has a valid store:
    // the cheap pre-check (a sync validity read, no Isolate.run, no
    // re-parse) so the slide path is genuinely not called then.
    var anyStore = false;
    for (final entry in outcome.loaded) {
      try {
        final xmlFile = await _xmltvFeedFile(entry.attempt.cacheKey);
        final dbPath = IptvFeedRowStore.dbPathForXmlPath(xmlFile.path);
        if (IptvFeedRowStore.isValid(
          dbPath: dbPath,
          xmlPath: xmlFile.path,
          expectedSha256: _lastFeedDownloads[entry.attempt.cacheKey]?.sha256,
        )) {
          anyStore = true;
          break;
        }
      } catch (_) {
        // A stat failure is a missing store — keep looking.
      }
    }
    if (!anyStore) return (slid: false, channelCount: 0, reason: 'store-unavailable');
    try {
      var slid = false;
      for (final entry in outcome.loaded) {
        final slidGuide = await _slideGuideWindowFromStore(
          entry.attempt.cacheKey,
          retainIds,
          entry.guide.fetchedAt,
        );
        if (slidGuide != null) slid = true;
      }
      if (!slid) return (slid: false, channelCount: 0, reason: 'store-unavailable');
      appLogger.i('IPTV: Reload slid the guide window for ${keys.length} rows (${retainIds.length} feed ids)');
      return (slid: true, channelCount: keys.length, reason: null);
    } catch (e) {
      appLogger.w('IPTV: Reload window slide failed', error: e);
      return (slid: false, channelCount: 0, reason: 'slide-failed');
    }
  }

  /// Read a guide from the row store (1.2.20 (a)): metadata for the
  /// whole feed plus the window rows for [retainIds]. Returns null
  /// when there is no persisted XML to anchor a store to, no store
  /// file, or the store is invalid/corrupt/stale for the current
  /// generation. The caller falls back to the re-parse path. The
  /// expected SHA is the last download's SHA when known (a new
  /// download invalidates the old store); the XML stat is read fresh
  /// so a replaced file invalidates it too.
  /// 1.4 F1 test seam: drive one store-backed window slide and report
  /// the window size, its titles (in channel-id order), and the
  /// index-build count, so the harness can assert a slide neither
  /// rebuilds the indexes nor returns the wrong rows. Production code
  /// never calls this.
  @visibleForTesting
  Future<({int windowProgramCount, List<String> windowTitles, int indexBuildCount})> debugSlideGuideFromStore(
    String cacheKey,
    Set<String> retainIds,
  ) async {
    final guide = await _readFeedRowsFromStore(cacheKey, retainIds: retainIds);
    final titles = <String>[];
    if (guide != null) {
      final ids = guide.windowByChannel.keys.toList()..sort();
      for (final id in ids) {
        titles.addAll(guide.windowByChannel[id]!.map((p) => p.title));
      }
    }
    return (
      windowProgramCount: guide?.windowProgramCount ?? -1,
      windowTitles: titles,
      indexBuildCount: _XmltvGuideIndexes.buildCount,
    );
  }

  Future<_CachedXmltvGuide?> _readFeedRowsFromStore(
    String cacheKey, {
    required Set<String> retainIds,
    // When null the guide is stamped with the XML file's last-modified
    // time (the warm-start convention — the file's mtime is the
    // generation's fetch time). A slide passes the current guide's
    // fetchedAt so the generation is unchanged (the persisted slide's
    // fetchedAtOverride).
    DateTime? fetchedAt,
  }) async {
    if (debugDisablePersistedEpg || debugDisableFeedRowStore) return null;
    try {
      final xmlFile = await _xmltvFeedFile(cacheKey);
      final dbPath = IptvFeedRowStore.dbPathForXmlPath(xmlFile.path);
      final window = _epgParseWindow(DateTime.now());
      final fetchedAtValue = fetchedAt ?? xmlFile.lastModifiedSync();
      final expectedSha = _lastFeedDownloads[cacheKey]?.sha256;
      // 1.4 F1: the window-only read first. When this generation's
      // metadata is cached, a slide is one indexed range query plus a
      // shared-indexes guide construction — no 5,583-row re-read, no
      // ten-index rebuild (40.7 s of CPU in the 1.3.29 Fold session).
      final windowRead = await IptvFeedRowStore.readWindowRows(
        dbPath: dbPath,
        xmlPath: xmlFile.path,
        expectedSha256: expectedSha,
        retainIds: retainIds,
        windowFromEpoch: window.fromEpoch,
        windowToEpoch: window.toEpoch,
      );
      if (windowRead != null) {
        final cached = _guideMetadataCache['$cacheKey|${windowRead.generationKey}'];
        if (cached != null) {
          return cached.guide(
            fetchedAt: fetchedAtValue,
            windowByChannel: windowRead.windowByChannel,
          );
        }
      }
      // Cache miss (or no window read): the full read, which also
      // populates the metadata cache for the next slide of this
      // generation. Stale-generation entries for this feed are dropped
      // — one generation per feed is held, never a history.
      final read = await IptvFeedRowStore.readGuide(
        dbPath: dbPath,
        xmlPath: xmlFile.path,
        expectedSha256: expectedSha,
        retainIds: retainIds,
        windowFromEpoch: window.fromEpoch,
        windowToEpoch: window.toEpoch,
        fetchedAt: fetchedAtValue,
      );
      if (read == null) return null;
      final metadata = _XmltvGuideMetadata.fromRead(read);
      _guideMetadataCache.removeWhere((key, _) => key.startsWith('$cacheKey|'));
      _guideMetadataCache['$cacheKey|${read.generationKey}'] = metadata;
      return metadata.guide(
        fetchedAt: read.fetchedAt,
        windowByChannel: read.windowByChannel,
      );
    } catch (_) {
      return null;
    }
  }

  Future<({List<LiveTvProgram> programs, IptvEpgSource source, bool feedDeferred, String? sourceId, String? matchedXmltvId, String? matchMethod, Map<String, DateTime> feedGenerations, bool shortEpgTimedOut, Future<List<LiveTvProgram>>? lateShortEpg})> _fetchFeedPrograms(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
    Duration? ttl, {
    bool force = false,
    bool bypassFeedGate = false,
  }) async {
    // L-20: below 500 MB free, skip the feed download entirely —
    // short-EPG only, same as the T0 tier. The big xmltv.php download
    // (+ its parse + its persisted file) is the guide's largest disk
    // write, and on a nearly-full disk it fails silently or stalls the
    // eMMC. The caller already tried short-EPG first and falls back to
    // it, so returning the empty/none result here is exactly "no feed"
    // — the row renders what short-EPG answered. The latched reading
    // comes from the startup refresh; a user-initiated Reload still
    // downloads (explicit action, and its report names the outcome).
    if (StorageHealth.isLowFreeSpace) {
      appLogger.w('IPTV: provider feed skipped — storage almost full (short-EPG only)');
      return (
        programs: const <LiveTvProgram>[],
        source: IptvEpgSource.none,
        feedDeferred: false,
        sourceId: null,
        matchedXmltvId: null,
        matchMethod: null,
        feedGenerations: const <String, DateTime>{},
        shortEpgTimedOut: false,
        lateShortEpg: null,
      );
    }
    final attempts = await _epgSourceAttempts();
    if (attempts.isEmpty) {
      return (
        programs: const <LiveTvProgram>[],
        source: IptvEpgSource.none,
        feedDeferred: false,
        sourceId: null,
        matchedXmltvId: null,
        matchMethod: null,
        feedGenerations: const <String, DateTime>{},
        shortEpgTimedOut: false,
        lateShortEpg: null,
      );
    }
    // 1.2.19 L-7: survival tier (T0) gets NO feed at all — the 88 MB
    // download + ~25 s parse + 30–80 MB transient is unaffordable
    // there. Short-EPG already ran first (see
    // [_fetchXtreamEpgWithAbort]), so the row keeps whatever short-EPG
    // answered; the feed is never consulted, never downloaded, never
    // parsed. Xtream-only: M3U has no short-EPG, so its feed IS the
    // first source and is never gated (gating it would remove the
    // guide entirely rather than degrade it). Not a deferral
    // ([feedDeferred] stays false): there is nothing to retry later,
    // and the row's short-EPG empty is a genuine empty for this tier
    // — the R6 sampler still counts never-fetched rows separately.
    if (_isXtream && DevicePerformance.currentTier == DeviceTier.survival) {
      if (!_loggedTierNoFeed) {
        _loggedTierNoFeed = true;
        appLogger.i('IPTV: survival tier — XMLTV feed skipped, short-EPG only');
      }
      return (
        programs: const <LiveTvProgram>[],
        source: IptvEpgSource.none,
        feedDeferred: false,
        sourceId: null,
        matchedXmltvId: null,
        matchMethod: null,
        feedGenerations: const <String, DateTime>{},
        shortEpgTimedOut: false,
        lateShortEpg: null,
      );
    }
    // 1.2.14 G1: the feed gate exists only on low-end hardware, and
    // it opens on the FIRST short-EPG miss — reaching here means a
    // row's short-EPG already missed (every Xtream caller has a
    // short-EPG result first), so there is nothing to defer: the feed
    // loads now. Deferring here was the 1.2.12 bug (the row rendered
    // "No information available" for a feed never consulted, for up
    // to 60 s on low-end). On non-low-end hardware there is no gate
    // at all. On low-end the gate's memory purpose survives: the feed
    // still never starts before a row actually needs it.
    if (_isXtream && !bypassFeedGate && !_epgFeedGateOpen && DevicePerformance.isLowEndHardware) {
      _openFeedGate();
    }
    final mappings = await _epgStore.loadMappings();
    final mapping = mappings[channelKey];
    final epgChannelId = _client.epgChannelIdForChannelKey(channelKey);
    final tvgId = _client.tvgIdForChannelKey(channelKey);
    final channelName = _client.channelNameForChannelKey(channelKey);
    var sawDeferred = false;
    var anyLoaded = false;
    Object? lastError;
    StackTrace? lastStackTrace;
    // 1.3.26 §69: the first loaded feed's block, for the per-channel
    // outcome log (same rule as _resolveChannelAcrossFeeds — the
    // first feed that serves wins, otherwise the first feed's block
    // is what the diagnostics name).
    _GuideResolution? firstBlocked;
    // D7: the feed generations consulted for this channel (cache key ->
    // that guide's fetch time), so the per-channel entry can be stamped
    // with the generation it was mapped from.
    final generations = <String, DateTime>{};
    for (final attempt in attempts) {
      _CachedXmltvGuide guide;
      try {
        final started = DateTime.now();
        // 1.2.12: the first load parses with this channel's window
        // (its id candidates + guide-order neighbours); the ensure
        // below slides it once when the match needs a name/loose
        // candidate the first load could not know about.
        final windowIds = await _windowFeedIdsFor(channelKey, null, mappings);
        final (loaded, loadedFresh) = await _loadSourceGuide(attempt.cacheKey, attempt.fetchFeed, ttl, force: force, retainIds: windowIds, attempt: attempt);
        var loadedGuide = loaded;
        loadedGuide = await _ensureGuideWindow(attempt.cacheKey, attempt.fetchFeed, loadedGuide, channelKey, mappings, includeNeighbors: true);
        guide = loadedGuide;
        anyLoaded = true;
        if (loadedFresh) {
          // 1.5.3 K3 (D9): a per-channel load does not stamp "Last
          // updated" — the channel's own stamp below fires only when
          // it stored programmes, so a fetch that stores nothing
          // leaves the stamp (and the Settings pref) alone.
          await _recordSourceSuccess(attempt, guide, started, stampLastUpdated: false);
          // 1.3.27 §P0-4: the feed just moved to a new generation
          // mid-guide-open — rows that completed empty against the
          // old generation must refetch instead of serving their
          // loaded-empty marks until the next open. The whole-guide
          // bump clears the tab's loaded-empty marks; the fresh feed
          // is in-memory, so the refetch serves from cache (no loop:
          // the next fetch finds loadedFresh false).
          _bumpEpgVersion();
        }
      } on _EpgFeedDeferred {
        sawDeferred = true;
        continue;
      } catch (e, st) {
        // A cancellation is not a failure (build #28): the row scrolled
        // away or the app backgrounded — the fetch is over, not a reason
        // to try the next source's download.
        if (MediaServerHttpException.from(e).isCancellation) rethrow;
        lastError = e;
        lastStackTrace = st;
        await _recordSourceFailure(attempt.config, e);
        continue;
      }
      generations[attempt.cacheKey] = guide.fetchedAt;
      if (guide.programCountByChannel.length > _lastXmltvFeedChannelIds) {
        _lastXmltvFeedChannelIds = guide.programCountByChannel.length;
      }
      final match = _matchInGuide(
        guide,
        channelKey,
        mapping,
        attempt.config.id,
        epgChannelId,
        tvgId,
        channelName,
        settings,
        from,
        to,
        keyPrefix: attempt.keyPrefix,
        offsetMinutes: attempt.config.timeShiftMinutes,
        loadRows: true,
      );
      firstBlocked ??= match;
      if (match.matchedXmltvId == null) continue;
      // 1.3.26 §69: per-channel fetch-outcome logging — the next
      // phone log must name the cause per row.
      appLogger.i('IPTV EPG $channelKey: feed matched ${match.matchedXmltvId} via ${match.matchMethod}');
      // 1.4.2: persist a guessed pick — pick one and stick with it.
      // Per-channel path only; the bulk paths never write.
      await _persistGuessedEpgPick(channelKey, match, guide);
      return (
        programs: match.programs,
        source: match.matchMethod == 'name' || match.matchMethod == 'name-loose' || match.matchMethod == 'name-guess' || match.matchMethod == 'name-guess-affiliate'
            ? IptvEpgSource.feedByName
            : IptvEpgSource.feedById,
        feedDeferred: false,
        sourceId: attempt.config.id,
        matchedXmltvId: match.matchedXmltvId,
        matchMethod: match.matchMethod,
        feedGenerations: generations,
        shortEpgTimedOut: false,
        lateShortEpg: null,
      );
    }
    if (!anyLoaded) {
      if (sawDeferred) {
        // Every source deferred — the caller returns an uncached empty
        // (D1b), and the deferral is recorded so the idle listener bumps
        // the guide version and the row re-fetches when playback stops.
        _recordFeedDeferral(channelKey);
        return (
          programs: const <LiveTvProgram>[],
          source: IptvEpgSource.none,
          feedDeferred: true,
          sourceId: null,
          matchedXmltvId: null,
          matchMethod: null,
          feedGenerations: const <String, DateTime>{},
          shortEpgTimedOut: false,
          lateShortEpg: null,
        );
      }
      if (lastError != null) Error.throwWithStackTrace(lastError, lastStackTrace ?? StackTrace.empty);
    }
    // 1.3.26 §69: per-channel fetch-outcome logging — no source
    // matched, so the first feed's block is the reason.
    if (firstBlocked != null && firstBlocked.blockedReason != null) {
      final candidates = firstBlocked.blockedCandidates;
      appLogger.i(
        'IPTV EPG $channelKey: feed blocked ${firstBlocked.blockedReason}'
        '${candidates.isEmpty ? '' : ' (${candidates.join(', ')})'}',
      );
    }
    return (
      programs: const <LiveTvProgram>[],
      source: IptvEpgSource.none,
      feedDeferred: false,
      sourceId: null,
      matchedXmltvId: null,
      matchMethod: null,
      feedGenerations: generations,
      shortEpgTimedOut: false,
      lateShortEpg: null,
    );
  }

  /// 1.4.2: persist a guess-served pick so the row sticks with it.
  /// Called only from the per-channel fetch path
  /// ([_fetchFeedPrograms]) — never from the bulk paths (Reload,
  /// Channels without guide, [_channelHasFeedMatch]), which would
  /// write ~10k rows into the prefs JSON in one Reload. A stored
  /// pick is read by tier 1 on the next load, so the row serves
  /// from the first pass instead of re-guessing from a feed whose
  /// contents drift between generations.
  ///
  /// Rules (research Q5): a manual mapping is never overwritten; a
  /// stored guessed pick is replaced only when it is gone from the
  /// feed entirely (not seen, no retained programmes) and the guess
  /// tier served a different id; still present but out of the
  /// window means keep the pick (no churn); a mapping for another
  /// source is never touched. A prefs failure never fails the fetch
  /// — the row already has its programmes, it just re-guesses next
  /// load.
  Future<void> _persistGuessedEpgPick(
    String channelKey,
    _GuideResolution match,
    _CachedXmltvGuide guide,
  ) async {
    final method = match.matchMethod;
    final matchedId = match.matchedXmltvId;
    final sourceId = match.sourceId;
    if (matchedId == null || sourceId == null) return;
    if (method != 'name-guess-affiliate' && method != 'name-guess') return;
    if (match.programs.isEmpty) return;
    final origin = method == 'name-guess-affiliate' ? 'guessed-affiliate' : 'guessed-name';
    try {
      // Fresh read: an Assign made while this fetch was in flight
      // must not be overwritten by a stale guard.
      final existing = (await _epgStore.loadMappings())[channelKey];
      if (existing != null) {
        if (existing.sourceId != sourceId) return;
        if (existing.origin == 'manual') return;
        if (existing.xmltvId == matchedId) return;
        if (guide.channelIdsSeen.contains(existing.xmltvId) ||
            guide.hasRetainedPrograms(existing.xmltvId)) {
          return;
        }
        appLogger.d(
          'IPTV EPG $channelKey: guessed pick replaced ${existing.xmltvId} -> $matchedId (stored affiliate gone from feed)',
        );
      } else {
        appLogger.d('IPTV EPG $channelKey: guessed pick persisted $matchedId via $method');
      }
      await _epgStore.saveMapping(
        channelKey,
        IptvEpgMapping(xmltvId: matchedId, sourceId: sourceId, origin: origin),
      );
    } catch (e) {
      appLogger.d('IPTV EPG $channelKey: guessed pick not persisted ($e)');
    }
  }

  /// The single best affiliate guess for [channelName] (1.3.29 P1-5,
  /// tier 5.5), or null when no serving feed channel overlaps the
  /// name words. Ranking, best first: (1) region — a non-foreign
  /// candidate ranks above a foreign twin. Non-foreign means the feed
  /// channel's countries are empty or contain the channel's country;
  /// when the channel carries no country, the default region is 'us'
  /// (the provider feed is US-centric and the rows that motivated
  /// this tier are US networks). A foreign twin never wins while a
  /// non-foreign candidate exists, and never serves a channel whose
  /// country is known. Region is binary on purpose: among
  /// non-foreign candidates overlap decides, so a callsign channel's
  /// own affiliate (4 shared words) beats the national feed (1
  /// shared word). (2) word overlap — shared words between the
  /// channel name and the candidate's id + display names. (3)
  /// affiliate shape — a candidate whose extra words are all
  /// number-like (a bare number, or the channel word plus a number:
  /// 'FOX 4', 'fox4', 'PBS 12'), or whose id is a US local affiliate
  /// (`loc.` prefix or a parenthesized US callsign: 1.3.30 — the real
  /// feed's affiliates are callsign+city shaped, `loc.CBS (KTVT)
  /// Fort Worth, TX`), ranks above one with topic words ('Fox News
  /// Channel', 'NBC East Stream'). A bare network word ('FOX') must
  /// only ever guess an affiliate, never a same-word spinoff — 'fox'
  /// alone also matches Fox News, Fox Sports, Fox Soccer, and the
  /// shape rule is what keeps those out. (4) fewest
  /// extra words — the candidate's words the channel does not share.
  /// (5) plain over timeshift. (6) feed id ascending, so the pick is
  /// deterministic for a given feed.
  ///
  /// Gate: a candidate guesses only when it is affiliate-shaped OR
  /// shares at least two words. A single shared word guesses only
  /// the affiliate shape — 'FOX' may guess 'FOX 4' but never 'Fox
  /// News Channel' (unshaped, overlap 1), and 'News' never guesses
  /// a specific news channel. Two shared words are a real name
  /// resemblance ('FOX 2 St. Louis' for 'KTVI FOX 2 St. Louis').
  /// The pick must share at least one word of length 2 or more — a
  /// bare number or single letter never guesses. Unlike H5's tie
  /// rule, a tie on every discriminator is broken by feed id, not
  /// refused: the owner ordered the bare rows filled, and among
  /// same-shape affiliates (FOX 4 vs FOX 5) there is no principled
  /// best — first-sorted is the guess, recorded honestly as one.
  ///
  /// Cost: candidate generation skips one-letter words — a candidate
  /// sharing only a bare number or letter can never satisfy the
  /// meaningful-overlap rule, so skipping it loses nothing and keeps
  /// common numbers ('2', '1') from pulling thousands of ids into
  /// the pool. Timeshift (a regex over re-tokenized names) is
  /// computed only for the candidates tied with the head. [exclude]
  /// is the set of ids the caller already ruled out
  /// (identified-but-empty, foreign twins).
  String? _affiliateGuessFor(
    _CachedXmltvGuide guide,
    String channelName,
    String? epgChannelId,
    String? tvgId, {
    Set<String> exclude = const {},
  }) {
    final channelWords = epgChannelNameWords(channelName).toSet();
    if (channelWords.isEmpty) return null;
    final channelCountry =
        epgChannelCountry(channelName) ??
        epgFeedIdCountry(epgChannelId ?? '') ??
        epgFeedIdCountry(tvgId ?? '');
    // The region a candidate must belong to: the channel's own
    // country when known, else the default 'us'.
    final homeCountry = channelCountry ?? 'us';
    final candidates = <String>{};
    for (final word in channelWords) {
      if (word.length < 2) continue;
      candidates.addAll(guide.wordCandidatesFor(word));
    }
    candidates.removeAll(exclude);
    if (candidates.isEmpty) return null;
    final scored = <({String id, int region, int overlap, bool shaped, int extra})>[];
    for (final id in candidates) {
      final feedWords = guide.feedWordsById[id] ?? const <String>{};
      final shared = feedWords.intersection(channelWords);
      if (shared.isEmpty) continue;
      if (shared.where((w) => w.length >= 2).isEmpty) continue;
      final countries = guide.feedCountriesById[id] ?? const <String>{};
      final isForeign = countries.isNotEmpty && !countries.contains(homeCountry);
      if (isForeign && channelCountry != null) continue;
      final extraWords = feedWords.difference(channelWords);
      // 1.3.30: the real feed's affiliates are callsign+city shaped
      // (`loc.CBS (KTVT) Fort Worth, TX`) — their extra words are not
      // number-like, so the old gate never fired for them. A `loc.`
      // prefix or a parenthesized US callsign on the raw id marks the
      // whole id as affiliate-shaped, whatever its other words are.
      // Spinoffs carry neither signal, so they stay refused.
      final shaped =
          extraWords.every((w) => _epgExtraWordIsNumberLike(w, channelWords)) || _epgIsLocalAffiliateId(id);
      // The gate: a single shared word guesses only the affiliate
      // shape; two shared words are a real resemblance.
      if (!shaped && shared.length < 2) continue;
      scored.add((
        id: id,
        region: isForeign ? 0 : 1,
        overlap: shared.length,
        shaped: shaped,
        extra: extraWords.length,
      ));
    }
    // A foreign twin never wins while a non-foreign candidate
    // exists: drop rank-0 candidates when any rank-1 candidate is
    // present.
    final hasHome = scored.any((s) => s.region > 0);
    final ranked = (hasHome ? scored.where((s) => s.region > 0) : scored).toList(growable: false)
      ..sort((a, b) {
        final region = b.region.compareTo(a.region);
        if (region != 0) return region;
        final overlap = b.overlap.compareTo(a.overlap);
        if (overlap != 0) return overlap;
        if (a.shaped != b.shaped) return a.shaped ? -1 : 1;
        final extra = a.extra.compareTo(b.extra);
        if (extra != 0) return extra;
        return a.id.compareTo(b.id);
      });
    if (ranked.isEmpty) return null;
    // Timeshift is the last discriminator and the expensive one: only
    // the candidates tied with the head on region, overlap, shape
    // and extra pay for it. The tied list stays in id order (the
    // sort above), so the first plain one — or the first one when
    // none is plain — is the deterministic pick.
    final head = ranked.first;
    final tied = ranked
        .takeWhile((s) => s.region == head.region && s.overlap == head.overlap && s.shaped == head.shaped && s.extra == head.extra)
        .toList(growable: false);
    if (tied.length == 1) return head.id;
    final plain = tied.where((s) => !_epgHasTimeshift(s.id, guide.displayNames[s.id] ?? const <String>[])).toList(growable: false);
    return (plain.isEmpty ? tied : plain).first.id;
  }

  /// The match chain for one loaded guide (shared by the fetch path, the
  /// local details probe, and the without-guide computation): a manual
  /// assignment for this source first, then the tvg-id (exact,
  /// case-insensitive, numeric), then the normalized name against the
  /// feed's display names and ids, then — whenever the channel's country
  /// is known — the loose name. Never null: a non-match names its
  /// reason, so the diagnostics can say why instead of only counting.
  _GuideResolution _matchInGuide(
    _CachedXmltvGuide guide,
    String channelKey,
    IptvEpgMapping? mapping,
    String? sourceId,
    String? epgChannelId,
    String? tvgId,
    String? channelName,
    _EpgSettings settings,
    DateTime from,
    DateTime to, {
    required String keyPrefix,
    int? offsetMinutes,
    bool loadRows = true,
  }) {
    List<LiveTvProgram> mapPrograms(List<XmltvProgram> rows) => _mapXmltvPrograms(
          rows,
          channelKey,
          settings,
          from,
          to,
          keyPrefix: keyPrefix,
          offsetMinutes: offsetMinutes,
        );

    // 1.2.12: how a tier proves "programmes in the window". With
    // loadRows true (the per-channel fetch path) the rows come from
    // the guide's window ([rowsFor]) and are mapped exactly as
    // before — the caller must have ensured the window holds the
    // candidate ids first (see [_ensureGuideWindow]). With loadRows
    // false (the bulk paths: Reload, [channelsWithoutGuide],
    // [_channelHasFeedMatch]) the tiers use the guide's metadata
    // only — [hasProgramsInWindow] (the slot bitmap) for the
    // in-window check and [hasRetainedPrograms] for the "serving"
    // check — and the resolution carries no programmes (bulk callers
    // never read them). The match decision is identical either way:
    // the bitmap answers exactly what mapping the rows would have
    // answered.
    bool hasInWindow(String feedId) {
      if (!loadRows) return guide.hasProgramsInWindow(feedId, from, to);
      // 1.2.18 C-3: the rows were mapped once just to test
      // non-emptiness, then mapped again on a match — the overlap test
      // alone answers the existence question exactly (the same
      // predicate the mapper filters with, timeshift included),
      // without constructing programmes or sorting them.
      final offsetSeconds = (offsetMinutes ?? settings.timeOffsetMinutes) * 60;
      final fromEpoch = from.millisecondsSinceEpoch ~/ 1000;
      final toEpoch = to.millisecondsSinceEpoch ~/ 1000;
      return guide.rowsFor(feedId).any((entry) {
        final beginsAt = entry.startEpoch + offsetSeconds;
        final endsAt = entry.stopEpoch + offsetSeconds;
        return endsAt > beginsAt && endsAt > fromEpoch && beginsAt < toEpoch;
      });
    }

    List<LiveTvProgram> programsFor(String feedId) =>
        loadRows ? mapPrograms(guide.rowsFor(feedId)) : const <LiveTvProgram>[];

    _GuideResolution matched(List<LiveTvProgram> programs, String xmltvId, String method) => (
          programs: programs,
          matchedXmltvId: xmltvId,
          matchMethod: method,
          sourceId: sourceId,
          blockedReason: null,
          blockedCandidates: const <String>[],
        );

    _GuideResolution blocked(String reason, [List<String> candidates = const <String>[]]) => (
          programs: const <LiveTvProgram>[],
          matchedXmltvId: null,
          matchMethod: null,
          sourceId: null,
          blockedReason: reason,
          blockedCandidates: candidates,
        );

    // Feed ids that were identified (by id, or by name) but brought no
    // in-window programmes: the loose fallback falls back from these,
    // and the diagnostics name them.
    final identifiedButEmpty = <String>{};

    // 1.2.22 §64.2 (F1): feed ids whose only same-key twin is foreign
    // (tier 5) — never matched, and reported as 'foreign' at the end
    // when nothing else matched.
    final foreignNameCandidates = <String>{};

    // 1. Stored assignment for this source — manual (Assign) or a
    // guessed pick persisted by the per-channel fetch (1.4.2). The
    // method is origin-aware, so a stored guess still reads as a
    // guess in the detail sheet and the Reload counts.
    if (mapping != null && mapping.sourceId == sourceId) {
      if (hasInWindow(mapping.xmltvId)) {
        return matched(programsFor(mapping.xmltvId), mapping.xmltvId, mapping.matchMethod);
      }
      if (guide.hasRetainedPrograms(mapping.xmltvId) ||
          guide.channelIdsSeen.contains(mapping.xmltvId)) {
        identifiedButEmpty.add(mapping.xmltvId);
      }
    }
    // 2. tvg-id, exact. The candidates, in the old order: Xtream tries
    // its `epg_channel_id` then the stream id (the key); M3U tries its
    // tvg-id, which IS the key when present. One list covers both.
    final candidates = <String>{?epgChannelId, ?tvgId, channelKey}.toList(growable: false);
    for (final id in candidates) {
      if (!guide.hasRetainedPrograms(id)) {
        if (guide.channelIdsSeen.contains(id)) identifiedButEmpty.add(id);
        continue;
      }
      if (hasInWindow(id)) return matched(programsFor(id), id, 'tvg-id');
      identifiedButEmpty.add(id);
    }
    // 3. tvg-id, case-insensitive (Fix 3): the fold only names a feed
    // id when exactly one raw id folds to it — two ids differing only
    // in case are never guessed between.
    for (final id in candidates) {
      final fold = id.toLowerCase();
      final feedId = guide.foldedChannelIds[fold];
      if (feedId == null) continue;
      if (hasInWindow(feedId)) return matched(programsFor(feedId), feedId, 'tvg-id');
      identifiedButEmpty.add(feedId);
    }
    // 4. Numeric feed id == stream id (Fix 5, dispatcharr): a feed id
    // that parses as an integer, whole-string, > 0, naming exactly one
    // raw id. Proves itself only when the strings differ ("012345" vs
    // the stream id 12345) — the exact tier already caught the rest.
    final streamId = int.tryParse(channelKey);
    if (streamId != null && streamId > 0) {
      final feedId = guide.numericChannelIds[streamId];
      if (feedId != null) {
        if (hasInWindow(feedId)) return matched(programsFor(feedId), feedId, 'tvg-id');
        identifiedButEmpty.add(feedId);
      }
    }
    // 5. Name, against the feed's display names and ids (Fix 2/7):
    // the name is a match when it names exactly one feed channel —
    // and since 1.3.26 §69, when it names more than one, the first
    // sorted candidate is picked instead of blocking ('name-guess').
    // A channel from another country blocks with 'foreign'. A "+1"
    // timeshift copy loses to the plain channel.
    if (channelName != null && channelName.isNotEmpty) {
      final key = normalizeEpgChannelName(channelName);
      if (key.isNotEmpty) {
        var nameCandidates = guide.nameCandidatesFor(key);
        // 1.2.22 §64.2 (F2): also query the sports-folded form, so a
        // playlist "SKY SPORTS NEWS" finds a feed "Sky Sport News".
        final foldedKey = sportsFoldedEpgChannelNameKey(channelName);
        if (foldedKey.isNotEmpty && foldedKey != key) {
          nameCandidates = {...nameCandidates, ...guide.nameCandidatesFor(foldedKey)};
        }
        final country = epgChannelCountry(channelName);
        if (country != null && nameCandidates.isNotEmpty) {
          final local = nameCandidates.where((id) {
            final countries = epgFeedChannelCountries(id, guide.displayNames[id] ?? const <String>[]);
            return countries.isEmpty || countries.contains(country);
          }).toSet();
          if (local.isEmpty) {
            if (_epgIsProviderLanguageTag(country)) {
              // 1.3.24 §67 F7: the provider uses AR| as an Arabic-
              // language tag, not Argentina, and the feed carries no
              // in-country copy — so the country gate would block
              // this channel forever. Keep all same-key candidates
              // and let the uniqueness gate below decide: exactly one
              // serving copy still matches by name, several are now
              // guessed by the first-sorted rule (1.3.26 §69) instead
              // of staying ambiguous. Do NOT record foreign.
            } else {
              // 1.2.22 §64.2 (F1): do NOT return here — the return
              // skipped the loose tier entirely, so a UK channel whose
              // only same-key twin was foreign never reached the loose
              // match that would have found its UK copy. Record the
              // foreign ids and fall through; tier 6 excludes them, and
              // if nothing else matches the end reports 'foreign'.
              foreignNameCandidates.addAll(nameCandidates);
              nameCandidates = <String>{};
            }
          } else {
            nameCandidates = local;
          }
        }
        final serving = nameCandidates.where((id) => guide.hasRetainedPrograms(id)).toSet();
        if (serving.isEmpty) {
          // Named, but every namesake is a feed id with no retained
          // programmes: identified, not matched — the loose fallback
          // may still find a split copy.
          identifiedButEmpty.addAll(nameCandidates);
        } else {
          var pick = serving;
          if (pick.length > 1) {
            final plain = pick.where((id) => !_epgHasTimeshift(id, guide.displayNames[id] ?? const <String>[])).toSet();
            if (plain.length == 1) pick = plain;
          }
          // 1.2.8 F6: the name still names more than one feed channel.
          // F6A — display-name-exact preference: when exactly one
          // candidate has a display name normalizing exactly to the
          // playlist key ("FOX" for "US - FOX HD"), that candidate is
          // the channel; "FOX Network" is a different name. (1.2.14
          // G4: the old example here was "FOX Channel" — G4 drops the
          // generic word 'channel', so that normalizes to "fox" too.)
          // F6B — same-channel duplicate collapse: when every
          // candidate's display names are one channel's ("CNN" under
          // CNN.us and CNN.us2) AND exactly one candidate has
          // programmes in the window, that candidate is the live feed
          // — the other copy's programmes are all outside the window.
          // Several in-window holders no longer stay ambiguous
          // (1.3.26 §69): the guess below picks the first sorted one
          // — the 1.2.5 uniqueness gate (cnn-a/cnn-b) no longer holds
          // for names.
          if (pick.length > 1) {
            final exact = pick.where((id) {
              final names = guide.displayNames[id] ?? const <String>[];
              return names.any((n) => normalizeEpgChannelName(n) == key);
            }).toList(growable: false);
            if (exact.length == 1) {
              pick = {exact.single};
            } else {
              final allNames = <String>[];
              for (final id in pick) {
                allNames.addAll(guide.displayNames[id] ?? const <String>[]);
              }
              if (allNames.isNotEmpty && epgDisplayNamesAreOneChannel(allNames)) {
                final inWindow = pick.where((id) => hasInWindow(id)).toList(growable: false)
                  ..sort();
                if (inWindow.length == 1) pick = {inWindow.single};
              }
            }
          }
          if (pick.length == 1) {
            final feedId = pick.single;
            if (hasInWindow(feedId)) return matched(programsFor(feedId), feedId, 'name');
            identifiedButEmpty.add(feedId);
          } else {
            // 1.3.26 §69: ambiguous names GUESS — the first candidate
            // in the existing sorted order. The owner decided filling
            // rows matters more than never guessing (other IPTV apps
            // pick one too); some picks will be the wrong guide. The
            // guess only fires after the F6A/F6B narrowing and the
            // country gate, never for foreign twins, and tiers 1–4
            // (manual, tvg-id) still win over it — a manual
            // assignment or a real tvg-id always beats a guessed name
            // match. The sort is lexicographic by feed id:
            // deterministic for a given feed, not semantically
            // ranked. When the first pick has no programmes in the
            // window it joins identifiedButEmpty and the loose tier
            // still runs, exactly like the single-pick path.
            final sorted = pick.toList(growable: false)..sort();
            final feedId = sorted.first;
            if (hasInWindow(feedId)) return matched(programsFor(feedId), feedId, 'name-guess');
            identifiedButEmpty.add(feedId);
          }
        }
      }
      // 6. Loose-name fallback for a split feed id (Fix 6, the TNT
      // case): 1.2.8 F5 — it runs whenever the channel's country is
      // known (from the playlist name, or from the identified id's
      // `.xx` suffix as a fallback), not only when an earlier tier
      // identified a feed id. A no-id channel with a known country
      // ("US - FOX SPORTS 1 HD") can now find its split copy ("Fox
      // Sport 1"). The loose key is too weak to cross countries on
      // its own. The loose key strips tier tags ("NOW:", "VIP:") and
      // reads "sports" as "sport", so a feed split into
      // "UK: TNT SPORTS 1" and "NOW: TNT SPORT 1" is found by the
      // copy that is actually in the window. The country filter
      // matches the name tier's: a feed id with no country of its own
      // is not filtered out (a country-free feed twin still counts).
      final looseKey = looseEpgChannelNameKey(channelName);
      final looseCountry =
          epgChannelCountry(channelName) ??
          (identifiedButEmpty.isNotEmpty ? epgFeedIdCountry(identifiedButEmpty.first) : null);
      if (looseKey.isNotEmpty && looseCountry != null) {
        var looseCandidates = guide.looseCandidatesFor(looseKey);
        looseCandidates.removeAll(identifiedButEmpty);
        // 1.2.22 §64.2 (F1): a foreign twin must never be served by
        // the loose tier either.
        looseCandidates.removeAll(foreignNameCandidates);
        looseCandidates = looseCandidates.where((id) {
          final countries = epgFeedChannelCountries(id, guide.displayNames[id] ?? const <String>[]);
          return countries.isEmpty || countries.contains(looseCountry);
        }).toSet();
        final serving = looseCandidates.where((id) => guide.hasRetainedPrograms(id)).toSet();
        if (serving.isNotEmpty) {
          var pick = serving;
          if (pick.length > 1) {
            final plain = pick.where((id) => !_epgHasTimeshift(id, guide.displayNames[id] ?? const <String>[])).toSet();
            if (plain.length == 1) pick = plain;
          }
          if (pick.length == 1) {
            final feedId = pick.single;
            if (hasInWindow(feedId)) return matched(programsFor(feedId), feedId, 'name-loose');
          }
        } else if (looseCandidates.isNotEmpty) {
          // 1.2.22 §64.2 (F1): in-country loose twins exist but none
          // is serving — identified, not foreign. The end reports
          // matched-but-no-programmes for them instead of 'foreign'.
          identifiedButEmpty.addAll(looseCandidates);
        }
      }
      // 5.5. Word-overlap affiliate guess (1.3.29 P1-5, owner-approved):
      // for a channel with no guide id whose name words overlap a
      // serving feed channel's words, guess the single best one and
      // record it as 'name-guess-affiliate' — never as a certain
      // match. The owner decided filling the bare network rows (FOX /
      // PBS / NBC / CBS) matters more than leaving them empty, and
      // accepts the programmes may be a local affiliate's rather
      // than the national feed's.
      //
      // Placement is deliberate: AFTER the loose tier, not between
      // name (5) and loose (6) as P1-5 first sketched it. The loose
      // tier proves itself by exact loose-key equality; a guess must
      // never pre-empt a deterministic match. The guess is the last
      // resort before the blocked reasons. The pick itself lives in
      // [_affiliateGuessFor], shared with [_windowCandidateIds] so
      // the window holds the pick's rows before the match runs —
      // without that, the per-channel fetch would pick the right id
      // and then report it out-of-window (1.3.29, harness).
      final guessId = _affiliateGuessFor(
        guide,
        channelName,
        epgChannelId,
        tvgId,
        exclude: {...identifiedButEmpty, ...foreignNameCandidates},
      );
      if (guessId != null) {
        if (hasInWindow(guessId)) {
          return matched(programsFor(guessId), guessId, 'name-guess-affiliate');
        }
        identifiedButEmpty.add(guessId);
      }
    }
    if (identifiedButEmpty.isNotEmpty) {
      final sorted = identifiedButEmpty.toList(growable: false)..sort();
      // 1.2.8 F2: split "matched but no programmes" — the feed
      // declaring the id with zero programmes ("declared") vs
      // programmes that exist but all fall outside the Reload window
      // ("outside-window"). The kind is "outside-window" when ANY
      // identified id has retained programmes; else "declared".
      // (The overview/details keep the single matchedButNoPrograms
      // reason — the split lives in the Reload tiers and dialog.)
      final anyProgrammes = sorted.any((id) => guide.hasRetainedPrograms(id));
      return blocked(
        anyProgrammes
            ? 'matched-but-no-programmes-outside-window'
            : 'matched-but-no-programmes-declared',
        sorted,
      );
    }
    // 1.2.22 §64.2 (F1): the only same-key twins were foreign and the
    // loose tier found nothing in-country — report 'foreign' for them,
    // never guess the foreign twin.
    if (foreignNameCandidates.isNotEmpty) {
      final sorted = foreignNameCandidates.toList(growable: false)..sort();
      return blocked('foreign', sorted);
    }
    if (epgChannelId != null || tvgId != null) return blocked('tvg-id-not-in-feed');
    return blocked('no-tvg-id');
  }

  /// One feed fetch per enabled source, in priority order (PlezTV 1.2.0,
  /// §3.1): the provider feed plus every enabled user-added source.
  /// [keyPrefix] names the source in programme keys (`xtream` for the
  /// provider feed, `m3u` for a playlist guide, `user` for added ones)
  /// so a programme served by an added source never collides with the
  /// provider's key for the same channel+start.
  Future<List<_EpgSourceAttempt>> _epgSourceAttempts() async {
    final userSources = await _epgStore.loadUserSources();
    final enabled = userSources.where((s) => s.enabled).toList(growable: false);
    final provider = await _providerSourceAttempt();
    // I9: the validators for each feed are loaded when the attempts are
    // built and captured in the fetcher closure — a refresh sends the
    // ETag / Last-Modified the server sent last time.
    final added = <_EpgSourceAttempt>[];
    for (final s in enabled) {
      final validators = await _epgStore.loadValidators('user:${s.id}');
      added.add(
        _EpgSourceAttempt(
          config: s,
          cacheKey: 'user:${s.id}',
          keyPrefix: 'user',
          fetchFeed: (abortTrigger, {bool useValidators = true}) => _m3uFeedFetch(
            s.url!,
            abortTrigger,
            etag: useValidators ? validators.etag : null,
            lastModified: useValidators ? validators.lastModified : null,
          ),
          userAgent: IptvClient.effectiveUserAgent,
        ),
      );
    }
    final addedFirst = await _epgStore.loadAddedSourcesFirst();
    if (addedFirst) return [...added, ?provider];
    return [?provider, ...added];
  }

  /// The provider feed's fetch (Xtream: the login's `xmltv.php`; M3U:
  /// the playlist's declared EPG URL). Null when the connection has no
  /// provider feed (an M3U playlist without a declared URL).
  Future<_EpgSourceAttempt?> _providerSourceAttempt() async {
    if (_isXtream) {
      final cacheKey = xtreamFeedCacheKey;
      final validators = await _epgStore.loadValidators(cacheKey);
      return _EpgSourceAttempt(
        config: _providerConfig(),
        cacheKey: cacheKey,
        keyPrefix: 'xtream',
        fetchFeed: (abortTrigger, {bool useValidators = true}) =>
            _client.xtreamApi.getXmltvFeed(
              etag: useValidators ? validators.etag : null,
              lastModified: useValidators ? validators.lastModified : null,
              abortTrigger: abortTrigger,
            ),
        userAgent: _client.xtreamApi.effectiveUserAgent,
      );
    }
    final connection = _client.connection;
    if (connection is M3uConnection && connection.epgUrl != null && connection.epgUrl!.isNotEmpty) {
      final url = connection.epgUrl!;
      final validators = await _epgStore.loadValidators(url);
      return _EpgSourceAttempt(
        config: _providerConfig(),
        cacheKey: url,
        keyPrefix: 'm3u',
        fetchFeed: (abortTrigger, {bool useValidators = true}) => _m3uFeedFetch(
          url,
          abortTrigger,
          etag: useValidators ? validators.etag : null,
          lastModified: useValidators ? validators.lastModified : null,
        ),
        userAgent: IptvClient.effectiveUserAgent,
      );
    }
    return null;
  }

  // 1.6.11 L4: the provider name comes from translations, not a
  // hardcoded string (it is the `iptv.epgProviderSource` key).
  IptvEpgSourceConfig _providerConfig() => IptvEpgSourceConfig(
    id: IptvEpgSourceConfig.providerId,
    kind: IptvEpgSourceConfig.kindProvider,
    name: t.iptv.epgProviderSource,
  );

  /// Load one source's guide, saying whether it loaded fresh (a download
  /// or a persisted-file parse — the status-worthy event) or was served
  /// from the fresh in-memory cache. The stale-while-revalidate path
  /// returns the stale guide while the refresh runs in the background,
  /// so a serve is not a fresh load.
  Future<(_CachedXmltvGuide guide, bool loadedFresh)> _loadSourceGuide(
    String cacheKey,
    XmltvFeedFetcher fetchFeed,
    Duration? ttl, {
    bool force = false,
    Set<String> retainIds = const {},
    _EpgSourceAttempt? attempt,
  }) async {
    final before = _xmltvCache[cacheKey]?.fetchedAt;
    final guide = await _xmltvGuideForKey(cacheKey, fetchFeed, ttl, force: force, retainIds: retainIds, attempt: attempt);
    // 1.4.4 F6: a guide served while its background refresh is still
    // in flight is the OLD guide, not a fresh load — it must not stamp
    // "last updated" (the refresh stamps when it lands, via
    // _recordBackgroundFeedLoad). Without this, a Reload's warm-start
    // serve would certify stale data as fresh, because the bust left
    // `before` null.
    return (guide, (before == null || guide.fetchedAt != before) && !_xmltvGuideFutures.containsKey(cacheKey));
  }

  /// One source's last download record (1.2.15 R4): the stashed facts
  /// for [attempt]'s cache key, with the attempt's identity and
  /// User-Agent attached. Null when this feed has not been downloaded
  /// this launch (served from memory or the persisted file instead).
  IptvEpgFeedDownload? _feedDownloadFor(_EpgSourceAttempt attempt) {
    final stash = _lastFeedDownloads[attempt.cacheKey];
    if (stash == null) return null;
    return IptvEpgFeedDownload(
      sourceId: attempt.config.id,
      sourceName: attempt.config.name,
      fetchedAt: stash.fetchedAt,
      notModified: stash.notModified,
      bytesDownloaded: stash.bytesDownloaded,
      sha256: stash.sha256,
      channelsParsed: stash.channelsParsed,
      channelsRetained: stash.channelsRetained,
      programsParsed: stash.programsParsed,
      programsRetained: stash.programsRetained,
      etag: stash.etag,
      lastModified: stash.lastModified,
      userAgent: attempt.userAgent,
      resumed: stash.resumed,
      resumedBytes: stash.resumedBytes,
    );
  }

  /// Record a background feed refresh in the per-source status (1.2.15
  /// R4): the stale-while-revalidate refresh runs behind the caller's
  /// back, so nobody else records it — without this, the 304 that
  /// revalidates a stale guide never surfaces anywhere (not in the
  /// status, not in the Reload report). A null attempt (a load the
  /// bulk/per-channel paths never built) records nothing. A failed
  /// refresh is recorded by [_recordBackgroundFeedFailure] instead —
  /// the previous status stands only until a failure is recorded.
  Future<void> _recordBackgroundFeedLoad(
    _EpgSourceAttempt? attempt,
    _CachedXmltvGuide guide,
    DateTime started,
  ) async {
    if (attempt == null) return;
    try {
      // 1.6.11 P7: a background refresh that stored zero programmes
      // must not certify "Last updated" — same lie D9 fixed for the
      // per-channel path, one path over. The bulk paths keep stamping
      // (1.3.24 §67 F1 invariant — Reload must not re-download on
      // first open).
      await _recordSourceSuccess(
        attempt,
        guide,
        started,
        stampLastUpdated: guide.totalProgramCount > 0,
      );
    } catch (_) {
      // Best-effort: the guide is already in memory; the next load
      // re-records.
    }
  }

  /// Record a failed background feed refresh in the per-source status
  /// (1.4.3 G1): the stale-while-revalidate refresh runs behind the
  /// caller's back, so nobody else records it — without this, a 403
  /// that kills the refresh never surfaces anywhere (not on the
  /// sources screen chip, not in the guide tab's stale stamp), and the
  /// previous success stands as if the feed were fresh. A null attempt
  /// records nothing; a cancellation is not a failure.
  Future<void> _recordBackgroundFeedFailure(_EpgSourceAttempt? attempt, Object error) async {
    if (attempt == null) return;
    if (MediaServerHttpException.from(error).isCancellation) return;
    try {
      await _recordSourceFailure(attempt.config, error);
    } catch (_) {
      // Best-effort: the guide is already in memory; the next load
      // re-records.
    }
  }

  /// Record a fresh source load in the per-source status (§3.1): last
  /// success, programmes + channels stored, feed size, fetch duration.
  /// A success clears a previous failure — the chip goes green again.
  /// 1.2.15 R4: the last download's facts (bytes, SHA, 304-vs-200,
  /// validators, User-Agent) land in the status too.
  ///
  /// [stampLastUpdated] certifies the "Last updated" stamp. Bulk/guide
  /// loads stamp (the Reload or background refresh puts the feed's
  /// programmes in the guide for every channel, so the guide's data is
  /// fresh — 1.3.24 §67 F1, the quiet-hour check must not re-download a
  /// feed that just landed). Per-channel loads do NOT stamp: a fetch
  /// that stores nothing for its channel must leave the stamp alone
  /// (1.1.2 D9 — the channel's own stamp in [_fetchEpgForChannelNetwork]
  /// fires only when that channel actually stored programmes).
  Future<void> _recordSourceSuccess(
    _EpgSourceAttempt attempt,
    _CachedXmltvGuide guide,
    DateTime started, {
    bool stampLastUpdated = true,
  }) async {
    // 1.3.24 §67 F1: a fresh feed load certifies the "last updated"
    // stamp — the Reload previously left it erased (clearEpgCache),
    // so the guide tab's quiet-hour check re-downloaded the feed on
    // first open. Every call site gates on `loadedFresh`, so this
    // stamps data, never a stale serve.
    if (stampLastUpdated) {
      _lastEpgUpdatedAt = DateTime.now();
      _noteEpgUpdated(_lastEpgUpdatedAt!);
      // 1.6.32, D4: the counts row in IPTV settings — the loaded
      // guide's size across every feed, written with the "Last
      // updated" stamp so the row survives a restart and stays in
      // step with it.
      _noteGuideCounts();
    }
    final size = await _xmltvFeedFileSize(attempt.cacheKey);
    final statuses = await _epgStore.loadStatuses();
    final status = statuses[attempt.config.id] ?? IptvEpgSourceStatus.empty;
    final download = _feedDownloadFor(attempt);
    await _epgStore.saveStatus(
      attempt.config.id,
      status.copyWith(
        lastSuccess: DateTime.now(),
        clearFailure: true,
        programs: guide.totalProgramCount,
        channels: guide.programCountByChannel.length,
        sizeBytes: size,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        programsParsed: guide.programsParsed,
        channelsParsed: guide.channelsParsed,
        // No download this load (served from memory): the nullable
        // fields keep the last download's facts instead of wiping
        // them — only a real download replaces them.
        bytesDownloaded: download?.bytesDownloaded,
        sha256: download?.sha256,
        notModified: download?.notModified,
        etag: download?.etag,
        lastModified: download?.lastModified,
        userAgent: attempt.userAgent,
        resumed: download?.resumed,
        resumedBytes: download?.resumedBytes,
      ),
    );
  }

  /// Record a failed source load in the per-source status (§3.1): last
  /// failure + reason. The previous success (if any) stays, so the chip
  /// can say "failed since ...".
  Future<void> _recordSourceFailure(IptvEpgSourceConfig config, Object error) async {
    final statuses = await _epgStore.loadStatuses();
    final status = statuses[config.id] ?? IptvEpgSourceStatus.empty;
    // 1.2.3: the reason is shown on the sources screen chip — store the
    // URL-free message, never error.toString(): a
    // MediaServerHttpException appends the request host+path to its
    // toString, and the panel URL must never surface in the UI (or be
    // persisted in a status).
    await _epgStore.saveStatus(
      config.id,
      status.copyWith(lastFailure: DateTime.now(), lastFailureReason: epgFeedErrorReason(error)),
    );
  }

  /// The persisted feed file's size in bytes (0 when the feed is not
  /// persisted — tests disable the persisted side, and a memory-only
  /// guide has no file). Best-effort, never throws.
  Future<int> _xmltvFeedFileSize(String cacheKey) async {
    if (debugDisablePersistedEpg) return 0;
    try {
      final file = await _xmltvFeedFile(cacheKey);
      if (!file.existsSync()) return 0;
      return file.lengthSync();
    } catch (_) {
      return 0;
    }
  }
  /// One channel's `get_short_epg` listings — the fallback when the
  /// `xmltv.php` feed has nothing for the channel (or cannot be fetched).
  /// Limit 500 covers ~10 days of half-hour slots; anything past the limit
  /// simply does not appear (placeholders fill the gap) instead of failing.
  ///
  /// Build #15, item 6: at most [_maxShortEpgConcurrency] calls run at
  /// once, and a call that doesn't answer within
  /// [shortEpgFirstPaintTimeout] gives up fast — the caller falls back to
  /// the cached feed slice instead of holding the row for the full 60s.
  /// Returns the mapped programmes plus whether the panel answered
  /// exactly [_shortEpgLimit] listings — with no total/count, that is
  /// the only truncation signal (1.2.1 D4): the answer may be cut off
  /// and the feed tail must fill the missing days.
  ///
  /// 1.2.15 R1: when the first-paint timeout fires, the timed-out
  /// request is NOT aborted — it stays alive in the background
  /// ([latePrograms]) and its listings merge into the row when they
  /// land (see [fetchEpgForChannel]). The old build #26 (26.8)
  /// behaviour aborted the socket at first paint, so a slow panel
  /// answer was lost and the resulting empty was cached for 24 h.
  /// The background request is still owned, not orphaned: its only
  /// abort is the channel's own [abortTrigger] — a scroll-away cancel
  /// or the app backgrounding stops it (the controller stays
  /// registered while a late request is outstanding, see
  /// [_fetchXtreamEpg]). [timedOut] tells the caller the row fell
  /// through on a timeout, not on an answer.
  Future<({List<LiveTvProgram> programs, bool atLimit, bool timedOut, Future<List<LiveTvProgram>>? latePrograms})> _fetchXtreamShortEpg(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
    Future<void>? abortTrigger,
  ) async {
    await _acquireShortEpgSlot();
    try {
      // 1.4.3 C1: pace the start — the semaphore bounds in-flight
      // calls, not rate. The wait runs while holding the slot, so at
      // most [_maxShortEpgConcurrency] callers queue in the pacer.
      await _shortEpgPacer.waitForSlot();
      final request = _client.xtreamApi.getShortEpg(
        channelKey,
        limit: _shortEpgLimit,
        timeout: const Duration(seconds: 60),
        abortTrigger: abortTrigger,
      );
      Future<List<LiveTvProgram>>? latePrograms;
      final listings = await request.timeout(
        shortEpgFirstPaintTimeout,
        onTimeout: () {
          // First paint gives up fast, but the request keeps running:
          // map its listings when they land (or swallow the error —
          // a late failure is just a miss, never a throw here).
          latePrograms = request.then(
            (listings) => _mapShortEpgListings(listings, channelKey, settings, from, to),
            onError: (_) => const <LiveTvProgram>[],
          );
          return const <XtreamEpgProgram>[];
        },
      );
      // The timeout path returns the empty marker list above; the real
      // listings are the late future's job now. A non-empty answer here
      // is the request landing inside the first-paint budget.
      if (latePrograms != null) {
        // 1.3.26 §69: per-channel fetch-outcome logging — the next
        // phone log must name the cause per row (the 1.3.24 log's
        // "zero short-EPG activity" was a logging gap, not proof).
        appLogger.i('IPTV EPG $channelKey: short-epg timed-out (late answer pending)');
        return (programs: const <LiveTvProgram>[], atLimit: false, timedOut: true, latePrograms: latePrograms);
      }
      final programs = _mapShortEpgListings(listings, channelKey, settings, from, to);
      appLogger.i('IPTV EPG $channelKey: short-epg ${programs.isEmpty ? 'empty' : 'answered ${programs.length}'}');
      return (programs: programs, atLimit: listings.length == _shortEpgLimit, timedOut: false, latePrograms: null);
    } finally {
      _releaseShortEpgSlot();
    }
  }

  /// Map raw short-EPG listings to guide programmes for [channelKey],
  /// window-filtered and sorted (shared by the first-paint answer and
  /// the late background answer in [_fetchXtreamShortEpg]).
  List<LiveTvProgram> _mapShortEpgListings(
    List<XtreamEpgProgram> listings,
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
  ) {
    final fromEpoch = from.millisecondsSinceEpoch ~/ 1000;
    final toEpoch = to.millisecondsSinceEpoch ~/ 1000;
    final offsetSeconds = settings.timeOffsetMinutes * 60;
    final programs = <LiveTvProgram>[];
    for (final listing in listings) {
      try {
        final beginsAt = listing.startTimestamp + offsetSeconds;
        final endsAt = listing.stopTimestamp + offsetSeconds;
        if (endsAt <= beginsAt || endsAt <= fromEpoch || beginsAt >= toEpoch) continue;
        programs.add(
          LiveTvProgram(
            // The API's own channel id is not trusted for matching: the
            // guide indexes programs by the channel key it asked for.
            key: 'epg:$channelKey:${listing.id}',
            title: listing.title.isEmpty ? t.liveTv.unknownProgram : listing.title,
            summary: listing.description.isEmpty ? null : listing.description,
            beginsAt: beginsAt,
            endsAt: endsAt,
            channelIdentifier: channelKey,
            serverId: _client.connection.id,
            serverName: _client.serverName,
          ),
        );
      } catch (_) {
        // One bad listing does not invalidate the channel's guide.
      }
    }
    programs.sort((a, b) => (a.beginsAt ?? 0).compareTo(b.beginsAt ?? 0));
    return programs;
  }

  /// Take one of the [_maxShortEpgConcurrency] `get_short_epg` slots,
  /// waiting for a free one when the storm is at the cap. The wait is
  /// bounded in practice: every holder gives up after
  /// [shortEpgFirstPaintTimeout], so a slot frees within that budget.
  Future<void> _acquireShortEpgSlot() async {
    while (_shortEpgInFlight >= _maxShortEpgConcurrency) {
      final waiter = Completer<void>();
      _shortEpgWaiters.add(waiter);
      await waiter.future;
    }
    _shortEpgInFlight++;
  }

  void _releaseShortEpgSlot() {
    _shortEpgInFlight--;
    if (_shortEpgWaiters.isNotEmpty) _shortEpgWaiters.removeAt(0).complete();
    // 1.2.12 feed gate, 1.2.14 G1: on non-low-end hardware, the gate
    // opens once the in-flight short-EPG count drops to 0 after a
    // round settled (any outcome — answered, empty, timeout,
    // failure). Redundant after G1 (the first miss opens it first),
    // but kept as a harmless extra opening path. On low-end hardware
    // the settle does not open the gate — the first miss does.
    if (!_epgFeedGateOpen && _shortEpgInFlight == 0 && !DevicePerformance.isLowEndHardware) {
      _openFeedGate();
    }
  }

  /// Programmes for one channel out of the playlist's XMLTV guide —
  /// the provider feed plus any enabled third-party sources, in
  /// priority order (PlezTV 1.2.0, §3.1). A channel with no tvg-id
  /// still tries the name fallback (1.2.1 D2): the Xtream path tries
  /// byId then byName, and the M3U path does the same — an id-less
  /// playlist entry matches the feed by its name.
  Future<({List<LiveTvProgram> programs, IptvEpgSource source, bool feedDeferred, String? sourceId, String? matchedXmltvId, String? matchMethod, Map<String, DateTime> feedGenerations, bool shortEpgTimedOut, Future<List<LiveTvProgram>>? lateShortEpg})> _fetchM3uEpg(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
    Duration? ttl, {
    bool force = false,
    bool bypassFeedGate = false,
  }) async {
    final connection = _client.connection;
    if (connection is! M3uConnection) {
      return (
        programs: const <LiveTvProgram>[],
        source: IptvEpgSource.none,
        feedDeferred: false,
        sourceId: null,
        matchedXmltvId: null,
        matchMethod: null,
        feedGenerations: const <String, DateTime>{},
        shortEpgTimedOut: false,
        lateShortEpg: null,
      );
    }
    final attempts = await _epgSourceAttempts();
    if (attempts.isEmpty) {
      return (
        programs: const <LiveTvProgram>[],
        source: IptvEpgSource.none,
        feedDeferred: false,
        sourceId: null,
        matchedXmltvId: null,
        matchMethod: null,
        feedGenerations: const <String, DateTime>{},
        shortEpgTimedOut: false,
        lateShortEpg: null,
      );
    }
    return _fetchFeedPrograms(channelKey, settings, from, to, ttl, force: force, bypassFeedGate: bypassFeedGate);
  }
  /// Map parsed XMLTV programmes for one channel to guide programs,
  /// window-filtered and sorted. Shared by the M3U (user EPG URL) and
  /// Xtream (`xmltv.php`) paths.
  List<LiveTvProgram> _mapXmltvPrograms(
    List<XmltvProgram> entries,
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to, {
    required String keyPrefix,
    int? offsetMinutes,
  }) {
    final fromEpoch = from.millisecondsSinceEpoch ~/ 1000;
    final toEpoch = to.millisecondsSinceEpoch ~/ 1000;
    final offsetSeconds = (offsetMinutes ?? settings.timeOffsetMinutes) * 60;
    final programs = <LiveTvProgram>[];
    for (final entry in entries) {
      final beginsAt = entry.startEpoch + offsetSeconds;
      final endsAt = entry.stopEpoch + offsetSeconds;
      if (endsAt <= beginsAt || endsAt <= fromEpoch || beginsAt >= toEpoch) continue;
      programs.add(
        LiveTvProgram(
          key: 'epg:$keyPrefix:$channelKey:$beginsAt',
          title: entry.title.isEmpty ? t.liveTv.unknownProgram : entry.title,
          summary: entry.description.isEmpty ? null : entry.description,
          beginsAt: beginsAt,
          endsAt: endsAt,
          channelIdentifier: channelKey,
          serverId: _client.connection.id,
          serverName: _client.serverName,
        ),
      );
    }
    programs.sort((a, b) => (a.beginsAt ?? 0).compareTo(b.beginsAt ?? 0));
    return programs;
  }

  /// The provider's XMLTV file, parsed once per key and cached for [ttl]
  /// (null = manual only: fetched once, refreshed only by Update now /
  /// Clear). Parsing runs in an isolate — provider files run to megabytes.
  /// Concurrent channel fetches share one in-flight download per key.
  ///
  /// Build #15, item 6 — the feed is persisted, not just held in memory:
  /// a warm start parses the feed FILE instead of re-downloading it, a
  /// Wait for a running catalog sync to settle before a feed download
  /// starts (1.6.34, P-06): the ~150 MB feed must not download
  /// concurrently with the sync's downloads + FTS writes on a low-end
  /// TV. Polls the sync stamp every second, bounded by
  /// [catalogSyncWaitBudget] — past it the download starts anyway, so
  /// a crashed sync (whose stamp ages out in 30 min) never blocks the
  /// guide forever. Throws a cancellation when the download is aborted
  /// while queued, so the caller treats it like any other cancelled
  /// load (no negative-cache poisoning).
  Future<void> _waitForCatalogSyncToSettle(Future<void> abortTrigger) async {
    final deadline = DateTime.now().add(catalogSyncWaitBudget);
    var logged = false;
    while (await IptvClient.isSyncRunningElsewhere()) {
      if (DateTime.now().isAfter(deadline)) {
        appLogger.w(
          'IPTV: starting the EPG download while a catalog sync is still running '
          'after ${catalogSyncWaitBudget.inMinutes} min — the guide cannot wait forever',
        );
        return;
      }
      if (!logged) {
        appLogger.i('IPTV: EPG download queued behind the running catalog sync');
        logged = true;
      }
      // Race one poll slice against the abort: backgrounding while
      // queued cancels the download like a mid-download abort.
      final aborted = await Future.any<bool>([
        Future<void>.delayed(const Duration(seconds: 1)).then((_) => false),
        abortTrigger.then((_) => true),
      ]);
      if (aborted) {
        throw MediaServerHttpException(
          type: MediaServerHttpErrorType.cancelled,
          message: 'EPG feed download cancelled while waiting for the catalog sync',
        );
      }
    }
  }

  /// stale guide is served immediately while the refresh runs in the
  /// background (stale-while-revalidate), and a failed download is
  /// remembered briefly instead of retried channel by channel.
  /// Start a shared feed download (build #28): the download owns an
  /// AbortController, registered in [_activeEpgAborts] so
  /// [cancelBackgroundWork] can stop it when the app backgrounds. The
  /// controller is removed when the download settles. The [fetchFeed]
  /// receives the controller's trigger — the Xtream feed aborts at the
  /// socket (see [XtreamApi.getXmltvFeed]); the M3U feed aborts at the
  /// socket too (see [_m3uFeedFetch]).
  Future<_CachedXmltvGuide> _startXmltvDownload(
    String cacheKey,
    XmltvFeedFetcher fetchFeed, {
    Set<String> retainIds = const {},
  }) async {
    final abort = AbortController();
    _activeEpgAborts.add(abort);
    // 1.3.24 §67 F2: count the job so clearEpgCache can defer the
    // persisted delete instead of racing the promotion. On settle,
    // drain a deferred delete — only once the LAST job is done, and
    // only if no job landed while it was deferred (a landed feed IS
    // the fresh state; deleting now would remove it).
    _feedJobsInFlight++;
    // 1.4.4 guide-first: a feed download or parse is running — the
    // download manager defers STARTING new downloads until the last
    // job settles.
    IptvFeedRefreshActivity.instance.markActive();
    try {
      // 1.6.34 (P-06): serialize against the catalog sync — the feed
      // download waits behind a running sync instead of competing
      // with it for bandwidth and memory.
      await _waitForCatalogSyncToSettle(abort.trigger);
      final guide = await _loadXmltvGuide(
        cacheKey,
        ({bool useValidators = true}) => fetchFeed(abort.trigger, useValidators: useValidators),
        retainIds: retainIds,
        // 1.2.19 (L-3): the resume download aborts on the same trigger
        // the fetch closure carries (build #28).
        abortTrigger: abort.trigger,
      );
      if (_epgDeleteDeferred) _epgDeleteDeferredLanded = true;
      return guide;
    } finally {
      _activeEpgAborts.remove(abort);
      _feedJobsInFlight--;
      if (_feedJobsInFlight == 0) {
        _drainDeferredEpgDelete();
        // 1.4.4 guide-first: the last feed job settled — downloads
        // deferred while the guide refreshed can start now.
        IptvFeedRefreshActivity.instance.markIdle();
      }
    }
  }

  /// Run a persisted-EPG clear deferred while a feed job was in flight
  /// (1.3.24 §67 F2). A landed feed is the fresh state, so the delete
  /// is dropped; a failed or cancelled job leaves nothing fresh
  /// behind, so the delete runs — the old clear semantics.
  void _drainDeferredEpgDelete() {
    if (!_epgDeleteDeferred) return;
    final landed = _epgDeleteDeferredLanded;
    _epgDeleteDeferred = false;
    _epgDeleteDeferredLanded = false;
    if (landed) return;
    unawaited(_deletePersistedEpg());
  }

  Future<_CachedXmltvGuide> _xmltvGuideForKey(
    String cacheKey,
    XmltvFeedFetcher fetchFeed,
    Duration? ttl, {
    bool force = false,
    Set<String> retainIds = const {},
    _EpgSourceAttempt? attempt,
  }) async {
    bool fresh(_CachedXmltvGuide guide) => ttl == null || DateTime.now().difference(guide.fetchedAt) < ttl;

    final cached = _xmltvCache[cacheKey];
    if (cached != null && fresh(cached)) return cached;

    // A failed download is remembered briefly: don't start another 120s
    // download for a channel whose feed just failed — the caller falls
    // back to get_short_epg / tap-to-retry instead. A stale guide still
    // beats nothing.
    // D8: an explicit retry (force) bypasses the remembered failure —
    // it is not a storm, so it attempts the download again instead of
    // failing fast for 5 minutes. A forced retry also forgets the
    // failure, so a later automatic fetch is not blocked by a failure
    // the retry already superseded.
    final failedAt = _xmltvFailedAt[cacheKey];
    if (failedAt != null) {
      if (force) {
        _xmltvFailedAt.remove(cacheKey);
      } else if (DateTime.now().difference(failedAt) < xmltvNegativeCacheTtl) {
        if (cached != null) return cached;
        throw StateError('XMLTV feed for $cacheKey failed recently; retry shortly');
      } else {
        _xmltvFailedAt.remove(cacheKey);
      }
    }

    // 1.4.4 F6: NO early return for an in-flight download here. A load
    // arriving while a download runs must serve the guide it already
    // has (in-memory / store / persisted file below) and let the
    // download finish in the background — returning the shared future
    // would make a Reload that arrives mid-download BLOCK on it (up
    // to ~a minute on the real panel), which is exactly the wait this
    // release removes. The fully-cold path at the bottom still shares
    // the in-flight future (there is nothing else to serve), and each
    // servable branch below guards against starting a second download
    // while one runs.
    // Stale-while-revalidate: a stale in-memory guide still answers while
    // the refresh runs in the background — the guide never waits on a
    // download for programmes it already has.
    if (cached != null) {
      // Build #28: while a stream is playing, do NOT start the refresh
      // download — the stale guide answers and the refresh waits until
      // playback stops. A new feed download on top of viewing traffic is
      // exactly the background work that gets a one-connection line
      // blocked.
      if (IptvPlaybackActivity.instance.isPlaying) return cached;
      // 1.4.4 F6: a concurrent caller may have started the refresh
      // while this one ran — share it instead of starting a second
      // download for the same key (the guard the store/persisted
      // branches below already have; the old top-of-function
      // in-flight return used to cover this branch and is gone).
      if (_xmltvGuideFutures[cacheKey] != null) return cached;
      // The background refresh keeps the current window's rows: a
      // metadata-only refresh would empty the window the guide is
      // showing and force a re-parse on the next fetch.
      final refreshStarted = DateTime.now();
      final future = _startXmltvDownload(cacheKey, fetchFeed, retainIds: cached.windowFeedIds);
      _xmltvGuideFutures[cacheKey] = future;
      // 1.4.4 F6: unregister the moment the refresh settles — BEFORE
      // the success/failure recording runs. The recording does async
      // work, and until it finishes the future would still read as
      // "in flight": a Reload returning in that window would report
      // feedRefreshBackground=true for a refresh that already failed
      // (or already landed), and its dialog would contradict the
      // outcome lines beside it. The whenComplete below stays as a
      // belt-and-braces (the removal is idempotent).
      unawaited(
        future
            .then<void>((guide) {
              _xmltvGuideFutures.removeWhere((key, value) => key == cacheKey && identical(value, future));
              return _recordBackgroundFeedLoad(attempt, guide, refreshStarted);
            })
            .catchError((Object e) {
              _xmltvGuideFutures.removeWhere((key, value) => key == cacheKey && identical(value, future));
              return _recordBackgroundFeedFailure(attempt, e);
            })
            .whenComplete(() {
          _xmltvGuideFutures.removeWhere((key, value) => key == cacheKey && identical(value, future));
        }),
      );
      return cached;
    }

    // No in-memory guide: the persisted feed file is the warm start —
    // parse it now (no download) and refresh in the background when stale.
    // 1.2.20 (a): with a valid row store, the warm start reads the
    // store's metadata (one cheap query) and returns a guide with an
    // empty window — rows stay in the DB until a slide needs them. No
    // XML parse on launch.
    final fromStore = await _readFeedRowsFromStore(
      cacheKey,
      retainIds: const {},
    );
    if (fromStore != null) {
      _xmltvCache[cacheKey] = fromStore;
      // 1.4.4 F6: a forced load (Reload / "Update now" / Assign
      // refresh) starts the background refresh even when the stored
      // guide is still fresh — the user asked for fresh data, and the
      // refresh runs behind the served guide instead of blocking it.
      // Without this, a Reload on a fresh feed would silently do
      // nothing (pre-1.4.4 Reload always re-downloaded).
      if (!fresh(fromStore) || force) {
        if (IptvPlaybackActivity.instance.isPlaying) return fromStore;
        if (_xmltvGuideFutures[cacheKey] != null) return fromStore;
        final refreshStarted = DateTime.now();
        final future = _startXmltvDownload(cacheKey, fetchFeed, retainIds: fromStore.windowFeedIds);
        _xmltvGuideFutures[cacheKey] = future;
        // 1.4.4 F6: unregister on settle, before the recording — see
        // the stale-cache branch above.
        unawaited(
          future
              .then<void>((guide) {
                _xmltvGuideFutures.removeWhere((key, value) => key == cacheKey && identical(value, future));
                return _recordBackgroundFeedLoad(attempt, guide, refreshStarted);
              })
              .catchError((Object e) {
                _xmltvGuideFutures.removeWhere((key, value) => key == cacheKey && identical(value, future));
                return _recordBackgroundFeedFailure(attempt, e);
              })
              .whenComplete(() {
            _xmltvGuideFutures.removeWhere((key, value) => key == cacheKey && identical(value, future));
          }),
        );
      }
      return fromStore;
    }
    final persisted = await _readPersistedXmltv(cacheKey, retainIds: retainIds, caller: 'warm-start');
    if (persisted != null) {
      _xmltvCache[cacheKey] = persisted;
      // 1.4.4 F6: same forced-refresh rule as the row-store branch
      // above — a forced load re-downloads in the background even
      // when the persisted guide is still fresh.
      if (!fresh(persisted) || force) {
        // Build #28: while a stream is playing, the persisted feed
        // answers and the refresh download waits — see the stale-cache
        // branch above.
        if (IptvPlaybackActivity.instance.isPlaying) return persisted;
        // Build #26: a concurrent caller may have started the refresh
        // while this one read the persisted file — share it instead of
        // starting a second download for the same key.
        if (_xmltvGuideFutures[cacheKey] != null) return persisted;
        final refreshStarted = DateTime.now();
        final future = _startXmltvDownload(cacheKey, fetchFeed, retainIds: persisted.windowFeedIds);
        _xmltvGuideFutures[cacheKey] = future;
        // 1.4.4 F6: unregister on settle, before the recording — see
        // the stale-cache branch above.
        unawaited(
          future
              .then<void>((guide) {
                _xmltvGuideFutures.removeWhere((key, value) => key == cacheKey && identical(value, future));
                return _recordBackgroundFeedLoad(attempt, guide, refreshStarted);
              })
              .catchError((Object e) {
                _xmltvGuideFutures.removeWhere((key, value) => key == cacheKey && identical(value, future));
                return _recordBackgroundFeedFailure(attempt, e);
              })
              .whenComplete(() {
            _xmltvGuideFutures.removeWhere((key, value) => key == cacheKey && identical(value, future));
          }),
        );
      }
      return persisted;
    }

    // Fully cold: one shared download, as before — unless a stream is
    // playing (build #28): then there is no guide to serve and no
    // download starts. The caller falls back to get_short_epg (or an
    // empty guide) and the feed loads when playback stops.
    if (IptvPlaybackActivity.instance.isPlaying) {
      // D1b: a deferral is not a failure — the caller converts it to
      // an uncached empty instead of a cached loaded-empty.
      throw _EpgFeedDeferred(cacheKey);
    }
    // Build #26: a concurrent caller may have started the download while
    // this one read the persisted file — share it instead of starting a
    // second one. Without this, N cold rows each download the feed and
    // tee to the same temp file (the old code had the same gap, hidden
    // because concurrent writeAsString calls to one path never errored).
    final inFlightAfterRead = _xmltvGuideFutures[cacheKey];
    if (inFlightAfterRead != null) return inFlightAfterRead;
    final future = _startXmltvDownload(cacheKey, fetchFeed, retainIds: retainIds);
    _xmltvGuideFutures[cacheKey] = future;
    try {
      return await future;
    } finally {
      // The future is already awaited above; dropping it from the map just
      // lets the next stale-cache call start a fresh fetch. (removeWhere
      // returns void, so the discarded Future value trips no lint.)
      _xmltvGuideFutures.removeWhere((key, value) => key == cacheKey && identical(value, future));
    }
  }

  /// The parse-time window for XMLTV feeds (1.2.2 I8, Kodi "Hours to
  /// import" model): programmes outside this window are dropped during
  /// the streaming parse instead of being retained and filtered per
  /// channel at read time — the retained list is what the ~180-203 MB
  /// floor at Trex scale is made of.
  ///
  /// The window is the widest any guide request can reach, so dropping
  /// outside it can never hide a visible show:
  /// - 7 days back / 7 days forward: the widest the day picker +
  ///   past-days settings can request (daysToLoad and pastDaysToKeep
  ///   both max out at 7).
  /// - +24h on the far side: a feed stays live for up to the 24h update
  ///   interval, and a request near the end of its life reaches 7 days
  ///   past *that* moment — the retained window must cover the TTL slop.
  /// - +/-2h: the time offset (global or per-source) shifts programme
  ///   times at map time by up to +/-120 min, so the stored window must
  ///   be wider than the displayed window by that much on both sides.
  /// Overlap semantics (same as [_mapXmltvPrograms]): a programme that
  /// straddles an edge is kept. Fixed maxima — no settings are read at
  /// parse time, so a settings change never strands the retained feed.
  /// "Now" is the parse moment: for a download parse the feed's live
  /// period starts then; for a warm-start parse it keeps exactly what
  /// the current guide window needs.
  ({int fromEpoch, int toEpoch}) _epgParseWindow(DateTime now) {
    final from = now.subtract(const Duration(days: 7, hours: 2));
    final to = now.add(const Duration(days: 8, hours: 2));
    return (
      fromEpoch: from.millisecondsSinceEpoch ~/ 1000,
      toEpoch: to.millisecondsSinceEpoch ~/ 1000,
    );
  }

  /// Store the validators from the latest feed response (1.2.2 I9).
  /// Best-effort: a lost validator only costs one full download next
  /// time — it must never lose the guide.
  Future<void> _saveFeedValidators(String cacheKey, String? etag, String? lastModified) async {
    try {
      await _epgStore.saveValidators(cacheKey, etag, lastModified);
    } catch (_) {
      // Best-effort: the guide is already in memory; the next refresh
      // just downloads in full.
    }
  }

  /// Mark the persisted feed file as fresh (1.2.2 I9): after a 304 the
  /// file's bytes are current, so its last-modified time is the
  /// revalidation time — the next warm start reads it as fresh instead
  /// of revalidating a launch early. Best-effort: the in-memory guide
  /// is already bumped.
  Future<void> _touchFeedFile(String cacheKey) async {
    if (debugDisablePersistedEpg) return;
    try {
      final file = await _xmltvFeedFile(cacheKey);
      if (file.existsSync()) file.setLastModifiedSync(DateTime.now());
    } catch (_) {
      // Best-effort: the file is gone or read-only.
    }
  }

  /// Download + stream-parse the XMLTV feed for [cacheKey] (build #26).
  ///
  /// The response bytes are tee'd to a temp file while they download,
  /// then parsed in a worker isolate (1.2.18 S-1) — the whole feed is
  /// never held as a String, DOM, or isolate copy, and the ~25 s parse
  /// no longer runs on the main isolate. The temp file is promoted to
  /// the persisted feed only when the parse completes successfully,
  /// preserving the old "only a parseable feed is persisted" invariant:
  /// a failed or cancelled download — or a failed parse — deletes the
  /// temp file and keeps the previously persisted feed (if any). A
  /// partial in-memory guide is never served as whole — on failure the
  /// partial list is discarded and the error is recorded exactly as a
  /// failed download was. When no temp file exists (persistence
  /// disabled/unavailable) the parse runs on the main isolate over the
  /// response stream, as before.
  ///
  /// 1.2.2 I9: the fetch happens first and a 304 means the server
  /// already has our feed — the stored guide is reused (its fetch time
  /// bumped to now so the TTL restarts and per-channel entries re-map
  /// from it) with no download and no re-parse. A 304 with no stored
  /// guide anywhere (feed file deleted, persistence disabled) retries
  /// once without validators; a server cannot 304 a request that sent
  /// none, so a second 304 is a broken server and throws exactly like
  /// a failed download.
  Future<_CachedXmltvGuide> _loadXmltvGuide(
    String cacheKey,
    Future<XmltvFeedFetch> Function({bool useValidators}) fetchFeed, {
    Set<String> retainIds = const {},
    // 1.2.19 (L-3): the same trigger the fetch closure carries — the
    // resume download aborts on it too (build #28), and the partial
    // it leaves behind is the next run's resume point, not waste.
    Future<void>? abortTrigger,
  }) async {
    // 1.2.19 (L-4/L-42): metered guard — on a metered link with
    // Wi-Fi-only large downloads on, do not start an 88 MB feed
    // download when a persisted guide already exists; the stale guide
    // answers and the refresh waits for Wi-Fi. With no persisted guide
    // at all, the download proceeds (fail-open: never leave the guide
    // empty over policy).
    if (await MeteredNetwork.largeDownloadsDeferred()) {
      final persisted = await _readPersistedXmltv(cacheKey, caller: 'load');
      if (persisted != null) {
        appLogger.i('IPTV: XMLTV feed for $cacheKey deferred on a metered link (Wi-Fi-only large downloads on) — serving the persisted guide');
        return persisted;
      }
    }
    // 1.2.19 (L-3): the download state both paths fill in — the resume
    // path downloads straight into a claimed partial file, the fetch
    // path tees the response stream into a fresh temp file. The tail
    // below only reads these, never which path ran.
    File? tempFile;
    var downloadedBytes = 0;
    String? feedShaHex;
    String? feedEtag;
    String? feedLastModified;
    var feedResumed = false;
    var feedResumedFromBytes = 0;
    // Claim a previous partial feed download for the Xtream provider
    // feed (only when the feed is persisted — the in-memory debug path
    // has no file to resume from). The claim renames the stable
    // `.resume` file to a unique temp file, so two concurrent loads
    // never append to the same file (1.2.17 R4).
    File? claimedResumeFile;
    if (!debugDisablePersistedEpg && cacheKey.startsWith('xtream:')) {
      claimedResumeFile = await _claimXmltvResumeFile(cacheKey);
    }
    XmltvFeedFetch? resumedFetch;
    if (claimedResumeFile != null) {
      // Resume path: continue the partial download in place. A
      // cancellation or failure keeps the partial (it is moved back to
      // the stable resume path below) — the next load resumes it
      // instead of restarting from byte 0. The 120s per-chunk-gap
      // timeout and the Range handling live in
      // [XtreamApi.downloadXmltvFeedToFile].
      try {
        final download = await _client.xtreamApi.downloadXmltvFeedToFile(
          filePath: claimedResumeFile.path,
          abortTrigger: abortTrigger,
          onProgress: (received, total) {
            _feedDownloadProgress[cacheKey] = (received: received, totalBytes: total);
          },
        );
        tempFile = claimedResumeFile;
        downloadedBytes = download.bytesDownloaded;
        feedShaHex = download.sha256;
        feedEtag = download.etag;
        feedLastModified = download.lastModified;
        feedResumed = download.resumed;
        feedResumedFromBytes = download.resumedFromBytes;
        _feedDownloadProgress.remove(cacheKey);
        appLogger.i('IPTV: XMLTV feed for $cacheKey resumed from $feedResumedFromBytes bytes (total $downloadedBytes bytes)');
        // A synthetic fetch whose stream is already drained — the tee
        // below writes nothing (the file already holds the bytes) and
        // the tail parses the file. The SHA and validators come from
        // the download result, not the empty stream.
        resumedFetch = (bytes: const Stream<List<int>>.empty(), notModified: false, etag: feedEtag, lastModified: feedLastModified);
      } catch (e) {
        _feedDownloadProgress.remove(cacheKey);
        // Keep the partial for the next run — move the claimed file
        // back to the stable resume path (keeping the longer of the two
        // if a newer partial landed meanwhile).
        await _restoreXmltvResumeFile(claimedResumeFile, cacheKey);
        if (!MediaServerHttpException.from(e).isCancellation) {
          _xmltvFailedAt[cacheKey] = DateTime.now();
        }
        rethrow;
      }
    }
    // I9: fetch first — a 304 answers before any download or parse.
    XmltvFeedFetch fetch;
    if (resumedFetch != null) {
      fetch = resumedFetch;
    } else {
      try {
        fetch = await fetchFeed();
      } catch (e) {
        if (!MediaServerHttpException.from(e).isCancellation) {
          _xmltvFailedAt[cacheKey] = DateTime.now();
        }
        rethrow;
      }
    }
    if (fetch.notModified) {
      final existing = _xmltvCache[cacheKey];
      if (existing != null) {
        await _saveFeedValidators(cacheKey, fetch.etag, fetch.lastModified);
        await _touchFeedFile(cacheKey);
        // 1.2.5 Fix 1: a 304 reuses the stored guide — its parse stats
        // (display names, pre-filter counts), metadata, and window
        // carry forward with it; only the fetch time is bumped.
        final guide = existing.withFetchedAt(DateTime.now());
        _xmltvCache[cacheKey] = guide;
        _xmltvFailedAt.remove(cacheKey);
        // 1.2.15 R4: a 304 downloads nothing — record that, keeping
        // the previous counts (the guide carried forward) and the
        // validators the server sent.
        _lastFeedDownloads[cacheKey] = (
          notModified: true,
          bytesDownloaded: 0,
          sha256: null,
          channelsParsed: guide.channelsParsed,
          channelsRetained: guide.programCountByChannel.length,
          programsParsed: guide.programsParsed,
          programsRetained: guide.totalProgramCount,
          etag: fetch.etag,
          lastModified: fetch.lastModified,
          fetchedAt: guide.fetchedAt,
          // 1.2.19 (L-3): a 304 never resumes — nothing was downloaded.
          resumed: false,
          resumedBytes: 0,
        );
        // L-44: a 304 revalidates without downloading — record it so
        // the week's cadence log can tell revalidations from downloads.
        EpgCadenceLog.recordFeedDownload(sourceKey: cacheKey, notModified: true);
        return guide;
      }
      // No guide to reuse: the stored validators are stale relative to
      // storage. Fetch fresh without them.
      try {
        fetch = await fetchFeed(useValidators: false);
      } catch (e) {
        if (!MediaServerHttpException.from(e).isCancellation) {
          _xmltvFailedAt[cacheKey] = DateTime.now();
        }
        rethrow;
      }
      if (fetch.notModified) {
        // A server cannot 304 a request that sent no validators: this
        // is a broken server. Throw exactly like a failed download.
        _xmltvFailedAt[cacheKey] = DateTime.now();
        throw StateError('XMLTV feed for $cacheKey answered 304 without validators');
      }
    }
    // L-44: past the 304 handling, this fetch carries a body — a real
    // download. The week's log decides whether the feed is
    // re-downloaded more than once a day (then the cadence control
    // gets built); a 304 above does not count.
    EpgCadenceLog.recordFeedDownload(sourceKey: cacheKey, notModified: false);
    // 1.2.12: the accumulator builds counts, slot bitmaps, and the
    // window rows in the single parse pass — the whole feed is never
    // held as a list.
    final window = _epgParseWindow(DateTime.now());
    final accumulator = _XmltvGuideAccumulator(
      retainIds: retainIds,
      windowFrom: DateTime.fromMillisecondsSinceEpoch(window.fromEpoch * 1000),
      windowTo: DateTime.fromMillisecondsSinceEpoch(window.toEpoch * 1000),
    );
    _feedParseCount++;
    // 1.2.5 Fix 1: the parse stats (display names, pre-filter counts)
    // are what the Reload diagnostics report from.
    final stats = XmltvParseStats();
    // Tee the raw bytes to a temp file in the same directory, so the
    // promote is a same-filesystem rename. Skipped entirely when the
    // persisted side is disabled for tests. If the temp file cannot even
    // be located (the cache directory is unavailable), the download still
    // parses in memory and serves — persistence is best-effort, never a
    // reason to lose the guide (the pre-#26 path parsed in memory and
    // only the write could fail). A resumed download already holds its
    // file (claimed above) — it is never replaced by a fresh temp file.
    if (tempFile == null && !debugDisablePersistedEpg) {
      try {
        tempFile = await _xmltvTempFeedFile(cacheKey);
      } catch (e) {
        appLogger.w('IPTV EPG feed cache unavailable for $cacheKey; parsing in memory', error: e);
      }
    }
    // Synchronous file I/O throughout (build #26): async dart:io never
    // completes inside testWidgets fake async (proven by probe: an
    // awaited File.exists() hangs, existsSync() works), and the fetch
    // path is awaited by widget tests — so an awaited create/write/
    // rename here would hang the guide in the harness. The parse loop
    // itself stays async (it awaits the byte stream, not the disk).
    // A tee that cannot be set up degrades to in-memory parsing, same as
    // the location fallback above — persistence never loses the guide.
    RandomAccessFile? raf;
    if (tempFile != null) {
      try {
        tempFile.parent.createSync(recursive: true);
        // 1.2.19 (L-3): a resumed file already holds the download —
        // opening it for write would truncate it back to zero.
        if (resumedFetch == null) {
          raf = tempFile.openSync(mode: FileMode.write);
        }
        // 1.2.17 R4: sweep up tmps left by loads that died mid-download.
        _pruneStaleXmltvTempFiles(tempFile.parent, cacheKey);
      } catch (e) {
        appLogger.w('IPTV EPG feed cache unavailable for $cacheKey; parsing in memory', error: e);
        raf = null;
      }
    }
    // 1.2.15 R4: count the downloaded bytes and hash them as they
    // stream past (the temp file holds the same bytes, but reading it
    // back would hold the whole feed in memory again). 1.2.19 (L-3):
    // [downloadedBytes] is hoisted above the resume branch — the
    // resume path fills it from the download result instead.
    final shaDigestSink = _DigestCollector();
    final shaSink = crypto.sha256.startChunkedConversion(shaDigestSink);
    try {
      // 1.2.18 S-1: the bytes are tee'd to the temp file and hashed
      // here, but NOT parsed — the parse runs in a worker isolate
      // over the temp file below, so the ~25 s main-isolate parse
      // (round-2 §1) no longer blocks the guide during a download.
      // When there is no temp file (persistence disabled or the cache
      // directory unavailable) the parse stays on the main isolate
      // over the response stream, exactly as before — persistence
      // never loses the guide.
      if (tempFile != null) {
        // Drained for the side effects (tee + hash) only.
        await for (final _ in fetch.bytes.map((chunk) {
          raf?.writeFromSync(chunk);
          shaSink.add(chunk);
          downloadedBytes += chunk.length;
          // 1.2.19 (L-3): the Reload row polls this while the
          // download runs — the fresh path has no declared total, so
          // the dialog shows bytes received only.
          _feedDownloadProgress[cacheKey] = (received: downloadedBytes, totalBytes: null);
          return chunk;
        })) {}
      } else {
        // I8: the parse-time window filter — programmes outside the
        // widest guide window are dropped during the parse and never
        // retained.
        await for (final program in parseXmltvStream(
          fetch.bytes.map((chunk) {
            shaSink.add(chunk);
            downloadedBytes += chunk.length;
            // 1.2.19 (L-3): same live progress as the tee branch above.
            _feedDownloadProgress[cacheKey] = (received: downloadedBytes, totalBytes: null);
            return chunk;
          }),
          windowFromEpoch: window.fromEpoch,
          windowToEpoch: window.toEpoch,
          stats: stats,
        )) {
          accumulator.add(program);
        }
      }
      raf?.closeSync();
      raf = null;
      shaSink.close();
      // 1.2.19 (L-3): the download phase is over — the parse below is
      // not a download, so the Reload row stops showing progress.
      _feedDownloadProgress.remove(cacheKey);
    } catch (e) {
      // Build #28: a cancellation is not a failure — the app backgrounded
      // or the feed was stopped, not refused. It must not poison the
      // negative cache, or the next guide fetch would refuse to download
      // the feed for 120 s.
      try {
        raf?.closeSync();
      } catch (_) {
        // Best-effort: the file is gone or already closed.
      }
      // 1.2.19 (L-3): a failed or cancelled download still leaves a
      // partial behind — keep it as the resume point for the next load
      // (Xtream provider feed only) instead of deleting it. A resumed
      // file that fails again is restored by its own catch above; this
      // branch covers the fresh-download path.
      if (!debugDisablePersistedEpg && cacheKey.startsWith('xtream:')) {
        if (tempFile != null) await _restoreXmltvResumeFile(tempFile, cacheKey);
      } else {
        try {
          if (tempFile != null && tempFile.existsSync()) tempFile.deleteSync();
        } catch (_) {
          // Best-effort: the temp file is gone or already deleted.
        }
      }
      // 1.2.19 (L-3): the download stopped — the partial (if any) is
      // the next load's resume point, not in-flight progress any more.
      _feedDownloadProgress.remove(cacheKey);
      if (!MediaServerHttpException.from(e).isCancellation) {
        _xmltvFailedAt[cacheKey] = DateTime.now();
      }
      rethrow;
    }
    // 1.2.19 (L-3): the tail reads the hoisted locals — the fetch path
    // fills them from the tee's digest and the response validators, the
    // resume path filled them from the download result above.
    feedShaHex ??= shaDigestSink.value?.toString();
    feedEtag ??= fetch.etag;
    feedLastModified ??= fetch.lastModified;
    // 1.4.4 F2: the new download is byte-identical to the previous one
    // (same SHA-256, and the row store's generation record matches it)
    // — skip the parse + store rebuild entirely and reuse the stored
    // guide. The persisted feed file is NOT touched: its mtime is part
    // of the store's generation record, and touching it would make the
    // store read as invalid on the next warm start. The guide's fetch
    // time is bumped in memory (like the 304 path) so the TTL restarts.
    // The temp file is deleted — the persisted feed already holds
    // these exact bytes. (This does not save the download itself: with
    // no validators from the panel, downloading is the only way to know
    // the content is unchanged. It saves the ~4 s parse + rebuild and
    // the memory spike.)
    // The store lives next to the temp file: when there is no temp
    // file (persistence disabled, or the cache directory unavailable
    // so the download parsed in memory) there is no store to reuse —
    // never resolve the feed-file path here to find it. That call
    // throws when the cache directory is unavailable, and this check
    // must not fail a load the in-memory parse below would serve.
    if (!debugDisablePersistedEpg && !debugDisableFeedRowStore && feedShaHex != null && tempFile != null) {
      final dbPath = IptvFeedRowStore.dbPathForDirAndKey(tempFile.parent.path, _fileSafe(cacheKey));
      if (IptvFeedRowStore.isValid(dbPath: dbPath, expectedSha256: feedShaHex)) {
        final reused = await _readFeedRowsFromStore(cacheKey, retainIds: retainIds);
        if (reused != null) {
          try {
            tempFile.deleteSync();
          } catch (_) {
            // Best-effort: the temp file is gone or already deleted.
          }
          final guide = reused.withFetchedAt(DateTime.now());
          _xmltvCache[cacheKey] = guide;
          _xmltvFailedAt.remove(cacheKey);
          _lastFeedDownloads[cacheKey] = (
            notModified: true,
            bytesDownloaded: downloadedBytes,
            sha256: feedShaHex,
            channelsParsed: guide.channelsParsed,
            channelsRetained: guide.programCountByChannel.length,
            programsParsed: guide.programsParsed,
            programsRetained: guide.totalProgramCount,
            etag: feedEtag,
            lastModified: feedLastModified,
            fetchedAt: guide.fetchedAt,
            resumed: feedResumed,
            resumedBytes: feedResumedFromBytes,
          );
          appLogger.i(
            'IPTV: feed for $cacheKey unchanged (SHA matches the previous download) — reusing the stored guide, parse skipped',
          );
          return guide;
        }
      }
    }
    // 1.2.18 S-1: parse the downloaded temp file in a worker isolate
    // BEFORE promoting it — the old "only a parseable feed is
    // persisted" invariant holds: a failed parse deletes the temp file
    // and keeps the previously persisted feed (if any), exactly as a
    // failed download did. A parse failure is recorded like a failed
    // download (unless it is a cancellation — build #28).
    _CachedXmltvGuide? parsedGuide;
    if (tempFile != null) {
      try {
        parsedGuide = await _parseFeedFile(
          tempFile,
          DateTime.fromMillisecondsSinceEpoch(window.fromEpoch * 1000),
          DateTime.fromMillisecondsSinceEpoch(window.toEpoch * 1000),
          retainIds,
          DateTime.now(),
          // 1.2.18 S-4b: trim before the parse starts (at job-start
          // time, inside the gate — not at queue time).
          onStart: () => _trimCachesIfHot('downloaded feed parse'),
          // 1.2.20 (a): the download parse builds the row store for
          // this generation (the tee's freshly computed SHA).
          cacheKey: cacheKey,
          storeSha256: feedShaHex,
          caller: 'download',
        );
      } catch (e) {
        try {
          if (tempFile.existsSync()) tempFile.deleteSync();
        } catch (_) {
          // Best-effort: the temp file is gone or already deleted.
        }
        if (!MediaServerHttpException.from(e).isCancellation) {
          _xmltvFailedAt[cacheKey] = DateTime.now();
        }
        rethrow;
      }
      // 1.2.18 S-8b: the parse spike is over — drop its leftovers
      // (image cache + oldest half of the short-EPG cache) while RSS
      // is still hot, before promoting the feed.
      _trimCachesIfHot('downloaded feed parse', after: true);
      // Parse completed: the temp file holds exactly the bytes parsed,
      // so promote it to the persisted feed. A rename failure must not
      // lose the parsed guide — the in-memory guide still serves this
      // launch, and the next cold start re-downloads.
      try {
        final feedFile = await _xmltvFeedFile(cacheKey);
        promoteFeedFile(tempFile, feedFile, cacheKey);
      } catch (e) {
        appLogger.w('IPTV EPG feed cache write failed for $cacheKey', error: e);
      }
    }
    // I9: store the response validators for the next refresh (also on a
    // 200 that sent none — that clears a stale row).
    await _saveFeedValidators(cacheKey, feedEtag, feedLastModified);
    final guide = parsedGuide ??
        accumulator.build(
          fetchedAt: DateTime.now(),
          displayNames: stats.channelDisplayNames,
          programsParsed: stats.programsSeen,
          channelsParsed: stats.channelIds.length,
          channelIdsSeen: {...stats.channelIds, ...stats.programChannelIds},
        );
    _xmltvCache[cacheKey] = guide;
    _xmltvFailedAt.remove(cacheKey);
    // 1.2.15 R4: the download's facts — bytes, SHA of exactly the
    // bytes parsed, counts before/after the window filter, validators.
    _lastFeedDownloads[cacheKey] = (
      notModified: false,
      bytesDownloaded: downloadedBytes,
      sha256: feedShaHex,
      channelsParsed: guide.channelsParsed,
      channelsRetained: guide.programCountByChannel.length,
      programsParsed: guide.programsParsed,
      programsRetained: guide.totalProgramCount,
      etag: feedEtag,
      lastModified: feedLastModified,
      fetchedAt: guide.fetchedAt,
      // 1.2.19 (L-3): whether this download resumed a partial file,
      // and how many bytes came from it — the Reload report shows
      // "resumed from X" so a resumed feed is visible, not silent.
      resumed: feedResumed,
      resumedBytes: feedResumedFromBytes,
    );
    return guide;
  }

  /// Parse [file] into a guide in a worker isolate (1.2.18 S-1), or
  /// on the main isolate when [debugDisableIsolateFeedParse] is set
  /// (tests: `compute` futures need `runAsync` in `testWidgets` fake
  /// async, and the sync test path keeps the old behaviour).
  /// Row-store builds in flight per cache key (1.2.20 (a)): one
  /// build per key at a time — a second build request for the same key
  /// skips its own build instead of starting a second writer (the
  /// first build's DB is there when the second parse's slides run).
  /// The heavy-work gate already serialises parse jobs, so this is
  /// defence-in-depth for the background-build fallback, not the only
  /// guard.
  static final Set<String> _feedStoreBuildsInFlight = {};

  static Future<_CachedXmltvGuide> _parseFeedFile(
    File file,
    DateTime windowFrom,
    DateTime windowTo,
    Set<String> retainIds,
    DateTime fetchedAt, {
    void Function()? onStart,
    // 1.2.20 (a): the feed's cache key — when non-null the parse also
    // builds the row store next to the persisted XML (unless storage
    // is low or the test seam disables it). Null for parses that have
    // no persisted feed to anchor a store to.
    String? cacheKey,
    // 1.2.20 (a): the download SHA for the store's generation record
    // (the download path's freshly computed SHA, or the last
    // download's SHA for a slide/warm-start parse). Null when unknown
    // — the store is not built without a SHA to stamp it with.
    String? storeSha256,
    // 1.2.20 (C3): which path started this parse — `download`,
    // `warm-start`, `slide`, or `load`. Logged on the slow-op record
    // and the thermal snapshot so the debug log can say which path
    // started a parse, and kept on [debugLastFeedParseCaller] for tests.
    String caller = 'unknown',
  }) async {
    // 1.2.20 (a): the store-build decision — built in the same isolate
    // pass as the parse, so it adds SQLite inserts, not a second file
    // pass. Skipped when there is no key, no SHA, low storage (the
    // L-20 500 MB threshold — a store build on a nearly-full disk
    // fails silently or stalls the eMMC), the test seam, or another
    // build for the same key is already in flight. The DB lives next
    // to the persisted XML (`feed_<key>.db`); the file being parsed is
    // the temp file on the download path and the persisted file on a
    // slide — same directory either way, and the rename preserves the
    // stat the generation record stamps.
    String? storeDbPath;
    int? storeXmlMtimeMs;
    int? storeXmlSizeBytes;
    var buildStore = false;
    if (cacheKey != null &&
        storeSha256 != null &&
        !debugDisableFeedRowStore &&
        !StorageHealth.isLowFreeSpace &&
        !_feedStoreBuildsInFlight.contains(cacheKey)) {
      try {
        final stat = file.statSync();
        storeDbPath = IptvFeedRowStore.dbPathForDirAndKey(file.parent.path, _fileSafe(cacheKey));
        storeXmlMtimeMs = stat.modified.millisecondsSinceEpoch;
        storeXmlSizeBytes = stat.size;
        buildStore = true;
      } catch (_) {
        // Best-effort: no stat, no store — the parse still serves.
        storeDbPath = null;
        storeXmlMtimeMs = null;
        storeXmlSizeBytes = null;
      }
    }
    final request = _XmltvFeedParseRequest(
      path: file.path,
      windowFromEpoch: windowFrom.millisecondsSinceEpoch ~/ 1000,
      windowToEpoch: windowTo.millisecondsSinceEpoch ~/ 1000,
      retainIds: retainIds,
      fetchedAt: fetchedAt,
      storeDbPath: storeDbPath,
      storeSha256: storeSha256,
      storeXmlMtimeMs: storeXmlMtimeMs,
      storeXmlSizeBytes: storeXmlSizeBytes,
    );
    // 1.2.18 S-3: the feed parse is a heavy job — it waits its turn
    // behind any running sync/seed/M3U parse, and jumps ahead of a
    // queued sync (the guide outranks background work).
    // L-52 / L-45 / L-51: the feed parse is a named slow op (threshold
    // 5 s) bracketed by thermal snapshots, with a phase-RSS sample when
    // it lands. Silence is the pass signal — a fast parse logs nothing
    // beyond the phase sample. The snapshots are fire-and-forget and
    // never block the parse.
    // 1.2.20 (C3): the call-site tag rides the slow-op record and the
    // thermal snapshot, so the debug log can say which path started a
    // parse — the 2026-11-15 log had 7 parse starts with no caller.
    debugLastFeedParseCaller = caller;
    final parseWatch = Stopwatch()..start();
    final parseRssBeforeMb = ProcessInfo.currentRss >> 20;
    unawaited(ThermalProbe.snapshot('feed-parse-start:$caller'));
    if (buildStore) _feedStoreBuildsInFlight.add(cacheKey!);
    try {
      final guide = await IptvHeavyWorkGate.instance.run(
        () => debugDisableIsolateFeedParse
            ? _parseXmltvFeedFile(request)
            : compute(_parseXmltvFeedFile, request),
        priority: IptvHeavyWorkPriority.guide,
        onStart: onStart,
      );
      parseWatch.stop();
      SlowOpLog.instance.record(
        'feed-parse',
        parseWatch.elapsedMilliseconds,
        rssBeforeMb: parseRssBeforeMb,
        rssAfterMb: ProcessInfo.currentRss >> 20,
        detail: 'caller=$caller',
      );
      // 1.2.20 (a): the store-build cost, next to the feed-parse slow
      // op — the budget gate (<= 5 s added to the download parse on
      // the Fold) is judged from this line in the debug log.
      if (guide.feedStoreBuildMs != null) {
        final bytes = guide.feedStoreBytes;
        appLogger.i(
          'IPTV: feed-store-build ms=${guide.feedStoreBuildMs} '
          '${bytes == null ? 'failed' : 'bytes=$bytes'} cacheKey=$cacheKey',
        );
      }
      PhaseRssSampler.instance.sample('feed-parsed');
      unawaited(ThermalProbe.snapshot('feed-parse-end'));
      return guide;
    } catch (e) {
      parseWatch.stop();
      SlowOpLog.instance.record(
        'feed-parse',
        parseWatch.elapsedMilliseconds,
        rssBeforeMb: parseRssBeforeMb,
        rssAfterMb: ProcessInfo.currentRss >> 20,
        detail: 'caller=$caller',
      );
      unawaited(ThermalProbe.snapshot('feed-parse-end'));
      rethrow;
    } finally {
      if (buildStore) _feedStoreBuildsInFlight.remove(cacheKey);
    }
  }

  /// Temp file the feed download is tee'd to while parsing (build #26):
  /// promoted to the persisted feed only on a successful parse. The
  /// `.tmp` suffix (not `.xml`) keeps it invisible to the feed-file
  /// helpers, which look for `*.xml`.
  /// Monotonic suffix for unique tmp feed names (1.2.17 R4).
  static int _xmltvTempFeedSequence = 0;

  /// A UNIQUE tmp file per feed load (1.2.17 R4): the old deterministic
  /// name (`feed_<key>.tmp`) let two concurrent loads for one connection
  /// tee to the same file — the first renamed tmp→xml, the second hit
  /// PathNotFoundException at its rename (and its promote deleted the
  /// first's just-promoted file, so the next cold start re-downloaded).
  /// The window slide re-downloads without registering in the in-flight
  /// futures map, so two slides can still run concurrently for one key —
  /// each needs its own tmp.
  Future<File> _xmltvTempFeedFile(String cacheKey) async {
    final dir = await _epgCacheDir();
    final unique = '${DateTime.now().microsecondsSinceEpoch}_${_xmltvTempFeedSequence++}';
    return File('${dir.path}/feed_${_fileSafe(cacheKey)}_$unique.tmp');
  }

  /// Delete stale tmp feed files for [cacheKey] (1.2.17 R4): a load that
  /// dies mid-download leaves its tmp behind. Best-effort, sync I/O —
  /// only files older than an hour are removed, never a fresh in-flight
  /// tmp from a concurrent load.
  void _pruneStaleXmltvTempFiles(Directory dir, String cacheKey) {
    try {
      final prefix = 'feed_${_fileSafe(cacheKey)}_';
      final cutoff = DateTime.now().subtract(const Duration(hours: 1));
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (!name.startsWith(prefix) || !name.endsWith('.tmp')) continue;
        try {
          if (entity.lastModifiedSync().isBefore(cutoff)) {
            entity.deleteSync();
          }
        } catch (_) {
          // One stale tmp that cannot be deleted is harmless.
        }
      }
    } catch (_) {
      // Best-effort: a listing failure never breaks the download.
    }
  }

  /// Stable resume path for the Xtream provider feed (1.2.19, L-3):
  /// the partial download lives here between loads, next to the
  /// persisted feed file. The `.resume` suffix keeps
  /// [_pruneStaleXmltvTempFiles] (which prunes only `*.tmp`) from ever
  /// deleting it. The name is stable across runs ([_fileSafe] is a
  /// base64url of the key, not a hashCode). Sync file I/O once the
  /// directory is resolved — the feed path runs under widget tests,
  /// where real async disk I/O never completes inside fake async.
  Future<File> _xmltvResumeFeedFile(String cacheKey) async {
    final dir = await _epgCacheDir();
    return File('${dir.path}/feed_${_fileSafe(cacheKey)}.resume');
  }

  /// Claim a previous partial feed download for the next load: rename
  /// the stable `.resume` file to a unique temp file (1.2.17 R4 —
  /// concurrent loads must never share one file) and return it, or
  /// null when there is no partial worth resuming (missing or empty).
  /// The claim is exclusive — once renamed, no other load can claim
  /// the same partial.
  Future<File?> _claimXmltvResumeFile(String cacheKey) async {
    try {
      final resumeFile = await _xmltvResumeFeedFile(cacheKey);
      if (!resumeFile.existsSync() || resumeFile.lengthSync() == 0) return null;
      final claimed = await _xmltvTempFeedFile(cacheKey);
      return resumeFile.renameSync(claimed.path);
    } catch (_) {
      return null;
    }
  }

  /// Move a (partial) feed file to the stable resume path, keeping the
  /// LONGER of the two when a resume file already exists (a newer
  /// partial may have landed while this load was running). A zero-byte
  /// file is never kept as the resume point — it is deleted.
  Future<void> _restoreXmltvResumeFile(File file, String cacheKey) async {
    try {
      final resumeFile = await _xmltvResumeFeedFile(cacheKey);
      if (!file.existsSync()) return;
      if (file.lengthSync() == 0) {
        file.deleteSync();
        return;
      }
      if (resumeFile.existsSync()) {
        if (resumeFile.lengthSync() >= file.lengthSync()) {
          file.deleteSync();
          return;
        }
        resumeFile.deleteSync();
      }
      file.renameSync(resumeFile.path);
    } catch (_) {
      // Best-effort: a lost resume point just means a fresh download.
    }
  }

  /// Promote a parsed feed temp file to the persisted feed file (1.2.22
  /// §63.1): the destination directory is created first — a concurrent
  /// clear can delete it between the temp-file creation and this rename,
  /// and the rename would fail on the missing folder — and a temp file
  /// that vanished meanwhile reads as a failed download (plain-words
  /// warning, in-memory serving, re-download next cold start), never a
  /// crash. Returns true when the file landed.
  @visibleForTesting
  static bool promoteFeedFile(File tempFile, File feedFile, String cacheKey) {
    try {
      if (!tempFile.existsSync()) {
        appLogger.w(
          'IPTV EPG feed cache write failed for $cacheKey: the downloaded feed file is gone, so the guide will download again next time',
        );
        return false;
      }
      feedFile.parent.createSync(recursive: true);
      if (feedFile.existsSync()) feedFile.deleteSync();
      tempFile.renameSync(feedFile.path);
      return true;
    } catch (e) {
      appLogger.w('IPTV EPG feed cache write failed for $cacheKey', error: e);
      return false;
    }
  }

  /// The persisted XMLTV feed file for [cacheKey]
  /// (`feed_<base64url(key)>.xml` next to the per-channel files). The raw
  /// bytes are stored, not the parsed guide — parsing streams from the
  /// file on read (build #26), same as on download.
  Future<File> _xmltvFeedFile(String cacheKey) async {
    final dir = await _epgCacheDir();
    return File('${dir.path}/feed_${_fileSafe(cacheKey)}.xml');
  }

  /// Read + parse the persisted feed file, or null when there is none (or
  /// it is unreadable / unparseable — a corrupt file reads as a miss, and
  /// is deleted so it is not re-parsed on every cold start). The guide's
  /// fetch time is the file's last-modified time.
  Future<_CachedXmltvGuide?> _readPersistedXmltv(
    String cacheKey, {
    Set<String> retainIds = const {},
    DateTime? fetchedAtOverride,
    // 1.2.20 (C3): which path started this read — `warm-start`,
    // `slide`, or `load`. Passed through to [_parseFeedFile] so the
    // slow-op record can name the caller.
    String caller = 'warm-start',
  }) async {
    if (debugDisablePersistedEpg) return null;
    // 1.2.20 (C3): the warm-start join — concurrent reads for one key
    // share the first read instead of each starting a whole-file
    // re-parse (the 7-parses-in-30-s storm). A joiner may get a guide
    // whose window covers the first caller's ids, not its own — the
    // caller always re-slides via [_ensureGuideWindow] when its ids
    // are missing, so a shared window is never a wrong answer, only
    // a cheap follow-up slide.
    final inFlight = _xmltvPersistedReadFutures[cacheKey];
    if (inFlight != null) return inFlight;
    final future = _readPersistedXmltvLocked(
      cacheKey,
      retainIds: retainIds,
      fetchedAtOverride: fetchedAtOverride,
      caller: caller,
    );
    _xmltvPersistedReadFutures[cacheKey] = future;
    try {
      return await future;
    } finally {
      _xmltvPersistedReadFutures.removeWhere((key, value) => key == cacheKey && identical(value, future));
    }
  }

  Future<_CachedXmltvGuide?> _readPersistedXmltvLocked(
    String cacheKey, {
    Set<String> retainIds = const {},
    DateTime? fetchedAtOverride,
    String caller = 'warm-start',
  }) async {
    File? file;
    try {
      file = await _xmltvFeedFile(cacheKey);
      if (!file.existsSync()) return null;
      // Build #26: stream-parse the file instead of reading the whole
      // body into a String — the cold-start path held the whole feed
      // ~4x at once (~1.45 GB peak RSS at Trex scale). 1.2.18 S-1:
      // the parse runs in a worker isolate over the file. A corrupt
      // file (including a truncated one) throws here and is deleted
      // below, exactly as before. Synchronous reads (see
      // _loadXmltvGuide): async dart:io never completes inside
      // testWidgets fake async, and this read is awaited on the fetch
      // path — the 64 KB sync chunks keep the streaming property (no
      // whole-file String) without touching the event loop.
      // I8 (1.2.2): the parse-time window filter applies here too — a
      // warm start keeps exactly what the current guide window needs
      // instead of re-retaining the whole persisted feed.
      final window = _epgParseWindow(DateTime.now());
      _feedParseCount++;
      // Awaited (not returned) so a parse failure is caught below —
      // the corrupt file is deleted and the read reports a miss.
      final guide = await _parseFeedFile(
        file,
        DateTime.fromMillisecondsSinceEpoch(window.fromEpoch * 1000),
        DateTime.fromMillisecondsSinceEpoch(window.toEpoch * 1000),
        retainIds,
        // A slide re-parses the same bytes, so the generation is
        // unchanged — the override keeps the original fetchedAt.
        fetchedAtOverride ?? file.lastModifiedSync(),
        // 1.2.18 S-4b: trim before the parse starts (at job-start
        // time, inside the gate — not at queue time).
        onStart: () => _trimCachesIfHot('persisted feed parse'),
        // 1.2.20 (a): a slide/warm-start re-parse rebuilds the store
        // for the current generation (the download's SHA, when known).
        cacheKey: cacheKey,
        storeSha256: _lastFeedDownloads[cacheKey]?.sha256,
        caller: caller,
      );
      // 1.2.18 S-8b: the parse spike is over — drop its leftovers
      // while RSS is still hot.
      _trimCachesIfHot('persisted feed parse', after: true);
      return guide;
    } catch (_) {
      try {
        if (file != null && file.existsSync()) file.deleteSync();
        // 1.2.20 (a): a corrupt feed file takes its row store with it.
        // A missing XML does NOT invalidate the store (the DB keeps
        // serving when the file is gone), so leaving the DB behind
        // would keep serving the corrupt feed's rows from the store
        // after the file was deleted for being corrupt.
        if (file != null) IptvFeedRowStore.delete(IptvFeedRowStore.dbPathForXmlPath(file.path));
      } catch (_) {
        // Best-effort: the file is gone or unreadable anyway.
      }
      return null;
    }
  }

  /// A file as a byte stream read in 64 KB synchronous chunks (build
  /// #26): the streaming parser needs a [Stream], but async file reads
  /// never complete inside testWidgets fake async — sync reads do, and
  /// the generator only yields between chunks, so the whole file is
  /// never held in memory at once.
  static Stream<List<int>> _readFileInChunks(File file) async* {
    final raf = file.openSync();
    try {
      while (true) {
        final chunk = raf.readSync(65536);
        if (chunk.isEmpty) break;
        yield chunk;
      }
    } finally {
      raf.closeSync();
    }
  }

  /// A byte stream that closes [client] when the stream ends, errors, or
  /// is cancelled — the per-fetch client must not outlive its response.
  static Stream<List<int>> _closeClientOnDone(Stream<List<int>> stream, http.Client client) async* {
    try {
      yield* stream;
    } finally {
      client.close();
    }
  }

  /// 1.3.28: gunzip a feed stream whose first bytes carry the gzip
  /// magic (0x1F 0x8B) — every live public US guide is a `.xml.gz`,
  /// and the added-source path (package:http, no auto-decompression,
  /// unlike the Xtream path's HttpClient autoUncompress) used to hand
  /// raw gzip bytes to the XML parser. Magic-byte sniffing, not the
  /// URL suffix: a plain `.xml` served gzip-encoded is caught too, and
  /// a `.gz` URL serving plain XML passes through untouched. The
  /// persisted feed file then holds XML (what the cold-start re-parse
  /// needs), and the byte/SHA stats describe the parsed bytes.
  static Stream<List<int>> _gunzipFeedIfNeeded(Stream<List<int>> source) async* {
    final it = StreamIterator<List<int>>(source);
    try {
      // Buffer small leading chunks until the magic bytes can be
      // judged (a 1-byte first chunk must not decide the stream).
      final head = <int>[];
      var isGzip = false;
      var decided = false;
      while (!decided) {
        if (!await it.moveNext()) return; // Empty stream.
        head.addAll(it.current);
        if (head.length >= 2) {
          decided = true;
          isGzip = head[0] == 0x1f && head[1] == 0x8b;
        }
      }
      Stream<List<int>> rest() async* {
        while (await it.moveNext()) {
          yield it.current;
        }
      }
      if (!isGzip) {
        yield head;
        yield* rest();
        return;
      }
      appLogger.i('IPTV: EPG feed is gzip-compressed, decompressing before parse');
      Stream<List<int>> all() async* {
        yield head;
        yield* rest();
      }
      yield* all().transform(GZipCodec().decoder);
    } finally {
      await it.cancel();
    }
  }

  /// The M3U feed as a byte stream plus the conditional-fetch outcome
  /// (build #26, 1.2.2 I9): the old bare `http.get` buffered the whole
  /// body, and its abort only raced the get — the socket could finish in
  /// the background. An [AbortableRequest] aborts at the socket (as the
  /// Xtream feed does), and the short-lived client is closed when the
  /// stream ends, errors, or is cancelled, so an abandoned download
  /// never holds a socket open. When [etag]/[lastModified] are given
  /// they are sent as If-None-Match / If-Modified-Since; a 304 comes
  /// back as `notModified: true` with an empty body.
  Future<XmltvFeedFetch> _m3uFeedFetch(
    String epgUrl,
    Future<void>? abortTrigger, {
    String? etag,
    String? lastModified,
  }) async {
    // 1.6.15 (WARP tunnel): the feed fetch rides the tunnel's local
    // proxy while it is on (the provider proxy — this fetch only ever
    // talks to the provider), and goes direct otherwise. The client is
    // short-lived and closed when the stream ends, as before.
    final client = WarpTunnelService.instance.proxiedHttpClient();
    http.StreamedResponse streamed;
    try {
      final request = http.AbortableRequest('GET', Uri.parse(epgUrl), abortTrigger: abortTrigger);
      // 1.6.12 (R2): the M3U feed used to send no User-Agent header, so
      // the panel saw Dart's default `Dart/3.13 (dart:io)` — the same
      // distinctive signature the Xtream calls were fixed for in build
      // #20. Wear the effective UA (an M3U playlist's guide URL is
      // usually the same provider).
      request.headers['User-Agent'] = IptvClient.effectiveUserAgent;
      if (etag != null) request.headers['If-None-Match'] = etag;
      if (lastModified != null) request.headers['If-Modified-Since'] = lastModified;
      streamed = await client.send(request).timeout(const Duration(seconds: 120));
    } catch (e) {
      client.close();
      rethrow;
    }
    if (streamed.statusCode == 304) {
      // A 304 has no body by definition: the feed the caller already
      // holds is current.
      _logM3uFeedFetch(statusCode: 304, headers: streamed.headers, sentEtag: etag, sentLastModified: lastModified);
      client.close();
      return (
        bytes: const Stream<List<int>>.empty(),
        notModified: true,
        etag: streamed.headers['etag'],
        lastModified: streamed.headers['last-modified'],
      );
    }
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      client.close();
      throw StateError('XMLTV fetch failed with HTTP ${streamed.statusCode}');
    }
    // 1.4.4 F4/F5: same one-line fetch record as XtreamApi.getXmltvFeed
    // (see XtreamApi._logFeedFetch) — Content-Encoding / Content-Length
    // and validators sent/received, so the next debug export proves
    // what the M3U panel actually sends.
    _logM3uFeedFetch(statusCode: streamed.statusCode, headers: streamed.headers, sentEtag: etag, sentLastModified: lastModified);
    return (
      bytes: _closeClientOnDone(_gunzipFeedIfNeeded(streamed.stream.timeout(const Duration(seconds: 120))), client),
      notModified: false,
      etag: streamed.headers['etag'],
      lastModified: streamed.headers['last-modified'],
    );
  }

  /// Render the F4/F5 M3U feed-fetch log line (same shape as
  /// XtreamApi._logFeedFetch).
  static void _logM3uFeedFetch({
    required int statusCode,
    required Map<String, String> headers,
    String? sentEtag,
    String? sentLastModified,
  }) {
    String validators(String? etag, String? lastModified) {
      final parts = <String>[];
      if (etag != null) parts.add('etag $etag');
      if (lastModified != null) parts.add('last-modified $lastModified');
      return parts.isEmpty ? 'none' : parts.join(', ');
    }

    appLogger.i(
      'IPTV: XMLTV feed fetch: status $statusCode, '
      'content-encoding: ${headers['content-encoding'] ?? 'none'}, '
      'content-length: ${headers['content-length'] ?? 'none'}, '
      'validators sent: ${validators(sentEtag, sentLastModified)}, '
      'validators received: ${validators(headers['etag'], headers['last-modified'])}',
    );
  }

  /// Bump on every cache clear so the guide can tell its per-channel state
  /// (loaded / failed) is stale and re-fetch visible rows.
  int get epgVersion => _epgVersion;

  /// Wall-clock time of the last EPG fetch that stored at least one
  /// programme on this client (1.1.2 D9), or null before the first one.
  /// The settings screen reads the stored pref
  /// ([SettingsService.iptvEpgLastUpdated]) instead; this is for tests and
  /// diagnostics.
  DateTime? get lastEpgUpdatedAt => _lastEpgUpdatedAt;

  /// 1.2.19, L-35: whether the EPG feed is stale — last updated more
  /// than 24 h ago. Null (never updated) is NOT stale: a fresh install
  /// has no feed to be stale about, and the guide already says the
  /// programmes are missing. The guide banner reads this.
  static bool isFeedStale(DateTime? lastUpdated, {DateTime? now}) {
    if (lastUpdated == null) return false;
    return (now ?? DateTime.now()).difference(lastUpdated) >= const Duration(hours: 24);
  }

  /// Distinct channel-id count of the last loaded XMLTV feed (build #17,
  /// §10) — context for the coverage diagnostic. 0 before any feed loads;
  /// reset by [clearEpgCache].
  int _lastXmltvFeedChannelIds = 0;

  /// The last download's raw facts per feed cache key (1.2.15 R4),
  /// written by [_loadXmltvGuide] — bytes, SHA, counts, 304-vs-200,
  /// validators, fetch time. Source identity + User-Agent attach at
  /// merge time ([_feedDownloadFor]), since the loader only knows the
  /// cache key. 1.2.19 (L-3): [resumed] / [resumedBytes] record
  /// whether the download resumed a partial file, and how many bytes
  /// came from it.
  final Map<String, ({bool notModified, int bytesDownloaded, String? sha256, int channelsParsed, int channelsRetained, int programsParsed, int programsRetained, String? etag, String? lastModified, DateTime fetchedAt, bool resumed, int resumedBytes})>
  _lastFeedDownloads = {};

  /// In-flight feed download progress per cache key (1.2.19, L-3):
  /// bytes received so far in this attempt + the feed's total size
  /// when the server declares it. Written by the resume download's
  /// [onProgress] and by the fresh-path tee below, removed when the
  /// download settles (or the parse starts). The EPG sources screen
  /// polls [feedDownloadProgress] while a Reload runs, so the Reload
  /// row shows live bytes instead of a bare spinner.
  final Map<String, ({int received, int? totalBytes})> _feedDownloadProgress = {};

  /// In-flight feed download progress for [cacheKey] (1.2.19, L-3):
  /// bytes received so far in this attempt + the feed's total size
  /// when the server declares it (resume path only — the fresh path
  /// has no total). Null when no download is in flight for the key.
  ({int received, int? totalBytes})? feedDownloadProgress(String cacheKey) => _feedDownloadProgress[cacheKey];

  /// True while a feed load is in flight for this connection (1.6.32,
  /// D2): the Update-now dialog uses it to tell a download that
  /// already settled from one that never started.
  bool get hasInFlightFeedLoad => _xmltvGuideFutures.isNotEmpty;

  /// Wait for every in-flight feed load to settle (1.6.32, D2): the
  /// Update-now tile keeps its spinner until the background download
  /// finishes instead of clearing it when the dialog appears.
  /// Snapshots the in-flight loads; a load that starts after the
  /// snapshot is not waited on. Never throws — a failed load settles
  /// the wait like a finished one. 1.6.34 (P-07): bounded by
  /// [feedRefreshWaitBudget] — a stalled download stops holding the
  /// wait after the budget, and the download itself keeps running.
  Future<void> waitForFeedRefresh() async {
    final inFlight = List<Future<_CachedXmltvGuide>>.of(_xmltvGuideFutures.values);
    if (inFlight.isEmpty) return;
    final Future<List<void>> wait = Future.wait<void>(
      inFlight.map((f) async {
        try {
          await f;
        } catch (_) {
          // A failed load settles the wait like a finished one.
        }
      }),
    );
    await wait.timeout(
      feedRefreshWaitBudget,
      onTimeout: () {
        appLogger.w(
          'IPTV: feed refresh wait gave up after ${feedRefreshWaitBudget.inMinutes} min — '
          'the download continues in the background',
        );
        return <void>[];
      },
    );
  }

  /// The provider feed's cache key for this connection
  /// (`xtream:<connection id>`) — the same key the feed loader uses.
  String get xtreamFeedCacheKey => 'xtream:${_client.connection.id}';

  /// True when a partial feed download is waiting to be resumed for
  /// [cacheKey] (1.2.19, L-3): a non-empty `.resume` file sits at the
  /// stable resume path, so the next load continues it instead of
  /// restarting from byte 0. Sync file I/O once the directory is
  /// resolved — the feed path runs under widget tests, where real
  /// async disk I/O never completes inside fake async.
  Future<bool> hasPendingFeedResume(String cacheKey) async {
    if (!cacheKey.startsWith('xtream:')) return false;
    try {
      final resumeFile = await _xmltvResumeFeedFile(cacheKey);
      return resumeFile.existsSync() && resumeFile.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  /// Guide coverage over the channels this support has loaded EPG for
  /// (build #17, §10): the guide only fetches visible rows, so this set
  /// IS the visible guide. Computed from the per-channel cache entries
  /// (in-memory + persisted), so it survives a relaunch; entries read
  /// from disk files written before this build report `unknown`.
  IptvGuideCoverage guideCoverage() {
    var withPrograms = 0;
    var fromFeedById = 0;
    var fromFeedByName = 0;
    var fromShortEpg = 0;
    var fromMixed = 0;
    var none = 0;
    var unknown = 0;
    final bySourceId = <String, int>{};
    for (final entry in _epgCache.values) {
      if (entry.programs.isEmpty) {
        none++;
        continue;
      }
      withPrograms++;
      if (entry.sourceId != null) {
        bySourceId[entry.sourceId!] = (bySourceId[entry.sourceId!] ?? 0) + 1;
      }
      switch (entry.source) {
        case IptvEpgSource.feedById:
          fromFeedById++;
        case IptvEpgSource.feedByName:
          fromFeedByName++;
        case IptvEpgSource.shortEpg:
          fromShortEpg++;
        case IptvEpgSource.mixed:
          fromMixed++;
        case IptvEpgSource.none:
          // A fetch that recorded `none` cannot have programmes; treat a
          // non-empty entry as unknown rather than dropping the row.
          unknown++;
        case IptvEpgSource.unknown:
          unknown++;
      }
    }
    return IptvGuideCoverage(
      total: _epgCache.length,
      withPrograms: withPrograms,
      fromFeedById: fromFeedById,
      fromFeedByName: fromFeedByName,
      fromShortEpg: fromShortEpg,
      fromMixed: fromMixed,
      none: none,
      unknown: unknown,
      feedChannelIds: _lastXmltvFeedChannelIds,
      bySourceId: bySourceId,
    );
  }

  /// Channels the loaded feed guides match (1.2.20 (d), pre-bust):
  /// a channel matches when any of its candidate feed ids (tvg-id,
  /// stream key, name candidates — no Reload mappings yet) has
  /// programmes in a currently loaded feed window. Empty when no feed
  /// guide is cached. Scanned in guide order, stopping once
  /// [sampleSize] matches are found — the sample never needs more.
  List<LiveTvChannel> _matchedFeedChannels(
    List<LiveTvChannel> channels, {
    required int sampleSize,
  }) {
    if (_xmltvCache.isEmpty) return const [];
    final matched = <LiveTvChannel>[];
    for (final channel in channels) {
      var hit = false;
      for (final guide in _xmltvCache.values) {
        final candidates = _windowCandidateIds(guide, channel.key, const {});
        if (candidates.any((id) => (guide.windowByChannel[id]?.isNotEmpty ?? false))) {
          hit = true;
          break;
        }
      }
      if (hit) {
        matched.add(channel);
        if (matched.length >= sampleSize) break;
      }
    }
    return matched;
  }

  /// The live guide's real coverage (1.2.15 R6, F10; 1.2.20 (d)): how
  /// many sampled rows actually show programmes, split by the source
  /// that served them — short-EPG, the feed by id, the feed by name,
  /// mixed (1.2.20 (c)) — vs rows with a cached empty ([none]) and
  /// rows never fetched ([notFetched]). Which rows are sampled depends
  /// on [IptvGuideCoverageSample.scope]: the rows the guide actually
  /// built ([IptvGuideSampleScope.visible], from the fetch registry,
  /// most-recent first); when the registry is empty, the channels the
  /// loaded feed guides match ([IptvGuideSampleScope.matched],
  /// computed pre-bust from the cached guides — the Reload's own
  /// match results do not exist yet and the bust destroys the cache
  /// the sample reads); when no guide is cached pre-bust, the first
  /// [sampleSize] channels in guide order
  /// ([IptvGuideSampleScope.guideOrder], the 1.2.15 behaviour).
  /// Read-only sampling of already-fetched rows: each sampled channel
  /// reads its per-channel cache entry (in-memory, else its persisted
  /// file — one directory listing, not one stat per channel) and never
  /// fires a panel call. A persisted entry counts the same as a memory
  /// one; programmes from an older cache file (source unknown) count
  /// in withPrograms but in no split bucket.
  Future<IptvGuideCoverageSample> sampleGuideCoverage(
    List<LiveTvChannel> channels, {
    int sampleSize = 200,
  }) async {
    // 1.2.20 (d): sample the rows on screen first.
    final byKey = <String, LiveTvChannel>{for (final c in channels) c.key: c};
    final visible = <LiveTvChannel>[];
    for (final key in _recentGuideFetchKeys(sampleSize: sampleSize)) {
      final channel = byKey[key];
      if (channel != null) visible.add(channel);
    }
    final List<LiveTvChannel> sampledChannels;
    final IptvGuideSampleScope scope;
    if (visible.isNotEmpty) {
      sampledChannels = visible;
      scope = IptvGuideSampleScope.visible;
    } else {
      final matched = _matchedFeedChannels(channels, sampleSize: sampleSize);
      if (matched.isNotEmpty) {
        sampledChannels = matched;
        scope = IptvGuideSampleScope.matched;
      } else {
        sampledChannels = channels.take(sampleSize).toList(growable: false);
        scope = IptvGuideSampleScope.guideOrder;
      }
    }
    final persistedKeys = await _persistedEpgChannelKeys();
    var withPrograms = 0;
    var fromShortEpg = 0;
    var fromFeedById = 0;
    var fromFeedByName = 0;
    var fromMixed = 0;
    var none = 0;
    var notFetched = 0;
    for (final channel in sampledChannels) {
      final entry =
          _epgCache[channel.key] ??
          (persistedKeys.contains(channel.key) ? await _readPersistedEpg(channel.key) : null);
      if (entry == null) {
        notFetched++;
        continue;
      }
      if (entry.programs.isEmpty) {
        none++;
        continue;
      }
      withPrograms++;
      switch (entry.source) {
        case IptvEpgSource.feedById:
          fromFeedById++;
        case IptvEpgSource.feedByName:
          fromFeedByName++;
        case IptvEpgSource.shortEpg:
          fromShortEpg++;
        case IptvEpgSource.mixed:
          fromMixed++;
        case IptvEpgSource.none:
        case IptvEpgSource.unknown:
          // Programmes from an older cache file (source unknown) or a
          // `none` entry: counted in withPrograms, not in any split.
          break;
      }
    }
    return IptvGuideCoverageSample(
      sampled: sampledChannels.length,
      withPrograms: withPrograms,
      fromShortEpg: fromShortEpg,
      fromFeedById: fromFeedById,
      fromFeedByName: fromFeedByName,
      fromMixed: fromMixed,
      none: none,
      notFetched: notFetched,
      scope: scope,
    );
  }

  /// Per-connection EPG sources store (§3.1/§3.2): user-added sources,
  /// the precedence toggle, manual mappings, per-source status, and the
  /// channel-list fingerprint. SharedPreferences-backed, keyed by
  /// connection id.
  IptvEpgSourcesStore get _epgStore => IptvEpgSourcesStore(_client.connection.id);

  /// The connection's sources in stored order: the provider feed first
  /// (when one exists — Xtream always, M3U only with a declared EPG
  /// URL), then added sources in the order the user arranged them. The
  /// provider cannot be removed, disabled, or moved.
  Future<List<IptvEpgSourceConfig>> epgSources() async {
    final user = await _epgStore.loadUserSources();
    final provider = await _providerSourceAttempt();
    return [if (provider != null) _providerConfig(), ...user];
  }

  /// Add a third-party EPG source (§3.1): validate the URL first (fetch
  /// the first bytes and confirm it parses as XMLTV — user-initiated, so
  /// the SEARCH/STARTUP rules don't apply), then store it. Returns the
  /// stored config. Throws [StateError] with the reason when validation
  /// fails. The same URL may be added twice (different names — the
  /// reorder test does exactly that); each entry is its own source.
  /// Add a one-tap preset source (1.3.28): adding the same preset
  /// twice returns the existing source — a preset is added once, never
  /// duplicated. A preset is identified by its id (and, for sources
  /// added before presets existed, by URL).
  Future<IptvEpgSourceConfig> addEpgPreset(IptvEpgSourcePreset preset) async {
    final sources = await _epgStore.loadUserSources();
    final existing =
        sources.where((s) => s.presetId == preset.id || (s.presetId == null && s.url == preset.url)).toList();
    if (existing.isNotEmpty) return existing.first;
    return addEpgSource(preset.url, name: preset.name, presetId: preset.id);
  }

  /// Built-in-default preset (1.3.28): when the flag is on, the US
  /// preset is added once for this connection. Off by default — the
  /// decision (built-in default vs one-tap preset) is the owner's,
  /// not the code's. Returns the preset's config when added or already
  /// present, null when the flag is off. The [preset] parameter is a
  /// test seam: production callers leave it at the real preset.
  Future<IptvEpgSourceConfig?> ensurePresetDefault({
    IptvEpgSourcePreset preset = IptvEpgSourcePresets.usEpgshare01,
  }) async {
    final settings = await SettingsService.getInstance();
    if (!settings.read(SettingsService.iptvEpgUsPresetDefault)) return null;
    return addEpgPreset(preset);
  }

  Future<IptvEpgSourceConfig> addEpgSource(String url, {String? name, int? timeShiftMinutes, String? presetId}) async {
    final trimmed = url.trim();
    await validateEpgSourceUrl(trimmed);
    final uri = Uri.parse(trimmed);
    // A growable copy: the store returns an unmodifiable list.
    final sources = (await _epgStore.loadUserSources()).toList();
    final config = IptvEpgSourceConfig(
      id: IptvEpgSourceConfig.newUserId(),
      kind: IptvEpgSourceConfig.kindXmltv,
      url: trimmed,
      name: (name ?? '').trim().isEmpty ? uri.host : name!.trim(),
      timeShiftMinutes: timeShiftMinutes,
      presetId: presetId,
    );
    sources.add(config);
    await _epgStore.saveUserSources(sources);
    return config;
  }

  /// Change an added source (enable/disable, rename, time shift). The
  /// provider guide cannot be changed.
  Future<void> updateEpgSource(IptvEpgSourceConfig source) async {
    if (source.isProvider) throw ArgumentError('The provider guide cannot be changed');
    final sources = (await _epgStore.loadUserSources()).toList();
    final index = sources.indexWhere((s) => s.id == source.id);
    if (index < 0) throw ArgumentError('Unknown EPG source ${source.id}');
    sources[index] = source;
    await _epgStore.saveUserSources(sources);
  }

  /// Remove an added source. The provider guide cannot be removed. A
  /// removed source stays removed (IPTVnator rule), and its mappings go
  /// with it — a deleted source must not keep matching channels.
  Future<void> deleteEpgSource(String sourceId) async {
    if (sourceId == IptvEpgSourceConfig.providerId) {
      throw ArgumentError('The provider guide cannot be removed');
    }
    final sources = (await _epgStore.loadUserSources()).toList();
    sources.removeWhere((s) => s.id == sourceId);
    await _epgStore.saveUserSources(sources);
    final mappings = await _epgStore.loadMappings();
    mappings.removeWhere((_, mapping) => mapping.sourceId == sourceId);
    await _epgStore.saveMappings(mappings);
    final statuses = await _epgStore.loadStatuses();
    statuses.remove(sourceId);
    await _epgStore.saveStatuses(statuses);
  }

  /// Move an added source up ([delta] -1) or down (+1) in the priority
  /// order. No-op at the ends and for unknown ids. The provider feed
  /// never moves — the precedence toggle is what flips it below the
  /// added sources.
  Future<void> moveEpgSource(String sourceId, int delta) async {
    final sources = (await _epgStore.loadUserSources()).toList();
    final index = sources.indexWhere((s) => s.id == sourceId);
    if (index < 0) return;
    final target = (index + delta).clamp(0, sources.length - 1);
    if (target == index) return;
    final source = sources.removeAt(index);
    sources.insert(target, source);
    await _epgStore.saveUserSources(sources);
  }

  /// "Added sources take precedence over the provider guide" (IPTVnator
  /// toggle, §3.1). Default off — the provider feed first, added sources
  /// fill gaps (TiviMate Premium model).
  Future<bool> addedSourcesTakePrecedence() => _epgStore.loadAddedSourcesFirst();

  Future<void> setAddedSourcesTakePrecedence(bool value) => _epgStore.saveAddedSourcesFirst(value);

  /// Per-source status (§3.1): every known source has an entry (missing
  /// = never fetched). The UI reads the display state from each status
  /// with the update interval as the freshness bar.
  Future<Map<String, IptvEpgSourceStatus>> epgSourceStatuses() async {
    final stored = await _epgStore.loadStatuses();
    final sources = await epgSources();
    final out = <String, IptvEpgSourceStatus>{};
    for (final source in sources) {
      out[source.id] = stored[source.id] ?? IptvEpgSourceStatus.empty;
    }
    return out;
  }

  /// Validate an EPG source URL before adding it (§3.1): it must be an
  /// http(s) URL that answers 200 with bytes that parse as XMLTV. Only
  /// the first 256 KB are read — a multi-megabyte feed is never
  /// downloaded for validation. Throws [StateError] with the reason.
  Future<void> validateEpgSourceUrl(
    String url, {
    Duration tunnelReadyTimeout = const Duration(seconds: 5),
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) {
      throw StateError('Not a valid http(s) URL');
    }
    // 1.6.30 (P0.2/F1): while the tunnel toggle is on but the tunnel
    // is still starting, do NOT fetch — the URL is often the panel's
    // credentialled xmltv.php and a direct fetch can 403, which would
    // be reported as "invalid source". Inconclusive instead: fail
    // with a wait-and-retry message and record no verdict about the
    // source.
    if (!await WarpTunnelService.instance.waitForTunnelReady(timeout: tunnelReadyTimeout)) {
      throw StateError('The VPN tunnel is still starting. Please wait a moment and try again.');
    }
    // 1.6.28 (G5): the validation fetch rides the tunnel when it is
    // on — the URL is often the panel's xmltv.php with credentials.
    final client = WarpTunnelService.instance.proxiedHttpClient();
    try {
      final response = await client.send(http.Request('GET', uri)).timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('EPG source returned HTTP ${response.statusCode}');
      }
      const cap = 256 * 1024;
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(const Duration(seconds: 15))) {
        bytes.addAll(chunk);
        if (bytes.length >= cap) break;
      }
      _checkXmltvPrefix(bytes);
    } on StateError catch (e) {
      // 1.3.30: validation used to fail silently — the phone log had
      // no preset lines at all. Log the host (never the full URL — it
      // could carry credentials) so the next debug export shows it.
      appLogger.w('IPTV EPG source validation failed for ${uri.host}: $e');
      rethrow;
    } catch (e) {
      appLogger.w('IPTV EPG source validation failed for ${uri.host}: $e');
      throw StateError('Could not fetch the EPG source: $e');
    } finally {
      client.close();
    }
  }

  /// Confirm the first bytes of a would-be source look like XMLTV. The
  /// prefix is a TRUNCATED file by construction (the 256 KB cap cuts
  /// it anywhere), so the only question it can answer is shape: a
  /// `<tv>` root and a first `<channel>` (both sit in the first
  /// kilobytes of any real guide). A strict DOM parse of the whole
  /// prefix can only fail on the cut itself — the phone's US2 preset
  /// died on `XmlTagException: Missing closing tag </desc>`, which the
  /// old forgiveness catch never caught (a sibling of
  /// XmlParserException, and "Missing closing tag" contains neither
  /// forgiven phrase) — so the DOM parse is gone.
  /// 1.3.28: the validation prefix may be gzip — decompress what the
  /// cap caught before checking for `<tv`. Chunked conversion without
  /// requiring close: the 256 KB cap can cut a gzip member mid-stream,
  /// and close() throws on the missing footer; the bytes decoded so
  /// far are enough — `<tv>` and the first `<channel>` sit in the
  /// first kilobytes of XML.
  static List<int> _gunzipPrefixIfNeeded(List<int> bytes) {
    if (bytes.length < 2 || bytes[0] != 0x1f || bytes[1] != 0x8b) return bytes;
    final out = <int>[];
    final decoder = GZipCodec().decoder.startChunkedConversion(_CollectingByteSink(out));
    try {
      decoder.add(bytes);
      decoder.close();
    } catch (_) {
      // A truncated member still yields its decodable prefix above;
      // close() throws on the missing footer, which is expected.
    }
    return out;
  }

  /// The shape a truncated validation prefix must have to count as
  /// XMLTV (1.3.30): a `<tv>` root and a first `<channel>`. Both sit
  /// in the first kilobytes of any real guide, so they are readable
  /// in the prefix even when the 256 KB cap cuts the file mid-element.
  /// Visible for testing — the validator itself is only reachable
  /// through a live HTTP fetch.
  @visibleForTesting
  static bool xmltvPrefixLooksValid(List<int> bytes) {
    final text = utf8.decode(_gunzipPrefixIfNeeded(bytes), allowMalformed: true);
    return text.contains('<tv') && text.contains('<channel');
  }

  static void _checkXmltvPrefix(List<int> bytes) {
    // 1.3.30: the prefix is a TRUNCATED file by construction (the
    // 256 KB cap cuts it anywhere), so a strict DOM parse of the whole
    // prefix can only fail on the cut itself — the phone's US2 preset
    // died on `XmlTagException: Missing closing tag </desc>`, a
    // sibling of XmlParserException the old forgiveness catch never
    // caught. The only question the prefix can answer is whether the
    // bytes so far are XMLTV-shaped.
    if (!xmltvPrefixLooksValid(bytes)) {
      throw StateError('Not an XMLTV file (no <tv> element or no <channel> element)');
    }
  }

  /// Assign an EPG to a channel by hand (§3.2, TiviMate's Assign EPG):
  /// this channel always uses this XMLTV channel id from this source.
  /// The mapping is consulted before the byId/byName chain and survives
  /// refreshes and catalog syncs. Throws [ArgumentError] for an empty id
  /// or an unknown source.
  Future<void> assignEpg(String channelKey, {required String xmltvId, required String sourceId}) async {
    if (xmltvId.trim().isEmpty) throw ArgumentError('An XMLTV channel id is required');
    final sources = await epgSources();
    if (sources.every((s) => s.id != sourceId)) throw ArgumentError('Unknown EPG source $sourceId');
    await _epgStore.saveMapping(channelKey, IptvEpgMapping(xmltvId: xmltvId.trim(), sourceId: sourceId));
    // 1.2.22 §64.6: an assignment must take effect on the next fetch,
    // not when the cached entry happens to expire (up to 24 h later) —
    // drop the channel's cached entry so it re-matches through the new
    // mapping. The persisted file goes too; the refetch re-writes it.
    // 1.4.4: forced invalidation, not just the drop — the tombstone
    // stops a lagging persist from resurrecting the stale entry, and
    // the channel-scoped bump makes the open guide heal exactly this
    // row in place (no Reload, no reopen).
    appLogger.i('IPTV EPG $channelKey: assigned ${xmltvId.trim()} via manual');
    _invalidateEpgForChannel(channelKey, force: true);
  }

  /// Clear a manual assignment: the channel goes back to auto-matching.
  /// The cached entry is dropped for the same reason as [assignEpg] —
  /// otherwise the old assignment's programmes would keep serving
  /// until the entry expired.
  Future<void> clearEpgAssignment(String channelKey) async {
    await _epgStore.clearMapping(channelKey);
    // 1.4.4: same forced invalidation as [assignEpg] — the open guide
    // heals this row in place instead of keeping the old programmes
    // until a Reload or reopen.
    appLogger.i('IPTV EPG $channelKey: manual assignment cleared');
    _invalidateEpgForChannel(channelKey, force: true);
  }

  /// The manual assignment for [channelKey], if one exists.
  Future<IptvEpgMapping?> epgAssignmentFor(String channelKey) async {
    final mappings = await _epgStore.loadMappings();
    return mappings[channelKey];
  }

  /// Which source served [channelKey]'s cached programmes (1.2.8 F8):
  /// the guide row's source chip reads this. `unknown` when the
  /// channel was never fetched (or its entry predates source
  /// recording) — an unfetched channel is `unknown`, not "no source".
  IptvEpgSource epgSourceForChannel(String channelKey) =>
      _epgCache[channelKey]?.source ?? IptvEpgSource.unknown;

  /// One channel's EPG assignment state (§3.2, the "see my assigned EPG"
  /// view): which source serves it, which XMLTV id matched, how it
  /// matched, programmes in the requested window, when it was fetched
  /// and when it expires — or, when it has nothing, why. A cached entry
  /// with programmes answers from the cache; otherwise the loaded feeds
  /// are probed locally (no network) — the channel may have guide that
  /// simply hasn't been fetched yet.
  Future<IptvChannelEpgDetail> channelEpgDetail(String channelKey, {DateTime? from, DateTime? to}) async {
    final settings = await _readEpgSettings();
    // Default window: the settings window, like the guide itself — callers
    // that already have a window (tests) pass it explicitly.
    final now = DateTime.now();
    from ??= now.subtract(Duration(days: settings.pastDays));
    to ??= now.add(Duration(days: settings.daysToLoad));
    final ttl = settings.updateIntervalHours <= 0 ? null : Duration(hours: settings.updateIntervalHours);
    final cached = _epgCache[channelKey] ?? await _readPersistedEpg(channelKey);
    if (cached != null) _putEpgCache(channelKey, cached);
    if (cached != null && cached.programs.isNotEmpty) {
      final slice = _slice(cached.programs, from, to);
      return IptvChannelEpgDetail(
        channelKey: channelKey,
        channelName: _client.channelNameForChannelKey(channelKey),
        sourceId: cached.sourceId,
        sourceName: await _sourceName(cached.sourceId),
        matchedXmltvId: cached.matchedXmltvId,
        matchMethod: cached.matchMethod,
        // 1.2.8 F8: the cached entry knows which source served it.
        epgSource: cached.source,
        programCount: slice.length,
        lastFetch: cached.fetchedAt,
        nextFetch: ttl == null ? null : cached.fetchedAt.add(ttl),
      );
    }
    final probe = await _probeLocalMatch(channelKey, settings, from, to);
    if (probe.detail != null) return probe.detail!;
    // The probe's per-channel reason when a feed was loaded (1.2.5
    // Fix 7): an ambiguous or foreign name, or a feed id that brought
    // no programmes, says so — the global reason only covers "no
    // source / nothing loaded".
    final perChannelReason = switch (probe.resolution.blockedReason) {
      'ambiguous' => IptvEpgNoGuideReason.ambiguous,
      'foreign' => IptvEpgNoGuideReason.foreign,
      // 1.2.8 F2: the split codes map back to the single overview
      // reason — the split lives in the Reload tiers and dialog.
      'matched-but-no-programmes' ||
      'matched-but-no-programmes-declared' ||
      'matched-but-no-programmes-outside-window' => IptvEpgNoGuideReason.matchedButNoPrograms,
      'no-tvg-id' || 'tvg-id-not-in-feed' => IptvEpgNoGuideReason.noMatch,
      _ => null,
    };
    return IptvChannelEpgDetail(
      channelKey: channelKey,
      channelName: _client.channelNameForChannelKey(channelKey),
      programCount: 0,
      lastFetch: cached?.fetchedAt,
      noGuideReason: perChannelReason ?? await _noGuideReason(ttl),
    );
  }

  /// The local match probe for [channelEpgDetail]: the match chain
  /// against the feeds already loaded in memory (no network). The
  /// detail when a loaded feed serves the channel in the window, and
  /// the resolution either way — a non-match names its reason, so the
  /// detail can say why instead of only the global reason.
  Future<({IptvChannelEpgDetail? detail, _GuideResolution resolution})> _probeLocalMatch(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
  ) async {
    final attempts = await _epgSourceAttempts();
    final mappings = await _epgStore.loadMappings();
    final channelName = _client.channelNameForChannelKey(channelKey);
    final loaded = <({ _EpgSourceAttempt attempt, _CachedXmltvGuide guide })>[];
    for (final attempt in attempts) {
      final cachedGuide = _xmltvCache[attempt.cacheKey];
      if (cachedGuide == null) continue;
      // 1.2.12: the probe reads programmes, so the window must hold
      // this channel's candidates — slide it (a file re-parse, no
      // network) when it does not.
      final guide = await _ensureGuideWindow(attempt.cacheKey, attempt.fetchFeed, cachedGuide, channelKey, mappings);
      loaded.add((attempt: attempt, guide: guide));
    }
    final resolution = _resolveChannelAcrossFeeds(channelKey, loaded, mappings, settings, from, to, loadRows: true);
    if (resolution.matchedXmltvId == null) return (detail: null, resolution: resolution);
    final entry = loaded.firstWhere((e) => e.attempt.config.id == resolution.sourceId);
    return (
      detail: IptvChannelEpgDetail(
        channelKey: channelKey,
        channelName: channelName,
        sourceId: entry.attempt.config.id,
        sourceName: entry.attempt.config.name,
        matchedXmltvId: resolution.matchedXmltvId,
        matchMethod: resolution.matchMethod,
        // 1.2.8 F8: the probe matched through a feed — a name match
        // was served by the feed's name index, an id/manual match by
        // the feed id.
        epgSource: switch (resolution.matchMethod) {
          'name' || 'name-loose' => IptvEpgSource.feedByName,
          'tvg-id' || 'manual' => IptvEpgSource.feedById,
          _ => IptvEpgSource.unknown,
        },
        programCount: resolution.programs.length,
      ),
      resolution: resolution,
    );
  }

  /// The no-guide reason for a channel, derived from the feeds' state
  /// (shared by the details view and the without-guide overview): no
  /// enabled sources at all, nothing loaded (failed vs never tried), or
  /// feeds loaded but nothing matched.
  Future<IptvEpgNoGuideReason> _noGuideReason(Duration? ttl) async {
    final attempts = await _epgSourceAttempts();
    if (attempts.isEmpty) return IptvEpgNoGuideReason.noSource;
    final statuses = await _epgStore.loadStatuses();
    final loadedKeys = attempts
        .where((a) => _xmltvCache.containsKey(a.cacheKey))
        .map((a) => a.cacheKey)
        .toSet();
    return _reasonFor(attempts: attempts, loadedCacheKeys: loadedKeys, statuses: statuses, ttl: ttl);
  }

  IptvEpgNoGuideReason _reasonFor({
    required List<_EpgSourceAttempt> attempts,
    required Set<String> loadedCacheKeys,
    required Map<String, IptvEpgSourceStatus> statuses,
    required Duration? ttl,
  }) {
    if (attempts.isEmpty) return IptvEpgNoGuideReason.noSource;
    if (loadedCacheKeys.isEmpty) {
      final anyFailed = attempts.any((attempt) {
        final status = statuses[attempt.config.id];
        return status != null && status.state(enabled: attempt.config.enabled, ttl: ttl) == IptvEpgSourceState.failed;
      });
      return anyFailed ? IptvEpgNoGuideReason.sourceFailed : IptvEpgNoGuideReason.notLoaded;
    }
    return IptvEpgNoGuideReason.noMatch;
  }

  /// The display name for a source id (the translated provider name
  /// for the provider feed, the stored name for an added one, the id
  /// itself when the source is gone — a deleted source's stale
  /// references still read).
  Future<String?> _sourceName(String? sourceId) async {
    if (sourceId == null) return null;
    if (sourceId == IptvEpgSourceConfig.providerId) return t.iptv.epgProviderSource;
    final sources = await _epgStore.loadUserSources();
    for (final source in sources) {
      if (source.id == sourceId) return source.name;
    }
    return sourceId;
  }

  /// Every XMLTV channel id in every enabled source's feed, for the
  /// Assign EPG picker (§3.2). The feeds load lazily on first need
  /// (user-initiated — opening Assign), exactly like the guide's lazy
  /// feed; a source that defers (playback gate) or fails contributes
  /// nothing. Search over the result is local, in the picker.
  Future<List<IptvEpgFeedChannel>> epgFeedChannels({bool forceRefresh = false}) async {
    final settings = await _readEpgSettings();
    final ttl = settings.updateIntervalHours <= 0 ? null : Duration(hours: settings.updateIntervalHours);
    final attempts = await _epgSourceAttempts();
    final outcome = await _loadEnabledFeeds(attempts, ttl, force: forceRefresh);
    final out = <IptvEpgFeedChannel>[];
    for (final entry in outcome.loaded) {
      for (final channel in entry.guide.programCountByChannel.entries) {
        out.add(
          IptvEpgFeedChannel(
            sourceId: entry.attempt.config.id,
            sourceName: entry.attempt.config.name,
            xmltvId: channel.key,
            programCount: channel.value,
            displayNames: entry.guide.displayNames[channel.key] ?? const [],
          ),
        );
      }
    }
    out.sort((a, b) => a.xmltvId.toLowerCase().compareTo(b.xmltvId.toLowerCase()));
    return out;
  }

  /// The Assign EPG picker's candidate list, ranked by relevance to
  /// the channel being assigned (1.3.26 §69) instead of the
  /// alphabetical order [epgFeedChannels] returns. The picker's
  /// search box still filters, but the DEFAULT unfiltered list is
  /// relevance-ranked, and the filter preserves the ranked order.
  Future<List<IptvEpgFeedChannel>> rankedEpgFeedChannelsFor(String channelKey, String channelName) async {
    final entries = await epgFeedChannels();
    return rankEpgFeedChannels(
      entries: entries,
      channelName: channelName,
      channelEpgId: _client.epgChannelIdForChannelKey(channelKey),
      channelTvgId: _client.tvgIdForChannelKey(channelKey),
    );
  }

  /// Every channel with no EPG (§3.2, the "see my assigned EPGs per
  /// channel" overview), grouped by reason by the caller. A channel
  /// counts as having guide when its per-channel cache holds programmes
  /// or any loaded feed matches it — the feeds load lazily on first
  /// need (user-initiated — opening the overview). Channels whose guide
  /// comes only from the provider's per-channel lookup are not listed
  /// until browsed; the overview says so.
  Future<List<IptvChannelWithoutGuide>> channelsWithoutGuide() async {
    final settings = await _readEpgSettings();
    final ttl = settings.updateIntervalHours <= 0 ? null : Duration(hours: settings.updateIntervalHours);
    final channels = await _client.iptvChannels();
    final attempts = await _epgSourceAttempts();
    final outcome = await _loadEnabledFeeds(attempts, ttl);
    final loaded = outcome.loaded;
    final mappings = await _epgStore.loadMappings();
    final statuses = await _epgStore.loadStatuses();
    final reason = _reasonFor(
      attempts: attempts,
      loadedCacheKeys: loaded.map((e) => e.attempt.cacheKey).toSet(),
      statuses: statuses,
      ttl: ttl,
    );
    final now = DateTime.now();
    final from = now.subtract(Duration(days: settings.pastDays));
    final to = now.add(Duration(days: settings.daysToLoad));
    // Persisted per-channel entries, from one directory listing (not
    // one stat per channel — the catalog runs to tens of thousands).
    final persistedKeys = await _persistedEpgChannelKeys();
    final out = <IptvChannelWithoutGuide>[];
    for (final channel in channels) {
      final cached =
          _epgCache[channel.key] ??
          (persistedKeys.contains(channel.key) ? await _readPersistedEpg(channel.key) : null);
      if (cached != null) _putEpgCache(channel.key, cached);
      if (cached != null && cached.programs.isNotEmpty) continue;
      final resolution = _resolveChannelAcrossFeeds(channel.key, loaded, mappings, settings, from, to, loadRows: false);
      if (resolution.matchedXmltvId != null) continue;
      // Per-channel reason from the provider (first loaded) feed's
      // block (1.2.5 Fix 7): an ambiguous or foreign name, or a feed
      // id that brought no programmes, says so — the global reason
      // only covers "no source / nothing loaded".
      final (perChannelReason, candidates) = switch (resolution.blockedReason) {
        'ambiguous' => (IptvEpgNoGuideReason.ambiguous, resolution.blockedCandidates),
        'foreign' => (IptvEpgNoGuideReason.foreign, resolution.blockedCandidates),
        // 1.2.8 F2: the split codes map back to the single overview
        // reason — the split lives in the Reload tiers and dialog.
        'matched-but-no-programmes' ||
        'matched-but-no-programmes-declared' ||
        'matched-but-no-programmes-outside-window' => (
          IptvEpgNoGuideReason.matchedButNoPrograms,
          resolution.blockedCandidates,
        ),
        'no-tvg-id' || 'tvg-id-not-in-feed' => (IptvEpgNoGuideReason.noMatch, const <String>[]),
        _ => (reason, const <String>[]),
      };
      out.add(
        IptvChannelWithoutGuide(
          channelKey: channel.key,
          channelName: channel.title ?? channel.key,
          reason: perChannelReason,
          candidates: candidates,
        ),
      );
    }
    return out;
  }

  /// True when any loaded feed serves [channelKey] in the window (by
  /// assignment, tvg-id, or name). Local only — no network.
  bool _channelHasFeedMatch(
    String channelKey,
    List<({ _EpgSourceAttempt attempt, _CachedXmltvGuide guide })> loaded,
    Map<String, IptvEpgMapping> mappings,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
  ) {
    return _resolveChannelAcrossFeeds(channelKey, loaded, mappings, settings, from, to, loadRows: false).matchedXmltvId != null;
  }

  /// One-time M3U `tvg-id` diagnostic (1.2.15 R2, diagnostic only):
  /// fetch the provider's `get.php` playlist ONCE (same credentials
  /// the app already holds), build a stream-id → `tvg-id` map, and
  /// report how many channels with no `epg_channel_id` gain a `tvg-id`
  /// from it — and how many of those ids are declared in the loaded
  /// feeds. It never runs automatically (the playlist is tens of MB).
  /// The result also carries the gained pairs ([IptvM3uTvgIdDiagnostic.gainedIds])
  /// so the dialog's Apply can write them as manual mappings (1.3.26
  /// §69) — the check is a repair now, not just a report. A failed
  /// playlist fetch returns an error result instead of throwing, so
  /// the Xtream-only path never breaks. The feeds load when they are
  /// not loaded — the user tapped the check, so the load is the point,
  /// not a surprise.
  /// 1.2.22 §63.4, repurposed 1.3.27 §P0-1: the SILENCE budget for one
  /// M3U tvg-id check attempt (download) and for the parse. A slice
  /// elapsing with no progress is a stall — the attempt aborts and
  /// retries from the resume point. A download that keeps delivering
  /// runs to completion however long it takes: the 1.3.26 total cap
  /// (150 s for download + parse) killed slow-but-delivering downloads
  /// on the phone. The download has its own 120 s per-gap timeout and
  /// the parse has this bound — without a bound, a stalled playlist
  /// hangs the check forever (the 1.2.19 log's "Future not completed").
  /// Tests lower it; production leaves it at 150 s.
  @visibleForTesting
  static Duration m3uTvgIdDiagnosticTimeout = const Duration(seconds: 150);

  /// 1.3.27 §P0-1: stall retries per check — the initial attempt plus
  /// three retries, then the check reports the stall with the bytes
  /// received instead of timing out silently.
  static const int m3uTvgIdCheckMaxAttempts = 4;

  /// Live byte progress of the in-flight M3U tvg-id check, or null when
  /// no check is running (1.3.27 §P0-1 — the Check row polls this, the
  /// way the Reload row polls feedDownloadProgress).
  ({int received, int? totalBytes, int resumedFromBytes})? get m3uTvgIdCheckProgress => _m3uTvgIdCheckProgress;
  ({int received, int? totalBytes, int resumedFromBytes})? _m3uTvgIdCheckProgress;

  /// Human-readable byte count for a check line (same shape as the
  /// settings screen's feed progress line).
  static String _humanBytes(int bytes) {
    if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes bytes';
  }

/// Stable resume path for the M3U playlist (1.3.27 §P0-1 — port of
/// the feed download's `.resume` claim/restore): the partial playlist
/// lives here between checks, next to the persisted feed file. The
/// `.resume` suffix keeps [_pruneStaleXmltvTempFiles] (which prunes
/// only `*.tmp`) from ever deleting it. The name is stable across
/// runs. Sync file I/O once the directory is resolved — the check
/// runs under widget tests, where real async disk I/O never completes
/// inside fake async. NOT gated on [debugDisablePersistedEpg]: the
/// resume point is a download artifact, not a cached guide entry, and
/// the harness needs it.
Future<File> _m3uResumeFile() async {
  final dir = await _epgCacheDir();
  return File('${dir.path}/playlist.m3u.resume');
}

/// A unique temp file for one check attempt, next to the stable
/// resume path (mirrors [_xmltvTempFeedFile]). The directory is
/// created first — the base code relied on createTempSync creating
/// it, and the download's openWrite fails on a missing folder.
Future<File> _m3uTempFile() async {
  final dir = await _epgCacheDir();
  dir.createSync(recursive: true);
  final unique = '${DateTime.now().microsecondsSinceEpoch}_${_xmltvTempFeedSequence++}';
  return File('${dir.path}/playlist_$unique.tmp');
}

/// Claim a previous partial playlist download for the next check:
/// rename the stable `.resume` file to a unique temp file (1.2.17 R4
/// — concurrent loads must never share one file) and return it, or
/// null when there is no partial worth resuming (missing or empty).
/// The claim is exclusive — once renamed, no other check can claim
/// the same partial.
Future<File?> _claimM3uResumeFile() async {
  try {
    final resumeFile = await _m3uResumeFile();
    if (!resumeFile.existsSync() || resumeFile.lengthSync() == 0) return null;
    final claimed = await _m3uTempFile();
    return resumeFile.renameSync(claimed.path);
  } catch (_) {
    return null;
  }
}

/// Move a (partial) playlist file to the stable resume path, keeping
/// the LONGER of the two when a resume file already exists. A
/// zero-byte file is never kept as the resume point — it is deleted.
/// The directory is created first — a concurrent clear can delete it
/// between the claim and this restore, and the rename would fail on
/// the missing folder.
Future<void> _restoreM3uResumeFile(File file) async {
  try {
    final resumeFile = await _m3uResumeFile();
    if (!file.existsSync()) return;
    if (file.lengthSync() == 0) {
      file.deleteSync();
      return;
    }
    resumeFile.parent.createSync(recursive: true);
    if (resumeFile.existsSync()) {
      if (resumeFile.lengthSync() >= file.lengthSync()) {
        file.deleteSync();
        return;
      }
      resumeFile.deleteSync();
    }
    file.renameSync(resumeFile.path);
  } catch (_) {
    // Best-effort: a lost resume point just means a fresh download.
  }
}

/// Delete the stable resume file (a successful check leaves no
/// partial behind).
Future<void> _deleteM3uResumeFile() async {
  try {
    final resumeFile = await _m3uResumeFile();
    if (resumeFile.existsSync()) resumeFile.deleteSync();
  } catch (_) {
    // Best-effort.
  }
}

/// Download the M3U playlist to [tempPath] and collect its live
/// tvg-ids in an isolate (1.3.26 §69, 1.3.27 §P0-1): the download is
/// exempt from the hostile-response cap ([XtreamApi.getM3uToFile] with
/// `ignoreCatalogCap` — the playlist streams to a file and the
/// parser reads it line by line, so the cap guards nothing) and the
/// parse is the streaming collector, so the 300 MB playlist is
/// never held as a String or a 300k-entry list. The download runs
/// with `resume: true` against the stable partial at [tempPath] and
/// is bounded by a SILENCE watchdog, not a total cap — a slice of
/// [m3uTvgIdDiagnosticTimeout] with no progress is a stall, while a
/// delivering download runs to completion however long it takes. The
/// parse keeps its own [m3uTvgIdDiagnosticTimeout] bound. A stall
/// throws [_M3uCheckFailure] (budget 'stall'); a parse timeout throws
/// it with budget 'parse'; a transport error surfaces as-is for the
/// caller to classify. [onProgress] reports (received, total,
/// resumedFrom) for the live progress getter.
Future<Map<int, String>> _fetchAndParseM3uPlaylist(
  String tempPath,
  Set<String> hiddenGroupTitles, {
  required void Function(int receivedBytes, int? totalBytes, int resumedFromBytes) onProgress,
}) async {
  // 1.3.27 §P0-1: the attempt resumes from the stable partial's length.
  var resumedFromBytes = 0;
  try {
    resumedFromBytes = File(tempPath).lengthSync();
  } catch (_) {
    resumedFromBytes = 0;
  }
  var bytesReceived = resumedFromBytes;
  // 1.3.26 §69: completing this aborts the in-flight download at
  // the socket when the stage times out.
  final abort = Completer<void>();
  // The race: the download's completion, or the silence watchdog.
  final done = Completer<void>();
  Timer? watchdog;
  void rearmWatchdog() {
    watchdog?.cancel();
    watchdog = Timer(m3uTvgIdDiagnosticTimeout, () {
      // A whole silence budget with no progress: the download stalled.
      if (!abort.isCompleted) abort.complete();
      if (!done.isCompleted) {
        final receivedThisAttempt = bytesReceived - resumedFromBytes;
        done.completeError(
          _M3uCheckFailure(
            reason: t.iptv.epgM3uTvgIdStalled(
              received: _humanBytes(receivedThisAttempt < 0 ? 0 : receivedThisAttempt),
              kept: _humanBytes(bytesReceived),
            ),
            bytesReceived: bytesReceived,
            resumeOffset: resumedFromBytes,
            budget: 'stall',
          ),
        );
      }
    });
  }

  final downloadFuture = () async {
    await _client.xtreamApi.getM3uToFile(
      filePath: tempPath,
      ignoreCatalogCap: true,
      abortTrigger: abort.future,
      resume: true,
      onProgress: (received, total) {
        bytesReceived = received;
        onProgress(received, total, resumedFromBytes);
        rearmWatchdog();
      },
    );
  }();
  // The download's own error ends the race; a late error after the
  // race ended is swallowed: the diagnostic already moved on, and
  // nobody awaits this future then.
  unawaited(
    downloadFuture.then<void>(
      (_) {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
    ),
  );
  rearmWatchdog();
  try {
    await done.future;
  } finally {
    watchdog?.cancel();
  }
  // The download landed — parse it, bounded by its own timeout (the
  // parse of a 300 MB playlist is the slow part after the download).
  return compute(
    collectM3uLiveTvgIds,
    (path: tempPath, hiddenGroupTitles: hiddenGroupTitles),
  ).timeout(
    m3uTvgIdDiagnosticTimeout,
    onTimeout: () => throw _M3uCheckFailure(
      reason: t.iptv.epgM3uTvgIdParseTimedOut,
      bytesReceived: bytesReceived,
      resumeOffset: resumedFromBytes,
      budget: 'parse',
    ),
  );
}

  Future<IptvM3uTvgIdDiagnostic> diagnoseM3uTvgIds() async {
    if (!_isXtream) {
      return const IptvM3uTvgIdDiagnostic(
        checked: 0,
        noId: 0,
        gained: 0,
        gainedInFeed: 0,
        feedLoaded: false,
        error: 'Not an Xtream connection',
        samples: [],
      );
    }
    // 1.3.26 §69: the channel loop already skips hidden categories
    // ([iptvChannels] drops them), so the counts never include them —
    // but the parse used to build all ~300k entries anyway. The
    // streaming parser drops live entries whose group-title is a
    // hidden category before they reach the map, so the map holds
    // visible rows only. Resolved from the live category table, the
    // same inputs [_isHiddenCategory] uses — the playlist carries
    // group titles (names), not category ids. Best-effort: a failed
    // category load falls back to no drop rather than failing the
    // whole check.
    final hiddenGroupTitles = <String>{};
    try {
      for (final category in await _client.liveCategories()) {
        if (_client.isCategoryHidden(category.id, category.name)) {
          hiddenGroupTitles.add(category.name);
        }
      }
    } catch (e) {
      appLogger.w('IPTV M3U tvg-id check: live categories unavailable, hidden categories will not be skipped in the parse', error: e);
    }
    // Stream id -> tvg-id, live entries only: the collector drops
    // movies and series, entries with no tvg-id, and hidden
    // group-titles, so the map is already the live-only map the old
    // whole-file loop used to build.
    // 1.3.27 §P0-1: the playlist streams to ONE stable path (port of
    // the feed download's .resume claim/restore, see
    // [_claimXmltvResumeFile]): a stalled attempt keeps its partial,
    // and the next attempt resumes from it instead of restarting from
    // byte 0. Sync file I/O is deliberate (see [_loadXmltvGuide]):
    // real async disk I/O never completes inside testWidgets fake
    // async. The stable file is deleted on success; on final failure
    // it is restored so the next check resumes from the bytes kept.
    Map<int, String>? tvgIdsByStreamId;
    String? failureReason;
    var failureBytes = 0;
    var failureBudget = '';
    var failureResumeOffset = 0;
    var failureType = '';
    _m3uTvgIdCheckProgress = null;
    File? target;
    try {
      target = await _claimM3uResumeFile() ?? await _m3uTempFile();
      for (var attempt = 1; attempt <= m3uTvgIdCheckMaxAttempts; attempt++) {
        var firstReportReceived = -1;
        var restartLogged = false;
        var resumedLogged = false;
        try {
          tvgIdsByStreamId = await _fetchAndParseM3uPlaylist(
            target.path,
            hiddenGroupTitles,
            onProgress: (received, total, resumedFrom) {
              _m3uTvgIdCheckProgress = (received: received, totalBytes: total, resumedFromBytes: resumedFrom);
              // C2: the first report of an attempt says whether the
              // server honoured Range — a count that restarts below
              // the partial it resumed from means the server ignored
              // it and the download restarted from byte 0.
              if (firstReportReceived < 0) {
                firstReportReceived = received;
                if (resumedFrom > 0 && received < resumedFrom && !restartLogged) {
                  restartLogged = true;
                  appLogger.i(
                    'IPTV M3U tvg-id check: playlist download restarted from byte 0 — the server ignored the resume point (${_humanBytes(resumedFrom)} discarded)',
                  );
                } else if (resumedFrom > 0 && received > resumedFrom && !resumedLogged) {
                  resumedLogged = true;
                  appLogger.i('IPTV M3U tvg-id check: playlist download resumed from ${_humanBytes(resumedFrom)}');
                }
              }
            },
          );
          break;
        } on _M3uCheckFailure catch (f) {
          // A stall (silence) retries from the resume point while
          // attempts remain. A parse timeout does not: the download
          // already landed, so report it.
          if (f.budget == 'parse' || attempt >= m3uTvgIdCheckMaxAttempts) {
            failureReason = f.reason;
            failureBytes = f.bytesReceived;
            failureBudget = f.budget;
            failureResumeOffset = f.resumeOffset;
            failureType = f.runtimeType.toString();
            break;
          }
          appLogger.i(
            'IPTV M3U tvg-id check: playlist download stalled (${_humanBytes(f.bytesReceived)} received) — retrying from the resume point (attempt $attempt of $m3uTvgIdCheckMaxAttempts)',
          );
        } on MediaServerHttpException catch (e) {
          // Transient transport errors retry; a refusal (401/403), a
          // cap error, or a cancellation reports immediately. Zero
          // bytes received means the playlist could not be reached at
          // all — that is the connect reason, not a stall. A timeout
          // after bytes arrived IS a stall: the download was delivering
          // and then went silent, so the check names the stall and how
          // much arrived instead of the bare "the connection timed
          // out" that erases which budget fired.
          final received = _m3uTvgIdCheckProgress?.received ?? 0;
          final resumedFrom = _m3uTvgIdCheckProgress?.resumedFromBytes ?? 0;
          if (!e.isTransient || e.isCancellation || attempt >= m3uTvgIdCheckMaxAttempts) {
            final isTimeout =
                e.type == MediaServerHttpErrorType.connectionTimeout || e.type == MediaServerHttpErrorType.receiveTimeout;
            if (received == 0 && resumedFrom == 0) {
              failureReason = t.iptv.epgM3uTvgIdUnreachable;
              failureBudget = 'transport';
            } else if (isTimeout) {
              final receivedThisAttempt = received - resumedFrom;
              failureReason = t.iptv.epgM3uTvgIdStalled(
                received: _humanBytes(receivedThisAttempt < 0 ? 0 : receivedThisAttempt),
                kept: _humanBytes(received),
              );
              failureBudget = 'stall';
            } else {
              failureReason = epgFeedErrorReason(e);
              failureBudget = 'transport';
            }
            failureBytes = received;
            failureResumeOffset = resumedFrom;
            failureType = e.runtimeType.toString();
            break;
          }
          appLogger.i(
            'IPTV M3U tvg-id check: playlist download failed transiently (${e.type.name}, ${_humanBytes(received)} received) — retrying from the resume point (attempt $attempt of $m3uTvgIdCheckMaxAttempts)',
          );
        } on TimeoutException {
          // A raw timeout with no progress is a stall; it retries from
          // the resume point while attempts remain.
          final received = _m3uTvgIdCheckProgress?.received ?? 0;
          final resumedFrom = _m3uTvgIdCheckProgress?.resumedFromBytes ?? 0;
          final receivedThisAttempt = received - resumedFrom;
          if (attempt >= m3uTvgIdCheckMaxAttempts) {
            failureReason = t.iptv.epgM3uTvgIdStalled(
              received: _humanBytes(receivedThisAttempt < 0 ? 0 : receivedThisAttempt),
              kept: _humanBytes(received),
            );
            failureBytes = received;
            failureBudget = 'stall';
            failureResumeOffset = resumedFrom;
            failureType = 'TimeoutException';
            break;
          }
          appLogger.i(
            'IPTV M3U tvg-id check: playlist download timed out (${_humanBytes(received)} received) — retrying from the resume point (attempt $attempt of $m3uTvgIdCheckMaxAttempts)',
          );
        }
      }
    } catch (e) {
      // Unexpected (the claim/temp-file helpers failing, a compute
      // isolate error): report it as-is instead of collapsing it.
      failureReason = epgFeedErrorReason(e);
      failureBytes = _m3uTvgIdCheckProgress?.received ?? 0;
      failureBudget = 'unexpected';
      failureResumeOffset = _m3uTvgIdCheckProgress?.resumedFromBytes ?? 0;
      failureType = e.runtimeType.toString();
    } finally {
      _m3uTvgIdCheckProgress = null;
    }
    if (tvgIdsByStreamId == null) {
      // 1.3.27 §P0-1: restore the partial so the next check resumes
      // from the bytes kept instead of starting over.
      if (target != null) await _restoreM3uResumeFile(target);
      final result = IptvM3uTvgIdDiagnostic(
        checked: 0,
        noId: 0,
        gained: 0,
        gainedInFeed: 0,
        feedLoaded: false,
        error: failureReason ?? t.iptv.epgM3uTvgIdUnreachable,
        samples: const [],
      );
      appLogger.i(
        'IPTV M3U tvg-id check: playlist fetch failed ($failureType: ${result.error}) — $failureBytes bytes received, budget $failureBudget, resumed from ${_humanBytes(failureResumeOffset)}',
      );
      return result;
    }
    // Success: the parse landed, so the temp and stable files go.
    try {
      target?.deleteSync();
    } catch (_) {
      // Best-effort; the next claim overwrites the stale file.
    }
    await _deleteM3uResumeFile();
    final channels = await _client.iptvChannels();
    final settings = await _readEpgSettings();
    final ttl = settings.updateIntervalHours <= 0 ? null : Duration(hours: settings.updateIntervalHours);
    final attempts = await _epgSourceAttempts();
    final outcome = await _loadEnabledFeeds(attempts, ttl);
    final feedIds = <String>{};
    for (final loaded in outcome.loaded) {
      feedIds.addAll(loaded.guide.channelIdsSeen);
    }
    var noId = 0;
    var gained = 0;
    var gainedInFeed = 0;
    // 1.3.26 §69: the gained pairs (channelKey -> tvgId) the dialog's
    // Apply writes as manual mappings.
    final gainedIds = <String, String>{};
    final samples = <({String channelName, int streamId, String tvgId, bool inFeed})>[];
    for (final channel in channels) {
      final epgChannelId = _client.epgChannelIdForChannelKey(channel.key);
      if (epgChannelId != null && epgChannelId.isNotEmpty) continue;
      noId++;
      final streamId = int.tryParse(channel.key);
      if (streamId == null) continue;
      final tvgId = tvgIdsByStreamId[streamId];
      if (tvgId == null) continue;
      gained++;
      gainedIds[channel.key] = tvgId;
      final inFeed = feedIds.contains(tvgId);
      if (inFeed) gainedInFeed++;
      if (samples.length < 5) {
        samples.add((
          channelName: channel.title ?? channel.key,
          streamId: streamId,
          tvgId: tvgId,
          inFeed: inFeed,
        ));
      }
    }
    final result = IptvM3uTvgIdDiagnostic(
      checked: channels.length,
      noId: noId,
      gained: gained,
      gainedInFeed: gainedInFeed,
      feedLoaded: outcome.loaded.isNotEmpty,
      error: null,
      samples: samples,
      gainedIds: gainedIds,
    );
    appLogger.i(
      'IPTV M3U tvg-id check: ${result.checked} channels, ${result.noId} without a guide ID, '
      '${result.gained} gain one from the playlist, ${result.gainedInFeed} of those in the guide'
      '${result.feedLoaded ? '' : ' (guide not loaded)'}',
    );
    return result;
  }

  /// Apply the gained guide IDs from a completed M3U tvg-id check
  /// (1.3.26 §69, 1.3.27 §P0-2/§P0-4): every pair WITHOUT an existing
  /// mapping becomes a manual mapping (provider source, tier 1 — the
  /// matcher consults it before the byId/byName chain), written in
  /// one bulk store save. A channel that already has a mapping keeps
  /// it — the playlist must never overwrite a hand assignment (the
  /// 1.3.26 wart: Apply wrote every pair unconditionally) — and the
  /// skipped count is reported so the dialog can say so. Returns the
  /// applied and skipped counts. Every applied key whose cached entry
  /// is empty or absent is invalidated (see
  /// [_invalidateEpgForChannel]), so a row that already completed
  /// empty heals inside the same guide open instead of waiting for
  /// the next one. The caller triggers a Reload after applying — the
  /// mappings take effect when the rows re-resolve, not on write.
  Future<({int applied, int skippedHandAssigned})> applyM3uTvgIds(Map<String, String> gainedIds) async {
    if (gainedIds.isEmpty) return (applied: 0, skippedHandAssigned: 0);
    final mappings = await _epgStore.loadMappings();
    var applied = 0;
    var skipped = 0;
    final healedKeys = <String>[];
    for (final entry in gainedIds.entries) {
      final tvgId = entry.value.trim();
      if (tvgId.isEmpty) continue;
      if (mappings.containsKey(entry.key)) {
        // 1.3.27 §P0-2: a mapping already exists — hand-assigned via
        // Assign, or applied by an earlier check — and the playlist
        // does not get to overwrite it.
        skipped++;
        continue;
      }
      mappings[entry.key] = IptvEpgMapping(xmltvId: tvgId, sourceId: IptvEpgSourceConfig.providerId);
      applied++;
      healedKeys.add(entry.key);
    }
    if (applied > 0) await _epgStore.saveMappings(mappings);
    appLogger.i('IPTV M3U tvg-id check: applied $applied guide IDs from the playlist ($skipped kept their existing guide ID)');
    // 1.3.27 §P0-4: invalidate the empty/absent cached entries for
    // the applied keys, so their rows can refill in this guide open.
    for (final key in healedKeys) {
      _invalidateEpgForChannel(key);
    }
    return (applied: applied, skippedHandAssigned: skipped);
  }

  /// Invalidate one channel's cached EPG so its row refetches (1.3.27
  /// §P0-4): only an empty or absent entry is dropped — a row already
  /// showing programmes keeps serving. The in-memory drop, the
  /// tombstone, and the bump happen synchronously together; the
  /// persisted delete is fire-and-forget, and the tombstone stops a
  /// stale persisted read from resurrecting the entry before the
  /// delete lands. The channel-scoped bump makes the guide tab heal
  /// the row (drop its loaded-empty marks and re-fetch). With
  /// [force] (1.4.4, Assign/Clear) the entry is dropped even when it
  /// holds programmes — an assignment's whole point is replacing the
  /// programmes a loaded row is showing.
  void _invalidateEpgForChannel(String channelKey, {bool force = false}) {
    final cached = _epgCache[channelKey];
    if (!force && cached != null && cached.programs.isNotEmpty) return;
    _epgCache.remove(channelKey);
    _epgInvalidatedKeys.add(channelKey);
    unawaited(_deletePersistedEpgFile(channelKey));
    _bumpEpgVersion(channelKey: channelKey);
  }

  /// Delete one channel's persisted EPG file (per-channel, unlike
  /// [_deletePersistedEpg], which deletes the whole directory).
  Future<void> _deletePersistedEpgFile(String channelKey) async {
    try {
      final file = await _epgCacheFile(channelKey);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // Best-effort: the in-memory entry and the tombstone are gone,
      // so the next fetch re-matches; a stale persisted file is only
      // re-read when the in-memory entry is missing.
    }
  }

  /// Resolve one channel against the loaded feeds in priority order
  /// (1.2.5): the first feed that serves it wins; otherwise the first
  /// feed's block reason (the provider feed is first) is what the
  /// diagnostics name. The resolution always carries a reason when it
  /// carries no match — never null.
  _GuideResolution _resolveChannelAcrossFeeds(
    String channelKey,
    List<({ _EpgSourceAttempt attempt, _CachedXmltvGuide guide })> loaded,
    Map<String, IptvEpgMapping> mappings,
    _EpgSettings settings,
    DateTime from,
    DateTime to, {
    bool loadRows = true,
  }) {
    final mapping = mappings[channelKey];
    final epgChannelId = _client.epgChannelIdForChannelKey(channelKey);
    final tvgId = _client.tvgIdForChannelKey(channelKey);
    final channelName = _client.channelNameForChannelKey(channelKey);
    _GuideResolution? firstBlocked;
    for (final entry in loaded) {
      final resolution = _matchInGuide(
        entry.guide,
        channelKey,
        mapping,
        entry.attempt.config.id,
        epgChannelId,
        tvgId,
        channelName,
        settings,
        from,
        to,
        keyPrefix: entry.attempt.keyPrefix,
        offsetMinutes: entry.attempt.config.timeShiftMinutes,
        loadRows: loadRows,
      );
      if (resolution.matchedXmltvId != null) return resolution;
      firstBlocked ??= resolution;
    }
    return firstBlocked ??
        (
          programs: const <LiveTvProgram>[],
          matchedXmltvId: null,
          matchMethod: null,
          sourceId: null,
          blockedReason: 'no-feed',
          blockedCandidates: const <String>[],
        );
  }

  /// The enabled sources' guides, loaded lazily (user-initiated callers
  /// only — Assign, Channels without guide, Reload TV details). A source
  /// that defers (playback gate) or fails contributes nothing to
  /// [loaded]; a fresh load records the source's status, a failure
  /// records its reason. 1.2.3: the failures and deferrals are returned
  /// too, so Reload / Update now can name the feed outcome in their
  /// report instead of silently dropping a failed source.
  ///
  /// What loading the enabled feeds produced: what loaded, what failed
  /// (with its error), and what deferred (playback gate).
  Future<_LoadedEpgFeeds> _loadEnabledFeeds(
    List<_EpgSourceAttempt> attempts,
    Duration? ttl, {
    bool force = false,
  }) async {
    final loaded = <({ _EpgSourceAttempt attempt, _CachedXmltvGuide guide })>[];
    final failures = <({ _EpgSourceAttempt attempt, Object error })>[];
    final deferred = <_EpgSourceAttempt>[];
    for (final attempt in attempts) {
      try {
        final started = DateTime.now();
        final (guide, loadedFresh) = await _loadSourceGuide(attempt.cacheKey, attempt.fetchFeed, ttl, force: force, attempt: attempt);
        if (loadedFresh) {
          await _recordSourceSuccess(attempt, guide, started);
        }
        loaded.add((attempt: attempt, guide: guide));
      } on _EpgFeedDeferred {
        deferred.add(attempt);
        continue;
      } catch (e) {
        // A cancellation aborts the whole bulk load (the app
        // backgrounded); a failed source is recorded and skipped.
        if (MediaServerHttpException.from(e).isCancellation) rethrow;
        await _recordSourceFailure(attempt.config, e);
        failures.add((attempt: attempt, error: e));
        continue;
      }
    }
    return (loaded: loaded, failures: failures, deferred: deferred);
  }

  /// Channel keys with a persisted per-channel EPG file, from one
  /// directory listing. Best-effort — a failure reads as "none
  /// persisted", and the overview still works from memory + feeds.
  /// Skipped entirely when the persisted side is disabled for tests.
  Future<Set<String>> _persistedEpgChannelKeys() async {
    final out = <String>{};
    if (debugDisablePersistedEpg) return out;
    try {
      final dir = await _epgCacheDir();
      if (!await dir.exists()) return out;
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        final key = _channelKeyFromFileName(entity.path.split('/').last);
        if (key != null) out.add(key);
      }
    } catch (_) {
      // Best-effort: the overview still works from memory + feeds.
    }
    return out;
  }

  /// Reload TV details (§3.2, the owner's original wording): re-fetch the
  /// channel list from the provider (not a full catalog sync — movies
  /// and series are untouched) and refresh the EPG for this connection,
  /// then report counts. The recovery action for D1-poisoned entries:
  /// it busts the per-channel cache the way Update now does.
  ///
  /// 1.2.3 RC1: the cache bust runs FIRST, before the list re-fetch, so
  /// poison clears even when the list fails — and the list failure is
  /// CAUGHT and carried on the result, never thrown: the tap must
  /// ALWAYS end in a report naming the failure ("panel denied access
  /// (HTTP 403), 0 channels loaded"), never in silence. The feeds are
  /// still tried after a list failure, and every feed's outcome is on
  /// the result, so the dialog can tell "the feed failed" apart from
  /// "the feed loaded but matched nothing".
  Future<IptvReloadTvDetailsResult> reloadTvDetails() async {
    // 1.2.15 R6: sample the guide rows as they stand BEFORE the bust
    // below clears the per-channel cache — the sample is read-only
    // (already-fetched rows only, no panel calls) and counts what the
    // guide actually showed before this Reload.
    final guideCoverageSample = await sampleGuideCoverage(await _client.iptvChannels());
    // Bust first: on a 403 the old order threw before this line.
    await refreshEpgCache();
    List<LiveTvChannel> channels;
    Object? channelListError;
    try {
      channels = await _client.refreshLiveChannelsFromNetwork();
    } catch (e) {
      channelListError = e;
      channels = const <LiveTvChannel>[];
    }
    final settings = await _readEpgSettings();
    final ttl = settings.updateIntervalHours <= 0 ? null : Duration(hours: settings.updateIntervalHours);
    final attempts = await _epgSourceAttempts();
    // An explicit user retry bypasses the 5-minute negative cache (D8):
    // Reload actually re-tries a feed that failed minutes ago instead
    // of reporting the remembered failure without downloading.
    // D9: loading the feeds is an attempt — stamp it, so "Last attempt"
    // certifies the activity even when the list or the feed then fails.
    _noteEpgAttempt(DateTime.now());
    // 1.4.4 F6: the Reload's start — download facts recorded before it
    // belong to an earlier download (the seed, or a previous Reload)
    // and must not be reported as this Reload's download.
    final reloadStarted = DateTime.now();
    final outcome = await _loadEnabledFeeds(attempts, ttl, force: true);
    final mappings = await _epgStore.loadMappings();
    final now = DateTime.now();
    final from = now.subtract(Duration(days: settings.pastDays));
    final to = now.add(Duration(days: settings.daysToLoad));
    var withGuide = 0;
    // 1.2.5 Fix 1: per-tier counts, so the report says HOW channels
    // matched (and why the rest did not), not just how many.
    var manualMatches = 0;
    var tvgIdMatches = 0;
    var nameMatches = 0;
    var looseNameMatches = 0;
    // 1.3.29 P1-5: the affiliate-guess bucket — kept apart from the
    // certain 'name' bucket so the dialog shows the guess honestly.
    var affiliateGuessMatches = 0;
    var ambiguousCount = 0;
    var foreignCount = 0;
    var noTvgIdCount = 0;
    var tvgIdNotInFeedCount = 0;
    var matchedButNoProgrammesCount = 0;
    // 1.2.8 F2: the split of the matched-but-no-programmes bucket.
    var matchedButNoProgrammesDeclaredCount = 0;
    var matchedButNoProgrammesOutsideWindowCount = 0;
    var noFeedCount = 0;
    var epgChannelIdCount = 0;
    // 1.2.8 F7: every unmatched row in channel order — stratified
    // into the 5-row sample after the loop.
    final unmatchedRows = <({int index, IptvEpgUnmatchedSample sample})>[];
    // 1.2.8 F9: the foreign-bucket diagnostic.
    final foreignSamples = <IptvEpgForeignSample>[];
    var foreignLanguageTaggedCandidateCount = 0;
    // 1.2.8 F2: the nearest retained programme start to now across
    // the outside-window rows.
    DateTime? nearestOutsideWindowProgramme;
    for (var i = 0; i < channels.length; i++) {
      final channel = channels[i];
      if ((_client.epgChannelIdForChannelKey(channel.key) ?? '').isNotEmpty) epgChannelIdCount++;
      final resolution = _resolveChannelAcrossFeeds(channel.key, outcome.loaded, mappings, settings, from, to, loadRows: false);
      if (resolution.matchedXmltvId != null) {
        withGuide++;
        switch (resolution.matchMethod) {
          case 'manual':
            manualMatches++;
          case 'name':
          case 'name-guess':
            nameMatches++;
          case 'name-loose':
            looseNameMatches++;
          case 'name-guess-affiliate':
            affiliateGuessMatches++;
          default:
            tvgIdMatches++;
        }
      } else {
        final blockedReason = resolution.blockedReason ?? 'no-feed';
        switch (blockedReason) {
          case 'ambiguous':
            ambiguousCount++;
          case 'foreign':
            foreignCount++;
            // 1.2.8 F9: record the refused candidates with their
            // countries (first loaded feed's guide — the resolution
            // came from it) and count the language-tagged ones.
            if (outcome.loaded.isNotEmpty) {
              final firstGuide = outcome.loaded.first.guide;
              final candidates = resolution.blockedCandidates.map((id) {
                final countries = epgFeedChannelCountries(id, firstGuide.displayNames[id] ?? const <String>[]);
                return IptvEpgForeignCandidate(
                  xmltvId: id,
                  countries: countries.toList(growable: false)..sort(),
                );
              }).toList(growable: false);
              for (final candidate in candidates) {
                if (candidate.countries.isNotEmpty &&
                    candidate.countries.every(_epgLanguageOnlyCodes.contains)) {
                  foreignLanguageTaggedCandidateCount++;
                }
              }
              if (foreignSamples.length < 5) {
                foreignSamples.add(
                  IptvEpgForeignSample(
                    channelName: channel.title ?? channel.key,
                    playlistCountry: epgChannelCountry(channel.title ?? channel.key),
                    candidates: candidates,
                  ),
                );
              }
            }
          case 'no-tvg-id':
            noTvgIdCount++;
          case 'tvg-id-not-in-feed':
            tvgIdNotInFeedCount++;
          case 'matched-but-no-programmes':
          case 'matched-but-no-programmes-declared':
            matchedButNoProgrammesCount++;
            matchedButNoProgrammesDeclaredCount++;
          case 'matched-but-no-programmes-outside-window':
            matchedButNoProgrammesCount++;
            matchedButNoProgrammesOutsideWindowCount++;
            // 1.2.8 F2: the nearest retained start to now across this
            // row's identified ids (first loaded feed's guide).
            if (outcome.loaded.isNotEmpty) {
              final firstGuide = outcome.loaded.first.guide;
              for (final id in resolution.blockedCandidates) {
                // 1.2.12: the nearest start comes from the slot bitmap
                // (30-minute granularity) — the rows are no longer
                // retained for the whole feed.
                final start = firstGuide.nearestProgramStart(id, now);
                if (start != null &&
                    (nearestOutsideWindowProgramme == null ||
                        start.difference(now).abs() < nearestOutsideWindowProgramme.difference(now).abs())) {
                  nearestOutsideWindowProgramme = start;
                }
              }
            }
          default:
            noFeedCount++;
        }
        unmatchedRows.add((
          index: i,
          sample: IptvEpgUnmatchedSample(
            channelName: channel.title ?? channel.key,
            epgChannelId: _client.epgChannelIdForChannelKey(channel.key),
            tvgId: _client.tvgIdForChannelKey(channel.key),
            reason: blockedReason,
          ),
        ));
      }
    }
    // 1.2.8 F7: stratified sample — first row per reason in order of
    // first appearance, then fill to 5 in channel order; the final
    // sample is in channel order.
    final pickedUnmatched = <({int index, IptvEpgUnmatchedSample sample})>[];
    final seenUnmatchedReasons = <String>{};
    for (final row in unmatchedRows) {
      if (seenUnmatchedReasons.add(row.sample.reason)) pickedUnmatched.add(row);
    }
    for (final row in unmatchedRows) {
      if (pickedUnmatched.length >= 5) break;
      if (!pickedUnmatched.contains(row)) pickedUnmatched.add(row);
    }
    pickedUnmatched.sort((a, b) => a.index.compareTo(b.index));
    final sampleUnmatched = pickedUnmatched.map((r) => r.sample).toList(growable: false);
    // 1.2.8 F3: the same resolution over ALL channels including
    // hidden ones (the refresh captured the full list). Null when the
    // list failed to load.
    final allChannels = channelListError == null ? _client.fullLiveChannelsFromLastRefresh : null;
    int? withGuideAllChannels;
    if (allChannels != null) {
      var count = 0;
      for (final channel in allChannels) {
        final resolution = _resolveChannelAcrossFeeds(channel.key, outcome.loaded, mappings, settings, from, to, loadRows: false);
        if (resolution.matchedXmltvId != null) count++;
      }
      withGuideAllChannels = count;
    }
    final feedChannelIds = outcome.loaded.expand((e) => e.guide.programCountByChannel.keys).toSet().length;
    // 1.2.15 R4: one download record per source whose feed was fetched
    // for this Reload (bytes, SHA, 304-vs-200, User-Agent). 1.4.4 F6:
    // only facts recorded during THIS Reload — the stash also holds
    // the previous download's facts, and a Reload whose refresh
    // failed (or is still running) must not report the old download's
    // bytes/SHA as its own.
    final feedDownloads = <IptvEpgFeedDownload>[];
    for (final entry in outcome.loaded) {
      final download = _feedDownloadFor(entry.attempt);
      if (download != null && !download.fetchedAt.isBefore(reloadStarted)) feedDownloads.add(download);
    }
    // Feed sample: the first loaded feed's first 5 ids, sorted, with
    // their display names — what the feed actually calls its channels.
    final feedSamples = <IptvEpgFeedSample>[];
    if (outcome.loaded.isNotEmpty) {
      final first = outcome.loaded.first.guide;
      final ids = first.programCountByChannel.keys.toList(growable: false)..sort();
      for (final id in ids.take(5)) {
        feedSamples.add(
          IptvEpgFeedSample(
            xmltvId: id,
            displayNames: first.displayNames[id] ?? const [],
            programCount: first.programCountByChannel[id] ?? 0,
          ),
        );
      }
    }
    // The Reload report and the Logs export carry the same numbers
    // (1.2.5 Fix 1): a feed that loads but matches nothing must say
    // which tier failed, in the dialog and in the export.
    final feedSummary = outcome.loaded.isEmpty
        ? 'no feeds loaded'
        : outcome.loaded
            .map((e) => '${e.attempt.config.name}: ${e.guide.channelsParsed} channels, ${e.guide.programsParsed} parsed, ${e.guide.totalProgramCount} retained')
            .join('; ');
    // 1.2.20 (b): slide the window for the visible rows (or the first
    // screen) so the guide opens with programmes on it. Best-effort
    // and reported honestly — it never changes the match counts.
    final windowSlide = await _slideReloadWindow(outcome, channels, mappings);
    // 1.4.4 F6: snapshot the flag HERE, at result-assembly time — not
    // right after the feed load. The match counts, samples and window
    // slide above take real time, and a refresh that fails (or lands)
    // in that window must read as settled, not "still downloading":
    // the flag describes the state when the result is produced, so
    // the dialog never contradicts the outcome lines beside it. A
    // slow download is still running here, so the flag stays true
    // for it.
    final feedRefreshBackground = outcome.loaded.any((e) => _xmltvGuideFutures.containsKey(e.attempt.cacheKey));
    appLogger.i(
      'IPTV EPG reload: ${channels.length} channels, $withGuide with guide '
      '(manual $manualMatches, tvg-id $tvgIdMatches, name $nameMatches, loose-name $looseNameMatches, affiliate-guess $affiliateGuessMatches; '
      'no match: ambiguous $ambiguousCount, foreign $foreignCount, no-tvg-id $noTvgIdCount, '
      'tvg-id-not-in-feed $tvgIdNotInFeedCount, matched-but-no-programmes $matchedButNoProgrammesCount, '
      'no-feed $noFeedCount); $epgChannelIdCount carry epg_channel_id; '
      'matched-but-no-programmes split: declared $matchedButNoProgrammesDeclaredCount, '
      'outside-window $matchedButNoProgrammesOutsideWindowCount'
      '${nearestOutsideWindowProgramme == null ? '' : ', nearest outside-window programme $nearestOutsideWindowProgramme'}; '
      '${allChannels == null ? 'all-channels counts unavailable' : 'all channels (incl. hidden): $withGuideAllChannels with guide of ${allChannels.length}'}; '
      'foreign samples: ${foreignSamples.map((e) => e.channelName).join(', ')} '
      '($foreignLanguageTaggedCandidateCount language-tagged candidates); '
      'feeds: $feedSummary; '
      'feed downloads: ${feedDownloads.map((d) => '${d.sourceName}: ${d.bytesDownloaded} bytes, SHA ${d.sha256 ?? '—'}, ${d.notModified ? '304' : '200'}, UA ${d.userAgent ?? 'none'}').join('; ')}; '
      'window slide: ${windowSlide.slid ? 'ready for ${windowSlide.channelCount} rows' : 'skipped (${windowSlide.reason ?? 'silent'})'}; '
      'guide rows showing programmes BEFORE THIS RELOAD: ${guideCoverageSample.withPrograms} of ${guideCoverageSample.sampled} sampled '
      '(quick guide ${guideCoverageSample.fromShortEpg}, big guide by id ${guideCoverageSample.fromFeedById}, by name ${guideCoverageSample.fromFeedByName}, mixed ${guideCoverageSample.fromMixed}, no data ${guideCoverageSample.none}, never fetched ${guideCoverageSample.notFetched}, scope ${guideCoverageSample.scope.name}); '
      'feed sample: ${feedSamples.map((e) => e.xmltvId).join(', ')}; '
      'unmatched sample: ${sampleUnmatched.map((e) => e.channelName).join(', ')}; '
      'feed refresh in background: $feedRefreshBackground',
    );
    return IptvReloadTvDetailsResult(
      channelsLoaded: channels.length,
      withGuide: withGuide,
      withoutGuide: channels.length - withGuide,
      feedChannelIds: feedChannelIds,
      feedDownloads: feedDownloads,
      guideCoverageSample: guideCoverageSample,
      channelListFailureKind: channelListError == null ? null : classifyEpgFeedError(channelListError),
      channelListFailureReason: channelListError == null ? null : epgFeedErrorReason(channelListError),
      // No list, no match counts: the feed lines name the feed's own
      // size instead of a match count that means nothing without a list.
      feedOutcomes: _feedOutcomes(
        outcome,
        channelListError == null ? channels : null,
        mappings,
        settings,
        from,
        to,
      ),
      matchTiers: IptvEpgMatchTiers(
        manual: manualMatches,
        tvgId: tvgIdMatches,
        name: nameMatches,
        nameLoose: looseNameMatches,
        affiliateGuess: affiliateGuessMatches,
        ambiguous: ambiguousCount,
        foreign: foreignCount,
        noTvgId: noTvgIdCount,
        tvgIdNotInFeed: tvgIdNotInFeedCount,
        matchedButNoProgrammes: matchedButNoProgrammesCount,
        matchedButNoProgrammesDeclared: matchedButNoProgrammesDeclaredCount,
        matchedButNoProgrammesOutsideWindow: matchedButNoProgrammesOutsideWindowCount,
        none: noFeedCount,
      ),
      feedSamples: feedSamples,
      sampleUnmatched: sampleUnmatched,
      epgChannelIdCount: epgChannelIdCount,
      withGuideAllChannels: withGuideAllChannels,
      channelsLoadedAll: allChannels?.length,
      nearestOutsideWindowProgramme: nearestOutsideWindowProgramme,
      foreignSamples: foreignSamples,
      foreignLanguageTaggedCandidateCount: foreignLanguageTaggedCandidateCount,
      windowSlide: windowSlide,
      feedRefreshBackground: feedRefreshBackground,
    );
  }

  /// "Update now" (1.2.3 RC2): bust the cache AND load the enabled
  /// feeds once, then report the outcome — so the action earns its
  /// success message instead of claiming "Guide updated" for a cache
  /// clear that downloads nothing. The fetch is the same lazy feed
  /// load the guide uses, with the 5-minute negative cache bypassed
  /// (D8: an explicit user retry is not a storm). It never touches
  /// the catalog: no channel-list re-fetch, so the report names each
  /// feed's own size rather than match counts (see [_feedOutcomes]).
  Future<IptvEpgUpdateNowResult> updateEpgNow() async {
    await refreshEpgCache();
    final settings = await _readEpgSettings();
    final ttl = settings.updateIntervalHours <= 0 ? null : Duration(hours: settings.updateIntervalHours);
    final attempts = await _epgSourceAttempts();
    // D9: loading the feeds is an attempt — stamp it, so "Last attempt"
    // certifies the activity even when the feed then fails.
    _noteEpgAttempt(DateTime.now());
    final outcome = await _loadEnabledFeeds(attempts, ttl, force: true);
    final mappings = await _epgStore.loadMappings();
    final now = DateTime.now();
    final from = now.subtract(Duration(days: settings.pastDays));
    final to = now.add(Duration(days: settings.daysToLoad));
    // 1.2.5 Fix 1: the feed stats land in the Logs export too, so an
    // Update-now that loads an empty feed leaves a trace.
    final feedSummary = outcome.loaded.isEmpty
        ? 'no feeds loaded'
        : outcome.loaded
            .map((e) => '${e.attempt.config.name}: ${e.guide.channelsParsed} channels, ${e.guide.programsParsed} parsed, ${e.guide.totalProgramCount} retained')
            .join('; ');
    // 1.2.20 (b): same end-of-load slide as the Reload, best-effort
    // with log-only reporting (this result type has no dialog line
    // for it). The channel list is the last refreshed one, cached —
    // no network — and only used when the registry is empty.
    final windowSlide = await _slideReloadWindow(
      outcome,
      _client.fullLiveChannelsFromLastRefresh,
      mappings,
    );
    // 1.4.4 F6: snapshot the flag HERE, at result-assembly time —
    // same reasoning as reloadTvDetails above: a refresh that fails
    // (or lands) during the slide must read as settled.
    final feedRefreshBackground = outcome.loaded.any((e) => _xmltvGuideFutures.containsKey(e.attempt.cacheKey));
    appLogger.i(
      'IPTV EPG update now: $feedSummary; '
      'window slide: ${windowSlide.slid ? 'ready for ${windowSlide.channelCount} rows' : 'skipped (${windowSlide.reason ?? 'silent'})'}; '
      'feed refresh in background: $feedRefreshBackground',
    );
    // 1.6.32, D3: Update now reports match counts — the channel list
    // is the last refreshed one, cached, no network (the same list
    // the window slide above already uses). When it is empty (never
    // refreshed) the outcomes keep their feed-only lines, as before.
    final cachedChannels = _client.fullLiveChannelsFromLastRefresh;
    final channelsForMatch = (cachedChannels != null && cachedChannels.isNotEmpty) ? cachedChannels : null;
    return IptvEpgUpdateNowResult(
      feedOutcomes: _feedOutcomes(outcome, channelsForMatch, mappings, settings, from, to),
      feedRefreshBackground: feedRefreshBackground,
      channelsTotal: channelsForMatch?.length ?? 0,
    );
  }

  /// Per-source outcomes for a Reload / Update-now report (1.2.3): one
  /// line per enabled source, naming what happened to ITS feed. Loaded
  /// feeds name how many of this connection's channels they can serve
  /// ([channels] is null when the list was not available — Update now,
  /// or a Reload whose list failed — and the report then names the
  /// feed's own size instead of a match count).
  List<IptvEpgFeedOutcome> _feedOutcomes(
    _LoadedEpgFeeds outcome,
    List<LiveTvChannel>? channels,
    Map<String, IptvEpgMapping> mappings,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
  ) {
    final out = <IptvEpgFeedOutcome>[];
    for (final entry in outcome.loaded) {
      int? matched;
      if (channels != null) {
        var count = 0;
        for (final channel in channels) {
          if (_channelHasFeedMatch(channel.key, [entry], mappings, settings, from, to)) count++;
        }
        matched = count;
      }
      out.add(
        IptvEpgFeedOutcome(
          sourceId: entry.attempt.config.id,
          sourceName: entry.attempt.config.name,
          kind: matched == null || matched > 0 ? IptvEpgFeedOutcomeKind.loaded : IptvEpgFeedOutcomeKind.loadedNoMatch,
          feedChannels: entry.guide.programCountByChannel.length,
          matchedChannels: matched,
          feedProgramsParsed: entry.guide.programsParsed,
          feedProgramsRetained: entry.guide.totalProgramCount,
          feedChannelsParsed: entry.guide.channelsParsed,
        ),
      );
    }
    for (final failure in outcome.failures) {
      out.add(
        IptvEpgFeedOutcome(
          sourceId: failure.attempt.config.id,
          sourceName: failure.attempt.config.name,
          kind: classifyEpgFeedError(failure.error),
          reason: epgFeedErrorReason(failure.error),
        ),
      );
    }
    for (final attempt in outcome.deferred) {
      out.add(
        IptvEpgFeedOutcome(
          sourceId: attempt.config.id,
          sourceName: attempt.config.name,
          kind: IptvEpgFeedOutcomeKind.deferred,
        ),
      );
    }
    return out;
  }

  /// Refresh the guide when the quiet hour passed since the last data
  /// landed (§3.3, TiviMate's ~04:00 update time). An in-app interval
  /// check on guide open — never a background-job promise. Returns true
  /// when a refresh was triggered.
  Future<bool> maybeRefreshForQuietHour() async {
    final settings = await SettingsService.getInstance();
    final updateTime = settings.read(SettingsService.iptvEpgUpdateTimeMinutes);
    if (updateTime < 0) {
      EpgCadenceLog.recordQuietHourDecision(refreshed: false, reason: 'update-time-off');
      return false;
    }
    final intervalHours = settings.read(SettingsService.iptvEpgUpdateIntervalHours);
    if (intervalHours <= 0) {
      EpgCadenceLog.recordQuietHourDecision(refreshed: false, reason: 'manual-only');
      return false; // Manual only: never auto-refresh.
    }
    final now = DateTime.now();
    var boundary = DateTime(now.year, now.month, now.day, updateTime ~/ 60, updateTime % 60);
    if (now.isBefore(boundary)) boundary = boundary.subtract(const Duration(days: 1));
    if (_quietHourRefreshedFor == boundary) {
      EpgCadenceLog.recordQuietHourDecision(refreshed: false, reason: 'already-refreshed');
      return false;
    }
    // Last data landed: this support's in-memory stamp, else the stored
    // pref (a relaunch clears the memory but not the pref).
    final stored = settings.read(SettingsService.iptvEpgLastUpdated);
    final lastData = _lastEpgUpdatedAt ?? DateTime.tryParse(stored);
    // 1.3.24 §67 F1: a fresh in-memory guide is proof data landed,
    // whatever the stamp says — a Reload that just parsed the feed
    // must not be re-downloaded by this check.
    final freshGuide = _xmltvCache.values.any((guide) => !guide.fetchedAt.isBefore(boundary));
    if (freshGuide) {
      EpgCadenceLog.recordQuietHourDecision(refreshed: false, reason: 'fresh-guide-in-memory', lastData: lastData);
      return false;
    }
    if (lastData != null && !lastData.isBefore(boundary)) {
      EpgCadenceLog.recordQuietHourDecision(refreshed: false, reason: 'stamp-fresh', lastData: lastData);
      return false;
    }
    EpgCadenceLog.recordQuietHourDecision(refreshed: true, reason: 'stale-or-unknown', lastData: lastData);
    _quietHourRefreshedFor = boundary;
    await refreshEpgCache();
    return true;
  }

  /// Drop the in-memory EPG caches under memory pressure (1.2.4, item
  /// 1): clear the per-channel EPG map and the parsed XMLTV guides,
  /// and bump [epgVersion] so the guide drops its own per-channel
  /// state (its merged-programs cache) and re-fetches visible rows
  /// lazily. A RELIEF VALVE, not a clear — unlike [clearEpgCache] it
  /// deletes NO persisted EPG, sets NO `_epgCleared` (the guide
  /// refetches instead of staying empty), and touches NO "Last updated"
  /// stamp. The failed-feed negative cache and the playback-gate
  /// deferrals are kept: a pressure drop must not re-download a feed
  /// that just failed, or re-poison a channel the gate deferred.
  void dropEpgFromMemory() {
    _epgCache.clear();
    _xmltvCache.clear();
    // 1.4 F1: the shared guide metadata is rebuildable cache data —
    // the valve drops it with the guides it derives from.
    _guideMetadataCache.clear();
    _bumpEpgVersion();
  }

  /// Empty the EPG caches (Update now / Clear guide). The next guide visit
  /// re-fetches visible channels; the guide watches [epgVersion] to reset
  /// its own per-channel state.
  ///
  /// This is the "Clear guide" behaviour: [fetchEpgForChannel] stays empty
  /// until something refreshes ([refreshEpgCache] or the start-up refresh),
  /// so the guide shows "No information available" hour blocks.
  /// 1.4.4 F1: when [keepPersistedFeed] is true (every refresh path —
  /// Reload, "Update now", the quiet-hour refresh), the bust clears the
  /// per-channel caches, the in-memory guide, the validators and the
  /// failure records, but KEEPS the persisted feed XML + row-store DB
  /// until the new parse promotes. The old guide then keeps serving
  /// while the new feed downloads (F6), and a failed download or parse
  /// falls back to it — the invariant the download path already
  /// promises but Reload used to void by deleting first. The whole
  /// directory delete stays only behind the explicit "Clear guide"
  /// settings action (keepPersistedFeed false), where the user asked
  /// for everything to go. When the feed is kept, the guide is not
  /// empty, so [_epgCleared] stays false and the "last updated" stamp
  /// is left alone.
  Future<void> clearEpgCache({bool keepPersistedFeed = false}) async {
    _epgCache.clear();
    _xmltvCache.clear();
    // 1.4 F1: a clear is a fresh start for the shared metadata too.
    _guideMetadataCache.clear();
    _lastXmltvFeedChannelIds = 0;
    // A clear is an explicit retry: forget a failed feed too, so the next
    // guide visit downloads instead of hitting the negative cache.
    _xmltvFailedAt.clear();
    // A clear is a fresh start: forget playback-gate deferrals (D1b)
    // too — the guide re-fetches visible rows from scratch.
    _deferredEpgChannels.clear();
    // A clear is a fresh start for validators too (1.2.2 I9): a 304
    // against a deleted feed has no guide to reuse. The 304 backstop
    // would recover anyway, but a clear must not depend on it.
    unawaited(
      (() async {
        try {
          await _epgStore.clearValidators();
        } catch (_) {
          // Best-effort: stale validators are harmless — the backstop
          // re-fetches fresh when there is no guide to reuse.
        }
      })(),
    );
    if (!keepPersistedFeed) {
      // Best-effort and fire-and-forget: the in-memory caches are already
      // empty and the guide is cleared, so don't gate the settings action
      // (or the guide) on the disk delete — it completes in the background.
      // 1.3.24 §67 F2: the persisted delete never runs under a feed
      // promotion. When no feed job is in flight it is awaited, so a
      // Reload's bust finishes before its feed download starts; while a
      // job is in flight the delete is deferred until the job settles
      // (and dropped if the feed lands — the promotion IS the fresh
      // state). All callers already await this method, so the await
      // blocks no UI thread.
      if (_feedJobsInFlight > 0) {
        _epgDeleteDeferred = true;
        _epgDeleteDeferredLanded = false;
        EpgCadenceLog.recordEpgClearDeferred(reason: 'feed-job-in-flight');
      } else {
        await _deletePersistedEpg();
      }
      _bumpEpgVersion();
      _epgCleared = true;
      _lastEpgUpdatedAt = null;
      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.iptvEpgLastUpdated, '');
      await settings.write(SettingsService.iptvEpgLastGuideCounts, '');
    } else {
      _bumpEpgVersion();
    }
  }

  /// Bust the EPG cache AND force a fresh fetch on the guide's next build
  /// ("Update now"). Unlike [clearEpgCache], the guide refetches instead
  /// of staying empty.
  ///
  /// 1.3.24 §67 F2: concurrent busts coalesce — a second bust while
  /// the first is still running joins the same future instead of
  /// deleting under the fresh feed. Returns the in-flight future
  /// itself, so concurrent callers can assert identity.
  Future<void> refreshEpgCache() {
    final inFlight = _refreshEpgCacheInFlight;
    if (inFlight != null) return inFlight;
    final future = _refreshEpgCacheLocked();
    _refreshEpgCacheInFlight = future;
    unawaited(
      future.then<void>((_) {}).catchError((_) {}).whenComplete(() {
        if (identical(_refreshEpgCacheInFlight, future)) _refreshEpgCacheInFlight = null;
      }),
    );
    return future;
  }

  Future<void> _refreshEpgCacheLocked() async {
    // 1.4.4 F1: a refresh busts the caches but keeps the persisted feed
    // + store — the old guide serves while the new feed downloads.
    await clearEpgCache(keepPersistedFeed: true);
    _epgCleared = false;
  }

  /// Record the last-update time for the settings screen, at most one
  /// SharedPreferences write per minute across all channel fetches.
  void _noteEpgUpdated(DateTime now) {
    if (_lastEpgPrefWrite != null && now.difference(_lastEpgPrefWrite!).inSeconds < 60) return;
    _lastEpgPrefWrite = now;
    final stamp = now.toIso8601String();
    SettingsService.getInstance().then((settings) {
      settings.write(SettingsService.iptvEpgLastUpdated, stamp);
    });
  }

  /// Record the loaded guide's size for the settings screen (1.6.32,
  /// D4): distinct feed channels with programmes + total programmes
  /// across every loaded feed, as "channels|programmes". Written only
  /// on bulk feed loads (the [stampLastUpdated] call sites), never on
  /// per-channel loads — one write per feed per load, so no throttle
  /// is needed. Best-effort: a failed write leaves the previous
  /// counts in place, and the next load re-records.
  void _noteGuideCounts() {
    if (_xmltvCache.isEmpty) return;
    final channelIds = <String>{};
    var programs = 0;
    for (final guide in _xmltvCache.values) {
      channelIds.addAll(guide.programCountByChannel.keys);
      programs += guide.totalProgramCount;
    }
    if (channelIds.isEmpty && programs == 0) return;
    final value = '${channelIds.length}|$programs';
    SettingsService.getInstance().then((settings) {
      settings.write(SettingsService.iptvEpgLastGuideCounts, value);
    });
  }

  /// Record the last EPG fetch ATTEMPT for the settings screen (1.1.2
  /// D9): an attempt happened even when the fetch failed or returned
  /// empty, so this stamp — unlike "Last updated" — certifies activity,
  /// not data. Throttled to one write per minute, like
  /// [_noteEpgUpdated]. Written before the fetch runs (see
  /// [fetchEpgForChannel]).
  void _noteEpgAttempt(DateTime now) {
    if (_lastEpgAttemptPrefWrite != null && now.difference(_lastEpgAttemptPrefWrite!).inSeconds < 60) return;
    _lastEpgAttemptPrefWrite = now;
    final stamp = now.toIso8601String();
    SettingsService.getInstance().then((settings) {
      settings.write(SettingsService.iptvEpgLastAttempt, stamp);
    });
  }

  @override
  Future<LiveTvPlaybackSession?> startPlayback(
    String channelKey, {
    String? dvrKey,
    TranscodeQualityPreset quality = TranscodeQualityPreset.original,
  }) async {
    // Populate the channel lookup (cached after the first call).
    // 1.2.17: a first load against a failing panel (fresh install, no
    // disk cache) throws here — return null like an unplayable channel
    // (the caller already handles null) instead of an uncaught throw.
    try {
      await _client.iptvChannels();
    } catch (e) {
      appLogger.w('IPTV: startPlayback could not load channels: $e');
      return null;
    }
    late final String liveUrl;
    try {
      liveUrl = _client.liveUrlForChannelKey(channelKey);
    } on UnsupportedError {
      return null;
    }
    final archive = _client.archiveInfoForChannelKey(channelKey);
    return IptvLiveTvPlaybackSession(
      client: _client,
      channelKey: channelKey,
      liveUrl: liveUrl,
      archiveDurationSeconds: archive?.archiveDurationSeconds ?? 0,
    );
  }

  @override
  Future<String> buildFavoriteChannelSource({String? lineup}) async => _favoriteChannelSource;

  @override
  String get favoriteStoreKey => 'iptv:${_client.connection.id}';

  @override
  FavoriteChannelPersistenceMode get favoritePersistenceMode => FavoriteChannelPersistenceMode.serverSlice;

  @override
  Future<List<FavoriteChannel>> fetchFavoriteChannels({bool migrate = true, void Function()? checkCurrent}) {
    return _favoritesRepository.read(
      key: _favoritesPrefsKey,
      legacyKey: _favoritesPrefsKey,
      migrate: migrate,
      checkCurrent: checkCurrent,
    );
  }

  @override
  Future<void> setFavoriteChannels(List<FavoriteChannel> channels, {void Function()? checkCurrent}) {
    checkCurrent?.call();
    return _favoritesRepository.write(_favoritesPrefsKey, channels, checkCurrent: checkCurrent);
  }
}

/// One IPTV live session: a static direct-play URL, plus a rebuilt
/// `/timeshift/` URL when the channel offers catch-up and the player asks
/// for a negative offset. No server session is opened, so there is nothing
/// to heartbeat, release, or re-negotiate — [recover] returns this session
/// so the player simply re-opens the same URL.
class IptvLiveTvPlaybackSession implements LiveTvPlaybackSession {
  final IptvClient client;
  final String channelKey;
  final String liveUrl;
  final int archiveDurationSeconds;

  /// Epoch seconds when the session started — the capture-buffer origin.
  final double _startedAtEpoch;

  IptvLiveTvPlaybackSession({
    required this.client,
    required this.channelKey,
    required this.liveUrl,
    required this.archiveDurationSeconds,
  }) : _startedAtEpoch = DateTime.now().millisecondsSinceEpoch / 1000;

  /// Build #28: on a one-connection line the next stream must wait for
  /// this one to be released (see [LiveTvPlaybackSession
  /// .requiresReleaseBeforeOpen]). The limit is the client's cached
  /// `max_connections` — unknown until the health probe runs, and
  /// unknown means wait.
  @override
  bool get requiresReleaseBeforeOpen => client.isSingleConnection;

  bool get _hasArchive => archiveDurationSeconds > 0;

  @override
  LiveProgramInfo get program => LiveProgramInfo.none;

  @override
  LiveTvBackgroundPolicy get backgroundPolicy => LiveTvBackgroundPolicy.stopAndExit;

  @override
  CaptureBuffer? get captureBuffer {
    if (!_hasArchive) return null;
    // The window's end is "now", computed at read time — not frozen at
    // tune time (build #9 Task 3): the old `seekEndSeconds: 0` left the
    // bar's live edge minutes stale after minutes of viewing, because no
    // heartbeat ever refreshed it.
    final nowEpoch = DateTime.now().millisecondsSinceEpoch / 1000;
    return CaptureBuffer(
      startedAt: _startedAtEpoch,
      seekStartSeconds: -archiveDurationSeconds.toDouble(),
      seekEndSeconds: (nowEpoch - _startedAtEpoch).clamp(0, double.infinity),
    );
  }

  @override
  List<MediaSubtitleTrack> get subtitleTracks => const [];

  @override
  bool get canTimeShift => _hasArchive;

  /// The live open carries the configured Xtream User-Agent alongside the
  /// language header (build #22): the panel sees the same identity on the
  /// stream as on the API calls. Delegates to the client so a Settings
  /// change applies to the next open; covers the live edge and the
  /// timeshift URL alike, since both open through this session.
  @override
  Map<String, String> get streamHeaders => {'Accept-Language': 'en', ...client.streamHeaders};

  @override
  Future<String?> streamUrlAt({int? offsetSeconds, MediaSubtitleTrack? subtitleTrack}) async {
    if (subtitleTrack != null) return null;
    if (offsetSeconds == null || offsetSeconds == 0) return liveUrl;
    if (offsetSeconds > 0 || !_hasArchive) return null;
    // offsetSeconds is seconds from the capture-buffer origin (session
    // start); negative = that far back into the archive.
    final startEpoch = (_startedAtEpoch + offsetSeconds).round();
    final start = DateTime.fromMillisecondsSinceEpoch(startEpoch * 1000, isUtc: true);
    final backMinutes = (-offsetSeconds / 60).ceil();
    final archiveMinutes = (archiveDurationSeconds / 60).ceil();
    final durationMinutes = backMinutes.clamp(1, archiveMinutes);
    return client.timeshiftUrlForChannelKey(channelKey, start, durationMinutes);
  }

  @override
  Future<LiveTimelineUpdate?> reportTimeline({
    required String state,
    required int positionMs,
    required int durationMs,
  }) async {
    // The player's 10s timeline heartbeat refreshes the seek window from
    // this report — returning null (the old behaviour) left the buffer
    // frozen at its tune-time snapshot and the live edge went stale
    // (build #9 Task 3). The update carries a freshly computed buffer so
    // the existing commit path refreshes `_live.captureBuffer` and
    // `atLiveEdge`, exactly as it does for Plex. No archive → no window.
    final buffer = captureBuffer;
    if (buffer == null) return null;
    return LiveTimelineUpdate(captureBuffer: buffer);
  }

  @override
  // Stays a no-op (build #28): there is no panel disconnect/logout
  // endpoint — no peer sends one — so the session owns nothing releasable.
  // The release IS the awaited player stop (the release gate), not this.
  Future<void> discard() async {}

  @override
  Future<LiveTvPlaybackSession?> recover({required bool directStream, required bool directStreamAudio}) async => this;
}

/// EPG settings as the EPG layer reads them (see [SettingsService]).
class _EpgSettings {
  final int daysToLoad;
  final int updateIntervalHours;
  final int pastDays;
  final bool updateOnStart;
  final int timeOffsetMinutes;

  const _EpgSettings({
    required this.daysToLoad,
    required this.updateIntervalHours,
    required this.pastDays,
    required this.updateOnStart,
    required this.timeOffsetMinutes,
  });
}

/// One channel's fetched guide: the full settings-window program list plus
/// the window it was fetched for, so a later request can tell whether the
/// cached entry still covers it.
class _CachedChannelEpg {
  final List<LiveTvProgram> programs;
  final DateTime fetchedAt;
  final DateTime windowFrom;
  final DateTime windowTo;

  /// Which source served these programmes (build #17, §10) — the split
  /// the guide coverage diagnostic reports. Persisted, so a disk-served
  /// entry still knows its source; files written before this build lack
  /// the field and read back as [IptvEpgSource.unknown].
  final IptvEpgSource source;

  /// Which configured source served these programmes (PlezTV 1.2.0):
  /// the provider feed (`'provider'`) or a user-added source id. Null
  /// for entries written before this build. Drives the EPG details view
  /// ("assigned source") and the per-source coverage breakdown.
  final String? sourceId;

  /// The XMLTV channel id that matched (or was manually assigned), and
  /// how it matched (`'tvg-id'`, `'name'`, `'manual'`). Null when nothing
  /// matched — the details view reads these, not a fresh fetch.
  final String? matchedXmltvId;
  final String? matchMethod;

  /// Feed generations this entry was mapped from (1.2.1 D7): the XMLTV
  /// cache key -> that guide's fetch time, for every feed consulted
  /// while fetching the channel. Empty when the entry came from
  /// short-EPG alone (or was written before this build). When a feed
  /// refreshes, entries stamped from the older generation are stale
  /// and must refetch instead of serving for the whole interval.
  final Map<String, DateTime> feedGenerations;

  const _CachedChannelEpg({
    required this.programs,
    required this.fetchedAt,
    required this.windowFrom,
    required this.windowTo,
    this.source = IptvEpgSource.unknown,
    this.sourceId,
    this.matchedXmltvId,
    this.matchMethod,
    this.feedGenerations = const {},
  });

  Map<String, dynamic> toJson() => {
    'fetchedAt': fetchedAt.toIso8601String(),
    'windowFrom': windowFrom.toIso8601String(),
    'windowTo': windowTo.toIso8601String(),
    'source': source.name,
    if (sourceId != null) 'sourceId': sourceId,
    if (matchedXmltvId != null) 'matchedXmltvId': matchedXmltvId,
    if (matchMethod != null) 'matchMethod': matchMethod,
    if (feedGenerations.isNotEmpty) 'feedGenerations': feedGenerations.map((k, v) => MapEntry(k, v.toIso8601String())),
    'programs': programs.map((p) => p.toJson()).toList(),
  };

  factory _CachedChannelEpg.fromJson(Map<String, dynamic> json) {
    final fetchedAt = DateTime.tryParse(json['fetchedAt'] as String? ?? '');
    final windowFrom = DateTime.tryParse(json['windowFrom'] as String? ?? '');
    final windowTo = DateTime.tryParse(json['windowTo'] as String? ?? '');
    if (fetchedAt == null || windowFrom == null || windowTo == null) {
      throw const FormatException('Invalid cached EPG entry');
    }
    final source = IptvEpgSource.values.firstWhere(
      (s) => s.name == json['source'] as String?,
      orElse: () => IptvEpgSource.unknown,
    );
    final programs = <LiveTvProgram>[];
    final raw = json['programs'];
    if (raw is List) {
      for (final row in raw) {
        if (row is! Map<String, dynamic>) continue;
        try {
          programs.add(LiveTvProgram.fromJson(row));
        } catch (_) {
          // One bad program does not invalidate the channel's guide.
        }
      }
    }
    return _CachedChannelEpg(
      programs: programs,
      fetchedAt: fetchedAt,
      windowFrom: windowFrom,
      windowTo: windowTo,
      source: source,
      sourceId: json['sourceId'] as String?,
      matchedXmltvId: json['matchedXmltvId'] as String?,
      matchMethod: json['matchMethod'] as String?,
      feedGenerations: _feedGenerationsFromJson(json['feedGenerations']),
    );
  }

  static Map<String, DateTime> _feedGenerationsFromJson(Object? raw) {
    final out = <String, DateTime>{};
    if (raw is Map<String, dynamic>) {
      for (final entry in raw.entries) {
        final at = DateTime.tryParse(entry.value as String? ?? '');
        if (at != null) out[entry.key] = at;
      }
    }
    return out;
  }

  bool covers(DateTime from, DateTime to) => !windowFrom.isAfter(from) && !windowTo.isBefore(to);

  bool isFresh(Duration? ttl) => ttl == null || DateTime.now().difference(fetchedAt) < ttl;
}

/// One parsed XMLTV file, with its fetch time and an index of programmes
/// by channel id (the `<programme channel="...">` attribute), so serving
/// one channel out of a whole-catalog file is a lookup, not a scan.
/// One source's fetch, in priority order (PlezTV 1.2.0, §3.1): the
/// provider feed or an added source. [cacheKey] is the guide's key in
/// [_xmltvCache] (`xtream:<id>` for the provider feed, the EPG URL for
/// a playlist guide, `user:<id>` for an added source); [keyPrefix]
/// names the source in programme keys.
/// What loading the enabled feeds produced (PlezTV 1.2.3): what loaded,
/// what failed (with its error), and what deferred (playback gate) — so
/// Reload / Update now can name each feed's outcome in their report
/// instead of silently dropping a failed source.
typedef _LoadedEpgFeeds = ({
  List<({ _EpgSourceAttempt attempt, _CachedXmltvGuide guide })> loaded,
  List<({ _EpgSourceAttempt attempt, Object error })> failures,
  List<_EpgSourceAttempt> deferred,
});

///
/// 1.2.2 I9: [fetchFeed] returns the response body as a byte stream plus
/// the conditional-fetch outcome. When [XmltvFeedFetcher.useValidators]
/// is true (the default) the fetcher sends the stored ETag /
/// Last-Modified for its feed; a 304 comes back as `notModified: true`
/// with an empty body. `useValidators: false` is the backstop — a 304
/// against no stored guide must be retried fresh, and a server cannot
/// 304 a request that sent no validators.
class _EpgSourceAttempt {
  final IptvEpgSourceConfig config;
  final String cacheKey;
  final String keyPrefix;
  final XmltvFeedFetcher fetchFeed;

  /// The User-Agent the feed request carries (1.2.15 R4): the Xtream
  /// API's effective User-Agent for the provider feed, and the same
  /// effective UA for M3U feeds (1.6.12 — the M3U fetch used to send no
  /// User-Agent header at all). Recorded in the download diagnostics so
  /// a panel that answers differently per client can be spotted.
  final String? userAgent;

  const _EpgSourceAttempt({
    required this.config,
    required this.cacheKey,
    required this.keyPrefix,
    required this.fetchFeed,
    this.userAgent,
  });
}

/// The sink half of a chunked SHA-256 (1.2.15 R4): [Hash.startChunkedConversion]
/// takes a [Sink] of digests, and the crypto package's own `DigestSink`
/// is not exported — this collects the one digest the conversion emits
/// on close. (`AccumulatorSink` is gone from this Dart SDK's
/// dart:convert, so it cannot stand in.)
class _DigestCollector implements Sink<crypto.Digest> {
  crypto.Digest? value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}

/// One EPG feed fetch attempt's fetcher (1.2.2 I9): returns the response
/// body as a byte stream plus the conditional-fetch outcome.
typedef XmltvFeedFetcher = Future<XmltvFeedFetch> Function(
  Future<void>? abortTrigger, {
  bool useValidators,
});

/// One loaded XMLTV feed: the metadata for the whole feed plus a
/// BOUNDED window of programmes (1.2.12, low-end item #4).
///
/// The old shape retained every in-window programme (~267k objects,
/// ~50-60 MB at Trex scale) plus six derived index maps built over
/// them. The windowed shape retains only:
/// - metadata for the whole feed (small): display names, the ids the
///   feed mentions, per-id programme counts, and a 30-minute slot
///   bitmap per id for exact "has programmes overlapping [from, to]"
///   checks; and
/// - the programmes of the window feed ids (the channels the guide is
///   actually looking at, plus a margin), capped at
///   [maxWindowFeedIds] ids.
///
/// The persisted feed file IS the store: a window slide re-parses it
/// The ten derived lookup indexes of a [_CachedXmltvGuide] (1.4 F1).
/// They depend only on the feed generation's metadata — the ids with
/// programmes plus the display names — never on the window rows. One
/// generation builds them once and every slide shares the reference,
/// instead of each slide rebuilding all ten over all 5,583 feed ids
/// (40.7 s of CPU in the 1.3.29 Fold session).
///
/// [buildCount] is the test seam: the 1.4 harness asserts a slide does
/// not raise it (reset via
/// [IptvLiveTvSupport.resetXmltvGuideIndexBuildCount]).
class _XmltvGuideIndexes {
  /// How many times the indexes have been built in this process.
  static int buildCount = 0;

  _XmltvGuideIndexes._({
    required this.foldedChannelIds,
    required this.numericChannelIds,
    required this.displayNameChannels,
    required this.normalizedNameChannels,
    required this.looseNameChannels,
    required this.wordChannels,
    required this.feedWordsById,
    required this.feedCountriesById,
    required this.mixedChannelIds,
    required this.looseMixedChannelIds,
  });

  /// Build the indexes from a generation's metadata. The builders are
  /// [_CachedXmltvGuide]'s static helpers (same library) — they are
  /// only ever called from here and from the old constructor path.
  factory _XmltvGuideIndexes.build(
    Iterable<String> idsWithPrograms,
    Map<String, List<String>> displayNames,
  ) {
    buildCount++;
    return _XmltvGuideIndexes._(
      foldedChannelIds: _CachedXmltvGuide._foldedChannelIds(idsWithPrograms),
      numericChannelIds: _CachedXmltvGuide._numericChannelIds(idsWithPrograms),
      displayNameChannels: _CachedXmltvGuide._channelsByDisplayName(displayNames),
      normalizedNameChannels: _CachedXmltvGuide._channelsByNormalizedName(idsWithPrograms),
      looseNameChannels: _CachedXmltvGuide._channelsByLooseName(idsWithPrograms, displayNames),
      mixedChannelIds: _CachedXmltvGuide._mixedChannelIds(displayNames),
      looseMixedChannelIds: _CachedXmltvGuide._mixedChannelIds(displayNames, loose: true),
      wordChannels: _CachedXmltvGuide._channelsByWord(idsWithPrograms, displayNames),
      feedWordsById: _CachedXmltvGuide._wordsByFeedId(idsWithPrograms, displayNames),
      feedCountriesById: _CachedXmltvGuide._countriesByFeedId(idsWithPrograms, displayNames),
    );
  }

  /// Fold -> raw feed id, for folds naming exactly one id (tier 3).
  final Map<String, String> foldedChannelIds;

  /// Numeric id -> raw feed id, for ids that parse as integers and
  /// name exactly one feed id (tier 4, the `streamId` lookup).
  final Map<int, String> numericChannelIds;

  /// Normalized display-name key -> feed ids carrying that display
  /// name (tier 5, F6A). Built from [displayNames] as before.
  final Map<String, Set<String>> displayNameChannels;

  /// Normalized feed-id key -> feed ids with programmes (tier 5).
  /// Built from the ids with programmes, as the old programme-derived
  /// index was.
  final Map<String, Set<String>> normalizedNameChannels;

  /// Loose-normalized key -> feed ids (tier 6, F5). The id side comes
  /// from the ids with programmes; the name side from [displayNames],
  /// as before.
  final Map<String, Set<String>> looseNameChannels;

  /// Word -> serving feed ids carrying that word in their id or in a
  /// display name (tier 5.5, the 1.3.29 affiliate guess). Built from
  /// the ids with programmes only, so a word lookup never returns a
  /// feed id with nothing to serve.
  final Map<String, Set<String>> wordChannels;

  /// Serving feed id -> the words its id and display names carry
  /// (tier 5.5 ranking: overlap and extra words). Precomputed at
  /// parse time so the tier does set arithmetic, not re-tokenizing,
  /// per channel — the Reload resolves ~26k channels against it.
  final Map<String, Set<String>> feedWordsById;

  /// Serving feed id -> the countries its id suffix or display-name
  /// tags name (tier 5.5 region gate). Precomputed for the same
  /// reason as [feedWordsById].
  final Map<String, Set<String>> feedCountriesById;

  /// Feed ids whose declared display names are NOT all one channel
  /// (F6B, 1.2.8).
  final Set<String> mixedChannelIds;
  final Set<String> looseMixedChannelIds;
}

/// One feed generation's shared guide metadata (1.4 F1): the raw maps
/// the derived indexes are built from, plus the indexes themselves.
/// Immutable per generation — a slide only swaps the window rows, so
/// it builds a guide from this bundle instead of re-reading the whole
/// `feed_channels` table and rebuilding all ten indexes. The bundle is
/// keyed by feed cacheKey + store generation (see
/// [_readFeedRowsFromStore]); a new generation replaces it, and the
/// relief valve / [IptvLiveTvSupport.clearEpgCache] drop it.
class _XmltvGuideMetadata {
  _XmltvGuideMetadata._({
    required this.displayNames,
    required this.programsParsed,
    required this.channelsParsed,
    required this.channelIdsSeen,
    required this.programCountByChannel,
    required this.programSlotsByChannel,
    required this.slotOriginEpoch,
    required this.totalProgramCount,
    required this.feedStoreBuildMs,
    required this.feedStoreBytes,
    required this.indexes,
  });

  /// Build the bundle from a full store read — the one read per
  /// generation that pays the metadata cost (and builds the indexes).
  factory _XmltvGuideMetadata.fromRead(FeedRowStoreGuide read) =>
      _XmltvGuideMetadata._(
        displayNames: read.displayNames,
        programsParsed: read.programsParsed,
        channelsParsed: read.channelsParsed,
        channelIdsSeen: read.channelIdsSeen,
        programCountByChannel: read.programCountByChannel,
        programSlotsByChannel: read.programSlotsByChannel,
        slotOriginEpoch: read.slotOriginEpoch,
        totalProgramCount: read.totalProgramCount,
        feedStoreBuildMs: null,
        feedStoreBytes: null,
        indexes: _XmltvGuideIndexes.build(
          read.programCountByChannel.keys,
          read.displayNames,
        ),
      );

  final Map<String, List<String>> displayNames;
  final int programsParsed;
  final int channelsParsed;
  final Set<String> channelIdsSeen;
  final Map<String, int> programCountByChannel;
  final Map<String, Uint8List> programSlotsByChannel;
  final int slotOriginEpoch;
  final int totalProgramCount;
  final int? feedStoreBuildMs;
  final int? feedStoreBytes;
  final _XmltvGuideIndexes indexes;

  /// A guide for this generation with [windowByChannel] as its window
  /// — the slide's cheap construction (no metadata re-read, no index
  /// rebuild).
  _CachedXmltvGuide guide({
    required DateTime fetchedAt,
    required Map<String, List<XmltvProgram>> windowByChannel,
  }) =>
      _CachedXmltvGuide(
        fetchedAt: fetchedAt,
        displayNames: displayNames,
        programsParsed: programsParsed,
        channelsParsed: channelsParsed,
        channelIdsSeen: channelIdsSeen,
        programCountByChannel: programCountByChannel,
        programSlotsByChannel: programSlotsByChannel,
        slotOriginEpoch: slotOriginEpoch,
        totalProgramCount: totalProgramCount,
        windowByChannel: windowByChannel,
        feedStoreBuildMs: feedStoreBuildMs,
        feedStoreBytes: feedStoreBytes,
        indexes: indexes,
      );
}

/// with a new window instead of re-downloading it. The match chain
/// resolves feed ids from the metadata (no rows needed) and only the
/// matched id's rows are ever read, through [rowsFor].
///
/// The metadata-only indexes below are derived exactly as the old
/// programme-derived ones were, so matching behaviour is unchanged:
/// the name/loose/display-name indexes come from [displayNames] (all
/// entries, as before), while the id-derived indexes come from the ids
/// with programmes ([programCountByChannel] keys — the old indexes
/// were built over programme rows, so an id with no retained
/// programmes was never in them).
class _CachedXmltvGuide {
  final DateTime fetchedAt;

  /// Display names per feed id, as declared in the feed (same as
  /// before — needed by the name/loose match tiers and the Assign
  /// picker).
  final Map<String, List<String>> displayNames;

  /// Programmes seen in the I8 parse window (post-dedupe), and the
  /// number of distinct feed ids parsed. These are the Reload
  /// feed-summary numbers (previously `programs.length` and
  /// `byChannel.length`).
  final int programsParsed;
  final int channelsParsed;

  /// Every feed id the parser saw (including ids whose programmes all
  /// fell outside the I8 window — Fix 6, 1.2.5). Used by the match
  /// tiers' identified-but-empty bookkeeping.
  final Set<String> channelIdsSeen;

  /// Programmes per feed id in the I8 parse window, post-dedupe
  /// (1.2.1 D3). The count the Reload feed sample and the source
  /// status used to read from `byChannel[id].length`.
  final Map<String, int> programCountByChannel;

  /// 30-minute slot bitmap per feed id over the I8 parse window (slot
  /// 0 starts at [slotOriginEpoch]): a set bit means the id has a
  /// programme overlapping that slot. The overlap test is exact at
  /// slot granularity — a programme overlapping [from, to) always
  /// shares a slot with it, so [hasProgramsInWindow] answers exactly
  /// what mapping the rows would have answered, without holding them.
  final Map<String, Uint8List> programSlotsByChannel;

  /// Epoch seconds of slot 0 in [programSlotsByChannel] — the I8
  /// window start at parse time.
  final int slotOriginEpoch;

  /// Total programmes retained in the I8 window across the whole
  /// feed (post-dedupe). The Reload feed summary's programme total
  /// (previously `programs.length`).
  final int totalProgramCount;

  /// Programmes retained for the window feed ids only. Keyed by feed
  /// id; each list is deduped by (channel, start) at import (1.2.1
  /// D3). Bounded: a window load replaces the whole map, capped at
  /// [maxWindowFeedIds] ids — never the whole feed.
  final Map<String, List<XmltvProgram>> windowByChannel;

  /// Row-store build cost for the parse that produced this guide
  /// (1.2.20 (a)): the isolate's store-build wall time in ms and the
  /// final DB size in bytes. Null when no store was built (in-memory
  /// fallback, low storage, or the test seam) or when the build
  /// failed (`feedStoreBuildMs` set, `feedStoreBytes` null).
  final int? feedStoreBuildMs;
  final int? feedStoreBytes;

  /// Feed ids with programmes (the old `byChannel` key set): derived
  /// from [programCountByChannel].
  Set<String> get feedIdsWithPrograms => programCountByChannel.keys.toSet();

  /// How many programmes the window currently retains (the debug
  /// bound assertion reads this).
  int get windowProgramCount =>
      windowByChannel.values.fold(0, (sum, rows) => sum + rows.length);

  /// The window's feed ids.
  Set<String> get windowFeedIds => windowByChannel.keys.toSet();

  /// Retained rows for [feedId], or empty when the id has no retained
  /// programmes or is not in the window. An empty result is
  /// ambiguous — use [hasRetainedPrograms] to tell "genuinely no
  /// programmes" from "not in the window".
  List<XmltvProgram> rowsFor(String feedId) => windowByChannel[feedId] ?? const [];

  /// True when [feedId] has retained programmes in the I8 window
  /// (the old `byChannel.containsKey(id)`).
  bool hasRetainedPrograms(String feedId) => (programCountByChannel[feedId] ?? 0) > 0;

  /// True when [feedId] has a programme overlapping [from, to) —
  /// the bulk (no-row) form of the old
  /// `mapPrograms(byChannel[id]).isNotEmpty` check. Exact at slot
  /// granularity: any programme overlapping the range shares a slot
  /// with it, and a set slot always comes from a programme
  /// overlapping that slot.
  bool hasProgramsInWindow(String feedId, DateTime from, DateTime to) {
    final slots = programSlotsByChannel[feedId];
    if (slots == null) return false;
    final fromSlot = _slotIndexFor(from);
    final toSlot = _slotIndexFor(to);
    final lo = fromSlot.clamp(0, slots.length - 1);
    final hi = toSlot.clamp(0, slots.length - 1);
    if (lo > hi) return false;
    for (var i = lo; i <= hi; i++) {
      if (slots[i] != 0) return true;
    }
    return false;
  }

  /// The nearest programme start (30-minute granularity) at or after
  /// [around], or the latest slot before it when nothing follows —
  /// the F2 diagnostic's "nearest programme outside the window" (the
  /// old code read `byChannel[id]`'s rows for this; the bitmap gives
  /// the same answer to the slot).
  DateTime? nearestProgramStart(String feedId, DateTime around) {
    final slots = programSlotsByChannel[feedId];
    if (slots == null) return null;
    final aroundSlot = _slotIndexFor(around);
    for (var i = aroundSlot; i < slots.length; i++) {
      if (slots[i] != 0) return _slotStart(i);
    }
    for (var i = aroundSlot - 1; i >= 0; i--) {
      if (slots[i] != 0) return _slotStart(i);
    }
    return null;
  }

  int _slotIndexFor(DateTime at) =>
      ((at.millisecondsSinceEpoch ~/ 1000) - slotOriginEpoch) ~/ slotSeconds;

  DateTime _slotStart(int slot) =>
      DateTime.fromMillisecondsSinceEpoch((slotOriginEpoch + slot * slotSeconds) * 1000);

  /// Maximum feed ids whose rows the window holds. A window load
  /// replaces the whole window, so this is a hard bound on retained
  /// programmes per feed, not an LRU. 1.2.19 L-7: per-tier — 0 on T0
  /// (no feed at all), 16 on T1, 32 on T2, 64 on T3/T4.
  static int get maxWindowFeedIds => DevicePerformance.epgWindowFeedIds;

  /// Slot width for [programSlotsByChannel]: 30 minutes. A programme
  /// of up to ~2 hours touches at most ~5 slots.
  static const int slotSeconds = 1800;

  /// Number of slots in the bitmap, from the I8 window span.
  static int slotCountFor(DateTime windowFrom, DateTime windowTo) {
    final spanSeconds = windowTo.difference(windowFrom).inSeconds;
    return (spanSeconds / slotSeconds).ceil() + 1;
  }

  _CachedXmltvGuide({
    required this.fetchedAt,
    required this.displayNames,
    required this.programsParsed,
    required this.channelsParsed,
    required this.channelIdsSeen,
    required this.programCountByChannel,
    required this.programSlotsByChannel,
    required this.slotOriginEpoch,
    required this.totalProgramCount,
    required this.windowByChannel,
    this.feedStoreBuildMs,
    this.feedStoreBytes,
    // 1.4 F1: a pre-built index set for this generation. When null the
    // constructor builds one (the parse path: once per download). A
    // slide passes the cached set instead, so it never rebuilds.
    _XmltvGuideIndexes? indexes,
  }) : _indexes = indexes ?? _XmltvGuideIndexes.build(programCountByChannel.keys, displayNames);

  /// The shared derived indexes for this guide's generation (1.4 F1).
  final _XmltvGuideIndexes _indexes;

  /// Copy with a new fetchedAt (the 304 path reuses the same guide
  /// object — metadata and window unchanged). The shared indexes are
  /// reused too (1.4 F1): a copy must not rebuild them.
  _CachedXmltvGuide withFetchedAt(DateTime at) => _CachedXmltvGuide(
        fetchedAt: at,
        displayNames: displayNames,
        programsParsed: programsParsed,
        channelsParsed: channelsParsed,
        channelIdsSeen: channelIdsSeen,
        programCountByChannel: programCountByChannel,
        programSlotsByChannel: programSlotsByChannel,
        slotOriginEpoch: slotOriginEpoch,
        totalProgramCount: totalProgramCount,
        windowByChannel: windowByChannel,
        feedStoreBuildMs: feedStoreBuildMs,
        feedStoreBytes: feedStoreBytes,
        indexes: _indexes,
      );

  /// Fold -> raw feed id, for folds naming exactly one id (tier 3).
  Map<String, String> get foldedChannelIds => _indexes.foldedChannelIds;

  /// Numeric id -> raw feed id, for ids that parse as integers and
  /// name exactly one feed id (tier 4, the `streamId` lookup).
  Map<int, String> get numericChannelIds => _indexes.numericChannelIds;

  /// Normalized display-name key -> feed ids carrying that display
  /// name (tier 5, F6A). Built from [displayNames] as before.
  Map<String, Set<String>> get displayNameChannels => _indexes.displayNameChannels;

  /// Normalized feed-id key -> feed ids with programmes (tier 5).
  /// Built from the ids with programmes, as the old programme-derived
  /// index was.
  Map<String, Set<String>> get normalizedNameChannels => _indexes.normalizedNameChannels;

  /// Loose-normalized key -> feed ids (tier 6, F5). The id side comes
  /// from the ids with programmes; the name side from [displayNames],
  /// as before.
  Map<String, Set<String>> get looseNameChannels => _indexes.looseNameChannels;

  /// Word -> serving feed ids carrying that word in their id or in a
  /// display name (tier 5.5, the 1.3.29 affiliate guess). Built from
  /// the ids with programmes only, so a word lookup never returns a
  /// feed id with nothing to serve.
  Map<String, Set<String>> get wordChannels => _indexes.wordChannels;

  /// Serving feed id -> the words its id and display names carry
  /// (tier 5.5 ranking: overlap and extra words). Precomputed at
  /// parse time so the tier does set arithmetic, not re-tokenizing,
  /// per channel — the Reload resolves ~26k channels against it.
  Map<String, Set<String>> get feedWordsById => _indexes.feedWordsById;

  /// Serving feed id -> the countries its id suffix or display-name
  /// tags name (tier 5.5 region gate). Precomputed for the same
  /// reason as [feedWordsById].
  Map<String, Set<String>> get feedCountriesById => _indexes.feedCountriesById;

  /// Feed ids whose declared display names are NOT all one channel
  /// (F6B, 1.2.8).
  Set<String> get mixedChannelIds => _indexes.mixedChannelIds;
  Set<String> get looseMixedChannelIds => _indexes.looseMixedChannelIds;

  /// Feed ids whose display names or normalized id match [normalized]
  /// (tier 5 candidates — ids with programmes only, via the
  /// metadata indexes; the caller loads rows for the chosen id).
  Set<String> nameCandidatesFor(String normalized) {
    final ids = <String>{};
    final display = displayNameChannels[normalized];
    if (display != null) ids.addAll(display);
    final byId = normalizedNameChannels[normalized];
    if (byId != null) ids.addAll(byId);
    ids.removeWhere((id) => mixedChannelIds.contains(id));
    return ids;
  }

  /// Feed ids matching [loose] by loose name (tier 6 candidates).
  Set<String> looseCandidatesFor(String loose) {
    final ids = <String>{};
    final matches = looseNameChannels[loose];
    if (matches != null) ids.addAll(matches);
    ids.removeWhere((id) => looseMixedChannelIds.contains(id));
    return ids;
  }

  /// Serving feed ids carrying [word] in their id or a display name
  /// (tier 5.5 candidates — the word index, built from the ids with
  /// programmes only).
  Set<String> wordCandidatesFor(String word) {
    final ids = wordChannels[word];
    if (ids == null) return const <String>{};
    return ids.toSet();
  }

  static Map<String, String> _foldedChannelIds(Iterable<String> ids) {
    final byFold = <String, Set<String>>{};
    for (final id in ids) {
      byFold.putIfAbsent(id.toLowerCase(), () => <String>{}).add(id);
    }
    final out = <String, String>{};
    for (final entry in byFold.entries) {
      if (entry.value.length == 1) out[entry.key] = entry.value.single;
    }
    return out;
  }

  static Map<int, String> _numericChannelIds(Iterable<String> ids) {
    final byNumeric = <int, Set<String>>{};
    for (final id in ids) {
      final numeric = int.tryParse(id);
      if (numeric == null || numeric <= 0) continue;
      byNumeric.putIfAbsent(numeric, () => <String>{}).add(id);
    }
    final out = <int, String>{};
    for (final entry in byNumeric.entries) {
      if (entry.value.length == 1) out[entry.key] = entry.value.single;
    }
    return out;
  }

  static Map<String, Set<String>> _channelsByDisplayName(Map<String, List<String>> displayNames) {
    final map = <String, Set<String>>{};
    for (final entry in displayNames.entries) {
      for (final name in entry.value) {
        final key = normalizeEpgChannelName(name);
        if (key.isEmpty) continue;
        (map[key] ??= <String>{}).add(entry.key);
        // 1.2.22 §64.2: index the sports-folded form too, so a playlist
        // "SKY SPORT NEWS" finds a feed "Sky Sports News" in tier 5.
        final foldedKey = sportsFoldedEpgChannelNameKey(name);
        if (foldedKey.isNotEmpty && foldedKey != key) {
          (map[foldedKey] ??= <String>{}).add(entry.key);
        }
      }
    }
    return map;
  }

  static Map<String, Set<String>> _channelsByNormalizedName(Iterable<String> ids) {
    final map = <String, Set<String>>{};
    for (final id in ids) {
      final key = normalizeEpgChannelName(id);
      if (key.isEmpty) continue;
      (map[key] ??= <String>{}).add(id);
      // 1.2.22 §64.2: index the sports-folded form too (see above).
      final foldedKey = sportsFoldedEpgChannelNameKey(id);
      if (foldedKey.isNotEmpty && foldedKey != key) {
        (map[foldedKey] ??= <String>{}).add(id);
      }
    }
    return map;
  }

  static Map<String, Set<String>> _channelsByLooseName(
    Iterable<String> ids,
    Map<String, List<String>> displayNames,
  ) {
    final map = <String, Set<String>>{};
    void add(String name, String channelId) {
      final key = looseEpgChannelNameKey(name);
      if (key.isEmpty) return;
      (map[key] ??= <String>{}).add(channelId);
    }

    for (final id in ids) {
      add(id, id);
    }
    for (final entry in displayNames.entries) {
      for (final name in entry.value) {
        add(name, entry.key);
      }
    }
    return map;
  }

  /// Word -> serving feed ids (tier 5.5): every word the id or a
  /// display name carries, for the ids with programmes only. A display
  /// name belonging to an id with no programmes contributes nothing —
  /// the tier only ever serves ids with retained programmes.
  static Map<String, Set<String>> _channelsByWord(
    Iterable<String> ids,
    Map<String, List<String>> displayNames,
  ) {
    final serving = ids.toSet();
    final map = <String, Set<String>>{};
    void addWords(Iterable<String> words, String channelId) {
      for (final word in words) {
        (map[word] ??= <String>{}).add(channelId);
      }
    }

    for (final id in serving) {
      addWords(epgChannelNameWords(id), id);
    }
    for (final entry in displayNames.entries) {
      if (!serving.contains(entry.key)) continue;
      for (final name in entry.value) {
        addWords(epgChannelNameWords(name), entry.key);
      }
    }
    return map;
  }

  /// Serving feed id -> its words (tier 5.5 ranking), from the id
  /// plus every display name.
  static Map<String, Set<String>> _wordsByFeedId(
    Iterable<String> ids,
    Map<String, List<String>> displayNames,
  ) {
    final map = <String, Set<String>>{};
    for (final id in ids) {
      final words = <String>{...epgChannelNameWords(id)};
      for (final name in displayNames[id] ?? const <String>[]) {
        words.addAll(epgChannelNameWords(name));
      }
      map[id] = words;
    }
    return map;
  }

  /// Serving feed id -> its countries (tier 5.5 region gate), from
  /// the id suffix plus every display name's leading tag.
  static Map<String, Set<String>> _countriesByFeedId(
    Iterable<String> ids,
    Map<String, List<String>> displayNames,
  ) {
    final map = <String, Set<String>>{};
    for (final id in ids) {
      map[id] = epgFeedChannelCountries(id, displayNames[id] ?? const <String>[]);
    }
    return map;
  }

  /// A feed id is "mixed" when its declared display names are not
  /// all one channel (jellyfin `_one_channel`, Fix 7): no channel is
  /// matched by name through one. With `loose`, the loose key decides.
  static Set<String> _mixedChannelIds(Map<String, List<String>> displayNames, {bool loose = false}) {
    final mixed = <String>{};
    for (final entry in displayNames.entries) {
      final names = entry.value;
      if (names.length < 2) continue;
      final one = loose
          ? epgDisplayNamesAreOneChannel(names, loose: true)
          : epgDisplayNamesAreOneChannel(names);
      if (!one) mixed.add(entry.key);
    }
    return mixed;
  }
}

/// One-pass accumulator for a feed parse (1.2.12, low-end item #4):
/// the streaming parser hands programmes over one at a time and this
/// builds the guide's metadata (counts, slot bitmaps) plus the window
/// rows in that single pass — the whole feed is never held as a list.
///
/// Dedupe by (channel, start) at import (1.2.1 D3, tvheadend model):
/// a provider that re-publishes a programme must not render it
/// twice. First-wins, via one transient Set (the old constructor's
/// `_dedupePrograms`); counts are post-dedupe.
///
/// [retainIds] is the window: rows are kept only for these feed ids.
/// Pass an empty set for a metadata-only load (Reload, update-now,
/// Assign, overview — they never read rows).
class _XmltvGuideAccumulator {
  final Set<String> retainIds;
  final int _slotCount;
  final int _originEpoch;
  final Map<String, int> _counts = {};
  final Map<String, Uint8List> _slots = {};
  final Map<String, List<XmltvProgram>> _window = {};
  // 1.2.18 S-5: the dedupe set held one interpolated String per
  // programme (282k strings per feed parse, ~15-30 MB transient).
  // A 64-bit hash of (channel, start) answers the same question —
  // a collision would drop one programme, at ~2e-9 odds for a
  // 282k-programme feed, and never corrupts the guide.
  final Set<int> _seen = {};
  int _total = 0;

  /// The per-id programme counts, slot bitmaps, and retained total —
  /// what the row-store build (1.2.20 (a)) writes into `feed_channels`
  /// + `feed_meta` at the end of the parse. Exposed (read-only) so the
  /// parse isolate can hand them to the writer without breaking the
  /// accumulator's encapsulation.
  Map<String, int> get programCounts => _counts;
  Map<String, Uint8List> get programSlots => _slots;
  int get totalPrograms => _total;

  _XmltvGuideAccumulator({
    required this.retainIds,
    required DateTime windowFrom,
    required DateTime windowTo,
  })  : _slotCount = _CachedXmltvGuide.slotCountFor(windowFrom, windowTo),
        _originEpoch = windowFrom.millisecondsSinceEpoch ~/ 1000;

  void add(XmltvProgram program) {
    if (!_seen.add(Object.hash(program.channelId, program.startEpoch))) return;
    _total++;
    _counts[program.channelId] = (_counts[program.channelId] ?? 0) + 1;
    final bitmap = _slots.putIfAbsent(
      program.channelId,
      () => Uint8List(_slotCount),
    );
    final fromSlot = ((program.startEpoch - _originEpoch) ~/ _CachedXmltvGuide.slotSeconds).clamp(0, _slotCount - 1);
    final toSlot = ((program.stopEpoch - _originEpoch) ~/ _CachedXmltvGuide.slotSeconds).clamp(0, _slotCount - 1);
    for (var i = fromSlot; i <= toSlot; i++) {
      bitmap[i] = 1;
    }
    if (retainIds.contains(program.channelId)) {
      (_window[program.channelId] ??= []).add(program);
    }
  }

  _CachedXmltvGuide build({
    required DateTime fetchedAt,
    required Map<String, List<String>> displayNames,
    required int programsParsed,
    required int channelsParsed,
    required Set<String> channelIdsSeen,
    int? feedStoreBuildMs,
    int? feedStoreBytes,
  }) =>
      _CachedXmltvGuide(
        fetchedAt: fetchedAt,
        displayNames: displayNames,
        programsParsed: programsParsed,
        channelsParsed: channelsParsed,
        channelIdsSeen: channelIdsSeen,
        programCountByChannel: _counts,
        programSlotsByChannel: _slots,
        slotOriginEpoch: _originEpoch,
        totalProgramCount: _total,
        windowByChannel: _window,
        feedStoreBuildMs: feedStoreBuildMs,
        feedStoreBytes: feedStoreBytes,
      );
}

/// Appends every decoded chunk to [out] as it arrives (1.3.28): the
/// 256 KB validation cap can cut a gzip member mid-stream, so the sink
/// must not wait for close() to deliver anything.
class _CollectingByteSink implements ChunkedConversionSink<List<int>> {
  final List<int> out;
  _CollectingByteSink(this.out);

  @override
  void add(List<int> chunk) => out.addAll(chunk);

  @override
  void close() {}
}
