import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:plezy/i18n/strings.g.dart';

class PipService {
  static const MethodChannel _channel = MethodChannel('com.plezy/pip');

  /// PiP is only implemented natively on Android, iOS, and macOS.
  static bool get _isAvailable => Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  /// The last native PiP feature-state answer (1.2.19, L-42): the
  /// `isSupported` channel call asks the OS whether the device
  /// actually has FEATURE_PICTURE_IN_PICTURE (and is not an Android
  /// TV) — the platform-only check in [PlatformDetector] cannot see
  /// that. Null until the first probe answers. Filled by [isSupported]
  /// and by the startup probe in [_internal].
  static bool? cachedSupported;

  /// Test-only override for [cachedSupported].
  @visibleForTesting
  static set debugCachedSupported(bool? value) => cachedSupported = value;

  static final PipService _instance = PipService._internal();
  factory PipService() => _instance;

  PipService._internal() {
    if (!_isAvailable) return;
    // Listen for callbacks from native Android
    _channel.setMethodCallHandler(_handleMethodCall);
    // 1.2.19 (L-42): probe the real feature state once at startup so
    // the PiP offer reflects the device, not just the platform.
    // Unawaited and best-effort — a missing channel leaves
    // [cachedSupported] null and the platform check stands.
    unawaited(isSupported());
  }

  /// ValueNotifier for PiP state - widgets can listen to this
  final ValueNotifier<bool> isPipActive = ValueNotifier<bool>(false);

  /// Callback invoked when native side is about to auto-enter PiP (API 26-30 path)
  static VoidCallback? onAutoPipEntering;

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onPipChanged':
        final isInPip = call.arguments as bool;
        isPipActive.value = isInPip;
        break;
      case 'onAutoPipEntering':
        onAutoPipEntering?.call();
        break;
    }
  }

  static Future<bool> isSupported() async {
    if (!_isAvailable) return false;
    try {
      final supported = await _channel.invokeMethod<bool>('isSupported') ?? false;
      // 1.2.19 (L-42): remember the answer for the platform check.
      cachedSupported = supported;
      return supported;
    } catch (_) {
      // No native side (tests, an older build): the last answer, if
      // any, stands; otherwise PiP is not offered from this call.
      return cachedSupported ?? false;
    }
  }

  /// Tell the native side whether auto-PiP is ready and the current video dimensions
  static Future<void> setAutoPipReady({required bool ready, int? width, int? height}) async {
    if (!_isAvailable) return;
    await _channel.invokeMethod('setAutoPipReady', {'ready': ready, 'width': width, 'height': height});
  }

  static Future<void> exit() async {
    if (!_isAvailable) return;
    await _channel.invokeMethod('exit');
  }

  static Future<(bool success, String? error)> enter({int? width, int? height}) async {
    if (!_isAvailable) return (false, null);
    final result = await _channel.invokeMethod<Map>('enter', {'width': width, 'height': height});
    if (result == null) {
      return (false, t.videoControls.pipErrors.unknown(error: t.common.unknown));
    }
    final success = result['success'] as bool? ?? false;
    final errorCode = result['errorCode'] as String?;
    final errorMessage = result['errorMessage'] as String?;
    final error = errorCode != null ? _getLocalizedError(errorCode, errorMessage) : null;
    return (success, error);
  }

  static String _getLocalizedError(String errorCode, String? errorMessage) {
    return switch (errorCode) {
      'android_version' => t.videoControls.pipErrors.androidVersion,
      'ios_version' => t.videoControls.pipErrors.iosVersion,
      'macos_version' => t.videoControls.pipErrors.notSupported,
      'permission_disabled' => t.videoControls.pipErrors.permissionDisabled,
      'not_supported' => t.videoControls.pipErrors.notSupported,
      'pip_prepare_failed' => t.videoControls.pipErrors.prepareFailed,
      'vo_switch_failed' => t.videoControls.pipErrors.voSwitchFailed,
      'failed' => t.videoControls.pipErrors.failed,
      _ => t.videoControls.pipErrors.unknown(error: errorMessage ?? t.common.unknown),
    };
  }
}
