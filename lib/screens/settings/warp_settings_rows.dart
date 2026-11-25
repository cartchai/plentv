import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../i18n/strings.g.dart';
import '../../services/iptv/warp_tunnel_service.dart';
import '../../services/settings_mutation_service.dart';
import '../../services/settings_service.dart' as settings;
import '../../utils/dialogs.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';

/// Subtitle for the WARP transport row (1.6.21): the label of the
/// chosen tunnel transport.
String warpTransportSubtitle(String choice) => switch (choice) {
  'wireguard' => t.settings.warpTransportWireguard,
  'masque' => t.settings.warpTransportMasque,
  _ => t.settings.warpTransportMasque,
};

/// Subtitle for the MASQUE transport row (1.6.21): the label of
/// the chosen MASQUE transport.
String warpMasqueVhttpSubtitle(String choice) => switch (choice) {
  'h3' => t.settings.warpMasqueVhttpH3,
  'h2' => t.settings.warpMasqueVhttpH2,
  'auto' => t.settings.warpMasqueVhttpAuto,
  _ => t.settings.warpMasqueVhttpAuto,
};

/// The VPN (WARP) row (1.6.15): a switch bound to the opt-in pref
/// whose subtitle is the live tunnel state (off / starting / on /
/// failed), with the terms gate on turn-on. A plain SettingSwitchTile
/// cannot do this: it writes the pref first and reports after, but
/// the terms gate must run BEFORE the pref flips — declining leaves
/// the switch off, and registration never runs without an explicit
/// accept. Turning off writes the pref false and stops the tunnel.
///
/// 1.6.24: extracted from SettingsScreen so Advanced and the Super
/// Spoof page share the one implementation — the terms gate is
/// safety-sensitive and must not drift into two copies. The focus
/// node is optional: Advanced passes its tracked node, the sub-page
/// passes none (its tiles own their nodes, the 1.6.23 precedent).
class WarpVpnRow extends StatelessWidget {
  const WarpVpnRow({super.key, this.focusNode});

  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: WarpTunnelService.instance,
      builder: (context, _) {
        final service = WarpTunnelService.instance;
        final subtitle = switch (service.state) {
          WarpTunnelState.on => t.settings.warpVpnStateOn,
          WarpTunnelState.starting => t.settings.warpVpnStateStarting,
          WarpTunnelState.failed => t.settings.warpVpnStateFailed,
          WarpTunnelState.off => t.settings.warpVpnDescription,
        };
        return ValueListenableBuilder<bool>(
          valueListenable: settings.SettingsService.instance.listenable(
            settings.SettingsService.iptvWarpVpn,
          ),
          builder: (_, value, _) => FocusableSwitchListTile(
            focusNode: focusNode,
            secondary: const AppIcon(Symbols.vpn_key_rounded, fill: 1),
            title: Text(t.settings.warpVpn),
            subtitle: Text(subtitle),
            value: value,
            onChanged: (v) => _onWarpVpnChanged(context, v),
          ),
        );
      },
    );
  }
}

Future<void> _onWarpVpnChanged(BuildContext context, bool value) async {
  final service = WarpTunnelService.instance;
  if (!value) {
    final failure = await const SettingsMutationService().write(
      context,
      settings.SettingsService.iptvWarpVpn,
      false,
    );
    if (failure != null && context.mounted) {
      showErrorSnackBar(context, failure.display);
    }
    await service.stop();
    return;
  }
  // The terms gate runs BEFORE the pref flips: declining leaves the
  // switch off, and registration never runs without an explicit
  // accept. The acceptance is recorded first, then the pref, then
  // the tunnel starts (registration runs inside the start).
  if (!service.termsAccepted) {
    final accepted = await _showWarpTermsDialog(context);
    if (accepted != true) {
      // Declining is not an error — but the switch stays off, and the
      // user should hear why instead of wondering what happened.
      if (context.mounted) showSnackBar(context, t.settings.warpTermsRequired);
      return;
    }
    await service.acceptTerms();
    if (!context.mounted) return;
  }
  final failure = await const SettingsMutationService().write(
    context,
    settings.SettingsService.iptvWarpVpn,
    true,
  );
  if (failure != null) {
    if (context.mounted) showErrorSnackBar(context, failure.display);
    return;
  }
  await service.start();
}

/// The WARP terms dialog: the summary of what turning the VPN on
/// does, with links to Cloudflare's full terms and privacy policy.
/// Barrier-dismissible is off — the user must pick Accept or Not now,
/// so a tap outside cannot silently decline (or accept) for them.
Future<bool?> _showWarpTermsDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(t.settings.warpTermsTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.settings.warpTermsBody),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => launchUrl(
                Uri.parse('https://www.cloudflare.com/application/terms/'),
                mode: LaunchMode.externalApplication,
              ),
              child: Text(t.settings.warpTermsReadTerms),
            ),
            TextButton(
              onPressed: () => launchUrl(
                Uri.parse(
                  'https://www.cloudflare.com/application/privacypolicy/',
                ),
                mode: LaunchMode.externalApplication,
              ),
              child: Text(t.settings.warpTermsReadPrivacy),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t.settings.warpTermsDecline),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t.settings.warpTermsAccept),
        ),
      ],
    ),
  );
}

/// The Reset WARP registration action (1.6.19): signs the app up
/// for a fresh free WARP account, replacing the stored one. The
/// tunnel is stopped first (and the switch turned off), and the
/// fresh sign-up runs before anything is replaced — if it fails,
/// the current account stays put. A 429 is surfaced plainly as
/// "wait a minute and try again" instead of a generic failure.
///
/// 1.6.24: moved here from SettingsScreen so Advanced and the Super
/// Spoof page share the one implementation.
Future<void> showResetWarpRegistrationDialog(BuildContext context) async {
  final confirmed = await showConfirmDialog(
    context,
    title: t.settings.resetWarpRegistration,
    message: t.settings.resetWarpRegistrationDescription,
    confirmText: t.common.reset,
    isDestructive: true,
  );
  if (!context.mounted || !confirmed) return;
  final service = WarpTunnelService.instance;
  // The tunnel must be stopped first: a reset while it is on would
  // leave a running tunnel with no account behind it.
  if (service.isOn) {
    final failure = await const SettingsMutationService().write(
      context,
      settings.SettingsService.iptvWarpVpn,
      false,
    );
    if (failure != null && context.mounted) {
      showErrorSnackBar(context, failure.display);
    }
    await service.stop();
  }
  final result = await service.resetRegistration();
  if (!context.mounted) return;
  switch (result) {
    case WarpResetResult.replaced:
      showSuccessSnackBar(
        context,
        t.settings.resetWarpRegistrationSuccess,
      );
    case WarpResetResult.rateLimited:
      showErrorSnackBar(
        context,
        t.settings.resetWarpRegistrationRateLimited,
      );
    case WarpResetResult.failed:
      showErrorSnackBar(
        context,
        t.settings.resetWarpRegistrationFailed,
      );
  }
}
