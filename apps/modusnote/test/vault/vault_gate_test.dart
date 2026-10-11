import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_library.dart';
import 'package:modusnote/vault/auto_lock.dart';
import 'package:modusnote/vault/vault_gate.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:sqlite3/sqlite3.dart';

import '../notes/harness.dart';
import 'support.dart';

Widget gateOn(Database database, {AutoLock Function(VoidCallback)? autoLock}) =>
    VaultGate(
      keeper: keeperOn(database),
      passwordFrom: (bytes) =>
          SodiumPasswordSecret.fromUtf8Bytes(sodium, bytes),
      catalog: SeedSchemas.catalog,
      autoLockFor: autoLock,
    );

/// The real policy with times short enough for a widget test.
AutoLock quickLock(VoidCallback onLock) => AutoLock(
  onLock: onLock,
  idle: const Duration(minutes: 1),
  background: const Duration(seconds: 10),
);

final passphraseField = find.byKey(const ValueKey('passphrase'));
final confirmField = find.byKey(const ValueKey('passphrase-confirm'));

void main() {
  setUpAll(loadSodium);
  late Database database;

  setUp(() => database = memoryDatabase());
  tearDown(() => database.close());

  Future<void> create(WidgetTester tester, String a, String b) async {
    await tester.enterText(passphraseField, a);
    await tester.enterText(confirmField, b);
    await tester.tap(find.text('Crea il vault'));
    await tester.pumpAndSettle();
  }

  Future<void> unlock(WidgetTester tester, String passphrase) async {
    await tester.enterText(passphraseField, passphrase);
    await tester.tap(find.text('Sblocca'));
    await tester.pumpAndSettle();
  }

  testWidgets('a new device asks to create the vault, then opens the notes', (
    tester,
  ) async {
    await pumpApp(tester, gateOn(database));

    expect(find.text('Crea il tuo vault'), findsOneWidget);
    await create(tester, 'frase lunga', 'frase lunga');

    expect(find.byType(NoteLibraryScreen), findsOneWidget);
  });

  testWidgets('the passphrase must be repeated exactly', (tester) async {
    await pumpApp(tester, gateOn(database));

    await create(tester, 'frase lunga', 'frase lunghe');

    expect(find.text('Le passphrase non coincidono.'), findsOneWidget);
    expect(find.byType(NoteLibraryScreen), findsNothing);
  });

  testWidgets('a passphrase under the policy minimum is refused', (
    tester,
  ) async {
    await pumpApp(tester, gateOn(database));

    await create(tester, 'corta', 'corta');

    expect(find.text('Usa almeno 8 caratteri.'), findsOneWidget);
    expect(find.byType(NoteLibraryScreen), findsNothing);
  });

  testWidgets('after a restart the vault asks for the passphrase', (
    tester,
  ) async {
    await pumpApp(tester, gateOn(database));
    await create(tester, 'frase lunga', 'frase lunga');
    await tester.tap(find.byTooltip('Blocca'));
    await tester.pumpAndSettle();

    await pumpApp(tester, gateOn(database));

    expect(find.text('Sblocca le tue note'), findsOneWidget);
    await unlock(tester, 'frase lunga');
    expect(find.byType(NoteLibraryScreen), findsOneWidget);
  });

  testWidgets('locking returns to the unlock screen', (tester) async {
    await pumpApp(tester, gateOn(database));
    await create(tester, 'frase lunga', 'frase lunga');

    await tester.tap(find.byTooltip('Blocca'));
    await tester.pumpAndSettle();

    expect(find.byType(NoteLibraryScreen), findsNothing);
    expect(find.text('Sblocca le tue note'), findsOneWidget);
  });

  group('auto-lock', () {
    final unlockPrompt = find.text('Sblocca le tue note');

    testWidgets('an idle vault locks and closes the open note', (tester) async {
      await pumpApp(tester, gateOn(database, autoLock: quickLock));
      await create(tester, 'frase lunga', 'frase lunga');
      await tester.tap(find.text('Nuova nota'));
      await tester.pumpAndSettle();
      expect(find.byType(NoteEditorScreen), findsOneWidget);

      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();

      expect(find.byType(NoteEditorScreen), findsNothing);
      expect(find.byType(NoteLibraryScreen), findsNothing);
      expect(unlockPrompt, findsOneWidget);
    });

    testWidgets('taps keep the vault open', (tester) async {
      await pumpApp(tester, gateOn(database, autoLock: quickLock));
      await create(tester, 'frase lunga', 'frase lunga');

      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 50));
        await tester.tapAt(const Offset(1, 300));
      }
      await tester.pump();

      expect(find.byType(NoteLibraryScreen), findsOneWidget);
    });

    testWidgets('typing in a note keeps the vault open', (tester) async {
      await pumpApp(tester, gateOn(database, autoLock: quickLock));
      await create(tester, 'frase lunga', 'frase lunga');
      await tester.tap(find.text('Nuova nota'));
      await tester.pumpAndSettle();
      // Focus without a tap, so only the typing counts as activity.
      await tester.showKeyboard(find.byType(EditableText).first);

      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 50));
        // The soft keyboard sends text, not pointer or key events.
        tester.testTextInput.enterText('nota $i');
        await tester.pump();
      }

      expect(find.byType(NoteEditorScreen), findsOneWidget);
    });

    testWidgets('a vault left in the background locks', (tester) async {
      await pumpApp(tester, gateOn(database, autoLock: quickLock));
      await create(tester, 'frase lunga', 'frase lunga');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 10));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(unlockPrompt, findsOneWidget);
    });

    testWidgets('a quick look at another app keeps the vault open', (
      tester,
    ) async {
      await pumpApp(tester, gateOn(database, autoLock: quickLock));
      await create(tester, 'frase lunga', 'frase lunga');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump(const Duration(seconds: 5));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 30));

      expect(find.byType(NoteLibraryScreen), findsOneWidget);
    });

    testWidgets('a locked vault stops counting', (tester) async {
      var locks = 0;
      await pumpApp(
        tester,
        gateOn(
          database,
          autoLock: (onLock) => quickLock(() {
            locks++;
            onLock();
          }),
        ),
      );
      await create(tester, 'frase lunga', 'frase lunga');
      await tester.tap(find.byTooltip('Blocca'));
      await tester.pumpAndSettle();

      await tester.pump(const Duration(minutes: 10));

      expect(locks, 0);
      expect(unlockPrompt, findsOneWidget);
    });
  });

  group('adversary', () {
    testWidgets('a wrong passphrase opens nothing and says so', (tester) async {
      await pumpApp(tester, gateOn(database));
      await create(tester, 'frase lunga', 'frase lunga');
      await tester.tap(find.byTooltip('Blocca'));
      await tester.pumpAndSettle();

      await unlock(tester, 'frase sbagliata');

      expect(find.text('Passphrase errata.'), findsOneWidget);
      expect(find.byType(NoteLibraryScreen), findsNothing);
    });

    testWidgets('the typed passphrase does not stay in the text field', (
      tester,
    ) async {
      await pumpApp(tester, gateOn(database));
      await create(tester, 'frase lunga', 'frase lunga');
      await tester.tap(find.byTooltip('Blocca'));
      await tester.pumpAndSettle();

      await unlock(tester, 'frase sbagliata');

      final field = tester.widget<TextField>(
        find.descendant(of: passphraseField, matching: find.byType(TextField)),
      );
      expect(field.controller!.text, isEmpty);
      expect(field.obscureText, isTrue);
      expect(field.enableSuggestions, isFalse);
      expect(field.autocorrect, isFalse);
    });

    testWidgets('a damaged vault is reported, not crashed on', (tester) async {
      await pumpApp(tester, gateOn(database));
      await create(tester, 'frase lunga', 'frase lunga');
      await tester.tap(find.byTooltip('Blocca'));
      await tester.pumpAndSettle();
      database.execute('DELETE FROM vault_membership');

      await pumpApp(tester, gateOn(database));
      await unlock(tester, 'frase lunga');

      expect(
        find.text(
          'Il vault su questo dispositivo è danneggiato e non si può aprire.',
        ),
        findsOneWidget,
      );
    });
  });
}
