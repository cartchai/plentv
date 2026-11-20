import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/downloads_media_store.dart';

// 1.6.11 X11 — the native finalize reply was delivered from a worker
// thread, so the Dart side could wait forever for a finalize that
// already ran. The Dart future now times out (10 minutes in production;
// shortened here) and reports false instead of hanging.
//
// Failing-first shape: on base there is no timeout at all, so the
// never-replying mock leaves the first test hanging until the test
// runner's own timeout fails it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.plentv.app/downloads');

  tearDown(() {
    DownloadsMediaStore.debugFinalizeEntryOverride = null;
    DownloadsMediaStore.debugFinalizeTimeout = const Duration(minutes: 10);
    DownloadsMediaStore.debugSweepOrphanedPendingEntriesOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('a lost native finalize reply returns false instead of hanging', () async {
    DownloadsMediaStore.debugFinalizeTimeout = const Duration(milliseconds: 50);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async {
        if (call.method == 'finalizeDownloadEntry') {
          // Never replies, like the worker-thread reply drop.
          return Completer<bool>().future;
        }
        return null;
      },
    );
    final result = await DownloadsMediaStore.finalizeDownloadEntry(
      finalPath: '/x/f.mp4',
      partPath: '/x/f.mp4.part',
    );
    expect(result, isFalse);
  });

  // 1.6.11 X10 — the orphan sweep wrapper. Failing-first shape: on
  // base the method does not exist, so this file fails to compile there.
  test('sweep returns the native counts', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async {
        if (call.method == 'sweepOrphanedPendingEntries') {
          expect(call.arguments['knownPaths'], ['/a/kept.mp4']);
          return {'shown': 2, 'deleted': 1, 'failed': 1};
        }
        return null;
      },
    );
    final swept = await DownloadsMediaStore.sweepOrphanedPendingEntries(knownPaths: ['/a/kept.mp4']);
    expect((swept.shown, swept.deleted, swept.failed), (2, 1, 1));
  });

  test('sweep returns zeros when the channel is unavailable', () async {
    final swept = await DownloadsMediaStore.sweepOrphanedPendingEntries(knownPaths: const []);
    expect((swept.shown, swept.deleted, swept.failed), (0, 0, 0));
  });

  test('a prompt native reply still returns its value', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'finalizeDownloadEntry' ? true : null,
    );
    expect(
      await DownloadsMediaStore.finalizeDownloadEntry(finalPath: '/x/f.mp4', partPath: '/x/f.mp4.part'),
      isTrue,
    );
  });
}
