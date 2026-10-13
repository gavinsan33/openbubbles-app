import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_crypto.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_server.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_store.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_wire.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:mime_type/mime_type.dart';
import 'package:path/path.dart';
import 'package:universal_io/io.dart';

class LanRelayError implements Exception {
  final int status;
  final String message;

  LanRelayError(this.status, this.message);

  @override
  String toString() => message;
}

/// REST endpoints for paired clients. The read endpoints follow the shapes of
/// the BlueBubbles server API so the existing sync managers work unchanged.
/// Actions go through /lan/rpc/<method>, which mirrors [BackendService] and
/// applies each action to the phone's database the same way the phone's own
/// UI would, so the phone stays the source of truth.
class LanRelayApi {
  final LanRelayServer server;
  final Map<String, File> _uploads = {};

  LanRelayApi(this.server);

  /// In the headless engine the push state may still be loading
  @visibleForTesting
  static Future<void> Function() waitForBackend = () async => await pushService.initFuture;

  static Object? toEncodable(Object? o) {
    if (o is DateTime) return o.millisecondsSinceEpoch;
    if (o is Uint8List) return base64.encode(o);
    return o.toString();
  }

  static Future<void> json(HttpRequest req, dynamic data, {Map<String, dynamic>? metadata}) async {
    final res = req.response;
    res.statusCode = 200;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode({
      "status": 200,
      "message": "Success",
      "data": data,
      if (metadata != null) "metadata": metadata,
    }, toEncodable: toEncodable));
    await res.close();
  }

  static Future<void> error(HttpRequest req, int status, String message) async {
    final res = req.response;
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode({
      "status": status,
      "message": message,
      "error": {"type": "Error", "message": message},
    }));
    await res.close();
  }

  static Future<void> file(HttpRequest req, File f, {String? mimeType}) async {
    final res = req.response;
    res.statusCode = 200;
    res.headers.contentType = ContentType.parse(mimeType ?? mime(f.path) ?? "application/octet-stream");
    res.contentLength = await f.length();
    await res.addStream(f.openRead());
    await res.close();
  }

  static Future<Map<String, dynamic>> body(HttpRequest req) async {
    final text = await utf8.decoder.bind(req).join();
    if (text.isEmpty) return {};
    return (jsonDecode(text) as Map).cast<String, dynamic>();
  }

  static List<String> _with(dynamic w) {
    if (w is List) return w.map((e) => e.toString().toLowerCase()).toList();
    if (w is String) return w.toLowerCase().split(",").map((e) => e.trim()).toList();
    return [];
  }

  static int? _int(dynamic v) => v is int ? v : int.tryParse(v?.toString() ?? "");

  Chat _chat(String? guid) => Chat.findOne(guid: guid) ?? (throw LanRelayError(404, "Chat not found"));

  Message _message(String? guid) => Message.findOne(guid: guid) ?? (throw LanRelayError(404, "Message not found"));

  Future<void> handle(HttpRequest req, List<String> path, LanRelayClientInfo client) async {
    await waitForBackend();
    final q = req.uri.queryParameters;
    final method = req.method;
    final p0 = path.firstOrNull;
    final p1 = path.length > 1 ? path[1] : null;
    final p2 = path.length > 2 ? path[2] : null;

    switch (p0) {
      case "ping":
        return json(req, "pong");
      case "server":
        if (p1 == "info") {
          return json(req, {
            "os_version": "14.0",
            "server_version": "1.2.0",
            "private_api": true,
            "proxy_service": "lan-relay",
            "detected_icloud": ss.settings.iCloudAccount.value,
            "lan_relay_protocol": lanRelayProtocolVersion,
            "name": await LanRelayServer.deviceName(),
          });
        }
        break;
      case "chat":
        if (p1 == "count") return json(req, {"total": Chat.count() ?? 0});
        if (p1 == "query" && method == "POST") return _chatQuery(req, await body(req));
        if (p1 != null && p2 == null && method == "GET") {
          return json(req, chatToWire(_chat(p1), withLastMessage: _with(q["with"]).contains("lastmessage")));
        }
        if (p1 != null && p2 == "message") return _chatMessages(req, _chat(p1), q);
        if (p1 != null && p2 == "icon") {
          final path = _chat(p1).customAvatarPath;
          if (path == null || !await File(path).exists()) throw LanRelayError(404, "No icon");
          return file(req, File(path));
        }
        break;
      case "message":
        if (p1 == "count") {
          return json(req, {"total": _messageQuery(after: _int(q["after"]), before: _int(q["before"]), includeUpdated: true).count()});
        }
        if (p1 == "query" && method == "POST") return _messageSearch(req, await body(req));
        if (p1 != null && p2 == null) {
          final w = _with(q["with"]);
          return json(req, messageToWire(_message(p1), withChats: w.any((e) => e.startsWith("chat"))));
        }
        break;
      case "handle":
        if (p1 == "count") return json(req, {"total": Database.handles.count()});
        if (p1 == "query" && method == "POST") {
          final b = await body(req);
          var handles = Database.handles.getAll();
          if (b["address"] != null) handles = handles.where((h) => h.address == b["address"]).toList();
          final offset = _int(b["offset"]) ?? 0;
          final limit = _int(b["limit"]) ?? 100;
          return json(req, handles.skip(offset).take(limit).map(handleToWire).toList(), metadata: {"total": handles.length});
        }
        if (p1 != null && p2 == null) {
          final h = Database.handles.getAll().firstWhereOrNull((h) => h.address == p1) ?? (throw LanRelayError(404, "Handle not found"));
          return json(req, handleToWire(h));
        }
        break;
      case "contact":
        final withAvatars = q["extraProperties"]?.contains("avatar") ?? false;
        return json(req, Contact.getContacts().map((c) {
          final map = c.toMap();
          map.remove("dbId");
          if (!withAvatars) map.remove("avatar");
          return map;
        }).toList());
      case "attachment":
        if (p1 == "count") return json(req, {"total": Database.attachments.count()});
        if (p1 == null) break;
        final att = Attachment.findOne(p1) ?? (throw LanRelayError(404, "Attachment not found"));
        if (p2 == null) return json(req, attachmentToWire(att));
        if (p2 == "download") return _downloadAttachment(req, att);
        if (p2 == "live") return _downloadLivePhoto(req, att);
        break;
      case "lan":
        if (p1 == "icons") {
          final query = Database.chats.query(Chat_.customAvatarPath.notNull()).build();
          final guids = query.find().map((c) => c.guid).toList();
          query.close();
          return json(req, guids);
        }
        if (p1 == "upload" && method == "POST") return _upload(req);
        if (p1 == "rpc" && p2 != null && method == "POST") {
          final result = await rpc(p2, await body(req));
          return json(req, result);
        }
        break;
    }
    throw LanRelayError(404, "Unknown endpoint ${req.method} ${req.uri.path}");
  }

  Future<void> _chatQuery(HttpRequest req, Map<String, dynamic> b) async {
    final offset = _int(b["offset"]) ?? 0;
    final limit = _int(b["limit"]) ?? 100;
    final withLast = _with(b["with"]).contains("lastmessage");
    final query = (Database.chats.query()..order(Chat_.dbOnlyLatestMessageDate, flags: Order.descending)).build()
      ..offset = offset
      ..limit = limit;
    final results = query.find();
    query.close();
    return json(req, results.map((c) => chatToWire(c, withLastMessage: withLast)).toList(),
        metadata: {"total": Chat.count() ?? 0, "offset": offset, "limit": limit});
  }

  Query<Message> _messageQuery({Chat? chat, int? after, int? before, int? afterRowId, int? beforeRowId, bool includeUpdated = false, bool asc = false}) {
    Condition<Message> cond = Message_.dateCreated.notNull();
    if (after != null) {
      Condition<Message> a = Message_.dateCreated.greaterThan(after);
      if (includeUpdated) {
        // catch edits, receipts and deletions of older messages too
        a = a
            .or(Message_.dateEdited.greaterThan(after))
            .or(Message_.dateDelivered.greaterThan(after))
            .or(Message_.dateRead.greaterThan(after))
            .or(Message_.dateDeleted.greaterThan(after));
      }
      cond = cond.and(a);
    }
    if (before != null) cond = cond.and(Message_.dateCreated.lessThan(before));
    if (afterRowId != null) cond = cond.and(Message_.id.greaterThan(afterRowId));
    if (beforeRowId != null) cond = cond.and(Message_.id.lessOrEqual(beforeRowId));
    final builder = Database.messages.query(cond);
    if (chat != null) builder.link(Message_.chat, Chat_.id.equals(chat.id!));
    builder.order(Message_.dateCreated, flags: asc ? 0 : Order.descending);
    return builder.build();
  }

  Future<void> _chatMessages(HttpRequest req, Chat chat, Map<String, String> q) async {
    final offset = _int(q["offset"]) ?? 0;
    final limit = _int(q["limit"]) ?? 100;
    final query = _messageQuery(
      chat: chat,
      after: _int(q["after"]),
      before: _int(q["before"]),
      asc: q["sort"]?.toUpperCase() == "ASC",
    )
      ..offset = offset
      ..limit = limit;
    final messages = query.find();
    query.close();
    return json(req, messages.map((m) => messageToWire(m, chat: chat)).toList());
  }

  Future<void> _messageSearch(HttpRequest req, Map<String, dynamic> b) async {
    final offset = _int(b["offset"]) ?? 0;
    final limit = _int(b["limit"]) ?? 100;
    int? afterRowId;
    int? beforeRowId;
    for (final w in (b["where"] as List? ?? [])) {
      final statement = w["statement"]?.toString() ?? "";
      final args = (w["args"] as Map?) ?? {};
      if (statement.contains("ROWID >")) afterRowId = _int(args.values.firstOrNull);
      if (statement.contains("ROWID <=")) beforeRowId = _int(args.values.firstOrNull);
    }
    final withQuery = _with(b["with"]);
    final query = _messageQuery(
      chat: b["chatGuid"] == null ? null : _chat(b["chatGuid"]),
      after: _int(b["after"]),
      before: _int(b["before"]),
      afterRowId: afterRowId,
      beforeRowId: beforeRowId,
      includeUpdated: true,
      asc: b["sort"]?.toString().toUpperCase() == "ASC",
    );
    final total = query.count();
    query
      ..offset = offset
      ..limit = limit;
    final messages = query.find();
    query.close();
    final withChats = withQuery.any((e) => e.startsWith("chat"));
    return json(req, messages.map((m) => messageToWire(m, withChats: withChats)).toList(),
        metadata: {"total": total, "offset": offset, "limit": limit});
  }

  Future<void> _downloadAttachment(HttpRequest req, Attachment att) async {
    if (!await File(att.path).exists()) {
      // not downloaded from Apple on the phone yet
      await backend.downloadAttachment(att);
    }
    final f = File(att.path);
    if (!await f.exists()) throw LanRelayError(404, "Attachment is not available");
    return file(req, f, mimeType: att.mimeType);
  }

  Future<void> _downloadLivePhoto(HttpRequest req, Attachment att) async {
    if (att.metadata?["myIris"] == null) throw LanRelayError(404, "Not a live photo");
    final temp = File("${att.directory}/relay-live-${lanRandomToken(6)}.mov");
    try {
      final rustAttachment = api.restoreAttachment(data: att.metadata!["myIris"]);
      await for (final _ in api.downloadAttachment(aps: pushService.state!.conn, attachment: rustAttachment, path: temp.path)) {}
      return await file(req, temp, mimeType: "video/quicktime");
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<void> _upload(HttpRequest req) async {
    final id = lanRandomToken(12);
    final dir = Directory("${fs.appDocDir.path}/lan_relay/uploads");
    await dir.create(recursive: true);
    final f = File("${dir.path}/$id");
    final sink = f.openWrite();
    await sink.addStream(req);
    await sink.close();
    _uploads[id] = f;
    // uploads are claimed by the rpc call that follows; drop forgotten ones
    Timer(const Duration(minutes: 30), () async {
      _uploads.remove(id);
      if (await f.exists()) await f.delete();
    });
    return json(req, {"uploadId": id});
  }

  File _claimUpload(String? id) {
    final f = _uploads.remove(id);
    if (f == null) throw LanRelayError(400, "Unknown upload");
    return f;
  }

  Future<Message> _persistOutgoing(Chat chat, String tempGuid, Message result, {Message? existing}) async {
    await ah.matchMessageWithExisting(chat, tempGuid, result, existing: existing);
    return Message.findOne(guid: result.guid) ?? result;
  }

  Future<dynamic> rpc(String method, Map<String, dynamic> a) async {
    Logger.info("LAN relay rpc $method", tag: "LanRelay");
    switch (method) {
      case "createChat":
        final c = await backend.createChat(
          (a["addresses"] as List).cast<String>(),
          a["message"] == null ? null : AttributedBody.fromMap(a["message"].cast<String, dynamic>()),
          a["service"],
          existingGuid: a["existingGuid"],
        );
        return chatToWire(Chat.findOne(guid: c.guid) ?? c, withLastMessage: true);

      case "sendMessage":
        final chat = _chat(a["chatGuid"]);
        final m = Message.fromMap(a["message"].cast<String, dynamic>());
        final tempGuid = m.guid!;
        await chat.addMessage(m);
        try {
          final result = await backend.sendMessage(chat, m).timeout(const Duration(minutes: 5));
          return messageToWire(await _persistOutgoing(chat, tempGuid, result, existing: m));
        } catch (e) {
          await Message.replaceMessage(tempGuid, handleSendError(e, m));
          rethrow;
        }

      case "sendTapback":
        final chat = _chat(a["chatGuid"]);
        final selected = _message(a["selectedGuid"]);
        final result = await backend.sendTapback(chat, selected, a["reaction"], _int(a["repPart"]));
        if (Message.findOne(guid: result.guid) == null) await chat.addMessage(result);
        return messageToWire(Message.findOne(guid: result.guid) ?? result);

      case "sendAttachment":
        final chat = _chat(a["chatGuid"]);
        final m = Message.fromMap(a["message"].cast<String, dynamic>());
        final tempGuid = m.guid!;
        final att = m.attachments.first!;
        final root = canonicalize("${fs.appDocDir.path}/attachments");
        final directory = "$root/${att.guid}";
        final target = "$directory/${att.transferName}";
        if (!canonicalize(directory).startsWith("$root/") || !canonicalize(target).startsWith("${canonicalize(directory)}/")) {
          throw LanRelayError(400, "Bad attachment name");
        }
        await Directory(directory).create(recursive: true);
        await _claimUpload(a["uploadId"]).rename(target);
        att.totalBytes = await File(target).length();
        await chat.addMessage(m);
        try {
          final result = await backend.sendAttachment(chat, m, a["isAudio"] == true, att);
          for (final newAtt in result.attachments.whereType<Attachment>()) {
            await ah.matchAttachmentWithExisting(chat, tempGuid, newAtt, existing: att);
          }
          return messageToWire(await _persistOutgoing(chat, tempGuid, result, existing: m));
        } catch (e) {
          await Message.replaceMessage(tempGuid, handleSendError(e, m));
          rethrow;
        }

      case "markRead":
        final chat = _chat(a["chatGuid"]);
        chat.toggleHasUnread(false, privateMark: false);
        return await backend.markRead(chat, a["notifyOthers"] == true);

      case "markUnread":
        final chat = _chat(a["chatGuid"]);
        chat.toggleHasUnread(true, privateMark: false, force: true);
        return await backend.markUnread(chat);

      case "renameChat":
        return await backend.renameChat(_chat(a["chatGuid"]), a["name"]);

      case "chatParticipant":
        final op = a["op"] == "add" ? ParticipantOp.Add : ParticipantOp.Remove;
        return await backend.chatParticipant(op, _chat(a["chatGuid"]), a["address"]);

      case "leaveChat":
        return await backend.leaveChat(_chat(a["chatGuid"]));

      case "unsend":
        final msg = _message(a["messageGuid"]);
        final result = await backend.unsend(msg, MessagePart(part: _int(a["part"]) ?? 0));
        if (result == null) return null;
        await ah.handleUpdatedMessage(msg.chat.target!, result, null);
        return messageToWire(Message.findOne(guid: result.guid) ?? result);

      case "edit":
        final msg = _message(a["messageGuid"]);
        final text = AttributedBody.fromMap(a["text"].cast<String, dynamic>());
        final result = await backend.edit(msg, text, _int(a["part"]) ?? 0);
        if (result == null) return null;
        await ah.handleUpdatedMessage(msg.chat.target!, result, null);
        return messageToWire(Message.findOne(guid: result.guid) ?? result);

      case "updateMessage":
        final chat = _chat(a["chatGuid"]);
        final old = _message(a["messageGuid"]);
        PlatformFile? image;
        if (a["uploadId"] != null) {
          final f = _claimUpload(a["uploadId"]);
          image = PlatformFile(name: a["imageName"] ?? "image.jpeg", path: f.path, size: await f.length(), bytes: await f.readAsBytes());
        }
        final result = await backend.updateMessage(
            chat, old, PayloadData.fromJson(a["payloadData"]), image, a["isMeta"] == true, a["notifText"]);
        inq.queue(IncomingItem(chat: chat, message: result, type: QueueType.newMessage));
        return messageToWire(result);

      case "moveToRecycleBin":
        if (a["messageGuid"] != null) {
          Message.softDelete(a["messageGuid"]);
        } else {
          Chat.softDelete(_chat(a["chatGuid"]));
        }
        return true;

      case "restoreChat":
        final chat = _chat(a["chatGuid"]);
        Chat.unDelete(chat);
        await backend.restoreChat(chat);
        return true;

      case "permanentlyDeleteChat":
        final chat = _chat(a["chatGuid"]);
        if (chat.dateDeleted != null) {
          Chat.deleteChat(chat);
        } else {
          final query = (Database.messages.query(Message_.dateDeleted.notNull())..link(Message_.chat, Chat_.id.equals(chat.id!))).build();
          for (final message in query.find()) {
            Message.delete(message.guid!);
          }
          query.close();
        }
        await backend.permanentlyDeleteChat(chat);
        return true;

      case "setChatIcon":
        final chat = _chat(a["chatGuid"]);
        final upload = _claimUpload(a["uploadId"]);
        final iconFile = File(chat.getIconPath(await upload.length()));
        await iconFile.parent.create(recursive: true);
        await upload.rename(iconFile.path);
        return await backend.setChatIcon(chat, iconFile.path);

      case "deleteChatIcon":
        return await backend.deleteChatIcon(_chat(a["chatGuid"]));

      case "startedTyping":
        backend.startedTyping(_chat(a["chatGuid"]));
        return true;

      case "stoppedTyping":
        backend.stoppedTyping(_chat(a["chatGuid"]));
        return true;

      case "handleiMessageState":
        return await backend.handleiMessageState(a["address"]);

      case "getAccountInfo":
        return await backend.getAccountInfo();

      case "getAccountContact":
        return await backend.getAccountContact();

      case "setDefaultHandle":
        await backend.setDefaultHandle(a["handle"]);
        return true;

      case "getDefaultHandle":
        final b = backend;
        return b is RustPushBackend ? await b.getDefaultHandle() : null;
    }
    throw LanRelayError(404, "Unknown method $method");
  }
}
