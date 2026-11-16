import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/app_logger.dart';

import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

/// 1.2.22 §63.2 (bug 2) — short-EPG retry storm.
///
/// The 1.2.19 log showed one channel's short-EPG requests aborting 7x
/// in 8 s: N concurrent fetches for one channel each opened their own
/// `get_short_epg` call, and every scroll-away cancel logged a warning.
/// The fix: a per-channel in-flight join (same pattern as the 1.2.20 C3
/// warm-start join) + an abort cooldown (3 aborts in 10 s → no refetch
/// until the window passes or tap-retry) + cancellation logging demoted
/// to debug + cancel only when the last waiter leaves.
///
/// Failing-first on the 1.2.21 base: 2a (two calls, no join), 2b (the
/// 4th fetch calls getShortEpg — no cooldown), 2c (the cancel kills the
/// second fetch — no waiter counting). F3 is a lock-in: it passes on
/// base too (a cancelled fetch already refetches cleanly) and pins the
/// behaviour.

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

XtreamEpgProgram _epg({
  String id = 'p1',
  String title = 'Show',
  required DateTime start,
  required DateTime end,
}) => XtreamEpgProgram(
  id: id,
  title: title,
  description: '',
  startTimestamp: start.millisecondsSinceEpoch ~/ 1000,
  stopTimestamp: end.millisecondsSinceEpoch ~/ 1000,
  channelId: 'provider-ch',
);

/// Fake provider: the short-EPG call waits on [shortEpgGate] when set,
/// and honours the abort trigger the way the real transport does (an
/// abort while gated throws a cancellation). The feed is an empty
/// document, so a short-EPG answer stands on its own.
class _JoinFakeApi extends XtreamApi {
  _JoinFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  var shortEpgCalls = 0;
  Completer<void>? shortEpgGate;
  List<XtreamEpgProgram> scripted = const [];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async {
    shortEpgCalls++;
    final gate = shortEpgGate;
    if (gate != null) {
      final abort = abortTrigger;
      if (abort != null) {
        await Future.any([
          gate.future,
          abort.then(
            (_) => throw MediaServerHttpException(
              type: MediaServerHttpErrorType.cancelled,
              message: 'Operation cancelled',
            ),
          ),
        ]);
      } else {
        await gate.future;
      }
    }
    return scripted;
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    return (
      bytes: Stream<List<int>>.value(utf8.encode('<?xml version="1.0" encoding="UTF-8"?><tv></tv>')),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
    XtreamLiveStream(streamId: 101, name: 'Channel 101', epgChannelId: 'ch101'),
  ];
}

bool _isCancellation(Object e) {
  try {
    return MediaServerHttpException.from(e).isCancellation;
  } catch (_) {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _JoinFakeApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    MemoryLogOutput.clearLogs();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_2_22_join_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _JoinFakeApi();
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt == 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  Future<IptvLiveTvSupport> supportFor() async {
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    await client.iptvChannels();
    return client.liveTv as IptvLiveTvSupport;
  }

  Future<void> waitForShortEpgCalls(int n) async {
    for (var i = 0; i < 100; i++) {
      if (api.shortEpgCalls >= n) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('getShortEpg was not called $n times (got ${api.shortEpgCalls})');
  }

  test('2a concurrent fetches for one channel share one short-EPG call', () async {
    final now = DateTime.now();
    api.scripted = [_epg(start: now.subtract(const Duration(minutes: 30)), end: now.add(const Duration(minutes: 90)))];
    final gate = Completer<void>();
    api.shortEpgGate = gate;
    final support = await supportFor();
    final from = now.subtract(const Duration(hours: 1));
    final to = now.add(const Duration(hours: 2));

    final first = support.fetchEpgForChannel('100', from: from, to: to);
    final second = support.fetchEpgForChannel('100', from: from, to: to);
    await waitForShortEpgCalls(1);
    gate.complete();
    final firstPrograms = await first;
    final secondPrograms = await second;

    expect(api.shortEpgCalls, 1, reason: 'the second fetch joins the first instead of opening its own call');
    expect(firstPrograms.map((p) => p.title), contains('Show'));
    expect(secondPrograms.map((p) => p.title), contains('Show'));
  });

  test('2b three aborts in 10 s start a cooldown, lifted after the window', () async {
    final now = DateTime.now();
    api.scripted = [_epg(start: now.subtract(const Duration(minutes: 30)), end: now.add(const Duration(minutes: 90)))];
    final support = await supportFor();
    final from = now.subtract(const Duration(hours: 1));
    final to = now.add(const Duration(hours: 2));

    // Abort the same channel three times in quick succession.
    for (var attempt = 0; attempt < 3; attempt++) {
      api.shortEpgGate = Completer<void>();
      final fetch = support.fetchEpgForChannel('100', from: from, to: to);
      await waitForShortEpgCalls(attempt + 1);
      support.cancelEpgFetchForChannel('100');
      await expectLater(fetch, throwsA(predicate<Object>(_isCancellation, 'is a cancellation')));
    }
    expect(api.shortEpgCalls, 3);

    // The 4th fetch, inside the cooldown, must NOT open a new call.
    api.shortEpgGate = Completer<void>();
    final cooled = support.fetchEpgForChannel('100', from: from, to: to);
    await expectLater(cooled, throwsA(predicate<Object>(_isCancellation, 'is a cancellation')));
    expect(api.shortEpgCalls, 3, reason: 'the cooldown suppresses the refetch');
    final cooldownWarnings = MemoryLogOutput.getLogs()
        .where((e) => e.message.contains('backing off'))
        .toList();
    expect(cooldownWarnings.length, 1, reason: 'one warning per burst, not one per abort');

    // After the window passes, a fetch calls the panel again.
    await Future<void>.delayed(const Duration(milliseconds: 10500));
    api.shortEpgGate = Completer<void>();
    final healed = support.fetchEpgForChannel('100', from: from, to: to);
    await waitForShortEpgCalls(4);
    api.shortEpgGate!.complete();
    final programs = await healed;
    expect(programs.map((p) => p.title), contains('Show'));
  });

  test('2c a cancel only aborts when the last waiter leaves', () async {
    final now = DateTime.now();
    api.scripted = [_epg(start: now.subtract(const Duration(minutes: 30)), end: now.add(const Duration(minutes: 90)))];
    final support = await supportFor();
    final from = now.subtract(const Duration(hours: 1));
    final to = now.add(const Duration(hours: 2));

    // Two waiters share one fetch; one cancel must NOT abort it.
    api.shortEpgGate = Completer<void>();
    final first = support.fetchEpgForChannel('100', from: from, to: to);
    final second = support.fetchEpgForChannel('100', from: from, to: to);
    await waitForShortEpgCalls(1);
    support.cancelEpgFetchForChannel('100');
    api.shortEpgGate!.complete();
    expect((await first).map((p) => p.title), contains('Show'));
    expect((await second).map((p) => p.title), contains('Show'));
    expect(api.shortEpgCalls, 1);

    // One waiter alone: the same cancel DOES abort it.
    api.shortEpgGate = Completer<void>();
    final solo = support.fetchEpgForChannel('101', from: from, to: to);
    await waitForShortEpgCalls(2);
    support.cancelEpgFetchForChannel('101');
    await expectLater(solo, throwsA(predicate<Object>(_isCancellation, 'is a cancellation')));
  });

  test('F3 an aborted fetch does not poison the row', () async {
    final now = DateTime.now();
    api.scripted = [_epg(start: now.subtract(const Duration(minutes: 30)), end: now.add(const Duration(minutes: 90)))];
    final support = await supportFor();
    final from = now.subtract(const Duration(hours: 1));
    final to = now.add(const Duration(hours: 2));

    api.shortEpgGate = Completer<void>();
    final aborted = support.fetchEpgForChannel('100', from: from, to: to);
    await waitForShortEpgCalls(1);
    support.cancelEpgFetchForChannel('100');
    await expectLater(aborted, throwsA(predicate<Object>(_isCancellation, 'is a cancellation')));

    // The retry (one abort, so no cooldown) refetches and serves the row.
    api.shortEpgGate = Completer<void>();
    final retried = support.fetchEpgForChannel('100', from: from, to: to);
    await waitForShortEpgCalls(2);
    api.shortEpgGate!.complete();
    expect((await retried).map((p) => p.title), contains('Show'));
  });
}
