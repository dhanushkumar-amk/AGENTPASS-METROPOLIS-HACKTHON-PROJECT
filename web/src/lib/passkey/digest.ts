import { concat, sha256 } from './encoding';

/**
 * Computes the 32-byte hash digest signed by the WebAuthn authenticator.
 *
 * Formula:
 *   clientDataHash = sha256(clientDataJSON)
 *   signedMessage  = authenticatorData || clientDataHash
 *   digest         = sha256(signedMessage)
 *
 * This matches the RIP-7212 / EIP-7951 precompile input requirements for `hash`.
 */
export function computeAssertionDigest(
  authenticatorData: Uint8Array,
  clientDataJSON: string | Uint8Array
): Uint8Array {
  const clientDataBytes = typeof clientDataJSON === 'string'
    ? new TextEncoder().encode(clientDataJSON)
    : clientDataJSON;

  const clientDataHash = sha256(clientDataBytes);
  const signedMessage = concat([authenticatorData, clientDataHash]);
  return sha256(signedMessage);
}
