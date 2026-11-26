import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:uuid/uuid.dart';

import '../../connection/connection.dart';
import '../../exceptions/media_server_exceptions.dart';
import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../mixins/controller_disposer_mixin.dart';
import '../../profiles/profile.dart';
import '../../services/iptv/iptv_refusal_log.dart';
import '../../services/iptv/warp_tunnel_service.dart';
import '../../services/iptv/xtream_api.dart';
import '../../services/iptv/xtream_transport.dart';
import '../../services/settings_service.dart';
import '../../utils/app_logger.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import 'async_form_state_mixin.dart';
import 'iptv_connection_persistence.dart';

/// Add an Xtream Codes account as a connection: the user gives it a NAME
/// (which becomes the library title) plus the server URL, username, and
/// password. The credentials are verified with a `player_api.php` auth
/// probe before anything is persisted; the connection is then stored via
/// [persistAndBindConnection] and bound to the target (or active) profile.
///
/// The password is never logged and never appears in any error message:
/// Xtream errors can embed the request URI, which carries the credentials
/// in the query string, so all failures map to fixed user-facing strings.
class AddXtreamScreen extends StatefulWidget {
  /// When set, the new connection is bound to this profile. When null,
  /// falls back to the currently active profile (typical for the global
  /// Connections screen entry point).
  final Profile? targetProfile;

  const AddXtreamScreen({super.key, this.targetProfile});

  @override
  State<AddXtreamScreen> createState() => _AddXtreamScreenState();
}

class _AddXtreamScreenState extends State<AddXtreamScreen> with AsyncFormStateMixin, ControllerDisposerMixin {
  late final _nameController = createTextEditingController();
  late final _urlController = createTextEditingController();
  late final _usernameController = createTextEditingController();
  late final _passwordController = createTextEditingController();
  final _nameFocus = FocusNode(debugLabel: 'AddXtream:Name');
  final _urlFocus = FocusNode(debugLabel: 'AddXtream:Url');
  final _usernameFocus = FocusNode(debugLabel: 'AddXtream:Username');
  final _passwordFocus = FocusNode(debugLabel: 'AddXtream:Password');
  final _signInFocus = FocusNode(debugLabel: 'AddXtream:SignIn');
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _nameFocus.dispose();
    _urlFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _signInFocus.dispose();
    super.dispose();
  }

  /// The configured Xtream User-Agent for the sign-in probe (build #20).
  /// Falls back to VLC when Settings is not initialized yet.
  static String _configuredUserAgent() {
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return XtreamUserAgent.vlc;
    return XtreamUserAgent.resolve(
      settings.read(SettingsService.iptvXtreamUserAgent),
      settings.read(SettingsService.iptvXtreamUserAgentCustom),
    );
  }

  /// Auth probe: `player_api.php` with no action. A `user_info` object
  /// means the login works; null means the server rejected it.
  ///
  /// The probe sends the configured Xtream User-Agent (build #20): a panel
  /// that 403s the bare Dart UA would fail sign-in here even though the
  /// app itself would work, so the probe must present the same signature
  /// the app will use.
  ///
  /// 1.6.27: the probe rides the same tunnel-aware transport client as
  /// post-login traffic ([XtreamTransportClient]), so sign-in goes
  /// through the tunnel when it is on instead of always going direct
  /// (the TV login could never use the VPN that works on the phone).
  /// When the tunnel is off the transport's proxy function returns
  /// DIRECT, so the probe behaves exactly as before.
  Future<bool> _probe(String serverUrl, String username, String password, String name) async {
    final api = XtreamApi(
      serverUrl: serverUrl,
      username: username,
      password: password,
      userAgent: _configuredUserAgent(),
      httpClient: XtreamTransportClient(
        superSpoofOn: _superSpoofOn,
        preferIpv4On: _preferIpv4On,
        transportChoice: _superSpoofTransport,
        tunnelOn: _tunnelOn,
      ),
      // Build #27: a sign-in refusal is a refusal too — the 06:02 event
      // WAS a failed sign-in. Recorded with the typed name (no connection
      // exists yet) so it shows in Settings → IPTV → Connection refusals.
      onRefusal: (entry) => IptvRefusalLog.instance.record(entry),
      connectionName: name,
    );
    try {
      final info = await api.getUserInfo();
      _logProbeOutcome(serverUrl, info != null ? 'ok' : 'rejected');
      return info != null;
    } catch (e) {
      _logProbeOutcome(serverUrl, _probeFailureOutcome(e));
      rethrow;
    } finally {
      api.close();
    }
  }

  /// Log the probe's path (DIRECT vs PROXY) and outcome (1.6.27), so a
  /// future debug log captures a login failure instead of a silent
  /// startup window. Host only — never the full URL or credentials: the
  /// password travels in the request's query string, so it must never
  /// reach a log line. The path is the same verdict function the
  /// transport's Dart clients evaluate, so it matches what the request
  /// did (Cronet is forced to Dart while the tunnel is on, so it can
  /// never ride the proxy; Platform reads the same proxy from the
  /// Kotlin singleton at open time).
  void _logProbeOutcome(String serverUrl, String outcome) {
    final uri = Uri.tryParse(serverUrl);
    final path = uri == null ? 'DIRECT' : WarpTunnelService.instance.proxyForProvider(uri);
    appLogger.i(
      'Xtream sign-in probe',
      error: {'host': uri?.host ?? '', 'path': path, 'outcome': outcome},
    );
  }

  /// The outcome string for a probe that threw: the exception type, plus
  /// the status code when the panel answered one (a 403 is the diagnostic
  /// the next TV log needs to show).
  String _probeFailureOutcome(Object e) {
    final status = switch (e) {
      MediaServerAuthException(:final statusCode) => statusCode,
      MediaServerHttpException(:final statusCode) => statusCode,
      _ => null,
    };
    return status == null ? 'failed: ${e.runtimeType}' : 'failed: ${e.runtimeType} $status';
  }

  /// The Super Spoof master toggle is on — mirrors `IptvClient`'s
  /// transport readers, so the probe presents the same signature the app
  /// will use. False when Settings is not initialized.
  static bool _superSpoofOn() {
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return false;
    return settings.read(SettingsService.iptvSuperSpoof);
  }

  /// The Super Spoof transport sub-setting — which network stack the
  /// Xtream requests ride while the master is on. The stored choice
  /// itself (default 'cronet'); the transport applies the master gate
  /// and the Prefer IPv4 win per request.
  static String _superSpoofTransport() {
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return SettingsService.iptvSuperSpoofTransport.defaultValue;
    return settings.read(SettingsService.iptvSuperSpoofTransport);
  }

  /// The IPv4-preference is on. False when Settings is not initialized.
  static bool _preferIpv4On() {
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return false;
    return settings.read(SettingsService.iptvPreferIpv4);
  }

  /// The WARP tunnel is up. The transport reads it per request, so the
  /// probe rides the local proxy while it is on and goes direct when it
  /// is off.
  static bool _tunnelOn() => WarpTunnelService.instance.isOn;

  /// 1.6.28 (G1): when the tunnel toggle is on, wait for the tunnel to
  /// finish starting/restoring before the sign-in probe fires, bounded
  /// to 5 s in total (same bound as the health gate in
  /// `IptvClient.checkHealth`). Returns true when the probe may fire:
  /// the tunnel is on, or the toggle is off (direct, as today).
  /// Returns false when the toggle is on but the tunnel is still
  /// starting after the bound — the caller must NOT probe direct in
  /// that case. Never throws.
  /// 1.6.30 (P0.3/F2): delegated to the shared
  /// [WarpTunnelService.waitForTunnelReady] — the local restore +
  /// state-settled waits lived here before and are now the one
  /// shared implementation.
  Future<bool> _waitForTunnelReady() =>
      WarpTunnelService.instance.waitForTunnelReady();

  Future<void> _signIn() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final name = _nameController.text.trim();
    final serverUrl = _urlController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    await runAsync<void>(
      () async {
        // 1.6.28 (G1): never send the sign-in probe direct while the
        // tunnel is still starting — on home WiFi it 403s and records
        // a refusal. If the tunnel is still starting after the
        // bounded wait, fail with a clear message instead.
        if (!await _waitForTunnelReady()) {
          if (!mounted) return;
          setErrorText(t.addServer.tunnelStillStarting);
          return;
        }
        final authed = await _probe(serverUrl, username, password, name);
        if (!mounted) return;
        if (!authed) {
          setErrorText(t.addServer.invalidCredentials);
          return;
        }
        final connection = XtreamConnection(
          id: const Uuid().v4(),
          name: name,
          serverUrl: serverUrl,
          username: username,
          password: password,
          createdAt: DateTime.now(),
        );
        final ok = await persistAndExitIptvConnection(
          context: context,
          connection: connection,
          targetProfile: widget.targetProfile,
          userIdentifier: username,
        );
        if (!ok && mounted) setErrorText(t.messages.noProfilesAvailable);
      },
      errorMapper: (e) {
        // Fixed strings only: Xtream errors may embed the request URI,
        // which carries the username and password in the query string.
        if (e is MediaServerAuthException) return t.addServer.invalidCredentials;
        appLogger.e('Add Xtream failed', error: e.runtimeType);
        return t.addServer.xtreamProbeFailed;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text(t.addServer.addXtreamTitle),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: .stretch,
                children: [
                  FocusableTextFormField(
                    controller: _nameController,
                    focusNode: _nameFocus,
                    autofocus: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !busy,
                    textInputAction: TextInputAction.next,
                    onFieldSubmitted: busy ? null : (_) => _urlFocus.requestFocus(),
                    decoration: InputDecoration(
                      labelText: t.addServer.libraryName,
                      helperText: t.addServer.libraryNameHelper,
                      prefixIcon: const AppIcon(Symbols.label_rounded, fill: 1),
                    ),
                    validator: (v) => v == null || v.trim().isEmpty ? t.addServer.required : null,
                  ),
                  const SizedBox(height: 12),
                  FocusableTextFormField(
                    controller: _urlController,
                    focusNode: _urlFocus,
                    tvTextInputPresentation: TvTextInputPresentation.platform,
                    keyboardType: TextInputType.url,
                    minLines: 1,
                    maxLines: 4,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !busy,
                    textInputAction: TextInputAction.next,
                    onFieldSubmitted: busy ? null : (_) => _usernameFocus.requestFocus(),
                    decoration: InputDecoration(
                      labelText: t.addServer.serverUrl,
                      prefixIcon: const AppIcon(Symbols.link_rounded, fill: 1),
                    ),
                    validator: (v) => v == null || v.trim().isEmpty ? t.addServer.required : null,
                  ),
                  const SizedBox(height: 12),
                  FocusableTextFormField(
                    controller: _usernameController,
                    focusNode: _usernameFocus,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !busy,
                    textInputAction: TextInputAction.next,
                    onFieldSubmitted: busy ? null : (_) => _passwordFocus.requestFocus(),
                    decoration: InputDecoration(
                      labelText: t.addServer.username,
                      prefixIcon: const AppIcon(Symbols.person_rounded, fill: 1),
                    ),
                    validator: (v) => v == null || v.trim().isEmpty ? t.addServer.required : null,
                  ),
                  const SizedBox(height: 12),
                  FocusableTextFormField(
                    controller: _passwordController,
                    focusNode: _passwordFocus,
                    obscureText: true,
                    enabled: !busy,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: busy ? null : (_) => _signIn(),
                    decoration: InputDecoration(
                      labelText: t.addServer.password,
                      prefixIcon: const AppIcon(Symbols.lock_rounded, fill: 1),
                    ),
                    validator: (v) => v == null || v.isEmpty ? t.addServer.required : null,
                  ),
                  const SizedBox(height: 16),
                  FocusableButton(
                    focusNode: _signInFocus,
                    useBackgroundFocus: true,
                    onPressed: busy ? null : _signIn,
                    child: FilledButton.icon(
                      onPressed: busy ? null : _signIn,
                      icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.login_rounded, fill: 1),
                      label: Text(t.addServer.signIn),
                    ),
                  ),
                  ...buildInlineError(theme),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
