import 'dart:convert';

import 'package:bluebubbles/app/layouts/setup/pages/sync/qr_code_scanner.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_client.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_pairing.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_server.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_store.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_wire.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:universal_io/io.dart';

/// On the phone: share this phone's iMessage with computers on the network.
/// On a paired computer: connection status and unpairing.
class LanRelayPanel extends StatefulWidget {
  const LanRelayPanel({super.key});

  @override
  State<StatefulWidget> createState() => _LanRelayPanelState();
}

class _LanRelayPanelState extends OptimizedState<LanRelayPanel> {
  List<LanRelayClientInfo> clients = [];
  List<String> addresses = [];

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    if (!LanRelayServer.supported) return;
    final list = LanRelayStore.instance.clients();
    final ips = await LanRelayServer.localAddresses();
    setState(() {
      clients = list;
      addresses = ips;
    });
  }

  Future<void> setEnabled(bool enabled) async {
    ss.settings.lanRelayEnabled.value = enabled;
    await ss.settings.saveOne("lanRelayEnabled");
    if (enabled) {
      await lanRelay.ensureRunning();
    } else {
      await lanRelay.stop();
    }
    try {
      await mcs.invokeMethod("lan-relay-changed");
    } catch (_) {}
    setState(() {});
  }

  Future<void> pairComputer() async {
    String? raw;
    if (Platform.isAndroid) {
      final bytes = await Navigator.of(context).push<List<int>>(
        CupertinoPageRoute(builder: (_) => QRCodeScanner()),
      );
      if (bytes != null) raw = utf8.decode(bytes, allowMalformed: true);
    }
    if (raw == null) return;
    await _pairWithCode(raw);
  }

  Future<void> enterCode() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.theme.colorScheme.properSurface,
        title: Text("Enter pairing code", style: context.theme.textTheme.titleLarge),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: "$lanRelayPairPrefix..."),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text("Pair")),
        ],
      ),
    );
    if (raw == null || raw.trim().isEmpty) return;
    await _pairWithCode(raw);
  }

  Future<void> _pairWithCode(String raw) async {
    final code = LanPairCode.tryParse(raw);
    if (code == null) {
      showSnackbar("Error", "That isn't an OpenBubbles pairing code");
      return;
    }
    try {
      final direct = await pairWithClientCode(code);
      showSnackbar("Paired", direct
          ? "${code.name} is connecting"
          : "Waiting for ${code.name} to find this phone. Keep both on the same network.");
    } catch (e) {
      showSnackbar("Error", "Pairing failed: $e");
    }
    await refresh();
  }

  Future<String?> askName(String title, String current) async {
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.theme.colorScheme.properSurface,
        title: Text(title, style: context.theme.textTheme.titleLarge),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text("Rename")),
        ],
      ),
    );
    final trimmed = name?.trim();
    return trimmed == null || trimmed.isEmpty || trimmed == current ? null : trimmed;
  }

  Future<void> renameClient(LanRelayClientInfo client) async {
    final name = await askName("Rename computer", client.name);
    if (name == null) return;
    await LanRelayStore.instance.renameClient(client.id, name);
    await refresh();
  }

  Future<void> renamePhone() async {
    final name = await askName("Rename phone", ss.settings.phoneRelayName.value);
    if (name == null) return;
    ss.settings.phoneRelayName.value = name;
    await ss.settings.saveOne("phoneRelayName");
  }

  Future<void> removeClient(LanRelayClientInfo client) async {
    await LanRelayStore.instance.removeClient(client.id);
    await lanRelay.kick(client.id);
    await refresh();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: isPhoneClient ? "Paired Phone" : "Use on Computers",
      initialHeader: isPhoneClient ? "Phone" : "Relay",
      iosSubtitle: iosSubtitle,
      materialSubtitle: materialSubtitle,
      tileColor: tileColor,
      headerColor: headerColor,
      bodySlivers: [
        SliverList(
          delegate: SliverChildListDelegate(isPhoneClient ? _clientTiles() : _phoneTiles()),
        ),
      ],
    );
  }

  List<Widget> _clientTiles() {
    return [
      SettingsSection(
        backgroundColor: tileColor,
        children: [
          Obx(() => SettingsTile(
                backgroundColor: tileColor,
                title: ss.settings.phoneRelayName.value.isEmpty ? "Your phone" : ss.settings.phoneRelayName.value,
                subtitle: switch (phoneRelay.state.value) {
                  LanRelayState.connected => "Connected at ${http.origin}",
                  LanRelayState.connecting => "Connecting...",
                  LanRelayState.disconnected => "Not connected. Make sure the phone is on the same network.",
                },
                onTap: renamePhone,
                leading: const SettingsLeadingIcon(
                  iosIcon: CupertinoIcons.device_phone_portrait,
                  materialIcon: Icons.phone_android,
                  containerColor: Colors.green,
                ),
              )),
          const SettingsDivider(),
          SettingsTile(
            backgroundColor: tileColor,
            title: "Find phone again",
            subtitle: "Search the network if the phone's address changed",
            onTap: () async {
              final found = await phoneRelay.rediscover();
              phoneRelay.reconnectNow();
              showSnackbar("Relay", found ? "Found your phone" : "Couldn't find a different address for your phone");
            },
          ),
          const SettingsDivider(),
          SettingsTile(
            backgroundColor: tileColor,
            title: "Unpair",
            subtitle: "Remove this computer's messages and disconnect from the phone",
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  backgroundColor: context.theme.colorScheme.properSurface,
                  title: Text("Unpair from phone?", style: context.theme.textTheme.titleLarge),
                  content: Text("This resets the app on this computer. You can pair again at any time.",
                      style: context.theme.textTheme.bodyLarge),
                  actions: [
                    TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text("Cancel")),
                    TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text("Unpair")),
                  ],
                ),
              );
              if (confirmed != true) return;
              await unpairFromPhone();
              // same as Reset App, minus the Apple logout this install never had
              fs.deleteDB();
              ss.settings = Settings();
              await ss.settings.saveAsync();
              await ss.prefs.clear();
              await ss.prefs.setString("selected-dark", "OLED Dark");
              await ss.prefs.setString("selected-light", "Bright White");
              Database.themes.putMany(ts.defaultThemes);
              exit(0);
            },
          ),
        ],
      ),
    ];
  }

  List<Widget> _phoneTiles() {
    return [
      SettingsSection(
        backgroundColor: tileColor,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 8.0, left: 15, top: 8.0, right: 15),
            child: Text(
              "Computers on the same network can send and receive iMessages through this phone, without registering "
              "with Apple themselves. Open OpenBubbles on the computer, choose \"Use my Android phone\", and scan the code it shows.",
            ),
          ),
        ],
      ),
      SettingsSection(
        backgroundColor: tileColor,
        children: [
          Obx(() => SettingsSwitch(
                initialVal: ss.settings.lanRelayEnabled.value,
                onChanged: setEnabled,
                title: "Allow paired computers",
                subtitle: ss.settings.lanRelayEnabled.value
                    ? addresses.isEmpty
                        ? "No network connection"
                        : "Reachable at ${addresses.join(", ")}"
                    : "Paired computers can't connect while this is off",
                backgroundColor: tileColor,
              )),
          const SettingsDivider(),
          SettingsTile(
            backgroundColor: tileColor,
            title: "Pair a computer",
            subtitle: "Scan the QR code shown on the computer",
            onTap: pairComputer,
            leading: const SettingsLeadingIcon(
              iosIcon: CupertinoIcons.qrcode_viewfinder,
              materialIcon: Icons.qr_code_scanner,
              containerColor: Colors.blueAccent,
            ),
          ),
          const SettingsDivider(),
          SettingsTile(
            backgroundColor: tileColor,
            title: "Enter pairing code",
            subtitle: "If the camera can't read the code",
            onTap: enterCode,
          ),
        ],
      ),
      SettingsHeader(iosSubtitle: iosSubtitle, materialSubtitle: materialSubtitle, text: "Paired Computers"),
      SettingsSection(
        backgroundColor: tileColor,
        children: [
          if (clients.isEmpty)
            SettingsTile(backgroundColor: tileColor, title: "No computers paired yet"),
          for (final client in clients) ...[
            Obx(() => SettingsTile(
                  backgroundColor: tileColor,
                  title: client.name,
                  // connectedCount makes this rebuild as clients come and go
                  subtitle: lanRelay.connectedCount.value > 0 && lanRelay.peers.any((p) => p.client.id == client.id)
                      ? "Connected"
                      : "Paired ${buildDate(DateTime.fromMillisecondsSinceEpoch(client.created))}",
                  onTap: () => renameClient(client),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(iOS ? CupertinoIcons.pencil : Icons.edit_outlined),
                        tooltip: "Rename",
                        onPressed: () => renameClient(client),
                      ),
                      IconButton(
                        icon: Icon(iOS ? CupertinoIcons.trash : Icons.delete_outline),
                        tooltip: "Unpair",
                        onPressed: () => removeClient(client),
                      ),
                    ],
                  ),
                )),
            if (client != clients.last) const SettingsDivider(),
          ],
        ],
      ),
    ];
  }
}
