import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';
import 'package:pointycastle/asn1/asn1_parser.dart';
import 'package:pointycastle/asn1/primitives/asn1_integer.dart';
import 'package:pointycastle/asn1/primitives/asn1_sequence.dart';

class E2EEService {
  static final E2EEService _instance = E2EEService._internal();
  factory E2EEService() => _instance;
  E2EEService._internal();

  static const _storage = FlutterSecureStorage();
  static const _privateKeyStorageKey = 'rsa_private_key';
  static const _publicKeyStorageKey = 'rsa_public_key';

  RSAPrivateKey? _cachedPrivateKey;
  RSAPublicKey? _cachedPublicKey;

  // ── Generate or load key pair on login ───────────────────────────────────

  Future<void> initKeys() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final existingPrivate =
        await _storage.read(key: _privateKeyStorageKey);
    final existingPublic =
        await _storage.read(key: _publicKeyStorageKey);

    if (existingPrivate != null && existingPublic != null) {
      // Keys already on device — just decode them (fast)
      _cachedPrivateKey = _decodePrivateKey(existingPrivate);
      _cachedPublicKey = _decodePublicKey(existingPublic);
      await _ensurePublicKeyInFirestore(uid, existingPublic);
      return;
    }

    // First time only: generate RSA-2048 keypair in a background
    // isolate so the UI thread never freezes during generation (~1-2s).
    final pems = await compute(_generateKeyPairPems, null);
    final privateKeyPem = pems[0];
    final publicKeyPem = pems[1];

    _cachedPrivateKey = _decodePrivateKey(privateKeyPem);
    _cachedPublicKey = _decodePublicKey(publicKeyPem);

    // Private key stays on device ONLY
    await _storage.write(
        key: _privateKeyStorageKey, value: privateKeyPem);
    await _storage.write(
        key: _publicKeyStorageKey, value: publicKeyPem);

    // Public key goes to Firestore (safe — it's public)
    await _ensurePublicKeyInFirestore(uid, publicKeyPem);
  }

  /// Top-level function required by compute() — no class context allowed.
  /// Generates RSA-2048 keypair and returns [privateKeyPem, publicKeyPem].
  static List<String> _generateKeyPairPems(void _) {
    final keyGen = RSAKeyGenerator()
      ..init(ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64),
        _buildSecureRandom(),
      ));
    final pair = keyGen.generateKeyPair();
    final priv = pair.privateKey as RSAPrivateKey;
    final pub = pair.publicKey as RSAPublicKey;
    return [_encodePemPrivate(priv), _encodePemPublic(pub)];
  }

  static SecureRandom _buildSecureRandom() {
    final secureRandom = FortunaRandom();
    final random = Random.secure();
    final seeds =
        List<int>.generate(32, (_) => random.nextInt(256));
    secureRandom.seed(KeyParameter(Uint8List.fromList(seeds)));
    return secureRandom;
  }

  /// Static version of _encodePublicKey for use inside the isolate.
  static String _encodePemPublic(RSAPublicKey key) {
    final seq = ASN1Sequence();
    seq.add(ASN1Integer(key.modulus!));
    seq.add(ASN1Integer(key.exponent!));
    return '-----BEGIN PUBLIC KEY-----\n'
        '${base64.encode(seq.encode())}\n'
        '-----END PUBLIC KEY-----';
  }

  /// Static version of _encodePrivateKey for use inside the isolate.
  static String _encodePemPrivate(RSAPrivateKey key) {
    final seq = ASN1Sequence();
    seq.add(ASN1Integer(BigInt.zero));
    seq.add(ASN1Integer(key.modulus!));
    seq.add(ASN1Integer(key.publicExponent!));
    seq.add(ASN1Integer(key.privateExponent!));
    seq.add(ASN1Integer(key.p!));
    seq.add(ASN1Integer(key.q!));
    seq.add(ASN1Integer(
        key.privateExponent! % (key.p! - BigInt.one)));
    seq.add(ASN1Integer(
        key.privateExponent! % (key.q! - BigInt.one)));
    seq.add(ASN1Integer(key.q!.modInverse(key.p!)));
    return '-----BEGIN RSA PRIVATE KEY-----\n'
        '${base64.encode(seq.encode())}\n'
        '-----END RSA PRIVATE KEY-----';
  }

  Future<void> _ensurePublicKeyInFirestore(
      String uid, String publicKeyPem) async {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .update({'publicKey': publicKeyPem});
  }

  // ── Encrypt a message with friend's public key ───────────────────────────

  Future<String> encryptMessage(
      String plainText, String friendId) async {
    // Fetch friend's public key
    final friendDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(friendId)
        .get();
    if (!friendDoc.exists) throw Exception('Friend not found');

    final data = friendDoc.data() as Map<String, dynamic>;
    final friendPublicKeyPem = data['publicKey'] as String?;

    // Friend hasn't set up E2EE yet — return plaintext
    if (friendPublicKeyPem == null) return plainText;

    // Also fetch OUR OWN public key so sender can decrypt their own messages
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    String? myPublicKeyPem = _cachedPublicKey != null ? null : null;
    if (myUid != null) {
      // Try local cache first, then Firestore
      myPublicKeyPem = await _storage.read(key: _publicKeyStorageKey);
    }

    final friendPublicKey = _decodePublicKey(friendPublicKeyPem);

    // Hybrid encryption:
    // 1. Random AES-256 key + IV
    // 2. Encrypt message with AES-CBC
    // 3. Encrypt AES key with FRIEND's RSA key (so they can decrypt)
    // 4. Encrypt AES key with OUR OWN RSA key (so sender can also decrypt)
    // 5. Bundle both encrypted keys in payload
    final aesKey = _generateAESKey();
    final iv = _generateIV();
    final encryptedMessage = _aesEncrypt(plainText, aesKey, iv);
    final encryptedAesKeyForFriend = _rsaEncrypt(aesKey, friendPublicKey);

    // Encrypt for self so sender can read their own sent messages
    Uint8List? encryptedAesKeyForSelf;
    if (myPublicKeyPem != null) {
      try {
        final myPublicKey = _decodePublicKey(myPublicKeyPem);
        encryptedAesKeyForSelf = _rsaEncrypt(aesKey, myPublicKey);
      } catch (_) {
        // If self-encryption fails, fall back to friend-only
      }
    }

    final payload = {
      'k':  base64.encode(encryptedAesKeyForFriend),
      'ks': encryptedAesKeyForSelf != null
            ? base64.encode(encryptedAesKeyForSelf)
            : null,
      'iv': base64.encode(iv),
      'c':  base64.encode(encryptedMessage),
      'e':  true,
    };
    return jsonEncode(payload);
  }

  // ── Decrypt a message with our private key ────────────────────────────────

  Future<String> decryptMessage(String encryptedJson) async {
    if (_cachedPrivateKey == null) await initKeys();
    if (_cachedPrivateKey == null) return '[Key error]';

    try {
      final payload =
          jsonDecode(encryptedJson) as Map<String, dynamic>;
      if (payload['e'] != true) return encryptedJson;

      final iv         = base64.decode(payload['iv'] as String);
      final ciphertext = base64.decode(payload['c']  as String);

      // Try decrypting the AES key with our private key.
      // For received messages: 'k'  was encrypted with our public key.
      // For sent messages:     'ks' was encrypted with our own public key.
      // Try 'k' first, then fall back to 'ks'.
      Uint8List? aesKey;

      try {
        final encryptedAesKey = base64.decode(payload['k'] as String);
        aesKey = _rsaDecrypt(encryptedAesKey, _cachedPrivateKey!);
      } catch (_) {
        // 'k' didn't work — this is a sent message, try 'ks'
      }

      if (aesKey == null && payload['ks'] != null) {
        try {
          final encryptedAesKeySelf = base64.decode(payload['ks'] as String);
          aesKey = _rsaDecrypt(encryptedAesKeySelf, _cachedPrivateKey!);
        } catch (_) {}
      }

      if (aesKey == null) return '[Unable to decrypt]';

      final plainText = _aesDecrypt(ciphertext, aesKey, iv);
      return plainText;
    } catch (e) {
      return '[Unable to decrypt]';
    }
  }

  // ── Check if a string is an encrypted payload ─────────────────────────────

  bool isEncrypted(String text) {
    try {
      final payload = jsonDecode(text);
      return payload is Map && payload['e'] == true;
    } catch (_) {
      return false;
    }
  }

  // ── RSA Encrypt / Decrypt ─────────────────────────────────────────────────

  Uint8List _rsaEncrypt(Uint8List data, RSAPublicKey publicKey) {
    final cipher = OAEPEncoding(RSAEngine())
      ..init(true,
          PublicKeyParameter<RSAPublicKey>(publicKey));
    return _processInBlocks(cipher, data);
  }

  Uint8List _rsaDecrypt(
      Uint8List data, RSAPrivateKey privateKey) {
    final cipher = OAEPEncoding(RSAEngine())
      ..init(false,
          PrivateKeyParameter<RSAPrivateKey>(privateKey));
    return _processInBlocks(cipher, data);
  }

  Uint8List _processInBlocks(
      AsymmetricBlockCipher cipher, Uint8List input) {
    final output = <int>[];
    var offset = 0;
    while (offset < input.length) {
      final end =
          (offset + cipher.inputBlockSize < input.length)
              ? offset + cipher.inputBlockSize
              : input.length;
      output.addAll(cipher.process(input.sublist(offset, end)));
      offset = end;
    }
    return Uint8List.fromList(output);
  }

  // ── AES-256-CBC Encrypt / Decrypt ─────────────────────────────────────────

  Uint8List _generateAESKey() {
    final random = Random.secure();
    return Uint8List.fromList(
        List<int>.generate(32, (_) => random.nextInt(256)));
  }

  Uint8List _generateIV() {
    final random = Random.secure();
    return Uint8List.fromList(
        List<int>.generate(16, (_) => random.nextInt(256)));
  }

  Uint8List _aesEncrypt(
      String plainText, Uint8List key, Uint8List iv) {
    final cipher = CBCBlockCipher(AESEngine())
      ..init(true,
          ParametersWithIV(KeyParameter(key), iv));
    final paddedData = _pad(utf8.encode(plainText));
    return _processBlocks(
        cipher, Uint8List.fromList(paddedData));
  }

  String _aesDecrypt(
      Uint8List ciphertext, Uint8List key, Uint8List iv) {
    final cipher = CBCBlockCipher(AESEngine())
      ..init(false,
          ParametersWithIV(KeyParameter(key), iv));
    final decrypted = _processBlocks(cipher, ciphertext);
    final unpadded = _unpad(decrypted);
    return utf8.decode(unpadded);
  }

  Uint8List _processBlocks(
      BlockCipher cipher, Uint8List input) {
    final output = Uint8List(input.length);
    for (var offset = 0;
        offset < input.length;
        offset += cipher.blockSize) {
      cipher.processBlock(input, offset, output, offset);
    }
    return output;
  }

  List<int> _pad(List<int> data) {
    final padLength = 16 - (data.length % 16);
    return [...data, ...List.filled(padLength, padLength)];
  }

  Uint8List _unpad(Uint8List data) {
    if (data.isEmpty) return data;
    final padLength = data.last;
    if (padLength > 16 || padLength == 0) return data;
    return data.sublist(0, data.length - padLength);
  }

  // ── PEM Encoding / Decoding ───────────────────────────────────────────────

  String _encodePublicKey(RSAPublicKey key) {
    final seq = ASN1Sequence();
    seq.add(ASN1Integer(key.modulus!));
    seq.add(ASN1Integer(key.exponent!));
    final bytes = seq.encode();
    return '-----BEGIN PUBLIC KEY-----\n'
        '${base64.encode(bytes)}\n'
        '-----END PUBLIC KEY-----';
  }

  String _encodePrivateKey(RSAPrivateKey key) {
    final seq = ASN1Sequence();
    seq.add(ASN1Integer(BigInt.zero));
    seq.add(ASN1Integer(key.modulus!));
    seq.add(ASN1Integer(key.publicExponent!));
    seq.add(ASN1Integer(key.privateExponent!));
    seq.add(ASN1Integer(key.p!));
    seq.add(ASN1Integer(key.q!));
    seq.add(ASN1Integer(
        key.privateExponent! % (key.p! - BigInt.one)));
    seq.add(ASN1Integer(
        key.privateExponent! % (key.q! - BigInt.one)));
    seq.add(ASN1Integer(key.q!.modInverse(key.p!)));
    final bytes = seq.encode();
    return '-----BEGIN RSA PRIVATE KEY-----\n'
        '${base64.encode(bytes)}\n'
        '-----END RSA PRIVATE KEY-----';
  }

  RSAPublicKey _decodePublicKey(String pem) {
    final bytes = base64.decode(pem
        .replaceAll('-----BEGIN PUBLIC KEY-----', '')
        .replaceAll('-----END PUBLIC KEY-----', '')
        .replaceAll('\n', '')
        .trim());
    final seq = ASN1Parser(bytes).nextObject() as ASN1Sequence;
    final modulus =
        (seq.elements![0] as ASN1Integer).integer!;
    final exponent =
        (seq.elements![1] as ASN1Integer).integer!;
    return RSAPublicKey(modulus, exponent);
  }

  RSAPrivateKey _decodePrivateKey(String pem) {
    final bytes = base64.decode(pem
        .replaceAll('-----BEGIN RSA PRIVATE KEY-----', '')
        .replaceAll('-----END RSA PRIVATE KEY-----', '')
        .replaceAll('\n', '')
        .trim());
    final seq = ASN1Parser(bytes).nextObject() as ASN1Sequence;
    final modulus =
        (seq.elements![1] as ASN1Integer).integer!;
    final publicExponent =
        (seq.elements![2] as ASN1Integer).integer!;
    final privateExponent =
        (seq.elements![3] as ASN1Integer).integer!;
    final p = (seq.elements![4] as ASN1Integer).integer!;
    final q = (seq.elements![5] as ASN1Integer).integer!;
    return RSAPrivateKey(
        modulus, privateExponent, p, q);
  }
}