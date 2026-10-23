import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notices/notice_center.dart';
import 'package:modusnote/notices/notices_sheet.dart';
import 'package:modusnote/notices/security_banner.dart';
import 'package:modusnote/sync/cloud_sheet.dart';
import 'package:modusnote/sync/sync_controller.dart';
import 'package:offline_sync/offline_sync.dart';

import '../notes/harness.dart';
import '../vault/support.dart';
import 'notice_support.dart';

void main() {
  setUpAll(loadSodium);

  late Fleet fleet;
  late List<NoticeMark> marks;

  NoticeCenter centerOf(Member member, {ServiceNoticeBoard? board}) {
    final center = NoticeCenter(
      engine: member.vault.engine,
      sync: member.sync,
      mark: NoticeMark(member.vault.engine.ledger.records.length),
      saveMark: (mark) async => marks.add(mark),
      board: board,
      saveDismissed: (_) async {},
    );
    addTearDown(center.dispose);
    return center;
  }

  Future<void> showNotices(
    WidgetTester tester,
    NoticeCenter center,
    SyncController sync,
  ) async {
    await pumpApp(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => NoticesSheet.show(context, center, sync),
            child: const Text('apri'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('apri'));
    await tester.pumpAndSettle();
  }

  /// The phone sees the browser admit a tablet that can only read.
  Future<(NoticeCenter, Member, Member)> admittedElsewhere() async {
    fleet = await Fleet.found();
    final browser = await fleet.admit(fleet.phone);
    final center = centerOf(fleet.phone);
    final tablet = await fleet.admit(browser, role: Role.viewer);
    await fleet.phone.sync.syncNow();
    return (center, browser, tablet);
  }

  setUp(() => marks = []);

  testWidgets('says who came in, by whom, and marks it read', (tester) async {
    final (center, browser, tablet) = await admittedElsewhere();
    expect(center.unreadSecurity, 1);

    await showNotices(tester, center, fleet.phone.sync);

    expect(find.text('Sicurezza del vault'), findsOneWidget);
    expect(
      find.text('Un dispositivo è entrato nel vault e può leggere le note.'),
      findsOneWidget,
    );
    expect(
      find.text('Un dispositivo è entrato nel vault come proprietario.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Dispositivo ${tablet.id.fingerprint}'),
      findsOneWidget,
    );
    expect(
      find.textContaining('dal dispositivo ${browser.id.fingerprint}'),
      findsOneWidget,
    );
    expect(find.textContaining('da questo dispositivo'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('notice-new-2')),
      findsOneWidget,
      reason: 'still shown as new while the sheet is open',
    );
    expect(find.byKey(const ValueKey('notice-new-1')), findsNothing);
    expect(center.unread, 0);
    expect(marks.single.seen, 3);
  });

  testWidgets('a notice not recognized opens the members', (tester) async {
    final (center, _, _) = await admittedElsewhere();
    await showNotices(tester, center, fleet.phone.sync);

    final members = find.text('Non lo riconosci? Apri Membri del vault');
    await tester.ensureVisible(members.first);
    await tester.tap(members.first);
    await tester.pumpAndSettle();

    expect(find.text('Membri'), findsOneWidget);
  });

  testWidgets('a removal of this device says so', (tester) async {
    fleet = await Fleet.found();
    final browser = await fleet.admit(fleet.phone);
    final center = centerOf(fleet.phone);
    await browser.sync.revoke(fleet.phone.id);
    await fleet.phone.sync.syncNow();

    await showNotices(tester, center, fleet.phone.sync);

    expect(
      find.text(
        'Questo dispositivo è stato rimosso dal vault: non si sincronizza '
        'più e tiene le note che ha.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Questo dispositivo ·'), findsOneWidget);
  });

  testWidgets('service notices come first, as plain text, with the fixed '
      'line, and close for good', (tester) async {
    fleet = await Fleet.found();
    final operator = TestOperator();
    final center = centerOf(
      fleet.phone,
      board: operator.board(
        FakeNoticeSource([
          operator.signed(
            3,
            level: ServiceNoticeLevel.warning,
            texts: const {
              'en': 'Update the app.',
              'it': 'Aggiorna l’app: **https://esempio.it**',
            },
          ),
        ]),
      ),
    );
    await tester.runAsync(() async {
      await fleet.phone.sync.syncNow();
      await pumpEventQueue();
    });
    expect(center.service, hasLength(1));

    await showNotices(tester, center, fleet.phone.sync);

    expect(find.text('Aggiorna l’app: **https://esempio.it**'), findsOneWidget);
    expect(
      tester
          .widget<Icon>(find.byIcon(Icons.warning_amber_outlined))
          .semanticLabel,
      'Importante',
    );
    expect(
      find.textContaining('Gli avvisi di Modus Notes non ti chiederanno mai'),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('service-3'))).dy,
      lessThan(tester.getTopLeft(find.text('Sicurezza del vault')).dy),
    );

    await tester.tap(find.byTooltip('Chiudi l\'avviso'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('service-3')), findsNothing);
    expect(center.service, isEmpty);
  });

  testWidgets('the sync button counts unread notices, and says when one is '
      'about security', (tester) async {
    final (center, _, _) = await admittedElsewhere();

    await pumpApp(
      tester,
      Scaffold(
        body: CloudButton(sync: fleet.phone.sync, notices: center),
      ),
    );

    expect(find.byType(Badge), findsOneWidget);
    expect(
      find.descendant(of: find.byType(Badge), matching: find.text('1')),
      findsOneWidget,
    );
    expect(
      find.byTooltip('Sincronizzazione: aggiornato · 1 avviso di sicurezza'),
      findsOneWidget,
    );

    await center.markRead();
    await tester.pump();
    expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isFalse);
  });

  /// A vault nobody else joined, with one operator notice unread.
  Future<NoticeCenter> onlyServiceNotice(WidgetTester tester) async {
    fleet = await Fleet.found();
    final operator = TestOperator();
    final center = centerOf(
      fleet.phone,
      board: operator.board(FakeNoticeSource([operator.signed(3)])),
    );
    await tester.runAsync(() async {
      await fleet.phone.sync.syncNow();
      await pumpEventQueue();
    });
    expect(center.unreadService, 1);
    expect(center.unreadSecurity, 0);
    return center;
  }

  Finder shieldOnBadge() => find.descendant(
    of: find.byType(Badge),
    matching: find.byIcon(Icons.shield_outlined),
  );

  testWidgets('the sync button marks security notices with a shield, not '
      'only with a colour', (tester) async {
    final (center, _, _) = await admittedElsewhere();
    await pumpApp(
      tester,
      Scaffold(
        body: CloudButton(sync: fleet.phone.sync, notices: center),
      ),
    );

    expect(shieldOnBadge(), findsOneWidget);
    expect(
      tester.getSize(shieldOnBadge()).height,
      lessThanOrEqualTo(tester.getSize(find.byType(Badge)).height),
    );
  });

  testWidgets('the sync button shows no shield for operator notices', (
    tester,
  ) async {
    final center = await onlyServiceNotice(tester);
    await pumpApp(
      tester,
      Scaffold(
        body: CloudButton(sync: fleet.phone.sync, notices: center),
      ),
    );

    expect(
      find.descendant(of: find.byType(Badge), matching: find.text('1')),
      findsOneWidget,
    );
    expect(shieldOnBadge(), findsNothing);
  });

  testWidgets('a screen reader hears the sync button once, with the count '
      'and the kind of notices', (tester) async {
    final semantics = tester.ensureSemantics();
    final (center, _, _) = await admittedElsewhere();
    await pumpApp(
      tester,
      Scaffold(
        body: CloudButton(sync: fleet.phone.sync, notices: center),
      ),
    );

    expect(
      find.bySemanticsLabel(RegExp(r'^\s*1\s*$')),
      findsNothing,
      reason: 'the bare count says nothing on its own',
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('cloud'))),
      isSemantics(
        label: 'Sincronizzazione: aggiornato · 1 avviso di sicurezza',
        isButton: true,
        hasTapAction: true,
      ),
    );

    tester.semantics.tap(
      find.semantics.byLabel(
        'Sincronizzazione: aggiornato · 1 avviso di sicurezza',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CloudSheet), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a screen reader hears what the count on the notices button '
      'counts', (tester) async {
    final semantics = tester.ensureSemantics();
    final (center, _, _) = await admittedElsewhere();
    await pumpApp(
      tester,
      Scaffold(
        body: CloudSheet(sync: fleet.phone.sync, notices: center),
      ),
    );

    expect(
      tester.getSemantics(find.byKey(const ValueKey('notices'))),
      isSemantics(
        label: 'Avvisi · 1 avviso di sicurezza',
        isButton: true,
        hasTapAction: true,
      ),
    );
    semantics.dispose();
  });

  testWidgets('the sync sheet opens the notices after the members', (
    tester,
  ) async {
    final (center, _, _) = await admittedElsewhere();
    await pumpApp(
      tester,
      Scaffold(
        body: CloudSheet(sync: fleet.phone.sync, notices: center),
      ),
    );

    final notices = find.byKey(const ValueKey('notices'));
    expect(
      tester.getTopLeft(notices).dy,
      greaterThan(tester.getTopLeft(find.byKey(const ValueKey('members'))).dy),
    );
    await tester.tap(notices);
    await tester.pumpAndSettle();

    expect(find.text('Sicurezza del vault'), findsOneWidget);
  });

  testWidgets('the library banner shows only news from other devices', (
    tester,
  ) async {
    final (center, _, _) = await admittedElsewhere();
    var opened = 0;
    await pumpApp(
      tester,
      Scaffold(
        body: SecurityBanner(notices: center, onOpen: () => opened++),
      ),
    );

    expect(
      find.text(
        '1 nuovo avviso di sicurezza: i membri del vault sono cambiati.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Vedi'));
    expect(opened, 1);

    await center.markRead();
    await tester.pump();
    expect(find.byKey(const ValueKey('security-banner')), findsNothing);
  });
}
