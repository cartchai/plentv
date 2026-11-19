import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_item_merge.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_version.dart';
import '../test_helpers/media_items.dart';

void main() {
  MediaItem item({String? serverId, String? serverName, String? libraryId, String? libraryTitle}) => testMediaItem(
    id: 'item',
    backend: MediaBackend.plex,
    kind: MediaKind.movie,
    serverId: serverId,
    serverName: serverName,
    libraryId: libraryId,
    libraryTitle: libraryTitle,
  );

  test('uses the authoritative fallback when both items omit server identity', () {
    final merged = mergeFetchedMediaItem(fetched: item(), fallbackServerId: ServerId('fallback'));

    expect(merged.serverId, 'fallback');
    expect(merged.globalKey, 'fallback:item');
  });

  test('preserves existing identity while preferring fetched library context', () {
    final merged = mergeFetchedMediaItem(
      fetched: item(serverId: 'fetched', serverName: 'Fetched', libraryId: 'new-lib', libraryTitle: 'New'),
      existing: item(serverId: 'existing', serverName: 'Existing', libraryId: 'old-lib', libraryTitle: 'Old'),
      fallbackServerId: ServerId('fallback'),
    );

    expect(merged.serverId, 'existing');
    expect(merged.serverName, 'Existing');
    expect(merged.libraryId, 'new-lib');
    expect(merged.libraryTitle, 'New');
  });

  test('fills missing fetched library context from the existing item', () {
    final merged = mergeFetchedMediaItem(
      fetched: item(),
      existing: item(libraryId: 'old-lib', libraryTitle: 'Old'),
      fallbackServerId: ServerId('fallback'),
    );

    expect(merged.libraryId, 'old-lib');
    expect(merged.libraryTitle, 'Old');
  });

  test('a fetched item that moved libraries does not inherit the old label', () {
    final merged = mergeFetchedMediaItem(
      fetched: item(libraryId: 'new-lib'),
      existing: item(libraryId: 'old-lib', libraryTitle: 'Old'),
      fallbackServerId: ServerId('fallback'),
    );

    expect(merged.libraryId, 'new-lib');
    expect(merged.libraryTitle, isNull);
  });

  test('a fetched item naming the same library fills its label from the existing item', () {
    final merged = mergeFetchedMediaItem(
      fetched: item(libraryId: 'old-lib'),
      existing: item(libraryId: 'old-lib', libraryTitle: 'Old'),
      fallbackServerId: ServerId('fallback'),
    );

    expect(merged.libraryId, 'old-lib');
    expect(merged.libraryTitle, 'Old');
  });

  MediaItem copy({
    required String id,
    String? libraryId,
    String? libraryTitle,
    String? videoResolution,
    List<MediaVersion>? mediaVersions,
  }) => testMediaItem(
    id: id,
    serverId: 'server-1',
    serverName: 'Living Room',
    libraryId: libraryId ?? (libraryTitle == null ? null : '$id-lib'),
    libraryTitle: libraryTitle,
    mediaVersions:
        mediaVersions ??
        (videoResolution == null ? null : [MediaVersion(id: '$id-v', videoResolution: videoResolution)]),
  );

  test('orders library copies by resolution, best first', () {
    final merged = mergeLibraryCopies(const [], [
      copy(id: 'hd', libraryTitle: 'Movies', videoResolution: '1080'),
      copy(id: 'uhd', libraryTitle: '4K Movies', videoResolution: '4k'),
    ]);

    expect(merged.map((item) => item.id), ['uhd', 'hd']);
  });

  test('keeps copies a later pass did not return', () {
    final merged = mergeLibraryCopies([copy(id: 'hd', libraryTitle: 'Movies')], const []);

    expect(merged.map((item) => item.id), ['hd']);
  });

  test('an unstamped re-resolve does not strip a copy of its library', () {
    // Jellyfin's library stamp is a best-effort ancestors lookup that returns
    // the item unstamped when it fails. Losing the title would make this copy
    // indistinguishable from its sibling in the server's other library.
    final merged = mergeLibraryCopies(
      [copy(id: 'hd', libraryTitle: 'Movies', videoResolution: '1080')],
      [copy(id: 'hd')],
    );

    expect(merged.single.libraryId, 'hd-lib');
    expect(merged.single.libraryTitle, 'Movies');
    expect(merged.single.serverName, 'Living Room');
    expect(merged.single.mediaVersions?.single.videoResolution, '1080');
  });

  test('a re-resolve carrying fresher library context wins', () {
    final merged = mergeLibraryCopies(
      [copy(id: 'hd', libraryTitle: 'Movies', videoResolution: '1080')],
      [copy(id: 'hd', libraryTitle: 'Renamed Movies', videoResolution: '4k')],
    );

    expect(merged.single.libraryTitle, 'Renamed Movies');
    expect(merged.single.mediaVersions?.single.videoResolution, '4k');
  });

  test('a re-resolve naming another library takes its id without the old label', () {
    final merged = mergeLibraryCopies(
      [copy(id: 'hd', libraryTitle: 'Movies')],
      [copy(id: 'hd', libraryId: 'other-lib')],
    );

    expect(merged.single.libraryId, 'other-lib');
    expect(merged.single.libraryTitle, isNull);
  });

  test('an empty version list is treated as absent, not as a downgrade', () {
    final merged = mergeLibraryCopies(
      [copy(id: 'hd', libraryTitle: 'Movies', videoResolution: '1080')],
      [copy(id: 'hd', libraryTitle: 'Movies', mediaVersions: const [])],
    );

    expect(merged.single.mediaVersions?.single.videoResolution, '1080');
  });

  // 1.4.6 G2: a re-fetch that leaves the hierarchy titles blank must not
  // wipe the titles the queued item already carries — the Downloads tree
  // reads show/season names from them, and a null-out re-labels a queued
  // episode "Unknown Show" / the series name as its season.
  group('1.4.6 G2: hierarchy titles survive a blank re-fetch', () {
    // Backend is plex here only because the test helper has no xtream
    // fixture — the merge is backend-agnostic; the titles are the point.
    MediaItem episode({String? grandparentTitle, String? parentTitle, String? grandparentId, String? parentId}) =>
        testMediaItem(
          id: 'episode:123:3823',
          backend: MediaBackend.plex,
          kind: MediaKind.episode,
          title: 'Cartman Gets an Anal Probe',
          serverId: 'xtream-1',
          grandparentId: grandparentId,
          grandparentTitle: grandparentTitle,
          parentId: parentId,
          parentTitle: parentTitle,
          parentIndex: 1,
          index: 1,
        );

    test('existing grandparent/parent titles are kept when fetched leaves them null', () {
      final merged = mergeFetchedMediaItem(
        fetched: episode(),
        existing: episode(grandparentTitle: 'South Park', parentTitle: 'Season 1', grandparentId: '123', parentId: 'series:123'),
        fallbackServerId: ServerId('xtream-1'),
      );

      expect(merged.grandparentTitle, 'South Park');
      expect(merged.parentTitle, 'Season 1');
      expect(merged.grandparentId, '123');
      expect(merged.parentId, 'series:123');
    });

    test('fetched titles still win when present', () {
      final merged = mergeFetchedMediaItem(
        fetched: episode(grandparentTitle: 'South Park', parentTitle: 'Season 2', grandparentId: '123', parentId: 'series:123'),
        existing: episode(grandparentTitle: 'Old Name', parentTitle: 'Season 1', grandparentId: '123', parentId: 'series:123'),
        fallbackServerId: ServerId('xtream-1'),
      );

      expect(merged.grandparentTitle, 'South Park');
      expect(merged.parentTitle, 'Season 2');
    });

    test('a null-out on one side only keeps the other side', () {
      final merged = mergeFetchedMediaItem(
        fetched: episode(grandparentTitle: 'South Park', parentId: 'series:123'),
        existing: episode(grandparentTitle: 'Old Name', parentTitle: 'Season 1', grandparentId: '123', parentId: 'series:123'),
        fallbackServerId: ServerId('xtream-1'),
      );

      expect(merged.grandparentTitle, 'South Park');
      expect(merged.parentTitle, 'Season 1');
      expect(merged.parentId, 'series:123');
    });
  });
}
