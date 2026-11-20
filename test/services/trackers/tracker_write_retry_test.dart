import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/models/trackers/tracker_context.dart';
import 'package:plezy/services/trackers/mdblist/mdblist_tracker.dart';
import 'package:plezy/services/trackers/tracker_constants.dart';
import 'package:plezy/services/trackers/tracker_exceptions.dart';
import 'package:plezy/services/trackers/tracker_coordinator.dart';
import 'package:plezy/services/trackers/tracker_session.dart';
import 'package:plezy/services/trackers/tracker_write_queue.dart';
import 'package:plezy/utils/external_ids.dart';

import '../../test_helpers/media_items.dart';
import '../../test_helpers/prefs.dart';

/// Media server that only answers what the tracker resolver asks for.
class _FakeMediaServerClient implements MediaServerClient {
  @override
  final ServerId serverId;
  @override
  String? get serverName => null;

  final Map<String, ExternalIds> externalIdsByItem;
  final List<MediaItem> descendants;

  @override
  final double watchedThreshold;

  _FakeMediaServerClient({required this.externalIdsByItem, this.descendants = const [], this.watchedThreshold = 0.9})
    : serverId = ServerId('server-1');

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  Future<ExternalIds> fetchExternalIds(String itemId) async => externalIdsByItem[itemId] ?? const ExternalIds();

  @override
  Future<List<MediaItem>> fetchChildren(String parentId) async => const [];

  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId) async => descendants;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// MDBList posts JSON; form bodies are decoded the same way for completeness.
Map<String, dynamic> _decodeBody(String body) {
  if (body.isEmpty) return <String, dynamic>{};
  if (body.startsWith('{') || body.startsWith('[')) {
    final decoded = json.decode(body);
    return decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{'body': decoded};
  }
  return Uri.splitQueryString(body);
}

/// Records every request and can hold one write in flight, which is how
/// request ordering is driven without leaning on wall-clock timing. Reads
/// pass through ungated so the gate always lands on the write whose ordering
/// the test drives.
class _Recorder {
  final List<String> paths = [];
  final List<Map<String, dynamic>> bodies = [];
  Completer<void>? gate;
  int status = 200;

  http.Client get client => MockClient((request) async {
    paths.add(request.url.path);
    bodies.add(_decodeBody(request.body));
    if (request.method != 'GET') {
      final pending = gate;
      if (pending != null) await pending.future;
    }
    return http.Response('{}', status);
  });
}

/// Stands in for an endpoint that cannot be reached at all, as opposed to one
/// that answers with an error.
http.Client _unreachableClient() => MockClient((_) async => throw http.ClientException('no route to host'));

MediaItem _episodeItem(int number) => testMediaItem(
  id: 'episode-1-$number',
  backend: MediaBackend.plex,
  kind: MediaKind.episode,
  title: 'Episode $number',
  serverId: ServerId('server-1'),
  libraryId: 'lib-1',
  parentIndex: 1,
  index: number,
  grandparentId: 'show-1',
);

MediaItem _episodeItemOfShow(String showId, int number) => testMediaItem(
  id: '$showId-episode-$number',
  backend: MediaBackend.plex,
  kind: MediaKind.episode,
  title: 'Episode $number',
  serverId: ServerId('server-1'),
  libraryId: 'lib-1',
  parentIndex: 1,
  index: number,
  grandparentId: showId,
);

MediaItem _movieItem({int? viewOffsetMs, int? durationMs}) => testMediaItem(
  id: 'movie-1',
  backend: MediaBackend.plex,
  kind: MediaKind.movie,
  title: 'Movie 1',
  serverId: ServerId('server-1'),
  libraryId: 'lib-1',
  viewOffsetMs: viewOffsetMs,
  durationMs: durationMs,
);

/// Shows with their own TMDb id, so each show's episodes are distinct rows.
/// MDBList matches on IMDb/TMDb only — a TVDB-only item would silently no-op.
const _showTmdbIds = {'show-a': 20001, 'show-b': 20002, 'show-c': 20003};

_FakeMediaServerClient _client({double watchedThreshold = 0.9}) => _FakeMediaServerClient(
  externalIdsByItem: {
    'show-1': const ExternalIds(tmdb: 12345),
    'movie-1': const ExternalIds(tmdb: 603),
    for (final show in _showTmdbIds.entries) show.key: ExternalIds(tmdb: show.value),
  },
  watchedThreshold: watchedThreshold,
);

TrackerSession _session() =>
    TrackerSession(accessToken: 'token', createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000);

/// The `/sync/watched` writes MDBList received.
int _watchedWrites(_Recorder recorder) => recorder.paths.where((path) => path == '/sync/watched').length;

void main() {
  final coordinator = TrackerCoordinator.instance;
  final mdblist = MdblistTracker.instance;

  setUp(() async {
    resetSharedPreferencesForTest();
    coordinator.onActiveProfileChanged('user-a');
    await mdblist.setEnabled(true);
  });

  tearDown(() async {
    coordinator.cancelInFlight();
    coordinator.onActiveProfileChanged('');
    mdblist.rebindSession(null, onSessionInvalidated: () {});
    await mdblist.setEnabled(false);
  });

  group('failed watched writes are retried', () {
    test('a failed history write is replayed on the next flush', () async {
      final recorder = _Recorder()..status = 500;
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recorder.client);

      await coordinator.markWatched(_episodeItem(5), _client());
      expect(_watchedWrites(recorder), 1, reason: 'the first attempt goes out and fails');

      recorder.status = 200;
      await coordinator.flushWriteQueue();

      expect(_watchedWrites(recorder), 2, reason: 'the queued write is replayed once the service recovers');
    });

    test('a replayed write that already succeeded is not sent twice', () async {
      final recorder = _Recorder();
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recorder.client);

      await coordinator.markWatched(_episodeItem(5), _client());
      await coordinator.flushWriteQueue();

      expect(_watchedWrites(recorder), 1);
    });
  });

  group('a failed container write', () {
    MediaItem show() => testMediaItem(
      id: 'show-1',
      backend: MediaBackend.plex,
      kind: MediaKind.show,
      title: 'Show 1',
      serverId: ServerId('server-1'),
      libraryId: 'lib-1',
    );

    _FakeMediaServerClient containerClient(int episodes) => _FakeMediaServerClient(
      externalIdsByItem: const {'show-1': ExternalIds(tmdb: 12345)},
      descendants: [for (var number = 1; number <= episodes; number++) _episodeItem(number)],
    );

    test('queues every episode and replays them as one request', () async {
      final recorder = _Recorder()..status = 500;
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recorder.client);

      await coordinator.markWatched(show(), containerClient(30));
      expect(recorder.paths, ['/sync/watched'], reason: 'the live write is one request for the whole show');

      recorder
        ..status = 200
        ..paths.clear()
        ..bodies.clear();
      await coordinator.flushWriteQueue();

      expect(recorder.paths, ['/sync/watched'], reason: 'the queued episodes replay together');
      final seasons = (recorder.bodies.single['shows'] as List).single['seasons'] as List;
      expect(((seasons.single as Map)['episodes'] as List), hasLength(30));

      recorder.paths.clear();
      await coordinator.flushWriteQueue();
      expect(recorder.paths, isEmpty, reason: 'every queued episode was cleared by the replay');
    });

    test('a rate-limited replay asks once and keeps every episode', () async {
      final recorder = _Recorder()..status = 500;
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recorder.client);
      await coordinator.markWatched(show(), containerClient(TrackerConstants.historyBatchSize + 1));

      final limited = _Recorder()..status = 429;
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: limited.client);
      await coordinator.flushWriteQueue();
      expect(limited.paths, ['/sync/watched'], reason: 'one refusal stops the drain for MDBList');

      final recovered = _Recorder();
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recovered.client);
      await coordinator.flushWriteQueue();
      expect(recovered.paths, ['/sync/watched', '/sync/watched'], reason: 'nothing was dropped or charged an attempt');
    });
  });

  group('a failure racing a newer write is not persisted', () {
    test('an older history failure never replaces a newer one', () async {
      final recorder = _Recorder()..status = 500;
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recorder.client);

      final client = _client();
      // Both fail, newest last: the queue must end up holding the un-watch.
      await coordinator.markWatched(_movieItem(), client);
      await coordinator.markUnwatched(_movieItem(), client);

      recorder
        ..status = 200
        ..paths.clear();
      await coordinator.flushWriteQueue();

      expect(recorder.paths, ['/sync/watched/remove'], reason: 'the newest intent for the row is the only one queued');
    });
  });

  group('a rate-limited service', () {
    test('one back-off answer stops the drain asking again for that service', () async {
      final recorder = _Recorder()..status = 429;
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recorder.client);

      // Three separate shows, so three queued rows for one service.
      for (final show in ['show-a', 'show-b', 'show-c']) {
        await coordinator.markWatched(_episodeItemOfShow(show, 5), _client());
      }
      expect(_watchedWrites(recorder), 3, reason: 'each live write tried once');

      recorder.paths.clear();
      await coordinator.flushWriteQueue();

      expect(_watchedWrites(recorder), 1, reason: 'after the first 429 the drain leaves the rest of the service alone');

      // Once it recovers, every row still drains — batched into one request.
      final recovered = _Recorder();
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recovered.client);
      await coordinator.flushWriteQueue();

      expect(recovered.paths, ['/sync/watched']);
      expect((recovered.bodies.single['shows'] as List), hasLength(3));
    });

    test('a coalesced second flush does not re-ask during the same burst', () async {
      final recorder = _Recorder()..status = 429;
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recorder.client);
      for (final show in ['show-a', 'show-b']) {
        await coordinator.markWatched(_episodeItemOfShow(show, 5), _client());
      }

      recorder
        ..paths.clear()
        ..gate = Completer<void>();
      // Two triggers landing together — network restore and app resume can — so
      // the second coalesces onto the running drain and re-enters its loop.
      final first = coordinator.flushWriteQueue();
      await pumpEventQueue();
      final second = coordinator.flushWriteQueue();
      recorder.gate!.complete();
      await first;
      await second;

      expect(_watchedWrites(recorder), 1, reason: 'the deferral spans the whole burst');
    });
  });

  group('isTrackerFailureTransient', () {
    test('separates non-verdicts from an answer about the write', () {
      // Never reached the service.
      expect(isTrackerFailureTransient(TimeoutException('timed out')), isTrue);
      expect(isTrackerFailureTransient(const SocketException('no route')), isTrue);
      expect(isTrackerFailureTransient(http.ClientException('closed')), isTrue);

      // The service asked us to come back.
      expect(
        isTrackerFailureTransient(
          const TrackerRateLimitException(service: TrackerService.mdblist, retryAfterSeconds: 60),
        ),
        isTrue,
      );
      expect(
        isTrackerFailureTransient(const TrackerApiException(service: TrackerService.mdblist, statusCode: 429)),
        isTrue,
        reason: 'MDBList surfaces a 429 untyped',
      );

      // The service broke on its own side.
      expect(
        isTrackerFailureTransient(const TrackerApiException(service: TrackerService.mdblist, statusCode: 500)),
        isTrue,
      );
      expect(
        isTrackerFailureTransient(const TrackerApiException(service: TrackerService.mdblist, statusCode: 503)),
        isTrue,
      );

      // A refresh that can still succeed, versus a session that is really gone.
      expect(
        isTrackerFailureTransient(
          const TrackerAuthException(
            service: TrackerService.mdblist,
            message: 'Refresh failed: HTTP 503',
            statusCode: 503,
          ),
        ),
        isTrue,
      );
      expect(
        isTrackerFailureTransient(
          const TrackerAuthException(
            service: TrackerService.mdblist,
            message: 'Session invalidated (401)',
            statusCode: 401,
            isPermanent: true,
          ),
        ),
        isFalse,
      );

      // Answers about the write itself.
      for (final status in [400, 401, 403, 404, 409, 422]) {
        expect(
          isTrackerFailureTransient(TrackerApiException(service: TrackerService.mdblist, statusCode: status)),
          isFalse,
          reason: 'HTTP $status is the service answering about this write',
        );
      }
    });
  });

  group('a service that cannot answer for the write', () {
    test('a rate limit never spends the retry budget', () async {
      final recorder = _Recorder()..status = 429;
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recorder.client);
      await coordinator.markWatched(_episodeItem(5), _client());

      for (var i = 0; i < TrackerWriteQueue.maxAttempts + 2; i++) {
        await coordinator.flushWriteQueue();
      }

      final recovered = _Recorder();
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recovered.client);
      await coordinator.flushWriteQueue();

      expect(_watchedWrites(recovered), 1, reason: 'a 429 is explicitly retryable, not a verdict on the write');
    });

    test('a server-side failure never spends the retry budget', () async {
      final recorder = _Recorder()..status = 503;
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recorder.client);
      await coordinator.markWatched(_episodeItem(5), _client());

      for (var i = 0; i < TrackerWriteQueue.maxAttempts + 2; i++) {
        await coordinator.flushWriteQueue();
      }

      final recovered = _Recorder();
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recovered.client);
      await coordinator.flushWriteQueue();

      expect(_watchedWrites(recovered), 1, reason: 'a bad hour for the service is not a bad watch');
    });

    test('a rejected write is dropped once its attempts are spent', () async {
      // 422 is the service answering about this write: asking again cannot help,
      // so the item must not be retried forever.
      final recorder = _Recorder()..status = 422;
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recorder.client);
      await coordinator.markWatched(_episodeItem(5), _client());

      for (var i = 0; i < TrackerWriteQueue.maxAttempts + 1; i++) {
        await coordinator.flushWriteQueue();
      }

      final recovered = _Recorder();
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recovered.client);
      await coordinator.flushWriteQueue();

      expect(_watchedWrites(recovered), 0, reason: 'the answered rejection exhausted the budget');
    });

    test('an unreachable service never spends the retry budget', () async {
      final recorder = _Recorder()..status = 500;
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recorder.client);
      await coordinator.markWatched(_episodeItem(5), _client());
      expect(_watchedWrites(recorder), 1, reason: 'the first attempt is answered and fails');

      // Now the endpoint is unreachable rather than answering. A connectivity flap
      // can drive many flushes; none of them may exhaust the item's attempts,
      // because nothing was learned about the write.
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: _unreachableClient());
      for (var i = 0; i < TrackerWriteQueue.maxAttempts + 2; i++) {
        await coordinator.flushWriteQueue();
      }

      // The service answers again: the watch is still queued and still lands.
      final recovered = _Recorder();
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recovered.client);
      await coordinator.flushWriteQueue();

      expect(_watchedWrites(recovered), 1, reason: 'the queued write survived every unreachable flush');
    });
  });

  group('writes to one remote row are serialised', () {
    test('a replay already in flight cannot land after a newer direct write', () async {
      final recorder = _Recorder()..status = 500;
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recorder.client);
      await coordinator.markWatched(_episodeItem(5), _client());
      expect(_watchedWrites(recorder), 1);

      // Hold the replay's request open, then let a direct write for the same
      // row arrive while it is still on the wire.
      recorder
        ..status = 200
        ..gate = Completer<void>();
      final flush = coordinator.flushWriteQueue();
      await pumpEventQueue();
      expect(_watchedWrites(recorder), 2, reason: 'the replay is in flight');

      final live = coordinator.markWatched(_episodeItem(5), _client());
      await pumpEventQueue();
      expect(_watchedWrites(recorder), 2, reason: 'the direct write waits for the row to be free');

      recorder.gate!.complete();
      await flush;
      await live;

      expect(_watchedWrites(recorder), 3, reason: 'the newest write is the last one to reach the service');
    });
  });

  group('queued rows a completed write already covers', () {
    final ctx = TrackerContext.episode(
      external: const ExternalIds(tmdb: 12345),
      ratingKey: 'episode-1-5',
      libraryGlobalKey: 'server-1:lib-1',
      season: 1,
      episodeNumber: 5,
    );

    TrackerWriteQueueItem item(String key) => TrackerWriteQueueItem(
      service: TrackerService.mdblist,
      watched: true,
      ctx: ctx,
      coalesceKey: key,
      progressClaim: 5,
      watchedAtIso: '2026-05-12T00:00:00.000Z',
    );

    test('a marked row is reported superseded until its marker is cleared', () async {
      final queue = TrackerWriteQueue();
      final key = trackerItemCoalesceKey(TrackerService.mdblist, ctx, trackerExternalRowIdentity(ctx.external))!;
      final queued = item(key);

      expect(queue.isSuperseded('user-a', queued), isFalse);

      final token = queue.noteDirectWrite('user-a', key, appliedProgress: 6);
      expect(queue.isSuperseded('user-a', queued), isTrue, reason: 'progress 6 covers a claim of 5');

      queue.clearDirectWrite('user-a', key, token);
      expect(queue.isSuperseded('user-a', queued), isFalse);
    });

    test('a marker only covers claims at or below the progress it applied', () async {
      final queue = TrackerWriteQueue();
      final key = trackerItemCoalesceKey(TrackerService.mdblist, ctx, trackerExternalRowIdentity(ctx.external))!;
      queue.noteDirectWrite('user-a', key, appliedProgress: 4);

      expect(queue.isSuperseded('user-a', item(key)), isFalse, reason: 'a claim of 5 is still a pending advance');
    });

    test('one profile\'s marker never covers another profile\'s queued row', () async {
      final queue = TrackerWriteQueue();
      final key = trackerItemCoalesceKey(TrackerService.mdblist, ctx, trackerExternalRowIdentity(ctx.external))!;
      queue.noteDirectWrite('user-a', key, appliedProgress: 6);

      expect(queue.isSuperseded('user-b', item(key)), isFalse);
      expect(queue.isSuperseded('user-a', item(key)), isTrue);
    });

    test('a stale marker cannot be cleared by an older write finishing', () async {
      final queue = TrackerWriteQueue();
      final key = trackerItemCoalesceKey(TrackerService.mdblist, ctx, trackerExternalRowIdentity(ctx.external))!;
      final first = queue.noteDirectWrite('user-a', key, appliedProgress: 6);
      queue.noteDirectWrite('user-a', key, appliedProgress: 7);

      queue.clearDirectWrite('user-a', key, first);

      expect(queue.isSuperseded('user-a', item(key)), isTrue, reason: 'the newer marker must survive');
    });
  });

  group('a terminal stop the service never acknowledged', () {
    test('MDBList records the watch through history when the stop fails', () async {
      final recorder = _Recorder();
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recorder.client);

      final client = _client();
      await coordinator.startPlayback(_movieItem(durationMs: 100000), client);
      // Past the server threshold, and past MDBList's own 80% completion rule,
      // so a confirmed stop would have recorded the watch by itself.
      coordinator.updateDuration(const Duration(milliseconds: 100000));
      coordinator.updatePosition(const Duration(milliseconds: 95000));
      recorder.status = 500;
      await coordinator.stopPlayback();
      recorder.status = 200;
      await pumpEventQueue();

      expect(recorder.paths, contains('/scrobble/stop'));
      expect(
        recorder.paths.where((path) => path == '/sync/watched'),
        hasLength(1),
        reason: 'nothing on MDBList saw the item finish, so the watch falls back to history',
      );
    });

    test('a confirmed stop above the completion rule writes no history', () async {
      final recorder = _Recorder();
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recorder.client);

      final client = _client();
      await coordinator.startPlayback(_movieItem(durationMs: 100000), client);
      coordinator.updateDuration(const Duration(milliseconds: 100000));
      coordinator.updatePosition(const Duration(milliseconds: 95000));
      await coordinator.stopPlayback();
      await pumpEventQueue();

      expect(recorder.paths, contains('/scrobble/stop'));
      expect(recorder.paths, isNot(contains('/sync/watched')), reason: 'the stop already recorded the watch');
    });
  });

  group('an account rebound while its write was in flight', () {
    test('a markWatched failure completing after a disconnect is not queued', () async {
      final recorder = _Recorder()..status = 500;
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recorder.client);

      // Hold the write on the wire, then disconnect the account underneath it.
      recorder.gate = Completer<void>();
      final write = coordinator.markWatched(_episodeItem(5), _client());
      await pumpEventQueue();
      expect(_watchedWrites(recorder), 1, reason: 'the write is in flight');

      mdblist.rebindSession(null, onSessionInvalidated: () {});
      recorder.gate!.complete();
      recorder.gate = null;
      await write;

      // Account B connects: A's late failure must not have left a row behind,
      // because the disconnect purge that would remove it has already run.
      final recovered = _Recorder();
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recovered.client);
      await coordinator.flushWriteQueue();

      expect(_watchedWrites(recovered), 0, reason: "account A's late failure must not replay through B");
    });

    test('a reconcile failure completing after a disconnect is not queued', () async {
      final recorder = _Recorder();
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recorder.client);

      // Watched by the server's rule but below MDBList's own 80% completion
      // rule, so a confirmed stop leaves the watch to reconciliation's history
      // write.
      final client = _client(watchedThreshold: 0.5);
      await coordinator.startPlayback(_movieItem(durationMs: 100000), client);
      coordinator.updateDuration(const Duration(milliseconds: 100000));
      coordinator.updatePosition(const Duration(milliseconds: 60000));
      // The unawaited start report must settle before the gate arms, or the
      // gate would catch it instead of the stop.
      await pumpEventQueue();

      recorder.gate = Completer<void>();
      final stopping = coordinator.stopPlayback();
      await pumpEventQueue();
      expect(recorder.paths, contains('/scrobble/stop'), reason: 'the stop is in flight');
      // Let the stop through confirmed, then hold reconciliation's history
      // write on the wire.
      final stopGate = recorder.gate!;
      recorder.gate = Completer<void>();
      stopGate.complete();
      await pumpEventQueue();
      expect(recorder.paths, contains('/sync/watched'), reason: 'the reconcile write is in flight');

      // Disconnect while the reconcile write is on the wire, then fail it.
      mdblist.rebindSession(null, onSessionInvalidated: () {});
      recorder.status = 500;
      recorder.gate!.complete();
      recorder.gate = null;
      await stopping;
      await pumpEventQueue();

      final recovered = _Recorder();
      mdblist.rebindSession(_session(), onSessionInvalidated: () {}, httpClient: recovered.client);
      await coordinator.flushWriteQueue();

      expect(recovered.paths, isEmpty, reason: "account A's late failure must not replay through B");
    });
  });
}
