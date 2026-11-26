import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/live_tv_support.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/models/catalog/catalog_item.dart';
import 'package:plezy/models/catalog/catalog_metadata.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_person.dart';
import 'package:plezy/navigation/navigation_tabs.dart';
import 'package:plezy/profiles/active_profile_binder.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/providers/account_preferences_controller.dart';
import 'package:plezy/providers/catalog_sources_provider.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/providers/explore_provider.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/main_screen.dart';
import 'package:plezy/screens/search_screen.dart';
import 'package:plezy/services/catalog/catalog_source.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:provider/provider.dart';

import '../test_helpers/download_fixtures.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/profile_navigation.dart';
import '../test_helpers/profile_stack.dart';
import '../test_helpers/pump.dart';

/// MainScreen phone tap-through for the 1.6.25 Explore search bug (Matt,
/// 2026-11-25 ~21:00 EST): in Explore, long-press a title, tap
/// "Search this title" — NOTHING happened at all.
///
/// Root cause (diagnosis paper
/// `plezy-tv-diagnose-explore-search/DIAGNOSIS_EXPLORE_SEARCH.md`):
/// `MainScreenFocusScope` was constructed only in MainScreen's side-nav
/// (TV/desktop) branch, so on a phone the menu's
/// `searchForQuery` lookup resolved to null and the tap was silently
/// swallowed. 1.6.26 wraps the phone branch in the scope too.
///
/// This is the FIRST test in the repo that pumps `MainScreen` at all. It
/// proves the full production tap-through on the phone branch: Explore
/// long-press → "Search this title" → Search tab opens with the title →
/// the query runs → results render. It runs on the phone branch (the test
/// binding defaults to Android; the override below just makes that
/// explicit). The TV branch is covered by the side-nav scope construction
/// being untouched — see `catalog_context_menu_test.dart` for the menu
/// seam itself.

/// One movie, shared by Explore (the card) and the fake Plex search (the
/// result), so the tap-through is end-to-end on one title.
const _title = 'Menu Movie';

const _catalogItem = CatalogItem(
  source: CatalogSourceId.mdblist,
  kind: MediaKind.movie,
  title: _title,
  ids: CatalogItemIds(tmdb: 61),
);

/// Fake Plex client: answers the search with the one movie, records the
/// queries so the test can prove the search actually ran.
class _FakePlexClient implements MediaServerClient {
  _FakePlexClient({required this.items});

  final List<MediaItem> items;
  final List<String> queries = [];

  @override
  ServerId get serverId => ServerId('server_1');

  @override
  String? get serverName => 'Server';

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.plex;

  @override
  Object get authenticationSessionId => 'test-session';

  @override
  LiveTvSupport get liveTv => _liveTv;
  final _liveTv = _FakeLiveTvSupport();

  @override
  Future<List<MediaLibrary>> fetchLibraries() async => const [];

  @override
  Future<List<MediaItem>> searchItems(
    String query, {
    int limit = 100,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
    bool onlineAllowed = false,
  }) async {
    queries.add(query);
    abort?.throwIfAborted();
    return items;
  }

  @override
  Future<List<MediaPerson>> searchPeople(
    String query, {
    int limit = defaultPeopleSearchLimit,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async {
    abort?.throwIfAborted();
    return const [];
  }

  // The binder's no-profile rebind removes every registered server and
  // closes it — the fake must survive being closed and re-registered.
  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Live TV support that reports unavailable: the harness has no Live TV,
/// so the availability check must settle to "none" without touching a
/// server. (`checkLiveTvAvailability` reads `authenticationSessionId`
/// outside its try/catch, so the fake client must answer that one —
/// `liveTv.isAvailable()` is inside the try and would only be logged.)
class _FakeLiveTvSupport implements LiveTvSupport {
  @override
  Future<bool> isAvailable() async => false;

  @override
  LiveTvDvrSupport? get dvr => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Fake catalog source for Explore: one row with the one movie. Shape
/// copied from `explore_screen_test.dart` — the remaining CatalogSource
/// members ride `noSuchMethod` and are never called here (the item's own
/// source does not support watchlist, so the menu never asks it).
class _FakeCatalogSource implements CatalogSource, CatalogHubSource {
  final WatchlistChangeNotifier _watchlistChanges = WatchlistChangeNotifier();

  @override
  CatalogSourceId get id => CatalogSourceId.mdblist;

  @override
  String get displayName => 'MDBList';

  @override
  List<CatalogRowId> get supportedRows => const [CatalogRowId.popularMovies];

  @override
  bool get supportsWatchlist => false;

  @override
  Listenable get watchlistChanges => _watchlistChanges;

  @override
  Future<CatalogPage> fetchRow(CatalogRowId row, {int page = 1, int limit = 25}) async {
    return CatalogPage(items: const [_catalogItem], hasMore: false, totalResults: 1);
  }

  @override
  Future<List<CatalogItem>> search(String query, {int limit = 30}) async {
    return const [_catalogItem];
  }

  @override
  Future<List<CatalogHub>> fetchHubs({int limit = 25}) async => const [];

  @override
  Future<CatalogPage> fetchHub(String id, {int page = 1, int limit = 25}) async => const CatalogPage(items: []);

  @override
  void dispose() => _watchlistChanges.dispose();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// CatalogSourcesProvider over the fake source (copied shape from
/// `explore_screen_test.dart` — the real provider only binds Plex /
/// MDBList / Seerr sessions, none of which exist in this harness).
class _FakeCatalogSourcesProvider extends CatalogSourcesProvider {
  _FakeCatalogSourcesProvider(this.sources);

  final List<CatalogSource> sources;

  @override
  List<CatalogSource> get connectedSources => sources;

  @override
  CatalogSource? get activeSource => sources.isEmpty ? null : sources.first;

  @override
  Future<void> setActiveSource(CatalogSourceId? id, {void Function()? checkCurrent}) async {
    checkCurrent?.call();
  }
}

/// DownloadProvider that never does anything: MainScreen's startup prime
/// runs (the fake Plex client is online), so the real DownloadProvider
/// reads must land somewhere safe instead of throwing via noSuchMethod.
class _NoOpDownloadProvider extends NoSyncRulesDownloadProvider {
  @override
  Future<void> ensureInitialized() async {}

  @override
  Future<void> refreshMetadataFromCache() async {}

  @override
  void resumeQueuedDownloads(MediaServerClient client) {}

  @override
  Future<void> syncDownloadCollections(MultiServerManager serverManager, Iterable<String> serverIds) async {}
}

class _MainScreenHarness {
  _MainScreenHarness({
    required this.stack,
    required this.client,
    required this.multiServer,
    required this.catalogSources,
    required this.explore,
    required this.libraries,
    required this.hiddenLibraries,
    required this.playbackState,
    required this.binder,
    required this.accountPreferences,
    required this.watchTogether,
    required this.companionRemote,
    required this.offlineWatchSync,
    required this.downloads,
  });

  final ProfileStack stack;
  final _FakePlexClient client;
  final MultiServerProvider multiServer;
  final _FakeCatalogSourcesProvider catalogSources;
  final ExploreProvider explore;
  final LibrariesProvider libraries;
  final HiddenLibrariesProvider hiddenLibraries;
  final PlaybackStateProvider playbackState;
  final ActiveProfileBinder binder;
  final AccountPreferencesController accountPreferences;
  final WatchTogetherProvider watchTogether;
  final CompanionRemoteProvider companionRemote;
  final OfflineWatchSyncService offlineWatchSync;
  final _NoOpDownloadProvider downloads;

  bool _disposed = false;

  Future<void> dispose(WidgetTester tester) async {
    // Idempotent: the test body disposes synchronously at its end (the
    // framework's timer/debug-var invariants run before tearDowns, so a
    // timer left alive until tearDown fails the test), and the tearDown
    // re-call below is then a no-op.
    if (_disposed) return;
    _disposed = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    // The Drift stream cancels inside stack.dispose() need real async
    // turns: once the binder started the profile/connection subscriptions,
    // awaiting them in the fake-async zone hangs. runAsync lets them land.
    await tester.runAsync(() => stack.dispose());
    multiServer.dispose();
    catalogSources.dispose();
    explore.dispose();
    libraries.dispose();
    hiddenLibraries.dispose();
    playbackState.dispose();
    accountPreferences.dispose();
    watchTogether.dispose();
    companionRemote.dispose();
    offlineWatchSync.dispose();
    downloads.dispose();
  }
}

Future<_MainScreenHarness> _pumpMainScreenPhone(WidgetTester tester) async {
  // Phone branch + phone viewport, explicit (the test binding defaults to
  // Android, but the branch under test must not depend on that).
  // isDesktopOS() reads the HOST OS (dart:io) — Linux here — so without
  // the override MainScreen would touch the unmocked window_manager
  // channel in initState/dispose.
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  PlatformDetector.debugSetIsDesktopOSOverride(false);
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = const Size(1170, 2532);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });

  // Open straight on Explore so Discover never mounts: the tap-through
  // starts there, and Discover's hub load is not part of this proof.
  final settings = await SettingsService.getInstance();
  await settings.write(SettingsService.startupSection, NavigationTabId.explore);

  // withStorage:false — PROVEN NECESSARY by a throwaway probe (run during
  // this build, then removed): calling `SettingsService.getInstance()`
  // in setUp and then `StorageService.getInstance()` (via
  // `ProfileStack.create()` with storage) hangs the test until the
  // ten-minute timeout — the second `initializeInstance` for a different
  // `BaseSharedPreferencesService` subclass never completes in the
  // `testWidgets` fake-async zone, while `withStorage:false` completes
  // immediately. The storage is only the Plex Home / active-profile
  // persistence cache; both accept null here and the tap-through does
  // not need it.
  final stack = await ProfileStack.create(withStorage: false);
  final manager = MultiServerManager();
  final client = _FakePlexClient(
    items: [
      testMediaItem(
        id: 'movie_1',
        backend: MediaBackend.plex,
        kind: MediaKind.movie,
        title: _title,
        serverId: 'server_1',
        serverName: 'Server',
      ),
    ],
  );
  manager.debugRegisterClientForTesting(client);
  final multiServer = testMultiServerProvider(manager);

  final source = _FakeCatalogSource();
  final catalogSources = _FakeCatalogSourcesProvider([source]);
  final explore = ExploreProvider(catalogSources);
  final libraries = LibrariesProvider();
  final hiddenLibraries = HiddenLibrariesProvider();
  final playbackState = PlaybackStateProvider();
  final binder = ActiveProfileBinder(
    activeProfile: stack.active,
    connections: stack.connections,
    profileConnections: stack.profileConnections,
    serverManager: manager,
    multiServerProvider: multiServer,
    pinPrompt: (_, {String? errorMessage}) async => null,
  );
  final accountPreferences = AccountPreferencesController();
  final watchTogether = WatchTogetherProvider();
  final companionRemote = CompanionRemoteProvider();
  final offlineWatchSync = OfflineWatchSyncService(database: stack.db, serverManager: manager);
  final downloads = _NoOpDownloadProvider();

  final harness = _MainScreenHarness(
    stack: stack,
    client: client,
    multiServer: multiServer,
    catalogSources: catalogSources,
    explore: explore,
    libraries: libraries,
    hiddenLibraries: hiddenLibraries,
    playbackState: playbackState,
    binder: binder,
    accountPreferences: accountPreferences,
    watchTogether: watchTogether,
    companionRemote: companionRemote,
    offlineWatchSync: offlineWatchSync,
    downloads: downloads,
  );
  addTearDown(() => harness.dispose(tester));

  await tester.pumpWidget(
    TranslationProvider(
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<MultiServerProvider>.value(value: multiServer),
          ChangeNotifierProvider<CatalogSourcesProvider>.value(value: catalogSources),
          ChangeNotifierProvider<ExploreProvider>.value(value: explore),
          ChangeNotifierProvider<LibrariesProvider>.value(value: libraries),
          ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hiddenLibraries),
          ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
          ChangeNotifierProvider<ActiveProfileProvider>.value(value: stack.active),
          Provider<PlexHomeService>.value(value: stack.plexHome),
          Provider<ConnectionRegistry>.value(value: stack.connections),
          Provider<ActiveProfileBinder>.value(value: binder),
          ChangeNotifierProvider<AccountPreferencesController>.value(value: accountPreferences),
          ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
          ChangeNotifierProvider<CompanionRemoteProvider>.value(value: companionRemote),
          ChangeNotifierProvider<OfflineWatchSyncService>.value(value: offlineWatchSync),
          ChangeNotifierProvider<DownloadProvider>.value(value: downloads),
        ],
        child: withProfileNavigationScope(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            // initialPromptHandled skips the first-login profile picker —
            // no profiles exist in this harness and the picker is not
            // part of this proof.
            home: const MainScreen(initialPromptHandled: true),
          ),
        ),
      ),
    ),
  );

  // The binder's no-profile rebind (MainScreen's post-frame `binder.start()`)
  // removes every registered server and closes it, and zeroes the visibility
  // filter — the fake Plex client is gone by the time the first pump lands.
  // Wait until the clear has happened (the client leaving
  // `visibleOnlineClients` is the observable), then put the client back and
  // clear the filter (null = all visible), so the search step has a server
  // to query. Nothing re-runs the binder after this unless a profile
  // switches, and the final check proves the client stuck.
  await pumpUntil(
    tester,
    () => !manager.visibleOnlineClients.containsKey('server_1'),
    describe: () => 'binder cleared the fake server',
  );
  manager.debugRegisterClientForTesting(client);
  multiServer.setVisibleServerIds(null);
  multiServer.setExpectedVisibleServerIds(null);
  await tester.pump();
  await pumpUntil(
    tester,
    () => manager.visibleOnlineClients.containsKey('server_1'),
    describe: () => 'fake server back online + visible',
  );

  return harness;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
  });

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  testWidgets('phone: Explore long-press Search this title opens Search and runs the query', (tester) async {
    final harness = await _pumpMainScreenPhone(tester);

    // Explore loads its row from the fake source.
    await pumpUntil(
      tester,
      () => find.text(_title).evaluate().isNotEmpty,
      describe: () => 'Explore card "$_title"',
    );

    // Long-press the card → the catalog context menu. Scroll it into view
    // first: the card sits low in the Explore list, and a menu anchored
    // below a bottom-of-screen card opens off-screen (the tap then misses).
    await tester.ensureVisible(find.text(_title).first);
    await tester.pump();
    await tester.longPress(find.text(_title).first);
    // The sheet slides up over 250 ms: the entry exists in the tree from
    // the first frame, still translated below the viewport — wait until
    // its centre is actually on-screen, or the tap misses mid-slide.
    final viewportHeight = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    await pumpUntil(
      tester,
      () {
        final entry = find.text(t.explore.searchThisTitle);
        if (entry.evaluate().isEmpty) return false;
        final dy = tester.getCenter(entry).dy;
        return dy > 0 && dy < viewportHeight;
      },
      describe: () => '"${t.explore.searchThisTitle}" menu entry on-screen',
    );

    // Tap it: Search tab opens, field holds the title verbatim, the
    // query runs against the server, results render.
    await tester.tap(find.text(t.explore.searchThisTitle));
    await pumpUntil(
      tester,
      () => find.byType(SearchScreen).evaluate().isNotEmpty,
      describe: () => 'SearchScreen mounted',
    );
    await pumpUntil(
      tester,
      () => harness.client.queries.contains(_title),
      describe: () => 'search queries ${harness.client.queries}',
    );

    final searchField = find.descendant(of: find.byType(SearchScreen), matching: find.byType(TextField));
    expect(tester.widget<TextField>(searchField).controller?.text, _title);
    await pumpUntil(
      tester,
      () =>
          find
              .descendant(of: find.byType(SearchScreen), matching: find.text(_title))
              .evaluate()
              .isNotEmpty,
      describe: () => 'Search result "$_title"',
    );

    // Dispose synchronously here, before the test ends: the framework's
    // timer/debug-var invariants run before tearDowns, so a timer left
    // alive until tearDown (the Plex Home refresh timer, MainScreen's
    // startup-settle timeout) fails the test. The tearDown re-call is a
    // no-op (dispose is idempotent).
    await harness.dispose(tester);

    // Reset before the test ends: the framework checks foundation debug
    // vars before tearDowns run, so an addTearDown reset is too late.
    debugDefaultTargetPlatformOverride = null;
    PlatformDetector.debugSetIsDesktopOSOverride(null);
  });
}
