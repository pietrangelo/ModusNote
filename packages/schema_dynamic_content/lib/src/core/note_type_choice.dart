import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'schema_definition.dart';

/// Which note types a person wants offered: the ones never used (a song
/// for someone who does not write music) can be turned off, so they leave
/// the choice of a new note's type and the filters.
///
/// It names the types turned off, by [SchemaId.name], so a type a newer
/// app brings arrives on. Notes of a type turned off stay what they are:
/// they are still shown, opened and saved; this only decides what is
/// offered. At least one type is always offered.
@immutable
final class NoteTypeChoice {
  const NoteTypeChoice() : _hidden = const [];

  /// [hidden] in the order given; a name twice counts once.
  NoteTypeChoice.ofHidden(Iterable<String> hidden)
    : _hidden = List.unmodifiable(_checked(hidden));

  final List<String> _hidden;

  /// More than the app has types, with room for those to come.
  static const maxHidden = 64;

  static final _name = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  static List<String> _checked(Iterable<String> names) {
    final unique = <String>{};
    for (final name in names) {
      if (!_name.hasMatch(name)) {
        throw ArgumentError.value(name, 'hidden', 'not a type name');
      }
      unique.add(name);
    }
    if (unique.length > maxHidden) {
      throw ArgumentError.value(unique.length, 'hidden', 'too many');
    }
    return [...unique];
  }

  bool isOn(String name) => !_hidden.contains(name);

  /// The types of [schemas] that are on, in their order; all of them if
  /// none would be (a choice made with other types in the app).
  List<SchemaDefinition> offered(List<SchemaDefinition> schemas) {
    final on = [
      for (final schema in schemas)
        if (isOn(schema.id.name)) schema,
    ];
    return on.isEmpty ? schemas : on;
  }

  /// Whether [name] can go without leaving none of [schemas] offered.
  bool canTurnOff(String name, List<SchemaDefinition> schemas) =>
      schemas.any((schema) => schema.id.name != name && isOn(schema.id.name));

  /// This choice with [name] off, unless it is the last of [schemas] on.
  NoteTypeChoice turnedOff(String name, List<SchemaDefinition> schemas) =>
      !isOn(name) || !canTurnOff(name, schemas)
      ? this
      : NoteTypeChoice.ofHidden([..._hidden, name]);

  NoteTypeChoice turnedOn(String name) => isOn(name)
      ? this
      : NoteTypeChoice.ofHidden(_hidden.where((hidden) => hidden != name));

  static const _version = 1;

  /// Version, count, then each name as its length and its ASCII bytes.
  Uint8List toBytes() {
    final bytes = BytesBuilder(copy: false)
      ..addByte(_version)
      ..addByte(_hidden.length);
    for (final name in _hidden) {
      bytes
        ..addByte(name.length)
        ..add(ascii.encode(name));
    }
    return bytes.takeBytes();
  }

  /// What [toBytes] wrote; anything else, damaged or from a newer app, is
  /// every type on.
  static NoteTypeChoice fromBytes(Uint8List? bytes) {
    if (bytes == null || bytes.length < 2 || bytes[0] != _version) {
      return const NoteTypeChoice();
    }
    final count = bytes[1];
    final names = <String>[];
    var at = 2;
    for (var i = 0; i < count; i++) {
      if (at >= bytes.length) return const NoteTypeChoice();
      final length = bytes[at++];
      if (length == 0 || at + length > bytes.length) {
        return const NoteTypeChoice();
      }
      final name = String.fromCharCodes(bytes, at, at + length);
      at += length;
      if (!_name.hasMatch(name) || names.contains(name)) {
        return const NoteTypeChoice();
      }
      names.add(name);
    }
    if (at != bytes.length || count > maxHidden) return const NoteTypeChoice();
    return NoteTypeChoice.ofHidden(names);
  }

  @override
  bool operator ==(Object other) =>
      other is NoteTypeChoice &&
      other._hidden.length == _hidden.length &&
      other._hidden.toSet().containsAll(_hidden);

  @override
  int get hashCode => Object.hashAllUnordered(_hidden);
}
