import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:uuid/uuid.dart';

import '../../connection/connection.dart';
import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../mixins/controller_disposer_mixin.dart';
import '../../profiles/profile.dart';
import '../../services/iptv/http_file_download.dart';
import '../../services/iptv/m3u_parser.dart';
import '../../services/iptv/warp_tunnel_service.dart';
import '../../utils/app_logger.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import 'async_form_state_mixin.dart';
import 'iptv_connection_persistence.dart';

/// Probe failure carrying a fixed user-facing message. Raw probe errors
/// are never surfaced: they may embed the request URI.
class _ProbeFailure implements Exception {
  final String message;
  const _ProbeFailure(this.message);
}

/// Add an M3U playlist as a connection: the user gives it a NAME (which
/// becomes the library title) and a playlist URL, plus an optional XMLTV
/// guide URL. The playlist is fetched and parsed as a probe before
/// anything is persisted; the connection is then stored via
/// [persistAndBindConnection] and bound to the target (or active) profile.
class AddM3uScreen extends StatefulWidget {
  /// When set, the new connection is bound to this profile. When null,
  /// falls back to the currently active profile (typical for the global
  /// Connections screen entry point).
  final Profile? targetProfile;

  const AddM3uScreen({super.key, this.targetProfile});

  @override
  State<AddM3uScreen> createState() => _AddM3uScreenState();
}

class _AddM3uScreenState extends State<AddM3uScreen> with AsyncFormStateMixin, ControllerDisposerMixin {
  late final _nameController = createTextEditingController();
  late final _urlController = createTextEditingController();
  late final _epgController = createTextEditingController();
  final _nameFocus = FocusNode(debugLabel: 'AddM3u:Name');
  final _urlFocus = FocusNode(debugLabel: 'AddM3u:Url');
  final _epgFocus = FocusNode(debugLabel: 'AddM3u:Epg');
  final _addFocus = FocusNode(debugLabel: 'AddM3u:Add');
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _nameFocus.dispose();
    _urlFocus.dispose();
    _epgFocus.dispose();
    _addFocus.dispose();
    super.dispose();
  }

  /// Fetch the playlist URL and require at least one parseable entry.
  /// The playlist streams straight to a temp file and is parsed from
  /// that file inside an isolate (1.5.3 N1) — the old probe held the
  /// whole playlist as a String and parsed it on the main isolate.
  Future<List<M3uEntry>> _probePlaylist(String playlistUrl) async {
    final uri = Uri.tryParse(playlistUrl);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw const _ProbeFailure('invalid-url');
    }
    // 1.6.30 (P0.2/F1): while the tunnel toggle is on but the tunnel
    // is still starting, do NOT probe — the fetch would go direct and
    // a 403 would surface as a generic "unreachable" failure verdict.
    // Inconclusive instead: the user is asked to wait and retry, and
    // no failure verdict is recorded. Bounded to 5 s by the shared
    // gate, same bound as the Xtream sign-in probe.
    if (!await WarpTunnelService.instance.waitForTunnelReady()) {
      throw const _ProbeFailure('tunnel-starting');
    }
    // 1.6.28 (G3): the playlist probe rides the tunnel when it is on,
    // like the runtime M3U feed fetch does — a bare client would go
    // direct while the user believes everything is tunneled.
    final client = WarpTunnelService.instance.proxiedHttpClient();
    final tempDir = await Directory.systemTemp.createTemp('plezy_m3u_probe_');
    final tempPath = '${tempDir.path}/playlist.m3u';
    try {
      try {
        await downloadHttpResponseToFile(client, uri, tempPath);
      } catch (_) {
        throw const _ProbeFailure('unreachable');
      }
      final entries = await compute(parseM3uFile, tempPath);
      if (entries.isEmpty) throw const _ProbeFailure('empty');
      return entries;
    } finally {
      client.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // Best-effort temp cleanup; a leftover probe file is inert.
      }
    }
  }

  Future<void> _add() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final name = _nameController.text.trim();
    final playlistUrl = _urlController.text.trim();
    final epgUrl = _epgController.text.trim();
    await runAsync<void>(
      () async {
        await _probePlaylist(playlistUrl);
        if (!mounted) return;
        final candidate = M3uConnection(
          id: const Uuid().v4(),
          name: name,
          playlistUrl: playlistUrl,
          epgUrl: epgUrl.isEmpty ? null : epgUrl,
          createdAt: DateTime.now(),
        );
        // 1.6.35 (issue #11): same as the Xtream screen — a playlist URL
        // already in the registry offers to update instead of adding a
        // second row for the same playlist.
        final connection = await resolveDuplicateIptvConnection(context: context, candidate: candidate);
        if (!mounted || connection == null) return;
        final ok = await persistAndExitIptvConnection(
          context: context,
          connection: connection,
          targetProfile: widget.targetProfile,
          // M3U has no server-side user id.
          userIdentifier: '',
        );
        if (!ok && mounted) setErrorText(t.messages.noProfilesAvailable);
      },
      errorMapper: (e) {
        if (e is _ProbeFailure) {
          return switch (e.message) {
            'invalid-url' => t.addServer.m3uInvalidUrl,
            'empty' => t.addServer.m3uPlaylistEmpty,
            // 1.6.30 (P0.2/F1): the tunnel was still starting — ask the
            // user to wait, never a failure verdict.
            'tunnel-starting' => t.addServer.tunnelStillStarting,
            _ => t.addServer.m3uProbeFailed,
          };
        }
        appLogger.e('Add M3U failed', error: e);
        return t.addServer.m3uProbeFailed;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text(t.addServer.addM3uTitle),
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
                    onFieldSubmitted: busy ? null : (_) => _epgFocus.requestFocus(),
                    decoration: InputDecoration(
                      labelText: t.addServer.playlistUrl,
                      prefixIcon: const AppIcon(Symbols.link_rounded, fill: 1),
                    ),
                    validator: (v) => v == null || v.trim().isEmpty ? t.addServer.required : null,
                  ),
                  const SizedBox(height: 12),
                  FocusableTextFormField(
                    controller: _epgController,
                    focusNode: _epgFocus,
                    tvTextInputPresentation: TvTextInputPresentation.platform,
                    keyboardType: TextInputType.url,
                    minLines: 1,
                    maxLines: 4,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !busy,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: busy ? null : (_) => _add(),
                    decoration: InputDecoration(
                      labelText: t.addServer.epgUrl,
                      prefixIcon: const AppIcon(Symbols.link_rounded, fill: 1),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FocusableButton(
                    focusNode: _addFocus,
                    useBackgroundFocus: true,
                    onPressed: busy ? null : _add,
                    child: FilledButton.icon(
                      onPressed: busy ? null : _add,
                      icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.add_rounded, fill: 1),
                      label: Text(t.addServer.addIptv),
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
