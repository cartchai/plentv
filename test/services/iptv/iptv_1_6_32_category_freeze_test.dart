// PlenTV 1.6.32 — category-groups freeze fix + category reorder.
//
// The toggle freeze (GitHub #8, previous-exit ANR "Input dispatching
// timed out" while toggling a whole region group): the toggle fired a
// cascade that rebuilt the whole ~26k-row Live TV guide synchronously
// on the UI thread — ~3–7+ s of unbroken work past Android's 5 s ANR
// line. The Reload TV details path (#9, same ANR at only 302 MB RSS)
// proved memory was not a contributor: the fix is getting the work off
// the UI thread, not a memory fix.
//
// Failing-first: the T1 tests use `materializeLiveGuideAsync`, which
// does not exist on base 6493fbbfe — the file does not compile there,
// so every T1 test fails on base and passes on the fix. The T2 tier-table
// test pins the numbers the gate now returns on Android, but the table
// itself is unchanged from base — the gate's Android branch is
// host-untestable (Platform.isAndroid is false in the runner), so its
// failing-first proof is the diff (base: 45%-of-RAM formula, 1536 MB on
// the Streamer; fix: the tier getter, 600 MB), not a test run.
//
// The sort (option 5) and dedupe (option 5) live inline in the Live TV
// screen's `_loadChannels` and the hide-only filter / fingerprint skip
// (options 2/4) live inside `IptvClient._rederiveMemosFromDisk` —
// neither is reachable from a unit test without pumping the screen, so
// those are proven by code inspection (the decorated sort parses each
// number once; the dedupe key is computed from the un-scoped channel
// before `copyWith`; the hide-only path filters the cached list and
// the fingerprint is skipped when only the hidden filter changed).
// Only the TV can prove the freeze itself is gone.

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/iptv_playlist_fingerprint.dart';
import 'package:plezy/services/device_performance.dart';
import 'package:plezy/services/iptv/iptv_heavy_work_gate.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

const _connId = 'conn-xt-1';

const _liveRows = [
  XtreamLiveStream(streamId: 1, name: 'EN News', categoryId: 'live1'),
  XtreamLiveStream(streamId: 2, name: 'EN Sport', categoryId: 'live1'),
  XtreamLiveStream(streamId: 3, name: 'AR Live', categoryId: 'live2'),
];

const _liveCategories = {
  'live1': '|EN| News',
  'live2': 'AR - Live',
};

void main() {
  group('option 1 — guide materialization off the UI thread', () {
    late IptvSearchIndex index;

    setUp(() {
      index = IptvSearchIndex.memory();
      index.replaceType(
        connectionId: _connId,
        type: IptvSearchIndex.typeLive,
        rows: _liveRows.map(IptvSearchIndexRow.fromLive).toList(),
        categories: _liveCategories,
        syncStampMs: 1,
      );
      addTearDown(index.close);
    });

    test('T1a: materializes every visible row as a channel + a stream', () async {
      final result = await index.materializeLiveGuideAsync(
        _connId,
        hiddenIds: const {},
        hiddenInitials: const {},
        serverId: 'srv-1',
        serverName: 'Trex',
        computeFingerprint: true,
      );

      expect(result.channels.map((c) => c.title), ['EN News', 'EN Sport', 'AR Live']);
      expect(result.streams.map((s) => s.streamId), [1, 2, 3]);
      // The isolate path must keep the stream map populated — playback
      // and the EPG read `_xtreamChannelByKey` (streamId -> stream).
      expect(result.streams.map((s) => s.name), ['EN News', 'EN Sport', 'AR Live']);
      expect(result.channels.every((c) => c.serverId == 'srv-1' && c.serverName == 'Trex'), isTrue);
    });

    test('T1b: the fingerprint matches the synchronous path over the same rows', () async {
      final result = await index.materializeLiveGuideAsync(
        _connId,
        hiddenIds: const {},
        hiddenInitials: const {},
        serverId: 'srv-1',
        serverName: 'Trex',
        computeFingerprint: true,
      );

      final expected = iptvPlaylistFingerprint(
        _liveRows.map((r) => iptvPlaylistRowHash([r.streamId, r.name, r.epgChannelId])),
      );
      expect(result.fingerprint, expected,
          reason: 'a fingerprint stored by the isolate path must match the sync path, or the guide re-derives on every load');
    });

    test('T1c: a hidden category is excluded from the channels AND the fingerprint', () async {
      final result = await index.materializeLiveGuideAsync(
        _connId,
        hiddenIds: const {'live2'},
        hiddenInitials: const {},
        serverId: 'srv-1',
        serverName: 'Trex',
        computeFingerprint: true,
      );

      expect(result.channels.map((c) => c.title), ['EN News', 'EN Sport']);
      expect(result.streams.map((s) => s.streamId), [1, 2]);
      final expected = iptvPlaylistFingerprint(
        _liveRows
            .where((r) => r.categoryId != 'live2')
            .map((r) => iptvPlaylistRowHash([r.streamId, r.name, r.epgChannelId])),
      );
      expect(result.fingerprint, expected,
          reason: 'the fingerprint is hashed over the hidden-filtered rows, so hiding a category does not look like a playlist change');
    });

    test('T1d: a hidden initial excludes its categories', () async {
      final result = await index.materializeLiveGuideAsync(
        _connId,
        hiddenIds: const {},
        hiddenInitials: const {'AR'},
        serverId: 'srv-1',
        serverName: 'Trex',
        computeFingerprint: true,
      );

      expect(result.channels.map((c) => c.title), ['EN News', 'EN Sport']);
    });

    test('T1e: no fingerprint is computed when the caller does not ask for one', () async {
      final result = await index.materializeLiveGuideAsync(
        _connId,
        hiddenIds: const {},
        hiddenInitials: const {},
        serverId: 'srv-1',
        serverName: 'Trex',
        computeFingerprint: false,
      );

      expect(result.channels, hasLength(3));
      expect(result.fingerprint, isNull);
    });
  });

  group('option 7 — the heavy-work gate reads the real watchdog line', () {
    test('T2: the tier table pins the Android thresholds the gate now returns', () {
      // The gate's Android branch is host-untestable (Platform.isAndroid
      // is false in the test runner), so the failing-first proof for the
      // gate change itself is the diff: base read 45% of RAM, clamped
      // [512 MB, 1536 MB] — 1536 MB on the Streamer, above its real
      // 600 MB kill line — while the fix returns the tier threshold
      // from DevicePerformance, the same number main.dart's RSS watchdog
      // already uses. This pins that table: a mid-tier TV (Streamer)
      // gets 600 MB and a low-tier TV (Hisense) gets 330 MB, both below
      // the RAM formula's floor.
      expect(DevicePerformance.watchdogBudgetFor(DeviceTier.mid).thresholdBytes, 600 << 20);
      expect(DevicePerformance.watchdogBudgetFor(DeviceTier.low).thresholdBytes, 330 << 20);
      expect(DevicePerformance.watchdogBudgetFor(DeviceTier.standard).thresholdBytes, 450 << 20);
      expect(DevicePerformance.watchdogBudgetFor(DeviceTier.survival).thresholdBytes, 260 << 20);
    });

    test('T2b: the desktop threshold is unchanged at 1536 MB', () {
      expect(IptvHeavyWorkGate.watchdogThresholdBytes(), 1536 << 20);
    });

    test('T2c: the forced-hot seam drives isMemoryHot', () {
      IptvHeavyWorkGate.debugForceMemoryHot = true;
      addTearDown(() => IptvHeavyWorkGate.debugForceMemoryHot = null);
      expect(IptvHeavyWorkGate.isMemoryHot, isTrue);
      IptvHeavyWorkGate.debugForceMemoryHot = false;
      expect(IptvHeavyWorkGate.isMemoryHot, isFalse);
    });
  });
}
