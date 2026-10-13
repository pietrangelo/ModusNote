import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:modusnote/backup/backup_sheet.dart';
import 'package:modusnote/backup/file_exchange.dart';
import 'package:offline_sync/offline_sync.dart';

import '../notes/harness.dart';

final class FakeFiles implements FileExchange {
  final saved = <String, Uint8List>{};
  Uint8List? toPick;
  bool tooLarge = false;

  @override
  Future<void> save(String name, String mimeType, Uint8List bytes) async =>
      saved[name] = bytes;

  @override
  Future<Uint8List?> pick({
    required String accept,
    required int maxBytes,
  }) async {
    expect(accept, '.mnbackup');
    if (tooLarge) throw const FileTooLargeException();
    return toPick;
  }
}

/// Keeps the typed text, to check what reached the tools.
final class TypedSecret implements PasswordSecret {
  TypedSecret(this.text);

  final String text;
  var disposed = false;

  @override
  void dispose() => disposed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late FakeFiles files;
  late List<String> phrases;
  late BackupTools tools;
  BackupContents? opened;

  setUp(() {
    files = FakeFiles();
    phrases = [];
    opened = null;
    tools = BackupTools(
      files: files,
      secretFrom: (bytes) => TypedSecret(utf8.decode(bytes)),
      export: (phrase) async {
        phrases.add((phrase as TypedSecret).text);
        return Uint8List.fromList([1, 2, 3]);
      },
      open: (file, phrase) async {
        final typed = (phrase as TypedSecret).text;
        phrases.add(typed);
        if (typed != 'frase giusta del backup') {
          throw const BackupRejectedException();
        }
        return opened = BackupContents(const {});
      },
      restore: (backup) async => (added: 3, kept: 1),
      markdown: (at) => Uint8List.fromList(utf8.encode('zip')),
    );
  });

  Future<void> openSheet(WidgetTester tester) async {
    await pumpApp(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showBackupSheet(context, tools),
              child: const Text('apri'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('apri'));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets('the backup asks for its phrase twice and downloads', (
    tester,
  ) async {
    await openSheet(tester);
    await tap(tester, find.byKey(const ValueKey('backup-export')));

    await tester.enterText(
      find.byKey(const ValueKey('backup-phrase')),
      'frase giusta del backup',
    );
    await tester.enterText(
      find.byKey(const ValueKey('backup-phrase-again')),
      'frase sbagliata',
    );
    await tap(tester, find.text('Continua'));
    expect(find.text('Le due frasi non coincidono.'), findsOneWidget);
    expect(phrases, isEmpty);

    await tester.enterText(
      find.byKey(const ValueKey('backup-phrase-again')),
      'frase giusta del backup',
    );
    await tap(tester, find.text('Continua'));

    expect(phrases, ['frase giusta del backup']);
    expect(files.saved.keys.single, endsWith('.mnbackup'));
    expect(files.saved.values.single, [1, 2, 3]);
    expect(find.text('Backup scaricato.'), findsOneWidget);
  });

  testWidgets('a short phrase is refused', (tester) async {
    await openSheet(tester);
    await tap(tester, find.byKey(const ValueKey('backup-export')));

    await tester.enterText(find.byKey(const ValueKey('backup-phrase')), 'ab');
    await tester.enterText(
      find.byKey(const ValueKey('backup-phrase-again')),
      'ab',
    );
    await tap(tester, find.text('Continua'));

    expect(
      find.text('Usa almeno ${PassphrasePolicy.minimumBytes} caratteri.'),
      findsOneWidget,
    );
    expect(files.saved, isEmpty);
  });

  testWidgets('a restore says what it added, or that the phrase is wrong', (
    tester,
  ) async {
    files.toPick = Uint8List.fromList([9]);
    await openSheet(tester);
    await tap(tester, find.byKey(const ValueKey('backup-restore')));
    await tester.enterText(
      find.byKey(const ValueKey('backup-phrase')),
      'altra frase',
    );
    await tap(tester, find.text('Continua'));
    expect(
      find.text('Questo file non si apre con questa frase.'),
      findsOneWidget,
    );
    expect(opened, isNull);

    await tap(tester, find.text('apri'));
    await tap(tester, find.byKey(const ValueKey('backup-restore')));
    await tester.enterText(
      find.byKey(const ValueKey('backup-phrase')),
      'frase giusta del backup',
    );
    await tap(tester, find.text('Continua'));

    expect(opened, isNotNull);
    expect(
      find.text('Ripristino completato: 3 aggiunti, 1 già presenti.'),
      findsOneWidget,
    );
  });

  testWidgets('a file too large is refused before any phrase', (tester) async {
    files.tooLarge = true;
    await openSheet(tester);
    await tap(tester, find.byKey(const ValueKey('backup-restore')));

    expect(find.text('Il file è troppo grande.'), findsOneWidget);
    expect(find.byKey(const ValueKey('backup-phrase')), findsNothing);
  });

  testWidgets('the Markdown export warns that it is in clear', (tester) async {
    await openSheet(tester);
    await tap(tester, find.byKey(const ValueKey('backup-markdown')));
    expect(find.text('Esportare in chiaro?'), findsOneWidget);
    await tap(tester, find.text('Annulla'));
    expect(files.saved, isEmpty);

    await tap(tester, find.text('apri'));
    await tap(tester, find.byKey(const ValueKey('backup-markdown')));
    await tap(tester, find.text('Esporta'));

    expect(files.saved.keys.single, endsWith('.zip'));
    expect(find.text('Note esportate.'), findsOneWidget);
  });
}
