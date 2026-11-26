import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:provider/provider.dart';

import '../../connection/connection.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/iptv_client.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/iptv/iptv_refusal_log.dart';
import '../../utils/formatters.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';

/// "Connection refusals" (build #27): every time the provider refuses a
/// request — the status, the response headers and the first bit of the
/// response body — listed newest-first so the cause can be read off the
/// phone instead of guessed at. Copy shares the whole log as text; Clear
/// empties it. Test (1.6.13) sends ONE real probe with the current
/// settings to the newest entry's connection, even while the 403 breaker
/// is open, and shows whether the panel answered — so a settings change
/// can be tested from this screen instead of waiting out the hold. A
/// 403 from the probe lands as a new entry, with the User-Agent that
/// went out. No usernames or passwords are ever stored here (see
/// [IptvRefusalEntry]).
class IptvRefusalsScreen extends StatefulWidget {
  const IptvRefusalsScreen({super.key});

  @override
  State<IptvRefusalsScreen> createState() => _IptvRefusalsScreenState();
}

class _IptvRefusalsScreenState extends State<IptvRefusalsScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(IptvRefusalLog.instance.ensureLoaded());
  }

  bool _testing = false;

  /// Android binder transactions are capped around 1 MiB and
  /// `Clipboard.setData` crosses one (same cap as the logs screen).
  /// Trimming drops the oldest entries, keeping the newest.
  static const int _maxClipboardBytes = 256 * 1024;

  String _formatAll(List<IptvRefusalEntry> entries) {
    final buffer = StringBuffer();
    for (final entry in entries) {
      final text = entry.toShareText();
      if (buffer.isNotEmpty) buffer.write('\n\n');
      if (utf8.encode(buffer.toString()).length + utf8.encode(text).length > _maxClipboardBytes) break;
      buffer.write(text);
    }
    return buffer.toString();
  }

  void _copy(List<IptvRefusalEntry> entries) {
    if (entries.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _formatAll(entries)));
    showSuccessSnackBar(context, t.iptv.refusalsCopied);
  }

  Future<void> _clear() async {
    // 1.4.3 G3: clearing the log alone would leave the breaker's
    // in-memory flag (C3) holding the panel shut for the rest of its
    // cooldown — the log-derived half clears, the flag does not. A
    // deliberate Clear clears both, so the next fetch actually tries.
    // The connection ids are read before the clear wipes them.
    final connectionIds = IptvRefusalLog.instance.entriesNotifier.value
        .map((e) => e.connectionId)
        .where((id) => id.isNotEmpty)
        .toSet();
    await IptvRefusalLog.instance.clear();
    if (!mounted) return;
    // The provider is absent when the screen is pumped standalone
    // (tests) — a nullable read keeps the Clear working there, and
    // there is simply no breaker to clear without a client.
    final multiServer = context.read<MultiServerProvider?>();
    if (multiServer != null) {
      for (final id in connectionIds) {
        final client = multiServer.getClientForServer(ServerId(id));
        if (client is IptvClient) client.clear403Cooldown();
      }
    }
    showSuccessSnackBar(context, t.iptv.refusalsCleared);
  }

  /// 1.6.13: one user-initiated probe to the newest entry's connection,
  /// even while the 403 breaker is open — so a settings change (UA
  /// choice, Prefer IPv4) can be tested from this screen instead of
  /// waiting out the hold. Exactly one request; a 403 lands as a new
  /// refusal entry, so the next test is provable from this screen. Only
  /// an explicit tap runs this — nothing on this screen probes on its
  /// own.
  Future<void> _test() async {
    final entries = IptvRefusalLog.instance.entriesNotifier.value;
    if (entries.isEmpty || _testing) return;
    final connectionId = entries
        .map((e) => e.connectionId)
        .firstWhere((id) => id.isNotEmpty, orElse: () => '');
    // The provider is absent when the screen is pumped standalone
    // (tests) — without a client there is nothing to probe.
    final multiServer = context.read<MultiServerProvider?>();
    final client = connectionId.isEmpty || multiServer == null
        ? null
        : multiServer.getClientForServer(ServerId(connectionId));
    if (client is! IptvClient || client.connection is! XtreamConnection) {
      showErrorSnackBar(context, t.iptv.refusalsTestFailed);
      return;
    }
    setState(() => _testing = true);
    try {
      final result = await client.forceProbeAccess();
      if (!mounted) return;
      if (result.ok) {
        showSuccessSnackBar(context, t.iptv.refusalsTestOk);
      } else if (result.statusCode == 403) {
        showErrorSnackBar(context, t.iptv.refusalsTestRefused);
      } else {
        final message = result.message;
        showErrorSnackBar(
          context,
          message == null || message.isEmpty
              ? t.iptv.refusalsTestFailed
              : '${t.iptv.refusalsTestFailed}: $message',
        );
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }


  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<List<IptvRefusalEntry>>(
      valueListenable: IptvRefusalLog.instance.entriesNotifier,
      builder: (context, entries, _) {
        return FocusedScrollScaffold(
          title: Text(t.iptv.refusalsTitle),
          actions: [
            IconButton(
              icon: const AppIcon(Symbols.network_check_rounded),
              tooltip: t.iptv.refusalsTest,
              onPressed: entries.isEmpty || _testing ? null : _test,
            ),
            IconButton(
              icon: const AppIcon(Symbols.content_copy_rounded),
              tooltip: t.iptv.refusalsCopy,
              onPressed: entries.isEmpty ? null : () => _copy(entries),
            ),
            IconButton(
              icon: const AppIcon(Symbols.delete_rounded),
              tooltip: t.iptv.refusalsClear,
              onPressed: entries.isEmpty ? null : _clear,
            ),
          ],
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              sliver: SliverToBoxAdapter(
                child: Text(t.iptv.refusalsDescription, style: theme.textTheme.bodyMedium),
              ),
            ),
            if (entries.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverToBoxAdapter(
                  child: Text(t.iptv.refusalsEmpty, style: theme.textTheme.bodyMedium),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) => _RefusalTile(
                    entry: entries[index],
                    timeText: formatDateTimeWithClock(entries[index].timestamp.toLocal(), context),
                  ),
                ),
              ),
            const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
          ],
        );
      },
    );
  }
}

/// One refusal, collapsed to status + action + time, expandable to the
/// full record: headers, body snippet, User-Agent, network, connection.
class _RefusalTile extends StatelessWidget {
  const _RefusalTile({required this.entry, required this.timeText});

  final IptvRefusalEntry entry;
  final String timeText;

  String get _statusLabel => entry.statusCode == null ? entry.failureKind : 'HTTP ${entry.statusCode}';

  Widget _row(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SelectableText.rich(
        TextSpan(
          children: [
            TextSpan(text: '$label: ', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold)),
            TextSpan(text: value, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      leading: const AppIcon(Symbols.block_rounded, fill: 1),
      title: Text('$_statusLabel · ${entry.action}'),
      subtitle: Text(timeText),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row(theme, t.iptv.refusalsStatus, _statusLabel),
              _row(theme, t.iptv.refusalsTime, timeText),
              if (entry.connectionName.isNotEmpty)
                _row(theme, t.iptv.refusalsConnection, entry.connectionName),
              _row(theme, t.iptv.refusalsNetwork, entry.network),
              if (entry.userAgent.isNotEmpty) _row(theme, t.iptv.refusalsUserAgent, entry.userAgent),
              if (entry.headers.isNotEmpty) ...[
                _row(theme, t.iptv.refusalsHeaders, ''),
                SelectableText(
                  entry.headers.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
                  style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                ),
              ],
              if (entry.bodySnippet.isNotEmpty) ...[
                _row(theme, t.iptv.refusalsBody, ''),
                SelectableText(
                  entry.bodySnippet,
                  style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
