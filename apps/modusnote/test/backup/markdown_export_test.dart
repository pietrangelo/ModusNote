import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/backup/markdown_export.dart';
import 'package:modusnote/backup/zip_writer.dart';
import 'package:modusnote/l10n/generated/app_localizations_it.dart';
import 'package:modusnote/notes/schema_text.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

DynamicEntry entry(
  String id,
  SchemaDefinition schema,
  Map<String, FieldValue> attributes,
) => switch (DynamicEntry.create(
  schema: schema,
  id: EntryId(id),
  attributes: {for (final e in attributes.entries) FieldKey(e.key): e.value},
  at: DateTime.utc(2026, 10, 11, 9),
)) {
  Valid(:final value) => value,
  Invalid(:final violations) => throw StateError('$violations'),
};

/// Reads back what [ZipWriter] wrote, checking every header and CRC.
Map<String, String> unzip(Uint8List zip) {
  final data = ByteData.sublistView(zip);
  final end = zip.length - 22;
  expect(data.getUint32(end, Endian.little), 0x06054b50);
  final count = data.getUint16(end + 10, Endian.little);
  var at = data.getUint32(end + 16, Endian.little);
  final files = <String, String>{};
  for (var i = 0; i < count; i++) {
    expect(data.getUint32(at, Endian.little), 0x02014b50);
    expect(data.getUint16(at + 8, Endian.little), 1 << 11, reason: 'UTF-8');
    final crc = data.getUint32(at + 16, Endian.little);
    final size = data.getUint32(at + 20, Endian.little);
    final nameLength = data.getUint16(at + 28, Endian.little);
    final local = data.getUint32(at + 42, Endian.little);
    final name = utf8.decode(zip.sublist(at + 46, at + 46 + nameLength));
    expect(data.getUint32(local, Endian.little), 0x04034b50);
    final start = local + 30 + data.getUint16(local + 26, Endian.little);
    final body = zip.sublist(start, start + size);
    expect(ZipWriter.crc32(body), crc, reason: name);
    files[name] = utf8.decode(body);
    at += 46 + nameLength;
  }
  return files;
}

void main() {
  final ideas = CategoryId('d' * 32);
  final songs = CategoryId('e' * 32);
  final tree = CategoryTree([
    NoteCategory(id: ideas, name: CategoryName('Idee')),
    NoteCategory(id: songs, name: CategoryName('Canzoni: 2026'), parent: ideas),
  ]);

  MarkdownExport export({Map<String, CategoryId> filed = const {}}) =>
      MarkdownExport(
        schemas: SeedSchemas.all,
        labels: SchemaText(AppLocalizationsIt()),
        words: (
          untitled: 'Senza titolo',
          recording: 'registrazione (non inclusa)',
          picture: 'immagine (non inclusa)',
          date: (d) => '${d.day}/${d.month}/${d.year}',
        ),
        categories: tree,
        categoryOf: (id) => filed[id.value],
      );

  test('CRC-32 of the standard check string', () {
    expect(ZipWriter.crc32(utf8.encode('123456789')), 0xCBF43926);
  });

  test('a note becomes a Markdown file in its category folder', () {
    final song = entry('a' * 32, SeedSchemas.songSketchV1, {
      'title': const TextValue('Notturno in La'),
      'lyrics': const TextValue('Prima strofa\n\n**ritornello**'),
      'bpm': NumberValue(92),
    });

    final files = unzip(
      export(filed: {'a' * 32: songs})
          .archive([song], at: DateTime(2026, 10, 13, 18, 30)),
    );

    final text = files['Idee/Canzoni 2026/Notturno in La.md']!;
    expect(text, startsWith('# Notturno in La\n\n'));
    expect(text, contains('Prima strofa\n\n**ritornello**'));
    expect(text, contains(':** 92'));
  });

  test('a picture in the text is named, never left as an address', () {
    final blob = BlobId('f' * 32);
    final page = entry('a' * 32, SeedSchemas.documentV1, {
      'title': const TextValue('Manuale'),
      'body': TextValue(
        'Il palco:\n${InlineImages.markdown('Vista [dal] fondo', blob)}\n'
        'e ${InlineImages.markdown('', blob)} fine.',
      ),
    });

    final text = unzip(export().archive([page], at: DateTime(2026)))
        .values
        .single;

    expect(
      text,
      contains(
        'Il palco:\n_immagine (non inclusa): Vista dal fondo_\n'
        'e _immagine (non inclusa)_ fine.',
      ),
    );
    expect(text, isNot(contains('image:')));
  });

  test('a to-do keeps its boxes; the same title twice gets a number', () {
    final list = entry('b' * 32, SeedSchemas.taskV2, {
      'title': const TextValue('Spesa'),
      'items': ChecklistValue([
        const ChecklistItem('Pane', done: true),
        const ChecklistItem('Latte'),
      ]),
    });
    final again = entry('c' * 32, SeedSchemas.taskV2, {
      'title': const TextValue('spesa'),
      'items': ChecklistValue([const ChecklistItem('Uova')]),
    });

    final files = unzip(export().archive([list, again], at: DateTime(2026)));

    expect(files.keys, ['Spesa.md', 'spesa (2).md']);
    expect(files['Spesa.md'], contains('- [x] Pane\n- [ ] Latte'));
  });

  test('names never leave the folder or break a system', () {
    String safe(String text) =>
        MarkdownExport.safeName(text, fallback: 'Senza titolo');

    expect(safe('../../etc/passwd'), 'etc passwd');
    expect(safe('a\\b:c*d?e"f<g>h|i'), 'a b c d e f g h i');
    expect(safe('...'), 'Senza titolo');
    expect(safe('CON'), 'Senza titolo');
    expect(safe('nota\u202Etxt.exe'), 'nota txt.exe');
    expect(safe('x' * 200).length, MarkdownExport.maxName);
  });
}
