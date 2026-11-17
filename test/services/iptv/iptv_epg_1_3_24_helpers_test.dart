// 1.3.24 §67 — the EPG fix, pure-helper tests (no client needed).
//
// F6: iptvPlaylistFingerprint names the set, not the order.
// F8: the cadence helpers log every decision they record.
//
// This file references the new 1.3.24 APIs directly, so on the 1.3.23
// base (92a82e6e1, via `git stash push --keep-index`) it fails to
// load — that is the failing-first signal for these two. The
// behaviour tests that must fail by assertion on base live in
// iptv_epg_1_3_24_test.dart, which references no new API.
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/lowend/epg_cadence_log.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/app_logger.dart';

import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    MemoryLogOutput.clearLogs();
    EpgCadenceLog.debugReset();
  });

  test('F6: iptvPlaylistFingerprint names the set, not the order', () {
    expect(iptvPlaylistFingerprint([3, 1, 2]), iptvPlaylistFingerprint([1, 2, 3]));
    expect(iptvPlaylistFingerprint([1, 2, 3]), iptvPlaylistFingerprint([3, 2, 1]));
    expect(iptvPlaylistFingerprint([1, 2, 3]), isNot(iptvPlaylistFingerprint([1, 2, 4])));
    expect(
      iptvPlaylistFingerprint([1, 1, 2]),
      isNot(iptvPlaylistFingerprint([1, 2])),
      reason: 'a duplicated row is part of the set',
    );
  });

  test('F8: the cadence helpers log every decision they record', () {
    final quiet = EpgCadenceLog.recordQuietHourDecision(
      refreshed: false,
      reason: 'stamp-fresh',
      lastData: DateTime.utc(2026, 11, 16, 4),
    );
    expect(quiet, contains('refreshed=false'));
    expect(quiet, contains('reason=stamp-fresh'));
    expect(quiet, contains('lastData=2026-11-16T04:00:00.000Z'));

    final fingerprint = EpgCadenceLog.recordFingerprintDecision(
      refreshed: true,
      reason: 'playlist-changed',
      stored: 11,
      fresh: 22,
    );
    expect(fingerprint, contains('refreshed=true'));
    expect(fingerprint, contains('stored=11'));
    expect(fingerprint, contains('fresh=22'));

    final sweep = EpgCadenceLog.recordSweepPass(
      pass: 2,
      started: 5,
      skippedLoaded: 3,
      skippedFailed: 1,
      skippedInFlight: 0,
      blockedByPlayback: false,
    );
    expect(sweep, contains('pass=2'));
    expect(sweep, contains('started=5'));
    expect(sweep, contains('skippedLoaded=3'));
    expect(sweep, contains('blockedByPlayback=false'));

    final deferred = EpgCadenceLog.recordEpgClearDeferred(reason: 'feed-job-in-flight');
    expect(deferred, contains('deferred'));
    expect(deferred, contains('feed-job-in-flight'));

    final lines = MemoryLogOutput.getLogs().map((e) => e.message).toList();
    expect(lines, contains(quiet));
    expect(lines, contains(fingerprint));
    expect(lines, contains(sweep));
    expect(lines, contains(deferred));
  });
}
