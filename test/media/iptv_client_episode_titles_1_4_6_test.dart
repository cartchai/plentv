// 1.4.6 downloads grouping — G1: the Xtream episode builder must carry
// Plex-shaped hierarchy titles (show ← grandparentTitle, season ←
// parentTitle), so the Downloads tree groups episodes under the series
// name and a "Season N" row instead of the series name twice.
//
// FAILING-FIRST: on the 1.4.5 base the builder puts the series name in
// parentTitle and leaves grandparentTitle unset, so the show row renders
// "Unknown Show" and the season row renders the series name (the user's
// screenshot). No live panel use: the builder is driven through the
// debugEpisodeItem seam with canned series/episode data; the stream URL
// is built by pure string concatenation, no request is made.
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
  const episode = XtreamEpisode(id: 3823, episodeNum: 1, title: 'Cartman Gets an Anal Probe');

  group('1.4.6 G1: Xtream episode hierarchy titles', () {
    test('show row = series name, season row = "Season 1"', () {
      final item = client().debugEpisodeItem(series, episode, 1);

      expect(item.grandparentTitle, 'South Park', reason: 'the Downloads tree reads the show name from grandparentTitle');
      expect(item.parentTitle, 'Season 1', reason: 'the Downloads tree reads the season label from parentTitle');
      expect(item.grandparentId, '123');
    });

    test('season number follows the season argument, not the episode number', () {
      final item = client().debugEpisodeItem(series, const XtreamEpisode(id: 3900, episodeNum: 3, title: 'Third'), 2);

      expect(item.grandparentTitle, 'South Park');
      expect(item.parentTitle, 'Season 2');
      expect(item.parentIndex, 2);
      expect(item.index, 3);
    });

    test('grandparentTitle is the STRIPPED series name (category prefix removed)', () {
      const prefixed = XtreamSeries(seriesId: 123, name: 'Animation - South Park');
      final item = client().debugEpisodeItem(prefixed, episode, 1, seriesCategoryName: 'Animation');

      expect(item.grandparentTitle, 'South Park');
      expect(item.parentTitle, 'Season 1');
    });

    test('the episode title itself is untouched', () {
      final item = client().debugEpisodeItem(series, episode, 1);

      expect(item.title, 'Cartman Gets an Anal Probe');
      expect(item.id, 'episode:123:3823');
    });
  });
}
