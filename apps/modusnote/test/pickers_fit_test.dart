import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/theme/modus_theme.dart';

/// The pickers are Material's own, laid out in fixed boxes: the golden
/// type scale must still fit inside them on a phone.
void main() {
  Future<void> openOn(
    WidgetTester tester,
    Size size,
    Future<void> Function(BuildContext) open,
  ) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ModusTheme.dark(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => open(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  for (final (name, size) in [
    ('phone', const Size(412, 892)),
    ('small phone', const Size(360, 640)),
    ('phone in landscape', const Size(892, 412)),
  ]) {
    testWidgets('the date picker fits on a $name', (tester) async {
      await openOn(
        tester,
        size,
        (context) => showDatePicker(
          context: context,
          initialDate: DateTime(2026, 10, 11),
          firstDate: DateTime(1900),
          lastDate: DateTime(2100),
        ),
      );

      expect(find.byType(DatePickerDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the time picker fits on a $name', (tester) async {
      await openOn(
        tester,
        size,
        (context) => showTimePicker(
          context: context,
          initialTime: const TimeOfDay(hour: 18, minute: 12),
        ),
      );

      expect(find.byType(TimePickerDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
