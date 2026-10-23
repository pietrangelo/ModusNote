import 'package:stream_channel/stream_channel.dart';

import 'live_server.dart';

/// The stand-in server on the VM, for the browser tests
/// (`spawnHybridUri`): it sends its origin, then answers each command.
Future<void> hybridMain(StreamChannel<Object?> channel) async {
  final server = await LiveServer.start();
  LiveSocket? socket;
  channel.sink.add(server.origin.toString());
  await for (final command in channel.stream) {
    switch (command) {
      case {'answer': final String answer}:
        server.answer = LiveAnswer.values.byName(answer);
        channel.sink.add('ok');
      case 'accept':
        socket = await server.next();
        channel.sink.add('ok');
      case {'send': final String text}:
        socket!.send(text);
        channel.sink.add('ok');
      case {'close': final int code}:
        await socket!.close(code);
        channel.sink.add('ok');
      case 'closed':
        channel.sink.add(await socket!.closed);
      case 'handshake':
        final handshake = server.handshakes.last;
        channel.sink.add({
          'path': handshake.path,
          'protocols': handshake.protocols,
        });
    }
  }
  await server.close();
}
