import 'dart:io';

import 'package:architecture_guard/architecture_guard.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory workspace;

  setUp(() => workspace = Directory.systemTemp.createTempSync('guard_'));
  tearDown(() => workspace.deleteSync(recursive: true));

  void writePackage(
    String name, {
    Map<String, String> files = const {},
    List<String> dependencies = const ['meta'],
  }) {
    final root = p.join(workspace.path, 'packages', name);
    final deps = dependencies.map((d) => '  $d: any').join('\n');
    File(p.join(root, 'pubspec.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('name: $name\ndependencies:\n$deps\n');
    files.forEach((relative, source) {
      File(p.join(root, 'lib', relative))
        ..createSync(recursive: true)
        ..writeAsStringSync(source);
    });
  }

  List<Violation> check() => ArchitectureGuard(workspace.path).check();

  test('a core importing only dart:core siblings and meta is clean', () {
    writePackage(
      'vault',
      files: {
        'src/core/key.dart':
            "import 'package:meta/meta.dart';\n"
            "import 'nonce.dart';\n"
            "import 'dart:typed_data';\n",
        'src/core/nonce.dart': '',
      },
    );

    expect(check(), isEmpty);
  });

  test('core may not import dart:io', () {
    writePackage('vault', files: {'src/core/key.dart': "import 'dart:io';\n"});

    expect(check().single.rule, Rule.impureCore);
  });

  test('core may not import a third-party package', () {
    writePackage(
      'vault',
      files: {'src/core/key.dart': "import 'package:sodium/sodium.dart';\n"},
    );

    expect(check().single.rule, Rule.impureCore);
  });

  test('core may not reach up into the application ring', () {
    writePackage(
      'vault',
      files: {
        'src/core/key.dart': "import '../application/unlock.dart';\n",
        'src/application/unlock.dart': '',
      },
    );

    expect(check().single.rule, Rule.impureCore);
  });

  test('core may not reach the application ring by package uri', () {
    writePackage(
      'vault',
      files: {
        'src/core/key.dart':
            "import 'package:vault/src/application/unlock.dart';\n",
      },
    );

    expect(check().single.rule, Rule.impureCore);
  });

  test('application may use core and dart:async', () {
    writePackage(
      'vault',
      files: {
        'src/application/unlock.dart':
            "import 'dart:async';\n"
            "import '../core/key.dart';\n"
            "import 'package:vault/src/core/key.dart';\n",
        'src/core/key.dart': '',
      },
    );

    expect(check(), isEmpty);
  });

  test('application may not import a framework', () {
    writePackage(
      'vault',
      files: {
        'src/application/unlock.dart':
            "import 'package:flutter/widgets.dart';\n",
      },
    );

    expect(check().single.rule, Rule.impureApplication);
  });

  test("no package may import another package's src/", () {
    writePackage(
      'vault',
      files: {
        'src/application/unlock.dart':
            "import 'package:ledger/src/core/entry.dart';\n",
      },
    );

    expect(check().single.rule, Rule.privateImport);
  });

  test('exports are held to the same rules as imports', () {
    writePackage('vault', files: {'src/core/key.dart': "export 'dart:io';\n"});

    expect(check().single.rule, Rule.impureCore);
  });

  test('a domain package may depend only on meta and sibling domains', () {
    writePackage('ledger');
    writePackage('vault', dependencies: ['meta', 'ledger', 'sqflite']);

    final violation = check().single;
    expect(violation.rule, Rule.impureDependency);
    expect(violation.detail, contains('sqflite'));
  });

  test('an adapters package may depend on anything', () {
    writePackage(
      'vault_adapters',
      dependencies: ['sodium', 'vault'],
      files: {'sodium_vault.dart': "import 'package:sodium/sodium.dart';\n"},
    );

    expect(check(), isEmpty);
  });

  test('a domain package may not grow an adapters ring', () {
    writePackage('vault', files: {'src/adapters/sodium_vault.dart': ''});

    expect(check().single.rule, Rule.adaptersInDomain);
  });

  group('adversary', () {
    test('a conditional import cannot smuggle dart:io into core', () {
      writePackage(
        'vault',
        files: {
          'src/core/key.dart':
              "import 'stub.dart'\n"
              "    if (dart.library.io) 'dart:io';\n",
          'src/core/stub.dart': '',
        },
      );

      expect(check().single.detail, 'dart:io');
    });

    test('a part directive cannot pull application code into core', () {
      writePackage(
        'vault',
        files: {'src/core/key.dart': "part '../application/key_part.dart';\n"},
      );

      expect(check().single.rule, Rule.impureCore);
    });

    test('a directive split across lines is still seen', () {
      writePackage(
        'vault',
        files: {
          'src/core/key.dart':
              "import\n    'package:sqflite/sqflite.dart'\n"
              "    as db;\n",
        },
      );

      expect(check().single.rule, Rule.impureCore);
    });
  });

  test('the ModusNote workspace itself respects every rule', () {
    final repoRoot = p.normalize(p.join(Directory.current.path, '..', '..'));

    expect(ArchitectureGuard(repoRoot).check(), isEmpty);
  });
}
