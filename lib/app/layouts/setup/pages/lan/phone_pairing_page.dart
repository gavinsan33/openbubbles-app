import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_pairing.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart' hide BackButton;
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';

enum _PairStep { showingCode, verifying, syncing, done, failed }

/// Pairs this computer with an Android phone running OpenBubbles, the way
/// Google Messages for Web pairs: show a code, scan it from the phone.
class PhonePairingPage extends StatefulWidget {
  const PhonePairingPage({super.key});

  @override
  State<PhonePairingPage> createState() => _PhonePairingPageState();
}

class _PhonePairingPageState extends OptimizedState<PhonePairingPage> {
  LanRelayPairingSession? session;
  String? code;
  _PairStep step = _PairStep.showingCode;
  String? error;
  final hostController = TextEditingController();

  @override
  void initState() {
    super.initState();
    startSession();
  }

  @override
  void dispose() {
    session?.cancel();
    hostController.dispose();
    super.dispose();
  }

  Future<void> startSession() async {
    await session?.cancel();
    final s = LanRelayPairingSession();
    final c = await s.start();
    setState(() {
      session = s;
      code = c;
      step = _PairStep.showingCode;
      error = null;
    });
    try {
      final (payload, host) = await s.result;
      if (!mounted || session != s) return;
      setState(() => step = _PairStep.verifying);
      await finishClientPairing(payload, host);
      final previous = sync.fullSyncManager;
      setState(() => step = _PairStep.syncing);
      final syncing = setup.startSetup(25, true, false);
      // the manager is created a moment after the sync starts
      while (sync.fullSyncManager == previous && mounted) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (mounted) setState(() {});
      await syncing;
      if (sync.fullSyncManager?.error != null) throw Exception(sync.fullSyncManager!.error);
      setState(() => step = _PairStep.done);
    } catch (e, s) {
      Logger.error("Phone pairing failed", error: e, trace: s, tag: "LanRelay");
      if (!mounted) return;
      setState(() {
        step = _PairStep.failed;
        error = e.toString();
      });
    }
  }

  void openConversations() {
    Get.offAll(
      () => ConversationList(showArchivedChats: false, showUnknownSenders: false),
      routeName: "",
      duration: Duration.zero,
      transition: Transition.noTransition,
    );
    Get.delete<SetupViewController>(force: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.theme.colorScheme.background,
      appBar: AppBar(
        backgroundColor: context.theme.colorScheme.background,
        title: Text("Use your Android phone", style: context.theme.textTheme.titleLarge),
        leading: step == _PairStep.syncing || step == _PairStep.done ? const SizedBox.shrink() : const BackButton(),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: switch (step) {
              _PairStep.showingCode => _codeView(),
              _PairStep.verifying => _status("Connecting to your phone..."),
              _PairStep.syncing => _syncView(),
              _PairStep.done => _doneView(),
              _PairStep.failed => _failedView(),
            },
          ),
        ),
      ),
    );
  }

  Widget _codeView() {
    final textStyle = context.theme.textTheme.bodyLarge!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          "Messages go through your phone, so this computer doesn't register with Apple. "
          "Keep both devices on the same network.",
          style: textStyle,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            "1. On your phone, open OpenBubbles\n"
            "2. Go to Settings → Use on Computers\n"
            "3. Tap \"Pair a computer\" and scan this code",
            style: textStyle,
          ),
        ),
        const SizedBox(height: 24),
        if (code == null)
          const CircularProgressIndicator()
        else
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: QrImageView(data: code!, size: 260, backgroundColor: Colors.white),
          ),
        const SizedBox(height: 12),
        if (code != null)
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: const Text("Copy code instead"),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code!));
              showSnackbar("Copied", "Paste it into \"Enter pairing code\" on your phone");
            },
          ),
        const SizedBox(height: 24),
        Text(
          "Phone not found automatically? Enter the address shown under \"Allow paired computers\" on your phone.",
          style: context.theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: hostController,
                decoration: const InputDecoration(hintText: "192.168.1.20"),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () {
                final host = hostController.text.trim();
                if (host.isEmpty) return;
                session?.manualHosts.add(host);
                showSnackbar("Looking", "Checking $host for your phone");
              },
              child: const Text("Add"),
            ),
          ],
        ),
      ],
    );
  }

  Widget _status(String text) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(text, style: context.theme.textTheme.bodyLarge),
      ],
    );
  }

  Widget _syncView() {
    final manager = sync.fullSyncManager;
    if (manager == null) return _status("Getting ready to sync...");
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text("Syncing messages from your phone", style: context.theme.textTheme.titleMedium),
        const SizedBox(height: 16),
        Obx(() => LinearProgressIndicator(value: manager.progress.value == 0 ? null : manager.progress.value)),
        const SizedBox(height: 12),
        Obx(() => Text(
              manager.output.isEmpty ? "" : manager.output.last.item2,
              style: context.theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            )),
      ],
    );
  }

  Widget _doneView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle, size: 64, color: context.theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text("Paired with ${ss.settings.phoneRelayName.value.isEmpty ? "your phone" : ss.settings.phoneRelayName.value}",
            style: context.theme.textTheme.titleMedium),
        const SizedBox(height: 24),
        ElevatedButton(onPressed: openConversations, child: const Text("Open messages")),
      ],
    );
  }

  Widget _failedView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline, size: 64, color: context.theme.colorScheme.error),
        const SizedBox(height: 16),
        Text(error ?? "Pairing failed", style: context.theme.textTheme.bodyLarge, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        ElevatedButton(onPressed: startSession, child: const Text("Try again")),
      ],
    );
  }
}
