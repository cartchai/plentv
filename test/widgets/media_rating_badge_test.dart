// FAILING-FIRST — 1.6.11 X7: a provider `0` / `0.0` rating renders as a
// "★ 0" badge. Zero means "not rated yet" (see
// `MediaRatingSource.fromScale`), so there is no badge at all.

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_rating.dart';
import 'package:plezy/widgets/media_rating_badge.dart';

void main() {
  test('a zero bare rating shows no badge', () {
    const item = MediaItem.xtream(id: 'movie:1', kind: MediaKind.movie, rating: 0.0);
    expect(mediaRatingsFor(item), isEmpty);
  });

  test('a real bare rating still shows one badge', () {
    const item = MediaItem.xtream(id: 'movie:1', kind: MediaKind.movie, rating: 7.3);
    final ratings = mediaRatingsFor(item);
    expect(ratings, hasLength(1));
    expect(ratings.single.value, 7.3);
  });

  test('zero entries in the attributed list are dropped', () {
    const item = MediaItem.xtream(
      id: 'movie:1',
      kind: MediaKind.movie,
      rating: 7.3,
      ratings: [
        MediaRatingSource(source: 'imdb', value: 0.0),
        MediaRatingSource(source: 'tmdb', value: 7.3),
      ],
    );
    expect(mediaRatingsFor(item).map((r) => r.source), ['tmdb']);
  });

  test('an all-zero attributed list falls back to the bare rating', () {
    const item = MediaItem.xtream(
      id: 'movie:1',
      kind: MediaKind.movie,
      rating: 7.3,
      ratings: [MediaRatingSource(source: 'imdb', value: 0.0)],
    );
    final ratings = mediaRatingsFor(item);
    expect(ratings, hasLength(1));
    expect(ratings.single.value, 7.3);
  });
}
