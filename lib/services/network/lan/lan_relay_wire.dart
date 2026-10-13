import 'package:bluebubbles/database/models.dart';
import 'package:collection/collection.dart';
import 'package:bluebubbles/services/services.dart';

/// Port the phone listens on for paired clients
const lanRelayPort = 47621;

/// mDNS / NSD service type the phone advertises so clients can find it again
/// after its IP changes
const lanRelayServiceType = "_obrelay._tcp";

const lanRelayProtocolVersion = 1;

/// Prefix for pairing codes (QR payloads and the copyable text form)
const lanRelayPairPrefix = "obrelay1:";

/// True when this install is a client of an Android phone rather than its own
/// iMessage device
bool get isPhoneClient => ss.settings.phoneRelayClient.value;

/// Models are serialized with their own toMap() and parsed on the other side
/// with fromMap(). Object IDs are local to each database, so they are moved
/// into originalROWID (which is what the client matches handles on) and the
/// local ID is dropped so the client never writes over an unrelated row.

Map<String, dynamic> handleToWire(Handle h) {
  final map = h.toMap();
  map.remove("ROWID");
  map["originalROWID"] = h.originalROWID ?? h.id;
  return map;
}

Map<String, dynamic> attachmentToWire(Attachment a) {
  // toMap() asserts these are set, which older rows don't guarantee
  a.isOutgoing ??= false;
  final map = a.toMap();
  map.remove("ROWID");
  map["originalROWID"] = a.id;
  return map;
}

Map<String, dynamic> chatToWire(Chat c, {bool withLastMessage = false}) {
  c.isArchived ??= false;
  c.isPinned ??= false;
  c.hasUnreadMessage ??= false;
  final map = c.toMap();
  map.remove("ROWID");
  // file paths and drafts are meaningless on another device
  map.remove("_customAvatarPath");
  map.remove("textFieldText");
  map.remove("textFieldAnnotations");
  map["participants"] = c.participants.map(handleToWire).toList();
  map["usingHandle"] = c.usingHandle;
  map["hasCustomIcon"] = c.customAvatarPath != null;
  if (withLastMessage) {
    final latest = Chat.getMessages(c, limit: 1, getDetails: true).firstOrNull;
    if (latest != null) map["lastMessage"] = messageToWire(latest);
  }
  return map;
}

Map<String, dynamic> messageToWire(Message m, {Chat? chat, bool withChats = false}) {
  m.isFromMe ??= false;
  m.hasDdResults ??= false;
  for (final a in m.attachments) {
    a?.isOutgoing ??= false;
  }
  final map = m.toMap(includeObjects: true);
  map.remove("ROWID");
  map["originalROWID"] = m.id;
  map["attachments"] = (m.dbAttachments.isNotEmpty ? m.dbAttachments : m.attachments.whereType<Attachment>())
      .map(attachmentToWire)
      .toList();
  final handle = m.handle ?? (m.isFromMe == true ? null : m.getHandle());
  map["handle"] = handle == null ? null : handleToWire(handle);
  // sendingServiceId identifies a process on the phone
  map.remove("sendingServiceId");
  if (withChats) {
    final c = chat ?? m.chat.target;
    map["chats"] = c == null ? [] : [chatToWire(c)];
  }
  return map;
}
