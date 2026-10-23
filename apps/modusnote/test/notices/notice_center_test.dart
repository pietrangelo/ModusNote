import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notices/notice_center.dart';
import 'package:modusnote/sync/sync_controller.dart';
import 'package:offline_sync/offline_sync.dart';

import '../vault/support.dart';
import 'notice_support.dart';

void main() {
  setUpAll(loadSodium);

  late Fleet fleet;
  late List<NoticeMark> marks;
  late List<Set<int>> dismissals;

  setUp(() async {
    fleet = await Fleet.found();
    marks = [];
    dismissals = [];
  });

  NoticeCenter centerOf(
    Member member, {
    int? seen,
    ServiceNoticeBoard? board,
    Set<int> dismissed = const {},
    DateTime Function()? clock,
    SyncController? sync,
  }) {
    final center = NoticeCenter(
      engine: member.vault.engine,
      sync: sync ?? member.sync,
      mark: NoticeMark(seen ?? member.vault.engine.ledger.records.length),
      saveMark: (mark) async => marks.add(mark),
      board: board,
      dismissed: dismissed,
      saveDismissed: (serials) async => dismissals.add(serials),
      clock: clock,
    );
    addTearDown(center.dispose);
    return center;
  }

  group('security', () {
    test('records seen before the mark are history, not news', () async {
      final browser = await fleet.admit(fleet.phone);
      final center = centerOf(browser);

      expect(center.security, hasLength(1));
      expect(center.security.single.notice, isA<MemberJoined>());
      expect(center.security.single.unread, isFalse);
      expect(center.unreadSecurity, 0);
    });

    test('a device another owner let in is news, until the person opens '
        'the notices', () async {
      final browser = await fleet.admit(fleet.phone);
      final center = centerOf(fleet.phone);
      var told = 0;
      center.addListener(() => told++);

      final tablet = await fleet.admit(browser, role: Role.viewer);
      await fleet.phone.sync.syncNow();

      expect(told, greaterThan(0));
      expect(center.unreadSecurity, 1);
      expect(center.unread, 1);
      final joined = center.security.first;
      expect(joined.unread, isTrue);
      expect(joined.byThisDevice, isFalse);
      expect(
        joined.notice,
        isA<MemberJoined>()
            .having((n) => n.member, 'member', tablet.id)
            .having((n) => n.author, 'author', browser.id)
            .having((n) => n.role, 'role', Role.viewer),
      );
      expect(center.security.last.unread, isFalse, reason: 'newest first');

      await center.markRead();

      expect(center.unreadSecurity, 0);
      expect(marks.single.seen, 3);
    });

    test("this device's own records are listed, never news", () async {
      final browser = await fleet.admit(fleet.phone);
      final center = centerOf(fleet.phone, seen: 1);

      await fleet.phone.sync.revoke(browser.id);

      expect(center.unreadSecurity, 0);
      final removed = center.security.first;
      expect(removed.byThisDevice, isTrue);
      expect(removed.notice, isA<MemberRemoved>());
      expect(removed.rotated, isTrue, reason: 'it made the new key');
    });

    test('a removal waits for the new key on a device that has none', () async {
      final browser = await fleet.admit(fleet.phone);
      final center = centerOf(fleet.phone);

      await browser.sync.revoke(fleet.phone.id);
      await fleet.phone.sync.syncNow();

      expect(center.unreadSecurity, 1);
      final removed = center.security.first;
      expect(removed.notice.member, fleet.phone.id);
      expect(removed.rotated, isFalse);
    });

    test('a removal another owner made says the key is new once it is '
        'here', () async {
      final browser = await fleet.admit(fleet.phone);
      final tablet = await fleet.admit(fleet.phone);
      final center = centerOf(fleet.phone);

      await browser.sync.revoke(tablet.id);
      await fleet.phone.sync.syncNow();

      expect(center.security.first.notice, isA<MemberRemoved>());
      expect(center.security.first.rotated, isTrue);
    });
  });

  group('service', () {
    late TestOperator operator;
    final now = TestOperator.now;

    setUp(() => operator = TestOperator());

    Uint8List signed(int serial) => operator.signed(serial);

    ServiceNoticeBoard board(FakeNoticeSource source) => operator.board(source);

    test('are read after the first sync of the unlock, then every six '
        'hours at most', () async {
      final source = FakeNoticeSource([signed(4), signed(7)]);
      var clock = now;
      final center = centerOf(
        fleet.phone,
        board: board(source),
        clock: () => clock,
      );
      expect(source.fetches, 0);

      await fleet.phone.sync.syncNow();
      await pumpEventQueue();
      expect(source.fetches, 1);
      expect(center.service.map((n) => n.serial), [7, 4]);
      expect(center.unreadService, 2);

      await fleet.phone.sync.syncNow();
      clock = now.add(const Duration(hours: 5));
      await fleet.phone.sync.syncNow();
      await pumpEventQueue();
      expect(source.fetches, 1);

      clock = now.add(const Duration(hours: 6));
      await fleet.phone.sync.syncNow();
      await pumpEventQueue();
      expect(source.fetches, 2);
    });

    test(
      'opening the notices reads them; closing one keeps it closed',
      () async {
        final source = FakeNoticeSource([signed(4), signed(7)]);
        final center = centerOf(
          fleet.phone,
          board: board(source),
          dismissed: {2},
        );
        await fleet.phone.sync.syncNow();
        await pumpEventQueue();

        await center.markRead();
        expect(center.unreadService, 0);
        expect(center.service, hasLength(2));

        await center.dismiss(7);

        expect(center.service.map((n) => n.serial), [4]);
        expect(dismissals.single, {2, 7});
      },
    );

    test('a vault whose sync is off asks for nothing', () async {
      final source = FakeNoticeSource([signed(4)]);
      final off = SyncController(
        engine: fleet.phone.vault.engine,
        onPulled: () async {},
      );
      addTearDown(off.dispose);
      final center = centerOf(fleet.phone, board: board(source), sync: off);
      await off.syncNow();
      await pumpEventQueue();

      expect(center.service, isEmpty);
      expect(source.fetches, 0);
    });
  });
}
