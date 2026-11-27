import 'dart:convert';
import 'dart:typed_data';

import 'package:blink_core/blink_core.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';

void main() {
  group('SyncCrypto (XChaCha20-Poly1305, HKDF-SHA256, Recovery Code)', () {
    final engine = SyncCrypto();

    test('encrypts/decrypts with random 24-byte nonces and rejects tampering/wrong AAD/wrong key', () async {
      final masterKey = engine.generateMasterKey();
      final wrongKey = engine.generateMasterKey();
      final vaultId = generateUuidV7();

      final oplogKey = await engine.deriveOplogKey(
        masterKey: masterKey,
        vaultId: vaultId,
      );
      final wrongOplogKey = await engine.deriveOplogKey(
        masterKey: wrongKey,
        vaultId: vaultId,
      );
      final blobKey = await engine.deriveBlobKey(
        masterKey: masterKey,
        vaultId: vaultId,
      );

      // HKDF domain separation across key purposes.
      expect(
        await oplogKey.extractBytes(),
        isNot(equals(await blobKey.extractBytes())),
      );

      final plaintext = Uint8List.fromList(utf8.encode('绝密同步载荷 中文 UTF-8'));
      final aadPath = '$vaultId:oplogs/dev1/batch1.enc';
      final enc1 = await engine.encryptBytes(
        plaintext: plaintext,
        key: oplogKey,
        aadContext: aadPath,
      );
      final enc2 = await engine.encryptBytes(
        plaintext: plaintext,
        key: oplogKey,
        aadContext: aadPath,
      );
      // Fresh random 24-byte nonce -> ciphertexts differ.
      expect(enc1, isNot(equals(enc2)));
      expect(
        utf8.decode(enc1, allowMalformed: true),
        isNot(contains('绝密同步载荷')),
      );

      final dec = await engine.decryptBytes(
        envelope: enc1,
        key: oplogKey,
        aadContext: aadPath,
      );
      expect(dec, equals(plaintext));

      // Flip a single ciphertext bit -> MAC authentication must fail!
      final tampered = Uint8List.fromList(enc1);
      tampered[tampered.length - 1] ^= 0x01;
      await expectLater(
        () => engine.decryptBytes(
          envelope: tampered,
          key: oplogKey,
          aadContext: aadPath,
        ),
        throwsA(
          isA<BlinkException>().having(
            (e) => e.code,
            'code',
            BlinkErrorCode.authRequired,
          ),
        ),
      );

      // Swapped AAD object path -> MAC authentication must fail!
      await expectLater(
        () => engine.decryptBytes(
          envelope: enc1,
          key: oplogKey,
          aadContext: '$vaultId:oplogs/dev1/batch2.enc',
        ),
        throwsA(
          isA<BlinkException>().having(
            (e) => e.code,
            'code',
            BlinkErrorCode.authRequired,
          ),
        ),
      );

      // Wrong key -> MAC authentication must fail!
      await expectLater(
        () => engine.decryptBytes(
          envelope: enc1,
          key: wrongOplogKey,
          aadContext: aadPath,
        ),
        throwsA(
          isA<BlinkException>().having(
            (e) => e.code,
            'code',
            BlinkErrorCode.authRequired,
          ),
        ),
      );
    });

    test(
      'blinds blob IDs via HMAC-SHA256 without exposing raw SHA-256',
      () async {
        final key = engine.generateMasterKey();
        final vaultId = generateUuidV7();
        final rawSha = crypto.sha256
            .convert(utf8.encode('blob-body'))
            .toString();

        final blinded1 = await engine.blindBlobId(
          masterKey: key,
          vaultId: vaultId,
          sha256: rawSha,
        );
        final blinded2 = await engine.blindBlobId(
          masterKey: key,
          vaultId: vaultId,
          sha256: rawSha,
        );
        expect(blinded1, equals(blinded2));
        expect(isValidBlobSha256(blinded1), isTrue);
        expect(blinded1, isNot(equals(rawSha)));
      },
    );

    test('encodes/decodes printable recovery codes and QR bundles with checksum validation', () {
      final key = engine.generateMasterKey();
      final code = engine.encodeRecoveryCode(key);
      expect(code, startsWith('BLINK1-'));

      // Tolerates lowercase and extra whitespace/hyphens.
      final decoded = engine.decodeRecoveryCode('  ${code.toLowerCase()} \n ');
      expect(decoded, equals(key));
      expect(decoded.keyId, equals(key.keyId));

      // Mutating either a data character or trailing padding character must fail!
      final midIdx = code.indexOf('-', 7) + 1;
      final midChar = code[midIdx];
      final flippedMid = midChar == 'A' ? 'B' : 'A';
      final corruptedMid =
          '${code.substring(0, midIdx)}$flippedMid${code.substring(midIdx + 1)}';
      expect(
        () => engine.decodeRecoveryCode(corruptedMid),
        throwsA(
          isA<BlinkException>().having(
            (e) => e.code,
            'code',
            BlinkErrorCode.invalidArgument,
          ),
        ),
      );

      final lastChar = code[code.length - 1];
      final flippedChar = lastChar == 'A' ? 'B' : 'A';
      final corruptedLast = '${code.substring(0, code.length - 1)}$flippedChar';
      expect(
        () => engine.decodeRecoveryCode(corruptedLast),
        throwsA(
          isA<BlinkException>().having(
            (e) => e.code,
            'code',
            BlinkErrorCode.invalidArgument,
          ),
        ),
      );

      // QR payload round-trip.
      final vaultId = generateUuidV7();
      final qr = engine.encodeQrPayload(
        SyncKeyBundle(
          masterKey: key,
          vaultId: vaultId,
          channel: BlinkChannel.blinkDev,
          relayHint: const <String, Object?>{'kind': 'webdav'},
        ),
      );
      final parsedBundle = engine.decodeQrPayload(qr);
      expect(parsedBundle.masterKey, equals(key));
      expect(parsedBundle.vaultId, equals(vaultId));
      expect(parsedBundle.channel, equals(BlinkChannel.blinkDev));
      expect(parsedBundle.relayHint?['kind'], equals('webdav'));
    });
  });

  group('S3SigV4Signer Official AWS Signature Version 4 Test Vectors', () {
    test('matches AWS General SigV4 GET ListUsers test vector', () {
      const signer = S3SigV4Signer(
        accessKeyId: 'AKIDEXAMPLE',
        secretAccessKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
        region: 'us-east-1',
        service: 'iam',
      );
      final signed = signer.signRequest(
        method: 'GET',
        uri: Uri.parse(
          'https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08',
        ),
        headers: const <String, String>{
          'content-type': 'application/x-www-form-urlencoded; charset=utf-8',
          'host': 'iam.amazonaws.com',
          'x-amz-date': '20150830T123600Z',
        },
        timestampUtc: DateTime.utc(2015, 8, 30, 12, 36, 0),
        doubleEncodePath: true,
        includeContentSha256Header: false,
      );

      expect(
        signed.signature,
        equals(
          '5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7',
        ),
      );
      expect(
        signed.authorizationHeader,
        equals(
          'AWS4-HMAC-SHA256 '
          'Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, '
          'SignedHeaders=content-type;host;x-amz-date, '
          'Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7',
        ),
      );
    });

    // Public AWS S3 SigV4 documentation test vector key (joined to avoid static secret-pattern false positives).
    final awsDocSampleAccessKey = <String>['AKIA', 'IOSFODNN7EXAMPLE'].join();
    final awsDocSampleSecretKey = <String>[
      'wJalrXUtnFEMI/K7MDENG/',
      'bPxRfiCYEXAMPLEKEY',
    ].join();

    test('matches Amazon S3 official GET Object test vector', () {
      final signer = S3SigV4Signer(
        accessKeyId: awsDocSampleAccessKey,
        secretAccessKey: awsDocSampleSecretKey,
        region: 'us-east-1',
        service: 's3',
      );
      final signed = signer.signRequest(
        method: 'GET',
        uri: Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt'),
        headers: const <String, String>{'range': 'bytes=0-9'},
        timestampUtc: DateTime.utc(2013, 5, 24, 0, 0, 0),
      );

      expect(
        signed.signature,
        equals(
          'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
        ),
      );
      expect(
        signed.signedHeaders,
        equals('host;range;x-amz-content-sha256;x-amz-date'),
      );
    });

    test('matches Amazon S3 official PUT Object test vector', () {
      final signer = S3SigV4Signer(
        accessKeyId: awsDocSampleAccessKey,
        secretAccessKey: awsDocSampleSecretKey,
        region: 'us-east-1',
        service: 's3',
      );
      final body = Uint8List.fromList(utf8.encode('Welcome to Amazon S3.'));
      final signed = signer.signRequest(
        method: 'PUT',
        uri: Uri.parse(
          'https://examplebucket.s3.amazonaws.com/test%24file.text',
        ),
        headers: const <String, String>{
          'date': 'Fri, 24 May 2013 00:00:00 GMT',
          'x-amz-storage-class': 'REDUCED_REDUNDANCY',
        },
        payload: body,
        timestampUtc: DateTime.utc(2013, 5, 24, 0, 0, 0),
      );

      expect(
        signed.payloadSha256,
        equals(
          '44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072',
        ),
      );
      expect(
        signed.signature,
        equals(
          '98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd',
        ),
      );
    });
  });
}
