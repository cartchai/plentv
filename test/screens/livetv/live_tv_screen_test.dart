import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/library_change_event.dart';
import 'package:plezy/media/live_tv_support.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/models/media_grab_operation.dart';
import 'package:plezy/models/media_subscription.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/livetv/guide_search_sheet.dart';
import 'package:plezy/screens/livetv/live_tv_screen.dart';
import 'package:plezy/screens/livetv/tabs/guide_tab.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/library_content_notifier.dart';
import 'package:plezy/widgets/focusable_tab_chip.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('en'));

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.liveTvDefaultFavorites, true);
  });

  testWidgets('loaded empty favorites shows the favorites empty state and can restore all channels', (tester) async {
    final harness = await _pumpLiveTvScreen(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.dispose();
    });

    expect(find.byIcon(Symbols.star_rounded), findsOneWidget);
    expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a']);

    harness.liveTv.favorites.complete(const []);
    await tester.pumpAndSettle();

    expect(find.byType(GuideTab), findsNothing);
    expect(find.text(t.liveTv.noFavoriteChannels), findsOneWidget);
    expect(find.text(t.liveTv.showAllChannels), findsOneWidget);

    await tester.tap(find.text(t.liveTv.showAllChannels));
    await tester.pumpAndSettle();

    expect(find.text(t.liveTv.noFavoriteChannels), findsNothing);
    expect(find.byIcon(Symbols.star_outline_rounded), findsOneWidget);
    expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a']);
  });

  testWidgets('favorites matching no loaded channel show the favorites empty state', (tester) async {
    final harness = await _pumpLiveTvScreen(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.dispose();
    });

    harness.liveTv.favorites.complete([FavoriteChannel(id: 'channel-gone', source: 'server://server-a/provider-a')]);
    await tester.pumpAndSettle();

    expect(find.byType(GuideTab), findsNothing);
    expect(find.text(t.liveTv.noFavoriteChannels), findsOneWidget);
    expect(find.text(t.liveTv.showAllChannels), findsOneWidget);
  });

  testWidgets('refresh keeps the favorites filter narrow while favorites reload', (tester) async {
    final harness = await _pumpLiveTvScreen(tester, channelKeys: const ['channel-a', 'channel-b']);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.dispose();
    });

    final favorite = FavoriteChannel(id: 'channel-a', source: 'server://server-a/provider-a');
    harness.liveTv.favorites.complete([favorite]);
    await tester.pumpAndSettle();

    expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a']);

    await tester.tap(find.byIcon(Symbols.refresh_rounded));
    await tester.pumpAndSettle();

    expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a']);

    harness.liveTv.favorites.complete([favorite]);
    await tester.pumpAndSettle();

    expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a']);
  });

  testWidgets('guide search covers all channels and selecting a non-favorite drops the favorites filter', (
    tester,
  ) async {
    final harness = await _pumpLiveTvScreen(tester, channelKeys: const ['channel-a', 'channel-b']);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.dispose();
    });

    harness.liveTv.favorites.complete([FavoriteChannel(id: 'channel-a', source: 'server://server-a/provider-a')]);
    await tester.pumpAndSettle();
    expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a']);

    await tester.tap(find.byIcon(Symbols.search_rounded));
    await tester.pumpAndSettle();

    // The sheet searches the full lineup, not the favorites-filtered one.
    final sheet = find.byType(GuideSearchSheet);
    expect(find.descendant(of: sheet, matching: find.text('Unique Channel A')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Unique Channel channel-b')), findsOneWidget);

    await tester.tap(find.descendant(of: sheet, matching: find.text('Unique Channel channel-b')));
    await tester.pumpAndSettle();

    // The target row must exist to land on, so the filter is dropped and the
    // guide widens to the full lineup.
    expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a', 'channel-b']);
  });

  testWidgets('favorite read failure preserves raw Guide channels', (tester) async {
    final harness = await _pumpLiveTvScreen(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.dispose();
    });

    expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a']);

    harness.liveTv.favorites.completeError(StateError('favorite read failed'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Symbols.star_rounded), findsOneWidget);
    expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a']);
  });
  testWidgets('favorite failure keeps favorites loaded from healthy stores', (tester) async {
    final failedLiveTv = _FakeLiveTvSupport(serverId: 'server-a', storeKey: 'store-a');
    final healthyLiveTv = _FakeLiveTvSupport(serverId: 'server-b', storeKey: 'store-b');
    final failedClient = _FakeMediaServerClient(failedLiveTv, serverId: ServerId('server-a'));
    final healthyClient = _FakeMediaServerClient(healthyLiveTv, serverId: ServerId('server-b'));
    final manager = MultiServerManager()
      ..debugRegisterClientForTesting(failedClient)
      ..debugRegisterClientForTesting(healthyClient);
    final provider = testMultiServerProvider(manager);
    provider.debugSetLiveTvServersForTesting([
      LiveTvServerInfo(serverId: 'server-a', dvrKey: 'dvr-a', lineup: 'provider-a'),
      LiveTvServerInfo(serverId: 'server-b', dvrKey: 'dvr-b', lineup: 'provider-b'),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      provider.dispose();
      manager.dispose();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: ChangeNotifierProvider<MultiServerProvider>.value(
            value: provider,
            child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const LiveTvScreen()),
          ),
        ),
      ),
    );
    failedLiveTv.favorites.completeError(StateError('favorite read failed'));
    healthyLiveTv.favorites.complete([FavoriteChannel(id: 'channel-server-b', source: 'server://server-b/provider-b')]);
    await tester.pumpAndSettle();

    final guide = tester.widget<GuideTab>(find.byType(GuideTab));
    final healthyChannel = guide.channels.singleWhere((channel) => channel.serverId == 'server-b');
    expect(guide.isFavoriteChannel!(healthyChannel), isTrue);
    expect(guide.channels.map((channel) => channel.serverId), ['server-b']);
  });

  testWidgets('favorite write failure keeps optimistic state, shows feedback, and leaves the queue usable', (
    tester,
  ) async {
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.liveTvDefaultFavorites, false);
    final harness = await _pumpLiveTvScreen(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.dispose();
    });
    harness.liveTv.writeFailures.add(StateError('favorite write failed'));
    harness.liveTv.favorites.complete(const []);
    await tester.pumpAndSettle();

    // Build #17 §9: long-press opens the channel menu — the favorite
    // toggles only when "Add to favourites" is tapped in it, not on the
    // long-press itself.
    await tester.longPress(find.text('Unique Channel A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to favourites'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    var guide = tester.widget<GuideTab>(find.byType(GuideTab));
    expect(guide.isFavoriteChannel!(guide.channels.single), isTrue);
    expect(find.text(t.liveTv.favoritesUpdateFailed), findsOneWidget);
    expect(harness.liveTv.writes.map((write) => write.map((favorite) => favorite.id).toList()), [
      ['channel-a'],
    ]);

    await tester.longPress(find.text('Unique Channel A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from favourites'));
    await tester.pumpAndSettle();

    guide = tester.widget<GuideTab>(find.byType(GuideTab));
    expect(guide.isFavoriteChannel!(guide.channels.single), isFalse);
    expect(harness.liveTv.writes.map((write) => write.map((favorite) => favorite.id).toList()), [
      ['channel-a'],
      <String>[],
    ]);
  });

  testWidgets('What\'s On is hidden when no Live TV server is Plex', (tester) async {
    final harness = await _pumpLiveTvScreen(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.dispose();
    });
    harness.liveTv.favorites.complete(const []);
    await tester.pumpAndSettle();

    expect(find.text(t.liveTv.guide), findsWidgets);
    expect(find.text(t.liveTv.whatsOn), findsNothing);
  });

  testWidgets('a refresh that fails on every server keeps the loaded channels', (tester) async {
    final harness = await _pumpLiveTvScreen(tester, channelKeys: const ['channel-a', 'channel-b']);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.dispose();
    });
    harness.liveTv.favorites.complete(const []);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.liveTv.showAllChannels));
    await tester.pumpAndSettle();
    expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a', 'channel-b']);

    harness.liveTv.channelsFailure = StateError('offline');
    await tester.tap(find.byIcon(Symbols.refresh_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a', 'channel-b']);
    expect(find.text(t.errors.unableToLoad(context: t.liveTv.title)), findsOneWidget);
    expect(find.text(t.liveTv.noChannels), findsNothing);
  });

  testWidgets('a first load that fails on every server shows the error state', (tester) async {
    final harness = await _pumpLiveTvScreen(tester, channelsFailure: StateError('offline'));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.dispose();
    });

    expect(find.text(t.errors.unableToLoad(context: t.liveTv.title)), findsOneWidget);
    expect(find.text(t.liveTv.noChannels), findsNothing);
  });

  testWidgets('guide refresh reports a DVR reload failure instead of success', (tester) async {
    final dvr = _FakeLiveTvDvrSupport(reloadFailure: StateError('reload failed'));
    final harness = await _pumpLiveTvScreen(tester, dvr: dvr);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.dispose();
    });
    harness.liveTv.favorites.complete(const []);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Symbols.refresh_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(dvr.reloadedDvrKeys, ['dvr-a']);
    expect(find.text(t.liveTv.guideReloadFailed), findsOneWidget);
    expect(find.text(t.liveTv.guideReloadRequested), findsNothing);
  });

  testWidgets('guide refresh names the admin requirement when the DVR rejects it with 403', (tester) async {
    final dvr = _FakeLiveTvDvrSupport(
      reloadFailure: MediaServerHttpException(type: MediaServerHttpErrorType.unknown, statusCode: 403),
    );
    final harness = await _pumpLiveTvScreen(tester, dvr: dvr);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.dispose();
    });
    harness.liveTv.favorites.complete(const []);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Symbols.refresh_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(t.liveTv.dvrAdminRequired), findsOneWidget);
    expect(find.text(t.liveTv.guideReloadRequested), findsNothing);
  });

  testWidgets('a VOD-only catalog event does not reload the guide, a live one does', (tester) async {
    final harness = await _pumpLiveTvScreen(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.dispose();
    });

    // Let the initial load finish first, or the live event below would
    // only set _reloadAfterLoad instead of reloading.
    harness.liveTv.favorites.complete([
      FavoriteChannel(id: 'channel-a', source: 'server://server-a/provider-a'),
    ]);
    await tester.pumpAndSettle();

    // The initial load ran once.
    expect(harness.liveTv.fetchChannelsCalls, 1);

    // A VOD/series background refresh landing (build #14, SA-4 partial):
    // the guide shows live channels only, so it must not reload.
    LibraryContentNotifier().notifyChanged(
      LibraryChangeEvent(
        serverId: ServerId('server-a'),
        itemsUpdated: true,
        liveCatalogChanged: false,
      ),
    );
    // The listener only registers a post-frame callback, which does not
    // schedule a frame — and tester.pump() is a no-op without one — so
    // schedule the frame explicitly, then pump. pump() flushes the
    // broadcast delivery first, so the callback is registered in time.
    tester.binding.scheduleFrame();
    await tester.pump();
    await tester.pump();
    expect(harness.liveTv.fetchChannelsCalls, 1);

    // A live refresh landing reloads the guide.
    LibraryContentNotifier().notifyChanged(
      LibraryChangeEvent(serverId: ServerId('server-a'), itemsUpdated: true),
    );
    tester.binding.scheduleFrame();
    await tester.pump();
    await tester.pump();
    expect(harness.liveTv.fetchChannelsCalls, 2);
  });

  testWidgets('an event for another server does not reload the guide', (tester) async {
    final harness = await _pumpLiveTvScreen(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.dispose();
    });

    harness.liveTv.favorites.complete([
      FavoriteChannel(id: 'channel-a', source: 'server://server-a/provider-a'),
    ]);
    await tester.pumpAndSettle();

    expect(harness.liveTv.fetchChannelsCalls, 1);
    LibraryContentNotifier().notifyChanged(
      LibraryChangeEvent(serverId: ServerId('server-b'), itemsUpdated: true),
    );
    // See the test above: the listener only registers a post-frame
    // callback, which does not schedule a frame on its own.
    tester.binding.scheduleFrame();
    await tester.pump();
    await tester.pump();
    expect(harness.liveTv.fetchChannelsCalls, 1);
  });

  group('Live TV phone UI (1.6.26)', () {
    // The test binding defaults to the host (desktop) platform, so the
    // side-nav branch renders unless the override forces Android.
    Future<_LiveTvHarness> pumpPhone(
      WidgetTester tester, {
      List<String>? channelKeys,
      _FakeLiveTvDvrSupport? dvr,
      List<({String id, String name})> categories = const [],
      Map<String, String> channelCategoryIds = const {},
      String? defaultTab,
      bool? defaultFavorites,
    }) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      if (defaultTab != null || defaultFavorites != null) {
        final settings = await SettingsService.getInstance();
        if (defaultTab != null) await settings.write(SettingsService.liveTvDefaultTab, defaultTab);
        if (defaultFavorites != null) {
          await settings.write(SettingsService.liveTvDefaultFavorites, defaultFavorites);
        }
      }
      return _pumpLiveTvScreen(
        tester,
        channelKeys: channelKeys,
        dvr: dvr,
        iptvClient: categories.isNotEmpty,
        categories: categories,
        channelCategoryIds: channelCategoryIds,
      );
    }

    Future<void> disposeHarness(WidgetTester tester, _LiveTvHarness harness) async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.dispose();
    }

    testWidgets('phone: category chips collapse into a dropdown beside Guide on the right', (tester) async {
      const categories = [
        (id: 'cat-uk', name: 'UK| GENERAL'),
        (id: 'cat-us', name: 'US| NEWS'),
      ];
      final harness = await pumpPhone(
        tester,
        channelKeys: const ['channel-a', 'channel-b'],
        categories: categories,
        channelCategoryIds: const {'channel-a': 'cat-uk', 'channel-b': 'cat-us'},
        defaultTab: 'guide',
      );
      addTearDown(() => disposeHarness(tester, harness));
      harness.liveTv.favorites.complete(const []);
      await tester.pumpAndSettle();

      // The chips row is gone: no ChoiceChip renders inside the guide.
      expect(find.descendant(of: find.byType(GuideTab), matching: find.byType(ChoiceChip)), findsNothing);
      // The dropdown is present, labelled with the current category.
      final dropdown = find.byKey(const ValueKey('live_tv_category_dropdown'));
      expect(dropdown, findsOneWidget);
      expect(find.descendant(of: dropdown, matching: find.text(t.liveTv.allCategories)), findsOneWidget);
      // ... beside Guide on the right: its centre is right of the Guide chip's.
      final guideChip = find.descendant(of: find.byType(TabChipStrip), matching: find.text(t.liveTv.guide));
      expect(tester.getCenter(dropdown).dx, greaterThan(tester.getCenter(guideChip).dx));

      // Opening it lists every category; picking one filters the guide.
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      expect(find.text('UK| GENERAL'), findsOneWidget);
      expect(find.text('US| NEWS'), findsOneWidget);
      await tester.tap(find.text('UK| GENERAL'));
      await tester.pumpAndSettle();
      expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a']);
      expect(find.descendant(of: dropdown, matching: find.text('UK| GENERAL')), findsOneWidget);
      // Reset before the test ends: the framework checks foundation debug
      // vars before tearDowns run, so an addTearDown reset is too late.
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('phone: Favourites is its own button left of Guide and the AppBar star is gone', (tester) async {
      final harness = await pumpPhone(
        tester,
        channelKeys: const ['channel-a', 'channel-b'],
        defaultTab: 'guide',
      );
      addTearDown(() => disposeHarness(tester, harness));
      harness.liveTv.favorites.complete([
        FavoriteChannel(id: 'channel-a', source: 'server://server-a/provider-a'),
      ]);
      await tester.pumpAndSettle();

      final button = find.byKey(const ValueKey('live_tv_favorites_filter_button'));
      expect(button, findsOneWidget);
      // Left of Guide.
      final guideChip = find.descendant(of: find.byType(TabChipStrip), matching: find.text(t.liveTv.guide));
      expect(tester.getCenter(button).dx, lessThan(tester.getCenter(guideChip).dx));
      // Star icon + Favorites label on the button; no star in the AppBar.
      expect(find.descendant(of: button, matching: find.byIcon(Symbols.star_outline_rounded)), findsOneWidget);
      expect(find.descendant(of: button, matching: find.text(t.liveTv.favorites)), findsOneWidget);
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.byIcon(Symbols.star_outline_rounded)),
        findsNothing,
      );
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.byIcon(Symbols.star_rounded)),
        findsNothing,
      );
      // The dropdown hides when the lineup has no categories.
      expect(find.byKey(const ValueKey('live_tv_category_dropdown')), findsNothing);

      // Tapping it narrows the guide to favourites; tapping again restores all.
      expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a', 'channel-b']);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a']);
      expect(find.descendant(of: button, matching: find.byIcon(Symbols.star_rounded)), findsOneWidget);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a', 'channel-b']);
      expect(find.descendant(of: button, matching: find.byIcon(Symbols.star_outline_rounded)), findsOneWidget);
      // Reset before the test ends: the framework checks foundation debug
      // vars before tearDowns run, so an addTearDown reset is too late.
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('phone: Default tab Favourites opens the Guide with the filter on', (tester) async {
      final harness = await pumpPhone(
        tester,
        channelKeys: const ['channel-a', 'channel-b'],
        defaultTab: 'favorites',
      );
      addTearDown(() => disposeHarness(tester, harness));
      harness.liveTv.favorites.complete([
        FavoriteChannel(id: 'channel-a', source: 'server://server-a/provider-a'),
      ]);
      await tester.pumpAndSettle();

      expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a']);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('live_tv_favorites_filter_button')),
          matching: find.byIcon(Symbols.star_rounded),
        ),
        findsOneWidget,
      );
      // Reset before the test ends: the framework checks foundation debug
      // vars before tearDowns run, so an addTearDown reset is too late.
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('phone: Default tab Guide opens with the filter off', (tester) async {
      // setUp wrote the old toggle true — a stored tab value wins over it.
      final harness = await pumpPhone(
        tester,
        channelKeys: const ['channel-a', 'channel-b'],
        defaultTab: 'guide',
      );
      addTearDown(() => disposeHarness(tester, harness));
      harness.liveTv.favorites.complete([
        FavoriteChannel(id: 'channel-a', source: 'server://server-a/provider-a'),
      ]);
      await tester.pumpAndSettle();

      expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a', 'channel-b']);
      // Reset before the test ends: the framework checks foundation debug
      // vars before tearDowns run, so an addTearDown reset is too late.
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('phone: an unknown default tab value clamps to Guide', (tester) async {
      final harness = await pumpPhone(
        tester,
        channelKeys: const ['channel-a', 'channel-b'],
        defaultTab: 'bogus',
      );
      addTearDown(() => disposeHarness(tester, harness));
      harness.liveTv.favorites.complete([
        FavoriteChannel(id: 'channel-a', source: 'server://server-a/provider-a'),
      ]);
      await tester.pumpAndSettle();

      expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a', 'channel-b']);
      // Reset before the test ends: the framework checks foundation debug
      // vars before tearDowns run, so an addTearDown reset is too late.
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('phone: no stored tab value migrates the old Appearance toggle', (tester) async {
      // setUp wrote liveTvDefaultFavorites=true and no tab value is stored.
      final harness = await pumpPhone(tester, channelKeys: const ['channel-a', 'channel-b']);
      addTearDown(() => disposeHarness(tester, harness));
      harness.liveTv.favorites.complete([
        FavoriteChannel(id: 'channel-a', source: 'server://server-a/provider-a'),
      ]);
      await tester.pumpAndSettle();

      expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a']);
      // The migration writes the choice once, so the old bool is never
      // consulted again.
      expect(SettingsService.instance.read(SettingsService.liveTvDefaultTab), 'favorites');
      // Reset before the test ends: the framework checks foundation debug
      // vars before tearDowns run, so an addTearDown reset is too late.
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('phone: no stored tab value and the old toggle off opens on Guide', (tester) async {
      final harness = await pumpPhone(
        tester,
        channelKeys: const ['channel-a', 'channel-b'],
        defaultFavorites: false,
      );
      addTearDown(() => disposeHarness(tester, harness));
      harness.liveTv.favorites.complete([
        FavoriteChannel(id: 'channel-a', source: 'server://server-a/provider-a'),
      ]);
      await tester.pumpAndSettle();

      expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a', 'channel-b']);
      expect(SettingsService.instance.read(SettingsService.liveTvDefaultTab), 'guide');
      // Reset before the test ends: the framework checks foundation debug
      // vars before tearDowns run, so an addTearDown reset is too late.
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('TV: chips row stays, AppBar star stays, no Favourites button or dropdown', (tester) async {
      // The test binding defaults to Android (phone branch), so the
      // desktop branch needs the override — macOS, per the
      // library_browse_tab_test precedent.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.liveTvDefaultTab, 'guide');
      final harness = await _pumpLiveTvScreen(
        tester,
        channelKeys: const ['channel-a', 'channel-b'],
        iptvClient: true,
        categories: const [(id: 'cat-uk', name: 'UK| GENERAL')],
        channelCategoryIds: const {'channel-a': 'cat-uk'},
      );
      addTearDown(() => disposeHarness(tester, harness));
      harness.liveTv.favorites.complete([
        FavoriteChannel(id: 'channel-a', source: 'server://server-a/provider-a'),
      ]);
      await tester.pumpAndSettle();

      expect(find.descendant(of: find.byType(GuideTab), matching: find.byType(ChoiceChip)), findsWidgets);
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.byIcon(Symbols.star_outline_rounded)),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('live_tv_favorites_filter_button')), findsNothing);
      expect(find.byKey(const ValueKey('live_tv_category_dropdown')), findsNothing);
      // Reset before the test ends: the framework checks foundation debug
      // vars before tearDowns run, so an addTearDown reset is too late.
      debugDefaultTargetPlatformOverride = null;
    });
  });
}

List<LiveTvChannel> _guideChannels(WidgetTester tester) => tester.widget<GuideTab>(find.byType(GuideTab)).channels;

Future<_LiveTvHarness> _pumpLiveTvScreen(
  WidgetTester tester, {
  List<String>? channelKeys,
  _FakeLiveTvDvrSupport? dvr,
  Object? channelsFailure,
  bool iptvClient = false,
  List<({String id, String name})> categories = const [],
  Map<String, String> channelCategoryIds = const {},
}) async {
  final liveTv = _FakeLiveTvSupport(channelKeys: channelKeys, dvr: dvr, channelCategoryIds: channelCategoryIds)
    ..channelsFailure = channelsFailure;
  final client = iptvClient ? _FakeIptvClient(liveTv, categories: categories) : _FakeMediaServerClient(liveTv);
  final manager = MultiServerManager()..debugRegisterClientForTesting(client);
  final provider = testMultiServerProvider(manager);
  provider.debugSetLiveTvServersForTesting([
    LiveTvServerInfo(serverId: client.serverId.value, dvrKey: 'dvr-a', lineup: 'provider-a'),
  ]);
  final harness = _LiveTvHarness(manager: manager, provider: provider, liveTv: liveTv);

  await tester.pumpWidget(
    TranslationProvider(
      child: InputModeTracker(
        child: ChangeNotifierProvider<MultiServerProvider>.value(
          value: provider,
          child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const LiveTvScreen()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

class _LiveTvHarness {
  const _LiveTvHarness({required this.manager, required this.provider, required this.liveTv});

  final MultiServerManager manager;
  final MultiServerProvider provider;
  final _FakeLiveTvSupport liveTv;

  void dispose() {
    provider.dispose();
    manager.dispose();
  }
}

class _FakeMediaServerClient implements MediaServerClient {
  _FakeMediaServerClient(this.liveTv, {ServerId? serverId}) : serverId = serverId ?? ServerId('server-a');

  @override
  final LiveTvSupport liveTv;

  @override
  final ServerId serverId;

  @override
  String? get serverName => 'Server ${serverId.value}';

  @override
  MediaBackend get backend => MediaBackend.jellyfin;

  @override
  ServerCapabilities get capabilities => ServerCapabilities(liveTv: true, liveTvDvr: liveTv.dvr != null);

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLiveTvSupport implements LiveTvSupport {
  _FakeLiveTvSupport({
    this.serverId = 'server-a',
    this.storeKey = 'test-store',
    List<String>? channelKeys,
    this.dvr,
    this.channelCategoryIds = const {},
  }) : channelKeys = channelKeys ?? [serverId == 'server-a' ? 'channel-a' : 'channel-$serverId'];

  final String serverId;
  final String storeKey;
  final List<String> channelKeys;

  /// Category id per channel key (1.6.26): lets the dropdown test prove a
  /// picked category narrows the guide to that category's channels.
  final Map<String, String> channelCategoryIds;
  Object? channelsFailure;
  final List<Completer<List<FavoriteChannel>>> _favoriteRequests = [];
  int _servedFavoriteRequests = 0;

  Completer<List<FavoriteChannel>> get favorites {
    if (_favoriteRequests.length > _servedFavoriteRequests) {
      return _favoriteRequests[_servedFavoriteRequests];
    }
    if (_servedFavoriteRequests > 0 && !_favoriteRequests[_servedFavoriteRequests - 1].isCompleted) {
      return _favoriteRequests[_servedFavoriteRequests - 1];
    }
    final request = Completer<List<FavoriteChannel>>();
    _favoriteRequests.add(request);
    return request;
  }

  @override
  final LiveTvDvrSupport? dvr;

  @override
  String get favoriteStoreKey => storeKey;

  @override
  FavoriteChannelPersistenceMode get favoritePersistenceMode => FavoriteChannelPersistenceMode.serverSlice;

  @override
  Future<String> buildFavoriteChannelSource({String? lineup}) async => 'server://$serverId/${lineup ?? 'default'}';

  /// How many times the guide (re)loaded its channels — the SA-4 test
  /// (build #14) asserts a VOD-only catalog event does not add one.
  int fetchChannelsCalls = 0;

  @override
  Future<List<LiveTvChannel>> fetchChannels({String? lineup}) async {
    fetchChannelsCalls++;
    return [
      if (channelsFailure case final failure?) throw failure,
      for (final key in channelKeys)
        LiveTvChannel(
          key: key,
          title: key == 'channel-a' ? 'Unique Channel A' : 'Unique Channel $key',
          serverId: serverId,
          categoryId: channelCategoryIds[key],
        ),
    ];
  }

  @override
  Future<List<LiveTvProgram>> fetchSchedule({DateTime? from, DateTime? to}) async => const [];

  @override
  Future<List<FavoriteChannel>> fetchFavoriteChannels({bool migrate = true, void Function()? checkCurrent}) {
    if (_favoriteRequests.length == _servedFavoriteRequests) {
      _favoriteRequests.add(Completer<List<FavoriteChannel>>());
    }
    return _favoriteRequests[_servedFavoriteRequests++].future;
  }

  final List<Object> writeFailures = [];
  final List<List<FavoriteChannel>> writes = [];

  @override
  Future<void> setFavoriteChannels(List<FavoriteChannel> channels, {void Function()? checkCurrent}) async {
    checkCurrent?.call();
    writes.add(List.of(channels));
    if (writeFailures.isNotEmpty) throw writeFailures.removeAt(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Fake IPTV client (1.6.26): the same shape as [_FakeMediaServerClient]
/// but an [IptvClient], so `LiveTvScreen._loadGuideCategories` populates
/// the category entries. Only [visibleLiveCategories] is overridden;
/// everything else falls through to [noSuchMethod].
class _FakeIptvClient implements IptvClient {
  _FakeIptvClient(this.liveTv, {this.categories = const [], ServerId? serverId})
    : serverId = serverId ?? ServerId('server-a');

  @override
  final LiveTvSupport liveTv;

  final List<({String id, String name})> categories;

  @override
  final ServerId serverId;

  @override
  String? get serverName => 'Server ${serverId.value}';

  @override
  MediaBackend get backend => MediaBackend.xtream;

  @override
  ServerCapabilities get capabilities => ServerCapabilities(liveTv: true, liveTvDvr: liveTv.dvr != null);

  @override
  Future<List<({String id, String name})>> visibleLiveCategories() async => categories;

  @override
  void close() {}

  @override
  int get filterGeneration => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLiveTvDvrSupport implements LiveTvDvrSupport {
  _FakeLiveTvDvrSupport({this.reloadFailure});

  final Object? reloadFailure;
  final List<String> reloadedDvrKeys = [];

  @override
  bool get supportsRuleProcessing => false;

  @override
  Future<void> reloadGuide(String dvrId) async {
    reloadedDvrKeys.add(dvrId);
    if (reloadFailure != null) throw reloadFailure!;
  }

  // The Recordings tab is built alongside the guide once a DVR exists.
  @override
  Future<List<MediaGrabOperation>> fetchScheduledRecordings() async => const [];

  @override
  Future<List<MediaSubscription>> fetchRecordingRules({bool includeGrabs = true, bool includeStorage = true}) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
