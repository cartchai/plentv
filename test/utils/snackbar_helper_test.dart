import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/utils/snackbar_helper.dart';

void main() {
  testWidgets('showLoadingErrorSnackBar shows the shared error message for a plain error', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () => showLoadingErrorSnackBar(context, StateError('boom')),
                child: const Text('show'),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text(t.messages.errorLoading(error: t.errors.reasonUnexpected)), findsOneWidget);
  });

  testWidgets('showLoadingErrorSnackBar honours an explicit reason override', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () =>
                    showLoadingErrorSnackBar(context, null, reason: t.errors.reasonUnreachable),
                child: const Text('show'),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text(t.messages.errorLoading(error: t.errors.reasonUnreachable)), findsOneWidget);
  });
}
