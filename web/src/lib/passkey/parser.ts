import { base64urlDecode, bytesToBigInt, to0xHex } from './encoding';
import { parseDERSignature } from './der';
import { findClientDataIndices } from './indices';
import { computeAssertionDigest } from './digest';
import type { Coordinate, ParsedAssertion } from './types';

export interface RawAssertionInput {
  authenticatorData: Uint8Array;
  clientDataJSON: Uint8Array;
  signature: Uint8Array;
}

/**
 * Pure, framework-free parser for WebAuthn get assertion responses.
 *
 * Enforces strict DER parsing, extracts low-s and raw r/s scalars, finds clientDataJSON
 * substrings for contract verification, and computes the 32-byte precompile digest.
 */
export function parseAssertionResponse(input: RawAssertionInput): ParsedAssertion {
  const { authenticatorData, clientDataJSON, signature } = input;
  const clientDataJSONText = new TextDecoder().decode(clientDataJSON);

  const der = parseDERSignature(signature);
  const indices = findClientDataIndices(clientDataJSON);
  const digest = computeAssertionDigest(authenticatorData, clientDataJSON);

  return {
    authenticatorData,
    authenticatorDataHex: to0xHex(authenticatorData),
    clientDataJSON,
    clientDataJSONText,
    signatureDER: signature,
    r: der.r,
    s: der.s,
    sLow: der.sLow,
    rHex: to0xHex(der.r, 32),
    sHex: to0xHex(der.s, 32),
    sLowHex: to0xHex(der.sLow, 32),
    defaultForm: der.defaultForm,
    typeIndex: indices.typeIndex,
    challengeIndex: indices.challengeIndex,
    digest,
    digestHex: to0xHex(digest, 32),
  };
}

/**
 * Parses a SubjectPublicKeyInfo (SPKI) DER buffer, validates that it is a P-256 key,
 * and extracts qx and qy coordinates.
 *
 * Uses WebCrypto importKey/exportKey (JWK) for standard-compliant parsing and strict curve checking.
 * Rejects non-P-256 keys.
 */
export async function parseP256PublicKeySPKI(
  spkiBytes: Uint8Array
): Promise<{ qx: Coordinate; qy: Coordinate }> {
  let key: CryptoKey;
  try {
    key = await globalThis.crypto.subtle.importKey(
      'spki',
      spkiBytes as BufferSource,
      { name: 'ECDSA', namedCurve: 'P-256' },
      true,
      ['verify']
    );
  } catch (err) {
    throw new Error(`Failed to import SPKI public key (rejected as non-P-256): ${(err as Error).message}`);
  }

  const jwk = await globalThis.crypto.subtle.exportKey('jwk', key);
  if (jwk.crv !== 'P-256' || !jwk.x || !jwk.y) {
    throw new Error(`Rejected non-P-256 key: curve is "${jwk.crv}"`);
  }

  const xBytes = base64urlDecode(jwk.x);
  const yBytes = base64urlDecode(jwk.y);

  if (xBytes.length !== 32 || yBytes.length !== 32) {
    throw new Error(`Invalid coordinate length: expected 32 bytes each, got x=${xBytes.length}, y=${yBytes.length}`);
  }

  const qxBigInt = bytesToBigInt(xBytes);
  const qyBigInt = bytesToBigInt(yBytes);

  return {
    qx: { bigint: qxBigInt, hex: to0xHex(qxBigInt, 32) },
    qy: { bigint: qyBigInt, hex: to0xHex(qyBigInt, 32) },
  };
}
