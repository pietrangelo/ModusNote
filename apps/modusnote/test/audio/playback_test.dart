import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/audio/note_playback.dart';
import 'package:modusnote/audio/note_recorder.dart';
import 'package:modusnote/audio/recording_player_view.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/vault/vault_note_store.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../notes/harness.dart';
import '../vault/support.dart';
import 'fake_capture.dart';

/// Five seconds of "audio" at the fake decoder's 8 kHz.
final take = voice(8000 * 2 * 5);

void main() {
  setUpAll(loadSodium);

  late UnlockedVault vault;
  late MemoryFileSystem files;
  late NoteRecorder recorder;
  late FakeDecoder decoder;
  late FakePlayer player;
  late NotePlayback playback;

  setUp(() async {
    final database = memoryDatabase();
    addTearDown(database.close);
    vault = await keeperOn(database).create(passphrase('frase lunga'));
    addTearDown(vault.lock);
    final storage = memoryBlobs();
    files = storage.files;
    var now = DateTime.utc(2026, 10, 11, 9);
    recorder = NoteRecorder(
      capture: () => FakeCapture(take),
      blobs: storage.blobs,
      engine: vault.engine,
      clock: () => now = now.add(const Duration(seconds: 5)),
    );
    decoder = FakeDecoder();
    player = FakePlayer();
    playback = NotePlayback(
      decoding: RecordingPlayback(storage: storage.blobs, decoders: [decoder]),
      engine: vault.engine,
      player: player,
    );
  });

  void tamper(BlobId blob) {
    final file = files.file('/blobs/${blob.value}.enc');
    final bytes = file.readAsBytesSync();
    bytes[bytes.length - 3] ^= 0x01;
    file.writeAsBytesSync(bytes);
  }

  group('NotePlayback', () {
    test('decrypts a take with its epoch key and loads it to play', () async {
      final recorded = await (await recorder.start()).stop();

      final opened = await playback.open(recorded);

      expect(decoder.heard.single, take);
      expect(opened.waveform.peaks, hasLength(NotePlayback.waveformBars));
      expect(opened.sound.length, const Duration(seconds: 5));
      expect(player.loaded.single, same(opened.sound));
    });

    test('only formats a decoder reads are offered for playback', () async {
      final recorded = await (await recorder.start()).stop();
      final safari = KeyedRecording(
        epoch: recorded.epoch,
        metadata: BlobMetadata(
          blob: recorded.metadata.blob,
          format: AudioFormat.aacMp4,
          duration: recorded.metadata.duration,
          recordedAt: recorded.metadata.recordedAt,
        ),
      );

      expect(playback.canPlay(recorded), isTrue);
      expect(playback.canPlay(safari), isFalse);
    });

    group('adversary', () {
      test(
        'a tampered blob is refused and nothing reaches the player',
        () async {
          final recorded = await (await recorder.start()).stop();
          tamper(recorded.id);

          await expectLater(playback.open(recorded), throwsA(anything));
          expect(player.loaded, isEmpty);
        },
      );

      test('a take claiming an epoch the vault has no key for fails', () async {
        final recorded = await (await recorder.start()).stop();
        final forged = KeyedRecording(
          epoch: recorded.epoch.next,
          metadata: recorded.metadata,
        );

        await expectLater(
          playback.open(forged),
          throwsA(isA<MissingGroupKeyException>()),
        );
        expect(decoder.heard, isEmpty);
      });
    });
  });

  group('player in the editor', () {
    late VaultNoteStore store;

    Future<void> openSong(
      WidgetTester tester, {
      bool withPlayback = true,
    }) async {
      store = await VaultNoteStore.open(
        vault.engine,
        catalog: SeedSchemas.catalog,
        recorder: recorder,
        playback: withPlayback ? playback : null,
      );
      final recorded = await (await recorder.start()).stop();
      final song = switch (DynamicEntry.create(
        schema: SeedSchemas.songSketchV1,
        id: EntryId('0123456789abcdef0123456789abcdef'),
        attributes: {
          FieldKey('title'): const TextValue('Riff'),
          FieldKey('guide_track'): AudioBlobValue(recorded.id),
        },
        at: DateTime.utc(2026, 10, 11, 9),
      )) {
        Valid(:final value) => value,
        Invalid(:final violations) => throw StateError('$violations'),
      };
      await store.save(song, takes: [recorded]);
      await pumpApp(
        tester,
        NoteEditorScreen(
          schemas: SeedSchemas.all,
          store: store,
          initialSchema: SeedSchemas.songSketchV1,
          entry: store.entries.single,
        ),
      );
      await tester.ensureVisible(fieldFinder('guide_track'));
      await tester.pumpAndSettle();
    }

    /// Decryption reads the blob store, which runs on the real event loop.
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }

    Future<void> tapPlay(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Ascolta la registrazione'));
      await settle(tester);
    }

    testWidgets('nothing is decrypted until play is tapped', (tester) async {
      await tester.runAsync(() => openSong(tester));
      await tester.pump();

      expect(find.text('Registrazione allegata · 0:05'), findsOneWidget);
      expect(decoder.heard, isEmpty);
    });

    testWidgets('play shows the waveform and the position as it moves', (
      tester,
    ) async {
      await tester.runAsync(() => openSong(tester));
      await tester.pump();

      await tapPlay(tester);

      final sound = player.loaded.single;
      expect(sound.playing, isTrue);
      expect(find.byKey(const ValueKey('waveform')), findsOneWidget);
      expect(find.byTooltip('Pausa'), findsOneWidget);

      sound.position = const Duration(seconds: 2);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('0:02 / 0:05'), findsOneWidget);

      await tester.tap(find.byTooltip('Pausa'));
      await tester.pump();
      expect(sound.playing, isFalse);
      expect(find.byTooltip('Ascolta la registrazione'), findsOneWidget);
    });

    testWidgets('tapping the waveform seeks there', (tester) async {
      await tester.runAsync(() => openSong(tester));
      await tester.pump();
      await tapPlay(tester);
      final waveform = find.byKey(const ValueKey('waveform'));

      final box = tester.getRect(waveform);
      await tester.tapAt(Offset(box.left + box.width * 0.8, box.center.dy));
      await tester.pump();

      expect(player.loaded.single.position, const Duration(seconds: 4));
      expect(find.text('0:04 / 0:05'), findsOneWidget);
    });

    testWidgets('a sound that played to the end goes back to play', (
      tester,
    ) async {
      await tester.runAsync(() => openSong(tester));
      await tester.pump();
      await tapPlay(tester);

      player.loaded.single.playing = false;
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byTooltip('Ascolta la registrazione'), findsOneWidget);
    });

    testWidgets('leaving the note frees the loaded samples', (tester) async {
      await tester.runAsync(() => openSong(tester));
      await tester.pump();
      await tapPlay(tester);

      await tester.pumpWidget(const SizedBox());

      expect(player.loaded.single.disposed, isTrue);
    });

    testWidgets('without a player the field shows only the length', (
      tester,
    ) async {
      await tester.runAsync(() => openSong(tester, withPlayback: false));
      await tester.pump();

      expect(find.byType(RecordingPlayerView), findsNothing);
      expect(find.text('Registrazione allegata · 0:05'), findsOneWidget);
    });

    group('adversary', () {
      testWidgets('a tampered recording says so and is never played', (
        tester,
      ) async {
        await tester.runAsync(() => openSong(tester));
        await tester.pump();
        tamper(
          store
              .recordingOf(
                (store.entries.single.valueOf(FieldKey('guide_track'))!
                        as AudioBlobValue)
                    .blob,
              )!
              .id,
        );

        await tapPlay(tester);

        expect(
          find.text(
            'La registrazione è danneggiata o è stata alterata, quindi non viene riprodotta.',
          ),
          findsOneWidget,
        );
        expect(player.loaded, isEmpty);
      });
    });
  });
}
