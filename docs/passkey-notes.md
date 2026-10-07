# AgentPass Passkey & WebAuthn Architecture Notes

This document details the cryptographic specifications, browser integration mechanics, and on-chain verification pipeline for WebAuthn P-256 passkey authentication in the AgentPass protocol on Monad Testnet (Chain ID `10143`).

---

## 1. Signed-Message Structure

WebAuthn authenticators do not sign arbitrary raw messages. Instead, they sign an envelope constructed collaboratively by the browser and the authenticator hardware:

$$\text{digest} = \text{SHA-256}\Big(\text{authenticatorData} \parallel \text{SHA-256}(\text{clientDataJSON})\Big)$$

### Field Breakdown

1. **`clientDataJSON`**:
   - A UTF-8 encoded JSON string constructed by the browser containing:
     - `type`: Must equal `"webauthn.get"` for assertions.
     - `challenge`: Base64url-encoded 32-byte challenge (in AgentPass, this is the EIP-712 typed action hash `actionHash(...)`).
     - `origin`: The full origin URL of the calling web application (e.g. `http://localhost:3000`).
     - `crossOrigin`: Boolean indicating cross-origin framing (`false`).
   - The clientData hash is computed as $\text{clientDataHash} = \text{SHA-256}(\text{clientDataJSON})$.

2. **`authenticatorData`**:
   - A raw byte stream generated inside the secure authenticator chip:
     - `rpIdHash` (Bytes `0..31`): SHA-256 hash of the Relying Party ID (`rpId`).
     - `flags` (Byte `32`): Bitmask containing:
       - Bit 0 (`0x01`): **User Presence (UP)** — user touched or confirmed the authenticator.
       - Bit 2 (`0x04`): **User Verification (UV)** — user passed biometrics (TouchID/FaceID) or device PIN.
     - `signCount` (Bytes `33..36`): 32-bit big-endian monotonic signature counter.
     - *Length:* 37 bytes for basic assertion (without extension payloads).

3. **DER-Encoded Signature**:
   - The authenticator returns an ASN.1 DER sequence containing two integers $(r, s)$:
     `0x30 || seqLen || 0x02 || rLen || rBytes || 0x02 || sLen || sBytes`
   - Strict DER parsing unpacks $r$ and $s$ into 32-byte scalars, stripping leading padding zeros, rejecting negative integers, and checking curve order boundaries ($1 \le r, s < n$).

4. **Monad Precompile Input (`0x0100`)**:
   - The native secp256r1 precompile at `0x0000000000000000000000000000000000000100` requires exactly 160 contiguous bytes:
     $$\text{input} = \text{hash}[32] \parallel r[32] \parallel s[32] \parallel qx[32] \parallel qy[32]$$
   - It returns a 32-byte integer with value `1` if valid, or `0x` / empty / revert if invalid.

---

## 2. RP ID Binding Rule

Passkeys are strictly bound by the authenticator to the **Relying Party ID (`rpId`)**:

- In development: `rpId = "localhost"`.
- In production: `rpId = "agentpass.xyz"` (or the deployed domain).
- **Domain Binding Constraint:** A passkey created on `localhost` **CANNOT** be used on any other domain. Authenticators compute `sha256(rpId)` and verify that the calling web origin matches or is a subdomain of `rpId`.
- **Browser Security Context:** WebAuthn requires a Secure Context (`https://` or `http://localhost`). Plain HTTP on other hostnames will fail.

---

## 3. Origin for Demo Recording

- **Status:** **OPEN** (Decision to be finalized in **Phase 22**).
- For local testing and development, `http://localhost:3000` is the active origin.
- For the final demo video and submission recording, the decision between recording on `http://localhost:3000` versus a custom domain (e.g. via `/etc/hosts` or local HTTPS proxy) remains open and will be evaluated alongside the frontend hosting setup in Phase 22.

---

## 4. Recovery-Based Login Flow (6 Steps)

Because WebAuthn public keys are generated client-side by authenticators without revealing the user's identity upfront, AgentPass implements a 6-step recovery-based authentication flow for existing passkey owners:

1. **User Initiation:** User clicks "Sign in with Passkey".
2. **Challenge Creation:** The frontend generates an ephemeral 32-byte random challenge.
3. **Discoverable Assertion Request:** The frontend calls `navigator.credentials.get({ publicKey: { challenge, userVerification: "required" } })` without passing `allowCredentials`, prompting the platform authenticator to present resident passkeys.
4. **Biometric Verification:** The user completes TouchID/FaceID/Windows Hello verification. The authenticator returns `authenticatorData`, `clientDataJSON`, and signature $(r, s)$.
5. **Candidate Public Key Recovery:**
   - ECDSA over secp256r1 allows recovering the public key from the signature and message digest up to two possible curve points corresponding to recovery IDs $v \in \{0, 1\}$.
   - The frontend calls `recoverPublicKeyCandidates(authenticatorData, clientDataJSON, r, s)`, yielding candidates $(qx_0, qy_0)$ and $(qx_1, qy_1)$.
   - For each candidate, the frontend derives the deterministic account ID:
     $$\text{accountId}_i = \text{keccak256}\big(\text{abi.encode}(qx_i, qy_i)\big)$$
6. **On-Chain Identity Resolution:**
   - The relayer queries `SpendingGuard.accountOf(accountId)` on Monad Testnet for both candidate IDs.
   - The candidate whose account exists on-chain is selected as the authenticated user account.

---

## 5. User-Verification Expectations

- All credential creation (`createPasskey`) and assertion (`signChallenge`) operations explicitly configure:
  ```json
  { "userVerification": "required" }
  ```
- **Security Guarantee:** Enforces that bit 2 of the `flags` byte in `authenticatorData` (UV flag) is always set. A passive touch (UP only) without biometric confirmation or PIN entry is rejected by local verification and smart contract guards.

---

## 6. Multi-Device and Recovery Limits (MVP Scope)

- **Single Passkey Per Account:** For the MVP, each AgentPass account is bound to exactly one P-256 public key pair $(qx, qy)$. Adding a second passkey or configuring fallback signer keys is intentionally out of scope.
- **Passkey Synchronization:** Modern operating systems sync passkeys seamlessly (Apple iCloud Keychain, Google Password Manager, 1Password, Bitwarden). For users using ecosystem passkeys, multi-device support is provided automatically at the authenticator layer without protocol changes.
- **Hardware Token Limit:** For hardware-bound physical authenticators (e.g. YubiKey without cloud sync), loss of the physical device means loss of vault owner control. Future phases may introduce multi-sig recovery guardians.

---

## 7. Mapping to Solidity `WebAuthnAuth` Struct

In `contracts/src/interfaces/ISpendingGuard.sol`, owner signatures are passed using the `WebAuthnAuth` struct:

```solidity
struct WebAuthnAuth {
    bytes authenticatorData;    // Raw authenticator data bytes
    string clientDataJSON;      // JSON client data string containing challenge and origin
    uint256 challengeIndex;     // Byte offset of the challenge in clientDataJSON
    uint256 typeIndex;          // Byte offset of "type":"webauthn.get" in clientDataJSON
    uint256 r;                  // P-256 signature scalar r
    uint256 s;                  // P-256 signature scalar s
}
```

### TypeScript Mapping (`toWebAuthnAuth`)

The TypeScript library's `toWebAuthnAuth(assertion)` maps parsed assertion parameters directly into an ABI-encodable shape:

| Solidity Field | TypeScript Type | Source & Verification |
| --- | --- | --- |
| `authenticatorData` | `0x${string}` | Hex-encoded raw authenticator data bytes (contains rpIdHash and flags). |
| `clientDataJSON` | `string` | UTF-8 JSON text returned by authenticator containing challenge. |
| `challengeIndex` | `bigint` | Byte offset of substring `"challenge":"` in `clientDataJSON`. |
| `typeIndex` | `bigint` | Byte offset of substring `"type":"webauthn.get"` in `clientDataJSON`. |
| `r` | `bigint` | 32-byte scalar $r$ extracted from strict DER parsing. |
| `s` | `bigint` | 32-byte scalar $s$ extracted from strict DER parsing. |

### Note on Signature Malleability & Low-s

In ECDSA over secp256r1, both $(r, s)$ and $(r, n - s)$ are mathematically valid signatures over the same message hash. Authenticators typically emit raw $s$, which may be in the upper half of the curve ($s > n/2$).
In the AgentPass protocol:
- Both raw $s$ and normalized $s_{low}$ are accepted by Monad's native `0x0100` precompile.
- Signature malleability is completely harmless because every state-modifying owner action consumes the account's sequential replay nonce atomically upon execution, preventing replay of any malleable variant.
