import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../utils/app_logger.dart';
import '../base_shared_preferences_service.dart';

/// Per-network "panel unreachable" verdicts (1.2.19, L-23).
///
/// Every launch health-probes every configured server — including a panel
/// blackholed on the current network (home WiFi blocked since Nov 9). A
/// blackholed endpoint does not refuse fast: it waits out the TCP/connect
/// budget (10 s connect / 30 s fetch) per probe, every launch, plus the
/// hub fetches that then time out and render home empty.
///
/// This store remembers the verdict *per network* so a blackholed panel
/// is probed once per network per day, not once per launch:
///
/// * Recorded when an IPTV health probe publishes the server offline
///   after a streak of network-shaped failures (connection timeout /
///   connection error / receive timeout — the panel never answered).
///   A definitive refusal (401/403/other 4xx) or a 429/5xx is NOT
///   recorded: the panel answered, so there is no blackhole wait to skip
///   and no verdict to remember.
/// * Read at the top of the next health probe: an active verdict returns
///   the last-known status with no panel call.
/// * TTL 24 h; a network change (different fingerprint) re-probes
///   immediately; Settings → IPTV offers a manual Retry that clears the
///   verdict.
///
/// The network fingerprint is best-effort: no SSID/BSSID channel exists,
/// so it is the local interface + /24 subnet of the first non-loopback
/// IPv4 address (home Wi-Fi vs a mobile hotspot vs another Wi-Fi differ).
/// The verdict is local-only and per-connection.
abstract final class PanelReachabilityStore {
  /// How long a verdict suppresses the probe on the same network.
  static const Duration verdictTtl = Duration(hours: 24);

  static const String _prefsKeyPrefix = 'iptv_panel_unreachable_v1:';

  @visibleForTesting
  static String? debugNetworkIdOverride;

  /// Best-effort fingerprint of the current network (see class doc).
  static Future<String> currentNetworkId() async {
    final override = debugNetworkIdOverride;
    if (override != null) return override;
    try {
      final interfaces = await NetworkInterface.list();
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.type != InternetAddressType.IPv4) continue;
          if (address.isLoopback || address.isLinkLocal) continue;
          final parts = address.address.split('.');
          if (parts.length == 4) return '${interface.name}:${parts.sublist(0, 3).join('.')}.0/24';
          return '${interface.name}:${address.address}';
        }
      }
    } catch (error, stackTrace) {
      appLogger.d('Panel reachability: network fingerprint unavailable', error: error, stackTrace: stackTrace);
    }
    return 'unknown';
  }

  @visibleForTesting
  static String? debugAddressFamiliesOverride;

  /// Which address families the device currently has a usable,
  /// non-local address in: 'ipv4' | 'ipv6' | 'dual' | 'unknown'
  /// (1.4.3 D2). Best effort, never throws — like [currentNetworkId].
  /// Only the family is ever reported, never an address: the caller
  /// (the refusal log) stores the label, so a 403 that only happens
  /// on IPv6 can be told apart from one that happens on both without
  /// any address ever leaving the device.
  ///
  /// An address counts when it is not loopback, not link-local and
  /// not unique-local (fc00::/7). A global IPv6 address is one in
  /// 2000::/3 — its first hex digit is 2 or 3.
  static Future<String> currentAddressFamilies() async {
    final override = debugAddressFamiliesOverride;
    if (override != null) return override;
    var hasV4 = false;
    var hasV6 = false;
    try {
      final interfaces = await NetworkInterface.list();
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.isLoopback || address.isLinkLocal) continue;
          final text = address.address.toLowerCase();
          if (text.startsWith('fc') || text.startsWith('fd')) continue;
          if (address.type == InternetAddressType.IPv4) {
            hasV4 = true;
          } else if (text.startsWith('2') || text.startsWith('3')) {
            hasV6 = true;
          }
        }
      }
    } catch (error, stackTrace) {
      appLogger.d('Panel reachability: address families unavailable', error: error, stackTrace: stackTrace);
    }
    if (hasV4 && hasV6) return 'dual';
    if (hasV4) return 'ipv4';
    if (hasV6) return 'ipv6';
    return 'unknown';
  }

  static String _prefsKey(String connectionId) => '$_prefsKeyPrefix$connectionId';

  /// The stored verdict for [connectionId], if any: the network it was
  /// recorded on and when. Null when no verdict is stored or it cannot
  /// be parsed.
  static Future<({String networkId, DateTime recordedAt})?> readVerdict({required String connectionId}) async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      final raw = prefs.getString(_prefsKey(connectionId));
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final networkId = decoded['networkId'];
      final recordedAtMs = (decoded['recordedAtMs'] as num?)?.toInt();
      if (networkId is! String || recordedAtMs == null) return null;
      return (
        networkId: networkId,
        recordedAt: DateTime.fromMillisecondsSinceEpoch(recordedAtMs),
      );
    } catch (error, stackTrace) {
      appLogger.d('Panel reachability: verdict unreadable', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  /// True when a verdict is active for [connectionId] on [networkId]
  /// (or the current network when omitted): recorded on this network
  /// and younger than [verdictTtl].
  static Future<bool> isUnreachable({
    required String connectionId,
    String? networkId,
    DateTime? now,
  }) async {
    final verdict = await readVerdict(connectionId: connectionId);
    if (verdict == null) return false;
    final network = networkId ?? await currentNetworkId();
    if (verdict.networkId != network) return false;
    final at = now ?? DateTime.now();
    return at.difference(verdict.recordedAt) < verdictTtl;
  }

  /// Record a verdict for [connectionId] on [networkId] (or the current
  /// network when omitted). Best effort, never throws.
  static Future<void> recordUnreachable({
    required String connectionId,
    String? networkId,
    DateTime? now,
  }) async {
    try {
      final network = networkId ?? await currentNetworkId();
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.setString(
        _prefsKey(connectionId),
        jsonEncode({
          'networkId': network,
          'recordedAtMs': (now ?? DateTime.now()).millisecondsSinceEpoch,
        }),
      );
      appLogger.i('Panel unreachable on $network for $connectionId — probe skipped for 24 h');
    } catch (error, stackTrace) {
      appLogger.d('Panel reachability: verdict unwritable', error: error, stackTrace: stackTrace);
    }
  }

  /// Clear the verdict for [connectionId] (manual Retry in Settings →
  /// IPTV). Best effort, never throws.
  static Future<void> clearVerdict({required String connectionId}) async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.remove(_prefsKey(connectionId));
    } catch (error, stackTrace) {
      appLogger.d('Panel reachability: verdict unclearable', error: error, stackTrace: stackTrace);
    }
  }
}
