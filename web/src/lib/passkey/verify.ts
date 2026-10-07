import { p256 } from '@noble/curves/p256';
import {
  base64urlEncode,
  bigIntToBytes,
  concat,
  fromHex,
  sha256,
  strip0x,
} from './encoding';
import { computeAssertionDigest } from './digest';
import type { LocalVerificationResult } from './types';

export interface VerifyAssertionLocalParams {
  authenticatorData: Uint8Array;
  clientDataJSON: Uint8Array | string;
  r: bigint;
  s: bigint;
  qx: bigint | string | Uint8Array;
  qy: bigint | string | Uint8Array;
  expectedChallenge: Uint8Array | string;
  expectedRpId: string;
}

/**
 * Validates a WebAuthn assertion locally against all protocol invariants:
 * 1. rpIdHash in authenticatorData equals sha256(expectedRpId).
 * 2. UP (User Present, bit 0) and UV (User Verified, bit 2) flags are set.
 * 3. clientDataJSON type equals "webauthn.get".
 * 4. clientDataJSON challenge equals base64url(expectedChallenge).
 * 5. Signature cross-verifies using BOTH WebCrypto and @noble/curves/p256.
 */
export async function verifyAssertionLocal(
  params: VerifyAssertionLocalParams
): Promise<LocalVerificationResult> {
  const reasons: string[] = [];
  const {
    authenticatorData,
    clientDataJSON,
    r,
    s,
    qx,
    qy,
    expectedChallenge,
    expectedRpId,
  } = params;

  // 1. Authenticator data length check
  if (!authenticatorData || authenticatorData.length < 37) {
    reasons.push(
      `authenticatorData is truncated: length is ${authenticatorData?.length ?? 0} bytes (minimum 37 required)`
    );
    return { valid: false, reasons };
  }

  // 2. rpIdHash check
  const expectedRpIdHash = sha256(new TextEncoder().encode(expectedRpId));
  const actualRpIdHash = authenticatorData.subarray(0, 32);
  let rpIdHashMatches = true;
  for (let i = 0; i < 32; i++) {
    if (actualRpIdHash[i] !== expectedRpIdHash[i]) {
      rpIdHashMatches = false;
      break;
    }
  }
  if (!rpIdHashMatches) {
    reasons.push(
      `rpIdHash does not match expected sha256("${expectedRpId}")`
    );
  }

  // 3. Flags check (byte offset 32): UP (bit 0) and UV (bit 2)
  const flags = authenticatorData[32];
  const userPresent = (flags & 0x01) !== 0;
  const userVerified = (flags & 0x04) !== 0;

  if (!userPresent) {
    reasons.push('User Presence (UP) flag (bit 0) is not set in authenticatorData');
  }
  if (!userVerified) {
    reasons.push('User Verification (UV) flag (bit 2) is not set in authenticatorData');
  }

  // 4. clientDataJSON validation
  const clientDataText = typeof clientDataJSON === 'string'
    ? clientDataJSON
    : new TextDecoder().decode(clientDataJSON);

  const clientDataBytes = typeof clientDataJSON === 'string'
    ? new TextEncoder().encode(clientDataJSON)
    : clientDataJSON;

  let parsedClientData: Record<string, unknown> | null = null;
  try {
    parsedClientData = JSON.parse(clientDataText);
  } catch (err) {
    reasons.push(`clientDataJSON is not valid JSON: ${(err as Error).message}`);
  }

  if (parsedClientData) {
    if (parsedClientData.type !== 'webauthn.get') {
      reasons.push(
        `clientDataJSON type mismatch: expected "webauthn.get", got "${parsedClientData.type}"`
      );
    }

    const expectedChallengeBytes = typeof expectedChallenge === 'string'
      ? (expectedChallenge.startsWith('0x') || expectedChallenge.startsWith('0X')
          ? fromHex(strip0x(expectedChallenge))
          : new TextEncoder().encode(expectedChallenge))
      : expectedChallenge;

    const expectedChallengeB64 = base64urlEncode(expectedChallengeBytes);
    if (parsedClientData.challenge !== expectedChallengeB64) {
      reasons.push(
        `clientDataJSON challenge mismatch: expected "${expectedChallengeB64}", got "${parsedClientData.challenge}"`
      );
    }
  }

  // Convert qx and qy coordinates to bigints and bytes
  const qxBigInt = typeof qx === 'bigint'
    ? qx
    : typeof qx === 'string'
      ? BigInt(qx.startsWith('0x') ? qx : `0x${qx}`)
      : BigInt(`0x${Array.from(qx).map((b) => b.toString(16).padStart(2, '0')).join('')}`);

  const qyBigInt = typeof qy === 'bigint'
    ? qy
    : typeof qy === 'string'
      ? BigInt(qy.startsWith('0x') ? qy : `0x${qy}`)
      : BigInt(`0x${Array.from(qy).map((b) => b.toString(16).padStart(2, '0')).join('')}`);

  const qxBytes = bigIntToBytes(qxBigInt, 32);
  const qyBytes = bigIntToBytes(qyBigInt, 32);

  // 5a. Signature verification with @noble/curves/p256
  const digest = computeAssertionDigest(authenticatorData, clientDataBytes);
  let nobleValid = false;
  try {
    const uncompressedPub = new Uint8Array(65);
    uncompressedPub[0] = 0x04;
    uncompressedPub.set(qxBytes, 1);
    uncompressedPub.set(qyBytes, 33);

    const sig = new p256.Signature(r, s);
    nobleValid = p256.verify(sig, digest, uncompressedPub);
  } catch (err) {
    reasons.push(`@noble/curves verification error: ${(err as Error).message}`);
  }

  if (!nobleValid) {
    reasons.push('Signature failed @noble/curves P-256 verification');
  }

  // 5b. Signature verification with WebCrypto
  // Note: W3C WebCrypto ECDSA verify expects IEEE P1363 signature encoding (raw 64 bytes r || s)
  let webCryptoValid = false;
  try {
    const jwk = {
      kty: 'EC',
      crv: 'P-256',
      x: base64urlEncode(qxBytes),
      y: base64urlEncode(qyBytes),
    };

    const cryptoKey = await globalThis.crypto.subtle.importKey(
      'jwk',
      jwk,
      { name: 'ECDSA', namedCurve: 'P-256' },
      true,
      ['verify']
    );

    const p1363Signature = concat([bigIntToBytes(r, 32), bigIntToBytes(s, 32)]);
    const clientDataHash = sha256(clientDataBytes);
    const signedMessage = concat([authenticatorData, clientDataHash]);

    webCryptoValid = await globalThis.crypto.subtle.verify(
      { name: 'ECDSA', hash: { name: 'SHA-256' } },
      cryptoKey,
      p1363Signature as BufferSource,
      signedMessage as BufferSource
    );
  } catch (err) {
    reasons.push(`WebCrypto verification error: ${(err as Error).message}`);
  }

  if (!webCryptoValid) {
    reasons.push('Signature failed WebCrypto P-256 verification');
  }

  return {
    valid: reasons.length === 0,
    reasons,
  };
}
