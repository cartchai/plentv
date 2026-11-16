import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/services/deep_links/deep_link_service.dart';
import 'package:plezy/services/trackers/direct_oauth_flow.dart';
import 'package:plezy/services/trackers/tracker_constants.dart';
import 'package:plezy/widgets/direct_oauth_dialog.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  DirectOAuthStart start() => DirectOAuthStart(
    service: TrackerService.mal,
    url: 'https://myanimelist.net/v1/oauth2/authorize?client_id=x&state=state-1',
    redirectUri: 'plezy://oauth/mal',
    state: 'state-1',
  );

  Widget dialog(DirectOAuthStart s) => MaterialApp(
    home: Scaffold(body: DirectOAuthDialog(start: s, serviceName: 'Example', onCancel: () {})),
  );

  testWidgets('copy control exposes the OAuth URL as its value', (tester) async {
    final semantics = tester.ensureSemantics();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final s = start();
    await tester.pumpWidget(dialog(s));

    final finder = find.bySemanticsLabel(t.services.pendingAuth.copyUrl);
    expect(finder, findsOneWidget);
    final data = tester.getSemantics(finder).getSemanticsData();
    expect(data.value, s.url);
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.flagsCollection.isEnabled, Tristate.isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(find.bySemanticsLabel(s.url), findsNothing);
    semantics.dispose();
  });

  testWidgets('always shows a QR code encoding the sign-in URL', (tester) async {
    final s = start();
    await tester.pumpWidget(dialog(s));

    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('myanimelist.net/v1/oauth2/authorize?client_id=x&state=state-1'), findsOneWidget);
  });

  testWidgets('code box submits a pasted code', (tester) async {
    final s = start();
    await tester.pumpWidget(dialog(s));

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text(t.services.directOAuth.codeLabel(service: 'Example')), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'PASTEDCODE123');
    await tester.tap(find.text(t.services.directOAuth.submitLabel));
    await tester.pump();

    expect(await s.codeFuture, 'PASTEDCODE123');
  });

  testWidgets('an invalid code is refused with a plain message', (tester) async {
    final s = start();
    await tester.pumpWidget(dialog(s));

    await tester.enterText(find.byType(TextField), '!!!');
    await tester.tap(find.text(t.services.directOAuth.submitLabel));
    await tester.pump();

    expect(find.text(t.services.directOAuth.invalidCode), findsOneWidget);
    expect(s.codeSubmitted, isFalse);
  });

  testWidgets('a deep-link return with matching state submits the code', (tester) async {
    final s = start();
    await tester.pumpWidget(dialog(s));

    DeepLinkService.instance.receive('plezy://oauth/mal?code=LINKCODE456&state=state-1');
    await tester.pump();

    expect(await s.codeFuture, 'LINKCODE456');
    // The stashed return is consumed, so a second connect does not replay it.
    expect(DeepLinkService.instance.takePendingOAuthReturn(), isNull);
  });

  testWidgets('a deep-link return with the wrong state is ignored', (tester) async {
    final s = start();
    await tester.pumpWidget(dialog(s));

    DeepLinkService.instance.receive('plezy://oauth/mal?code=LINKCODE456&state=someone-else');
    await tester.pump();

    expect(s.codeSubmitted, isFalse);
  });

  testWidgets('fits within a tvOS-sized 960x540 logical viewport without overflowing', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(960, 540);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(dialog(start()));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
