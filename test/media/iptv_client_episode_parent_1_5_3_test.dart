// 1.5.3 K1: an Xtream episode leaf must point at its per-season parent
// (`season:<seriesId>:<n>`), not at the show (`series:<seriesId>`), or
// Downloads merges every season of a show into one row.
//
// FAILING-FIRST: on the 1.5.2 base _episodeItem sets parentId to the show
// for every episode regardless of season, so both assertions below fail.
// No live panel use: the builder is driven through the debugEpisodeItem
// seam with canned series/episode data; the stream URL is built by pure
// string concatenation, no request is made.
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

void main() {
  IptvClient client() => IptvClient.xtream(
    xtreamConnection: XtreamConnection(
      id: 'xtream-1',
      name: 'Test',
      serverUrl: 'https://example.test',
      username: 'user',
      password: 'pa' 'ss',
      createdAt: DateTime(2026, 1, 1),
    ),
  );

  const series = XtreamSeries(seriesId: 123, name: 'South Park');

  group('1.5.3 K1: Xtream episode parentId points at its season', () {
    test('season 1 episode points at season:123:1', () {
      final item = client().debugEpisodeItem(
        series,
        const XtreamEpisode(id: 3823, episodeNum: 1, title: 'Cartman Gets an Anal Probe'),
        1,
      );

      expect(item.parentId, 'season:123:1', reason: 'the Downloads tree groups seasons by parentId');
      expect(item.grandparentId, '123');
      expect(item.parentTitle, 'Season 1');
      expect(item.parentIndex, 1);
    });

    test('season 2 episode points at season:123:2, not the show', () {
      final item = client().debugEpisodeItem(
        series,
        const XtreamEpisode(id: 3900, episodeNum: 1, title: 'Second Season Opener'),
        2,
      );

      expect(item.parentId, 'season:123:2', reason: 'same show, different season must not share a parentId');
      expect(item.grandparentId, '123');
      expect(item.parentTitle, 'Season 2');
      expect(item.parentIndex, 2);
    });
  });
}
