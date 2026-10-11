import 'dart:io';

import 'package:architecture_guard/architecture_guard.dart';

void main(List<String> args) {
  final root = args.isEmpty ? Directory.current.path : args.single;
  final violations = ArchitectureGuard(root).check();

  for (final violation in violations) {
    stderr.writeln(violation);
  }
  if (violations.isNotEmpty) exitCode = 1;
}
