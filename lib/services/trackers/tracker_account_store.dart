import '../../profiles/profile.dart';
import '../base_shared_preferences_service.dart';
import 'tracker_constants.dart';
import 'tracker_session.dart';

/// Per-Plex-profile session persistence for any tracker service.
///
/// Keyed by `user_{uuid}_{baseKey}` so each Plex Home profile gets its own
/// stored session. The storage key remains service-specific, while the payload
/// is the unified [TrackerSession] JSON shape.
///
/// Pass an empty `userUuid` to fall back to a single global slot (used
/// before a profile has been selected).
class TrackerAccountStore {
  static final Map<TrackerService, TrackerAccountStore> _stores = {
    TrackerService.mdblist: TrackerAccountStore._(TrackerService.mdblist, 'mdblist_session'),
  };

  static TrackerAccountStore forService(TrackerService service) => _stores[service]!;

  /// One-time purge for the 1.5.2 tracker removal: delete the stored OAuth
  /// sessions of the removed services (Trakt, Simkl, MAL, AniList) for every
  /// profile, plus any queued writes for them. The MDBList session and its
  /// queue rows are untouched. Idempotent and guarded by a flag so it runs
  /// once, on first launch after the update; callers that already hold a
  /// removed service's session in memory never re-read it afterwards.
  static const String _purgeFlagKey = 'tracker_removal_1_5_2_purged';

  static const List<String> _removedSessionBaseKeys = <String>[
    'mal_session',
    'anilist_session',
    'simkl_session',
    'trakt_session',
  ];

  static Future<void> purgeRemovedServiceSessions() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    if (prefs.getBool(_purgeFlagKey) ?? false) return;
    for (final key in prefs.keys) {
      for (final base in _removedSessionBaseKeys) {
        if (key == base || key.endsWith('_$base')) {
          await prefs.remove(key);
        }
      }
    }
    await prefs.setBool(_purgeFlagKey, true);
  }

  final TrackerService service;
  final String _baseKey;

  TrackerAccountStore._(this.service, this._baseKey);

  String _scopedKey(String userUuid) => profileScopedPrefsKey(userUuid, _baseKey);

  Future<TrackerSession?> load(String userUuid) async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final raw = readTolerantString(prefs, _scopedKey(userUuid));
    if (raw == null) return null;
    try {
      return TrackerSession.decode(raw, service: service);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String userUuid, TrackerSession session) async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(_scopedKey(userUuid), session.encode());
  }

  Future<void> clear(String userUuid) async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.remove(_scopedKey(userUuid));
  }
}

TrackerAccountStore trackerAccountStore(TrackerService service) => TrackerAccountStore.forService(service);
