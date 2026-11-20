import 'dart:ffi';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'base_shared_preferences_service.dart';

/// Service to check for new versions on GitHub
/// Only enabled when ENABLE_UPDATE_CHECK build flag is set
///
/// 1.2.22 §66 (U5): the native desktop updater is gone entirely — its
/// appcast was the upstream feed (it would offer upstream Plezy builds)
/// and the fork never used it (`useNativeUpdater` was hard-coded false).
/// Every platform uses the GitHub API check + browser link dialog.
///
/// PlenTV fork notes (build #6):
/// - The check points at the FORK repo (cartchai/plentv), not upstream
///   edde746/plezy — an update must never offer an upstream Plezy build.
///   1.6: the repo is the new `plentv` repo; until its first release
///   lands, the check quietly reports no update (a non-200 answer reads
///   as "no update", never an error).
/// - On Android the flow is: check -> dialog with version + changelog ->
///   "Download APK" opens the release's .apk asset in the browser -> the
///   user opens the download and the system installer puts it over the
///   current install. All current builds are debug-signed with the same
///   debug key, so the over-the-top update keeps its signature. Switching
///   to release signing later WILL break this path (signature mismatch) and
///   must be handled then, not now.
class UpdateService {
  static const String _githubRepo = 'cartchai/plentv';

  /// Public releases page, linked from the Settings Updates section.
  static const String releasesUrl = 'https://github.com/cartchai/plentv/releases';

  static const String _keySkippedVersion = 'update_skipped_version';
  static const String _keyLastCheckTime = 'update_last_check_time';

  // Check cooldown: 6 hours
  static const Duration _checkCooldown = Duration(hours: 6);

  /// Check if update checking is enabled via build flag
  static bool get isUpdateCheckEnabled {
    return const bool.fromEnvironment('ENABLE_UPDATE_CHECK', defaultValue: false);
  }

  /// Whether any in-app update path applies to this install.
  /// False inside a packaged (MSIX/Store) install: the Store owns updates and
  /// the package directory is read-only, so neither WinSparkle nor the GitHub
  /// fallback dialog has anything it can do. Gates the settings entry too, so
  /// no dead affordance ships.
  static bool get isUpdateCheckAvailable => isUpdateCheckEnabled && !PlatformDetector.isPackagedInstall();

  static Future<void> skipVersion(String version) async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(_keySkippedVersion, version);
  }

  static Future<String?> getSkippedVersion() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    return prefs.getString(_keySkippedVersion);
  }

  /// Check if cooldown period has passed since last check
  static Future<bool> shouldCheckForUpdates() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final lastCheckString = prefs.getString(_keyLastCheckTime);
    if (lastCheckString == null) return true;

    final now = DateTime.now();
    final lastCheck = DateTime.tryParse(lastCheckString);
    if (lastCheck == null || lastCheck.isAfter(now)) {
      await prefs.remove(_keyLastCheckTime);
      return true;
    }

    return now.difference(lastCheck) >= _checkCooldown;
  }

  static Future<void> _updateLastCheckTime() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(_keyLastCheckTime, DateTime.now().toIso8601String());
  }

  /// Internal method that performs the actual update check
  /// [respectCooldown] - if true, checks cooldown and records the attempt before the request
  /// [throwOnFailure] - if true, a failed check (network, non-200, bad payload)
  /// is rethrown instead of reading as "no update"
  /// [deviceAbi] - test seam for the per-ABI asset pick (1.2.21): production
  /// passes nothing and [Abi.current()] is used.
  static Future<Map<String, dynamic>?> _performUpdateCheck({
    required bool respectCooldown,
    MediaServerHttpClient? client,
    bool forceEnabled = false,
    bool throwOnFailure = false,
    Abi? deviceAbi,
  }) async {
    if (!forceEnabled && !isUpdateCheckAvailable) {
      return null;
    }

    // Check cooldown if requested
    if (respectCooldown && !await shouldCheckForUpdates()) {
      return null;
    }

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      if (respectCooldown) {
        await _updateLastCheckTime();
      }

      final response = await (client ?? httpClient).get(
        'https://api.github.com/repos/$_githubRepo/releases/latest',
        headers: {'Accept': 'application/vnd.github+json'},
      );

      if (response.statusCode != 200) {
        throw StateError('Release check returned HTTP ${response.statusCode}');
      }
      final data = response.data;
      final rawTag = data['tag_name'] as String?;

      // Tags may be "v2.25.2", "2.25.2" or "PlezTV v2.25.2" — take the
      // first numeric x.y[.z] run. A tag with no version in it is not an
      // update, not a crash.
      final cleanVersion = rawTag == null ? null : _extractVersion(rawTag);
      if (cleanVersion == null) {
        appLogger.w('Release check: tag "$rawTag" carries no version number');
        return null;
      }

      final hasUpdate = _isNewerVersion(cleanVersion, currentVersion);

      if (hasUpdate) {
        // Check if this version was skipped
        final skippedVersion = await getSkippedVersion();
        if (skippedVersion == cleanVersion) {
          return null;
        }

        return {
          'hasUpdate': true,
          'currentVersion': currentVersion,
          'latestVersion': cleanVersion,
          'releaseUrl': data['html_url'] as String? ?? releasesUrl,
          'releaseName': data['name'] as String? ?? 'Version $cleanVersion',
          'releaseNotes': data['body'] as String? ?? '',
          'publishedAt': data['published_at'] as String? ?? '',
          // The .apk asset is how Android installs over the top. GitHub
          // stores a spaced asset name with dots (PlenTV.v2.25.2.apk), so
          // match on the .apk suffix, never an exact filename. A release
          // with no .apk asset (e.g. v2.25.1 shipped source-only) still
          // reports the update — the dialog says plainly there is no APK
          // attached yet instead of offering a dead download. A split-only
          // release with no asset for this device likewise offers no
          // download (1.2.21) — the dialog says plainly there is no build
          // for this device.
          ...selectApkAsset(data['assets'], deviceAbi: deviceAbi),
        };
      }
    } catch (error, stackTrace) {
      appLogger.e('Failed to check for updates', error: error, stackTrace: stackTrace);
      if (throwOnFailure) rethrow;
    }

    return null;
  }

  @visibleForTesting
  static Future<Map<String, dynamic>?> debugPerformUpdateCheck({
    required bool respectCooldown,
    required MediaServerHttpClient client,
    bool throwOnFailure = false,
    Abi? deviceAbi,
  }) {
    return _performUpdateCheck(
      respectCooldown: respectCooldown,
      client: client,
      forceEnabled: true,
      throwOnFailure: throwOnFailure,
      deviceAbi: deviceAbi,
    );
  }

  /// Test-only override for the manual check, so widget tests can drive the
  /// up-to-date and update-available paths without the network. Same pattern
  /// as [debugPerformUpdateCheck] below and the *ForTesting seams elsewhere
  /// in the codebase. Never set in production code.
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function()? debugCheckForUpdatesOverride;

  /// Check for updates on GitHub (manual check, ignores cooldown)
  /// Returns a map with update info, or null when there is no update (or the
  /// release is skipped). Throws when the check itself fails, so the caller
  /// can say so instead of reporting the latest version.
  static Future<Map<String, dynamic>?> checkForUpdates() {
    final override = debugCheckForUpdatesOverride;
    if (override != null) return override();
    return _performUpdateCheck(respectCooldown: false, throwOnFailure: true);
  }

  /// First version token inside a release tag, or null when the tag
  /// carries no version ("v2.25.2", "2.25.2", "PlezTV v2.25.2" all yield
  /// "2.25.2"; "nightly-build" yields null). Build #18: the token keeps
  /// the upstream suffix of PlenTV's own scheme ("v1.0.0-2.25.0" yields
  /// "1.0.0-2.25.0", not "1.0.0") — dropping it made 1.0.0 read older
  /// than 2.25.13, so the updater would never offer the new scheme.
  static String? _extractVersion(String tag) {
    final match = RegExp(r'\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z.+-]+)?').firstMatch(tag);
    return match?.group(0);
  }

  /// The device ABI as it appears in a split-per-ABI asset name
  /// (1.2.19, L-9): `arm64-v8a` on a 64-bit ARM device (Fold),
  /// `armeabi-v7a` on a 32-bit ARM device (Hisense), `x86_64`/`x86`
  /// on Intel devices. Any other ABI returns '' — no per-ABI asset can
  /// be matched, so a split-only release offers no download (1.2.21)
  /// and a single-asset release still offers its one asset.
  @visibleForTesting
  static String deviceAbiName([Abi? abi]) {
    final current = abi ?? Abi.current();
    if (current == Abi.androidArm64) return 'arm64-v8a';
    if (current == Abi.androidArm) return 'armeabi-v7a';
    if (current == Abi.androidX64) return 'x86_64';
    if (current == Abi.androidIA32) return 'x86';
    return '';
  }

  /// The release's .apk asset, matched on the `.apk` suffix only (GitHub
  /// rewrites spaces to dots in stored asset names). Returns
  /// `{'apkAssetUrl': ..., 'apkAssetName': ..., 'apkAssetSize': ...,
  /// 'apkAssetAbi': ..., 'apkAssetNoMatch': ...}` — the URL, name and
  /// size are null when the release carries no .apk asset, or when it
  /// carries split APKs and none of them fits this device.
  /// The size (bytes, from the GitHub API) is what the in-app downloader
  /// verifies the finished file against before offering Install (build
  /// #10) — a truncated download must never reach the installer.
  ///
  /// 1.2.19, L-9: when the release carries split-per-ABI assets (the
  /// parent's `--split-per-abi` workflow ships 2–3), the asset whose
  /// name contains the device ABI wins — an arm64 Fold must not
  /// download the 32-bit Hisense APK and vice versa. [deviceAbi] is the
  /// test seam: production passes nothing and [Abi.current()] is used.
  ///
  /// 1.2.21: the 1.2.19 rules had two holes. The ABI match was a
  /// substring ('x86' matched the x86_64 asset, offering a 64-bit Intel
  /// APK to a 32-bit Intel device) — the match is delimited now, so the
  /// token must be its own segment. And a split-only release with no
  /// asset for this device fell back to the first asset — a ~100 MB
  /// download the installer refuses (INSTALL_FAILED_NO_MATCHING_ABIS).
  /// The rules are count-first now: 0 .apk assets → no download
  /// (`apkAssetNoMatch: false`, the release simply has no APK); exactly
  /// 1 → offer it (the fat asset, `apkAssetAbi: null`); 2+ (split) →
  /// the ABI match wins, else no download is offered at all
  /// (`apkAssetNoMatch: true` — the dialog says so plainly instead).
  /// A fat asset shipped ALONGSIDE splits is still offered when no
  /// split matches (a tokenless asset cannot be a per-ABI build).
  @visibleForTesting
  static Map<String, Object?> selectApkAsset(Object? assets, {Abi? deviceAbi}) {
    final apkAssets = <Map>[];
    if (assets is List) {
      for (final asset in assets) {
        if (asset is! Map) continue;
        final assetName = asset['name'] as String?;
        if (assetName == null || !assetName.toLowerCase().endsWith('.apk')) continue;
        apkAssets.add(asset);
      }
    }
    if (apkAssets.isEmpty) {
      return {
        'apkAssetUrl': null,
        'apkAssetName': null,
        'apkAssetSize': null,
        'apkAssetAbi': null,
        'apkAssetNoMatch': false,
      };
    }
    if (apkAssets.length == 1) {
      final picked = apkAssets.first;
      return {
        'apkAssetUrl': picked['browser_download_url'] as String?,
        'apkAssetName': picked['name'] as String?,
        'apkAssetSize': picked['size'] as int?,
        'apkAssetAbi': null,
        'apkAssetNoMatch': false,
      };
    }
    final abiName = deviceAbiName(deviceAbi);
    final matched = abiName.isNotEmpty
        ? apkAssets.firstWhereOrNull((a) => _assetMatchesAbi((a['name'] as String?) ?? '', abiName))
        : null;
    if (matched != null) {
      return {
        'apkAssetUrl': matched['browser_download_url'] as String?,
        'apkAssetName': matched['name'] as String?,
        'apkAssetSize': matched['size'] as int?,
        'apkAssetAbi': abiName,
        'apkAssetNoMatch': false,
      };
    }
    final fat = apkAssets.firstWhereOrNull((a) => _isTokenlessApk((a['name'] as String?) ?? ''));
    if (fat != null) {
      return {
        'apkAssetUrl': fat['browser_download_url'] as String?,
        'apkAssetName': fat['name'] as String?,
        'apkAssetSize': fat['size'] as int?,
        'apkAssetAbi': null,
        'apkAssetNoMatch': false,
      };
    }
    return {
      'apkAssetUrl': null,
      'apkAssetName': null,
      'apkAssetSize': null,
      'apkAssetAbi': null,
      'apkAssetNoMatch': true,
    };
  }

  /// A delimited ABI match: the token must appear as its own segment
  /// (after a '-' or '.' and before '.apk'), so 'x86' never matches
  /// the x86_64 asset and 'arm64-v8a' never matches a longer name.
  /// Case-insensitive — GitHub asset names are lower-case in practice,
  /// but the check must not depend on that.
  static bool _assetMatchesAbi(String assetName, String abiName) {
    return RegExp('(?:^|[-.])${RegExp.escape(abiName)}\\.apk\$', caseSensitive: false).hasMatch(assetName);
  }

  /// A fat asset carries no per-ABI token as its own segment.
  static bool _isTokenlessApk(String assetName) {
    const abiTokens = ['arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86'];
    return !abiTokens.any((token) => _assetMatchesAbi(assetName, token));
  }

  /// Check for updates on startup (respects cooldown and skipped versions)
  /// Returns update info if available, null otherwise
  static Future<Map<String, dynamic>?> checkForUpdatesOnStartup() {
    return _performUpdateCheck(respectCooldown: true);
  }

  /// Parse version string into list of integers
  /// Handles versions like "1.2.3+4" by taking only the numeric parts
  static List<int> _parseVersionParts(String version) {
    return version.split('.').map((p) {
      final numPart = p.split('+').first.split('-').first;
      return int.tryParse(numPart) ?? 0;
    }).toList();
  }

  /// A parsed release version: the core number plus, for PlenTV's own
  /// scheme (build #18), the upstream Plezy version after the dash
  /// ("1.0.0-2.25.0" → core [1, 0, 0], upstream [2, 25, 0]). A bare
  /// version ("2.25.13") has no upstream. A suffix that is not a version
  /// ("2.25.2-rc1") is ignored for comparison — a pre-release tag is not
  /// newer than the release with the same core.
  static ({List<int> core, List<int>? upstream}) _parseVersion(String version) {
    final dash = version.indexOf('-');
    final corePart = dash < 0 ? version : version.substring(0, dash);
    List<int>? upstream;
    if (dash >= 0) {
      final suffixParts = version.substring(dash + 1).split('.').map(int.tryParse).toList();
      if (suffixParts.every((p) => p != null)) {
        upstream = suffixParts.cast<int>();
      }
    }
    return (core: _parseVersionParts(corePart), upstream: upstream);
  }

  /// Numeric comparison of two version part lists: -1, 0 or 1.
  static int _compareVersionParts(List<int> a, List<int> b) {
    final maxLength = a.length > b.length ? a.length : b.length;
    for (int i = 0; i < maxLength; i++) {
      final aPart = i < a.length ? a[i] : 0;
      final bPart = i < b.length ? b[i] : 0;
      if (aPart > bPart) return 1;
      if (aPart < bPart) return -1;
    }
    return 0;
  }

  /// Compare two version strings
  /// Returns true if newVersion is newer than currentVersion
  ///
  /// Build #18: PlenTV moved to its own numbering (1.0.0-2.25.0) after
  /// the last bare Plezy-numbered release (2.25.13). A PlenTV-scheme
  /// version is therefore always newer than a bare one — without this
  /// rule 1.0.0 compares older than 2.25.13 and the updater never offers
  /// it. Among PlenTV-scheme versions the core compares first, then the
  /// upstream suffix (so a 2.25.1 rebase reads newer than 2.25.0).
  static bool _isNewerVersion(String newVersion, String currentVersion) {
    try {
      final next = _parseVersion(newVersion);
      final current = _parseVersion(currentVersion);
      if (next.upstream != null && current.upstream == null) return true;
      if (next.upstream == null && current.upstream != null) return false;
      final core = _compareVersionParts(next.core, current.core);
      if (core != 0) return core > 0;
      if (next.upstream != null && current.upstream != null) {
        return _compareVersionParts(next.upstream!, current.upstream!) > 0;
      }
      return false;
    } catch (error, stackTrace) {
      appLogger.e('Error comparing versions', error: error, stackTrace: stackTrace);
      return false;
    }
  }
}
