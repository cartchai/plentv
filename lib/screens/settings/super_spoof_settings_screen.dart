import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../services/iptv/xtream_api.dart';
import '../../services/iptv/xtream_transport.dart';
import '../../services/settings_service.dart' as settings;
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_section.dart';
import 'settings_utils.dart';
import 'warp_settings_rows.dart';

/// Super Spoof settings (Settings → Advanced → Super Spoof).
///
/// 1.6.23: the whole Super Spoof block moved here from the Advanced
/// section — master toggle on top, the four sub-settings underneath it
/// while it is on. Same prefs, same labels, same defaults, same
/// visibility rules; only the location changed. The readers of these
/// prefs (the request resolver, the background sync) never know the UI
/// moved.
///
/// 1.6.11 (Super Spoof): one master toggle that turns on ALL the
/// request-spoofing pieces at once, with the per-piece sub-settings
/// underneath it while it is on. The subs tune which pieces are active
/// and how they behave; the master still turns the whole thing on/off
/// at once.
/// 1.6.14 (unified spoof): the pieces are separate sub-settings — the
/// UA mimic (the same list as the base Xtream User-Agent choice, Custom
/// included, sharing the one custom text), the transport (Dart /
/// IPv4-only / Cronet / Platform (Android)), the headers piece and the
/// streams piece — so one piece can change without touching the others.
/// 1.6.24: a second group underneath holds the six Advanced rows
/// (MPEG-TS, Prefer IPv4, VPN (WARP), Tunnel transport, MASQUE
/// transport, Reset WARP registration) — duplicated here, not moved:
/// they stay in Advanced too, and both pages write the same prefs,
/// so a change in either place shows in the other. No focus nodes
/// on this page (the 1.6.23 precedent — sub-page tiles own theirs).
class SuperSpoofSettingsScreen extends StatelessWidget {
  const SuperSpoofSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return FocusedScrollScaffold(
      title: Text(t.settings.superSpoof),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingSwitchTile(
                  pref: settings.SettingsService.iptvSuperSpoof,
                  icon: Symbols.theater_comedy_rounded,
                  title: t.settings.superSpoof,
                  subtitle: t.settings.superSpoofDescription,
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: settings.SettingsService.instance.listenable(
                    settings.SettingsService.iptvSuperSpoof,
                  ),
                  builder: (_, spoofOn, _) {
                    if (!spoofOn) return const SizedBox.shrink();
                    return Column(
                      children: [
                        ValueListenableBuilder<String>(
                          // The UA row's subtitle shows the resolved value, so
                          // it must rebuild when the custom text changes too —
                          // not just when the choice changes (the selection
                          // tile only listens to the choice pref).
                          valueListenable: settings.SettingsService.instance.listenable(
                            settings.SettingsService.iptvXtreamUserAgentCustom,
                          ),
                          builder: (_, _, _) => Column(
                            children: [
                              SettingSelectionTile<String>(
                                pref: settings.SettingsService.iptvSuperSpoofUserAgent,
                                icon: Symbols.badge_rounded,
                                title: t.settings.superSpoofUserAgent,
                                subtitleBuilder: _superSpoofUserAgentSubtitle,
                                options: [
                                  DialogOption(
                                    value: XtreamSuperSpoof.userAgentOff,
                                    title: t.settings.superSpoofUserAgentOff,
                                  ),
                                  DialogOption(
                                    value: XtreamUserAgent.choicePlayer,
                                    title: t.iptv.xtreamUserAgentPlayer,
                                  ),
                                  DialogOption(
                                    value: XtreamUserAgent.choiceVlc,
                                    title: t.iptv.xtreamUserAgentVlc,
                                  ),
                                  DialogOption(
                                    value: XtreamUserAgent.choiceSmarters,
                                    title: t.iptv.xtreamUserAgentSmarters,
                                  ),
                                  DialogOption(
                                    value: XtreamUserAgent.choiceBrowser,
                                    title: t.iptv.xtreamUserAgentBrowser,
                                  ),
                                  DialogOption(
                                    value: XtreamSuperSpoof.userAgentCustom,
                                    title: t.iptv.xtreamUserAgentCustom,
                                  ),
                                ],
                              ),
                              ValueListenableBuilder<String>(
                                valueListenable: settings.SettingsService.instance.listenable(
                                  settings.SettingsService.iptvSuperSpoofUserAgent,
                                ),
                                builder: (_, choice, _) {
                                  if (choice != XtreamSuperSpoof.userAgentCustom) {
                                    return const SizedBox.shrink();
                                  }
                                  // The custom text is ONE shared pref with the
                                  // base Xtream User-Agent choice — typed once,
                                  // used by whichever list picks Custom.
                                  return SettingTextTile(
                                    pref: settings.SettingsService.iptvXtreamUserAgentCustom,
                                    icon: Symbols.edit_rounded,
                                    title: t.iptv.xtreamUserAgentCustomTitle,
                                    emptyHint: t.iptv.xtreamUserAgentCustomHint,
                                    emptyError: t.iptv.xtreamUserAgentCustomEmpty,
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        SettingSelectionTile<String>(
                          pref: settings.SettingsService.iptvSuperSpoofTransport,
                          icon: Symbols.swap_horiz_rounded,
                          title: t.settings.superSpoofTransport,
                          subtitleBuilder: _superSpoofTransportSubtitle,
                          options: [
                            DialogOption(
                              value: XtreamTransportChoice.dart,
                              title: t.settings.superSpoofTransportDart,
                            ),
                            DialogOption(
                              value: XtreamTransportChoice.ipv4,
                              title: t.settings.superSpoofTransportIpv4,
                            ),
                            DialogOption(
                              value: XtreamTransportChoice.cronet,
                              title: t.settings.superSpoofTransportCronet,
                            ),
                            DialogOption(
                              value: XtreamTransportChoice.platform,
                              title: t.settings.superSpoofTransportPlatform,
                            ),
                          ],
                        ),
                        SettingSwitchTile(
                          pref: settings.SettingsService.iptvSuperSpoofHeaders,
                          icon: Symbols.article_rounded,
                          title: t.settings.superSpoofHeaders,
                          subtitle: t.settings.superSpoofHeadersDescription,
                        ),
                        SettingSwitchTile(
                          pref: settings.SettingsService.iptvSuperSpoofStreams,
                          icon: Symbols.play_circle_rounded,
                          title: t.settings.superSpoofStreams,
                          subtitle: t.settings.superSpoofStreamsDescription,
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(top: 24)),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                // 1.6.24: the six Advanced rows, duplicated here in
                // Advanced order — same prefs, icons, titles,
                // subtitles and options as Advanced, no focus nodes.
                SettingSwitchTile(
                  pref: settings.SettingsService.iptvLiveTs,
                  icon: Symbols.live_tv_rounded,
                  title: t.settings.iptvLiveTs,
                  subtitle: t.settings.iptvLiveTsDescription,
                ),
                SettingSwitchTile(
                  pref: settings.SettingsService.iptvPreferIpv4,
                  icon: Symbols.lan_rounded,
                  title: t.settings.preferIpv4,
                  subtitle: t.settings.preferIpv4Description,
                ),
                const WarpVpnRow(),
                SettingSelectionTile<String>(
                  pref: settings.SettingsService.iptvWarpTransport,
                  icon: Symbols.swap_horiz_rounded,
                  title: t.settings.warpTransport,
                  subtitleBuilder: warpTransportSubtitle,
                  options: [
                    DialogOption(
                      value: 'masque',
                      title: t.settings.warpTransportMasque,
                    ),
                    DialogOption(
                      value: 'wireguard',
                      title: t.settings.warpTransportWireguard,
                    ),
                  ],
                ),
                SettingSelectionTile<String>(
                  pref: settings.SettingsService.iptvWarpMasqueVhttp,
                  icon: Symbols.lan_rounded,
                  title: t.settings.warpMasqueVhttp,
                  subtitleBuilder: warpMasqueVhttpSubtitle,
                  options: [
                    DialogOption(
                      value: 'auto',
                      title: t.settings.warpMasqueVhttpAuto,
                    ),
                    DialogOption(
                      value: 'h3',
                      title: t.settings.warpMasqueVhttpH3,
                    ),
                    DialogOption(
                      value: 'h2',
                      title: t.settings.warpMasqueVhttpH2,
                    ),
                  ],
                ),
                SettingNavigationTile(
                  icon: Symbols.restart_alt_rounded,
                  title: t.settings.resetWarpRegistration,
                  subtitle: t.settings.resetWarpRegistrationDescription,
                  onTap: () => showResetWarpRegistrationDialog(context),
                ),
              ],
            ),
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(top: 24)),
      ],
    );
  }
}

/// Subtitle for the Super Spoof User-Agent row: the name the mimic
/// sends, or the Off line when the piece leaves the normal choice
/// alone. Custom shows the shared custom text — or `Custom · <base>`
/// when the text is blank, which is the fallback the resolver
/// applies (the normal UA choice). Reads the custom pref
/// synchronously; the row rebuilds when the text changes (see the
/// group wrapper above).
String _superSpoofUserAgentSubtitle(String choice) {
  if (choice == XtreamSuperSpoof.userAgentOff) return t.settings.superSpoofUserAgentOff;
  final instance = settings.SettingsService.instance;
  final custom = instance.read(settings.SettingsService.iptvXtreamUserAgentCustom);
  final mimic = XtreamSuperSpoof.userAgentForChoice(choice, custom);
  if (mimic != null) return mimic;
  final fallback = XtreamUserAgent.resolve(
    instance.read(settings.SettingsService.iptvXtreamUserAgent),
    custom,
  );
  return '${t.iptv.xtreamUserAgentCustom} · $fallback';
}

/// Subtitle for the Super Spoof Transport row: the label of the
/// chosen network stack.
String _superSpoofTransportSubtitle(String choice) => switch (choice) {
  XtreamTransportChoice.dart => t.settings.superSpoofTransportDart,
  XtreamTransportChoice.ipv4 => t.settings.superSpoofTransportIpv4,
  XtreamTransportChoice.cronet => t.settings.superSpoofTransportCronet,
  XtreamTransportChoice.platform => t.settings.superSpoofTransportPlatform,
  _ => t.settings.superSpoofTransportDart,
};
