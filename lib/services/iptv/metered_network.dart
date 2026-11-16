import 'package:connectivity_plus/connectivity_plus.dart';

import '../base_shared_preferences_service.dart';
import '../native_device_info.dart';
import '../settings_service.dart';

/// The metered / Data Saver state of the active network, as the
/// large-download gate sees it (1.2.19, L-42 + L-4).
class MeteredNetworkState {
  const MeteredNetworkState({required this.metered, required this.dataSaver, required this.known});

  /// The active network is metered (mobile data, or a metered Wi-Fi).
  final bool metered;

  /// Android Data Saver is on (background data restricted).
  final bool dataSaver;

  /// False when neither the platform channel nor connectivity_plus
  /// could answer — the state is unknown, not unmetered.
  final bool known;

  static const unknown = MeteredNetworkState(metered: false, dataSaver: false, known: false);
}

/// Policy for large downloads on metered links (1.2.19, L-42 + L-4):
/// the 88 MB EPG feed, the per-type catalog sync, and the ~363 MB APK
/// update must not silently burn metered data when the user asked for
/// Wi-Fi-only large downloads — but the gate must never strand the
/// guide/sync on the user's only working network (home WiFi is
/// Trex-blocked for this user, so mobile data IS the working path).
/// The Wi-Fi-only preference defaults OFF (current behaviour); turning
/// it on defers large downloads on metered links until an unmetered
/// link is available, and the sync records the deferral in its
/// last-run tile ("sync incomplete — will finish on Wi-Fi").
class MeteredNetwork {
  /// Read the current state: the native metered/Data Saver state first
  /// ([NativeDeviceInfo.networkMeteredState]), falling back to the
  /// connectivity_plus link type (mobile = metered, Wi-Fi/Ethernet =
  /// unmetered) when the channel cannot answer. Never throws — an
  /// unreadable state reads as [MeteredNetworkState.unknown].
  static Future<MeteredNetworkState> currentState() async {
    try {
      final native = await NativeDeviceInfo.networkMeteredState();
      if (native != null) {
        return MeteredNetworkState(
          metered: native['metered'] == true,
          dataSaver: native['dataSaver'] == true,
          known: true,
        );
      }
    } catch (_) {
      // Fall through to the link-type proxy below.
    }
    try {
      final results = await Connectivity().checkConnectivity().timeout(
        const Duration(seconds: 5),
        onTimeout: () => const <ConnectivityResult>[],
      );
      if (results.isEmpty) return MeteredNetworkState.unknown;
      // A VPN result rides on top of the underlying link, so it says
      // nothing about metered-ness on its own — look past it.
      final withoutVpn = results.where((r) => r != ConnectivityResult.vpn).toList(growable: false);
      final effective = withoutVpn.isEmpty ? results : withoutVpn;
      if (effective.contains(ConnectivityResult.mobile)) {
        return const MeteredNetworkState(metered: true, dataSaver: false, known: true);
      }
      if (effective.contains(ConnectivityResult.wifi) || effective.contains(ConnectivityResult.ethernet)) {
        return const MeteredNetworkState(metered: false, dataSaver: false, known: true);
      }
      return MeteredNetworkState.unknown;
    } catch (_) {
      return MeteredNetworkState.unknown;
    }
  }

  /// True when a large download should be deferred on this link: the
  /// user turned on Wi-Fi-only for large downloads AND the link is
  /// metered. An unknown link never defers — failing open is the safe
  /// default (see the class doc): failing closed would strand the
  /// sync/feed on the user's only working network.
  static bool shouldDeferLargeDownload({required bool wifiOnly, required MeteredNetworkState state}) =>
      wifiOnly && state.known && state.metered;

  /// True when large downloads should be deferred right now: the
  /// user turned on Wi-Fi-only large downloads AND the active link is
  /// metered. The preference is read from the already-initialized
  /// SettingsService instance when one exists — awaiting a cold
  /// shared-prefs load here deadlocks widget tests (the load does
  /// genuine file I/O that never completes under fake async, and this
  /// runs on every feed load; proven by the EPG area screens test,
  /// which hung on `pumpAndSettle` until the guard stopped awaiting
  /// a cold cache). In the app the instance is initialized at startup,
  /// before any guide loads, so the warm read is the normal path. With
  /// no instance yet (a background isolate, which has no
  /// SettingsService), the shared cache is awaited instead — real
  /// async I/O completes there. Never throws — an unreadable state
  /// reads as "do not defer" (failing open: the working path is
  /// mobile data).
  static Future<bool> largeDownloadsDeferred() async {
    try {
      final instance = SettingsService.instanceOrNull;
      final bool wifiOnly;
      if (instance != null) {
        wifiOnly = instance.read(SettingsService.iptvLargeDownloadsWifiOnly);
      } else {
        final prefs = await BaseSharedPreferencesService.sharedCache();
        wifiOnly = prefs.getBool(SettingsService.iptvLargeDownloadsWifiOnly.key) ?? false;
      }
      if (!wifiOnly) return false;
      final state = await currentState();
      return shouldDeferLargeDownload(wifiOnly: wifiOnly, state: state);
    } catch (_) {
      return false;
    }
  }
}
