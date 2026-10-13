import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// Crypto helpers for the LAN relay. The phone serves HTTPS with a self-signed
/// certificate and clients pin its SHA-256 fingerprint, which they learn
/// during pairing over an HMAC-authenticated channel.

Uint8List lanRandomBytes(int length) {
  final rand = Random.secure();
  return Uint8List.fromList(List<int>.generate(length, (_) => rand.nextInt(256)));
}

String lanRandomToken([int length = 32]) => base64Url.encode(lanRandomBytes(length)).replaceAll("=", "");

String lanFingerprint(List<int> der) => sha256.convert(der).toString();

String lanHmac(String key, String message) =>
    Hmac(sha256, utf8.encode(key)).convert(utf8.encode(message)).toString();

/// Constant-time string comparison for tokens and MACs
bool lanSecureEquals(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  if (x.length != y.length) return false;
  var diff = 0;
  for (var i = 0; i < x.length; i++) {
    diff |= x[i] ^ y[i];
  }
  return diff == 0;
}

class LanCertificate {
  final String certPem;
  final String keyPem;
  final String fingerprint;

  LanCertificate(this.certPem, this.keyPem, this.fingerprint);

  Map<String, String> toMap() => {"cert": certPem, "key": keyPem, "fingerprint": fingerprint};

  factory LanCertificate.fromMap(Map<String, dynamic> m) => LanCertificate(m["cert"], m["key"], m["fingerprint"]);
}

/// RSA keygen is slow on phones, so it runs off the main isolate
Future<LanCertificate> generateLanCertificate(String commonName) {
  return Isolate.run(() => _generate(commonName));
}

LanCertificate _generate(String commonName) {
  final random = FortunaRandom()..seed(KeyParameter(lanRandomBytes(32)));
  final keyGen = RSAKeyGenerator()
    ..init(ParametersWithRandom(RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64), random));
  final pair = keyGen.generateKeyPair();
  final pub = pair.publicKey as RSAPublicKey;
  final priv = pair.privateKey as RSAPrivateKey;

  final sigAlg = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString("1.2.840.113549.1.1.11")) // sha256WithRSAEncryption
    ..add(ASN1Null());

  ASN1Sequence name() {
    final atv = ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString("2.5.4.3")) // commonName
      ..add(ASN1UTF8String(commonName));
    return ASN1Sequence()..add(ASN1Set()..add(atv));
  }

  final now = DateTime.now().toUtc();
  final validity = ASN1Sequence()
    ..add(ASN1UtcTime(now.subtract(const Duration(days: 1))))
    ..add(ASN1UtcTime(now.add(const Duration(days: 365 * 20))));

  final rsaPub = ASN1Sequence()
    ..add(ASN1Integer(pub.modulus!))
    ..add(ASN1Integer(pub.exponent!));
  final spki = ASN1Sequence()
    ..add(ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString("1.2.840.113549.1.1.1")) // rsaEncryption
      ..add(ASN1Null()))
    ..add(ASN1BitString(rsaPub.encodedBytes));

  final serial = BigInt.parse(lanRandomBytes(16).map((b) => b.toRadixString(16).padLeft(2, "0")).join(), radix: 16) >> 1;

  final tbs = ASN1Sequence()
    ..add(ASN1Sequence(tag: 0xA0)..add(ASN1Integer.fromInt(2))) // v3
    ..add(ASN1Integer(serial))
    ..add(sigAlg)
    ..add(name())
    ..add(validity)
    ..add(name())
    ..add(spki);

  final signer = RSASigner(SHA256Digest(), "0609608648016503040201")
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(priv));
  final signature = signer.generateSignature(tbs.encodedBytes);

  final cert = ASN1Sequence()
    ..add(tbs)
    ..add(sigAlg)
    ..add(ASN1BitString(signature.bytes));
  final certDer = cert.encodedBytes;

  final p = priv.p!;
  final q = priv.q!;
  final d = priv.privateExponent!;
  final rsaPriv = ASN1Sequence()
    ..add(ASN1Integer.fromInt(0))
    ..add(ASN1Integer(priv.modulus!))
    ..add(ASN1Integer(pub.exponent!))
    ..add(ASN1Integer(d))
    ..add(ASN1Integer(p))
    ..add(ASN1Integer(q))
    ..add(ASN1Integer(d % (p - BigInt.one)))
    ..add(ASN1Integer(d % (q - BigInt.one)))
    ..add(ASN1Integer(q.modInverse(p)));

  return LanCertificate(
    _pem("CERTIFICATE", certDer),
    _pem("RSA PRIVATE KEY", rsaPriv.encodedBytes),
    lanFingerprint(certDer),
  );
}

String _pem(String label, Uint8List der) {
  final b64 = base64.encode(der);
  final lines = <String>[];
  for (var i = 0; i < b64.length; i += 64) {
    lines.add(b64.substring(i, min(i + 64, b64.length)));
  }
  return "-----BEGIN $label-----\n${lines.join("\n")}\n-----END $label-----\n";
}

/// Pairing works like Google Messages: the client shows a QR code holding a
/// one-time secret, the phone scans it, and the phone hands back its address,
/// certificate fingerprint and a client token sealed with a key derived from
/// that secret. The secret never crosses the network, so the sealed payload
/// can travel over plain HTTP or an unverified TLS connection.
class LanPairing {
  static String pairId(String secret) => sha256.convert(utf8.encode("obrelay-pair-id:$secret")).toString();

  static Uint8List _key(String secret) =>
      Uint8List.fromList(Hmac(sha256, utf8.encode(secret)).convert(utf8.encode("obrelay-pair-key")).bytes);

  static Map<String, String> seal(String secret, Map<String, dynamic> payload) {
    final nonce = lanRandomBytes(12);
    final cipher = GCMBlockCipher(AESEngine())..init(true, AEADParameters(KeyParameter(_key(secret)), 128, nonce, Uint8List(0)));
    final ct = cipher.process(Uint8List.fromList(utf8.encode(jsonEncode(payload))));
    return {"nonce": base64.encode(nonce), "ct": base64.encode(ct)};
  }

  /// Throws if the payload was not sealed with [secret]
  static Map<String, dynamic> open(String secret, Map<String, dynamic> sealed) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(_key(secret)), 128, base64.decode(sealed["nonce"]), Uint8List(0)));
    final pt = cipher.process(base64.decode(sealed["ct"]));
    return (jsonDecode(utf8.decode(pt)) as Map).cast<String, dynamic>();
  }
}
