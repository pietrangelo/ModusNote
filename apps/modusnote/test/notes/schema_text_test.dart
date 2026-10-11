import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/l10n/generated/app_localizations.dart';
import 'package:modusnote/notes/schema_text.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

void main() {
  final italian = SchemaText(lookupAppLocalizations(const Locale('it')));
  final english = SchemaText(lookupAppLocalizations(const Locale('en')));

  test('every seed schema, field and option has a translation', () {
    for (final text in [italian, english]) {
      for (final schema in SeedSchemas.all) {
        expect(text.lookup(schema.label), isNotNull, reason: '${schema.id}');
        for (final field in schema.fields) {
          expect(text.lookup(field.label), isNotNull, reason: '${field.key}');
          if (field.type case ChoiceFieldType(:final options)) {
            for (final option in options) {
              expect(
                text.lookupOption(field, option),
                isNotNull,
                reason: '${field.key}.$option',
              );
            }
          }
        }
      }
    }
  });

  test('labels and options read naturally in each language', () {
    final song = SeedSchemas.songSketchV1;
    final key = song.fieldFor(FieldKey('key'))!;
    final priority = SeedSchemas.taskV1.fieldFor(FieldKey('priority'))!;

    expect(italian.label(song.label), 'Canzone');
    expect(english.label(song.label), 'Song');
    expect(italian.option(key, 'f_sharp_minor'), 'Fa♯ minore');
    expect(english.option(key, 'b_flat_major'), 'B♭ major');
    expect(italian.option(priority, 'urgent'), 'Urgente');
  });

  test('a label typed by the user is shown exactly as typed', () {
    expect(
      italian.label(Label.literal('Ricette di nonna')),
      'Ricette di nonna',
    );
  });

  test('every violation has a message', () {
    for (final code in ViolationCode.values) {
      expect(italian.violation(code), isNotEmpty);
      expect(english.violation(code), isNotEmpty);
    }
    expect(italian.violation(ViolationCode.missingRequired), 'Obbligatorio');
  });

  group('adversary', () {
    test('a key from a newer app version falls back to readable text', () {
      final unknown = Label.localized('schema.recipe.field.cooking_time');

      expect(italian.lookup(unknown), isNull);
      expect(italian.label(unknown), 'cooking time');
    });

    test('an option with no translation is shown by its identifier', () {
      final field = FieldDefinition(
        key: FieldKey('mood'),
        label: Label.literal('Umore'),
        type: ChoiceFieldType(['very_happy']),
      );

      expect(italian.option(field, 'very_happy'), 'very happy');
    });
  });
}
