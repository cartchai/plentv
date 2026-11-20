import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/trackers/tracker_context.dart';
import 'package:plezy/providers/trackers_provider.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/trackers/mdblist/mdblist_tracker.dart';
import 'package:plezy/services/trackers/tracker_account_store.dart';
import 'package:plezy/services/trackers/tracker_constants.dart';
import 'package:plezy/services/trackers/tracker_coordinator.dart';
import 'package:plezy/services/trackers/tracker_session.dart';
import 'package:plezy/services/trackers/tracker_write_queue.dart';
import 'package:plezy/utils/external_ids.dart';

import '../test_helpers/io_fakes.dart';
import '../test_helpers/prefs.dart';

final _mdblistStore = trackerAccountStore(TrackerService.mdblist);

/// An MDBList session as a fresh sign-in produces: 30-day access token plus
/// a refresh token.
TrackerSession _session(String owner) => TrackerSession(
  accessToken: '$owner-mdblist-at',
  refreshToken: '$owner-mdblist-rt',
  expiresAt: 2000000000,
  createdAt: 1900000000,
  username: owner,
);

TrackerSession _sessionWithToken({required String accessToken, String refreshToken = 'mdblist-rt'}) =>
    TrackerSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: 2000000000,
      createdAt: 1900000000,
    );

Future<void> _bindProfile(TrackersProvider provider, String? userUuid) async {
  await provider.onActiveProfileChanged(userUuid);
  await TrackerCoordinator.instance.flushWriteQueue();
}

/// A queued watched write, as a failed live write would leave it.
TrackerWriteQueueItem _queuedItem() {
  final ctx = TrackerContext.movie(
    external: const ExternalIds(tmdb: 456),
    ratingKey: 'movie-1',
    libraryGlobalKey: 'server-1:8',
  );
  return TrackerWriteQueueItem(
    service: TrackerService.mdblist,
    watched: true,
    ctx: ctx,
    coalesceKey: trackerItemCoalesceKey(
      TrackerService.mdblist,
      ctx,
      trackerExternalRowIdentity(ctx.external),
    )!,
    progressClaim: null,
    watchedAtIso: '2026-05-12T00:00:00.000Z',
  );
}

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    _resetTrackerBindings();
  });
  tearDown(_resetTrackerBindings);

  group('TrackersProvider', () {
    test('starts disconnected', () {
      final p = TrackersProvider();
      expect(p.mdblist, isNull);
      expect(p.isMdblistConnected, isFalse);
      expect(p.mdblistCatalogClient, isNull);
      expect(p.mdblistUsername, isNull);
      expect(p.isConnecting(TrackerService.mdblist), isFalse);
      p.dispose();
    });

    test('forTesting owns one fresh client for the eager auth owner', () {
      final clients = <FakeHttpClient>[];
      final p = TrackersProvider.forTesting(
        connectPipeline: _ControlledConnectPipeline(_session('alice')).call,
        httpClientFactory: () {
          final client = FakeHttpClient(200, const <int>[]);
          clients.add(client);
          return client;
        },
      );

      // 1: only the MDBList auth owner remains (1.5.2 removed the other four
      // trackers). The MAL OAuth-proxy client was already gone since 1.3.23.
      expect(clients, hasLength(1));
      expect(clients.single.closeCount, 0);

      p.dispose();

      expect(clients.single.closeCount, 1);
      expect(clients.single.isClosed, isTrue);
    });

    test('onActiveProfileChanged loads the session from the per-profile store', () async {
      const uuid = 'profile-1';
      await _mdblistStore.save(uuid, _session('eve'));
      // Reset cached singletons so the provider reads fresh prefs state.
      BaseSharedPreferencesService.resetForTesting();

      final p = TrackersProvider();
      var notified = 0;
      p.addListener(() => notified++);

      await _bindProfile(p, uuid);
      expect(p.isMdblistConnected, isTrue);
      expect(p.mdblistUsername, 'eve');
      expect(p.mdblistCatalogClient, same(MdblistTracker.instance.client));
      expect(notified, greaterThanOrEqualTo(1));

      p.dispose();
    });

    test('onActiveProfileChanged switching to empty profile clears the session', () async {
      const uuid = 'profile-1';
      await _mdblistStore.save(uuid, _session('eve'));
      BaseSharedPreferencesService.resetForTesting();

      final p = TrackersProvider();
      await _bindProfile(p, uuid);
      expect(p.isMdblistConnected, isTrue);

      await _bindProfile(p, 'other-profile');
      expect(p.isMdblistConnected, isFalse);
      expect(p.mdblistCatalogClient, isNull);

      p.dispose();
    });

    test('onActiveProfileChanged loads only the populated store', () async {
      const uuid = 'profile-2';
      await _mdblistStore.save(uuid, _session('eve'));
      BaseSharedPreferencesService.resetForTesting();

      final p = TrackersProvider();
      await _bindProfile(p, uuid);
      expect(p.isMdblistConnected, isTrue);
      expect(p.mdblistUsername, 'eve');
      p.dispose();

      final q = TrackersProvider();
      await _bindProfile(q, 'profile-with-nothing');
      expect(q.isMdblistConnected, isFalse);
      q.dispose();
    });

    test('disconnectMdblist clears stored session and notifies', () async {
      const uuid = 'profile-3';
      await _mdblistStore.save(uuid, _session('eve'));
      BaseSharedPreferencesService.resetForTesting();

      final p = TrackersProvider();
      await _bindProfile(p, uuid);
      expect(p.isMdblistConnected, isTrue);

      var notified = 0;
      p.addListener(() => notified++);

      await p.disconnectMdblist();
      expect(p.isMdblistConnected, isFalse);
      expect(p.mdblist, isNull);
      // _clearAndRebind notifies once.
      expect(notified, 1);

      // Persistence is cleared too.
      expect(await _mdblistStore.load(uuid), isNull);

      p.dispose();
    });

    test('session invalidation purges the queued writes so the next account cannot replay them', () async {
      const uuid = 'profile-invalidated';
      await _mdblistStore.save(uuid, _session('eve'));
      BaseSharedPreferencesService.resetForTesting();

      final queue = TrackerWriteQueue();
      await queue.enqueue(uuid, _queuedItem());

      final p = TrackersProvider();
      await _bindProfile(p, uuid);
      expect(p.isMdblistConnected, isTrue);

      // Fire the auth-failure teardown exactly as the client does on a 401.
      MdblistTracker.instance.client!.onSessionInvalidated();
      expect(p.isMdblistConnected, isFalse);
      await pumpEventQueue();

      // Account B connecting starts with a flush; nothing of A's may be waiting.
      await TrackerCoordinator.instance.flushWriteQueue();
      final survivors = await queue.load(uuid);
      expect(survivors, isEmpty, reason: 'the invalidated service rows must not wait for the next account');
      expect(await _mdblistStore.load(uuid), isNull);

      p.dispose();
    });

    test('disconnect during an in-flight profile load does not resurrect the session', () async {
      const uuid = 'profile-race';
      await _mdblistStore.save(uuid, _session('eve'));
      BaseSharedPreferencesService.resetForTesting();

      final p = TrackersProvider();
      // Start the load, then disconnect before it resolves.
      final load = _bindProfile(p, uuid);
      await p.disconnectMdblist();
      await load;

      // The session stays disconnected (and cleared) — the racing load must
      // not resurrect it.
      expect(p.isMdblistConnected, isFalse);
      expect(await _mdblistStore.load(uuid), isNull);

      p.dispose();
    });

    test('disconnectMdblist on a profile with no session is safe', () async {
      final p = TrackersProvider();
      // No `onActiveProfileChanged` — uuid is empty (global slot).
      // disconnectMdblist just clears the (already absent) entry and rebinds.
      await p.disconnectMdblist();
      expect(p.isMdblistConnected, isFalse);
      p.dispose();
    });

    test('cancelConnect is a no-op when not connecting', () {
      final p = TrackersProvider();
      expect(() => p.cancelConnect(), returnsNormally);
      expect(p.isConnecting(TrackerService.mdblist), isFalse);
      p.dispose();
    });

    test('safeNotifyListeners after dispose is a no-op', () async {
      final p = TrackersProvider();
      p.dispose();
      // Post-dispose rebind should not throw.
      await _bindProfile(p, 'any-uuid');
    });

    test('stale connect cannot save or replace a newer binding after dispose', () async {
      const oldUuid = 'profile-old';
      const newUuid = 'profile-new';
      final oldSession = _session('old');
      final newSession = _session('new');
      await _mdblistStore.save(newUuid, newSession);
      BaseSharedPreferencesService.resetForTesting();

      final pipeline = _ControlledConnectPipeline(oldSession);
      final oldProvider = TrackersProvider.forTesting(connectPipeline: pipeline.call);
      await _bindProfile(oldProvider, oldUuid);
      final connect = oldProvider.connectMdblist(onCodeReady: (_) {});
      await pipeline.beforeSave.future;

      oldProvider.dispose();
      final newProvider = TrackersProvider();
      await _bindProfile(newProvider, newUuid);
      final newBinding = MdblistTracker.instance.client;
      expect(newBinding, isNotNull);
      expect(newProvider.mdblist?.accessToken, newSession.accessToken);

      pipeline.releaseBeforeSave.complete();
      expect(await connect, isFalse);
      expect(await _mdblistStore.load(oldUuid), isNull);
      expect((await _mdblistStore.load(newUuid))?.accessToken, newSession.accessToken);
      expect(MdblistTracker.instance.client, same(newBinding));
      expect(MdblistTracker.instance.client?.session.accessToken, newSession.accessToken);
      expect(oldProvider.mdblist, isNull);

      newProvider.dispose();
    });

    test('cancel invalidates a connect after authorization and before save', () async {
      const uuid = 'profile-cancel';
      final pipeline = _ControlledConnectPipeline(_session('cancelled'));
      final p = TrackersProvider.forTesting(connectPipeline: pipeline.call);
      await _bindProfile(p, uuid);

      final connect = p.connectMdblist(onCodeReady: (_) {});
      await pipeline.beforeSave.future;
      p.cancelConnect();
      pipeline.releaseBeforeSave.complete();

      expect(await connect, isFalse);
      expect(p.isConnecting(TrackerService.mdblist), isFalse);
      expect(p.mdblist, isNull);
      expect(await _mdblistStore.load(uuid), isNull);
      expect(MdblistTracker.instance.client, isNull);
      p.dispose();
    });

    test('profile change invalidates the old connect and preserves the new binding', () async {
      const oldUuid = 'profile-change-old';
      const newUuid = 'profile-change-new';
      final oldSession = _session('old');
      final newSession = _session('new');
      await _mdblistStore.save(newUuid, newSession);
      BaseSharedPreferencesService.resetForTesting();

      final pipeline = _ControlledConnectPipeline(oldSession);
      final p = TrackersProvider.forTesting(connectPipeline: pipeline.call);
      await _bindProfile(p, oldUuid);
      final connect = p.connectMdblist(onCodeReady: (_) {});
      await pipeline.beforeSave.future;

      await _bindProfile(p, newUuid);
      final newBinding = MdblistTracker.instance.client;
      pipeline.releaseBeforeSave.complete();

      expect(await connect, isFalse);
      expect(await _mdblistStore.load(oldUuid), isNull);
      expect((await _mdblistStore.load(newUuid))?.accessToken, newSession.accessToken);
      expect(p.mdblist?.accessToken, newSession.accessToken);
      expect(MdblistTracker.instance.client, same(newBinding));
      expect(MdblistTracker.instance.client?.session.accessToken, newSession.accessToken);
      p.dispose();
    });

    test('same-service disconnect invalidates an in-flight connect', () async {
      const uuid = 'profile-same-disconnect';
      final pipeline = _ControlledConnectPipeline(_session('late'));
      final p = TrackersProvider.forTesting(connectPipeline: pipeline.call);
      await _bindProfile(p, uuid);
      final connect = p.connectMdblist(onCodeReady: (_) {});
      await pipeline.beforeSave.future;

      await p.disconnectMdblist();
      pipeline.releaseBeforeSave.complete();

      expect(await connect, isFalse);
      expect(p.mdblist, isNull);
      expect(await _mdblistStore.load(uuid), isNull);
      expect(MdblistTracker.instance.client, isNull);
      p.dispose();
    });

    test('dispose after save cannot assign or erase a newer same-profile binding', () async {
      const uuid = 'profile-save-race';
      final staleSession = _session('stale');
      final freshSession = _session('fresh');
      final pipeline = _ControlledConnectPipeline(staleSession, pauseAfterSave: true);
      final staleProvider = TrackersProvider.forTesting(connectPipeline: pipeline.call);
      await _bindProfile(staleProvider, uuid);
      final connect = staleProvider.connectMdblist(onCodeReady: (_) {});
      await pipeline.beforeSave.future;
      pipeline.releaseBeforeSave.complete();
      await pipeline.afterSave.future;

      staleProvider.dispose();
      await _mdblistStore.save(uuid, freshSession);
      BaseSharedPreferencesService.resetForTesting();
      final freshProvider = TrackersProvider();
      await _bindProfile(freshProvider, uuid);
      final freshBinding = MdblistTracker.instance.client;
      pipeline.releaseAfterSave.complete();

      expect(await connect, isFalse);
      expect((await _mdblistStore.load(uuid))?.accessToken, freshSession.accessToken);
      expect(MdblistTracker.instance.client, same(freshBinding));
      expect(MdblistTracker.instance.client?.session.accessToken, freshSession.accessToken);
      expect(staleProvider.mdblist, isNull);
      freshProvider.dispose();
    });

    test('a refreshed MDBList session is persisted and published', () async {
      const uuid = 'profile-mdblist-refresh';
      await _mdblistStore.save(uuid, _sessionWithToken(accessToken: 'mdblist_at_old'));
      BaseSharedPreferencesService.resetForTesting();

      final p = TrackersProvider();
      await _bindProfile(p, uuid);
      var notified = 0;
      p.addListener(() => notified++);

      // Fire the refresh publication exactly as the client does.
      MdblistTracker.instance.client!.onSessionUpdated!(_sessionWithToken(accessToken: 'mdblist_at_new'));
      await pumpEventQueue();

      expect(p.mdblist?.accessToken, 'mdblist_at_new');
      expect((await _mdblistStore.load(uuid))?.accessToken, 'mdblist_at_new');
      expect(notified, 1);
      p.dispose();
    });
  });
}

void _resetTrackerBindings() {
  MdblistTracker.instance.rebindSession(null, onSessionInvalidated: () {});
}

class _ControlledConnectPipeline {
  _ControlledConnectPipeline(this.session, {this.pauseAfterSave = false});

  final TrackerSession session;
  final bool pauseAfterSave;
  final beforeSave = Completer<void>();
  final releaseBeforeSave = Completer<void>();
  final afterSave = Completer<void>();
  final releaseAfterSave = Completer<void>();

  Future<bool> call({
    required String logLabel,
    required Future<TrackerSession?> Function() authorize,
    required Future<TrackerSession> Function(TrackerSession raw) enrich,
    required Future<void> Function(TrackerSession enriched) save,
    required void Function(TrackerSession enriched) assign,
  }) async {
    beforeSave.complete();
    await releaseBeforeSave.future;
    await save(session);
    afterSave.complete();
    if (pauseAfterSave) await releaseAfterSave.future;
    assign(session);
    return true;
  }
}
