import 'dart:convert';

import 'package:bluebubbles/services/network/lan/lan_relay_crypto.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:universal_io/io.dart';

class LanRelayClientInfo {
  final String id;
  final String name;
  final String tokenHash;
  final int created;

  LanRelayClientInfo({required this.id, required this.name, required this.tokenHash, required this.created});

  Map<String, dynamic> toMap() => {"id": id, "name": name, "tokenHash": tokenHash, "created": created};

  factory LanRelayClientInfo.fromMap(Map<String, dynamic> m) =>
      LanRelayClientInfo(id: m["id"], name: m["name"], tokenHash: m["tokenHash"], created: m["created"] ?? 0);
}

/// File-backed state for the phone side of the relay. Both the UI engine and
/// the headless engine can host the server, so state lives on disk instead of
/// in memory, and is re-read whenever the file changes.
class LanRelayStore {
  static final LanRelayStore instance = LanRelayStore._();
  LanRelayStore._();

  Directory get _dir => Directory("${fs.appDocDir.path}/lan_relay");
  File get _identityFile => File("${_dir.path}/identity.json");
  File get _clientsFile => File("${_dir.path}/clients.json");
  File get _pendingFile => File("${_dir.path}/pending.json");

  LanCertificate? _identity;
  Future<LanCertificate>? _generating;
  List<LanRelayClientInfo> _clients = [];
  DateTime? _clientsMtime;

  static String hashToken(String token) => sha256.convert(utf8.encode(token)).toString();

  Future<LanCertificate> identity() async {
    if (_identity != null) return _identity!;
    if (await _identityFile.exists()) {
      try {
        _identity = LanCertificate.fromMap(jsonDecode(await _identityFile.readAsString()));
        return _identity!;
      } catch (_) {}
    }
    // only generate once even if called concurrently
    _generating ??= () async {
      final cert = await generateLanCertificate("OpenBubbles LAN Relay");
      await _dir.create(recursive: true);
      await _identityFile.writeAsString(jsonEncode(cert.toMap()));
      _identity = cert;
      return cert;
    }();
    return _generating!;
  }

  List<LanRelayClientInfo> clients() {
    try {
      if (!_clientsFile.existsSync()) {
        _clients = [];
        _clientsMtime = null;
        return _clients;
      }
      final mtime = _clientsFile.lastModifiedSync();
      if (_clientsMtime != mtime) {
        _clients = (jsonDecode(_clientsFile.readAsStringSync()) as List)
            .map((e) => LanRelayClientInfo.fromMap(e.cast<String, dynamic>()))
            .toList();
        _clientsMtime = mtime;
      }
    } catch (_) {}
    return _clients;
  }

  LanRelayClientInfo? clientForToken(String? token) {
    if (token == null || token.isEmpty) return null;
    final hash = hashToken(token);
    return clients().firstWhereOrNull((c) => lanSecureEquals(c.tokenHash, hash));
  }

  Future<void> _writeClients(List<LanRelayClientInfo> list) async {
    await _dir.create(recursive: true);
    await _clientsFile.writeAsString(jsonEncode(list.map((e) => e.toMap()).toList()));
    _clientsMtime = null;
  }

  /// Registers a new client and returns the bearer token it should use
  Future<String> addClient(String name) async {
    final token = lanRandomToken();
    final list = List<LanRelayClientInfo>.from(clients())
      ..add(LanRelayClientInfo(
        id: lanRandomToken(8),
        name: name,
        tokenHash: hashToken(token),
        created: DateTime.now().millisecondsSinceEpoch,
      ));
    await _writeClients(list);
    return token;
  }

  Future<void> renameClient(String id, String name) async {
    await _writeClients(clients()
        .map((c) => c.id == id ? LanRelayClientInfo(id: c.id, name: name, tokenHash: c.tokenHash, created: c.created) : c)
        .toList());
  }

  Future<void> removeClient(String id) async {
    await _writeClients(clients().where((c) => c.id != id).toList());
  }

  /// Pairing results waiting for a client that polls instead of listening
  Future<void> savePending(String pairId, Map<String, dynamic> payload) async {
    final pending = _readPending()..[pairId] = {
      "payload": payload,
      "expires": DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch,
    };
    await _dir.create(recursive: true);
    await _pendingFile.writeAsString(jsonEncode(pending));
  }

  /// Not removed on read: anyone can poll, but only the holder of the pairing
  /// secret can open the payload, so letting it expire avoids a poller
  /// burning someone else's pairing
  Map<String, dynamic>? peekPending(String pairId) {
    final entry = _readPending()[pairId];
    if (entry == null) return null;
    return (entry["payload"] as Map).cast<String, dynamic>();
  }

  Map<String, dynamic> _readPending() {
    try {
      if (!_pendingFile.existsSync()) return {};
      final now = DateTime.now().millisecondsSinceEpoch;
      final map = (jsonDecode(_pendingFile.readAsStringSync()) as Map).cast<String, dynamic>();
      map.removeWhere((key, value) => (value["expires"] as int) < now);
      return map;
    } catch (_) {
      return {};
    }
  }
}
