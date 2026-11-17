// 1.3.26 §69 — the Assign EPG candidate list ranks by RELEVANCE,
// best matches at the top, not alphabetical. PURE-FUNCTION proofs
// (the screen proof lives in
// iptv_epg_assign_ranking_screen_1_3_26_test.dart, which references
// no new APIs and so fails by assertion on base).
//
// The owner opened Assign for a US channel (KTVI FOX 2, St. Louis)
// and the list at the top was NL / AU / ISR / PL / FR guide channels
// in plain alphabetical order, nothing to do with FOX 2. The ranking
// signals: (1) channel-id match (exact, or a shared prefix of at
// least 3 chars) ranks highest; (2) region correctness — a candidate
// from the channel's country ranks above one from a different
// country, and a candidate whose region cannot be determined sits
// between them; (3) name word overlap; (4) xmltvId ascending, so the
// order is deterministic. Region sits above name even though the
// owner listed name second: his own rule is that a candidate from
// the WRONG region must rank below a region-matching candidate even
// if its name is closer.
//
// Failing-first on the 1.3.25 base (6b46c2d35, via
// `git stash push --keep-index`): this file fails to load
// (`rankEpgFeedChannels` is new — a load failure counts as
// failing-first for a file introducing a new API).

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_epg_sources.dart';

/// The owner's screenshot case: a US FOX 2 (KTVI, St. Louis) with
/// foreign FOX 2 guide channels crowding the top alphabetically.
List<IptvEpgFeedChannel> _fox2Entries() => const [
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'fox2.nl', programCount: 10, displayNames: ['FOX 2 NL']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'fox2.au', programCount: 10, displayNames: ['FOX 2 AU']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'fox2.il', programCount: 10, displayNames: ['FOX 2']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'fox2.pl', programCount: 10, displayNames: ['FOX 2 PL']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'fox2.fr', programCount: 10, displayNames: ['FOX 2 FR']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'ktvi-fox2.us', programCount: 10, displayNames: ['KTVI FOX 2 St. Louis']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'fox2.us', programCount: 10, displayNames: ['FOX 2']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'wjbktv.us', programCount: 10, displayNames: ['FOX 2 Detroit']),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('rankEpgFeedChannels (pure function)', () {
    test('a US FOX 2 puts US guide channels on top, foreign below', () {
      final ranked = rankEpgFeedChannels(
        entries: _fox2Entries(),
        channelName: 'US: KTVI FOX 2 St. Louis',
        channelEpgId: 'ktvi-fox2.us',
      );
      final ids = ranked.map((e) => e.xmltvId).toList();
      // Exact id match first, then the US entries (region-correct,
      // name-matched, alphabetical tiebreak), then the foreign
      // entries — alphabetically among themselves, but BELOW every
      // US entry even though their names are just as close.
      expect(ids, [
        'ktvi-fox2.us',
        'fox2.us',
        'wjbktv.us',
        'fox2.au',
        'fox2.fr',
        'fox2.il',
        'fox2.nl',
        'fox2.pl',
      ]);
    });

    test('a wrong-region candidate ranks below a region match even with a closer name', () {
      final ranked = rankEpgFeedChannels(
        entries: const [
          IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'cnn.nl', programCount: 1, displayNames: ['CNN']),
          IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'cnnnews.us', programCount: 1, displayNames: ['CNN News']),
        ],
        channelName: 'US - CNN HD',
      );
      // 'cnn.nl' shares the whole name but is NL; 'cnnnews.us' is US
      // with one shared word — region beats name.
      expect(ranked.map((e) => e.xmltvId).toList(), ['cnnnews.us', 'cnn.nl']);
    });

    test('with no country anywhere the ranking falls back to id + name words', () {
      final ranked = rankEpgFeedChannels(
        entries: const [
          IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'zzz', programCount: 1, displayNames: ['ZZZ']),
          IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'cnn', programCount: 1, displayNames: ['CNN']),
        ],
        channelName: 'CNN',
      );
      expect(ranked.map((e) => e.xmltvId).toList(), ['cnn', 'zzz']);
    });

    test('a prefix id match (shared prefix of 3+) ranks above a name match', () {
      final ranked = rankEpgFeedChannels(
        entries: const [
          IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'other', programCount: 1, displayNames: ['CNN']),
          IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'cnn-extra', programCount: 1, displayNames: ['Something Else']),
        ],
        channelName: 'CNN',
        channelEpgId: 'cnn',
      );
      // 'cnn-extra' shares the 'cnn' prefix with the channel id;
      // 'other' only shares the name.
      expect(ranked.map((e) => e.xmltvId).toList(), ['cnn-extra', 'other']);
    });
  });
}
