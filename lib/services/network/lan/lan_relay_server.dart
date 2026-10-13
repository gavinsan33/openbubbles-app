import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_api.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_events.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_store.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_wire.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:universal_io/io.dart';

LanRelayServer get lanRelay => LanRelayServer.instance;

class LanRelayPeer {
  final WebSocket ws;
  final LanRelayClientInfo client;

  LanRelayPeer(this.ws, this.client);
}

/// Serves paired computers from this phone over the local network.
///
/// On Android the server can live in the UI engine or in the headless
/// DartWorker engine, whichever is alive. Only one can bind the port; the
/// other keeps retrying so the server moves over when an engine goes away.
/// Database writes from any engine reach the server through
/// [LanRelayEvents], and are fanned out to connected clients.
class LanRelayServer {
  static final LanRelayServer instance = LanRelayServer._();
  LanRelayServer._();

  HttpServer? _server;
  ReceivePort? _events;
  Timer? _retry;
  Timer? _watchdog;
  Timer? _flushTimer;
  bool _starting = false;
  late final LanRelayApi _api = LanRelayApi(this);

  final List<LanRelayPeer> peers = [];
  final RxInt connectedCount = 0.obs;

  final Map<String, bool> _pendingMessages = {};
  final Map<String, bool> _pendingChats = {};
  final Set<String> _pendingMessageDeletes = {};
  final Set<String> _pendingChatDeletes = {};

  bool get isRunning => _server != null;

  @visibleForTesting
  static bool forceSupported = false;

  static bool get supported => forceSupported || (!kIsWeb && Platform.isAndroid);

  /// Settings live in shared prefs, which another engine may have changed
  static Future<bool> enabledInPrefs() async {
    await ss.prefs.reload();
    return ss.prefs.getBool("lanRelayEnabled") ?? false;
  }

  Future<void> ensureRunning() async {
    if (!supported) return;
    if (!await enabledInPrefs()) {
      await stop();
      return;
    }
    if (_server != null || _starting) return;
    _starting = true;
    try {
      final identity = await LanRelayStore.instance.identity();
      final context = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(identity.certPem))
        ..usePrivateKeyBytes(utf8.encode(identity.keyPem));
      try {
        _server = await HttpServer.bindSecure(InternetAddress.anyIPv6, lanRelayPort, context, v6Only: false);
      } on SocketException catch (e) {
        // usually means the other engine is already serving
        Logger.info("LAN relay port unavailable, will retry: ${e.message}", tag: "LanRelay");
        _scheduleRetry();
        return;
      }
      _retry?.cancel();
      _retry = null;
      _server!.listen(_handleRequest, onError: (e, s) => Logger.warn("LAN relay server error", error: e, trace: s, tag: "LanRelay"));
      _listenForEvents();
      _watchdog = Timer.periodic(const Duration(seconds: 5), (_) => _checkStillWanted());
      await _advertise(identity.fingerprint);
      Logger.info("LAN relay listening on port $lanRelayPort", tag: "LanRelay");
    } catch (e, s) {
      Logger.error("Failed to start LAN relay", error: e, trace: s, tag: "LanRelay");
      _scheduleRetry();
    } finally {
      _starting = false;
    }
  }

  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 15), ensureRunning);
  }

  /// The relay can be turned off, or a computer unpaired, from the other
  /// engine, so the serving engine checks for itself
  Future<void> _checkStillWanted() async {
    if (!await enabledInPrefs()) {
      await stop();
      return;
    }
    final paired = LanRelayStore.instance.clients().map((c) => c.id).toSet();
    for (final peer in peers.where((p) => !paired.contains(p.client.id)).toList()) {
      await peer.ws.close(WebSocketStatus.policyViolation, "unpaired");
    }
  }

  Future<void> stop() async {
    _retry?.cancel();
    _retry = null;
    _watchdog?.cancel();
    _watchdog = null;
    if (_server == null) return;
    for (final peer in List<LanRelayPeer>.from(peers)) {
      await peer.ws.close(WebSocketStatus.goingAway);
    }
    peers.clear();
    connectedCount.value = 0;
    await _server?.close(force: true);
    _server = null;
    if (_events != null) {
      if (IsolateNameServer.lookupPortByName(lanRelayEventPortName) == _events!.sendPort) {
        IsolateNameServer.removePortNameMapping(lanRelayEventPortName);
      }
      _events!.close();
      _events = null;
    }
    try {
      await mcs.invokeMethod("lan-relay-nsd", {"enable": false});
    } catch (_) {}
    Logger.info("LAN relay stopped", tag: "LanRelay");
  }

  /// Disconnect a client that was just unpaired
  Future<void> kick(String clientId) async {
    for (final peer in peers.where((p) => p.client.id == clientId).toList()) {
      await peer.ws.close(WebSocketStatus.policyViolation, "unpaired");
    }
  }

  static Future<String> deviceName() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return "${info.manufacturer.capitalizeFirst} ${info.model}".trim();
    } catch (_) {
      return "Android phone";
    }
  }

  Future<void> _advertise(String fingerprint) async {
    try {
      await mcs.invokeMethod("lan-relay-nsd", {
        "enable": true,
        "port": lanRelayPort,
        "name": "OpenBubbles ${await deviceName()}",
        "fp": fingerprint.substring(0, 16),
      });
    } catch (e) {
      Logger.warn("Failed to advertise LAN relay", error: e, tag: "LanRelay");
    }
  }

  /// IPv4 addresses clients can try, private LAN ranges first
  static Future<List<String>> localAddresses() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    final addresses = interfaces.expand((i) => i.addresses).map((a) => a.address).toSet().toList();
    int rank(String ip) {
      if (ip.startsWith("192.168.") || ip.startsWith("10.")) return 0;
      if (RegExp(r"^172\.(1[6-9]|2\d|3[01])\.").hasMatch(ip)) return 0;
      if (ip.startsWith("100.")) return 1; // CGNAT, often Tailscale
      return 2;
    }
    addresses.sort((a, b) => rank(a).compareTo(rank(b)));
    return addresses;
  }

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      final segments = req.uri.pathSegments;
      if (segments.length < 2 || segments[0] != "api" || segments[1] != "v1") {
        return await LanRelayApi.error(req, 404, "Not found");
      }
      final rest = segments.sublist(2);

      // the pairing result is sealed with a secret only the client knows
      if (rest.length == 2 && rest[0] == "pair" && rest[1] == "poll") {
        final payload = LanRelayStore.instance.peekPending(req.uri.queryParameters["id"] ?? "");
        if (payload == null) return await LanRelayApi.error(req, 404, "No pending pairing");
        return await LanRelayApi.json(req, payload);
      }

      final auth = req.headers.value(HttpHeaders.authorizationHeader);
      final token = req.uri.queryParameters["guid"] ?? (auth?.startsWith("Bearer ") == true ? auth!.substring(7) : null);
      final client = LanRelayStore.instance.clientForToken(token);
      if (client == null) {
        return await LanRelayApi.error(req, 401, "Not paired with this phone");
      }

      if (rest.length == 1 && rest[0] == "ws") {
        return await _upgrade(req, client);
      }
      await _api.handle(req, rest, client);
    } catch (e, s) {
      Logger.error("LAN relay request failed: ${req.method} ${req.uri.path}", error: e, trace: s, tag: "LanRelay");
      try {
        await LanRelayApi.error(req, e is LanRelayError ? e.status : 500, e is LanRelayError ? e.message : e.toString());
      } catch (_) {}
    }
  }

  Future<void> _upgrade(HttpRequest req, LanRelayClientInfo client) async {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      return await LanRelayApi.error(req, 400, "Expected a websocket upgrade");
    }
    final ws = await WebSocketTransformer.upgrade(req);
    ws.pingInterval = const Duration(seconds: 20);
    final peer = LanRelayPeer(ws, client);
    peers.add(peer);
    connectedCount.value = peers.length;
    Logger.info("LAN relay client connected: ${client.name}", tag: "LanRelay");
    ws.add(jsonEncode({"event": "hello", "data": {"protocol": lanRelayProtocolVersion, "name": await deviceName()}}));
    ws.listen(
      (data) => _onPeerMessage(peer, data),
      onDone: () => _dropPeer(peer),
      onError: (_) => _dropPeer(peer),
      cancelOnError: true,
    );
  }

  void _dropPeer(LanRelayPeer peer) {
    if (peers.remove(peer)) {
      connectedCount.value = peers.length;
      Logger.info("LAN relay client disconnected: ${peer.client.name}", tag: "LanRelay");
    }
  }

  void _onPeerMessage(LanRelayPeer peer, dynamic data) {
    try {
      final msg = (jsonDecode(data as String) as Map).cast<String, dynamic>();
      final chat = Chat.findOne(guid: msg["data"]?["chatGuid"]);
      if (chat == null) return;
      switch (msg["event"]) {
        case "started-typing":
          backend.startedTyping(chat);
          break;
        case "stopped-typing":
          backend.stoppedTyping(chat);
          break;
      }
    } catch (e) {
      Logger.warn("Bad message from LAN relay client", error: e, tag: "LanRelay");
    }
  }

  void broadcast(String event, dynamic data) {
    if (peers.isEmpty) return;
    final encoded = jsonEncode({"event": event, "data": data}, toEncodable: LanRelayApi.toEncodable);
    for (final peer in List<LanRelayPeer>.from(peers)) {
      try {
        peer.ws.add(encoded);
      } catch (_) {
        _dropPeer(peer);
      }
    }
  }

  void _listenForEvents() {
    _events?.close();
    _events = ReceivePort();
    IsolateNameServer.removePortNameMapping(lanRelayEventPortName);
    IsolateNameServer.registerPortWithName(_events!.sendPort, lanRelayEventPortName);
    _events!.listen((e) {
      if (e is Map) _onDbEvent(e.cast<String, dynamic>());
    });
  }

  void _onDbEvent(Map<String, dynamic> e) {
    // nobody to tell; clients catch up with an incremental sync on connect
    if (peers.isEmpty) return;
    switch (e["kind"]) {
      case "message":
        _pendingMessages[e["guid"]] = (_pendingMessages[e["guid"]] ?? false) || e["isNew"] == true;
        break;
      case "messages":
        for (final guid in (e["guids"] as List).cast<String>()) {
          _pendingMessages.putIfAbsent(guid, () => false);
        }
        break;
      case "message-deleted":
        _pendingMessageDeletes.add(e["guid"]);
        break;
      case "chat":
        _pendingChats[e["guid"]] = (_pendingChats[e["guid"]] ?? false) || e["iconChanged"] == true;
        break;
      case "chat-deleted":
        _pendingChatDeletes.add(e["guid"]);
        break;
      case "typing":
        broadcast("typing-indicator", {"guid": e["chatGuid"], "address": e["address"], "display": e["display"]});
        return;
    }
    // saves come in bursts (a message save also saves its chat), so coalesce
    _flushTimer ??= Timer(const Duration(milliseconds: 150), _flush);
  }

  void _flush() {
    _flushTimer = null;
    final messages = Map<String, bool>.from(_pendingMessages);
    final chats = Map<String, bool>.from(_pendingChats);
    final messageDeletes = Set<String>.from(_pendingMessageDeletes);
    final chatDeletes = Set<String>.from(_pendingChatDeletes);
    _pendingMessages.clear();
    _pendingChats.clear();
    _pendingMessageDeletes.clear();
    _pendingChatDeletes.clear();

    try {
      if (messages.length > 250) {
        // a cloud sync or similar; cheaper for clients to pull it
        broadcast("sync-needed", {});
      } else {
        for (final entry in messages.entries) {
          final m = Message.findOne(guid: entry.key);
          if (m == null) continue;
          broadcast(entry.value ? "new-message" : "updated-message", messageToWire(m, withChats: true));
        }
      }
      for (final guid in messageDeletes) {
        broadcast("message-deleted", {"guid": guid});
      }
      for (final entry in chats.entries) {
        final c = Chat.findOne(guid: entry.key);
        if (c == null) continue;
        broadcast("chat-updated", {"chat": chatToWire(c), "iconChanged": entry.value});
      }
      for (final guid in chatDeletes) {
        broadcast("chat-deleted", {"guid": guid});
      }
    } catch (e, s) {
      Logger.error("Failed to push LAN relay events", error: e, trace: s, tag: "LanRelay");
    }
  }
}
