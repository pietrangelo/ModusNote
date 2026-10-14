import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/l10n/generated/app_localizations_en.dart';
import 'package:modusnote/l10n/generated/app_localizations_it.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:modusnote/reminders/password_reminders.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

final class FakeScheduler implements ReminderScheduler {
  final sent = <List<ScheduledReminder>>[];
  var asked = 0;
  var allow = true;

  @override
  Future<bool> ask() async {
    asked++;
    return allow;
  }

  @override
  Future<void> replaceAll(List<ScheduledReminder> reminders) async =>
      sent.add(reminders);
}

FieldKey k(String key) => FieldKey(key);

DynamicEntry credential(
  String id,
  DateValue? expiry, {
  String name = 'Banca',
}) => switch (DynamicEntry.create(
  schema: SeedSchemas.credentialV1,
  id: EntryId(id * 32),
  attributes: {
    k('description'): TextValue(name),
    k('password'): const SecretValue('zebra-Quokka-42'),
    k('password_expiry'): ?expiry,
  },
  at: DateTime.utc(2026),
)) {
  Valid(:final value) => value,
  Invalid(:final violations) => throw StateError('$violations'),
};

void main() {
  late InMemoryNoteStore store;
  late FakeScheduler scheduler;
  late PasswordReminders reminders;
  var now = DateTime(2026, 10, 14, 15);

  setUp(() {
    now = DateTime(2026, 10, 14, 15);
    store = InMemoryNoteStore();
    scheduler = FakeScheduler();
    reminders = PasswordReminders(
      store: store,
      scheduler: scheduler,
      texts: ReminderTexts(AppLocalizationsIt()),
      clock: () => now,
    );
  });

  tearDown(() => reminders.dispose());

  test('a week before, the day before and on the day, at nine', () async {
    await store.save(credential('a', DateValue(2026, 11, 2)));
    reminders.start();
    await reminders.settled;
    expect(scheduler.sent.last.map((r) => (r.at, r.body)), [
      (DateTime(2026, 10, 26, 9), 'Una password scade tra 7 giorni.'),
      (DateTime(2026, 11, 1, 9), 'Una password scade domani.'),
      (DateTime(2026, 11, 2, 9), 'Una password scade oggi.'),
    ]);
    expect(scheduler.sent.last.first.title, 'Password in scadenza');
  });

  test('adversary: the text never names the note or the password', () async {
    await store.save(
      credential('a', DateValue(2026, 11, 2), name: 'Conto segreto'),
    );
    reminders.start();
    await reminders.settled;
    for (final reminder in scheduler.sent.last) {
      final shown = '${reminder.title} ${reminder.body}';
      expect(shown, isNot(contains('Conto')));
      expect(shown, isNot(contains('Quokka')));
    }
  });

  test('one reminder per day for passwords expiring together', () async {
    await store.save(credential('a', DateValue(2026, 11, 2)));
    await store.save(credential('b', DateValue(2026, 11, 2)));
    reminders.start();
    await reminders.settled;
    expect(scheduler.sent.last, hasLength(3));
    expect(scheduler.sent.last.last.body, '2 password scadono oggi.');
  });

  test('a reminder whose hour has passed today is not set', () async {
    await store.save(credential('a', DateValue(2026, 10, 15)));
    reminders.start();
    await reminders.settled;
    // Today at nine is gone: only tomorrow's.
    expect(scheduler.sent.last.map((r) => r.at), [DateTime(2026, 10, 15, 9)]);
  });

  test('changes follow the notes; trash and deletion withdraw', () async {
    reminders.start();
    await reminders.settled;
    expect(scheduler.sent.last, isEmpty);
    expect(scheduler.asked, 0, reason: 'nothing to remind: no question');

    final note = credential('a', DateValue(2026, 11, 2));
    await store.save(note);
    await reminders.settled;
    expect(scheduler.sent.last, hasLength(3));
    expect(scheduler.asked, 1);

    await store.moveToTrash(note.id);
    await reminders.settled;
    expect(scheduler.sent.last, isEmpty);

    await store.restore(note.id);
    await reminders.settled;
    expect(scheduler.sent.last, hasLength(3));
    expect(scheduler.asked, 1, reason: 'asked once per open vault');
  });

  test('an unchanged plan is not sent again', () async {
    await store.save(credential('a', DateValue(2026, 11, 2)));
    reminders.start();
    await reminders.settled;
    await store.save(credential('b', null));
    await reminders.settled;
    expect(scheduler.sent, hasLength(1));
  });

  test('a refused permission still keeps the plan in step', () async {
    scheduler.allow = false;
    await store.save(credential('a', DateValue(2026, 11, 2)));
    reminders.start();
    await reminders.settled;
    expect(scheduler.sent.last, hasLength(3));
  });

  test('after dispose, changes are no longer followed', () async {
    reminders.start();
    await reminders.settled;
    reminders.dispose();
    await store.save(credential('a', DateValue(2026, 11, 2)));
    await reminders.settled;
    expect(scheduler.sent, hasLength(1));
  });

  test('in English', () {
    final texts = ReminderTexts(AppLocalizationsEn());
    expect(
      texts.body(
        ReminderSlot(DateValue(2026, 1, 1), ExpiryReminderKind.dayBefore, 3),
      ),
      '3 passwords expire tomorrow.',
    );
  });
}
