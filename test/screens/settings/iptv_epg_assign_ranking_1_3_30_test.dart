// 1.3.30 — bug 2: the Assign page does not rank the closest
// matches on top. Written failing-first against the 1.3.29 base
// (9ada155e4).
//
// What the phone proved (screenshot + debug log 20261117-233440):
// for a St. Louis FOX channel the Assign list opens with
// Canadian / Polish / Latin channels and the US FOX affiliates sit
// at the bottom. The 1.3.26 ranking IS applied to the default list,
// but all three discriminators tie:
//   - idScore 0 (the channel has no epg/tvg id),
//   - regionScore 0 (every candidate's country set is {} — the
//     detectors miss `CA|` / `CND|` prefixes and `, ON` / `, MN`
//     suffixes; and the channel's own country is misparsed as `tv`
//     from the `TV|` category prefix),
//   - nameScore 1 for ALL (the bare number `2` in "FOX 2" counts
//     exactly as much as `fox`),
// so it falls back to alphabetical.
//
// This file proves, with the exact screenshot case (pure function,
// so it compiles on base):
//   R1: the St. Louis FOX channel's own affiliate
//       (loc.FOX (KTVI) St. Louis, MO) tops the list.
//   R2: the other US FOX affiliate (loc.FOX (KMSP-DT9) Minneapolis,
//       MN) is second, and the Latin FOX DEPORTES — which shares
//       only the word `fox` and has no detectable country — is third.
//   R3: every channel that shares only the number `2` sits below
//       every channel that shares `fox`.
//   R4: the wrong-region (Canadian) channels sit at the bottom.
// Fixtures are invented (invented ids shaped like the screenshot's)
// — no live panel use, no real panel values.

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_epg_sources.dart';

/// The owner's screenshot case: Assign opened for a St. Louis FOX
/// channel, no epg/tvg id. The entries are the ten rows visible in
/// the screenshot plus the channel's own affiliate (which the feed
/// carries but the list buried at the bottom).
List<IptvEpgFeedChannel> _stLouisFoxEntries() => const [
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'ca.CHCH Hamilton, ON', programCount: 56, displayNames: ['CND| CHCH HD (2)']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'ca.OMNI.1 HD', programCount: 33, displayNames: ['CND| OMNI 2 HD']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'Canal+ Extra 2', programCount: 17, displayNames: ['PLAY+| CANAL+ EXTRA 2 RAW']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'Canal+ Sport 2', programCount: 48, displayNames: ['PLAY+| CANAL+ SPORT 2 RAW']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'CA| CRAVE 2 / TMN 2', programCount: 33, displayNames: ['CND| CRAVE 2 HD']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'Eleven Sports 2', programCount: 26, displayNames: ['PL-VIP| ELEVEN SPORTS 2 RAW']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'la.Canal 2 de Panamá (TVN-2)', programCount: 45, displayNames: ['LAT| TVN (PA)']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'la.Canal Fox Deportes', programCount: 16, displayNames: ['LAT| FOX DEPORTES HD']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'LAT| HISTORY 2 HD', programCount: 36, displayNames: ['LAT| HISTORY 2 HD']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'loc.FOX (KMSP-DT9) Minneapolis, MN', programCount: 41, displayNames: ['NFL FOX VIKINGS MINNEAPOLIS MN']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'loc.FOX (KTVI) St. Louis, MO', programCount: 44, displayNames: ['KTVI FOX 2 St. Louis']),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<String> rankedIds() => rankEpgFeedChannels(
    entries: _stLouisFoxEntries(),
    channelName: 'TV| ST. LOUIS, MO KTVI FOX 2',
  ).map((e) => e.xmltvId).toList();

  group('rankEpgFeedChannels — St. Louis FOX, no id (1.3.30 bug 2)', () {
    test('R1+R2 the US FOX affiliates top the list, own affiliate first', () {
      final ids = rankedIds();
      expect(ids[0], 'loc.FOX (KTVI) St. Louis, MO', reason: 'the channel\'s own affiliate — region-correct and the closest name — tops the list');
      expect(ids[1], 'loc.FOX (KMSP-DT9) Minneapolis, MN', reason: 'the other US FOX affiliate is second');
      expect(ids[2], 'la.Canal Fox Deportes', reason: 'FOX DEPORTES shares only `fox` and has no detectable country, so it sits below the US affiliates');
    });

    test('R3 channels sharing only the number 2 sit below every fox-sharing channel', () {
      final ids = rankedIds();
      final foxSharers = ids.take(3).toList();
      expect(foxSharers, ['loc.FOX (KTVI) St. Louis, MO', 'loc.FOX (KMSP-DT9) Minneapolis, MN', 'la.Canal Fox Deportes']);
      // Everything after the fox-sharers shares at most the bare
      // number `2` with the channel — on base the `2` counted as
      // much as `fox` and these rows opened the list.
      for (final id in ids.skip(3)) {
        expect(id, isNot(startsWith('loc.FOX')), reason: 'no affiliate is buried below a number-only match');
      }
    });

    test('R4 the wrong-region channels sit at the bottom', () {
      final ids = rankedIds();
      // The wrong-region group is four, not three: Eleven Sports 2
      // is Polish here — its `PL-VIP|` tag parses as Poland — so it
      // sits with the Canadian channels at the bottom, below every
      // neutral channel, even though its name shares only `2`.
      expect(ids.sublist(ids.length - 4), [
        'ca.CHCH Hamilton, ON',
        'ca.OMNI.1 HD',
        'CA| CRAVE 2 / TMN 2',
        'Eleven Sports 2',
      ]);
      expect(
        ids,
        [
          'loc.FOX (KTVI) St. Louis, MO',
          'loc.FOX (KMSP-DT9) Minneapolis, MN',
          'la.Canal Fox Deportes',
          'Canal+ Extra 2',
          'Canal+ Sport 2',
          'la.Canal 2 de Panamá (TVN-2)',
          'LAT| HISTORY 2 HD',
          'ca.CHCH Hamilton, ON',
          'ca.OMNI.1 HD',
          'CA| CRAVE 2 / TMN 2',
          'Eleven Sports 2',
        ],
        reason: 'region-correct first, then neutral, then wrong-region — never alphabetical',
      );
    });
  });
}
