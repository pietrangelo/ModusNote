import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers the dialog that asks for the passphrase again before an action
/// that gives lasting access to the vault. Pumps a second instead of
/// settling: a sync spinner behind the dialog never settles.
Future<void> confirmWith(WidgetTester tester, String phrase) async {
  await _work(tester);
  await tester.enterText(
    find.byKey(const ValueKey('confirm-passphrase')),
    phrase,
  );
  await tester.tap(find.byKey(const ValueKey('confirm-submit')));
  await _work(tester);
}

Future<void> _work(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
