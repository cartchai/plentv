// Widget tests — 1.6.30 settings fix (NO-CONFIRM-2): removing a profile
// PIN is a security change, so it asks first.
//
// PinStatusRow owns the confirm: both of its parents (profile detail,
// add-local-profile) pass a bare removal callback, and the row must not
// run it until the user confirms.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/profile/pin_status_row.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  Future<void> pumpRow(WidgetTester tester, {required VoidCallback onRemove}) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: MaterialApp(
            home: Scaffold(
              body: PinStatusRow(onChange: () {}, onRemove: onRemove),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('Remove PIN asks first; cancelling keeps the PIN', (tester) async {
    var removed = false;
    await pumpRow(tester, onRemove: () => removed = true);

    await tester.tap(find.text(t.profiles.removePin));
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text(t.profiles.removePinTitle), findsOneWidget);
    expect(removed, isFalse);

    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text(t.common.cancel)),
    );
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);
    expect(removed, isFalse);
  });

  testWidgets('Remove PIN asks first; confirming removes the PIN', (tester) async {
    var removed = false;
    await pumpRow(tester, onRemove: () => removed = true);

    await tester.tap(find.text(t.profiles.removePin));
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text(t.profiles.removePinTitle), findsOneWidget);
    expect(removed, isFalse);

    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text(t.profiles.removePin)),
    );
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);
    expect(removed, isTrue);
  });
}
