import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/trackers/mdblist/mdblist_tracker.dart';
import 'package:plezy/services/trackers/tracker.dart';
import 'package:plezy/services/trackers/tracker_coordinator.dart';
import 'package:plezy/services/trackers/tracker_session.dart';
import 'package:plezy/utils/external_ids.dart';

import '../../test_helpers/media_items.dart';
import '../../test_helpers/prefs.dart';

typedef _Call = ({String path, Map<String, dynamic> body});

class _Recorder {
  final List<_Call> calls = [];
  bool failStop = false;

  http.Client client() => MockClient((req) async {
    if (failStop && req.url.path == '/scrobble/stop') throw http.ClientException('stop failed');
    calls.add((path: req.url.path, body: json.decode(req.body) as Map<String, dynamic>));
    return http.Response('{}', 200);
  });

  List<_Call> get watchedCalls => calls.where((c) => c.path == '/sync/watched').toList();
  List<_Call> get unwatchedCalls => calls.where((c) => c.path == '/sync/watched/remove').toList();
  List<_Call> get scrobbleCalls => calls.where((c) => c.path.startsWith('/scrobble/')).toList();

  int watchedEpisodeCountIn(_Call call) =>
      (call.body['shows'] as List)
          .expand((show) => (show['seasons'] as List))
          .expand((season) => (season['episodes'] as List))
          .length;
}

/// A media server whose show ids and episode lists are scripted per test.
class _FakeMediaServerClient implements MediaServerClient {
  @override
  final ServerId serverId = ServerId('server-1');
  @override
  String? get serverName => null;
  @override
  MediaBackend get backend => MediaBackend.plex;

  final Map<String, ExternalIds> externalIdsByItem;
  final Map<String, List<MediaItem>> descendantsByParent;
  final List<String> externalIdCalls = [];
  bool throwOnExternalIds = false;

  _FakeMediaServerClient({required this.externalIdsByItem, this.descendantsByParent = const {}});

  @override
  double get watchedThreshold => 0.9;

  @override
  Future<ExternalIds> fetchExternalIds(String itemId) async {
    externalIdCalls.add(itemId);
    if (throwOnExternalIds) throw Exception('server down');
    return externalIdsByItem[itemId] ?? const ExternalIds();
  }

  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId) async =>
      descendantsByParent[parentId] ?? const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _showIds = ExternalIds(tvdb: 81797, tmdb: 37854, imdb: 'tt0388629');
const _movieIds = ExternalIds(imdb: 'tt0372784', tmdb: 272);

MediaItem _episode({required int season, required int number, String showId = 'show-1'}) => testMediaItem(
  id: 'episode-s${season}e$number',
  backend: MediaBackend.plex,
  kind: MediaKind.episode,
  title: 'Episode $number',
  grandparentId: showId,
  parentId: 'season-$season',
  parentIndex: season,
  index: number,
  serverId: 'server-1',
  libraryId: '8',
  durationMs: 2700000,
);

MediaItem _season({int season = 1, String showId = 'show-1'}) => testMediaItem(
  id: 'season-$season',
  backend: MediaBackend.plex,
  kind: MediaKind.season,
  title: 'Season $season',
  parentId: showId,
  index: season,
  serverId: 'server-1',
  libraryId: '8',
);

MediaItem _show({String id = 'show-1'}) => testMediaItem(
  id: id,
  backend: MediaBackend.plex,
  kind: MediaKind.show,
  title: 'Show',
  serverId: 'server-1',
  libraryId: '8',
);

MediaItem _movie() => testMediaItem(
  id: 'movie-1',
  backend: MediaBackend.plex,
  kind: MediaKind.movie,
  title: 'Movie',
  serverId: 'server-1',
  libraryId: '8',
  durationMs: 7200000,
);

TrackerSession _session() =>
    TrackerSession(accessToken: 'at', refreshToken: 'rt', expiresAt: 4000000000, createdAt: 1900000000);

void main() {
  late _Recorder recorder;
  late _FakeMediaServerClient client;
  var now = DateTime(2026, 5, 12, 12);

  DateTime fakeClock() => now;

  setUp(() async {
    resetSharedPreferencesForTest();
    recorder = _Recorder();
    client = _FakeMediaServerClient(
      externalIdsByItem: {'show-1': _showIds, 'movie-1': _movieIds},
      descendantsByParent: {
        'show-1': [for (var n = 1; n <= 3; n++) _episode(season: 1, number: n)],
        'season-1': [for (var n = 1; n <= 3; n++) _episode(season: 1, number: n)],
      },
    );
    MdblistTracker.instance.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recorder.client());
    await MdblistTracker.instance.setEnabled(true);
    TrackerCoordinator.instance.onActiveProfileChanged('test-profile');
    TrackerCoordinator.instance.debugUseScrobbleClock(fakeClock);
  });

  tearDown(() async {
    await TrackerCoordinator.instance.stopPlayback();
    TrackerCoordinator.instance.cancelInFlight();
    TrackerCoordinator.instance.debugUseScrobbleClock(null);
    MdblistTracker.instance.rebindSession(null, onSessionInvalidated: () {});
    await MdblistTracker.instance.setEnabled(false);
  });

  Future<void> advance(Duration by) async {
    now = now.add(by);
  }

  group('TrackerCoordinator manual watched sync', () {
    test('writes a manually watched season to MDBList as one request', () async {
      await TrackerCoordinator.instance.markWatched(_season(), client);
      await TrackerCoordinator.instance.flushWriteQueue();

      expect(recorder.watchedCalls, hasLength(1));
      expect(recorder.watchedEpisodeCountIn(recorder.watchedCalls.single), 3);
      expect(recorder.unwatchedCalls, isEmpty);
    });

    test('a long show goes to MDBList in capped batches, never one request per episode', () async {
      final many = [for (var n = 1; n <= 250; n++) _episode(season: 1, number: n)];
      client = _FakeMediaServerClient(
        externalIdsByItem: {'show-1': _showIds},
        descendantsByParent: {'show-1': many},
      );

      await TrackerCoordinator.instance.markWatched(_show(), client);
      await TrackerCoordinator.instance.flushWriteQueue();

      // historyBatchSize is 100.
      expect(recorder.watchedCalls, hasLength(3));
      expect([for (final call in recorder.watchedCalls) recorder.watchedEpisodeCountIn(call)], [100, 100, 50]);
    });

    test('a manually watched episode is written once, not counted on top of the server rollup', () async {
      await TrackerCoordinator.instance.markWatched(_episode(season: 1, number: 2), client);
      await TrackerCoordinator.instance.flushWriteQueue();

      expect(recorder.watchedCalls, hasLength(1));
      expect(recorder.watchedEpisodeCountIn(recorder.watchedCalls.single), 1);
    });

    test('a manually watched movie is written once', () async {
      await TrackerCoordinator.instance.markWatched(_movie(), client);
      await TrackerCoordinator.instance.flushWriteQueue();

      expect(recorder.watchedCalls, hasLength(1));
      expect(recorder.calls.single.path, '/sync/watched');
      expect((recorder.calls.single.body['movies'] as List).single['ids'], {'imdb': 'tt0372784', 'tmdb': 272});
    });

    test('removes a manually unwatched season from MDBList history in one request', () async {
      await TrackerCoordinator.instance.markUnwatched(_season(), client);
      await TrackerCoordinator.instance.flushWriteQueue();

      expect(recorder.unwatchedCalls, hasLength(1));
      expect(recorder.watchedCalls, isEmpty);
      final removed =
          (recorder.unwatchedCalls.single.body['shows'] as List)
              .expand((show) => (show['seasons'] as List))
              .expand((season) => (season['episodes'] as List))
              .length;
      expect(removed, 3);
    });

    test('a manual mark with no external ids writes nothing', () async {
      final unknown = _FakeMediaServerClient(externalIdsByItem: const {});
      await TrackerCoordinator.instance.markWatched(_episode(season: 1, number: 1), unknown);
      await TrackerCoordinator.instance.flushWriteQueue();

      expect(recorder.calls, isEmpty);
    });

    test('playback resolver is recreated when the server client changes', () async {
      final clientA = _FakeMediaServerClient(
        externalIdsByItem: {'show-1': const ExternalIds(tvdb: 111, tmdb: 1111)},
      );
      final clientB = _FakeMediaServerClient(
        externalIdsByItem: {'show-1': const ExternalIds(tvdb: 222, tmdb: 2222)},
      );

      await TrackerCoordinator.instance.startPlayback(_episode(season: 1, number: 1), clientA);
      await pumpEventQueue();
      await TrackerCoordinator.instance.stopPlayback();
      await pumpEventQueue();
      await advance(const Duration(seconds: 2));
      await TrackerCoordinator.instance.startPlayback(_episode(season: 1, number: 2), clientB);
      await pumpEventQueue();

      expect(clientA.externalIdCalls, ['show-1']);
      expect(clientB.externalIdCalls, ['show-1']);
      final starts = recorder.scrobbleCalls.where((c) => c.path == '/scrobble/start').toList();
      expect(starts, hasLength(2));
      expect((starts[0].body['show'] as Map)['ids'], {'tmdb': 1111});
      expect((starts[1].body['show'] as Map)['ids'], {'tmdb': 2222});
    });
  });

  group('TrackerCoordinator playback', () {
    test('start sends a scrobble start and stop sends a stop, with the true progress', () async {
      final episode = _episode(season: 1, number: 1);
      await TrackerCoordinator.instance.startPlayback(episode, client);
      await pumpEventQueue();
      await advance(const Duration(seconds: 2));
      TrackerCoordinator.instance.updatePosition(const Duration(minutes: 20));
      await pumpEventQueue();
      await advance(const Duration(seconds: 2));
      await TrackerCoordinator.instance.stopPlayback();
      await pumpEventQueue();

      final starts = recorder.scrobbleCalls.where((c) => c.path == '/scrobble/start').toList();
      final stops = recorder.scrobbleCalls.where((c) => c.path == '/scrobble/stop').toList();
      expect(starts.length, greaterThanOrEqualTo(1));
      expect(stops, hasLength(1));
      // 20 of 45 minutes = ~44%.
      expect((stops.single.body['progress'] as num).toDouble(), closeTo(44.44, 0.5));
      expect(recorder.watchedCalls, isEmpty, reason: '44% is below the server watched threshold');
    });

    test('stop past the server threshold records no second watch: the stop already owns it', () async {
      final episode = _episode(season: 1, number: 1);
      await TrackerCoordinator.instance.startPlayback(episode, client);
      await pumpEventQueue();
      await advance(const Duration(seconds: 2));
      // 43 of 45 minutes = ~95%: past the server 90% threshold and past
      // MDBList's own 80% scrobble-watched rule, so the stop owns the watch.
      TrackerCoordinator.instance.updatePosition(const Duration(minutes: 43));
      await pumpEventQueue();
      await advance(const Duration(seconds: 2));
      await TrackerCoordinator.instance.stopPlayback();
      await pumpEventQueue();

      expect(recorder.scrobbleCalls.where((c) => c.path == '/scrobble/stop'), hasLength(1));
      expect(recorder.watchedCalls, isEmpty);
    });

    test('a failed stop past the threshold falls back to a history write', () async {
      recorder.failStop = true;
      final episode = _episode(season: 1, number: 1);
      await TrackerCoordinator.instance.startPlayback(episode, client);
      await pumpEventQueue();
      await advance(const Duration(seconds: 2));
      TrackerCoordinator.instance.updatePosition(const Duration(minutes: 43));
      await pumpEventQueue();
      await advance(const Duration(seconds: 2));
      await TrackerCoordinator.instance.stopPlayback();
      await pumpEventQueue();
      await TrackerCoordinator.instance.flushWriteQueue();

      expect(recorder.scrobbleCalls.where((c) => c.path == '/scrobble/stop'), isEmpty);
      expect(recorder.watchedCalls, hasLength(1));
      expect(recorder.watchedEpisodeCountIn(recorder.watchedCalls.single), 1);
    });

    test('pause and resume checkpoint through the scrobble endpoints', () async {
      await TrackerCoordinator.instance.startPlayback(_episode(season: 1, number: 1), client);
      await pumpEventQueue();
      await advance(const Duration(seconds: 2));
      await TrackerCoordinator.instance.pausePlayback();
      await pumpEventQueue();
      await advance(const Duration(seconds: 2));
      await TrackerCoordinator.instance.resumePlayback();
      await pumpEventQueue();

      expect(recorder.scrobbleCalls.map((c) => c.path), ['/scrobble/start', '/scrobble/pause', '/scrobble/start']);
    });

    test('a failing external-id lookup leaves the coordinator reset instead of escalating', () async {
      client.throwOnExternalIds = true;

      await TrackerCoordinator.instance.startPlayback(_episode(season: 1, number: 1), client);
      await pumpEventQueue();
      await TrackerCoordinator.instance.stopPlayback();
      await pumpEventQueue();

      expect(recorder.calls, isEmpty);
    });

    test('live playback never scrobbles', () async {
      await TrackerCoordinator.instance.startPlayback(_episode(season: 1, number: 1), client, isLive: true);
      await pumpEventQueue();
      await TrackerCoordinator.instance.stopPlayback();
      await pumpEventQueue();

      expect(recorder.calls, isEmpty);
    });
  });
}
