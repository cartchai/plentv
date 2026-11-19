import 'package:flutter/material.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/settings_section.dart';
import '../../i18n/strings.g.dart';
import '../../theme/mono_tokens.dart';
import 'licenses_screen.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static final Future<PackageInfo> _packageInfoFuture = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    final appName = t.app.title;

    return FutureBuilder<PackageInfo>(
      future: _packageInfoFuture,
      builder: (context, snapshot) {
        final appVersion = snapshot.data?.version ?? '';
        return FocusedScrollScaffold(
          title: Text(t.about.title),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  Center(
                    child: Column(
                      children: [
                        const SizedBox(height: 24),
                        Image.asset('assets/plezy.png', width: 80, height: 80),
                        const SizedBox(height: 16),
                        Text(appName, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: .bold)),
                        const SizedBox(height: 8),
                        Text(
                          t.about.versionLabel(version: appVersion),
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens(context).textMuted),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          t.about.appDescription,
                          style: Theme.of(context).textTheme.bodyLarge,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 40),

                  // What's new: static in-app changelog, newest first. Kept
                  // in code (not fetched) so About works fully offline.
                  SettingsGroup(
                    margin: EdgeInsets.zero,
                    title: t.about.changelogTitle,
                    children: [
                      _ChangelogEntry(version: '1.5.2-2.26.0', changes: t.about.changelog2326),
                      _ChangelogEntry(version: '1.5.1-2.26.0', changes: t.about.changelog2325),
                      _ChangelogEntry(version: '1.5.0-2.26.0', changes: t.about.changelog2323),
                      _ChangelogEntry(version: '1.4.61-2.25.0', changes: t.about.changelog2324),
                      _ChangelogEntry(version: '1.4.6-2.25.0', changes: t.about.changelog2322),
                      _ChangelogEntry(version: '1.4.5-2.25.0', changes: t.about.changelog2321),
                      _ChangelogEntry(version: '1.4.4-2.25.0', changes: t.about.changelog2320),
                      _ChangelogEntry(version: '1.4.3-2.25.0', changes: t.about.changelog2319),
                      _ChangelogEntry(version: '1.4.2-2.25.0', changes: t.about.changelog2318),
                      _ChangelogEntry(version: '1.4.0-2.25.0', changes: t.about.changelog2317),
                      _ChangelogEntry(version: '1.3.30-2.25.0', changes: t.about.changelog2316),
                      _ChangelogEntry(version: '1.3.29-2.25.0', changes: t.about.changelog2315),
                      _ChangelogEntry(version: '1.3.28-2.25.0', changes: t.about.changelog2314),
                      _ChangelogEntry(version: '1.3.27-2.25.0', changes: t.about.changelog2313),
                      _ChangelogEntry(version: '1.3.26-2.25.0', changes: t.about.changelog2312),
                      _ChangelogEntry(version: '1.3.25-2.25.0', changes: t.about.changelog2311),
                      _ChangelogEntry(version: '1.3.24-2.25.0', changes: t.about.changelog2310),
                      _ChangelogEntry(version: '1.3.23-2.25.0', changes: t.about.changelog2309),
                      _ChangelogEntry(version: '1.2.22-2.25.0', changes: t.about.changelog2308),
                      _ChangelogEntry(version: '1.2.21-2.25.0', changes: t.about.changelog2307),
                      // 1.2.21: the 1.2.20 entry was never listed — the
                      // changelog2306 strings shipped in 1.2.20 but About
                      // still started at 1.2.19. Restored here.
                      _ChangelogEntry(version: '1.2.20-2.25.0', changes: t.about.changelog2306),
                      _ChangelogEntry(version: '1.2.19-2.25.0', changes: t.about.changelog2305),
                      _ChangelogEntry(version: '1.2.18-2.25.0', changes: t.about.changelog2304),
                      _ChangelogEntry(version: '1.2.17-2.25.0', changes: t.about.changelog2303),
                      _ChangelogEntry(version: '1.2.16-2.25.0', changes: t.about.changelog2302),
                      _ChangelogEntry(version: '1.2.15-2.25.0', changes: t.about.changelog2301),
                      _ChangelogEntry(version: '1.2.14-2.25.0', changes: t.about.changelog2300),
                      _ChangelogEntry(version: '1.2.13-2.25.0', changes: t.about.changelog2299),
                      _ChangelogEntry(version: '1.2.12-2.25.0', changes: t.about.changelog2298),
                      _ChangelogEntry(version: '1.2.11-2.25.0', changes: t.about.changelog2297),
                      _ChangelogEntry(version: '1.2.10-2.25.0', changes: t.about.changelog2296),
                      _ChangelogEntry(version: '1.2.9-2.25.0', changes: t.about.changelog2295),
                      _ChangelogEntry(version: '1.2.8-2.25.0', changes: t.about.changelog2294),
                      _ChangelogEntry(version: '1.2.7-2.25.0', changes: t.about.changelog2293),
                      _ChangelogEntry(version: '1.2.6-2.25.0', changes: t.about.changelog2292),
                      _ChangelogEntry(version: '1.2.5-2.25.0', changes: t.about.changelog2291),
                      _ChangelogEntry(version: '1.2.4-2.25.0', changes: t.about.changelog2290),
                      _ChangelogEntry(version: '1.2.3-2.25.0', changes: t.about.changelog2289),
                      _ChangelogEntry(version: '1.2.2-2.25.0', changes: t.about.changelog2288),
                      _ChangelogEntry(version: '1.2.1-2.25.0', changes: t.about.changelog2287),
                      _ChangelogEntry(version: '1.2.0-2.25.0', changes: t.about.changelog2286),
                      _ChangelogEntry(version: '1.1.2-2.25.0', changes: t.about.changelog2285),
                      _ChangelogEntry(version: '1.1.1-2.25.0', changes: t.about.changelog2284),
                      _ChangelogEntry(version: '1.1.0-2.25.0', changes: t.about.changelog2283),
                      _ChangelogEntry(version: '1.0.18-2.25.0', changes: t.about.changelog2282),
                      _ChangelogEntry(version: '1.0.17-2.25.0', changes: t.about.changelog2281),
                      _ChangelogEntry(version: '1.0.16-2.25.0', changes: t.about.changelog2280),
                      _ChangelogEntry(version: '1.0.14-2.25.0', changes: t.about.changelog2278),
                      _ChangelogEntry(version: '1.0.13-2.25.0', changes: t.about.changelog2277),
                      _ChangelogEntry(version: '1.0.12-2.25.0', changes: t.about.changelog2276),
                      _ChangelogEntry(version: '1.0.11-2.25.0', changes: t.about.changelog2275),
                      _ChangelogEntry(version: '1.0.10-2.25.0', changes: t.about.changelog2274),
                      _ChangelogEntry(version: '1.0.9-2.25.0', changes: t.about.changelog2273),
                      _ChangelogEntry(version: '1.0.8-2.25.0', changes: t.about.changelog2272),
                      _ChangelogEntry(version: '1.0.7-2.25.0', changes: t.about.changelog2271),
                      _ChangelogEntry(version: '1.0.6-2.25.0', changes: t.about.changelog2270),
                      _ChangelogEntry(version: '1.0.5-2.25.0', changes: t.about.changelog2269),
                      _ChangelogEntry(version: '1.0.4-2.25.0', changes: t.about.changelog2268),
                      _ChangelogEntry(version: '1.0.3-2.25.0', changes: t.about.changelog2267),
                      _ChangelogEntry(version: '1.0.2-2.25.0', changes: t.about.changelog2265),
                      _ChangelogEntry(version: '1.0.1-2.25.0 (build 173)', changes: t.about.changelog2266),
                      _ChangelogEntry(version: '1.0.0-2.25.0 (build 171)', changes: t.about.changelog2264),
                      _ChangelogEntry(version: '2.25.13', changes: t.about.changelog2263),
                      _ChangelogEntry(version: '2.25.12', changes: t.about.changelog2262),
                      _ChangelogEntry(version: '2.25.11', changes: t.about.changelog2261),
                      _ChangelogEntry(version: '2.25.10', changes: t.about.changelog2260),
                      _ChangelogEntry(version: '2.25.9', changes: t.about.changelog2259),
                      _ChangelogEntry(version: '2.25.8', changes: t.about.changelog2258),
                      _ChangelogEntry(version: '2.25.7', changes: t.about.changelog2257),
                      _ChangelogEntry(version: '2.25.6', changes: t.about.changelog2256),
                      _ChangelogEntry(version: '2.25.5', changes: t.about.changelog2255),
                      _ChangelogEntry(version: '2.25.4', changes: t.about.changelog2254),
                      _ChangelogEntry(version: '2.25.3', changes: t.about.changelog2253),
                      _ChangelogEntry(version: '2.25.2', changes: t.about.changelog2252),
                      _ChangelogEntry(version: '2.25.1', changes: t.about.changelog2251),
                      _ChangelogEntry(version: '2.25.0', changes: t.about.changelog2250),
                    ],
                  ),

                  const SizedBox(height: 24),

                  SettingsGroup(
                    margin: EdgeInsets.zero,
                    children: [
                      FocusableListTile(
                        leading: const AppIcon(Symbols.description_rounded, fill: 1),
                        title: Text(t.about.openSourceLicenses),
                        subtitle: Text(t.about.viewLicensesDescription),
                        trailing: const AppIcon(Symbols.chevron_right_rounded, fill: 1),
                        onTap: () {
                          Navigator.push(context, MaterialPageRoute(builder: (context) => const LicensesScreen()));
                        },
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),
                ]),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One version's entry in the About changelog: a version heading followed
/// by a plain-words bullet list of what changed in that release.
class _ChangelogEntry extends StatelessWidget {
  final String version;
  final List<String> changes;

  const _ChangelogEntry({required this.version, required this.changes});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.about.versionLabel(version: version),
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          for (final change in changes)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('•  ', style: theme.textTheme.bodyMedium),
                  Expanded(child: Text(change, style: theme.textTheme.bodyMedium)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
