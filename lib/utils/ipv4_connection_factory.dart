import 'dart:async';
import 'dart:io';

import 'certificate_trust.dart';
import 'happy_eyeballs.dart';

/// IPv4-only connection factory (1.6.13, H1): the panel's nginx refuses
/// the phone on home WiFi while the same login works from the Fire Stick
/// on the same network, and the phone's IPv6 is the leading suspect — so
/// when the preference is on, the panel host is resolved to IPv4
/// addresses only and the connection is made over IPv4, the same address
/// family the working Fire Stick uses.
///
/// Shape mirrors [happyEyeballsConnectionFactory]: a custom factory means
/// the SDK no longer secures the socket itself, so TLS is done here with
/// [SecureSocket.secure] against [CertificateTrust.contextFor] the host —
/// SNI and certificate validation stay correct for the hostname while the
/// socket itself goes to the resolved IPv4 literal. Certificate checks are
/// never disabled. Proxied requests are handed back plain: the SDK
/// tunnels and secures those on its own.
///
/// Candidates are tried in resolver order, one at a time (no racing —
/// the panel host normally answers on one address, and a race would only
/// add a second connection attempt against a provider that already
/// refuses us).
///

Future<ConnectionTask<Socket>> ipv4OnlyConnectionFactory(
  Uri url,
  String? proxyHost,
  int? proxyPort,
) {
  if (proxyHost != null) return Socket.startConnect(proxyHost, proxyPort!);
  final secure = url.isScheme('https');
  // WebSocket.connect supplies port 0 when a ws/wss URL omits its port.
  // Match HttpClient's default-port substitution for direct connections.
  final port = url.port == 0
      ? (secure ? HttpClient.defaultHttpsPort : HttpClient.defaultHttpPort)
      : url.port;
  return Future.value(startIpv4OnlyConnect(url.host, port, secure: secure));
}

Future<Socket> _secureUpgrade(Socket socket, String host) =>
    SecureSocket.secure(
      socket,
      host: host,
      context: CertificateTrust.contextFor(host),
    );

/// Connect to [host] over IPv4 only, in resolver order. Returns
/// synchronously so `HttpClient.connectionTimeout` and `cancel()` cover
/// the lookup as well as the connect.
///
/// The task owns the transport until it is delivered: `cancel()` is
/// idempotent, settles [ConnectionTask.socket] at once with a
/// [SocketException], cancels an in-flight connect, destroys a raw
/// socket that has not entered TLS yet, and never touches a socket that
/// was already delivered. dart:io exposes no handle to abort
/// `SecureSocket.secure` once it has detached the raw transport
/// (`destroy` on the plain socket is a no-op from then on), so a cancel
/// during the handshake can only settle the future and destroy whatever
/// the handshake eventually yields. [upgrade] is that handoff,
/// injectable like [lookup] and [connect].
ConnectionTask<Socket> startIpv4OnlyConnect(
  String host,
  int port, {
  bool secure = false,
  AddressLookup lookup = InternetAddress.lookup,
  AddressConnect connect = Socket.startConnect,
  TlsUpgrade upgrade = _secureUpgrade,
}) {
  final result = Completer<Socket>();
  var cancelled = false;
  ConnectionTask<Socket>? inFlight;
  Socket? rawHeld;

  void cancel() {
    cancelled = true;
    inFlight?.cancel();
    rawHeld?.destroy();
    rawHeld = null;
    if (!result.isCompleted) {
      result.completeError(const SocketException('Connection cancelled'));
    }
  }

  Future<void> run() async {
    try {
      final addresses = await lookup(host, type: InternetAddressType.IPv4);
      final ipv4 = addresses
          .where((a) => a.type == InternetAddressType.IPv4)
          .toList();
      if (ipv4.isEmpty) {
        throw SocketException('No IPv4 address for $host');
      }
      Socket? connected;
      Object? lastError;
      StackTrace? lastTrace;
      for (final address in ipv4) {
        if (cancelled) return;
        try {
          final task = await connect(address, port);
          inFlight = task;
          connected = await task.socket;
          inFlight = null;
          break;
        } catch (e, st) {
          lastError = e;
          lastTrace = st;
          inFlight = null;
        }
      }
      if (connected == null) {
        Error.throwWithStackTrace(
          lastError ?? SocketException('Could not connect to $host'),
          lastTrace ?? StackTrace.empty,
        );
      }
      if (cancelled) {
        connected.destroy();
        return;
      }
      if (secure) {
        rawHeld = connected;
        final secured = await upgrade(connected, host);
        rawHeld = null;
        if (cancelled) {
          secured.destroy();
          return;
        }
        result.complete(secured);
      } else {
        result.complete(connected);
      }
    } catch (e, st) {
      if (!result.isCompleted) result.completeError(e, st);
      rawHeld?.destroy();
      rawHeld = null;
    }
  }

  // The lookup runs inside run() (not synchronously) so a slow DNS
  // answer does not block the caller — but the task is returned
  // synchronously, so HttpClient's timeout and cancel() still cover it.
  unawaited(run());
  return ConnectionTask.fromSocket(result.future, cancel);
}
