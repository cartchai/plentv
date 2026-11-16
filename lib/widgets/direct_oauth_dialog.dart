import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../focus/focusable_button.dart';
import '../i18n/strings.g.dart';
import '../services/deep_links/deep_link_service.dart';
import '../services/trackers/direct_oauth_flow.dart';
import '../utils/snackbar_helper.dart';
import 'app_icon.dart';
import 'pending_auth_dialog.dart';

/// Sign-in dialog for direct OAuth flows (MAL, AniList — 1.3.23, FORK §66 U2).
///
/// The [PendingAuthDialog] shell contributes everything this flow needs —
/// QR code, readable copyable URL, browser launch button, and the waiting
/// spinner — so it works uniformly on phones (user taps the button),
/// desktops (same), and TVs without a browser (user scans the QR with a
/// phone). This dialog adds the code box: the provider redirects to
/// `plezy://oauth/<service>?code=...`, which the app catches and submits
/// automatically when it can — and when it cannot (TV, or a cold start),
/// the user pastes the code, or the whole redirect link, into the box.
class DirectOAuthDialog extends StatefulWidget {
  final DirectOAuthStart start;
  final String serviceName;
  final VoidCallback onCancel;

  const DirectOAuthDialog({super.key, required this.start, required this.serviceName, required this.onCancel});

  @override
  State<DirectOAuthDialog> createState() => _DirectOAuthDialogState();
}

class _DirectOAuthDialogState extends State<DirectOAuthDialog> {
  late final TextEditingController _codeController;
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    _codeController = TextEditingController();
    // Cold-start return: the app launched from the redirect while no
    // dialog was up; the service stashed it for the next connect.
    final pending = DeepLinkService.instance.takePendingOAuthReturn();
    if (pending != null) _handleReturn(pending);
    DeepLinkService.instance.onOAuthReturn = _handleReturn;
  }

  @override
  void dispose() {
    if (DeepLinkService.instance.onOAuthReturn == _handleReturn) {
      DeepLinkService.instance.onOAuthReturn = null;
    }
    _codeController.dispose();
    super.dispose();
  }

  void _handleReturn(Uri uri) {
    if (_submitted) return;
    if (widget.start.submitCode(uri.toString())) {
      setState(() => _submitted = true);
    }
  }

  void _submit() {
    if (_submitted) return;
    if (widget.start.submitCode(_codeController.text)) {
      setState(() => _submitted = true);
    } else if (mounted) {
      showAppSnackBar(context, t.services.directOAuth.invalidCode);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PendingAuthDialog(
      title: t.services.directOAuth.title(service: widget.serviceName),
      body: t.services.directOAuth.body,
      url: widget.start.url,
      openLabel: t.services.directOAuth.openToSignIn(service: widget.serviceName),
      onCancel: widget.onCancel,
      children: [
        TextField(
          controller: _codeController,
          enabled: !_submitted,
          decoration: InputDecoration(
            labelText: t.services.directOAuth.codeLabel(service: widget.serviceName),
            hintText: t.services.directOAuth.codeHint,
            border: const OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FocusableButton(
            onPressed: _submitted ? null : _submit,
            useBackgroundFocus: true,
            child: FilledButton.icon(
              icon: const AppIcon(Symbols.check_rounded),
              label: Text(t.services.directOAuth.submitLabel),
              onPressed: _submitted ? null : _submit,
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
