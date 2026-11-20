import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/settings_service.dart' show EpisodePosterMode;

// 1.6.11 X9 — in episode-thumbnail mode the card shows the episode still;
// when the still cannot be served, the fallback is the show poster
// instead of a black tile.
//
// Failing-first shape: on base, `posterThumbFallback` returns null in
// episode-thumbnail mode, so both expectations fail there.
void main() {
  test('episode-thumbnail fallback is the show poster when the still fails', () {
    final item = MediaItem.xtream(
      id: 'episode:10:100',
      kind: MediaKind.episode,
      title: 'Pilot',
      thumbPath: 'https://example.invalid/still.jpg',
      grandparentThumbPath: 'https://example.invalid/show.jpg',
    );
    expect(
      item.posterThumb(mode: EpisodePosterMode.episodeThumbnail),
      'https://example.invalid/still.jpg',
    );
    expect(
      item.posterThumbFallback(mode: EpisodePosterMode.episodeThumbnail),
      'https://example.invalid/show.jpg',
    );
  });

  test('episode-thumbnail fallback is null when there is no show poster', () {
    final item = MediaItem.xtream(
      id: 'episode:10:100',
      kind: MediaKind.episode,
      title: 'Pilot',
      thumbPath: 'https://example.invalid/still.jpg',
    );
    expect(
      item.posterThumbFallback(mode: EpisodePosterMode.episodeThumbnail),
      isNull,
    );
  });

  test('season-poster fallback is unchanged', () {
    final item = MediaItem.xtream(
      id: 'episode:10:100',
      kind: MediaKind.episode,
      title: 'Pilot',
      thumbPath: 'https://example.invalid/still.jpg',
      parentThumbPath: 'https://example.invalid/season.jpg',
      grandparentThumbPath: 'https://example.invalid/show.jpg',
    );
    expect(
      item.posterThumbFallback(mode: EpisodePosterMode.seasonPoster),
      'https://example.invalid/show.jpg',
    );
  });
}
