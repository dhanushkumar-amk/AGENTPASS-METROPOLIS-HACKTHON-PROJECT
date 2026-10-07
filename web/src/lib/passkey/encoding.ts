import { sha256 as nobleSha256 } from '@noble/hashes/sha256';
import { keccak_256 as nobleKeccak256 } from '@noble/hashes/sha3';

/**
 * Encodes bytes to lowercase hex string without 0x prefix.
 */
export function toHex(bytes: Uint8Array): string {
  let hex = '';
  for (let i = 0; i < bytes.length; i++) {
    hex += bytes[i].toString(16).padStart(2, '0');
  }
  return hex;
}

/**
 * Strips optional 0x prefix from a hex string.
 */
export function strip0x(hex: string): string {
  return hex.startsWith('0x') || hex.startsWith('0X') ? hex.slice(2) : hex;
}

/**
 * Decodes a hex string (with or without 0x prefix) to Uint8Array.
 */
export function fromHex(hex: string): Uint8Array {
  const clean = strip0x(hex);
  if (clean.length % 2 !== 0) {
    throw new Error(`Invalid hex string length: ${clean.length}`);
  }
  const bytes = new Uint8Array(clean.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    const byte = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
    if (Number.isNaN(byte)) {
      throw new Error(`Invalid hex byte at index ${i * 2}`);
    }
    bytes[i] = byte;
  }
  return bytes;
}

/**
 * Formats a byte array, bigint, or hex string as a 0x-prefixed hex string.
 * Optionally pads to lengthBytes.
 */
export function to0xHex(val: Uint8Array | bigint | string, lengthBytes?: number): `0x${string}` {
  let hexStr: string;
  if (typeof val === 'bigint') {
    hexStr = val.toString(16);
    if (lengthBytes) {
      hexStr = hexStr.padStart(lengthBytes * 2, '0');
    } else if (hexStr.length % 2 !== 0) {
      hexStr = '0' + hexStr;
    }
  } else if (typeof val === 'string') {
    hexStr = strip0x(val);
    if (lengthBytes) {
      hexStr = hexStr.padStart(lengthBytes * 2, '0');
    }
  } else {
    hexStr = toHex(val);
    if (lengthBytes && hexStr.length < lengthBytes * 2) {
      hexStr = hexStr.padStart(lengthBytes * 2, '0');
    }
  }
  return `0x${hexStr.toLowerCase()}` as `0x${string}`;
}

/**
 * Converts big-endian bytes to BigInt.
 */
export function bytesToBigInt(bytes: Uint8Array): bigint {
  let result = BigInt(0);
  for (let i = 0; i < bytes.length; i++) {
    result = (result << BigInt(8)) | BigInt(bytes[i]);
  }
  return result;
}

/**
 * Converts BigInt to big-endian bytes with specified length (default 32).
 */
export function bigIntToBytes(val: bigint, length = 32): Uint8Array {
  let hex = val.toString(16);
  if (hex.length > length * 2) {
    throw new Error(`BigInt value ${val} exceeds requested length ${length} bytes`);
  }
  hex = hex.padStart(length * 2, '0');
  return fromHex(hex);
}

/**
 * Encodes bytes or ArrayBuffer to base64url string without padding.
 */
export function base64urlEncode(buffer: Uint8Array | ArrayBuffer): string {
  const bytes = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
  let binary = '';
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  const base64 = typeof btoa !== 'undefined'
    ? btoa(binary)
    : Buffer.from(bytes).toString('base64');
  return base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/**
 * Decodes base64url string to Uint8Array.
 */
export function base64urlDecode(base64url: string): Uint8Array {
  let base64 = base64url.replace(/-/g, '+').replace(/_/g, '/');
  while (base64.length % 4 !== 0) {
    base64 += '=';
  }
  if (typeof atob !== 'undefined') {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  }
  return new Uint8Array(Buffer.from(base64, 'base64'));
}

/**
 * SHA-256 hash helper using @noble/hashes.
 */
export function sha256(data: Uint8Array): Uint8Array {
  return nobleSha256(data);
}

/**
 * Keccak-256 hash helper using @noble/hashes.
 */
export function keccak256(data: Uint8Array): Uint8Array {
  return nobleKeccak256(data);
}

/**
 * Concatenates multiple Uint8Arrays into one.
 */
export function concat(arrays: Uint8Array[]): Uint8Array {
  const totalLength = arrays.reduce((acc, curr) => acc + curr.length, 0);
  const result = new Uint8Array(totalLength);
  let offset = 0;
  for (const arr of arrays) {
    result.set(arr, offset);
    offset += arr.length;
  }
  return result;
}
