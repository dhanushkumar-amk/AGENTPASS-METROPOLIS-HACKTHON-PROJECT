/**
 * Finds the byte offsets of the key verification substrings in clientDataJSON.
 *
 * Follows OpenZeppelin and Solady WebAuthn contract conventions:
 * - `typeIndex`: byte offset where `"type":"webauthn.get"` begins.
 * - `challengeIndex`: byte offset where `"challenge":"` begins.
 *
 * Phase 14 smart contract verification validates both indices. Keeping them
 * computed in this single canonical function guarantees frontend and contract parity.
 */
export function findClientDataIndices(clientDataJSON: string | Uint8Array): {
  typeIndex: number;
  challengeIndex: number;
} {
  const bytes = typeof clientDataJSON === 'string'
    ? new TextEncoder().encode(clientDataJSON)
    : clientDataJSON;

  function findByteOffset(target: string): number {
    const targetBytes = new TextEncoder().encode(target);
    const limit = bytes.length - targetBytes.length;

    for (let i = 0; i <= limit; i++) {
      let match = true;
      for (let j = 0; j < targetBytes.length; j++) {
        if (bytes[i + j] !== targetBytes[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        return i;
      }
    }
    return -1;
  }

  const typeTarget = '"type":"webauthn.get"';
  const challengeTarget = '"challenge":"';

  const typeIndex = findByteOffset(typeTarget);
  if (typeIndex === -1) {
    throw new Error(`Substring '${typeTarget}' not found in clientDataJSON`);
  }

  const challengeIndex = findByteOffset(challengeTarget);
  if (challengeIndex === -1) {
    throw new Error(`Substring '${challengeTarget}' not found in clientDataJSON`);
  }

  return {
    typeIndex,
    challengeIndex,
  };
}
