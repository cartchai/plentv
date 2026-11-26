import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/catalog/catalog_item.dart';
import 'package:plezy/models/catalog/catalog_metadata.dart';
import 'package:plezy/navigation/main_screen_scope.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/external_url.dart';
import 'package:plezy/widgets/catalog_context_menu.dart';

const _item = CatalogItem(
  source: CatalogSourceId.mdblist,
  kind: MediaKind.movie,
  title: 'Menu Movie',
  ids: CatalogItemIds(tmdb: 61),
  trailerUrl: 'https://youtu.be/dQw4w9WgXcQ',
  links: [CatalogLink(label: 'StreamCo', url: 'https://example.com/watch', isStreaming: true)],
);

Future<void> _openMenu(
  WidgetTester tester, {
  CatalogItem item = _item,
  void Function(String query)? onSearch,
}) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        theme: monoTheme(MonoPalette.dark),
        home: MainScreenFocusScope(
          focusSidebar: () {},
          sideNavigationWidth: 0,
          searchForQuery: onSearch,
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => unawaited(showCatalogItemMenu(context, item, position: const Offset(10, 10))),
                child: const Text('Open menu'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open menu'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  testWidgets('says so when a link cannot be opened', (tester) async {
    const urlLauncherChannel = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(urlLauncherChannel, (call) async => call.method == 'launch' ? false : null);
    addTearDown(() => messenger.setMockMethodCallHandler(urlLauncherChannel, null));

    await _openMenu(tester);
    await tester.tap(find.text('Open on StreamCo'));
    await tester.pumpAndSettle();

    expect(find.text(t.explore.detail.linkUnavailable), findsOneWidget);
  });

  group('Search this title (1.6.25)', () {
    testWidgets('sits second after View details and calls the seam with the title verbatim', (tester) async {
      final received = <String>[];
      await _openMenu(tester, onSearch: received.add);

      expect(find.text(t.explore.searchThisTitle), findsOneWidget);
      // Placement: directly after "View details", before the trailer.
      final viewDetailsTop = tester.getCenter(find.text(t.mediaMenu.viewDetails)).dy;
      final searchTop = tester.getCenter(find.text(t.explore.searchThisTitle)).dy;
      final trailerTop = tester.getCenter(find.text(t.explore.detail.watchTrailer)).dy;
      expect(viewDetailsTop, lessThan(searchTop));
      expect(searchTop, lessThan(trailerTop));

      await tester.tap(find.text(t.explore.searchThisTitle));
      await tester.pumpAndSettle();
      expect(received, ['Menu Movie']);
    });

    testWidgets('a blank title shows no Search this title entry', (tester) async {
      const blankItem = CatalogItem(
        source: CatalogSourceId.mdblist,
        kind: MediaKind.movie,
        title: '   ',
        ids: CatalogItemIds(tmdb: 61),
      );
      await _openMenu(tester, item: blankItem);

      expect(find.text(t.explore.searchThisTitle), findsNothing);
    });
  });

  group('tvOS runner', () {
    const handoffChannel = MethodChannel('com.plezy/external_player');
    late bool youTubeInstalled;
    late List<String> opened;

    setUp(() {
      debugTvosRunnerOverride = true;
      youTubeInstalled = true;
      opened = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(handoffChannel, (
        call,
      ) async {
        final url = (call.arguments as Map)['url'] as String;
        switch (call.method) {
          case 'canOpenUrl':
            return url == 'youtube://' && youTubeInstalled;
          case 'openUrl':
            opened.add(url);
            return true;
        }
        return null;
      });
    });

    tearDown(() {
      debugTvosRunnerOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(handoffChannel, null);
    });

    testWidgets('drops site links and hands the trailer to the YouTube app', (tester) async {
      await _openMenu(tester);

      expect(find.text('Open on StreamCo'), findsNothing);
      await tester.tap(find.text(t.explore.detail.watchTrailer));
      await tester.pumpAndSettle();

      expect(opened, ['youtube://www.youtube.com/watch?v=dQw4w9WgXcQ']);
    });

    testWidgets('drops the trailer when the YouTube app is missing', (tester) async {
      youTubeInstalled = false;

      await _openMenu(tester);

      expect(find.text(t.mediaMenu.viewDetails), findsOneWidget);
      expect(find.text(t.explore.detail.watchTrailer), findsNothing);
    });
  });
}
