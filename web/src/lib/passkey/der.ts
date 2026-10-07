import { bytesToBigInt } from './encoding';

/**
 * secp256r1 (P-256) curve order n.
 */
export const P256_N = BigInt('0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551');

/**
 * Half-order of secp256r1: floor(n / 2).
 */
export const P256_HALF_N = P256_N >> BigInt(1);

export interface ParsedDERSignature {
  r: bigint;
  s: bigint;
  sLow: bigint;
  /**
   * The default form returned by authenticators is raw `s` as parsed from the DER signature.
   * Both `s` (raw) and `sLow` (normalized) are provided.
   * In AgentPass smart contracts, owner action nonce consumption ensures signature
   * malleability between s and (n - s) is harmless against replay attacks.
   */
  defaultForm: 'raw';
}

/**
 * Strictly parses a DER-encoded ECDSA P-256 signature into raw scalars r, s and normalized sLow.
 *
 * Enforces strict DER rules:
 * - Must start with SEQUENCE tag 0x30.
 * - Sequence length must match the remaining bytes exactly (no trailing or extra bytes).
 * - Must contain exactly two INTEGER tags (0x02) for r and s.
 * - Rejects negative integers (first byte having high bit set without 0x00 prefix).
 * - Rejects redundant leading zeros (leading 0x00 is only valid if next byte has high bit set).
 * - Handles 31, 32, and 33-byte integers (33-byte must start with 0x00).
 * - Rejects integers with length 0 or length > 33 bytes.
 * - Validates that 0 < r < n and 0 < s < n.
 */
export function parseDERSignature(der: Uint8Array): ParsedDERSignature {
  if (der.length < 7) {
    throw new Error(`DER signature too short: ${der.length} bytes`);
  }

  // 1. SEQUENCE tag
  if (der[0] !== 0x30) {
    throw new Error(`Invalid DER sequence tag: expected 0x30, got 0x${der[0].toString(16)}`);
  }

  // 2. SEQUENCE length
  let seqLen: number;
  let offset: number;
  if (der[1] & 0x80) {
    const lenBytes = der[1] & 0x7f;
    if (lenBytes === 1) {
      seqLen = der[2];
      offset = 3;
    } else {
      throw new Error(`Unsupported multi-byte DER sequence length: ${lenBytes} bytes`);
    }
  } else {
    seqLen = der[1];
    offset = 2;
  }

  if (der.length !== offset + seqLen) {
    throw new Error(`DER length mismatch: declared ${seqLen} bytes, buffer has ${der.length - offset} bytes`);
  }

  // 3. Parse r INTEGER
  if (offset >= der.length || der[offset] !== 0x02) {
    throw new Error(`Expected INTEGER tag 0x02 for r at offset ${offset}`);
  }
  offset++;

  if (offset >= der.length) {
    throw new Error('Truncated DER signature before r length');
  }
  const rLen = der[offset++];
  if (rLen === 0) {
    throw new Error('Integer r length cannot be 0');
  }
  if (offset + rLen > der.length) {
    throw new Error('Integer r extends beyond buffer');
  }

  const rBytes = der.subarray(offset, offset + rLen);
  offset += rLen;

  // Length check: max 33 bytes for 256-bit scalar
  if (rBytes.length > 33) {
    throw new Error(`Integer r too long: ${rBytes.length} bytes (max 33 for P-256)`);
  }
  // Strict check: negative integers
  if ((rBytes[0] & 0x80) !== 0) {
    throw new Error('Integer r is negative (high bit set without 0x00 prefix)');
  }
  // Strict check: redundant leading zeros
  if (rBytes.length > 1 && rBytes[0] === 0x00 && (rBytes[1] & 0x80) === 0) {
    throw new Error('Non-minimal DER integer r (redundant leading 0x00)');
  }
  if (rBytes.length === 33 && rBytes[0] !== 0x00) {
    throw new Error('33-byte integer r must start with 0x00');
  }

  const r = bytesToBigInt(rBytes);

  // 4. Parse s INTEGER
  if (offset >= der.length || der[offset] !== 0x02) {
    throw new Error(`Expected INTEGER tag 0x02 for s at offset ${offset}`);
  }
  offset++;

  if (offset >= der.length) {
    throw new Error('Truncated DER signature before s length');
  }
  const sLen = der[offset++];
  if (sLen === 0) {
    throw new Error('Integer s length cannot be 0');
  }
  if (offset + sLen > der.length) {
    throw new Error('Integer s extends beyond buffer');
  }

  const sBytes = der.subarray(offset, offset + sLen);
  offset += sLen;

  // Length check: max 33 bytes for 256-bit scalar
  if (sBytes.length > 33) {
    throw new Error(`Integer s too long: ${sBytes.length} bytes (max 33 for P-256)`);
  }
  // Strict check: negative integers
  if ((sBytes[0] & 0x80) !== 0) {
    throw new Error('Integer s is negative (high bit set without 0x00 prefix)');
  }
  // Strict check: redundant leading zeros
  if (sBytes.length > 1 && sBytes[0] === 0x00 && (sBytes[1] & 0x80) === 0) {
    throw new Error('Non-minimal DER integer s (redundant leading 0x00)');
  }
  if (sBytes.length === 33 && sBytes[0] !== 0x00) {
    throw new Error('33-byte integer s must start with 0x00');
  }

  const s = bytesToBigInt(sBytes);

  // 5. Ensure no extra bytes remaining
  if (offset !== der.length) {
    throw new Error(`Extra bytes remaining in DER signature after s: ${der.length - offset} bytes`);
  }

  // 6. Range checks
  if (r <= BigInt(0) || r >= P256_N) {
    throw new Error(`Scalar r out of valid curve range [1, n-1]: ${r}`);
  }
  if (s <= BigInt(0) || s >= P256_N) {
    throw new Error(`Scalar s out of valid curve range [1, n-1]: ${s}`);
  }

  // 7. Compute normalized low-s
  const sLow = s > P256_HALF_N ? P256_N - s : s;

  return {
    r,
    s,
    sLow,
    defaultForm: 'raw',
  };
}

/**
 * Encodes scalars r and s into strict canonical DER format.
 */
export function encodeDERSignature(r: bigint, s: bigint): Uint8Array {
  function encodeInteger(val: bigint): Uint8Array {
    if (val <= BigInt(0)) {
      throw new Error(`Cannot encode non-positive integer ${val}`);
    }
    let hex = val.toString(16);
    if (hex.length % 2 !== 0) {
      hex = '0' + hex;
    }
    const bytes: number[] = [];
    for (let i = 0; i < hex.length; i += 2) {
      bytes.push(parseInt(hex.slice(i, i + 2), 16));
    }
    // If high bit of first byte is set, prepend 0x00 to preserve positive sign in two's complement
    if ((bytes[0] & 0x80) !== 0) {
      bytes.unshift(0x00);
    }
    return new Uint8Array([0x02, bytes.length, ...bytes]);
  }

  const rEnc = encodeInteger(r);
  const sEnc = encodeInteger(s);
  const seqContent = new Uint8Array(rEnc.length + sEnc.length);
  seqContent.set(rEnc, 0);
  seqContent.set(sEnc, rEnc.length);

  const der = new Uint8Array(2 + seqContent.length);
  der[0] = 0x30;
  der[1] = seqContent.length;
  der.set(seqContent, 2);
  return der;
}
