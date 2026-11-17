import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';

void main() {
  test('the Log out confirmation states what the full logout deletes', () async {
    // 1.3.25 §68 (b): the bare "Are you sure you want to log out?" hid
    // that Log out wipes every connection (including IPTV), every
    // profile, and all settings. The prompt must say so, and point at
    // the per-account sign-out instead.
    final english = await AppLocale.en.build();
    final message = english.messages.logoutConfirm;

    expect(message, contains('IPTV'));
    expect(message, contains('profile'));
    expect(message, contains('settings'));
    expect(message, contains('connection'));
    expect(message.toLowerCase(), contains('sign out'));
  });

  test('the per-account sign-out label names the account', () async {
    final english = await AppLocale.en.build();
    expect(english.profiles.signOutPlexAccount(displayName: 'acct-a'), contains('acct-a'));
  });
}
