import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The jobs that build and deploy the app run nothing that can change
/// under the same name: a moved tag or a fresh npm resolution would ship a
/// different bundle whose published hashes still match it.
void main() {
  final workflows = Directory('../../.github/workflows')
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.yml'))
      .toList();

  test('adversary: every action is pinned to a commit', () {
    expect(workflows, isNotEmpty);
    for (final workflow in workflows) {
      for (final line in workflow.readAsLinesSync()) {
        final uses = RegExp(r'uses:\s*(\S+)').firstMatch(line)?[1];
        if (uses == null || uses.startsWith('./')) continue;
        expect(
          uses,
          matches(RegExp(r'@[0-9a-f]{40}$')),
          reason: '${workflow.path}: $line',
        );
      }
    }
  });

  test('adversary: no package is fetched without a lockfile', () {
    for (final workflow in workflows) {
      expect(
        workflow.readAsStringSync(),
        isNot(contains('npx --yes')),
        reason: workflow.path,
      );
    }
  });

  test('adversary: every workflow starts with a read-only token', () {
    for (final workflow in workflows) {
      expect(
        workflow.readAsStringSync(),
        contains('\npermissions:\n  contents: read'),
        reason: workflow.path,
      );
    }
  });

  test('adversary: secrets are read only from the production environment, '
      'on main', () {
    for (final workflow in workflows) {
      final text = workflow.readAsStringSync();
      if (!text.contains(r'${{ secrets.')) continue;
      expect(
        text,
        contains('    environment: production\n'),
        reason: workflow.path,
      );
      expect(
        text,
        contains("github.ref == 'refs/heads/main'"),
        reason: workflow.path,
      );
    }
  });

  test('adversary: the web deploy runs by hand only from main', () {
    final deploy = workflows.singleWhere(
      (file) => file.path.endsWith('deploy-web.yml'),
    );
    expect(
      deploy.readAsStringSync(),
      contains(
        "(github.event_name == 'workflow_dispatch' &&\n"
        "       github.ref == 'refs/heads/main')",
      ),
    );
  });
}
