import 'package:flutter/material.dart';
import '../media/ids.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../providers/multi_server_provider.dart';
import '../screens/settings/add_connection_screen.dart';
import '../screens/settings/iptv_refusals_screen.dart';
import '../focus/focusable_button.dart';
import 'app_icon.dart';

/// Top-of-app banner for servers that answered and refused this account.
/// Distinct from "server offline" — the server is reachable, so empty hubs
/// need an explanation.
///
/// Two refusals, two rows. A rejected token (HTTP 401,
/// [MultiServerProvider.authErrorServers]) gets a CTA that opens
/// [AddConnectionScreen]; the user picks the right backend and signs in
/// again. 1.6.35 (issue #11): the add screen now offers to UPDATE the
/// existing connection when the same host + username is already in the
/// registry, instead of minting a second row — updating reuses the stale
/// row's id with the new credentials, which clears the auth-error state
/// on the next health sweep. A refused account (HTTP 403,
/// [MultiServerProvider.accessDeniedServers]) gets a CTA that opens the
/// Connection refusals screen — a new sign-in gets the same refusal, so
/// there is no re-sign-in button; the refusals screen shows what the
/// panel actually said, and the hint says so in plain words.
///
/// Collapses to `SizedBox.shrink()` when no visible server refuses.
class AuthErrorBanner extends StatelessWidget {
  const AuthErrorBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final signInEntries = context.select<MultiServerProvider, List<({ServerId serverId, String displayName})>>(
      (p) => p.authErrorServers,
    );
    final deniedEntries = context.select<MultiServerProvider, List<({ServerId serverId, String displayName})>>(
      (p) => p.accessDeniedServers,
    );
    if (signInEntries.isEmpty && deniedEntries.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (signInEntries.isNotEmpty)
              _BannerRow(
                icon: Symbols.lock_rounded,
                label: signInEntries.length == 1
                    ? t.connections.sessionExpiredOne(name: signInEntries.first.displayName)
                    : t.connections.sessionExpiredMany(count: signInEntries.length),
                action: FocusableButton(
                  onPressed: () => _openReauth(context),
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.onErrorContainer,
                      foregroundColor: scheme.errorContainer,
                    ),
                    onPressed: () => _openReauth(context),
                    child: Text(t.connections.signInAgain),
                  ),
                ),
              ),
            if (deniedEntries.isNotEmpty)
              _BannerRow(
                icon: Symbols.block_rounded,
                label: deniedEntries.length == 1
                    ? t.connections.accessDeniedOne(name: deniedEntries.first.displayName)
                    : t.connections.accessDeniedMany(count: deniedEntries.length),
                // 1.4.3 G2: the 403 row used to be dead — no action, no
                // explanation. It now opens the refusals screen (where
                // the panel's actual answer is shown) and says in plain
                // words that the refusal is per-network.
                subtitle: t.connections.accessDeniedHint,
                action: FocusableButton(
                  onPressed: () => _openRefusals(context),
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.onErrorContainer,
                      foregroundColor: scheme.errorContainer,
                    ),
                    onPressed: () => _openRefusals(context),
                    child: Text(t.connections.accessDeniedViewRefusals),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openReauth(BuildContext context) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddConnectionScreen()));
  }

  Future<void> _openRefusals(BuildContext context) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const IptvRefusalsScreen()));
  }
}

class _BannerRow extends StatelessWidget {
  const _BannerRow({required this.icon, required this.label, this.subtitle, this.action});

  final IconData icon;
  final String label;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final action = this.action;
    final subtitle = this.subtitle;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, action == null ? 16 : 8, 8),
      child: Row(
        children: [
          AppIcon(icon, fill: 1, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onErrorContainer, fontWeight: .w500),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
                  ),
                ],
              ],
            ),
          ),
          if (action != null) ...[const SizedBox(width: 8), action],
        ],
      ),
    );
  }
}
