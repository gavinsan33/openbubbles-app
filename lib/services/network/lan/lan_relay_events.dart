import 'dart:ui' show IsolateNameServer;

import 'package:flutter/foundation.dart';
import 'package:universal_io/io.dart';

/// Name of the port the isolate hosting the LAN relay server listens on.
/// Database writes can happen in any engine or isolate (the UI engine, the
/// headless DartWorker engine, sync isolates), so they report changes here
/// and the server isolate turns them into events for paired clients.
const lanRelayEventPortName = "lan_relay_events";

class LanRelayEvents {
  @visibleForTesting
  static bool forceEnabled = false;

  static bool get _canServe => forceEnabled || (!kIsWeb && Platform.isAndroid);

  static void _send(Map<String, dynamic> event) {
    if (!_canServe) return;
    final port = IsolateNameServer.lookupPortByName(lanRelayEventPortName);
    port?.send(event);
  }

  static bool _isTemp(String? guid) => guid == null || guid.startsWith("temp") || guid.startsWith("error");

  static void messageSaved(String? guid, {bool isNew = false}) {
    if (_isTemp(guid)) return;
    _send({"kind": "message", "guid": guid, "isNew": isNew});
  }

  static void messagesSaved(Iterable<String?> guids) {
    final list = guids.where((g) => !_isTemp(g)).toList();
    if (list.isEmpty) return;
    _send({"kind": "messages", "guids": list});
  }

  static void messageDeleted(String guid) {
    if (_isTemp(guid)) return;
    _send({"kind": "message-deleted", "guid": guid});
  }

  static void chatSaved(String guid, {bool iconChanged = false}) {
    _send({"kind": "chat", "guid": guid, "iconChanged": iconChanged});
  }

  static void chatDeleted(String guid) {
    _send({"kind": "chat-deleted", "guid": guid});
  }

  static void typing(String chatGuid, String address, bool display) {
    _send({"kind": "typing", "chatGuid": chatGuid, "address": address, "display": display});
  }
}
