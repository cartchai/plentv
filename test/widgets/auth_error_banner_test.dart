import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/services/iptv/iptv_refusal_log.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/widgets/auth_error_banner.dart';
import 'package:provider/provider.dart';

import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';

void main() {
  late MultiServerManager manager;
  late MultiServerProvider provider;

  setUp(() {
    resetSharedPreferencesForTest();
    IptvRefusalLog.debugResetInstance();
    manager = MultiServerManager();
    provider = testMultiServerProvider(manager);
  });

  tearDown(() {
    IptvRefusalLog.debugResetInstance();
    provider.dispose();
    manager.dispose();
  });

  Future<void> pumpBanner(WidgetTester tester) => tester.pumpWidget(
    ChangeNotifierProvider<MultiServerProvider>.value(
      value: provider,
      child: InputModeTracker(child: const MaterialApp(home: Scaffold(body: AuthErrorBanner()))),
    ),
  );

  testWidgets('a server refusing the account (403) is explained without a sign-in that cannot help', (tester) async {
    manager.debugMarkAccessDeniedForTesting(ServerId('denied'));

    await pumpBanner(tester);

    expect(find.text(t.connections.accessDeniedOne(name: 'denied')), findsOneWidget);
    expect(find.text(t.connections.signInAgain), findsNothing);
    expect(find.textContaining(t.connections.sessionExpiredOne(name: 'denied')), findsNothing);
  });

  testWidgets('a rejected token keeps its sign-in prompt beside a refused account', (tester) async {
    manager.debugMarkAuthErrorForTesting(ServerId('expired'));
    manager.debugMarkAccessDeniedForTesting(ServerId('denied'));

    await pumpBanner(tester);

    expect(find.text(t.connections.sessionExpiredOne(name: 'expired')), findsOneWidget);
    expect(find.text(t.connections.accessDeniedOne(name: 'denied')), findsOneWidget);
    expect(find.text(t.connections.signInAgain), findsOneWidget);
  });

  testWidgets('the 403 row explains the refusal and opens the refusals screen (1.4.3 G2)', (tester) async {
    manager.debugMarkAccessDeniedForTesting(ServerId('denied'));

    await pumpBanner(tester);

    // The row used to be dead — no action, no explanation. It now
    // says in plain words that the refusal is per-network, and offers
    // the refusals screen (where the panel's actual answer is shown)
    // — but still no re-sign-in, which would get the same refusal.
    expect(find.text(t.connections.accessDeniedHint), findsOneWidget);
    expect(find.text(t.connections.accessDeniedViewRefusals), findsOneWidget);
    expect(find.text(t.connections.signInAgain), findsNothing);

    await tester.tap(find.text(t.connections.accessDeniedViewRefusals));
    await tester.pumpAndSettle();

    expect(find.text(t.iptv.refusalsTitle), findsOneWidget);
    expect(find.text(t.iptv.refusalsEmpty), findsOneWidget);
  });
}
