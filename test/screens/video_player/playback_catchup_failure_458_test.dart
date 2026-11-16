import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/catchup_failure_harness.dart';
import '../../test_helpers/hdr_startup.dart';
import '../../test_helpers/io_fakes.dart';
import '../../test_helpers/pump.dart';

/// 1.2.19 L-47, 458 half: a catch-up open the panel answers with 458 shows
/// the line-busy card — never a missing recording — with Watch live AND
/// Retry. The Retry replays the same catch-up offset (the line may have
/// cleared); Watch live opens the live edge. Neither path silently
/// re-opens live TV on its own: the old ladder did, burning another open
/// on the one connection slot.
/// One test per file: a second screen in the same isolate never reaches
/// `initialize` (see [installHdrStartupHarness]).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpRoot;
  late PathProviderPlatform previousPathProvider;
  late AppDatabase db;

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
    tmpRoot = await Directory.systemTemp.createTemp('playback_catchup_458_test_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(tmpRoot);
    await installHdrStartupHarness();
    DownloadStorageService.resetForTesting();
    await DownloadStorageService.instance.initialize(SettingsService.instance);
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    DownloadStorageService.resetForTesting();
    SettingsService.resetForTesting();
    PathProviderPlatform.instance = previousPathProvider;
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  testWidgets('a catch-up 458 shows the line-busy card with Watch live and a catch-up Retry', (tester) async {
    final client = CatchUpTestClient();
    final key = GlobalKey<VideoPlayerScreenState>();
    final loadfileUrls = <String>[];
    final channel = LiveTvChannel(
      key: '100',
      title: 'Trex News',
      serverId: 'srv-1',
      hasCatchUp: true,
      catchUpArchiveDurationSeconds: 86400,
    );
    final catchUpStart = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3600;

    await pumpCatchUpPlayer(
      tester: tester,
      db: db,
      client: client,
      channel: channel,
      catchUpStartEpoch: catchUpStart,
      catchUpProgrammeTitle: 'The Office',
      failStatus: 458,
      loadfileUrls: loadfileUrls,
      key: key,
      onCard: (tester) async {
        await pumpUntil(
          tester,
          () => find.text(t.iptv.miniPlayerLineBusy).evaluate().isNotEmpty,
          describe: () => 'loadfiles=$loadfileUrls, no line-busy card',
        );
        expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'the spinner must not cover the card');
        expect(find.byType(SnackBar), findsNothing);
        expect(find.text('Browse'), findsNothing, reason: 'the route must stay so the viewer can act on the card');
        // A busy line is transient, never a missing recording.
        expect(
          find.text(t.iptv.miniPlayerMissingRecording(programme: 'The Office', channel: 'Trex News')),
          findsNothing,
        );
        // Retry stays: the line may have cleared. Watch live beside it.
        expect(find.widgetWithText(FilledButton, t.common.retry), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, t.iptv.miniPlayerWatchLive), findsOneWidget);

        await tester.tap(find.widgetWithText(FilledButton, t.common.retry));
        await pumpUntil(
          tester,
          () => loadfileUrls.length == 2,
          describe: () => 'loadfiles=$loadfileUrls, Retry never re-opened',
        );
        expect(
          loadfileUrls[1],
          'https://example.invalid/timeshift',
          reason: 'Retry replays the same catch-up offset — it must not drop to live TV',
        );
        // The offset is recomputed at retry time, so it is a few seconds
        // past the first tune's -3600 — what matters is that it is a
        // catch-up offset at all (negative, inside the 24 h archive),
        // not the live edge.
        final retriedOffset = client.testSession.requestedOffsets.last;
        expect(retriedOffset, isNotNull);
        expect(retriedOffset!, lessThan(0));
        expect(retriedOffset, greaterThanOrEqualTo(-86400));
        await pumpUntil(
          tester,
          () => find.text(t.iptv.miniPlayerLineBusy).evaluate().isEmpty,
          describe: () => 'line-busy card still up after the retried open rendered',
        );
      },
    );
  });
}
