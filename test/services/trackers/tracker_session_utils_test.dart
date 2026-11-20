import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/trackers/tracker_constants.dart';
import 'package:plezy/services/trackers/tracker_exceptions.dart';
import 'package:plezy/services/trackers/tracker_session.dart';
import 'package:plezy/services/trackers/tracker_session_utils.dart';

void main() {
  group('tracker token expiry helpers', () {
    test('detects refresh window', () {
      expect(trackerTokenNeedsRefresh(400, nowSeconds: 100), isTrue);
      expect(trackerTokenNeedsRefresh(401, nowSeconds: 100), isFalse);
      expect(trackerTokenNeedsRefresh(110, refreshWindowSeconds: 10, nowSeconds: 100), isTrue);
    });
  });

  group('tracker session json codec', () {
    test('round-trips MDBList sessions with snake-case keys', () {
      const session = TrackerSession(
        accessToken: 'mdblist-at',
        refreshToken: 'mdblist-rt',
        expiresAt: 2000,
        createdAt: 1000,
      );

      expect(session.toJson(), {
        'access_token': 'mdblist-at',
        'refresh_token': 'mdblist-rt',
        'expires_at': 2000,
        'username': null,
        'created_at': 1000,
      });

      final decoded = TrackerSession.fromJson({
        'access_token': 'mdblist-at',
        'refresh_token': 'mdblist-rt',
        'expires_at': 2000,
        'created_at': 1000,
      });

      expect(decoded.accessToken, 'mdblist-at');
      expect(decoded.refreshToken, 'mdblist-rt');
      expect(decoded.expiresAt, 2000);
      expect(decoded.username, isNull);
      expect(decoded.createdAt, 1000);
    });

    test('round-trips MDBList sessions through shared encode mixin', () {
      const session = TrackerSession(
        accessToken: 'mdblist-at',
        refreshToken: 'mdblist-rt',
        expiresAt: 2000,
        username: 'bob',
        createdAt: 1000,
      );

      final decoded = TrackerSession.decode(session.encode());

      expect(decoded.accessToken, 'mdblist-at');
      expect(decoded.refreshToken, 'mdblist-rt');
      expect(decoded.expiresAt, 2000);
      expect(decoded.username, 'bob');
      expect(decoded.createdAt, 1000);
    });

    test('builds MDBList token sessions', () {
      final session = TrackerSession.fromTokenResponse(TrackerService.mdblist, {
        'access_token': 'mdblist-at',
        'refresh_token': 'mdblist-rt',
        'expires_in': 1000,
        'created_at': 1000,
      });

      expect(session.accessToken, 'mdblist-at');
      expect(session.refreshToken, 'mdblist-rt');
      expect(session.expiresAt, 2000);
    });

    test('rejects a MDBList token response without a refresh token', () {
      expect(
        () => TrackerSession.fromTokenResponse(TrackerService.mdblist, {
          'access_token': 'mdblist-at',
          'expires_in': 1000,
          'created_at': 1000,
        }),
        throwsA(isA<TrackerAuthException>()),
      );
    });
  });

  // The migration-safety contract: a service-aware decode (the shape
  // TrackerAccountStore.load uses) must keep accepting every pre-refactor blob
  // shape, and reject corrupt/truncated ones by throwing — TrackerAccountStore
  // swallows that into a clean re-auth rather than loading a broken session.
  group('persisted session validation', () {
    test('decodes a MDBList blob', () {
      final raw = encodeTrackerSessionJson({
        'access_token': 'mdblist-at',
        'refresh_token': 'mdblist-rt',
        'expires_at': 2000,
        'username': 'bob',
        'created_at': 1000,
      });

      final session = TrackerSession.decode(raw, service: TrackerService.mdblist);

      expect(session.accessToken, 'mdblist-at');
      expect(session.refreshToken, 'mdblist-rt');
      expect(session.expiresAt, 2000);
    });

    test('rejects a MDBList blob missing the refresh token', () {
      final raw = encodeTrackerSessionJson({'access_token': 'at', 'expires_at': 2000, 'created_at': 1000});

      expect(
        () => TrackerSession.decode(raw, service: TrackerService.mdblist),
        throwsA(isA<TrackerAuthException>()),
        reason: 'MDBList must require a refresh token',
      );
    });

    test('rejects a MDBList blob with an empty refresh token', () {
      final raw = encodeTrackerSessionJson({
        'access_token': 'at',
        'refresh_token': '',
        'expires_at': 2000,
        'created_at': 1000,
      });

      expect(
        () => TrackerSession.decode(raw, service: TrackerService.mdblist),
        throwsA(isA<TrackerAuthException>()),
        reason: 'MDBList must reject an empty refresh token',
      );
    });

    test('rejects a MDBList blob missing the expiry', () {
      final raw = encodeTrackerSessionJson({
        'access_token': 'at',
        'refresh_token': 'rt',
        'created_at': 1000,
      });

      expect(
        () => TrackerSession.decode(raw, service: TrackerService.mdblist),
        throwsA(isA<TrackerAuthException>()),
        reason: 'MDBList must require an expiry',
      );
    });
  });
}
