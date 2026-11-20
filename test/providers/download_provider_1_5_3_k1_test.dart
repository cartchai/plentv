// 1.5.3 K1: Downloads must not merge multi-season Xtream downloads into
// one season row. Every episode of a show stored before 1.5.3 carries the
// SHOW as parentId (`series:<id>`); the season lives only in parentIndex.
// The provider must re-stamp those leaves onto their per-season parent
// (`season:<id>:<n>`) so S1 and S2 list as two seasons.
//
// FAILING-FIRST: on the 1.5.2 base both seasons share the parentId
// `series:123`, so _downloadedSeasons returns one merged season.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/saf_storage_service.dart';
import '../test_helpers/saf_fakes.dart';

/// An Xtream episode exactly as 1.5.2 stored it: every episode of the show
/// carries the SHOW as parentId, the season only in parentIndex.
MediaItem oldXtreamEpisode({required String id, required int episode, required int season}) => MediaItem.xtream(
  id: id,
  kind: MediaKind.episode,
  title: 'Episode $id',
  parentId: 'series:123',
  parentTitle: 'Season $season',
  parentIndex: season,
  index: episode,
  grandparentId: '123',
  grandparentTitle: 'South Park',
  serverId: ServerId('srv'),
  serverName: 'Test',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DownloadManagerService downloadManager;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    JellyfinApiCache.initialize(db);
    SafStorageService.setOpsForTesting(FakeSafStorage());
    downloadManager = DownloadManagerService(
      database: db,
      storageService: DownloadStorageService.instance,
      clientResolver: (serverId, {clientScopeId}) => null,
    );
    downloadManager.recoveryFuture = Future<void>.value();
  });

  tearDown(() async {
    downloadManager.dispose();
    await db.close();
    SafStorageService.setOpsForTesting(null);
  });

  group('1.5.3 K1: multi-season Xtream downloads split by season', () {
    test('old show-level parentId leaves list as two seasons', () async {
      final p = DownloadProvider.forTesting(downloadManager: downloadManager, database: db);
      await p.ensureInitialized();
      p.debugSeedState(
        downloads: {
          for (final key in ['srv:episode:123:3823', 'srv:episode:123:3824', 'srv:episode:123:3900'])
            key: DownloadProgress(globalKey: key, status: DownloadStatus.completed),
        },
        metadata: {
          'srv:episode:123:3823': oldXtreamEpisode(id: 'episode:123:3823', episode: 1, season: 1),
          'srv:episode:123:3824': oldXtreamEpisode(id: 'episode:123:3824', episode: 2, season: 1),
          'srv:episode:123:3900': oldXtreamEpisode(id: 'episode:123:3900', episode: 1, season: 2),
        },
      );

      final seasons = p.downloadedSeasons;
      expect(seasons, hasLength(2), reason: 'S1 and S2 must not merge into one season row');
      expect(seasons.map((s) => s.index), [1, 2]);
      expect(seasons.map((s) => s.leafCount), [2, 1]);
      expect(
        seasons.map((s) => s.id),
        ['season:123:1', 'season:123:2'],
        reason: 'each season row takes its per-season id',
      );
      p.dispose();
    });

    test('new season-level parentId leaves still split the same way (no regression)', () async {
      MediaItem newXtreamEpisode({required String id, required int episode, required int season}) =>
          oldXtreamEpisode(id: id, episode: episode, season: season).copyWith(parentId: 'season:123:$season');
      final p = DownloadProvider.forTesting(downloadManager: downloadManager, database: db);
      await p.ensureInitialized();
      p.debugSeedState(
        downloads: {
          for (final key in ['srv:episode:123:3823', 'srv:episode:123:3900'])
            key: DownloadProgress(globalKey: key, status: DownloadStatus.completed),
        },
        metadata: {
          'srv:episode:123:3823': newXtreamEpisode(id: 'episode:123:3823', episode: 1, season: 1),
          'srv:episode:123:3900': newXtreamEpisode(id: 'episode:123:3900', episode: 1, season: 2),
        },
      );

      final seasons = p.downloadedSeasons;
      expect(seasons, hasLength(2));
      expect(seasons.map((s) => s.index), [1, 2]);
      p.dispose();
    });
  });
}
