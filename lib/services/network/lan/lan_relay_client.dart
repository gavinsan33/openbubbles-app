import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_crypto.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_wire.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:collection/collection.dart';
import 'package:get/get.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:tuple/tuple.dart';
import 'package:universal_io/io.dart';

LanRelayClient get phoneRelay => LanRelayClient.instance;

class LanRelayDiscovered {
  final String host;
  final int port;
  final String? fingerprintPrefix;
  final String name;

  LanRelayDiscovered(this.host, this.port, this.fingerprintPrefix, this.name);

  String get url => "https://${host.contains(":") ? "[$host]" : host}:$port";
}

/// Finds phones advertising the relay over mDNS
Future<List<LanRelayDiscovered>> discoverRelayPhones({Duration timeout = const Duration(seconds: 3)}) async {
  final results = <LanRelayDiscovered>[];
  final client = MDnsClient();
  try {
    await client.start();
    final ptrs = await client
        .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer("$lanRelayServiceType.local"), timeout: timeout)
        .toList();
    for (final ptr in ptrs) {
      String? fp;
      await for (final txt in client.lookup<TxtResourceRecord>(ResourceRecordQuery.text(ptr.domainName), timeout: timeout)) {
        fp ??= RegExp(r"fp=([0-9a-f]+)").firstMatch(txt.text)?.group(1);
      }
      final name = ptr.domainName.split(".$lanRelayServiceType").first;
      await for (final srv in client.lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName), timeout: timeout)) {
        await for (final ip in client.lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target), timeout: timeout)) {
          results.add(LanRelayDiscovered(ip.address.address, srv.port, fp, name));
        }
      }
    }
  } catch (e) {
    // mDNS is best effort; avahi or a firewall can get in the way
    Logger.warn("mDNS discovery failed", error: e, tag: "LanRelay");
  } finally {
    client.stop();
  }
  return results;
}

/// HttpClient that only trusts the phone's pinned certificate
HttpClient pinnedHttpClient(String fingerprint) {
  return HttpClient(context: SecurityContext(withTrustedRoots: false))
    ..connectionTimeout = const Duration(seconds: 8)
    ..badCertificateCallback = (cert, host, port) => lanSecureEquals(lanFingerprint(cert.der), fingerprint);
}

enum LanRelayState { disconnected, connecting, connected }

/// Keeps a websocket open to the paired phone for live events, and finds the
/// phone again if its address changes.
class LanRelayClient {
  static final LanRelayClient instance = LanRelayClient._();
  LanRelayClient._();

  final Rx<LanRelayState> state = LanRelayState.disconnected.obs;
  final RxString phoneName = "".obs;
  WebSocket? _ws;
  Timer? _reconnect;
  int _failures = 0;
  bool _running = false;
  bool _rediscovering = false;
  final Map<String, Map<String, dynamic>> _lastChatState = {};

  String get _fingerprint => ss.settings.phoneRelayFingerprint.value;

  void start() {
    if (_running) return;
    _running = true;
    _connect();
  }

  Future<void> stop() async {
    _running = false;
    _reconnect?.cancel();
    await _ws?.close();
    _ws = null;
    state.value = LanRelayState.disconnected;
  }

  void reconnectNow() {
    if (!_running) return start();
    if (state.value == LanRelayState.connected) return;
    _reconnect?.cancel();
    _connect();
  }

  Future<void> _connect() async {
    if (!_running || http.origin.isEmpty) return;
    state.value = LanRelayState.connecting;
    try {
      final uri = Uri.parse(http.origin).replace(
        scheme: "wss",
        path: "/api/v1/ws",
        queryParameters: {"guid": ss.settings.guidAuthKey.value},
      );
      final ws = await WebSocket.connect(uri.toString(), customClient: pinnedHttpClient(_fingerprint))
          .timeout(const Duration(seconds: 10));
      ws.pingInterval = const Duration(seconds: 20);
      _ws = ws;
      _failures = 0;
      state.value = LanRelayState.connected;
      Logger.info("Connected to phone over LAN relay", tag: "LanRelay");
      ws.listen(_onData, onDone: _onClosed, onError: (_) => _onClosed(), cancelOnError: true);
    } catch (e) {
      Logger.warn("LAN relay connection failed", error: e, tag: "LanRelay");
      _onClosed();
    }
  }

  void _onClosed() {
    _ws = null;
    if (!_running) return;
    state.value = LanRelayState.disconnected;
    _failures++;
    _reconnect?.cancel();
    final delay = Duration(seconds: (_failures * 3).clamp(3, 30));
    _reconnect = Timer(delay, () async {
      if (_failures >= 2) await rediscover();
      _connect();
    });
  }

  /// Try the phone's other known addresses, then look for it with mDNS
  Future<bool> rediscover() async {
    if (_rediscovering) return false;
    _rediscovering = true;
    try {
      final current = http.origin;
      final candidates = <String>[
        ...(ss.prefs.getStringList("phoneRelayAddresses") ?? []).map((ip) => LanRelayDiscovered(ip, lanRelayPort, null, "").url),
      ];
      final prefix = _fingerprint.length >= 16 ? _fingerprint.substring(0, 16) : _fingerprint;
      for (final found in await discoverRelayPhones()) {
        if (found.fingerprintPrefix == null || found.fingerprintPrefix == prefix) candidates.insert(0, found.url);
      }
      for (final url in candidates.toSet()) {
        if (url == current) continue;
        if (await pingPhone(url, ss.settings.guidAuthKey.value, _fingerprint)) {
          Logger.info("Found phone at new address $url", tag: "LanRelay");
          ss.settings.serverAddress.value = url;
          await ss.settings.saveOne("serverAddress");
          return true;
        }
      }
      return false;
    } finally {
      _rediscovering = false;
    }
  }

  static Future<bool> pingPhone(String url, String token, String fingerprint) async {
    final client = pinnedHttpClient(fingerprint);
    try {
      final req = await client.getUrl(Uri.parse("$url/api/v1/ping?guid=${Uri.encodeQueryComponent(token)}"));
      final res = await req.close().timeout(const Duration(seconds: 5));
      await res.drain();
      return res.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  void send(String event, Map<String, dynamic> data) {
    try {
      _ws?.add(jsonEncode({"event": event, "data": data}));
    } catch (_) {}
  }

  Future<void> _onData(dynamic raw) async {
    try {
      final msg = (jsonDecode(raw as String) as Map).cast<String, dynamic>();
      final event = msg["event"] as String;
      final data = msg["data"] is Map ? (msg["data"] as Map).cast<String, dynamic>() : <String, dynamic>{};
      switch (event) {
        case "hello":
          phoneName.value = data["name"] ?? "";
          break;
        case "new-message":
        case "updated-message":
          if (data["handle"] is Map) _adoptHandle(Handle.fromMap((data["handle"] as Map).cast<String, dynamic>()));
          await ah.handleEvent(event, data, "LanRelay");
          break;
        case "message-deleted":
          final m = Message.findOne(guid: data["guid"]);
          if (m == null) break;
          final chat = m.chat.target;
          Message.delete(m.guid!);
          if (chat != null) ms(chat.guid).removeMessage(m);
          break;
        case "chat-updated":
          await _applyChat((data["chat"] as Map).cast<String, dynamic>(), data["iconChanged"] == true);
          break;
        case "chat-deleted":
          final c = Chat.findOne(guid: data["guid"]);
          if (c == null) break;
          chats.removeChat(c);
          Chat.deleteChat(c);
          break;
        case "typing-indicator":
          _applyTyping(data["guid"], data["address"], data["display"] == true);
          break;
        case "sync-needed":
          sync.startIncrementalSync();
          break;
      }
    } catch (e, s) {
      Logger.error("Failed to handle LAN relay event", error: e, trace: s, tag: "LanRelay");
    }
  }

  void _applyTyping(String? chatGuid, String? address, bool display) {
    final chat = chats.chats.firstWhereOrNull((c) => c.guid == chatGuid);
    if (chat == null || address == null) return;
    final controller = cvc(chat);
    final handle = chat.participants.firstWhereOrNull((h) => h.address == address) ??
        Handle.findOne(addressAndService: Tuple2(address, "iMessage"));
    if (handle == null) return;
    controller.typingIndicatorData.remove(address)?.$1.cancel();
    controller.showTypingIndicatorFor.removeWhere((h) => h.address == address);
    if (display) {
      controller.showTypingIndicatorFor.add(handle);
      final expiry = Future.delayed(const Duration(minutes: 1)).asStream().listen((_) {
        controller.showTypingIndicatorFor.removeWhere((h) => h.address == address);
        controller.typingIndicatorData.remove(address);
      });
      controller.typingIndicatorData[address] = (expiry, null);
    }
  }

  void _adoptHandle(Handle h) {
    final existing = Handle.findOne(addressAndService: Tuple2(h.address, h.service));
    if (existing != null && existing.originalROWID != h.originalROWID) h.save();
  }

  /// Applies chat state from the phone. Archive and mute are only copied when
  /// they change on the phone, so a choice made on this computer is not
  /// undone by the next unrelated update.
  Future<void> _applyChat(Map<String, dynamic> wire, bool iconChanged) async {
    final remote = Chat.fromMap(wire);
    final previous = _lastChatState[remote.guid];
    final current = {
      "hasUnreadMessage": remote.hasUnreadMessage,
      "isArchived": remote.isArchived,
      "muteType": remote.muteType,
      "displayName": remote.displayName,
      "dateDeleted": remote.dateDeleted?.millisecondsSinceEpoch,
    };
    _lastChatState[remote.guid] = current;
    bool changed(String key) => previous == null ? false : previous[key] != current[key];

    // messages refer to senders by the phone's handle IDs, so a handle this
    // computer created itself (e.g. starting a new chat) has to adopt them
    remote.participants.forEach(_adoptHandle);

    var local = Chat.findOne(guid: remote.guid);
    if (local == null) {
      local = await cm.fetchChat(remote.guid);
      if (local == null) return;
      await chats.addChat(local);
    } else {
      final localAddresses = local.participants.map((h) => h.address).toSet();
      final remoteAddresses = remote.participants.map((h) => h.address).toSet();
      if (!const SetEquality().equals(localAddresses, remoteAddresses)) {
        local = await cm.fetchChat(remote.guid) ?? local;
      }
      if (!local.lockChatName && local.displayName != remote.displayName) {
        local.displayName = remote.displayName;
        local = local.save(updateDisplayName: true);
      }
      if (local.hasUnreadMessage != remote.hasUnreadMessage) {
        local = local.toggleHasUnread(remote.hasUnreadMessage!, privateMark: false);
      }
      if (changed("isArchived") && local.isArchived != remote.isArchived) {
        local = local.toggleArchived(remote.isArchived!);
      }
      if (changed("muteType")) {
        local.muteType = remote.muteType;
        local.muteArgs = remote.muteArgs;
        local = local.save(updateMuteType: true, updateMuteArgs: true);
      }
      if (local.dateDeleted?.millisecondsSinceEpoch != remote.dateDeleted?.millisecondsSinceEpoch) {
        if (remote.dateDeleted != null) {
          local.dateDeleted = remote.dateDeleted;
          local = local.save(updateDateDeleted: true);
          chats.removeChat(local);
        } else {
          Chat.unDelete(local);
          await chats.addChat(local);
        }
      }
      chats.updateChat(local);
    }
    final hasIcon = wire["hasCustomIcon"] == true;
    if (iconChanged || (hasIcon && local.customAvatarPath == null) || (!hasIcon && local.customAvatarPath != null)) {
      await Chat.getIcon(local, force: true);
    }
  }

  /// Pulls icons for every group chat that has one, after a full sync
  Future<void> syncChatIcons() async {
    final response = await http.dio.get("${http.apiRoot}/lan/icons", queryParameters: http.buildQueryParams());
    if (response.statusCode != 200) return;
    for (final guid in (response.data["data"] as List).cast<String>()) {
      final chat = Chat.findOne(guid: guid);
      if (chat != null) await Chat.getIcon(chat, force: true);
    }
  }

  /// Contacts come from the phone's address book
  Future<List<Contact>> fetchContacts() async {
    final response = await http.contacts(withAvatars: true);
    if (response.statusCode != 200) return [];
    return (response.data["data"] as List).map((e) {
      final m = (e as Map).cast<String, dynamic>();
      return Contact(
        id: m["id"],
        displayName: m["displayName"] ?? "",
        phones: (m["phoneNumbers"] as List? ?? []).cast<String>(),
        emails: (m["emails"] as List? ?? []).cast<String>(),
        structuredName: m["structuredName"] == null ? null : StructuredName.fromMap(m["structuredName"].cast<String, dynamic>()),
        avatar: m["avatar"] == null ? null : base64Decode(m["avatar"]),
      );
    }).toList();
  }
}
