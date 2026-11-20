
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/trackers/tracker_context.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/trackers/tracker_constants.dart';
import 'package:plezy/services/trackers/tracker_write_queue.dart';
import 'package:plezy/utils/external_ids.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import '../../test_helpers/prefs.dart';

const _watchedAt = '2026-05-12T00:00:00.000Z';

TrackerContext _episode({
  String ratingKey = 'episode-1',
  String? libraryGlobalKey = 'server-1:7',
  ExternalIds external = const ExternalIds(tvdb: 123),
  int season = 1,
  int episodeNumber = 2,
}) => TrackerContext.episode(
  external: external,
  ratingKey: ratingKey,
  libraryGlobalKey: libraryGlobalKey,
  season: season,
  episodeNumber: episodeNumber,
);

TrackerContext _movie({
  String ratingKey = 'movie-1',
  String? libraryGlobalKey = 'server-1:8',
  ExternalIds external = const ExternalIds(tmdb: 456),
}) => TrackerContext.movie(external: external, ratingKey: ratingKey, libraryGlobalKey: libraryGlobalKey);

TrackerWriteQueueItem _item({
  required TrackerContext ctx,
  required String coalesceKey,
  TrackerService service = TrackerService.mdblist,
  bool watched = true,
  int? progressClaim,
  String watchedAtIso = _watchedAt,
  int attempts = 0,
}) => TrackerWriteQueueItem(
  service: service,
  watched: watched,
  ctx: ctx,
  coalesceKey: coalesceKey,
  progressClaim: progressClaim,
  watchedAtIso: watchedAtIso,
  attempts: attempts,
);

/// Drains one row per send, as for services that do not batch.
Future<void> _flushEach(
  TrackerWriteQueue queue,
  String userUuid,
  Future<TrackerWriteDisposition> Function(TrackerWriteQueueItem item) send,
) => queue.flush(userUuid, batches: (_) => false, send: (rows) async => [await send(rows.single)]);

String _historyKey(TrackerService service, TrackerContext ctx) =>
    trackerItemCoalesceKey(service, ctx, trackerExternalRowIdentity(ctx.external))!;

void main() {
  setUp(resetSharedPreferencesForTest);

  test('done flush sends and removes the queued write', () async {
    final queue = TrackerWriteQueue();
    final ctx = _episode();
    final key = trackerItemCoalesceKey(TrackerService.mdblist, ctx, trackerExternalRowIdentity(ctx.external))!;
    await queue.enqueue('user-a', _item(ctx: ctx, coalesceKey: key));

    final sent = <TrackerWriteQueueItem>[];
    await _flushEach(queue, 'user-a', (item) async {
      sent.add(item);
      return TrackerWriteDisposition.done;
    });

    expect(sent, hasLength(1));
    expect(sent.single.ctx.ratingKey, 'episode-1');
    expect(sent.single.watched, isTrue);
    expect(await queue.load('user-a'), isEmpty);
  });

  test('a drain spaces requests by the fixed request spacing', () async {
    final pauses = <Duration>[];
    final queue = TrackerWriteQueue(pause: (duration) async => pauses.add(duration));
    for (var number = 1; number <= 3; number++) {
      final ctx = _episode(ratingKey: 'episode-$number', episodeNumber: number);
      final key = trackerItemCoalesceKey(TrackerService.mdblist, ctx, trackerExternalRowIdentity(ctx.external))!;
      await queue.enqueue('user-a', _item(ctx: ctx, coalesceKey: key));
    }

    await _flushEach(queue, 'user-a', (item) async => TrackerWriteDisposition.done);

    expect(pauses, [
      const Duration(milliseconds: 50),
      const Duration(milliseconds: 50),
      const Duration(milliseconds: 50),
    ]);
  });

  test('failed flush increments attempts and a later flush drops an exhausted write without sending', () async {
    final queue = TrackerWriteQueue();
    final ctx = _episode();
    final key = trackerItemCoalesceKey(TrackerService.mdblist, ctx, trackerExternalRowIdentity(ctx.external))!;
    await queue.enqueue('user-a', _item(ctx: ctx, coalesceKey: key, attempts: TrackerWriteQueue.maxAttempts - 1));

    var sendCalls = 0;
    await _flushEach(queue, 'user-a', (item) async {
      sendCalls++;
      return TrackerWriteDisposition.failed;
    });
    final exhausted = await queue.load('user-a');
    expect(sendCalls, 1);
    expect(exhausted.single.attempts, TrackerWriteQueue.maxAttempts);

    await _flushEach(queue, 'user-a', (item) async {
      sendCalls++;
      return TrackerWriteDisposition.done;
    });
    expect(sendCalls, 1);
    expect(await queue.load('user-a'), isEmpty);
  });

  test('skipped flush keeps the write without burning an attempt', () async {
    final queue = TrackerWriteQueue();
    final ctx = _episode();
    final key = trackerItemCoalesceKey(TrackerService.mdblist, ctx, trackerExternalRowIdentity(ctx.external))!;
    await queue.enqueue('user-a', _item(ctx: ctx, coalesceKey: key, attempts: 2));

    await _flushEach(queue, 'user-a', (item) async => TrackerWriteDisposition.skipped);

    final remaining = await queue.load('user-a');
    expect(remaining, hasLength(1));
    expect(remaining.single.attempts, 2);
  });

  test('newer per-item history intent replaces the older intent for its coalesce key', () async {
    final queue = TrackerWriteQueue();
    final ctx = _episode();
    final key = trackerItemCoalesceKey(TrackerService.mdblist, ctx, trackerExternalRowIdentity(ctx.external))!;
    await queue.enqueue('user-a', _item(ctx: ctx, coalesceKey: key));
    await queue.enqueue(
      'user-a',
      _item(ctx: ctx, coalesceKey: key, watched: false, watchedAtIso: '2026-05-13T00:00:00.000Z'),
    );

    final remaining = await queue.load('user-a');
    expect(remaining, hasLength(1));
    expect(remaining.single.watched, isFalse);
    expect(remaining.single.watchedAtIso, '2026-05-13T00:00:00.000Z');
  });

  test('coalescing retains the greatest monotonic claim for one key', () async {
    final queue = TrackerWriteQueue();
    final ctx = _episode();
    final key = trackerItemCoalesceKey(TrackerService.mdblist, ctx, trackerExternalRowIdentity(ctx.external))!;
    await queue.enqueue('user-a', _item(ctx: ctx, coalesceKey: key, progressClaim: 5));
    await queue.enqueue('user-a', _item(ctx: ctx, coalesceKey: key, progressClaim: 6));
    expect((await queue.load('user-a')).single.progressClaim, 6);

    await queue.enqueue('user-a', _item(ctx: ctx, coalesceKey: key, progressClaim: 5));
    final remaining = await queue.load('user-a');
    expect(remaining, hasLength(1));
    expect(remaining.single.progressClaim, 6);
  });

  test('invalidate drops outright or only claims covered by applied progress', () async {
    final queue = TrackerWriteQueue();
    final ctx = _episode();
    final key = trackerItemCoalesceKey(TrackerService.mdblist, ctx, trackerExternalRowIdentity(ctx.external))!;
    TrackerWriteQueueItem claim(int progress) => _item(ctx: ctx, coalesceKey: key, progressClaim: progress);

    await queue.enqueue('user-a', claim(5));
    await queue.invalidate('user-a', {key: null});
    expect(await queue.load('user-a'), isEmpty);

    await queue.enqueue('user-a', claim(5));
    await queue.invalidate('user-a', {key: 6});
    expect(await queue.load('user-a'), isEmpty);

    await queue.enqueue('user-a', claim(7));
    await queue.invalidate('user-a', {key: 6});
    final remaining = await queue.load('user-a');
    expect(remaining, hasLength(1));
    expect(remaining.single.progressClaim, 7);
  });

  group('batched drain', () {
    test('groups history rows by direction, capped per request', () async {
      final pauses = <Duration>[];
      final queue = TrackerWriteQueue(pause: (duration) async => pauses.add(duration));
      TrackerWriteQueueItem added(int number) => _item(
        ctx: _episode(ratingKey: 'episode-$number', episodeNumber: number),
        coalesceKey: _historyKey(TrackerService.mdblist, _episode(episodeNumber: number)),
      );
      const half = TrackerConstants.historyBatchSize ~/ 2;
      final rows = <TrackerWriteQueueItem>[
        for (var number = 1; number <= half; number++) added(number),
        _item(
          ctx: _episode(ratingKey: 'episode-removed', episodeNumber: 500),
          coalesceKey: _historyKey(TrackerService.mdblist, _episode(episodeNumber: 500)),
          watched: false,
        ),
        for (var number = half + 1; number <= TrackerConstants.historyBatchSize + 1; number++) added(number),
      ];
      await queue.enqueueAll('user-a', rows);

      final units = <List<String>>[];
      await queue.flush(
        'user-a',
        batches: (service) => service == TrackerService.mdblist,
        send: (unit) async {
          units.add([for (final row in unit) row.ctx.ratingKey]);
          return List.filled(unit.length, TrackerWriteDisposition.done);
        },
      );

      expect(units, [
        [for (var number = 1; number <= TrackerConstants.historyBatchSize; number++) 'episode-$number'],
        ['episode-removed'],
        ['episode-${TrackerConstants.historyBatchSize + 1}'],
      ], reason: 'additions batch around a removal, overflow starts a new request');
      expect(pauses, hasLength(units.length), reason: 'every request is followed by the service spacing');
      expect(await queue.load('user-a'), isEmpty);
    });

    test('applies each row its own disposition and keeps the survivors in queue order', () async {
      final queue = TrackerWriteQueue(pause: (_) async {});
      final rows = [
        for (var number = 1; number <= 3; number++)
          _item(
            ctx: _episode(ratingKey: 'episode-$number', episodeNumber: number),
            coalesceKey: _historyKey(TrackerService.mdblist, _episode(episodeNumber: number)),
            attempts: 1,
          ),
      ];
      await queue.enqueueAll('user-a', rows);

      await queue.flush(
        'user-a',
        batches: (_) => true,
        send: (unit) async => const [
          TrackerWriteDisposition.skipped,
          TrackerWriteDisposition.done,
          TrackerWriteDisposition.failed,
        ],
      );

      final remaining = await queue.load('user-a');
      expect(remaining.map((row) => row.ctx.ratingKey), ['episode-1', 'episode-3']);
      expect(remaining.map((row) => row.attempts), [1, 2], reason: 'only the failed row spends an attempt');
    });

    test('a deferred batch leaves the rest of that service for a later drain', () async {
      final queue = TrackerWriteQueue(pause: (_) async {});
      await queue.enqueueAll('user-a', [
        for (var number = 1; number <= TrackerConstants.historyBatchSize + 1; number++)
          _item(
            ctx: _episode(ratingKey: 'episode-$number', episodeNumber: number),
            coalesceKey: _historyKey(TrackerService.mdblist, _episode(episodeNumber: number)),
            service: TrackerService.mdblist,
          ),
      ]);

      var requests = 0;
      await queue.flush(
        'user-a',
        batches: (_) => true,
        send: (unit) async {
          requests++;
          return List.filled(unit.length, TrackerWriteDisposition.deferredService);
        },
      );

      expect(requests, 1, reason: 'a service that asked for quiet gets no second request in the same drain');
      final remaining = await queue.load('user-a');
      expect(remaining, hasLength(TrackerConstants.historyBatchSize + 1));
      expect(remaining.map((row) => row.attempts), everyElement(0));
    });
  });

  test('external identity and media coordinates prevent server-local rating-key collisions', () async {
    final queue = TrackerWriteQueue();
    final first = _episode(ratingKey: 'shared-rating-key', external: const ExternalIds(tvdb: 100));
    final second = _episode(ratingKey: 'shared-rating-key', external: const ExternalIds(tvdb: 200));
    final sameRemoteEpisode = _episode(ratingKey: 'different-local-key', external: const ExternalIds(tvdb: 100));
    final movie = _movie(ratingKey: 'shared-rating-key', external: const ExternalIds(tvdb: 100));

    final firstKey = trackerItemCoalesceKey(TrackerService.mdblist, first, trackerExternalRowIdentity(first.external))!;
    final secondKey = trackerItemCoalesceKey(
      TrackerService.mdblist,
      second,
      trackerExternalRowIdentity(second.external),
    )!;
    expect(firstKey, isNot(secondKey));
    expect(
      trackerItemCoalesceKey(
        TrackerService.mdblist,
        sameRemoteEpisode,
        trackerExternalRowIdentity(sameRemoteEpisode.external),
      ),
      firstKey,
    );
    expect(
      trackerItemCoalesceKey(TrackerService.mdblist, movie, trackerExternalRowIdentity(movie.external)),
      isNot(firstKey),
    );

    await queue.enqueue('user-a', _item(ctx: first, coalesceKey: firstKey));
    await queue.enqueue('user-a', _item(ctx: second, coalesceKey: secondKey));
    expect(await queue.load('user-a'), hasLength(2));
  });

  test('profile queues are isolated and flushing one never sends another profile writes', () async {
    final queue = TrackerWriteQueue();
    final first = _episode(ratingKey: 'first', external: const ExternalIds(tvdb: 100));
    final second = _episode(ratingKey: 'second', external: const ExternalIds(tvdb: 200));
    await queue.enqueue(
      'user-a',
      _item(
        ctx: first,
        coalesceKey: trackerItemCoalesceKey(TrackerService.mdblist, first, trackerExternalRowIdentity(first.external))!,
      ),
    );
    await queue.enqueue(
      'user-b',
      _item(
        ctx: second,
        coalesceKey: trackerItemCoalesceKey(TrackerService.mdblist, second, trackerExternalRowIdentity(second.external))!,
      ),
    );

    expect(await queue.load('user-a'), hasLength(1));
    expect(await queue.load('user-b'), hasLength(1));
    final sent = <String>[];
    await _flushEach(queue, 'user-a', (item) async {
      sent.add(item.ctx.ratingKey);
      return TrackerWriteDisposition.done;
    });

    expect(sent, ['first']);
    expect(await queue.load('user-a'), isEmpty);
    expect((await queue.load('user-b')).single.ctx.ratingKey, 'second');
  });

  test('disconnect purge drops the service rows so nothing replays', () async {
    final queue = TrackerWriteQueue();
    final firstCtx = _episode(ratingKey: 'first-episode', external: const ExternalIds(tvdb: 100));
    final firstKey = trackerItemCoalesceKey(
      TrackerService.mdblist,
      firstCtx,
      trackerExternalRowIdentity(firstCtx.external),
    )!;
    final secondCtx = _episode(ratingKey: 'second-episode', external: const ExternalIds(tvdb: 200));
    final secondKey = trackerItemCoalesceKey(
      TrackerService.mdblist,
      secondCtx,
      trackerExternalRowIdentity(secondCtx.external),
    )!;
    await queue.enqueue('user-a', _item(ctx: firstCtx, coalesceKey: firstKey));
    await queue.enqueue('user-a', _item(ctx: secondCtx, coalesceKey: secondKey));

    await queue.removeService('user-a', TrackerService.mdblist);

    expect(await queue.load('user-a'), isEmpty);

    final sent = <TrackerWriteQueueItem>[];
    await _flushEach(queue, 'user-a', (item) async {
      sent.add(item);
      return TrackerWriteDisposition.done;
    });

    expect(sent, isEmpty, reason: 'the purged service must not dispatch');
  });

  test('a persist-failure enqueue racing the disconnect purge cannot resurrect the row', () async {
    final platform = _FailingQueuePreferences();
    SharedPreferencesAsyncPlatform.instance = platform;
    BaseSharedPreferencesService.resetForTesting();

    final queue = TrackerWriteQueue();
    final ctx = _episode();
    final key = trackerItemCoalesceKey(TrackerService.mdblist, ctx, trackerExternalRowIdentity(ctx.external))!;

    // The enqueue claims its lock slot synchronously, then its persist fails
    // and the row can only be buffered in memory. The purge claims the next
    // slot in the same synchronous segment — the interleaving of a write
    // failing while the user disconnects the service.
    platform.failQueueWrites = true;
    final enqueue = queue.enqueue('user-a', _item(ctx: ctx, coalesceKey: key));
    final purge = queue.removeService('user-a', TrackerService.mdblist);
    await enqueue;
    await purge;
    platform.failQueueWrites = false;

    final sent = <TrackerWriteQueueItem>[];
    await _flushEach(queue, 'user-a', (item) async {
      sent.add(item);
      return TrackerWriteDisposition.done;
    });

    expect(sent, isEmpty, reason: 'the buffered row was created under the disconnected account');
    expect(await queue.load('user-a'), isEmpty);
  });

  test('legacy Trakt rows are inert now that the migration is gone', () async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    const user = 'legacy-user';
    final legacyKey = profileScopedPrefsKey(user, 'trakt_sync_queue');
    const legacyPayload = '[{"op":"add","ratingKey":"legacy-episode","serverId":"server-1",'
        '"libraryGlobalKey":"server-1:7","kind":"episode","ids":{"tvdb":123},'
        '"season":3,"number":4,"watchedAtIso":"2026-05-12T00:00:00.000Z","attempts":2}]';
    await prefs.setString(legacyKey, legacyPayload);

    final queue = TrackerWriteQueue();
    expect(await queue.load(user), isEmpty, reason: 'the legacy Trakt queue no longer migrates');
    expect(prefs.getString(legacyKey), legacyPayload, reason: 'the inert key is left alone');
  });

  test('corrupt tracker queue payload is archived and discarded without throwing', () async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    const user = 'corrupt-user';
    const corruptPayload = '{not valid json';
    final queueKey = profileScopedPrefsKey(user, 'tracker_write_queue');
    final archiveKey = profileScopedPrefsKey(user, 'tracker_write_queue_corrupt');
    await prefs.setString(queueKey, corruptPayload);

    final queue = TrackerWriteQueue();
    expect(await queue.load(user), isEmpty);
    expect(prefs.getString(queueKey), isNull);
    expect(prefs.getString(archiveKey), corruptPayload);
  });
}

/// Fails writes to the tracker queue key while armed, simulating the disk
/// full/revoked-storage case that feeds the in-memory fallback.
/// `SharedPreferencesWithCache` sits above the platform and is not
/// subclassable, so the failure is injected here.
final class _FailingQueuePreferences extends InMemorySharedPreferencesAsync {
  _FailingQueuePreferences() : super.empty();

  bool failQueueWrites = false;

  @override
  Future<bool> setString(String key, String value, SharedPreferencesOptions options) async {
    if (failQueueWrites && key.contains('tracker_write_queue')) {
      throw StateError('simulated persist failure');
    }
    return super.setString(key, value, options);
  }
}
