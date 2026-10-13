import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_crypto.dart';
import 'package:bluebubbles/services/network/lan/lan_relay_wire.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:universal_io/io.dart';

bool hasBadCert = false;

class BadCertOverride extends HttpOverrides {
  @override
  createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      // If there is a bad certificate callback, override it if the host is part of
      // your server URL
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        // a paired phone's self-signed certificate must match the one pinned
        // at pairing. Checked here, at handshake time, because clients are
        // created once and reused across pairing.
        if (isPhoneClient && Uri.tryParse(http.origin)?.host == host) {
          return lanSecureEquals(lanFingerprint(cert.der), ss.settings.phoneRelayFingerprint.value);
        }
        String serverUrl = sanitizeServerAddress() ?? "";
        if (host.startsWith("*")) {
          final regex = RegExp(
              "^((\\*|[\\w\\d]+(-[\\w\\d]+)*)\\.)*(${host.split(".").reversed.take(2).toList().reversed.join(".")})\$");
          hasBadCert = regex.hasMatch(serverUrl);
        } else {
          hasBadCert = serverUrl.endsWith(host);
        }
        return hasBadCert;
      };
  }
}