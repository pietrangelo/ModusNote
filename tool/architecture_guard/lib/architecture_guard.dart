/// Static checks that keep every bounded context shaped as a rosette:
/// a pure core, an application ring that depends only on the core, and
/// adapters that live in their own `<context>_adapters` package.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

enum Rule {
  impureCore,
  impureApplication,
  impureDependency,
  privateImport,
  adaptersInDomain,
  conditionalImport,
}

final class Violation {
  const Violation(this.rule, this.location, this.detail);

  final Rule rule;
  final String location;
  final String detail;

  @override
  String toString() => '[${rule.name}] $location: $detail';
}

final class ArchitectureGuard {
  ArchitectureGuard(this.workspaceRoot);

  final String workspaceRoot;

  static const _adaptersSuffix = '_adapters';

  // `meta` carries only annotations (@immutable, @useResult), so it adds
  // compile-time guarantees without pulling behaviour into the domain.
  static const _pureDependencies = {'meta'};

  static const _coreDartLibraries = {
    'dart:core',
    'dart:typed_data',
    'dart:collection',
    'dart:math',
    'dart:convert',
  };

  static const _applicationDartLibraries = {
    ..._coreDartLibraries,
    'dart:async',
  };

  // Whole directive up to its `;`, so conditional-import alternatives and
  // multi-line directives cannot slip past a single-URI match.
  static final _directive = RegExp(
    r'^\s*(?:import|export|part)\b[^;]*;',
    multiLine: true,
  );
  static final _conditional = RegExp(
    r'^\s*(?:import|export)\b[^;]*\bif\s*\(',
    multiLine: true,
  );
  static final _quoted = RegExp(r'''['"]([^'"]+)['"]''');

  List<Violation> check() {
    final packagesDir = Directory(p.join(workspaceRoot, 'packages'));
    if (!packagesDir.existsSync()) return const [];

    final packages = packagesDir.listSync().whereType<Directory>().where(
      (dir) => File(p.join(dir.path, 'pubspec.yaml')).existsSync(),
    );
    final domainNames = packages
        .map((dir) => p.basename(dir.path))
        .where((name) => !name.endsWith(_adaptersSuffix))
        .toSet();

    return [
      for (final package in packages) ..._checkPackage(package, domainNames),
    ];
  }

  Iterable<Violation> _checkPackage(
    Directory package,
    Set<String> domainNames,
  ) sync* {
    final name = p.basename(package.path);
    final isDomain = domainNames.contains(name);

    if (isDomain) {
      yield* _checkDependencies(package, domainNames);
      final adapters = Directory(
        p.join(package.path, 'lib', 'src', 'adapters'),
      );
      if (adapters.existsSync()) {
        yield Violation(
          Rule.adaptersInDomain,
          _relative(adapters.path),
          'adapters belong in the separate package $name$_adaptersSuffix',
        );
      }
    }

    final lib = Directory(p.join(package.path, 'lib'));
    if (!lib.existsSync()) return;

    for (final file in lib.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final ring = isDomain ? _ringOf(lib.path, file.path) : null;
      // Platform switches belong in adapters; a domain that compiles
      // differently per platform is no longer one domain.
      if (isDomain && _conditional.hasMatch(file.readAsStringSync())) {
        yield Violation(
          Rule.conditionalImport,
          _relative(file.path),
          'conditional imports belong in a ${_adaptersSuffix.substring(1)} package',
        );
      }
      for (final uri in _directives(file)) {
        yield* _checkDirective(name, lib.path, file, ring, uri);
      }
    }
  }

  Iterable<Violation> _checkDependencies(
    Directory package,
    Set<String> domainNames,
  ) sync* {
    final pubspec = loadYaml(
      File(p.join(package.path, 'pubspec.yaml')).readAsStringSync(),
    ) as YamlMap;
    final dependencies = pubspec['dependencies'];
    if (dependencies is! YamlMap) return;

    for (final dependency in dependencies.keys.cast<String>()) {
      if (_pureDependencies.contains(dependency)) continue;
      if (domainNames.contains(dependency)) continue;
      yield Violation(
        Rule.impureDependency,
        _relative(p.join(package.path, 'pubspec.yaml')),
        'domain package depends on $dependency',
      );
    }
  }

  Iterable<Violation> _checkDirective(
    String packageName,
    String libPath,
    File file,
    _Ring? ring,
    String uri,
  ) sync* {
    final location = _relative(file.path);

    if (uri.startsWith('package:')) {
      final segments = uri.substring('package:'.length).split('/');
      final target = segments.first;
      if (target != packageName &&
          segments.length > 1 &&
          segments[1] == 'src') {
        yield Violation(Rule.privateImport, location, uri);
        return;
      }
    }

    if (ring == null) return;

    if (!_isAllowed(packageName, libPath, file, ring, uri)) {
      yield Violation(
        ring == _Ring.core ? Rule.impureCore : Rule.impureApplication,
        location,
        uri,
      );
    }
  }

  bool _isAllowed(
    String packageName,
    String libPath,
    File file,
    _Ring ring,
    String uri,
  ) {
    final allowedRings = ring == _Ring.core
        ? const {_Ring.core}
        : const {_Ring.core, _Ring.application};

    if (uri.startsWith('dart:')) {
      final library = uri.split('/').first;
      return (ring == _Ring.core
              ? _coreDartLibraries
              : _applicationDartLibraries)
          .contains(library);
    }

    if (uri.startsWith('package:')) {
      final path = uri.substring('package:'.length);
      final target = path.split('/').first;
      if (_pureDependencies.contains(target)) return true;
      if (target != packageName) return false;
      return allowedRings.contains(
        _ringOf(libPath, p.join(libPath, path.substring(target.length + 1))),
      );
    }

    final resolved = p.normalize(p.join(p.dirname(file.path), uri));
    return allowedRings.contains(_ringOf(libPath, resolved));
  }

  _Ring? _ringOf(String libPath, String filePath) {
    final relative = p.split(p.relative(filePath, from: libPath));
    if (relative.length < 2 || relative.first != 'src') return null;
    return switch (relative[1]) {
      'core' => _Ring.core,
      'application' => _Ring.application,
      _ => null,
    };
  }

  Iterable<String> _directives(File file) => _directive
      .allMatches(file.readAsStringSync())
      .expand((directive) => _quoted.allMatches(directive.group(0)!))
      .map((uri) => uri.group(1)!)
      .where((uri) => !uri.startsWith('dart.library.'));

  String _relative(String path) => p.relative(path, from: workspaceRoot);
}

enum _Ring { core, application }
