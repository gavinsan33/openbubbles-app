import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/services/network/lan/lan_relay_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("self-signed cert serves TLS and pins by fingerprint", () async {
    final cert = await generateLanCertificate("OpenBubbles Test");
    final ctx = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(cert.certPem))
      ..usePrivateKeyBytes(utf8.encode(cert.keyPem));
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
    server.listen((req) {
      req.response.write("ok");
      req.response.close();
    });

    String? seen;
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..badCertificateCallback = (c, host, port) {
        seen = lanFingerprint(c.der);
        return seen == cert.fingerprint;
      };
    final req = await client.getUrl(Uri.parse("https://127.0.0.1:${server.port}/"));
    final res = await req.close();
    expect(await res.transform(utf8.decoder).join(), "ok");
    expect(seen, cert.fingerprint);
    await server.close(force: true);
  });

  test("pairing payload round trips and rejects the wrong secret", () {
    final sealed = LanPairing.seal("secret", {"token": "abc"});
    expect(LanPairing.open("secret", sealed)["token"], "abc");
    expect(() => LanPairing.open("other", sealed), throwsA(anything));
  });

  test("hmac and secure equals", () {
    expect(lanSecureEquals(lanHmac("k", "m"), lanHmac("k", "m")), true);
    expect(lanSecureEquals(lanHmac("k", "m"), lanHmac("k2", "m")), false);
  });
}
