import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_backend.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_client.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_crypto.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_server.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_store.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_wire.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:universal_io/io.dart';

/// What the client's QR code carries
class LanPairCode {
  final String secret;
  final List<String> addresses;
  final int? port;
  final String name;

  LanPairCode({required this.secret, required this.addresses, required this.port, required this.name});

  String encode() => lanRelayPairPrefix +
      base64Url.encode(utf8.encode(jsonEncode({"v": lanRelayProtocolVersion, "s": secret, "a": addresses, "p": port, "n": name})));

  static LanPairCode? tryParse(String raw) {
    final text = raw.trim();
    if (!text.startsWith(lanRelayPairPrefix)) return null;
    try {
      final m = (jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(text.substring(lanRelayPairPrefix.length))))) as Map)
          .cast<String, dynamic>();
      return LanPairCode(
        secret: m["s"],
        addresses: (m["a"] as List? ?? []).cast<String>(),
        port: m["p"],
        name: m["n"] ?? "Computer",
      );
    } catch (_) {
      return null;
    }
  }
}

/// Phone side: accept a computer whose pairing QR code was just scanned.
/// Returns true if the computer received the result directly; otherwise it
/// will pick it up by polling the phone.
Future<bool> pairWithClientCode(LanPairCode code) async {
  ss.settings.lanRelayEnabled.value = true;
  await ss.settings.saveOne("lanRelayEnabled");
  await lanRelay.ensureRunning();
  try {
    await mcs.invokeMethod("lan-relay-changed");
  } catch (_) {}

  final identity = await LanRelayStore.instance.identity();
  final token = await LanRelayStore.instance.addClient(code.name);
  final sealed = LanPairing.seal(code.secret, {
    "token": token,
    "fingerprint": identity.fingerprint,
    "addresses": await LanRelayServer.localAddresses(),
    "port": lanRelayPort,
    "name": await LanRelayServer.deviceName(),
    "protocol": lanRelayProtocolVersion,
  });
  await LanRelayStore.instance.savePending(LanPairing.pairId(code.secret), sealed);

  if (code.port == null) return false;
  // computers often have several interfaces (docker, VMs, VPNs); try them all at once
  Future<bool> push(String ip) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final authority = ip.contains(":") ? "[$ip]" : ip;
      final req = await client.postUrl(Uri.parse("http://$authority:${code.port}/pair"));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(sealed));
      final res = await req.close().timeout(const Duration(seconds: 6));
      await res.drain();
      return res.statusCode == 200;
    } catch (e) {
      Logger.info("Couldn't reach computer at $ip: $e", tag: "LanRelay");
      return false;
    } finally {
      client.close(force: true);
    }
  }
  final results = await Future.wait(code.addresses.map(push));
  return results.contains(true);
}

/// Client side: shows a QR code and waits for the phone to answer, either by
/// connecting to us or by us polling it (found via mDNS or typed in).
class LanRelayPairingSession {
  final String secret = lanRandomToken();
  final List<String> manualHosts = [];
  final Completer<(Map<String, dynamic>, String?)> _result = Completer();
  HttpServer? _listener;
  Timer? _poll;
  bool _polling = false;
  int _pollCount = 0;
  List<LanRelayDiscovered> _discovered = [];

  Future<(Map<String, dynamic>, String?)> get result => _result.future;

  Future<String> start() async {
    try {
      _listener = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _listener!.listen(_onPush);
    } catch (e) {
      Logger.warn("Pairing listener unavailable, relying on polling", error: e, tag: "LanRelay");
    }
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _pollOnce());
    return LanPairCode(
      secret: secret,
      addresses: await LanRelayServer.localAddresses(),
      port: _listener?.port,
      name: Platform.localHostname,
    ).encode();
  }

  Future<void> cancel() async {
    _poll?.cancel();
    await _listener?.close(force: true);
    _listener = null;
  }

  void _complete(Map<String, dynamic> sealed, String? fromHost) {
    if (_result.isCompleted) return;
    final payload = LanPairing.open(secret, sealed);
    _result.complete((payload, fromHost));
    cancel();
  }

  Future<void> _onPush(HttpRequest req) async {
    Map<String, dynamic>? sealed;
    try {
      if (req.method != "POST" || req.uri.path != "/pair") {
        req.response.statusCode = 404;
      } else {
        sealed = (jsonDecode(await utf8.decoder.bind(req).join()) as Map).cast<String, dynamic>();
        // reject anything not sealed with our secret before acknowledging
        LanPairing.open(secret, sealed);
        req.response.statusCode = 200;
      }
    } catch (e) {
      sealed = null;
      req.response.statusCode = 400;
    }
    final from = req.connectionInfo?.remoteAddress.address;
    await req.response.close();
    // completing closes the listener, so only after the reply is sent
    if (sealed != null) _complete(sealed, from);
  }

  Future<void> _pollOnce() async {
    if (_polling || _result.isCompleted) return;
    _polling = true;
    try {
      if (_pollCount++ % 4 == 0) _discovered = await discoverRelayPhones(timeout: const Duration(seconds: 2));
      final hosts = {...manualHosts, ..._discovered.map((d) => d.host)};
      for (final host in hosts) {
        // the payload is sealed, so the certificate does not matter yet
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 3)
          ..badCertificateCallback = (_, __, ___) => true;
        try {
          final authority = host.contains(":") ? "[$host]" : host;
          final req = await client.getUrl(Uri.parse("https://$authority:$lanRelayPort/api/v1/pair/poll?id=${LanPairing.pairId(secret)}"));
          final res = await req.close().timeout(const Duration(seconds: 4));
          final text = await utf8.decoder.bind(res).join();
          if (res.statusCode == 200) {
            _complete((jsonDecode(text)["data"] as Map).cast<String, dynamic>(), host);
            return;
          }
        } catch (_) {
        } finally {
          client.close(force: true);
        }
      }
    } finally {
      _polling = false;
    }
  }
}

/// Client side: verify we can reach the phone with the pinned certificate,
/// then switch this install over to phone relay mode.
Future<void> finishClientPairing(Map<String, dynamic> payload, String? fromHost) async {
  final token = payload["token"] as String;
  final fingerprint = payload["fingerprint"] as String;
  final port = payload["port"] as int? ?? lanRelayPort;
  final addresses = <String>{if (fromHost != null) fromHost, ...(payload["addresses"] as List).cast<String>()}.toList();

  String? url;
  for (final ip in addresses) {
    final candidate = LanRelayDiscovered(ip, port, null, "").url;
    if (await LanRelayClient.pingPhone(candidate, token, fingerprint)) {
      url = candidate;
      break;
    }
  }
  if (url == null) {
    throw Exception("Paired, but couldn't reach the phone at ${addresses.join(", ")}. Make sure both devices are on the same network.");
  }

  ss.settings.serverAddress.value = url;
  ss.settings.guidAuthKey.value = token;
  ss.settings.phoneRelayFingerprint.value = fingerprint;
  ss.settings.phoneRelayName.value = payload["name"] ?? "";
  ss.settings.phoneRelayClient.value = true;
  await ss.settings.saveMany(["serverAddress", "guidAuthKey", "phoneRelayFingerprint", "phoneRelayName", "phoneRelayClient"]);
  await ss.prefs.setStringList("phoneRelayAddresses", addresses);
  // the sync managers pick their strategy from the server version; 1.2.0
  // selects the timestamp based incremental sync the phone implements
  await ss.prefs.setString("server-version", "1.2.0");
  await ss.prefs.setInt("server-version-code", 142);
  await ss.prefs.setInt("macos-version", 14);
  await ss.prefs.setInt("macos-minor-version", 0);

  backend = PhoneRelayBackend();
  // routes the relay connection state through the socket service
  socket.restartSocket();
}

/// Client side: forget the phone and go back to an unconfigured install
Future<void> unpairFromPhone() async {
  await phoneRelay.stop();
  ss.settings.phoneRelayClient.value = false;
  ss.settings.phoneRelayFingerprint.value = "";
  ss.settings.phoneRelayName.value = "";
  ss.settings.guidAuthKey.value = "";
  ss.settings.serverAddress.value = "";
  await ss.settings.saveMany(["phoneRelayClient", "phoneRelayFingerprint", "phoneRelayName", "guidAuthKey", "serverAddress"]);
  await ss.prefs.remove("phoneRelayAddresses");
}
