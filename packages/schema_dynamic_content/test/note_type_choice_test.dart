import 'dart:typed_data';

import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

void main() {
  final schemas = SeedSchemas.all;
  List<String> names(Iterable<SchemaDefinition> list) => [
    for (final schema in list) schema.id.name,
  ];

  group('NoteTypeChoice', () {
    test('offers every type until one is turned off', () {
      const choice = NoteTypeChoice();
      expect(names(choice.offered(schemas)), names(schemas));
      expect(choice.isOn('song_sketch'), isTrue);
    });

    test('a type turned off is no longer offered, in the same order', () {
      final choice = const NoteTypeChoice().turnedOff('song_sketch', schemas);
      expect(choice.isOn('song_sketch'), isFalse);
      expect(
        names(choice.offered(schemas)),
        names(schemas).where((name) => name != 'song_sketch'),
      );
      expect(choice.turnedOn('song_sketch'), const NoteTypeChoice());
    });

    test('never turns off the last type offered', () {
      var choice = const NoteTypeChoice();
      for (final schema in schemas.skip(1)) {
        choice = choice.turnedOff(schema.id.name, schemas);
      }
      final last = schemas.first.id.name;
      expect(choice.canTurnOff(last, schemas), isFalse);
      expect(choice.turnedOff(last, schemas), choice);
      expect(names(choice.offered(schemas)), [last]);
    });

    test('a stored choice that hides every type offers them all', () {
      // Written by another version of the app, or with other types.
      final choice = NoteTypeChoice.fromBytes(
        NoteTypeChoice.ofHidden(names(schemas)).toBytes(),
      );
      expect(names(choice.offered(schemas)), names(schemas));
    });

    test('names the app does not know count for nothing but are kept', () {
      final choice = NoteTypeChoice.ofHidden(const ['from_a_newer_app']);
      expect(names(choice.offered(schemas)), names(schemas));
      expect(NoteTypeChoice.fromBytes(choice.toBytes()), choice);
    });

    test('round-trips through its bytes', () {
      final choice = const NoteTypeChoice()
          .turnedOff('song_sketch', schemas)
          .turnedOff('journal', schemas);
      expect(NoteTypeChoice.fromBytes(choice.toBytes()), choice);
      expect(
        NoteTypeChoice.fromBytes(choice.toBytes()).offered(schemas),
        choice.offered(schemas),
      );
    });

    test('anything damaged or unknown is every type on', () {
      final good = NoteTypeChoice.ofHidden(const ['song_sketch']).toBytes();
      for (final bytes in [
        null,
        Uint8List(0),
        Uint8List.fromList([2, 0]),
        Uint8List.fromList([1]),
        Uint8List.fromList([1, 1]),
        Uint8List.fromList([1, 1, 3, 0x61, 0x62]),
        Uint8List.fromList([...good, 0]),
        Uint8List.fromList(good.sublist(0, good.length - 1)),
        // Not a schema name: upper case, a space, invalid UTF-8.
        Uint8List.fromList([1, 1, 1, 0x41]),
        Uint8List.fromList([1, 1, 2, 0x61, 0x20]),
        Uint8List.fromList([1, 1, 2, 0xc3, 0x28]),
        Uint8List.fromList([1, 1, 0]),
        // The same name twice.
        Uint8List.fromList([1, 2, 1, 0x61, 1, 0x61]),
      ]) {
        expect(NoteTypeChoice.fromBytes(bytes), const NoteTypeChoice());
      }
    });

    test('refuses more names than it would ever store', () {
      final many = [for (var i = 0; i < 65; i++) 't$i'];
      expect(
        () => NoteTypeChoice.ofHidden(many),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => NoteTypeChoice.ofHidden(const ['Not A Name']),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
