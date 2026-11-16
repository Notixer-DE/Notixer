import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

/// Versioned, domain-separated authenticated encryption. Random AES-GCM nonces
/// are stored with ciphertext; plaintext hashes never cross the network.
class SyncCrypto {
  SyncCrypto._(this.account, this._encryption, this._identity);
  final String account;
  final SecretKey _encryption;
  final List<int> _identity;
  static final _aes = AesGcm.with256bits();

  static Future<String> generateRecoveryKey() async =>
      base64UrlEncode(await (await _aes.newSecretKey()).extractBytes());

  static Future<SyncCrypto> create(String recoveryKey, String account) async {
    final raw = base64Url.decode(recoveryKey.trim());
    if (raw.length != 32) {
      throw const FormatException('Schlüssel muss 32 Bytes enthalten.');
    }
    Future<SecretKey> derive(String purpose) =>
        Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
          secretKey: SecretKey(raw),
          nonce: utf8.encode('noter:sync:v1:$account'),
          info: utf8.encode(purpose),
        );
    return SyncCrypto._(
      account,
      await derive('encryption'),
      await (await derive('identity')).extractBytes(),
    );
  }

  String identify(String value) => hashes.Hmac(
    hashes.sha256,
    _identity,
  ).convert(utf8.encode(value)).toString();
  String get keyCheck => identify('noter:key-check:v1:$account');
  String wireRevision(String id) => identify('noter:revision:v1:$id');

  Future<Uint8List> encrypt(List<int> bytes, String context) async {
    if (bytes.length >= 65536) {
      final key = await _encryption.extractBytes();
      final aad = utf8.encode('noter:sync:v1:$account:$context');
      final transfer = TransferableTypedData.fromList([
        Uint8List.fromList(bytes),
      ]);
      return Isolate.run(() => _cryptBlock(transfer, key, aad, true));
    }
    final box = await _aes.encrypt(
      bytes,
      secretKey: _encryption,
      aad: utf8.encode('noter:sync:v1:$account:$context'),
    );
    return Uint8List.fromList(box.concatenation());
  }

  Future<Uint8List> decrypt(List<int> bytes, String context) async {
    if (bytes.length < 28) {
      throw const FormatException('Verschlüsselte Daten unvollständig.');
    }
    if (bytes.length >= 65536) {
      final key = await _encryption.extractBytes();
      final aad = utf8.encode('noter:sync:v1:$account:$context');
      final transfer = TransferableTypedData.fromList([
        Uint8List.fromList(bytes),
      ]);
      return Isolate.run(() => _cryptBlock(transfer, key, aad, false));
    }
    return Uint8List.fromList(
      await _aes.decrypt(
        SecretBox.fromConcatenation(bytes, nonceLength: 12, macLength: 16),
        secretKey: _encryption,
        aad: utf8.encode('noter:sync:v1:$account:$context'),
      ),
    );
  }
}

Future<Uint8List> _cryptBlock(
  TransferableTypedData transfer,
  List<int> key,
  List<int> aad,
  bool encrypt,
) async {
  final bytes = transfer.materialize().asUint8List();
  final aes = AesGcm.with256bits();
  if (encrypt) {
    return Uint8List.fromList(
      (await aes.encrypt(
        bytes,
        secretKey: SecretKey(key),
        aad: aad,
      )).concatenation(),
    );
  }
  return Uint8List.fromList(
    await aes.decrypt(
      SecretBox.fromConcatenation(bytes, nonceLength: 12, macLength: 16),
      secretKey: SecretKey(key),
      aad: aad,
    ),
  );
}
