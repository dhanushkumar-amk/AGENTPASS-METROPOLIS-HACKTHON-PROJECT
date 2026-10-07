import { p256 } from '@noble/curves/p256';
import {
  base64urlEncode,
  bigIntToBytes,
  bytesToBigInt,
  concat,
  sha256,
  to0xHex,
} from '../encoding';
import { encodeDERSignature } from '../der';
import { accountIdOf } from '../recovery';
import type { Coordinate } from '../types';

export interface SoftwareKey {
  privateKey: bigint;
  qx: Coordinate;
  qy: Coordinate;
  spki: Uint8Array;
  accountId: `0x${string}`;
}

/**
 * Creates a P-256 keypair for testing using WebCrypto or deterministic scalar.
 */
export async function createSoftwareKey(fixedPrivateKey?: bigint): Promise<SoftwareKey> {
  let priv: bigint;
  let qxBigInt: bigint;
  let qyBigInt: bigint;

  if (fixedPrivateKey) {
    priv = fixedPrivateKey;
    const pubUncompressed = p256.getPublicKey(priv, false); // 65 bytes: 04 || qx(32) || qy(32)
    qxBigInt = bytesToBigInt(pubUncompressed.slice(1, 33));
    qyBigInt = bytesToBigInt(pubUncompressed.slice(33, 65));
  } else {
    const keyPair = await globalThis.crypto.subtle.generateKey(
      { name: 'ECDSA', namedCurve: 'P-256' },
      true,
      ['sign', 'verify']
    );
    const jwk = await globalThis.crypto.subtle.exportKey('jwk', keyPair.publicKey);
    const spkiBuffer = await globalThis.crypto.subtle.exportKey('spki', keyPair.publicKey);
    const jwkPriv = await globalThis.crypto.subtle.exportKey('jwk', keyPair.privateKey);

    const xBytes = Buffer.from(jwk.x!, 'base64url');
    const yBytes = Buffer.from(jwk.y!, 'base64url');
    const dBytes = Buffer.from(jwkPriv.d!, 'base64url');

    priv = bytesToBigInt(new Uint8Array(dBytes));
    qxBigInt = bytesToBigInt(new Uint8Array(xBytes));
    qyBigInt = bytesToBigInt(new Uint8Array(yBytes));

    const accountId = accountIdOf(qxBigInt, qyBigInt);
    return {
      privateKey: priv,
      qx: { bigint: qxBigInt, hex: to0xHex(qxBigInt, 32) },
      qy: { bigint: qyBigInt, hex: to0xHex(qyBigInt, 32) },
      spki: new Uint8Array(spkiBuffer),
      accountId,
    };
  }

  // Construct standard SPKI DER for P-256
  const qxBytes = bigIntToBytes(qxBigInt, 32);
  const qyBytes = bigIntToBytes(qyBigInt, 32);
  const jwk = {
    kty: 'EC',
    crv: 'P-256',
    x: base64urlEncode(qxBytes),
    y: base64urlEncode(qyBytes),
  };
  const importedKey = await globalThis.crypto.subtle.importKey(
    'jwk',
    jwk,
    { name: 'ECDSA', namedCurve: 'P-256' },
    true,
    ['verify']
  );
  const spkiBuffer = await globalThis.crypto.subtle.exportKey('spki', importedKey);

  const accountId = accountIdOf(qxBigInt, qyBigInt);
  return {
    privateKey: priv,
    qx: { bigint: qxBigInt, hex: to0xHex(qxBigInt, 32) },
    qy: { bigint: qyBigInt, hex: to0xHex(qyBigInt, 32) },
    spki: new Uint8Array(spkiBuffer),
    accountId,
  };
}

/**
 * Builds authenticatorData the way authenticators do:
 * - 32 bytes rpIdHash = sha256(rpId)
 * - 1 byte flags (0x05 for UP | UV)
 * - 4 bytes signCount (counter)
 */
export function buildAuthenticatorData(
  rpId = 'localhost',
  flags = 0x05,
  signCount = 1
): Uint8Array {
  const rpIdHash = sha256(new TextEncoder().encode(rpId));
  const authData = new Uint8Array(37);
  authData.set(rpIdHash, 0);
  authData[32] = flags;
  // 4-byte big-endian signCount
  authData[33] = (signCount >> 24) & 0xff;
  authData[34] = (signCount >> 16) & 0xff;
  authData[35] = (signCount >> 8) & 0xff;
  authData[36] = signCount & 0xff;
  return authData;
}

/**
 * Builds clientDataJSON the way Chrome does:
 * {"type":"webauthn.get","challenge":"<base64url>","origin":"http://localhost:3000","crossOrigin":false}
 */
export function buildClientDataJSON(
  challenge: Uint8Array,
  origin = 'http://localhost:3000',
  extraFields?: Record<string, unknown>
): { jsonText: string; jsonBytes: Uint8Array } {
  const challengeB64 = base64urlEncode(challenge);
  const obj: Record<string, unknown> = {
    type: 'webauthn.get',
    challenge: challengeB64,
    origin,
    crossOrigin: false,
    ...extraFields,
  };
  const jsonText = JSON.stringify(obj);
  const jsonBytes = new TextEncoder().encode(jsonText);
  return { jsonText, jsonBytes };
}

/**
 * Signs an assertion using a P-256 private key and produces a DER-encoded signature.
 */
export function signSoftwareAssertion(
  privateKey: bigint,
  authData: Uint8Array,
  clientDataBytes: Uint8Array
): { derSignature: Uint8Array; r: bigint; s: bigint; digest: Uint8Array } {
  const clientDataHash = sha256(clientDataBytes);
  const signedMessage = concat([authData, clientDataHash]);
  const digest = sha256(signedMessage);

  const sig = p256.sign(digest, privateKey);
  const derSignature = encodeDERSignature(sig.r, sig.s);

  return {
    derSignature,
    r: sig.r,
    s: sig.s,
    digest,
  };
}
