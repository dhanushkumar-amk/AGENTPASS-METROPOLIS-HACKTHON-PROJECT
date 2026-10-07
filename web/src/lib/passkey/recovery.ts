import { p256 } from '@noble/curves/p256';
import { bigIntToBytes, concat, fromHex, keccak256, strip0x, to0xHex } from './encoding';
import { computeAssertionDigest } from './digest';
import type { Coordinate, PublicKeyCandidate } from './types';

/**
 * Computes the canonical AgentPass accountId for a P-256 public key (qx, qy).
 *
 * Solidity specification (ISpendingGuard.sol):
 *   accountId = keccak256(abi.encode(qx, qy))
 *
 * Encoding details:
 *   In Solidity ABI encoding, two `bytes32` values `abi.encode(qx, qy)` are concatenated
 *   sequentially into a contiguous 64-byte payload (32 bytes of qx followed by 32 bytes of qy).
 *   The 32-byte Keccak-256 hash of this 64-byte payload produces the accountId.
 *
 * @param qx Public key x-coordinate as bigint, hex string, or 32-byte Uint8Array.
 * @param qy Public key y-coordinate as bigint, hex string, or 32-byte Uint8Array.
 * @returns 0x-prefixed 32-byte hex account identifier.
 */
export function accountIdOf(
  qx: bigint | string | Uint8Array,
  qy: bigint | string | Uint8Array
): `0x${string}` {
  const qxBytes = typeof qx === 'bigint'
    ? bigIntToBytes(qx, 32)
    : typeof qx === 'string'
      ? fromHex(strip0x(qx).padStart(64, '0'))
      : qx;

  const qyBytes = typeof qy === 'bigint'
    ? bigIntToBytes(qy, 32)
    : typeof qy === 'string'
      ? fromHex(strip0x(qy).padStart(64, '0'))
      : qy;

  if (qxBytes.length !== 32 || qyBytes.length !== 32) {
    throw new Error(`Coordinates must be exactly 32 bytes each (got qx=${qxBytes.length}, qy=${qyBytes.length})`);
  }

  const packed = concat([qxBytes, qyBytes]);
  const hash = keccak256(packed);
  return to0xHex(hash, 32);
}

/**
 * Recovers the two candidate P-256 public keys (qx, qy) from one assertion signature.
 *
 * In ECDSA over secp256r1, an assertion signature (r, s) and message digest yield two
 * mathematical curve point candidates corresponding to recovery bits v = 0 and v = 1.
 *
 * Login flow (Phase 16) invokes this function when an owner signs a login challenge with an
 * existing passkey, recovering both candidates and querying the SpendingGuard contract on-chain
 * to find the matching account whose `accountId` exists.
 *
 * @param authenticatorData Raw authenticator data bytes.
 * @param clientDataJSON Raw UTF-8 bytes or JSON string of clientDataJSON.
 * @param r Signature scalar r.
 * @param s Signature scalar s (can be raw or low-s).
 * @returns Array of candidate public keys with coordinates and derived accountId.
 */
export function recoverPublicKeyCandidates(
  authenticatorData: Uint8Array,
  clientDataJSON: Uint8Array | string,
  r: bigint,
  s: bigint
): PublicKeyCandidate[] {
  const digest = computeAssertionDigest(authenticatorData, clientDataJSON);
  const candidates: PublicKeyCandidate[] = [];

  for (const recoveryBit of [0, 1]) {
    try {
      const sigWithRecovery = new p256.Signature(r, s).addRecoveryBit(recoveryBit);
      const recoveredPoint = sigWithRecovery.recoverPublicKey(digest);

      const qxCoord: Coordinate = {
        bigint: recoveredPoint.x,
        hex: to0xHex(recoveredPoint.x, 32),
      };

      const qyCoord: Coordinate = {
        bigint: recoveredPoint.y,
        hex: to0xHex(recoveredPoint.y, 32),
      };

      const accountId = accountIdOf(qxCoord.bigint, qyCoord.bigint);

      candidates.push({
        recoveryBit,
        qx: qxCoord,
        qy: qyCoord,
        accountId,
      });
    } catch {
      // If a recovery bit does not yield a valid curve point, ignore it
    }
  }

  return candidates;
}
