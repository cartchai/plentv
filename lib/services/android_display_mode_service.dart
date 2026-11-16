import '../utils/app_logger.dart';
import '../utils/device_channel.dart';

/// Android native display-mode controls (1.2.19 L-18/L-27), over the
/// existing device channel (`com.plezy/device`).
///
/// The methods deliberately do their own failure handling by try/catch
/// rather than by `Platform.isAndroid`: in a `flutter test` run the host
/// platform is not Android, and the channel call must still be observable
/// through a mock handler. Callers gate on TV where the feature is TV-only
/// (the settings tiles are TV-only; main.dart applies the UI mode on TV
/// only). On a device without the native handler the invoke throws
/// MissingPluginException and the call is a logged no-op.
class AndroidDisplayModeService {
  /// L-27 trial: persist the RenderMode.surface opt-in natively. Takes
  /// effect on the next cold start; returns whether native stored it.
  static Future<bool> setSurfaceRenderMode(bool enabled) async {
    try {
      return await deviceChannel.invokeMethod<bool>('setSurfaceRenderMode', enabled) ?? false;
    } catch (e) {
      appLogger.w('Failed to persist surface render mode', error: e);
      return false;
    }
  }

  /// L-27 trial: the natively persisted surface-render-mode flag.
  static Future<bool> getSurfaceRenderMode() async {
    try {
      return await deviceChannel.invokeMethod<bool>('getSurfaceRenderMode') ?? false;
    } catch (e) {
      appLogger.w('Failed to read surface render mode', error: e);
      return false;
    }
  }

  /// L-18 trial: request (or leave) the 1080p UI mode. Fire-and-forget:
  /// native settles the switch on its display listener and Dart does not
  /// await the HDMI renegotiation. Returns whether native accepted the
  /// request (false on non-TV / missing handler); a panel with no 1080p
  /// mode is a silent native no-op.
  static Future<bool> setUi1080pMode(bool enabled) async {
    try {
      return await deviceChannel.invokeMethod<bool>('setUi1080pMode', enabled) ?? false;
    } catch (e) {
      appLogger.w('Failed to apply 1080p UI mode', error: e);
      return false;
    }
  }

  /// L-18 diagnostics: the display's current + supported modes, as the
  /// native manager describes them (for the Hisense spike + debug export).
  static Future<String?> describeDisplayModes() async {
    try {
      return await deviceChannel.invokeMethod<String>('getDisplayModes');
    } catch (e) {
      appLogger.w('Failed to read display modes', error: e);
      return null;
    }
  }
}
