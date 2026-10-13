import 'dart:async';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_client.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_wire.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:dio/dio.dart';
import 'package:universal_io/io.dart';

/// Backend for a computer paired with an Android phone. Every action is
/// carried out by the phone over the LAN relay; this device never talks to
/// Apple itself.
class PhoneRelayBackend implements BackendService {
  Future<dynamic> _rpc(String method, [Map<String, dynamic> args = const {}, CancelToken? cancelToken]) async {
    final response = await http.dio.post(
      "${http.apiRoot}/lan/rpc/$method",
      queryParameters: http.buildQueryParams(),
      data: args,
      // sends wait on Apple, attachments can take a while
      options: Options(receiveTimeout: const Duration(minutes: 6), headers: http.headers),
      cancelToken: cancelToken,
    );
    // handleSendError knows how to read the server's error shape off a Response
    if (response.statusCode != 200) throw response;
    return response.data["data"];
  }

  Future<String> _upload(PlatformFile file, {void Function(int, int)? onSendProgress, CancelToken? cancelToken}) async {
    final length = file.path != null ? await File(file.path!).length() : file.bytes!.length;
    final response = await http.dio.post(
      "${http.apiRoot}/lan/upload",
      queryParameters: http.buildQueryParams(),
      data: file.path != null ? File(file.path!).openRead() : Stream.value(file.bytes!.toList()),
      options: Options(
        headers: {...http.headers, Headers.contentLengthHeader: length, Headers.contentTypeHeader: "application/octet-stream"},
        sendTimeout: const Duration(minutes: 30),
        receiveTimeout: const Duration(minutes: 30),
      ),
      onSendProgress: onSendProgress,
      cancelToken: cancelToken,
    );
    if (response.statusCode != 200) throw response;
    return response.data["data"]["uploadId"];
  }

  /// The phone gives the message its own IDs, so drop ours
  Map<String, dynamic> _outgoing(Message m) {
    final map = messageToWire(m);
    map.remove("originalROWID");
    for (final a in (map["attachments"] as List)) {
      a.remove("originalROWID");
    }
    return map;
  }

  Message _message(dynamic data) => Message.fromMap((data as Map).cast<String, dynamic>());

  @override
  Future<Chat> createChat(List<String> addresses, AttributedBody? message, String service,
      {CancelToken? cancelToken, String? existingGuid}) async {
    final data = await _rpc("createChat", {
      "addresses": addresses,
      "message": message?.toMap(),
      "service": service,
      "existingGuid": existingGuid,
    }, cancelToken);
    return Chat.fromMap((data as Map).cast<String, dynamic>());
  }

  @override
  Future<Message> sendMessage(Chat c, Message m, {CancelToken? cancelToken}) async {
    return _message(await _rpc("sendMessage", {"chatGuid": c.guid, "message": _outgoing(m)}, cancelToken));
  }

  @override
  Future<Message> sendTapback(Chat chat, Message selected, String reaction, int? repPart) async {
    return _message(await _rpc("sendTapback", {
      "chatGuid": chat.guid,
      "selectedGuid": selected.guid,
      "reaction": reaction,
      "repPart": repPart,
    }));
  }

  @override
  Future<Message> sendAttachment(Chat c, Message m, bool isAudioMessage, Attachment attachment,
      {void Function(int, int)? onSendProgress, CancelToken? cancelToken}) async {
    final uploadId = await _upload(attachment.getFile(), onSendProgress: onSendProgress, cancelToken: cancelToken);
    return _message(await _rpc("sendAttachment", {
      "chatGuid": c.guid,
      "message": _outgoing(m),
      "uploadId": uploadId,
      "isAudio": isAudioMessage,
    }, cancelToken));
  }

  @override
  Future<Message> updateMessage(
      Chat chat, Message old, PayloadData newData, PlatformFile? newImage, bool isMeta, String? notifText) async {
    String? uploadId;
    if (newImage != null) uploadId = await _upload(newImage);
    return _message(await _rpc("updateMessage", {
      "chatGuid": chat.guid,
      "messageGuid": old.guid,
      "payloadData": newData.toJson(),
      "uploadId": uploadId,
      "imageName": newImage?.name,
      "isMeta": isMeta,
      "notifText": notifText,
    }));
  }

  @override
  Future<bool> renameChat(Chat chat, String newName) async =>
      await _rpc("renameChat", {"chatGuid": chat.guid, "name": newName}) == true;

  @override
  Future<bool> chatParticipant(ParticipantOp method, Chat chat, String newName) async => await _rpc("chatParticipant", {
        "op": method == ParticipantOp.Add ? "add" : "remove",
        "chatGuid": chat.guid,
        "address": newName,
      }) == true;

  @override
  Future<bool> leaveChat(Chat chat) async => await _rpc("leaveChat", {"chatGuid": chat.guid}) == true;

  @override
  Future<void> moveToRecycleBin(Chat c, Message? message) async {
    await _rpc("moveToRecycleBin", {"chatGuid": c.guid, "messageGuid": message?.guid});
  }

  @override
  Future<void> restoreChat(Chat c) async {
    await _rpc("restoreChat", {"chatGuid": c.guid});
  }

  @override
  Future<void> permanentlyDeleteChat(Chat c) async {
    await _rpc("permanentlyDeleteChat", {"chatGuid": c.guid});
  }

  @override
  Future<bool> markRead(Chat chat, bool notifyOthers) async =>
      await _rpc("markRead", {"chatGuid": chat.guid, "notifyOthers": notifyOthers}) == true;

  @override
  Future<bool> markUnread(Chat chat) async => await _rpc("markUnread", {"chatGuid": chat.guid}) == true;

  @override
  Future<Message?> unsend(Message msg, MessagePart part) async {
    final data = await _rpc("unsend", {"messageGuid": msg.guid, "part": part.part});
    return data == null ? null : _message(data);
  }

  @override
  Future<Message?> edit(Message msgGuid, AttributedBody text, int part) async {
    final data = await _rpc("edit", {"messageGuid": msgGuid.guid, "text": text.toMap(), "part": part});
    return data == null ? null : _message(data);
  }

  @override
  Future<PlatformFile> downloadAttachment(Attachment attachment,
      {void Function(int, int)? onReceiveProgress, bool original = false, CancelToken? cancelToken}) async {
    final response = await http.dio.download(
      "${http.apiRoot}/attachment/${attachment.guid}/download",
      attachment.path,
      queryParameters: http.buildQueryParams(),
      options: Options(receiveTimeout: const Duration(minutes: 30), headers: http.headers),
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
    );
    if (response.statusCode != 200) throw Exception("Phone could not provide the attachment (${response.statusCode})");
    return attachment.getFile();
  }

  @override
  Future<bool> downloadLivePhoto(Attachment att, String target,
      {void Function(int, int)? onReceiveProgress, CancelToken? cancelToken}) async {
    final response = await http.downloadLivePhoto(att.guid!, onReceiveProgress: onReceiveProgress, cancelToken: cancelToken);
    if (response.statusCode != 200) return false;
    await as.saveToDisk(PlatformFile(name: target, size: response.data.length, bytes: response.data));
    return true;
  }

  @override
  Future<bool> setChatIcon(Chat chat, String path, {void Function(int, int)? onSendProgress, CancelToken? cancelToken}) async {
    final uploadId = await _upload(PlatformFile(name: "icon", path: path, size: await File(path).length()),
        onSendProgress: onSendProgress, cancelToken: cancelToken);
    return await _rpc("setChatIcon", {"chatGuid": chat.guid, "uploadId": uploadId}, cancelToken) == true;
  }

  @override
  Future<bool> deleteChatIcon(Chat chat, {CancelToken? cancelToken}) async =>
      await _rpc("deleteChatIcon", {"chatGuid": chat.guid}, cancelToken) == true;

  @override
  void startedTyping(Chat c, [iMessageAppData? appdata]) {
    phoneRelay.send("started-typing", {"chatGuid": c.guid});
  }

  @override
  void stoppedTyping(Chat c) {
    phoneRelay.send("stopped-typing", {"chatGuid": c.guid});
  }

  @override
  void updateTypingStatus(Chat c) {}

  @override
  Future<bool> handleiMessageState(String address) async => await _rpc("handleiMessageState", {"address": address}) == true;

  @override
  Future<Map<String, dynamic>> getAccountInfo() async {
    final data = await _rpc("getAccountInfo");
    return data == null ? {} : (data as Map).cast<String, dynamic>();
  }

  @override
  Future<void> setDefaultHandle(String handle) async {
    await _rpc("setDefaultHandle", {"handle": handle});
  }

  @override
  Future<Map<String, dynamic>> getAccountContact() async {
    final data = await _rpc("getAccountContact");
    return data == null ? {} : (data as Map).cast<String, dynamic>();
  }

  @override
  HttpService? getRemoteService() => http;

  @override
  void init() {}

  @override
  bool canLeaveChat() => true;

  @override
  bool canEditUnsend() => true;

  @override
  bool canSendSubject() => true;

  @override
  bool canCancelUploads() => true;

  @override
  Future<bool> canUploadGroupPhotos() async => true;

  @override
  bool supportsFocusStates() => false;

  @override
  bool canSchedule() => false;

  @override
  bool supportsFindMy() => false;

  @override
  bool canCreateGroupChats() => true;

  // forwarding happens on the phone
  @override
  bool supportsSmsForwarding() => false;

  @override
  bool canDelete() => true;
}
