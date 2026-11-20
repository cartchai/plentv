import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/downloads_media_store.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/io_fakes.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

/// Public downloads root (1.6): new downloads land in `Download/PlenTV/`
/// instead of the app-private folder, so the user can see them in the
/// Files app. The native MediaStore side is faked here against a temp
/// directory: entries are empty files, finalize settles them the way the
/// Kotlin code does (rename-landed final wins, otherwise the temp bytes
/// are copied into the final entry).
void main() {
  late Directory tmpRoot;
  late Directory fakePublicRoot;
  late Directory fakeDownloadsCollection;
  late PathProviderPlatform previousPathProvider;
  late List<({String relativePath, String fileName, String mimeType})> createdEntries;
  late List<({String finalPath, String partPath})> finalizedEntries;
  late List<String> deletedEntries;

  Future<String?> fakeCreateEntry({
    required String relativePath,
    required String fileName,
    required String mimeType,
  }) async {
    createdEntries.add((relativePath: relativePath, fileName: fileName, mimeType: mimeType));
    // relativePath is relative to the Downloads collection (Download/),
    // e.g. `PlenTV/TV Shows/...` — the same contract the Kotlin
    // DownloadsChannel expects — so it joins onto the collection root,
    // NOT onto the public root (which would double the PlenTV segment).
    final dir = Directory(p.join(fakeDownloadsCollection.path, relativePath));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, fileName));
    if (!await file.exists()) await file.create();
    return file.path;
  }

  Future<bool> fakeFinalizeEntry({required String finalPath, required String partPath}) async {
    finalizedEntries.add((finalPath: finalPath, partPath: partPath));
    final finalFile = File(finalPath);
    final partFile = File(partPath);
    if (await finalFile.exists() && await finalFile.length() > 0) {
      if (await partFile.exists()) await partFile.delete();
      return true;
    }
    if (await partFile.exists() && await partFile.length() > 0) {
      await partFile.copy(finalPath);
      await partFile.delete();
      return true;
    }
    return false;
  }

  Future<bool> fakeMarkComplete({required String path}) async => File(path).exists();

  Future<bool> fakeDeleteEntry({required String path}) async {
    deletedEntries.add(path);
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
      return true;
    }
    return false;
  }

  void installFakes() {
    DownloadsMediaStore.debugCreateEntryOverride = fakeCreateEntry;
    DownloadsMediaStore.debugFinalizeEntryOverride = fakeFinalizeEntry;
    DownloadsMediaStore.debugMarkCompleteOverride = fakeMarkComplete;
    DownloadsMediaStore.debugDeleteEntryOverride = fakeDeleteEntry;
  }

  Future<DownloadStorageService> publicService() async {
    final settings = await SettingsService.getInstance();
    final service = DownloadStorageService.instance;
    await service.initialize(settings);
    // Resolve the root so isPublicPath() knows it.
    await service.getDownloadsDirectory();
    return service;
  }

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    DownloadStorageService.resetForTesting();
    tmpRoot = await Directory.systemTemp.createTemp('dss_public_test_');
    fakePublicRoot = Directory(p.join(tmpRoot.path, 'Download', 'PlenTV'));
    fakeDownloadsCollection = Directory(p.join(tmpRoot.path, 'Download'));
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(tmpRoot);
    createdEntries = [];
    finalizedEntries = [];
    deletedEntries = [];
    DownloadStorageService.debugPublicRootOverride = fakePublicRoot.path;
    installFakes();
  });

  tearDown(() async {
    DownloadsMediaStore.debugCreateEntryOverride = null;
    DownloadsMediaStore.debugFinalizeEntryOverride = null;
    DownloadsMediaStore.debugMarkCompleteOverride = null;
    DownloadsMediaStore.debugDeleteEntryOverride = null;
    DownloadStorageService.resetForTesting();
    SettingsService.resetForTesting();
    PathProviderPlatform.instance = previousPathProvider;
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  group('public downloads root', () {
    test('default root is the public folder, not the app-private folder', () async {
      final service = await publicService();
      final dir = await service.getDownloadsDirectory();
      expect(dir.path, fakePublicRoot.path);
      expect(service.isUsingPublicDownloads, isTrue);
    });

    test('without the override the default root stays app-private', () async {
      DownloadStorageService.debugPublicRootOverride = null;
      final settings = await SettingsService.getInstance();
      final service = DownloadStorageService.instance;
      await service.initialize(settings);
      final dir = await service.getDownloadsDirectory();
      expect(dir.path, isNot(fakePublicRoot.path));
      expect(dir.path, contains('downloads'));
      expect(service.isUsingPublicDownloads, isFalse);
    });

    test('episode path keeps its layout under the public root', () async {
      final service = await publicService();
      final episode = testMediaItem(
        kind: MediaKind.episode,
        title: 'Pilot',
        grandparentTitle: 'Show Name',
        parentIndex: 1,
        index: 2,
        year: 2020,
        serverId: 'srv-1',
      );
      final videoPath = await service.getEpisodeVideoPath(episode, 'mp4');
      expect(videoPath, startsWith(fakePublicRoot.path));
      expect(
        videoPath,
        matches(
          RegExp(r'TV Shows/Show Name \(2020\)/Season 01/S01E02 - Pilot \[[0-9a-f]{8}\]\.mp4$'),
        ),
      );
    });

    test('toRelativePath keeps a public path absolute; tasks use BaseDirectory.root', () async {
      final service = await publicService();
      final episode = testMediaItem(
        kind: MediaKind.episode,
        title: 'Pilot',
        grandparentTitle: 'Show Name',
        parentIndex: 1,
        index: 2,
        year: 2020,
        serverId: 'srv-1',
      );
      final videoPath = await service.getEpisodeVideoPath(episode, 'mp4');
      expect(await service.toRelativePath(videoPath), videoPath);
      final location = await service.resolveTaskDirectory(videoPath);
      expect(location.baseDirectory, BaseDirectory.root);
      expect(location.directory, p.dirname(videoPath));
    });
  });

  group('prepareDownloadTarget', () {
    test('reserves the final file and its .part temp, returns the public path', () async {
      const taskId = 'task-abc-123';
      final service = await publicService();
      final episode = testMediaItem(
        kind: MediaKind.episode,
        title: 'Pilot',
        grandparentTitle: 'Show Name',
        parentIndex: 1,
        index: 2,
        year: 2020,
        serverId: 'srv-1',
      );
      final videoPath = await service.getEpisodeVideoPath(episode, 'mp4');
      final resolved = await service.prepareDownloadTarget(videoPath, taskId);
      expect(resolved, videoPath);

      final partPath = partialDownloadFilePath(videoPath, taskId);
      expect(partPath, endsWith('.part'));
      expect(
        createdEntries.map((e) => e.fileName).toSet(),
        containsAll([p.basename(videoPath), p.basename(partPath)]),
      );
      expect(await File(videoPath).exists(), isTrue);
      expect(await File(partPath).exists(), isTrue);
    });

    test('falls back to the app-private folder when entries cannot be created', () async {
      DownloadsMediaStore.debugCreateEntryOverride =
          ({required String relativePath, required String fileName, required String mimeType}) async => null;
      final service = await publicService();
      final episode = testMediaItem(
        kind: MediaKind.episode,
        title: 'Pilot',
        grandparentTitle: 'Show Name',
        parentIndex: 1,
        index: 2,
        year: 2020,
        serverId: 'srv-1',
      );
      final videoPath = await service.getEpisodeVideoPath(episode, 'mp4');
      final resolved = await service.prepareDownloadTarget(videoPath, 'task-abc-123');
      // The fallback is the app-private folder: documents on mobile,
      // support on desktop/host — the same split `_getBaseAppDir` uses.
      // Host tests run on the desktop branch, so expect `support` here;
      // on a real Android device this is `documents/downloads`.
      expect(
        resolved,
        startsWith(p.join(tmpRoot.path, Platform.isAndroid || Platform.isIOS ? 'documents' : 'support', 'downloads')),
      );
      expect(resolved, isNot(startsWith(fakePublicRoot.path)));
      expect(await Directory(p.dirname(resolved)).exists(), isTrue);
      expect(resolved, endsWith('.mp4'));
    });
  });

  group('finalizePublicDownload', () {
    test('rename-landed final: drops the .part file, clears pending', () async {
      const taskId = 'task-abc-123';
      final service = await publicService();
      final episode = testMediaItem(
        kind: MediaKind.episode,
        title: 'Pilot',
        grandparentTitle: 'Show Name',
        parentIndex: 1,
        index: 2,
        year: 2020,
        serverId: 'srv-1',
      );
      final videoPath = await service.getEpisodeVideoPath(episode, 'mp4');
      final resolved = await service.prepareDownloadTarget(videoPath, taskId);
      final partPath = partialDownloadFilePath(resolved, taskId);
      // Simulate the downloader: bytes into the temp, then rename onto final.
      await File(partPath).writeAsBytes([1, 2, 3, 4]);
      await File(partPath).rename(resolved);

      await service.finalizePublicDownload(resolved, taskId);

      expect(finalizedEntries, hasLength(1));
      expect(finalizedEntries.single.finalPath, resolved);
      expect(finalizedEntries.single.partPath, partPath);
      expect(await File(resolved).exists(), isTrue);
      expect(await File(partPath).exists(), isFalse);
    });

    test('rename missed: copies the temp bytes into the final entry', () async {
      const taskId = 'task-abc-123';
      final service = await publicService();
      final episode = testMediaItem(
        kind: MediaKind.episode,
        title: 'Pilot',
        grandparentTitle: 'Show Name',
        parentIndex: 1,
        index: 2,
        year: 2020,
        serverId: 'srv-1',
      );
      final videoPath = await service.getEpisodeVideoPath(episode, 'mp4');
      final resolved = await service.prepareDownloadTarget(videoPath, taskId);
      final partPath = partialDownloadFilePath(resolved, taskId);
      // Simulate the downloader: bytes only in the temp, rename never ran.
      await File(partPath).writeAsBytes([9, 9, 9]);
      await File(resolved).delete();

      await service.finalizePublicDownload(resolved, taskId);

      expect(await File(resolved).exists(), isTrue);
      expect(await File(resolved).readAsBytes(), [9, 9, 9]);
      expect(await File(partPath).exists(), isFalse);
    });
  });

  group('direct writes (subtitles)', () {
    test('prepare reserves file and .download temp; finish settles it', () async {
      final service = await publicService();
      final episode = testMediaItem(
        kind: MediaKind.episode,
        title: 'Pilot',
        grandparentTitle: 'Show Name',
        parentIndex: 1,
        index: 2,
        year: 2020,
        serverId: 'srv-1',
      );
      final subtitlePath = await service.getEpisodeSubtitlePath(episode, 1, 'srt');
      final readyPath = await service.preparePublicFile(subtitlePath);
      expect(readyPath, subtitlePath);
      expect(
        createdEntries.map((e) => e.fileName).toSet(),
        containsAll([p.basename(subtitlePath), '${p.basename(subtitlePath)}.download']),
      );

      // Simulate downloadFile: bytes into the temp, then rename onto final.
      await File('$readyPath.download').writeAsString('subtitle bytes');
      await File('$readyPath.download').rename(readyPath);
      await service.finishPublicFile(readyPath);

      expect(finalizedEntries, hasLength(1));
      expect(finalizedEntries.single.finalPath, readyPath);
      expect(finalizedEntries.single.partPath, '$readyPath.download');
      expect(await File(readyPath).readAsString(), 'subtitle bytes');
    });
  });

  group('deletePublicEntryForPath', () {
    test('removes the public file and its row', () async {
      const taskId = 'task-abc-123';
      final service = await publicService();
      final episode = testMediaItem(
        kind: MediaKind.episode,
        title: 'Pilot',
        grandparentTitle: 'Show Name',
        parentIndex: 1,
        index: 2,
        year: 2020,
        serverId: 'srv-1',
      );
      final videoPath = await service.getEpisodeVideoPath(episode, 'mp4');
      final resolved = await service.prepareDownloadTarget(videoPath, taskId);
      expect(await File(resolved).exists(), isTrue);

      expect(await service.deletePublicEntryForPath(resolved), isTrue);
      expect(await File(resolved).exists(), isFalse);
      expect(deletedEntries, contains(resolved));
    });

    test('non-public paths are a no-op', () async {
      final service = await publicService();
      final privatePath = p.join(tmpRoot.path, 'documents', 'downloads', 'old.mp4');
      expect(await service.deletePublicEntryForPath(privatePath), isFalse);
      expect(deletedEntries, isEmpty);
    });
  });
}
