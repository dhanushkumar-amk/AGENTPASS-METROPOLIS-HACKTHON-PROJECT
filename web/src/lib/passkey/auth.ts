import { to0xHex } from './encoding';
import type { ParsedAssertion, WebAuthnAuthStruct } from './types';

export interface WebAuthnAuthInput {
  authenticatorData: Uint8Array | `0x${string}`;
  clientDataJSON: Uint8Array | string;
  challengeIndex: number | bigint;
  typeIndex: number | bigint;
  r: bigint;
  s: bigint;
}

/**
 * Maps a parsed assertion or assertion fields to the contract struct shape `WebAuthnAuth`:
 *
 * ```solidity
 * struct WebAuthnAuth {
 *     bytes authenticatorData;
 *     string clientDataJSON;
 *     uint256 challengeIndex;
 *     uint256 typeIndex;
 *     uint256 r;
 *     uint256 s;
 * }
 * ```
 *
 * Returned fields are directly ABI-encodable via viem or ethers.
 */
export function toWebAuthnAuth(
  assertion: ParsedAssertion | WebAuthnAuthInput
): WebAuthnAuthStruct {
  const authDataHex = typeof assertion.authenticatorData === 'string'
    ? (assertion.authenticatorData.startsWith('0x')
        ? (assertion.authenticatorData as `0x${string}`)
        : to0xHex(assertion.authenticatorData))
    : to0xHex(assertion.authenticatorData);

  const clientDataJSONStr = typeof assertion.clientDataJSON === 'string'
    ? assertion.clientDataJSON
    : new TextDecoder().decode(assertion.clientDataJSON);

  return {
    authenticatorData: authDataHex,
    clientDataJSON: clientDataJSONStr,
    challengeIndex: BigInt(assertion.challengeIndex),
    typeIndex: BigInt(assertion.typeIndex),
    r: assertion.r,
    s: assertion.s,
  };
}
