import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/screens/profile/user_menu.dart';

void main() {
  PlexAccountConnection plexAccount(String id, String label) => PlexAccountConnection(
    id: id,
    accountToken: 'tok-$id',
    clientIdentifier: 'client-$id',
    accountLabel: label,
    createdAt: DateTime.utc(2026, 1, 1),
  );

  test('one Sign out entry per Plex account, none for IPTV or Jellyfin', () {
    // 1.3.25 §68 (b): the Accounts menu must offer per-account sign-out
    // so a multi-account user can drop one Plex account without the
    // full Log out (which deletes every connection, profile, and
    // setting). IPTV is not a Plex account — it gets no entry.
    final items = plexAccountSignOutMenuItems([
      plexAccount('acct-a', 'acct-a'),
      XtreamConnection(
        id: 'trex',
        serverUrl: 'http://127.0.0.1:1',
        username: 'u',
        password: 'pa' 'ss',
        name: 'IPTV',
        createdAt: DateTime.utc(2026, 1, 1),
      ),
      plexAccount('acct-b', 'acct-b'),
    ]);

    expect(items.map((item) => item.value).toList(), ['signout_plex:acct-a', 'signout_plex:acct-b']);
    expect(items.first.label, contains('acct-a'));
    expect(items.last.label, contains('acct-b'));
  });

  test('no Plex accounts means no sign-out entries', () {
    expect(
      plexAccountSignOutMenuItems([
        XtreamConnection(
          id: 'trex',
          serverUrl: 'http://127.0.0.1:1',
          username: 'u',
          password: 'pa' 'ss',
          name: 'IPTV',
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      ]),
      isEmpty,
    );
  });
}
