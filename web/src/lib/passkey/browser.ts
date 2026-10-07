import { base64urlDecode, base64urlEncode } from './encoding';
import { parseAssertionResponse, parseP256PublicKeySPKI } from './parser';
import { accountIdOf } from './recovery';
import type { ParsedAssertion, PasskeyCreationResult } from './types';

/**
 * Checks whether WebAuthn API is supported in current browser runtime.
 */
export function isWebAuthnSupported(): boolean {
  return (
    typeof window !== 'undefined' &&
    typeof window.navigator !== 'undefined' &&
    typeof window.navigator.credentials !== 'undefined' &&
    typeof window.navigator.credentials.create === 'function' &&
    typeof window.navigator.credentials.get === 'function'
  );
}

/**
 * Creates a new WebAuthn P-256 (ES256) passkey for the specified RP ID and user name.
 *
 * Requirements:
 * - Alg: -7 (ES256 / P-256)
 * - userVerification: "required"
 * - residentKey: "preferred"
 * - attestation: "none"
 * - SPKI extraction via getPublicKey() with WebCrypto validation
 * - Rejects any key that is not P-256.
 *
 * @param rpId Relying party ID (e.g. "localhost" in development). Note: passkeys are bound to rpId!
 * @param userName Human-readable user name for authenticator UI.
 */
export async function createPasskey(
  rpId: string,
  userName = 'AgentPass Owner'
): Promise<PasskeyCreationResult> {
  if (!isWebAuthnSupported()) {
    throw new Error('WebAuthn is not supported in this browser or environment.');
  }

  const userId = globalThis.crypto.getRandomValues(new Uint8Array(16));
  const challenge = globalThis.crypto.getRandomValues(new Uint8Array(32));

  const credential = (await navigator.credentials.create({
    publicKey: {
      rp: {
        id: rpId,
        name: 'AgentPass',
      },
      user: {
        id: userId,
        name: userName,
        displayName: userName,
      },
      pubKeyCredParams: [
        {
          type: 'public-key',
          alg: -7, // ES256 (P-256 with SHA-256)
        },
      ],
      authenticatorSelection: {
        userVerification: 'required',
        residentKey: 'preferred',
        requireResidentKey: false,
      },
      attestation: 'none',
      challenge,
      timeout: 60000,
    },
  })) as PublicKeyCredential | null;

  if (!credential) {
    throw new Error('Passkey creation cancelled or returned empty credential.');
  }

  const rawId = new Uint8Array(credential.rawId);
  const credentialId = base64urlEncode(rawId);

  const response = credential.response as AuthenticatorAttestationResponse;
  if (!response.getPublicKey) {
    throw new Error('AuthenticatorAttestationResponse does not support getPublicKey()');
  }

  const spkiBuffer = response.getPublicKey();
  if (!spkiBuffer) {
    throw new Error('getPublicKey() returned null SPKI public key');
  }

  const { qx, qy } = await parseP256PublicKeySPKI(new Uint8Array(spkiBuffer));
  const accountId = accountIdOf(qx.bigint, qy.bigint);

  return {
    credentialId,
    qx,
    qy,
    accountId,
  };
}

/**
 * Signs a 32-byte challenge with an existing or resident passkey.
 *
 * Options:
 * - userVerification: "required"
 * - challenge: 32-byte Uint8Array
 *
 * Returns parsed assertion with raw r/s, normalized sLow, typeIndex, challengeIndex,
 * and precompile digest.
 *
 * @param credentialId Optional credential ID base64url string. If undefined, requests resident key.
 * @param challenge32 32-byte challenge buffer to sign.
 * @param rpId Optional RP ID (defaults to current window.location.hostname).
 */
export async function signChallenge(
  credentialId: string | undefined,
  challenge32: Uint8Array,
  rpId?: string
): Promise<ParsedAssertion> {
  if (!isWebAuthnSupported()) {
    throw new Error('WebAuthn is not supported in this browser or environment.');
  }

  if (challenge32.length !== 32) {
    throw new Error(`Challenge must be exactly 32 bytes (got ${challenge32.length})`);
  }

  const allowCredentials: PublicKeyCredentialDescriptor[] = credentialId
    ? [
        {
          type: 'public-key',
          id: base64urlDecode(credentialId) as unknown as ArrayBuffer,
        },
      ]
    : [];

  const credential = (await navigator.credentials.get({
    publicKey: {
      challenge: challenge32 as unknown as ArrayBuffer,
      userVerification: 'required',
      ...(allowCredentials.length > 0 ? { allowCredentials } : {}),
      ...(rpId ? { rpId } : {}),
      timeout: 60000,
    },
  })) as PublicKeyCredential | null;

  if (!credential) {
    throw new Error('Passkey assertion ceremony was cancelled or returned empty.');
  }

  const response = credential.response as AuthenticatorAssertionResponse;
  const authenticatorData = new Uint8Array(response.authenticatorData);
  const clientDataJSON = new Uint8Array(response.clientDataJSON);
  const signature = new Uint8Array(response.signature);

  return parseAssertionResponse({
    authenticatorData,
    clientDataJSON,
    signature,
  });
}
