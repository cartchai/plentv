import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/database/download_operations.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/saf_storage_service.dart';
import '../test_helpers/download_fixtures.dart';
import '../test_helpers/io_fakes.dart';
import '../test_helpers/saf_fakes.dart';

/// Minimal Xtream client: answers `fetchItem` from a canned map, nothing
/// else. Every other call reaches [noSuchMethod] and throws, like the
/// throwing clients in `download_provider_test.dart`.
class _FakeIptvClient implements MediaServerClient {
  _FakeIptvClient({required this.serverId, required this.itemsById});

  @override
  final ServerId serverId;
  final Map<String, MediaItem> itemsById;

  @override
  MediaBackend get backend => MediaBackend.xtream;

  @override
  Future<MediaItem?> fetchItem(String id) async => itemsById[id];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// [_FakeIptvClient] that counts `fetchItem` calls, so a test can prove
/// two concurrent refreshes share one network fill (A3).
class _CountingFakeIptvClient extends _FakeIptvClient {
  _CountingFakeIptvClient({required super.serverId, required super.itemsById});

  int fetchCount = 0;

  @override
  Future<MediaItem?> fetchItem(String id) async {
    fetchCount++;
    return super.fetchItem(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const serverId = 'xtream-conn-1';
  const episodeRatingKey = 'episode:3823:1835460';
  const seasonRatingKey = 'season:3823:1';
  const seriesRatingKey = 'series:3823';
  const globalKey = '$serverId:$episodeRatingKey';
  const showFolder = 'EN - South Park (1997) (US)';
  const episodeFileName = 'S01E01 - EN - South Park - S01E01 - Cartman Gets an Anal Probe [992c7989].mp4';
  const storedPath = 'downloads/TV Shows/$showFolder/Season 01/$episodeFileName';

  MediaItem episodeItem({String? title}) => MediaItem.xtream(
    id: episodeRatingKey,
    kind: MediaKind.episode,
    title: title ?? 'EN - South Park - S01E01 - Cartman Gets an Anal Probe',
    parentId: seasonRatingKey,
    parentTitle: 'Season 01',
    parentIndex: 1,
    index: 1,
    grandparentId: seriesRatingKey,
    grandparentTitle: showFolder,
    serverId: serverId,
    libraryId: 'xtream-vod',
    libraryTitle: 'TV Shows',
  );

  late Directory tmpRoot;
  late PathProviderPlatform previousPathProvider;
  late AppDatabase db;
  late DownloadManagerService downloadManager;
  MediaClientResolver? testClientResolver;

  setUp(() async {
    DownloadStorageService.resetForTesting();
    tmpRoot = await Directory.systemTemp.createTemp('pleztv-151-');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(tmpRoot);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    JellyfinApiCache.initialize(db);
    testClientResolver = null;
    SafStorageService.setOpsForTesting(FakeSafStorage());
    downloadManager = DownloadManagerService(
      database: db,
      storageService: DownloadStorageService.instance,
      clientResolver: (serverId, {clientScopeId}) => testClientResolver?.call(serverId, clientScopeId: clientScopeId),
    );
    downloadManager.recoveryFuture = Future<void>.value();

    await db
        .into(db.connections)
        .insert(
          ConnectionsCompanion.insert(
            id: serverId,
            kind: 'xtream',
            displayName: 'Test Xtream',
            configJson: '{}',
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
  });

  tearDown(() async {
    downloadManager.dispose();
    await db.close();
    SafStorageService.setOpsForTesting(null);
    DownloadStorageService.resetForTesting();
    PathProviderPlatform.instance = previousPathProvider;
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  Future<void> seedCompletedEpisodeRow({String? videoFilePath, int? status}) async {
    final rowStatus = status ?? DownloadStatus.completed.index;
    await db.insertDownload(
      serverId: ServerId(serverId),
      ratingKey: episodeRatingKey,
      globalKey: globalKey,
      type: 'episode',
      parentRatingKey: seasonRatingKey,
      grandparentRatingKey: seriesRatingKey,
      libraryId: 'xtream-vod',
      libraryTitle: 'TV Shows',
      status: rowStatus,
      videoFilePath: videoFilePath,
      downloadedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await db.addDownloadOwner(profileId: 'test-profile', globalKey: globalKey, backendId: 'xtream');
  }

  Future<File> createEpisodeFile() async {
    // Write through the storage service's own resolver, exactly like the
    // real download writer does: on the Linux test host relative paths
    // anchor under the support dir, on Matt's phone under documents.
    // Writing to a hardcoded dir would test the wrong path.
    final absolute = await DownloadStorageService.instance.toAbsolutePath(storedPath);
    final file = File(absolute);
    await file.create(recursive: true);
    await file.writeAsString('fake-episode-bytes');
    return file;
  }

  /// The real constructor starts with no active profile, so the
  /// ownership-filtered getters stay empty until a profile is set —
  /// mirror what the app does at startup.
  Future<DownloadProvider> buildReadyProvider() async {
    final provider = DownloadProvider(downloadManager: downloadManager, database: db);
    provider.setActiveProfileId('test-profile');
    await provider.ensureInitialized();
    await provider.debugWaitForProfileScopedReload();
    return provider;
  }

  group('1.5.1 IPTV downloads lost after restart', () {
    test('completed IPTV episode lists after a simulated restart with no server', () async {
      // The 1.5 state: Drift row + file on disk, no metadata anywhere,
      // no server reachable (home-WiFi 403 shape). The Downloads screen
      // must still list the episode.
      await seedCompletedEpisodeRow(videoFilePath: storedPath);
      await createEpisodeFile();

      final provider = await buildReadyProvider();

      expect(provider.downloads, contains(globalKey));
      expect(provider.metadata, contains(globalKey));
      expect(provider.isSynthesizedMetadata(globalKey), isTrue);
      expect(provider.downloadedEpisodes, hasLength(1));
      expect(provider.downloadedEpisodes.single.title, contains('Cartman Gets an Anal Probe'));
      expect(provider.downloadedShows, hasLength(1));
      expect(provider.downloadedShows.single.title, showFolder);

      provider.dispose();
    });

    test('synthesis is scoped: queued rows and missing files stay unlisted', () async {
      // Queued row WITH a file on disk: not completed, never synthesized.
      await seedCompletedEpisodeRow(
        videoFilePath: storedPath,
        status: DownloadStatus.queued.index,
      );
      final file = await createEpisodeFile();

      final provider = await buildReadyProvider();

      expect(provider.downloads, contains(globalKey));
      expect(provider.metadata, isNot(contains(globalKey)));
      expect(provider.downloadedEpisodes, isEmpty);

      // And a completed row whose file is gone: nothing to synthesize from.
      await db.insertDownload(
        serverId: ServerId(serverId),
        ratingKey: 'episode:3823:1835461',
        globalKey: '$serverId:episode:3823:1835461',
        type: 'episode',
        parentRatingKey: seasonRatingKey,
        grandparentRatingKey: seriesRatingKey,
        status: DownloadStatus.completed.index,
        videoFilePath: 'downloads/TV Shows/$showFolder/Season 01/S01E02 - missing.mp4',
      );
      await db.addDownloadOwner(
        profileId: 'test-profile',
        globalKey: '$serverId:episode:3823:1835461',
        backendId: 'xtream',
      );
      await provider.refreshMetadataFromCache();

      expect(provider.downloadedEpisodes, isEmpty);
      // The guard rails: synthesis never deletes the file or the row.
      expect(await file.exists(), isTrue);
      expect(await db.getDownloadedMedia(globalKey), isNotNull);

      provider.dispose();
    });

    test('synthesized metadata is replaced by a later live fetch', () async {
      await seedCompletedEpisodeRow(videoFilePath: storedPath);
      await createEpisodeFile();

      final provider = await buildReadyProvider();

      // Synthesized from the filename: the feed's own title text.
      expect(provider.getMetadata(globalKey)?.title, contains('Cartman Gets an Anal Probe'));
      expect(provider.isSynthesizedMetadata(globalKey), isTrue);

      // The server comes back with the canonical title; a refresh must
      // replace the synthesized entry, not keep it forever.
      testClientResolver = (_, {clientScopeId}) => _FakeIptvClient(
        serverId: ServerId(serverId),
        itemsById: {episodeRatingKey: episodeItem(title: 'Cartman Gets an Anal Probe (canonical)')},
      );
      await provider.refreshMetadataFromCache();

      expect(provider.getMetadata(globalKey)?.title, 'Cartman Gets an Anal Probe (canonical)');
      expect(provider.isSynthesizedMetadata(globalKey), isFalse);
      expect(provider.downloadedEpisodes, hasLength(1));

      provider.dispose();
    });

    test('network fill populates IPTV metadata once the client is live', () async {
      // No file on disk, so synthesis cannot fire — only the live fill
      // (Fix 1) can populate the row.
      await seedCompletedEpisodeRow();

      final provider = await buildReadyProvider();
      expect(provider.metadata, isNot(contains(globalKey)));

      testClientResolver = (_, {clientScopeId}) => _FakeIptvClient(
        serverId: ServerId(serverId),
        itemsById: {episodeRatingKey: episodeItem()},
      );
      await provider.refreshMetadataFromCache();

      expect(provider.metadata, contains(globalKey));
      expect(provider.downloadedEpisodes, hasLength(1));
      expect(provider.downloadedShows.single.title, showFolder);

      provider.dispose();
    });

    test('concurrent refreshes join one run instead of filling twice (A3)', () async {
      // No file on disk, so synthesis cannot fire — only the live fill
      // can populate the row. Two refreshes fired at once (startup +
      // servers-connected, or tab shown mid-refresh) must share one
      // pass: the fake client sees exactly one fetchItem call.
      await seedCompletedEpisodeRow();

      final provider = await buildReadyProvider();
      expect(provider.metadata, isNot(contains(globalKey)));

      final client = _CountingFakeIptvClient(
        serverId: ServerId(serverId),
        itemsById: {episodeRatingKey: episodeItem()},
      );
      testClientResolver = (_, {clientScopeId}) => client;
      await Future.wait([
        provider.refreshMetadataFromCache(),
        provider.refreshMetadataFromCache(),
      ]);

      expect(client.fetchCount, 1);
      expect(provider.metadata, contains(globalKey));
      expect(provider.downloadedEpisodes, hasLength(1));

      provider.dispose();
    });

    test('enqueue-time persist survives a restart with no server and no file', () async {
      // The durable fix (Fix 2): metadata saved at enqueue time must list
      // after a restart even with no server reachable and no file for the
      // synthesis net to read.
      await seedCompletedEpisodeRow();
      final client = _FakeIptvClient(serverId: ServerId(serverId), itemsById: const {});
      await downloadManager.saveMetadata(episodeItem(), client);

      // Simulated restart: a fresh provider on the same database.
      final provider = await buildReadyProvider();

      expect(provider.metadata, contains(globalKey));
      expect(provider.downloadedEpisodes, hasLength(1));
      expect(provider.downloadedEpisodes.single.title, contains('Cartman Gets an Anal Probe'));

      provider.dispose();
    });

    test('deleting a download clears its saved details', () async {
      // The durable row belongs to the physical download: deleting the
      // download must drop the saved details with it, or a stale row
      // would linger and could re-list a deleted download.
      await seedCompletedEpisodeRow();
      final client = _FakeIptvClient(serverId: ServerId(serverId), itemsById: const {});
      await downloadManager.saveMetadata(episodeItem(), client);
      expect(await db.getDownloadMetadata(globalKey), isNotNull);

      await downloadManager.deleteDownload(globalKey);

      expect(await db.getDownloadMetadata(globalKey), isNull);
      expect(await db.getDownloadedMedia(globalKey), isNull);

      // A fresh provider on the same database lists nothing for the key.
      final provider = await buildReadyProvider();
      expect(provider.downloads, isNot(contains(globalKey)));
      expect(provider.metadata, isNot(contains(globalKey)));

      provider.dispose();
    });

    test('malformed durable metadata does not break the refresh', () async {
      // A corrupt durable row (bad write, truncated JSON) must be ignored,
      // not crash the refresh — the synthesis net still lists the row
      // from the file on disk.
      await seedCompletedEpisodeRow(videoFilePath: storedPath);
      await createEpisodeFile();
      await db.putDownloadMetadata(
        globalKey: globalKey,
        serverId: serverId,
        itemId: episodeRatingKey,
        data: 'not-json{{{',
      );

      final provider = await buildReadyProvider();

      expect(provider.metadata, contains(globalKey));
      expect(provider.downloadedEpisodes, hasLength(1));

      await provider.refreshMetadataFromCache();
      expect(provider.downloadedEpisodes, hasLength(1));
      expect(provider.downloadedEpisodes.single.title, contains('Cartman Gets an Anal Probe'));

      provider.dispose();
    });
  });
}
