/**
 * Coordinate representation for a 32-byte curve point coordinate.
 */
export interface Coordinate {
  bigint: bigint;
  hex: `0x${string}`;
}

/**
 * Result returned upon passkey creation.
 */
export interface PasskeyCreationResult {
  credentialId: string;
  qx: Coordinate;
  qy: Coordinate;
  accountId: `0x${string}`;
}

/**
 * Result of parsing a WebAuthn assertion.
 */
export interface ParsedAssertion {
  authenticatorData: Uint8Array;
  authenticatorDataHex: `0x${string}`;
  clientDataJSON: Uint8Array;
  clientDataJSONText: string;
  signatureDER: Uint8Array;
  r: bigint;
  s: bigint;
  sLow: bigint;
  rHex: `0x${string}`;
  sHex: `0x${string}`;
  sLowHex: `0x${string}`;
  defaultForm: 'raw';
  typeIndex: number;
  challengeIndex: number;
  digest: Uint8Array;
  digestHex: `0x${string}`;
}

/**
 * Candidate P-256 public key recovered from an assertion signature.
 */
export interface PublicKeyCandidate {
  recoveryBit: number;
  qx: Coordinate;
  qy: Coordinate;
  accountId: `0x${string}`;
}

/**
 * Solidity contract struct representation for WebAuthnAuth in ISpendingGuard.sol:
 * struct WebAuthnAuth {
 *     bytes authenticatorData;
 *     string clientDataJSON;
 *     uint256 challengeIndex;
 *     uint256 typeIndex;
 *     uint256 r;
 *     uint256 s;
 * }
 */
export interface WebAuthnAuthStruct {
  authenticatorData: `0x${string}`;
  clientDataJSON: string;
  challengeIndex: bigint;
  typeIndex: bigint;
  r: bigint;
  s: bigint;
}

/**
 * Result of local assertion verification.
 */
export interface LocalVerificationResult {
  valid: boolean;
  reasons: string[];
}
