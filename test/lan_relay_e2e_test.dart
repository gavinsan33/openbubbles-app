// Exercises the phone side of the LAN relay against a real ObjectBox store and
// a real TLS socket, with the client side's HTTP and websocket code talking to
// it. Needs libobjectbox.so on LD_LIBRARY_PATH, e.g. from a Linux build:
//   LD_LIBRARY_PATH=build/linux/x64/release/bundle/lib flutter test test/lan_relay_e2e_test.dart
import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/network/http_overrides.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_api.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_client.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_events.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_pairing.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_server.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_store.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_wire.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:dio/dio.dart' show Response, RequestOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_io/io.dart';

void main() {
  late Directory tmp;
  late String token;
  late String fingerprint;
  late Handle handle;
  late Chat chat;
  late Message first;
  const origin = "https://127.0.0.1:$lanRelayPort";

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp("lanrelay");
    SharedPreferences.setMockInitialValues({});
    fs.appDocDir = tmp;
    ss.prefs = await SharedPreferences.getInstance();
    ss.settings = Settings();
    await Database.init();
    HttpOverrides.global = BadCertOverride();

    LanRelayServer.forceSupported = true;
    LanRelayEvents.forceEnabled = true;
    LanRelayApi.waitForBackend = () async {};
    await ss.prefs.setBool("lanRelayEnabled", true);

    handle = Handle(address: "+15551234567");
    handle = handle.save();
    handle.originalROWID = handle.id;
    handle = handle.save();
    chat = Chat(guid: "iMessage;-;+15551234567", chatIdentifier: "+15551234567", participants: [handle]);
    chat = chat.save();

    first = Message(
      guid: "msg-1",
      text: "hello from the phone",
      dateCreated: DateTime.now().subtract(const Duration(hours: 1)),
      isFromMe: false,
      handleId: handle.originalROWID,
      hasAttachments: true,
    );
    first = first.save(chat: chat);
    final att = Attachment(guid: "att-1", transferName: "note.txt", mimeType: "text/plain", totalBytes: 5, isOutgoing: false);
    att.save(first);
    await File(att.path).create(recursive: true);
    await File(att.path).writeAsString("hello");

    Contact(id: "c1", displayName: "Test Person", phones: ["+15551234567"]).save();

    await lanRelay.ensureRunning();
    // like a real setup, the HTTP client gets created before pairing
    ss.settings.serverAddress.value = origin;
    await http.ping().catchError((_) => Response(requestOptions: RequestOptions()));
    final identity = await LanRelayStore.instance.identity();
    fingerprint = identity.fingerprint;
    token = await LanRelayStore.instance.addClient("Test PC");

    ss.settings.serverAddress.value = origin;
    ss.settings.guidAuthKey.value = token;
    ss.settings.phoneRelayFingerprint.value = fingerprint;
    ss.settings.phoneRelayClient.value = true;
  });

  tearDownAll(() async {
    await lanRelay.stop();
  });

  test("server is listening", () {
    expect(lanRelay.isRunning, true);
  });

  test("rejects requests without a paired token", () async {
    final client = pinnedHttpClient(fingerprint);
    final res = await (await client.getUrl(Uri.parse("$origin/api/v1/ping"))).close();
    await res.drain();
    expect(res.statusCode, 401);
  });

  test("renaming a computer keeps it paired", () async {
    final id = LanRelayStore.instance.clientForToken(token)!.id;
    await LanRelayStore.instance.renameClient(id, "Work Laptop");
    expect(LanRelayStore.instance.clientForToken(token)?.name, "Work Laptop");
    expect(await LanRelayClient.pingPhone(origin, token, fingerprint), true);
    await LanRelayStore.instance.renameClient(id, "Test PC");
  });

  test("pinned client accepts the phone and rejects a different certificate", () async {
    expect(await LanRelayClient.pingPhone(origin, token, fingerprint), true);
    expect(await LanRelayClient.pingPhone(origin, token, "0" * 64), false);

    ss.settings.phoneRelayFingerprint.value = "0" * 64;
    await expectLater(http.ping(), throwsA(anything));
    ss.settings.phoneRelayFingerprint.value = fingerprint;
    expect((await http.ping()).statusCode, 200);
  });

  test("chat sync endpoints serve parseable chats without local ids", () async {
    expect((await http.chatCount()).data["data"]["total"], 1);
    final res = await http.chats(withQuery: ["participants", "lastmessage"]);
    final wire = (res.data["data"] as List).first as Map<String, dynamic>;
    expect(wire.containsKey("ROWID"), false);
    expect(wire["participants"][0]["originalROWID"], handle.id);
    expect(wire["lastMessage"]["guid"], "msg-1");
    final parsed = Chat.fromMap(wire);
    expect(parsed.id, null);
    expect(parsed.guid, chat.guid);
    expect(parsed.participants.first.address, "+15551234567");
  });

  test("message endpoints include attachments and chats", () async {
    final res = await http.chatMessages(chat.guid, withQuery: "attachments");
    final wire = (res.data["data"] as List).single as Map<String, dynamic>;
    final parsed = Message.fromMap(wire);
    expect(parsed.id, null);
    expect(parsed.guid, "msg-1");
    expect(parsed.text, "hello from the phone");
    expect(parsed.handleId, handle.originalROWID);
    expect(parsed.attachments.single!.guid, "att-1");
    expect(parsed.attachments.single!.id, null);

    final after = DateTime.now().subtract(const Duration(days: 1));
    expect((await http.messageCount(after: after)).data["data"]["total"], 1);
    final query = await http.messages(after: after.millisecondsSinceEpoch, withQuery: ["chats", "chats.participants"]);
    expect(query.data["metadata"]["total"], 1);
    final withChats = (query.data["data"] as List).single;
    expect(withChats["chats"][0]["guid"], chat.guid);
  });

  test("attachments and contacts download", () async {
    final res = await http.downloadAttachment("att-1");
    expect(utf8.decode(res.data), "hello");
    final contacts = await phoneRelay.fetchContacts();
    expect(contacts.single.displayName, "Test Person");
    expect(contacts.single.phones, ["+15551234567"]);
  });

  test("unknown rpc methods are reported as errors", () async {
    final res = await http.dio.post("$origin/api/v1/lan/rpc/doesNotExist", queryParameters: http.buildQueryParams(), data: {});
    expect(res.statusCode, 404);
    expect(res.data["error"]["message"], contains("doesNotExist"));
  });

  test("database changes are pushed over the websocket", () async {
    final ws = await WebSocket.connect("wss://127.0.0.1:$lanRelayPort/api/v1/ws?guid=$token",
        customClient: pinnedHttpClient(fingerprint));
    final events = StreamController<Map<String, dynamic>>.broadcast();
    ws.listen((e) => events.add((jsonDecode(e) as Map).cast<String, dynamic>()));
    Future<Map<String, dynamic>> next(String name) =>
        events.stream.firstWhere((e) => e["event"] == name).timeout(const Duration(seconds: 5));

    await next("hello");
    expect(lanRelay.peers.length, 1);

    final newEvent = next("new-message");
    Message(guid: "msg-2", text: "second", dateCreated: DateTime.now(), isFromMe: true, handleId: 0).save(chat: chat);
    final created = (await newEvent)["data"];
    expect(created["guid"], "msg-2");
    expect(created["chats"][0]["guid"], chat.guid);
    // the client feeds these straight into the incoming queue
    final item = IncomingItem.fromMap(QueueType.newMessage, (created as Map).cast<String, dynamic>());
    expect(item.chat.guid, chat.guid);

    final updatedEvent = next("updated-message");
    final m1 = Message.findOne(guid: "msg-1")!;
    m1.dateRead = DateTime.now();
    m1.save();
    expect((await updatedEvent)["data"]["dateRead"], isNotNull);

    final chatEvent = next("chat-updated");
    chat.displayName = "Renamed";
    chat.save(updateDisplayName: true);
    expect((await chatEvent)["data"]["chat"]["displayName"], "Renamed");

    final deletedEvent = next("message-deleted");
    Message.delete("msg-2");
    expect((await deletedEvent)["data"]["guid"], "msg-2");

    final tempEvents = <String>[];
    final sub = events.stream.listen((e) => tempEvents.add(e["data"]?["guid"]?.toString() ?? ""));
    Message(guid: "temp-abc", text: "sending", dateCreated: DateTime.now(), isFromMe: true, handleId: 0).save(chat: chat);
    await Future.delayed(const Duration(milliseconds: 500));
    expect(tempEvents.contains("temp-abc"), false);
    await sub.cancel();

    await ws.close();
  });

  test("pairing hands the client a working token, by push or by poll", () async {
    // pushed: the phone connects to the computer's pairing listener
    final pushed = LanRelayPairingSession();
    final pushedCode = LanPairCode.tryParse(await pushed.start())!;
    final delivered = await pairWithClientCode(pushedCode);
    final (payload, _) = await pushed.result.timeout(const Duration(seconds: 10));
    expect(delivered, true);
    expect(payload["fingerprint"], fingerprint);
    expect(await LanRelayClient.pingPhone(origin, payload["token"], payload["fingerprint"]), true);

    // polled: the computer can't be reached, so it asks the phone instead
    final polled = LanRelayPairingSession()..manualHosts.add("127.0.0.1");
    final code = LanPairCode.tryParse(await polled.start())!;
    await pairWithClientCode(LanPairCode(secret: code.secret, addresses: code.addresses, port: null, name: code.name));
    final (polledPayload, host) = await polled.result.timeout(const Duration(seconds: 15));
    expect(host, "127.0.0.1");
    expect(await LanRelayClient.pingPhone(origin, polledPayload["token"], fingerprint), true);

    // someone without the secret learns nothing from the poll endpoint
    final res = await (await pinnedHttpClient(fingerprint)
            .getUrl(Uri.parse("$origin/api/v1/pair/poll?id=${Uri.encodeQueryComponent("not-a-real-id")}")))
        .close();
    await res.drain();
    expect(res.statusCode, 404);

    expect(LanRelayStore.instance.clients().length, 3);
  });
}
