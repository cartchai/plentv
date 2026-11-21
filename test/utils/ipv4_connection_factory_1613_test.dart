import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/ipv4_connection_factory.dart';

void main() {
  late ServerSocket server;
  final accepted = <Socket>[];
  final opened = <Socket>[];

  setUp(() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(accepted.add);
  });

  tearDown(() async {
    for (final socket in [...accepted, ...opened]) {
      socket.destroy();
    }
    accepted.clear();
    opened.clear();
    await server.close();
  });

  Future<ConnectionTask<Socket>> realConnect(
    InternetAddress address,
    int port,
  ) => Socket.startConnect(address, port);

  test('connects to the IPv4 address from the lookup', () async {
    final task = startIpv4OnlyConnect(
      'panel.example.com',
      server.port,
      lookup: (_, {required type}) async {
        expect(type, InternetAddressType.IPv4);
        return [InternetAddress.loopbackIPv4];
      },
      connect: realConnect,
    );
    final socket = await task.socket;
    opened.add(socket);
    expect(socket.remoteAddress.address, '127.0.0.1');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(accepted, hasLength(1));
  });

  test('ignores IPv6 addresses in the lookup result', () async {
    final attempted = <InternetAddress>[];
    Future<ConnectionTask<Socket>> guardedConnect(
      InternetAddress address,
      int port,
    ) async {
      attempted.add(address);
      if (address.type != InternetAddressType.IPv4) {
        throw const SocketException('IPv6 must not be attempted');
      }
      return Socket.startConnect(address, port);
    }

    final task = startIpv4OnlyConnect(
      'panel.example.com',
      server.port,
      lookup: (_, {required type}) async => [
        InternetAddress.loopbackIPv6,
        InternetAddress.loopbackIPv4,
      ],
      connect: guardedConnect,
    );
    final socket = await task.socket;
    opened.add(socket);
    expect(attempted, [InternetAddress.loopbackIPv4]);
    expect(socket.remoteAddress.address, '127.0.0.1');
  });

  test('TLS upgrade receives the hostname, not the IPv4 literal', () async {
    final upgradeHosts = <String>[];
    Future<Socket> fakeUpgrade(Socket socket, String host) async {
      upgradeHosts.add(host);
      return socket;
    }

    final task = startIpv4OnlyConnect(
      'panel.example.com',
      server.port,
      secure: true,
      lookup: (_, {required type}) async => [InternetAddress.loopbackIPv4],
      connect: realConnect,
      upgrade: fakeUpgrade,
    );
    final socket = await task.socket;
    opened.add(socket);
    // SNI + certificate validation must see the hostname while the socket
    // itself goes to the resolved IPv4 literal.
    expect(upgradeHosts, ['panel.example.com']);
  });

  test('throws when the lookup returns no IPv4 address', () async {
    final task = startIpv4OnlyConnect(
      'panel.example.com',
      server.port,
      lookup: (_, {required type}) async => [InternetAddress.loopbackIPv6],
      connect: realConnect,
    );
    await expectLater(
      task.socket,
      throwsA(
        isA<SocketException>().having(
          (e) => e.message,
          'message',
          contains('No IPv4 address'),
        ),
      ),
    );
  });

  test('throws the connect error when every IPv4 address refuses', () async {
    Future<ConnectionTask<Socket>> refusedConnect(
      InternetAddress address,
      int port,
    ) async {
      throw const SocketException('refused');
    }

    final task = startIpv4OnlyConnect(
      'panel.example.com',
      server.port,
      lookup: (_, {required type}) async => [InternetAddress.loopbackIPv4],
      connect: refusedConnect,
    );
    await expectLater(
      task.socket,
      throwsA(
        isA<SocketException>().having(
          (e) => e.message,
          'message',
          'refused',
        ),
      ),
    );
  });

  test('factory connects over IPv4 for a plain http URL', () async {
    final task = await ipv4OnlyConnectionFactory(
      Uri.parse('http://localhost:${server.port}/'),
      null,
      null,
    );
    final socket = await task.socket;
    opened.add(socket);
    expect(socket.remoteAddress.address, '127.0.0.1');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(accepted, hasLength(1));
  });

  test('cancel settles the task with a SocketException', () async {
    final task = startIpv4OnlyConnect(
      'panel.example.com',
      server.port,
      lookup: (_, {required type}) async {
        // Never resolves, so the only way out is cancel().
        await Completer<void>().future;
        return [InternetAddress.loopbackIPv4];
      },
      connect: realConnect,
    );
    final future = task.socket;
    task.cancel();
    await expectLater(future, throwsA(isA<SocketException>()));
  });
}
