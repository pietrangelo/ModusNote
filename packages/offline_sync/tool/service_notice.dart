// Writes the operator's signed service notices into the app's
// `notices.json`, which the Worker serves as a static file on the app's
// own origin. Devices show a notice only if a key pinned in the app signed
// it, so the server, which has no such key, cannot write one.
//
//   dart run tool/service_notice.dart keygen <key file>
//   dart run tool/service_notice.dart sign --key <key file> [--serial N] \
//       --days D [--level warning] --text it=... --text en=... \
//       [--file <notices.json>]
//   dart run tool/service_notice.dart prune [--file <notices.json>]
//
// keygen prints the public key to pin; the private key leaves it sealed
// under a passphrase (Argon2id and XChaCha20-Poly1305, as a backup) and
// stays on the operator's computer: never in the repository, the CI or the
// Worker. sign checks the new envelope with the app's own code before
// writing it; prune drops the expired ones. The default file is
// apps/modusnote/web/notices.json; publishing is a commit on main.
//
// Serials only go up. A device remembers, for good, the serials of the
// notices its person closed and never shows those again, so a new notice
// under an old serial would stay hidden there and nobody would know. The
// file keeps the highest serial ever signed into it (`lastSerial`, which
// prune leaves alone); sign refuses a serial that is not above it, and
// without --serial takes the next one.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sodium/sodium_sumo.dart';

const _usage = '''
usage: dart run tool/service_notice.dart keygen <key file>
       dart run tool/service_notice.dart sign --key <key file> [--serial N]
           --days D [--level warning] --text it=... [--text en=...]
           [--file <notices.json>]
       dart run tool/service_notice.dart prune [--file <notices.json>]

Serials only go up: devices never show again a serial their person closed.
Without --serial, sign takes the one after the highest ever signed.''';

Future<void> main(List<String> args) async {
  final NoticeCommand command;
  try {
    command = parseCommand(args, defaultFile: _appNotices());
  } on UsageException catch (error) {
    stderr
      ..writeln(error.message)
      ..writeln(_usage);
    exit(64);
  }
  final tool = NoticeTool(
    sodium: await SodiumSumoInit.init(),
    readPassphrase: _askPassphrase,
  );
  try {
    switch (command) {
      case KeygenCommand(:final keyPath):
        final key = await tool.keygen(keyPath);
        stdout
          ..writeln('Sealed key written to $keyPath.')
          ..writeln('Public key to pin in operator_keys.dart:')
          ..writeln(key.hex);
      case SignCommand(:final file):
        final signed = await tool.sign(command);
        stdout.writeln(
          'Notice ${signed.notice.serial} added to $file, shown until '
          '${signed.notice.expires.toIso8601String()}.',
        );
      case PruneCommand(:final file):
        stdout.writeln('${tool.prune(file)} expired notice(s) removed.');
    }
  } on UsageException catch (error) {
    stderr.writeln(error.message);
    exit(1);
  }
}

/// A mistake of the operator's: a wrong argument, passphrase or file.
final class UsageException implements Exception {
  const UsageException(this.message);

  final String message;

  @override
  String toString() => 'UsageException: $message';
}

sealed class NoticeCommand {
  const NoticeCommand();
}

final class KeygenCommand extends NoticeCommand {
  const KeygenCommand(this.keyPath);

  final String keyPath;
}

final class SignCommand extends NoticeCommand {
  const SignCommand({
    required this.keyPath,
    required this.serial,
    required this.days,
    required this.level,
    required this.texts,
    required this.file,
  });

  final String keyPath;

  /// Null for the next one: one above the highest ever signed into [file].
  final int? serial;

  /// How long the notice is shown, from now.
  final int days;
  final ServiceNoticeLevel level;

  /// By language, in the order given; `\n` in an argument is a line break.
  final Map<String, String> texts;
  final String file;
}

final class PruneCommand extends NoticeCommand {
  const PruneCommand(this.file);

  final String file;
}

/// The command [args] ask for; throws [UsageException] for anything else.
NoticeCommand parseCommand(List<String> args, {required String defaultFile}) {
  if (args.isEmpty) throw const UsageException('no command');
  final options = _options(args.skip(1).toList(), args.first);
  switch (args.first) {
    case 'keygen':
      return KeygenCommand(options.single('<key file>')!);
    case 'sign':
      final serialText = options.single('--serial');
      final serial = serialText == null ? null : int.tryParse(serialText);
      final days = int.tryParse(options.single('--days') ?? '');
      final keyPath = options.single('--key');
      if (keyPath == null) throw const UsageException('--key is required');
      if (serialText != null &&
          (serial == null || serial < 0 || serial > 0xffffffff)) {
        throw const UsageException('--serial must be 0 to 4294967295');
      }
      final longest = ServiceNotice.maxDuration.inDays;
      if (days == null || days < 1 || days > longest) {
        throw UsageException('--days must be 1 to $longest');
      }
      final level = switch (options.single('--level') ?? 'info') {
        'info' => ServiceNoticeLevel.info,
        'warning' => ServiceNoticeLevel.warning,
        _ => throw const UsageException('--level is info or warning'),
      };
      final texts = <String, String>{};
      for (final text in options.all('--text')) {
        final split = text.indexOf('=');
        if (split < 1) {
          throw const UsageException('--text is <language>=<text>');
        }
        final language = text.substring(0, split);
        if (texts.containsKey(language)) {
          throw UsageException('two texts in $language');
        }
        texts[language] = text.substring(split + 1).replaceAll(r'\n', '\n');
      }
      if (texts.isEmpty) throw const UsageException('--text is required');
      return SignCommand(
        keyPath: keyPath,
        serial: serial,
        days: days,
        level: level,
        texts: texts,
        file: options.single('--file') ?? defaultFile,
      );
    case 'prune':
      return PruneCommand(options.single('--file') ?? defaultFile);
    default:
      throw UsageException('unknown command ${args.first}');
  }
}

/// The options each command takes, and how many times.
const _accepted = {
  'keygen': {'<key file>'},
  'sign': {'--key', '--serial', '--days', '--level', '--text', '--file'},
  'prune': {'--file'},
};

({String? Function(String) single, List<String> Function(String) all}) _options(
  List<String> args,
  String command,
) {
  final accepted = _accepted[command];
  if (accepted == null) throw UsageException('unknown command $command');
  final values = <String, List<String>>{};
  for (var i = 0; i < args.length; i++) {
    final String name;
    final String value;
    if (accepted.contains('<key file>')) {
      (name, value) = ('<key file>', args[i]);
    } else {
      name = args[i];
      if (!accepted.contains(name)) throw UsageException('unknown $name');
      if (++i == args.length) throw UsageException('$name needs a value');
      value = args[i];
    }
    (values[name] ??= []).add(value);
  }
  return (
    single: (name) {
      final given = values[name] ?? const [];
      if (given.length > 1) throw UsageException('$name given twice');
      if (given.isEmpty && name == '<key file>') {
        throw const UsageException('the key file is required');
      }
      return given.firstOrNull;
    },
    all: (name) => values[name] ?? const [],
  );
}

/// What a notices file holds: the envelopes it publishes, and the highest
/// serial ever signed into it (null in a file written before it kept one,
/// or before its first notice), which only goes up.
typedef PublishedNotices = ({List<Uint8List> envelopes, int? lastSerial});

/// What [file] publishes; nothing when it does not exist yet.
PublishedNotices readNotices(File file) {
  if (!file.existsSync()) return (envelopes: [], lastSerial: null);
  try {
    if (jsonDecode(file.readAsStringSync())
        case {'notices': final List<Object?> notices} &&
            final Map<Object?, Object?> json
        when notices.every((n) => n is String) &&
            json.keys.every(const {'lastSerial', 'notices'}.contains)) {
      final lastSerial = json['lastSerial'];
      if (!json.containsKey('lastSerial') ||
          lastSerial is int && lastSerial >= 0 && lastSerial <= 0xffffffff) {
        return (
          envelopes: [for (final n in notices.cast<String>()) base64.decode(n)],
          lastSerial: lastSerial as int?,
        );
      }
    }
  } on FormatException {
    // Falls through to the refusal below.
  }
  throw UsageException('${file.path} is not a notices file');
}

void writeNotices(File file, List<Uint8List> envelopes, {int? lastSerial}) =>
    file.writeAsStringSync(
      noticesText(envelopes, lastSerial: lastSerial),
      flush: true,
    );

/// The text [writeNotices] writes, whose size devices check.
String noticesText(List<Uint8List> envelopes, {int? lastSerial}) {
  final json = const JsonEncoder.withIndent('  ').convert({
    'lastSerial': ?lastSerial,
    'notices': [for (final envelope in envelopes) base64.encode(envelope)],
  });
  return '$json\n';
}

/// The highest serial ever signed into a file that publishes [envelopes]
/// and remembers [lastSerial]: the highest of both.
int? _highestSerial(List<Uint8List> envelopes, int? lastSerial) {
  var highest = lastSerial;
  for (final envelope in envelopes) {
    final int serial;
    try {
      serial = SignedServiceNotice.parse(envelope).notice.serial;
    } on MalformedSyncDataException {
      continue;
    }
    if (highest == null || serial > highest) highest = serial;
  }
  return highest;
}

/// Keeps the operator key and signs with it.
final class NoticeTool {
  NoticeTool({
    required SodiumSumo sodium,
    required this._readPassphrase,
    this.kdf = KdfParameters.moderate,
    DateTime Function()? now,
  }) : _sodium = sodium,
       _identities = SodiumIdentityService(sodium),
       _keys = SodiumKeyDerivationService(sodium),
       _now = now ?? DateTime.now;

  final SodiumSumo _sodium;
  final IdentityService _identities;
  final KeyDerivationService _keys;
  final Uint8List Function(String prompt) _readPassphrase;
  final DateTime Function() _now;

  /// Argon2id costs for a new key file; an existing file keeps its own.
  final KdfParameters kdf;

  /// Generates an operator key and writes it to [path], sealed under a
  /// passphrase asked twice; a file already there is never overwritten.
  /// The public key, which the app pins.
  Future<PublicSigningKey> keygen(String path) async {
    final file = File(path);
    if (file.existsSync()) {
      throw UsageException('$path exists: a key is never overwritten');
    }
    final first = _readPassphrase('Passphrase for the new key: ');
    final again = _readPassphrase('Same passphrase again: ');
    final same = _sameBytes(first, again);
    again.fillRange(0, again.length, 0);
    if (!same) {
      first.fillRange(0, first.length, 0);
      throw const UsageException('the two passphrases differ');
    }
    final salt = _keys.newSalt();
    final sealing = await _derive(first, salt, kdf);
    final identity = _identities.generateIdentity();
    try {
      final public = identity.publicIdentity.signingKey;
      final sealed = _identities.sealIdentity(
        identity,
        key: sealing,
        associatedData: _OperatorKeyFile.slotFor(salt, kdf, public),
      );
      final bytes = _OperatorKeyFile(
        salt: salt,
        kdf: kdf,
        public: public,
        sealed: sealed,
      ).toBytes();
      try {
        file.createSync(exclusive: true);
      } on FileSystemException {
        throw UsageException('$path exists: a key is never overwritten');
      }
      try {
        final chmod = await Process.run('chmod', ['600', path]);
        if (chmod.exitCode != 0) throw UsageException('cannot chmod $path');
        file.writeAsBytesSync(bytes, flush: true);
      } catch (_) {
        file.deleteSync();
        rethrow;
      }
      return public;
    } finally {
      identity.dispose();
      sealing.dispose();
    }
  }

  /// Signs a notice as [command] describes, checks the envelope as a device
  /// would, then adds it to the notices file.
  Future<SignedServiceNotice> sign(SignCommand command) async {
    final file = File(command.file);
    final (envelopes: published, :lastSerial) = readNotices(file);
    for (final envelope in published) {
      try {
        SignedServiceNotice.parse(envelope);
      } on MalformedSyncDataException {
        throw UsageException('${file.path} holds a malformed notice');
      }
    }
    if (published.length >= ServiceNoticeBoard.maxPublished) {
      throw const UsageException('too many notices: prune first');
    }
    final highest = _highestSerial(published, lastSerial);
    if (highest == 0xffffffff) {
      throw const UsageException('no serial is left above 4294967295');
    }
    final serial = command.serial ?? (highest ?? 0) + 1;
    if (highest != null && serial <= highest) {
      throw UsageException(
        'serial $serial is not above $highest, the highest signed: devices '
        'never show again a serial their person closed',
      );
    }
    final issued = DateTime.fromMillisecondsSinceEpoch(
      _now().millisecondsSinceEpoch,
      isUtc: true,
    );
    final ServiceNotice notice;
    try {
      notice = ServiceNotice(
        serial: serial,
        issued: issued,
        expires: issued.add(Duration(days: command.days)),
        level: command.level,
        texts: command.texts,
      );
    } on MalformedSyncDataException catch (error) {
      throw UsageException('no device would show it: ${error.message}');
    }

    final keyFile = _OperatorKeyFile.read(command.keyPath);
    final opening = await _derive(
      _readPassphrase('Passphrase of ${command.keyPath}: '),
      keyFile.salt,
      keyFile.kdf,
    );
    final IdentityKeyPair identity;
    try {
      identity = _identities.openIdentity(
        keyFile.sealed,
        key: opening,
        associatedData: keyFile.slot,
      );
    } on CryptographyException {
      throw const UsageException('wrong passphrase, or an altered key file');
    } finally {
      opening.dispose();
    }
    final Signature signature;
    try {
      if (identity.publicIdentity.signingKey != keyFile.public) {
        throw const UsageException('the key file does not match its key');
      }
      signature = _identities.sign(notice.signable, signer: identity);
    } finally {
      identity.dispose();
    }

    final signed = SignedServiceNotice(notice: notice, signature: signature);
    await _check(signed.toBytes(), notice, keyFile.public);
    final envelopes = [...published, signed.toBytes()];
    final text = noticesText(envelopes, lastSerial: serial);
    if (utf8.encode(text).length > ServiceNoticeBoard.maxPublishedBytes) {
      throw const UsageException('notices file too large: prune first');
    }
    file.writeAsStringSync(text, flush: true);
    return signed;
  }

  /// Removes from [path] the notices no device shows any more; how many.
  /// The highest serial they had stays in the file.
  int prune(String path) {
    final file = File(path);
    final (envelopes: published, :lastSerial) = readNotices(file);
    final now = _now();
    final kept = [
      for (final envelope in published)
        if (_inForce(envelope, now)) envelope,
    ];
    if (kept.length != published.length) {
      writeNotices(
        file,
        kept,
        lastSerial: _highestSerial(published, lastSerial),
      );
    }
    return published.length - kept.length;
  }

  static bool _inForce(Uint8List envelope, DateTime now) {
    try {
      return now.isBefore(SignedServiceNotice.parse(envelope).notice.expires);
    } on MalformedSyncDataException {
      return false;
    }
  }

  /// Reads [envelope] back as the app does, with [key] pinned: it must be
  /// exactly [notice], shown now.
  Future<void> _check(
    Uint8List envelope,
    ServiceNotice notice,
    PublicSigningKey key,
  ) async {
    final board = ServiceNoticeBoard(
      source: _Envelopes([envelope]),
      identities: _identities,
      keys: [OperatorKey(key, notAfter: notice.expires)],
      clock: _At(notice.issued),
    );
    final shown = await board.current();
    if (SignedServiceNotice.parse(envelope).notice != notice ||
        shown.length != 1 ||
        shown.single != notice) {
      throw StateError('the signed notice does not verify');
    }
  }

  /// Stretches [passphrase] (wiped) into the key that seals the key file.
  Future<SymmetricKey> _derive(
    Uint8List passphrase,
    Salt salt,
    KdfParameters parameters,
  ) async {
    final PasswordSecret secret;
    try {
      secret = SodiumPasswordSecret.fromUtf8Bytes(_sodium, passphrase);
    } on WeakPassphraseException {
      throw const UsageException('the passphrase is too short');
    }
    try {
      return await _keys.deriveKey(
        password: secret,
        salt: salt,
        parameters: parameters,
      );
    } finally {
      secret.dispose();
    }
  }
}

/// The operator key as kept on the operator's computer.
///
/// Wire: `"MNOK" | version(1) | salt(16) | opsLimit(u32) | memLimit(u32) |
/// public key(32) | sealed identity`. Every clear field is bound into the
/// associated data, so a file with weaker costs, another salt or another
/// public key does not open.
final class _OperatorKeyFile {
  _OperatorKeyFile({
    required this.salt,
    required this.kdf,
    required this.public,
    required this.sealed,
  });

  /// Throws [UsageException] for anything but a key file whose costs are
  /// within bounds, before any Argon2id runs.
  factory _OperatorKeyFile.read(String path) {
    final Uint8List bytes;
    try {
      bytes = File(path).readAsBytesSync();
    } on FileSystemException {
      throw UsageException('cannot read $path');
    }
    final header =
        _magic.length + 1 + Salt.length + 8 + PublicSigningKey.length;
    if (bytes.length <= header ||
        !_sameBytes(bytes.sublist(0, _magic.length), _magic) ||
        bytes[_magic.length] != _version) {
      throw UsageException('$path is not an operator key');
    }
    var at = _magic.length + 1;
    Uint8List take(int length) => bytes.sublist(at, at += length);
    try {
      final salt = Salt.fromBytes(take(Salt.length));
      final costs = ByteData.sublistView(take(8));
      final kdf = KdfParameters.custom(
        opsLimit: costs.getUint32(0),
        memLimitBytes: costs.getUint32(4),
      );
      final public = PublicSigningKey.fromBytes(take(PublicSigningKey.length));
      final sealed = EncryptedEnvelope.parse(bytes.sublist(at));
      return _OperatorKeyFile(
        salt: salt,
        kdf: kdf,
        public: public,
        sealed: sealed,
      );
    } on CryptographyException {
      throw UsageException('$path is not an operator key');
    }
  }

  static const _version = 1;
  static final _magic = ascii.encode('MNOK');

  final Salt salt;
  final KdfParameters kdf;
  final PublicSigningKey public;
  final EncryptedEnvelope sealed;

  AssociatedData get slot => slotFor(salt, kdf, public);

  static AssociatedData slotFor(
    Salt salt,
    KdfParameters kdf,
    PublicSigningKey public,
  ) => AssociatedData.forContext(
    'modusnote.operator-key.v1',
    _clearFields(
      salt,
      kdf,
      public,
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
  );

  Uint8List toBytes() => Uint8List.fromList([
    ..._clearFields(salt, kdf, public),
    ...sealed.toBytes(),
  ]);

  static Uint8List _clearFields(
    Salt salt,
    KdfParameters kdf,
    PublicSigningKey public,
  ) {
    final costs = ByteData(8)
      ..setUint32(0, kdf.opsLimit)
      ..setUint32(4, kdf.memLimitBytes);
    return Uint8List.fromList([
      ..._magic,
      _version,
      ...salt.bytes,
      ...costs.buffer.asUint8List(),
      ...public.bytes,
    ]);
  }
}

final class _Envelopes implements ServiceNoticeSource {
  _Envelopes(this._envelopes);

  final List<Uint8List> _envelopes;

  @override
  Future<List<Uint8List>> fetch() async => _envelopes;
}

final class _At implements Clock {
  _At(this._now);

  final DateTime _now;

  @override
  DateTime now() => _now;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

/// The app's notices file, from wherever in the repository the tool runs.
String _appNotices() {
  const relative = 'apps/modusnote/web/notices.json';
  for (var dir = Directory.current.absolute; ; dir = dir.parent) {
    if (Directory('${dir.path}/apps/modusnote/web').existsSync()) {
      return '${dir.path}/$relative';
    }
    if (dir.parent.path == dir.path) return relative;
  }
}

/// Reads a passphrase from the terminal without showing it.
Uint8List _askPassphrase(String prompt) {
  stdout.write(prompt);
  final terminal = stdin.hasTerminal;
  if (terminal) stdin.echoMode = false;
  try {
    final line = stdin.readLineSync(encoding: utf8, retainNewlines: false);
    if (line == null) throw const UsageException('no passphrase given');
    return Uint8List.fromList(utf8.encode(line));
  } finally {
    if (terminal) {
      stdin.echoMode = true;
      stdout.writeln();
    }
  }
}
