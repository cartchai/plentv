import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/media_server_client.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/settings_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_section.dart';

/// Settings → Live TV (build #15, item 1): one switch per live-TV server.
/// Turning a server off hides its channels from the guide, search, What's
/// On and the mini-player — the server's libraries are untouched. On by
/// default; hiding the last live-TV server hides the Live TV tab itself.
///
/// 1.6.26: the "Default tab" choice underneath — which tab Live TV opens
/// on the first open per app session (Guide, Favourites, What's On,
/// Recordings). It subsumes the old "Default to Favorite Channels"
/// toggle in Settings → Appearance, which is gone; a one-time migration
/// in LiveTvScreen carries the old choice over.
class LiveTvSettingsScreen extends StatelessWidget {
  const LiveTvSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return FocusedScrollScaffold(
      title: Text(t.liveTv.title),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          sliver: SliverToBoxAdapter(
            child: Text(t.liveTv.settingsHint, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(
            child: Consumer<MultiServerProvider>(
              builder: (context, multiServer, _) {
                final serverIds = multiServer.liveTvServerIds;
                // Which tabs the Default tab choice can offer — the same
                // visibility rule as LiveTvScreen._tabStateFor (Guide
                // always; What's On only with a Plex server; Recordings
                // only with a DVR). On an IPTV-only phone this is just
                // Guide + Favourites.
                var hasPlexServer = false;
                var hasDvr = false;
                for (final id in serverIds) {
                  final serverId = ServerId(id);
                  if (multiServer.getPlexClientForServer(serverId) != null) hasPlexServer = true;
                  if (multiServer.getClientForServer(serverId)?.liveTvDvr != null) hasDvr = true;
                }
                final defaultTabTile = SettingSegmentedTile<String>(
                  pref: SettingsService.liveTvDefaultTab,
                  icon: Symbols.live_tv_rounded,
                  title: t.settings.liveTvDefaultTab,
                  segments: [
                    ButtonSegment(value: 'guide', label: Text(t.liveTv.guide)),
                    ButtonSegment(value: 'favorites', label: Text(t.liveTv.favorites)),
                    if (hasPlexServer) ButtonSegment(value: 'whatsOn', label: Text(t.liveTv.whatsOn)),
                    if (hasDvr) ButtonSegment(value: 'recordings', label: Text(t.liveTv.recordings)),
                  ],
                );
                if (serverIds.isEmpty) {
                  return SettingsGroup(
                    title: t.liveTv.title,
                    children: [
                      ListTile(
                        leading: const AppIcon(Symbols.live_tv_rounded, fill: 1),
                        title: Text(t.liveTv.settingsEmpty),
                        subtitle: Text(t.liveTv.settingsEmptyHint),
                      ),
                      defaultTabTile,
                    ],
                  );
                }
                return SettingsGroup(
                  title: t.liveTv.title,
                  children: [
                    for (final serverId in serverIds)
                      FocusableSwitchListTile(
                        secondary: const AppIcon(Symbols.live_tv_rounded, fill: 1),
                        title: Text(t.liveTv.fromServer(server: multiServer.liveTvServerName(serverId))),
                        value: !multiServer.isLiveTvServerHidden(serverId),
                        onChanged: (value) => multiServer.setLiveTvServerHidden(serverId, !value),
                      ),
                    defaultTabTile,
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
