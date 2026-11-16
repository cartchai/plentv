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

/// 1.2.19 L-47, 404 half: a catch-up open the panel answers with 404 shows
/// the missing-recording card naming programme + channel, with Watch live
/// and NO Retry — and never silently re-opens live TV (the ladder's old
/// behaviour, which burned another open on the one connection slot).
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
    tmpRoot = await Directory.systemTemp.createTemp('playback_catchup_404_test_');
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

  testWidgets('a catch-up 404 shows the missing-recording card with Watch live and no Retry', (tester) async {
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
      failStatus: 404,
      loadfileUrls: loadfileUrls,
      key: key,
      onCard: (tester) async {
        final cardText = t.iptv.miniPlayerMissingRecording(programme: 'The Office', channel: 'Trex News');
        await pumpUntil(
          tester,
          () => find.text(cardText).evaluate().isNotEmpty,
          describe: () => 'loadfiles=$loadfileUrls, no missing-recording card',
        );
        expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'the spinner must not cover the card');
        expect(find.byType(SnackBar), findsNothing);
        expect(find.text('Browse'), findsNothing, reason: 'the route must stay so the viewer can act on the card');
        // Never retried: the panel already answered.
        expect(find.widgetWithText(FilledButton, t.common.retry), findsNothing);
        // Watch live is the card's one action — and it is focused, so a
        // D-pad user lands on it, not on nothing.
        final watchLive = find.widgetWithText(FilledButton, t.iptv.miniPlayerWatchLive);
        expect(watchLive, findsOneWidget);
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'PlayerInitializationErrorAction',
          reason: 'a D-pad user must land on Watch live, not on nothing',
        );

        await tester.tap(watchLive);
        await pumpUntil(
          tester,
          () => loadfileUrls.length == 2,
          describe: () => 'loadfiles=$loadfileUrls, Watch live never re-opened',
        );
        expect(
          loadfileUrls[1],
          'https://example.invalid/live',
          reason: 'Watch live re-opens the same channel at the live edge, not the catch-up URL',
        );
        expect(
          client.testSession.requestedOffsets.last,
          isNull,
          reason: 'the Watch live open carries no catch-up offset',
        );
        await pumpUntil(
          tester,
          () => find.text(cardText).evaluate().isEmpty,
          describe: () => 'missing-recording card still up after Watch live rendered',
        );
      },
    );
  });
}
