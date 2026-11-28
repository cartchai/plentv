import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_merge.dart';

/// 1.6.35 item 5: the Accounts menu must never list an IPTV connection as
/// if it were a person. A first-run IPTV add invents a local profile named
/// after the connection (iptv_connection_persistence.dart) because the boot
/// guard requires at least one profile — that profile is an anchor, not a
/// user account. [isIptvAnchorProfile] spots it so the menu can hide it
/// and the boot migration can remove it once a real profile exists.
void main() {
  final connCreatedAt = DateTime.utc(2026, 11, 26, 10, 0, 0);

  XtreamConnection xtream({required String id, String name = 'trex', DateTime? createdAt}) => XtreamConnection(
    id: id,
    name: name,
    serverUrl: 'https://panel.example.com:8080',
    username: 'user-$id',
    password: 'pw',
    createdAt: createdAt ?? connCreatedAt,
  );

  M3uConnection m3u({required String id, String name = 'Playlist', DateTime? createdAt}) => M3uConnection(
    id: id,
    name: name,
    playlistUrl: 'https://example.test/playlist.m3u',
    createdAt: createdAt ?? connCreatedAt,
  );

  PlexAccountConnection plexAccount({required String id}) => PlexAccountConnection(
    id: id,
    accountToken: 'token-$id',
    clientIdentifier: 'client-$id',
    accountLabel: 'Plex',
    createdAt: connCreatedAt,
  );

  Profile anchor({String id = 'local-anchor', String name = 'trex', DateTime? createdAt, String? pinHash}) =>
      Profile.local(id: id, displayName: name, pinHash: pinHash, createdAt: createdAt ?? connCreatedAt.add(const Duration(seconds: 5)));

  ProfileConnection row(String profileId, String connectionId) =>
      ProfileConnection(profileId: profileId, connectionId: connectionId, userIdentifier: 'user');

  bool check({
    required Profile profile,
    required Map<String, Connection> connectionsById,
    required List<ProfileConnection> joinRows,
    String? activeProfileId,
    bool hasOtherProfile = true,
  }) => isIptvAnchorProfile(
    profile: profile,
    connectionsById: connectionsById,
    joinRows: joinRows,
    activeProfileId: activeProfileId,
    hasOtherProfile: hasOtherProfile,
  );

  group('isIptvAnchorProfile', () {
    test('detects the invented Xtream anchor profile', () {
      final conn = xtream(id: 'trex-1');
      final profile = anchor();

      expect(
        check(profile: profile, connectionsById: {conn.id: conn}, joinRows: [row(profile.id, conn.id)]),
        isTrue,
      );
    });

    test('detects an M3U anchor too', () {
      final conn = m3u(id: 'm3u-1', name: 'Playlist');
      final profile = anchor(name: 'Playlist');

      expect(
        check(profile: profile, connectionsById: {conn.id: conn}, joinRows: [row(profile.id, conn.id)]),
        isTrue,
      );
    });

    test('detects the anchor when a same-named twin was added later', () {
      final first = xtream(id: 'trex-1');
      final twin = xtream(id: 'trex-2', createdAt: connCreatedAt.add(const Duration(days: 2)));
      final profile = anchor();

      expect(
        check(
          profile: profile,
          connectionsById: {first.id: first, twin.id: twin},
          joinRows: [row(profile.id, first.id)],
        ),
        isTrue,
      );
    });

    test('not an anchor when it is the active profile', () {
      final conn = xtream(id: 'trex-1');
      final profile = anchor();

      expect(
        check(
          profile: profile,
          connectionsById: {conn.id: conn},
          joinRows: [row(profile.id, conn.id)],
          activeProfileId: profile.id,
        ),
        isFalse,
      );
    });

    test('not an anchor when it is the only profile (load-bearing)', () {
      final conn = xtream(id: 'trex-1');
      final profile = anchor();

      expect(
        check(
          profile: profile,
          connectionsById: {conn.id: conn},
          joinRows: [row(profile.id, conn.id)],
          hasOtherProfile: false,
        ),
        isFalse,
      );
    });

    test('not an anchor when it has a PIN', () {
      final conn = xtream(id: 'trex-1');
      final profile = anchor(pinHash: 'deadbeef');

      expect(
        check(profile: profile, connectionsById: {conn.id: conn}, joinRows: [row(profile.id, conn.id)]),
        isFalse,
      );
    });

    test('not an anchor when it also holds a Plex row', () {
      final iptv = xtream(id: 'trex-1');
      final plex = plexAccount(id: 'plex-1');
      final profile = anchor();

      expect(
        check(
          profile: profile,
          connectionsById: {iptv.id: iptv, plex.id: plex},
          joinRows: [row(profile.id, iptv.id), row(profile.id, plex.id)],
        ),
        isFalse,
      );
    });

    test('not an anchor when its name matches no connection', () {
      final conn = xtream(id: 'trex-1', name: 'other-service');
      final profile = anchor();

      expect(
        check(profile: profile, connectionsById: {conn.id: conn}, joinRows: [row(profile.id, conn.id)]),
        isFalse,
      );
    });

    test('not an anchor when created an hour after the connection', () {
      final conn = xtream(id: 'trex-1');
      final profile = anchor(createdAt: connCreatedAt.add(const Duration(hours: 1)));

      expect(
        check(profile: profile, connectionsById: {conn.id: conn}, joinRows: [row(profile.id, conn.id)]),
        isFalse,
      );
    });

    test('not an anchor when created 11 minutes after the connection', () {
      final conn = xtream(id: 'trex-1');
      final profile = anchor(createdAt: connCreatedAt.add(const Duration(minutes: 11)));

      expect(
        check(profile: profile, connectionsById: {conn.id: conn}, joinRows: [row(profile.id, conn.id)]),
        isFalse,
      );
    });

    test('not an anchor for a Plex Home profile', () {
      final conn = xtream(id: 'trex-1');
      final profile = Profile.plexHome(
        id: 'plex-home-plex-1-user-1',
        displayName: 'trex',
        parentConnectionId: 'plex-1',
        createdAt: connCreatedAt.add(const Duration(seconds: 5)),
      );

      expect(
        check(profile: profile, connectionsById: {conn.id: conn}, joinRows: [row(profile.id, conn.id)]),
        isFalse,
      );
    });

    test('not an anchor with no join rows', () {
      final conn = xtream(id: 'trex-1');
      final profile = anchor();

      expect(check(profile: profile, connectionsById: {conn.id: conn}, joinRows: const []), isFalse);
    });

    test('not an anchor when its join row points at a missing connection', () {
      final profile = anchor();

      expect(
        check(profile: profile, connectionsById: const {}, joinRows: [row(profile.id, 'gone')]),
        isFalse,
      );
    });
  });
}
