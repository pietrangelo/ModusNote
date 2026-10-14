import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/l10n/generated/app_localizations_it.dart';
import 'package:modusnote/notes/attachments/attachments_input.dart';
import 'package:modusnote/notes/credentials/expiry_status.dart';
import 'package:modusnote/notes/credentials/password_generator_sheet.dart';
import 'package:modusnote/notes/credentials/secret_clipboard.dart';
import 'package:modusnote/notes/dynamic_form_renderer.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'harness.dart';

FieldKey k(String key) => FieldKey(key);

void main() {
  final schema = SeedSchemas.credentialV1;
  late List<FormDraft> drafts;
  late List<Uri> opened;
  String? clipboard;

  setUp(() {
    drafts = [];
    opened = [];
    clipboard = null;
  });

  Future<void> render(
    WidgetTester tester, {
    Map<FieldKey, FieldValue> values = const {},
  }) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            clipboard = (call.arguments as Map)['text'] as String?;
          case 'Clipboard.getData':
            return {'text': clipboard};
        }
        return null;
      },
    );
    await pumpApp(
      tester,
      Scaffold(
        body: SingleChildScrollView(
          child: DynamicFormRenderer(
            schema: schema,
            values: values,
            onChanged: drafts.add,
            attachments: AttachmentHooks(
              openImage: (_) => throw UnimplementedError(),
              openLink: (uri) async {
                opened.add(uri);
                return true;
              },
            ),
          ),
        ),
      ),
    );
  }

  EditableText editable(WidgetTester tester, String key) =>
      tester.widget<EditableText>(textInput(key));

  testWidgets('every field shows at once, nothing folded away', (tester) async {
    await render(
      tester,
      values: {
        k('description'): const TextValue('Banca'),
        k('username'): const TextValue('mario'),
      },
    );
    for (final field in schema.fields) {
      expect(fieldFinder(field.key.value), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('details-toggle')), findsNothing);
    expect(find.text('Nome utente'), findsOneWidget);
    expect(find.text('Scadenza password'), findsOneWidget);
  });

  testWidgets('the password is masked until asked, and reported as secret', (
    tester,
  ) async {
    await render(
      tester,
      values: {k('password'): const SecretValue('zebra-Quokka-42')},
    );
    expect(editable(tester, 'password').obscureText, isTrue);
    expect(editable(tester, 'password').enableSuggestions, isFalse);
    expect(editable(tester, 'password').autocorrect, isFalse);

    await tester.tap(find.byKey(const ValueKey('password-visibility')));
    await tester.pump();
    expect(editable(tester, 'password').obscureText, isFalse);

    await tester.enterText(textInput('password'), 'nuova');
    expect(drafts.last.values[k('password')], const SecretValue('nuova'));
  });

  testWidgets('copying keeps it masked and clears the clipboard after', (
    tester,
  ) async {
    await render(
      tester,
      values: {k('password'): const SecretValue('zebra-Quokka-42')},
    );
    await tester.tap(find.byKey(const ValueKey('password-copy')));
    await tester.pump();
    expect(clipboard, 'zebra-Quokka-42');
    expect(editable(tester, 'password').obscureText, isTrue);
    expect(find.textContaining('30 secondi'), findsOneWidget);

    await tester.runAsync(SecretClipboard.flush);
    expect(clipboard, '');
  });

  testWidgets('the clipboard is left alone if something else was copied', (
    tester,
  ) async {
    await render(
      tester,
      values: {k('password'): const SecretValue('zebra-Quokka-42')},
    );
    await tester.tap(find.byKey(const ValueKey('password-copy')));
    await tester.pump();
    clipboard = 'altro';
    await tester.runAsync(SecretClipboard.flush);
    expect(clipboard, 'altro');
  });

  testWidgets('the generator fills the field, without excluded symbols', (
    tester,
  ) async {
    await render(tester);
    await tester.tap(find.byKey(const ValueKey('password-generate')));
    await tester.pumpAndSettle();
    expect(find.byType(PasswordGeneratorSheet), findsOneWidget);

    for (final symbol in ['"', "'", r'\']) {
      await tester.ensureVisible(find.byKey(ValueKey('exclude-$symbol')));
      await tester.tap(find.byKey(ValueKey('exclude-$symbol')));
      await tester.pump();
    }
    final shown = tester
        .widget<SelectableText>(
          find.byKey(const ValueKey('generated-password')),
        )
        .data!;
    expect(shown, hasLength(PasswordRecipe.defaultLength));
    expect(shown, isNot(matches(RegExp(r'''["'\\]'''))));

    await tester.ensureVisible(find.text('Usa questa password'));
    await tester.tap(find.text('Usa questa password'));
    await tester.pumpAndSettle();
    expect(drafts.last.values[k('password')], SecretValue(shown));
    expect(editable(tester, 'password').controller.text, shown);
    expect(editable(tester, 'password').obscureText, isTrue);
  });

  testWidgets('a link without a scheme is kept as https, and opens on yes', (
    tester,
  ) async {
    await render(tester);
    await tester.enterText(textInput('link'), 'banca.example/accesso');
    expect(
      drafts.last.values[k('link')],
      const TextValue('https://banca.example/accesso'),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('url-open')));
    await tester.pumpAndSettle();
    expect(find.text('https://banca.example/accesso'), findsWidgets);
    await tester.tap(find.text('Apri'));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse('https://banca.example/accesso')]);
  });

  testWidgets('adversary: a javascript: link is kept as typed and refused', (
    tester,
  ) async {
    await render(tester);
    await tester.enterText(textInput('link'), 'javascript:alert(1)');
    final value = drafts.last.values[k('link')]!;
    expect(value, const TextValue('javascript:alert(1)'));
    expect(schema.fieldFor(k('link'))!.type.check(value), [
      ViolationCode.invalidUrl,
    ]);
    await tester.pump();
    final open = tester.widget<IconButton>(
      find.byKey(const ValueKey('url-open')),
    );
    expect(open.onPressed, isNull);
  });

  group('expiry on the card', () {
    final l10n = AppLocalizationsIt();
    final now = DateTime(2026, 10, 14, 15);

    DynamicEntry credential(DateValue? expiry) => switch (DynamicEntry.create(
      schema: schema,
      id: EntryId('a' * 32),
      attributes: {
        k('description'): const TextValue('Posta'),
        k('password_expiry'): ?expiry,
      },
      at: DateTime.utc(2026),
    )) {
      Valid(:final value) => value,
      Invalid() => throw StateError('fixture'),
    };

    String? status(DateValue? expiry) =>
        ExpiryStatus.of(credential(expiry), l10n, now: now);

    test('silent until a week before', () {
      expect(status(null), isNull);
      expect(status(DateValue(2026, 10, 22)), isNull);
    });

    test('then how long is left, then expired', () {
      expect(status(DateValue(2026, 10, 21)), 'La password scade tra 7 giorni');
      expect(status(DateValue(2026, 10, 15)), 'La password scade domani');
      expect(status(DateValue(2026, 10, 14)), 'La password scade oggi');
      expect(status(DateValue(2026, 10, 13)), 'Password scaduta');
    });
  });
}
