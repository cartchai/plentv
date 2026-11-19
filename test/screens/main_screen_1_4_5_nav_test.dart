import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/navigation/navigation_tabs.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_avatar.dart';
import 'package:plezy/screens/main_screen.dart';
import 'package:plezy/screens/profile/user_menu.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:plezy/widgets/app_menu.dart';

void main() {
  group('1.4.5 phone bar order', () {
    test('mobile bar is Search first, Downloads gone, Home second', () {
      final visible = NavigationTab.getVisibleTabs(isOffline: false, hasLiveTv: true, hasExplore: true);
      final bar = mainScreenBottomNavigationTabs(
        visibleTabs: visible,
        isMobile: true,
        isOffline: false,
        currentTab: NavigationTabId.discover,
      );
      expect(
        bar.map((t) => t.id).toList(),
        [
          NavigationTabId.search,
          NavigationTabId.discover,
          NavigationTabId.libraries,
          NavigationTabId.liveTv,
          NavigationTabId.explore,
        ],
      );
    });

    test('mobile bar offline has no Downloads destination', () {
      final visible = NavigationTab.getVisibleTabs(isOffline: true, hasLiveTv: false, hasExplore: false);
      final bar = mainScreenBottomNavigationTabs(
        visibleTabs: visible,
        isMobile: true,
        isOffline: true,
        currentTab: NavigationTabId.downloads,
      );
      expect(bar.map((t) => t.id), isNot(contains(NavigationTabId.downloads)));
    });

    test('non-mobile bar order is untouched', () {
      final visible = NavigationTab.getVisibleTabs(isOffline: false, hasLiveTv: true, hasExplore: true);
      final bar = mainScreenBottomNavigationTabs(
        visibleTabs: visible,
        isMobile: false,
        isOffline: false,
        currentTab: NavigationTabId.discover,
      );
      expect(bar, visible);
    });

    test('Search is first in the bar but Home is still the default tab', () {
      final visible = NavigationTab.getVisibleTabs(isOffline: false, hasLiveTv: true, hasExplore: true);
      final bar = mainScreenBottomNavigationTabs(
        visibleTabs: visible,
        isMobile: true,
        isOffline: false,
        currentTab: NavigationTabId.discover,
      );
      expect(bar.first.id, NavigationTabId.search);
      expect(
        NavigationTab.resolveDefaultTab(isOffline: false, hasLiveTv: true, preferredStartup: null),
        NavigationTabId.discover,
      );
    });
  });

  group('Accounts destination', () {
    test('no active profile shows the generic account icon', () {
      final destination = accountsNavigationDestination(activeProfile: null, avatarUrl: null);
      expect(destination.label, 'Accounts');
      expect(destination.icon, isA<AppIcon>());
    });

    test('active profile shows its avatar', () {
      final profile = Profile.local(id: 'p1', displayName: 'Test', createdAt: DateTime(2026));
      final destination = accountsNavigationDestination(activeProfile: profile, avatarUrl: null);
      expect(destination.label, 'Accounts');
      final icon = destination.icon;
      expect(icon, isA<ProfileAvatar>());
      expect((icon as ProfileAvatar).profile, profile);
    });
  });

  group('Accounts menu entries', () {
    List<String> itemValues(List<AppMenuEntry<String>> entries) {
      return entries.whereType<AppMenuItem<String>>().map((item) => item.value).toList();
    }

    test('Downloads sits right after Settings; Profiles, Settings, Log out still there', () {
      final entries = buildUserMenuEntries(
        activeProfile: null,
        profiles: const [],
        connections: const <Connection>[],
        avatarUrlFor: (_) => null,
        lockIconColor: Colors.grey,
      );
      final values = itemValues(entries);
      expect(values, contains('downloads'));
      expect(values, contains('manage_profiles'));
      expect(values, contains('settings'));
      expect(values, contains('logout'));
      expect(values.indexOf('downloads'), values.indexOf('settings') + 1);
    });

    test('profile rows still come first', () {
      final other = Profile.local(id: 'p2', displayName: 'Other', createdAt: DateTime(2026));
      final entries = buildUserMenuEntries(
        activeProfile: null,
        profiles: [other],
        connections: const <Connection>[],
        avatarUrlFor: (_) => null,
        lockIconColor: Colors.grey,
      );
      final values = itemValues(entries);
      expect(values.first, 'profile:p2');
    });
  });

  group('Accounts menu Downloads action', () {
    testWidgets('selecting Downloads calls the scope selectTab', (tester) async {
      NavigationTabId? selected;
      late BuildContext childContext;

      await tester.pumpWidget(
        MaterialApp(
          home: MainScreenFocusScope(
            focusSidebar: () {},
            sideNavigationWidth: 0,
            selectTab: (tab) => selected = tab,
            child: Builder(
              builder: (context) {
                childContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      await handleUserMenuSelection(childContext, 'downloads');
      expect(selected, NavigationTabId.downloads);
    });

    testWidgets('selecting Downloads prefers an explicit callback over the scope', (tester) async {
      NavigationTabId? viaCallback;
      NavigationTabId? viaScope;
      late BuildContext childContext;

      await tester.pumpWidget(
        MaterialApp(
          home: MainScreenFocusScope(
            focusSidebar: () {},
            sideNavigationWidth: 0,
            selectTab: (tab) => viaScope = tab,
            child: Builder(
              builder: (context) {
                childContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      await handleUserMenuSelection(
        childContext,
        'downloads',
        onSelectDownloads: () => viaCallback = NavigationTabId.downloads,
      );
      expect(viaCallback, NavigationTabId.downloads);
      expect(viaScope, isNull);
    });

    testWidgets('Downloads with no scope and no callback is a no-op', (tester) async {
      late BuildContext childContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              childContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      await expectLater(() => handleUserMenuSelection(childContext, 'downloads'), returnsNormally);
    });
  });
}
