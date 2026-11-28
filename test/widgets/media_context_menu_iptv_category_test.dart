import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/settings/iptv_categories_screen.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/iptv_initials.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/focusable_list_tile.dart';
import 'package:plezy/widgets/media_context_menu.dart';
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/profile_stack.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

/// 1.6.33: the IPTV item long-press menu swaps "File Info" — which never
/// worked for a stream (IptvClient.getFileInfo throws) — for the item's
/// OWN provider category, with the ability to turn that category off
/// right from there. The category comes from the item's own provider
/// category id, resolved against the item's per-kind category list —
/// never the initials (whole-groups) aggregation, which misses one-off
/// groups like NF. Plex/local items keep real File Info.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    // Real dart:io never completes in testWidgets' fake async zone — the
    // catalog disk cache is switched off here, as in the other IPTV
    // widget tests.
    IptvCatalogDiskCache.debugDisableDisk = true;
    // The client swap after a hide builds through
    // IptvClient.forConnection — point the factory at a fake-backed
    // client too, or the swapped client probes the real panel.
    IptvClient.debugClientFactory = (connection) {
      final client = IptvClient.xtream(xtreamConnection: connection as XtreamConnection);
      client.testXtreamApi = _VodCategoryFakeApi();
      return client;
    };
  });

  tearDown(() {
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvClient.debugClientFactory = null;
  });

  XtreamConnection trexConnection({List<String> hiddenCategoryIds = const []}) => XtreamConnection(
        id: 'trex',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: _testPassword,
        createdAt: DateTime.utc(2026, 11, 6),
        hiddenCategoryIds: hiddenCategoryIds,
      );

  IptvClient trexClient() {
    final client = IptvClient.xtream(xtreamConnection: trexConnection());
    client.testXtreamApi = _VodCategoryFakeApi();
    return client;
  }

  Future<({AppDatabase db, ConnectionRegistry registry, MultiServerManager manager, MultiServerProvider provider})> harness({
    List<String> hiddenCategoryIds = const [],
  }) async {
    // ONE database per test: the registry and the profile stack share it
    // (two AppDatabase instances on one executor race — drift warns).
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    final registry = ConnectionRegistry(db);
    await registry.upsert(trexConnection(hiddenCategoryIds: hiddenCategoryIds));
    final manager = MultiServerManager();
    manager.debugRegisterClientForTesting(trexClient());
    final provider = testMultiServerProvider(manager);
    addTearDown(() {
      provider.dispose();
      manager.dispose();
    });
    return (db: db, registry: registry, manager: manager, provider: provider);
  }

  Future<GlobalKey<MediaContextMenuState>> pumpIptvMenu(
    WidgetTester tester,
    MultiServerProvider provider,
    ConnectionRegistry registry,
    MediaItem item, {
    required AppDatabase db,
  }) async {
    TvDetectionService.debugSetAppleTVOverride(true);
    addTearDown(() => TvDetectionService.debugSetAppleTVOverride(null));
    final stack = await ProfileStack.create(db: db, withStorage: false);
    addTearDown(() async => stack.dispose());
    final menuKey = GlobalKey<MediaContextMenuState>();
    final menu = MediaContextMenu(
      key: menuKey,
      item: item,
      child: const SizedBox(width: 120, height: 80, child: Text('picker target')),
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<MultiServerProvider>.value(value: provider),
            ChangeNotifierProvider<ActiveProfileProvider>.value(value: stack.active),
            Provider<ConnectionRegistry>.value(value: registry),
          ],
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: Scaffold(body: Center(child: menu)),
          ),
        ),
      ),
    );
    return menuKey;
  }

  Future<void> openMenu(WidgetTester tester, GlobalKey<MediaContextMenuState> menuKey) async {
    menuKey.currentState!.showContextMenu(tester.element(find.text('picker target')));
    await tester.pumpAndSettle();
  }

  MediaItem xtreamMovie({String categoryId = '2'}) => testMediaItem(
        id: 'movie:1',
        backend: MediaBackend.xtream,
        kind: MediaKind.movie,
        title: 'Creed',
        serverId: 'trex',
        categoryId: categoryId,
      );

  MediaItem xtreamShow({String categoryId = '2'}) => testMediaItem(
        id: 'series:1',
        backend: MediaBackend.xtream,
        kind: MediaKind.show,
        title: 'American Dad',
        serverId: 'trex',
        categoryId: categoryId,
      );

  MediaItem xtreamEpisode({String categoryId = '2'}) => testMediaItem(
        id: 'episode:1:1',
        backend: MediaBackend.xtream,
        kind: MediaKind.episode,
        title: 'Pilot',
        serverId: 'trex',
        categoryId: categoryId,
      );

  testWidgets('IPTV movie menu shows its own category instead of File Info', (tester) async {
    final h = await harness();
    final menuKey = await pumpIptvMenu(tester, h.provider, h.registry, xtreamMovie(), db: h.db);
    await openMenu(tester, menuKey);

    expect(find.text('Category: NF'), findsOneWidget);
    expect(find.text(t.mediaMenu.fileInfo), findsNothing);
  });

  testWidgets('IPTV series menu shows its series category, no File Info', (tester) async {
    final h = await harness();
    final menuKey = await pumpIptvMenu(tester, h.provider, h.registry, xtreamShow(), db: h.db);
    await openMenu(tester, menuKey);

    expect(find.text('Category: NF - Series 1'), findsOneWidget);
    expect(find.text(t.mediaMenu.fileInfo), findsNothing);
  });

  testWidgets('IPTV episode menu swaps File Info for the category', (tester) async {
    final h = await harness();
    final menuKey = await pumpIptvMenu(tester, h.provider, h.registry, xtreamEpisode(), db: h.db);
    await openMenu(tester, menuKey);

    expect(find.text('Category: NF - Series 1'), findsOneWidget);
    expect(find.text(t.mediaMenu.fileInfo), findsNothing);
  });

  testWidgets('a category the whole-groups list misses still shows from the item itself', (tester) async {
    // 'Boutique' carries no initial at all — no whole-groups (initials)
    // row can ever cover it — yet the menu must still name it, because
    // the name comes from the item's own per-kind category list.
    expect(categoryInitial('Boutique'), isNull);
    final h = await harness();
    final client = trexClient();
    final initials = await client.iptvInitials();
    expect(initials.any((i) => i.initial == 'Boutique'), isFalse);

    final menuKey = await pumpIptvMenu(tester, h.provider, h.registry, xtreamMovie(categoryId: '9'), db: h.db);
    await openMenu(tester, menuKey);

    expect(find.text('Category: Boutique'), findsOneWidget);
    expect(find.text(t.mediaMenu.fileInfo), findsNothing);
  });

  testWidgets('turning a category off from the menu hides it in the registry', (tester) async {
    final h = await harness();
    final menuKey = await pumpIptvMenu(tester, h.provider, h.registry, xtreamMovie(), db: h.db);
    await openMenu(tester, menuKey);

    await tester.tap(find.text('Category: NF'));
    await tester.pumpAndSettle();

    // Confirm dialog names the category and where to turn it back on.
    expect(find.text('Hide this category?'), findsOneWidget);
    expect(find.textContaining('NF'), findsWidgets);
    await tester.tap(find.text(t.liveTv.hideCategory));
    await tester.pumpAndSettle();

    final stored = await h.registry.list();
    final storedTrex = stored.singleWhere((c) => c.id == 'trex') as XtreamConnection;
    expect(storedTrex.hiddenCategoryIds, ['2']);
    // The bound client was swapped in place with the new filter.
    final swapped = h.manager.getClient(ServerId('trex')) as IptvClient;
    expect((swapped.connection as XtreamConnection).hiddenCategoryIds, ['2']);
    expect(find.text('Category NF hidden'), findsOneWidget);
  });

  testWidgets('hiding from the menu hides the whole category, not just the one item', (tester) async {
    final h = await harness();
    final menuKey = await pumpIptvMenu(tester, h.provider, h.registry, xtreamMovie(), db: h.db);
    await openMenu(tester, menuKey);

    await tester.tap(find.text('Category: NF'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.liveTv.hideCategory));
    await tester.pumpAndSettle();

    // The swapped client is the one the library, search and home paths
    // consult: the whole category reads hidden now, and only it. The
    // library itself omitting a hidden category is covered by
    // library_categories_tab_test ('disabled categories are omitted');
    // this test closes the chain from the menu to that filter.
    final swapped = h.manager.getClient(ServerId('trex')) as IptvClient;
    expect(swapped.isCategoryHidden('2', 'NF'), isTrue);
    expect(swapped.isCategoryHidden('1', 'EN - Films 1'), isFalse);
    expect(swapped.isCategoryHidden('9', 'Boutique'), isFalse);
  });

  testWidgets('turning off a category the whole-groups list misses still persists', (tester) async {
    final h = await harness();
    final menuKey = await pumpIptvMenu(tester, h.provider, h.registry, xtreamMovie(categoryId: '9'), db: h.db);
    await openMenu(tester, menuKey);

    await tester.tap(find.text('Category: Boutique'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.liveTv.hideCategory));
    await tester.pumpAndSettle();

    final stored = await h.registry.list();
    final storedTrex = stored.singleWhere((c) => c.id == 'trex') as XtreamConnection;
    expect(storedTrex.hiddenCategoryIds, ['9']);
  });

  testWidgets('Plex movie menu still shows File Info and no category row', (tester) async {
    final h = await harness();
    // No server id: the item's own backend marker is what the File Info
    // gate reads, and no client is needed to offer it.
    final item = testMediaItem(
      id: 'movie-1',
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      title: 'Movie',
    );
    final menuKey = await pumpIptvMenu(tester, h.provider, h.registry, item, db: h.db);
    await openMenu(tester, menuKey);

    expect(find.text(t.mediaMenu.fileInfo), findsOneWidget);
    expect(find.textContaining('Category:'), findsNothing);
  });

  testWidgets('an item with no provider category says so honestly', (tester) async {
    final h = await harness();
    final item = testMediaItem(
      id: 'movie:1',
      backend: MediaBackend.xtream,
      kind: MediaKind.movie,
      title: 'Creed',
      serverId: 'trex',
    );
    final menuKey = await pumpIptvMenu(tester, h.provider, h.registry, item, db: h.db);
    await openMenu(tester, menuKey);

    expect(find.text('Category unknown'), findsOneWidget);
    expect(find.text(t.mediaMenu.fileInfo), findsNothing);
    await tester.tap(find.text('Category unknown'));
    await tester.pumpAndSettle();
    expect(find.text('This item has no provider category, so there is nothing to turn off.'), findsOneWidget);
    final stored = await h.registry.list();
    final storedTrex = stored.singleWhere((c) => c.id == 'trex') as XtreamConnection;
    expect(storedTrex.hiddenCategoryIds, isEmpty);
  });

  testWidgets('other menu entries are untouched on an IPTV movie', (tester) async {
    final h = await harness();
    final menuKey = await pumpIptvMenu(tester, h.provider, h.registry, xtreamMovie(), db: h.db);
    await openMenu(tester, menuKey);

    // The entries around the swap, in the order the photo shows them.
    // (Watchlist needs a catalog-sources provider and the external
    // player entry is hidden by this harness's Apple TV override, so
    // neither is asserted here — the entries that do render must all
    // still be present and in place.)
    expect(find.text(t.mediaMenu.markAsWatched), findsOneWidget);
    expect(find.text(t.mediaMenu.rate), findsOneWidget);
    expect(find.text(t.mediaMenu.addToFavorites), findsOneWidget);
    expect(find.text(t.deepLinks.showLink), findsOneWidget);
    expect(find.text(t.common.addTo), findsOneWidget);
  });

  Finder switchTileFor(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byType(FocusableSwitchListTile),
      );

  Future<void> pumpCategoriesScreen(
    WidgetTester tester,
    MultiServerProvider provider,
    ConnectionRegistry registry, {
    XtreamConnection? connection,
  }) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MultiServerProvider>.value(value: provider),
          Provider<ConnectionRegistry>.value(value: registry),
        ],
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          home: IptvCategoriesScreen(connection: connection ?? trexConnection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Settings shows a hidden category the lists never showed, so it can come back', (tester) async {
    final h = await harness(hiddenCategoryIds: ['ghost-1']);
    await pumpCategoriesScreen(tester, h.provider, h.registry, connection: trexConnection(hiddenCategoryIds: ['ghost-1']));

    // 'ghost-1' is in no fetched list — it still appears, turned off, so
    // the owner can switch it back on from here.
    expect(find.text('ghost-1'), findsOneWidget);
    expect(tester.widget<FocusableSwitchListTile>(switchTileFor('ghost-1')).value, isFalse);
  });
}

class _VodCategoryFakeApi extends XtreamApi {
  _VodCategoryFakeApi()
      : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  @override
  Future<Map<String, dynamic>?> getUserInfo() async => const {'username': 'user', 'status': 'Active'};

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async => const [
        XtreamCategory(id: '1', name: 'EN - Live 1'),
        XtreamCategory(id: 'L2', name: 'EN - Live 2'),
      ];

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async => const [
        XtreamCategory(id: '1', name: 'EN - Films 1'),
        XtreamCategory(id: '2', name: 'NF'),
        XtreamCategory(id: '9', name: 'Boutique'),
      ];

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async => const [
        XtreamCategory(id: '2', name: 'NF - Series 1'),
        XtreamCategory(id: 'S2', name: 'Action'),
      ];

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async => const [];

  @override
  Future<XmltvFeedFetch> getXmltvFeed({
    String? etag,
    String? lastModified,
    Duration timeout = const Duration(seconds: 120),
    Future<void>? abortTrigger,
  }) async {
    return (
      bytes: Stream<List<int>>.value(utf8.encode('<?xml version="1.0" encoding="UTF-8"?><tv></tv>')),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async =>
      const [];
}
