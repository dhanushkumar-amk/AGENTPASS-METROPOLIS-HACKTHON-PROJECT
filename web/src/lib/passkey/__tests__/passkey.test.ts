import { describe, expect, it } from 'vitest';
import fs from 'fs';
import path from 'path';
import {
  base64urlDecode,
  base64urlEncode,
  bigIntToBytes,
  concat,
  fromHex,
  sha256,
  to0xHex,
} from '../encoding';
import {
  encodeDERSignature,
  P256_HALF_N,
  P256_N,
  parseDERSignature,
} from '../der';
import { findClientDataIndices } from '../indices';
import { computeAssertionDigest } from '../digest';
import { parseAssertionResponse, parseP256PublicKeySPKI } from '../parser';
import { accountIdOf, recoverPublicKeyCandidates } from '../recovery';
import { verifyAssertionLocal } from '../verify';
import { toWebAuthnAuth } from '../auth';
import {
  buildAuthenticatorData,
  buildClientDataJSON,
  createSoftwareKey,
  signSoftwareAssertion,
} from './software-authenticator';

describe('Passkey Module Tests', () => {
  // ----------------------------------------------------
  // 1. Base64url encoding and decoding
  // ----------------------------------------------------
  describe('base64url encoding and decoding', () => {
    it('round trips arbitrary binary payloads correctly', () => {
      const payloads = [
        new Uint8Array([0]),
        new Uint8Array([255, 254, 253, 0, 1, 2]),
        new TextEncoder().encode('Hello, AgentPass WebAuthn Protocol!'),
        new Uint8Array(32).fill(0xaa),
      ];

      for (const payload of payloads) {
        const encoded = base64urlEncode(payload);
        expect(encoded).not.toContain('+');
        expect(encoded).not.toContain('/');
        expect(encoded).not.toContain('=');
        const decoded = base64urlDecode(encoded);
        expect(decoded).toEqual(payload);
      }
    });
  });

  // ----------------------------------------------------
  // 2. accountIdOf and Fixed Vector
  // ----------------------------------------------------
  describe('accountIdOf derivation', () => {
    it('matches fixed vector computed via Solidity abi.encode(qx, qy)', () => {
      // Test vector from docs/decisions.md (Phase 5 P256 spike):
      // qx = 0xba3f24fb7b03f2e0720d70984fe1dbeafdc0133b371f6490fe02138b96a4250d
      // qy = 0xe99f23cb34ae6bdb48d2cd43aa8ae67d4271fa16b98fb6501bf41d2ebd0f7116
      // cast keccak(0xba3f...e99f...) = 0x4f087f5a08e26f140d8809c09227edc855ea80cebe48b16286d5af0990e1e582
      const qx = '0xba3f24fb7b03f2e0720d70984fe1dbeafdc0133b371f6490fe02138b96a4250d';
      const qy = '0xe99f23cb34ae6bdb48d2cd43aa8ae67d4271fa16b98fb6501bf41d2ebd0f7116';
      const expectedAccountId = '0x4f087f5a08e26f140d8809c09227edc855ea80cebe48b16286d5af0990e1e582';

      const derived = accountIdOf(qx, qy);
      expect(derived.toLowerCase()).toBe(expectedAccountId.toLowerCase());
    });
  });

  // ----------------------------------------------------
  // 3. Strict DER Signature Parsing & Normalization
  // ----------------------------------------------------
  describe('DER signature parser and edge cases', () => {
    it('round trips normal positive r and s scalars', () => {
      const r = 12345678901234567890n;
      const s = 98765432109876543210n;
      const der = encodeDERSignature(r, s);
      const parsed = parseDERSignature(der);
      expect(parsed.r).toBe(r);
      expect(parsed.s).toBe(s);
      expect(parsed.defaultForm).toBe('raw');
    });

    it('handles integers with leading 0x00 padding (high bit set)', () => {
      // 0x8000... has the most significant bit set in 32 bytes, requiring 0x00 prefix in DER
      const rWithHighBit = 0x8000000000000000000000000000000000000000000000000000000000000001n;
      const sNormal = 0x1234567890abcdefn;
      const der = encodeDERSignature(rWithHighBit, sNormal);

      // Verify that r starts with 0x00 in the DER stream
      expect(der[3]).toBe(33); // 33 bytes for r
      expect(der[4]).toBe(0x00); // leading zero

      const parsed = parseDERSignature(der);
      expect(parsed.r).toBe(rWithHighBit);
      expect(parsed.s).toBe(sNormal);
    });

    it('handles short integers (e.g. 31 bytes or smaller)', () => {
      const rShort = 0x12345678n; // 4 bytes
      const sShort = 0xabcdefn; // 3 bytes
      const der = encodeDERSignature(rShort, sShort);
      const parsed = parseDERSignature(der);
      expect(parsed.r).toBe(rShort);
      expect(parsed.s).toBe(sShort);
    });

    it('handles values near the curve order', () => {
      const rNearOrder = P256_N - 2n;
      const sNearOrder = P256_N - 1n;
      const der = encodeDERSignature(rNearOrder, sNearOrder);
      const parsed = parseDERSignature(der);
      expect(parsed.r).toBe(rNearOrder);
      expect(parsed.s).toBe(sNearOrder);
      // Since sNearOrder > halfN, sLow should be n - s = 1n
      expect(parsed.sLow).toBe(1n);
    });

    it('correctly computes low-s normalization and keeps raw s by default', () => {
      const r = 42n;
      // High s (above n / 2)
      const highS = P256_HALF_N + 100n;
      const derHigh = encodeDERSignature(r, highS);
      const parsedHigh = parseDERSignature(derHigh);
      expect(parsedHigh.s).toBe(highS);
      expect(parsedHigh.sLow).toBe(P256_N - highS);
      expect(parsedHigh.sLow).toBeLessThanOrEqual(P256_HALF_N);

      // Low s (below or equal n / 2)
      const lowS = P256_HALF_N - 50n;
      const derLow = encodeDERSignature(r, lowS);
      const parsedLow = parseDERSignature(derLow);
      expect(parsedLow.s).toBe(lowS);
      expect(parsedLow.sLow).toBe(lowS);
    });

    it('rejects DER with extra trailing bytes', () => {
      const der = encodeDERSignature(10n, 20n);
      const withTrailing = new Uint8Array([...der, 0x00, 0x01]);
      expect(() => parseDERSignature(withTrailing)).toThrow(/Extra bytes|mismatch/);
    });

    it('rejects negative integers (high bit set without 0x00 prefix)', () => {
      // Craft invalid DER where r has high bit set with no 0x00 byte
      // 0x30, 0x06, 0x02, 0x01, 0x80, 0x02, 0x01, 0x01
      const invalidDer = new Uint8Array([0x30, 0x06, 0x02, 0x01, 0x80, 0x02, 0x01, 0x01]);
      expect(() => parseDERSignature(invalidDer)).toThrow(/negative/);
    });

    it('rejects redundant leading zeros', () => {
      // 0x30, 0x07, 0x02, 0x02, 0x00, 0x01, 0x02, 0x01, 0x01
      // r is 0x00 0x01: high bit of 0x01 is NOT set, so leading 0x00 is redundant
      const redundantZeroDer = new Uint8Array([0x30, 0x07, 0x02, 0x02, 0x00, 0x01, 0x02, 0x01, 0x01]);
      expect(() => parseDERSignature(redundantZeroDer)).toThrow(/Non-minimal/);
    });

    it('rejects zero length integer or integer exceeding 33 bytes', () => {
      // Zero length r
      const zeroLenDer = new Uint8Array([0x30, 0x05, 0x02, 0x00, 0x02, 0x01, 0x01]);
      expect(() => parseDERSignature(zeroLenDer)).toThrow(/cannot be 0/);

      // Oversized r (34 bytes)
      const oversizedR = new Uint8Array(34).fill(0x01);
      oversizedR[0] = 0x00;
      const oversizedDer = new Uint8Array([0x30, 34 + 3 + 2, 0x02, 34, ...oversizedR, 0x02, 1, 1]);
      expect(() => parseDERSignature(oversizedDer)).toThrow(/too long/);
    });
  });

  // ----------------------------------------------------
  // 4. clientDataJSON Substrings and Indices
  // ----------------------------------------------------
  describe('clientDataJSON index extraction', () => {
    it('points to correct byte offsets for standard clientDataJSON', () => {
      const challenge = new Uint8Array(32).fill(7);
      const { jsonText, jsonBytes } = buildClientDataJSON(challenge);

      const { typeIndex, challengeIndex } = findClientDataIndices(jsonBytes);

      const typeSlice = jsonText.slice(typeIndex, typeIndex + '"type":"webauthn.get"'.length);
      expect(typeSlice).toBe('"type":"webauthn.get"');

      const challengeSlice = jsonText.slice(challengeIndex, challengeIndex + '"challenge":"'.length);
      expect(challengeSlice).toBe('"challenge":"');
    });

    it('accurately indexes clientDataJSON with extra prefix and suffix fields', () => {
      const challenge = new Uint8Array(32).fill(9);
      const obj = {
        customPrefix: 'some-prefix-data-here',
        type: 'webauthn.get',
        challenge: base64urlEncode(challenge),
        origin: 'http://localhost:3000',
        crossOrigin: false,
        extraSuffixField: { nested: 12345 },
      };
      const jsonText = JSON.stringify(obj);
      const { typeIndex, challengeIndex } = findClientDataIndices(jsonText);

      expect(jsonText.slice(typeIndex, typeIndex + '"type":"webauthn.get"'.length)).toBe(
        '"type":"webauthn.get"'
      );
      expect(jsonText.slice(challengeIndex, challengeIndex + '"challenge":"'.length)).toBe(
        '"challenge":"'
      );
    });

    it('throws when required substrings are missing', () => {
      const invalidJson = JSON.stringify({ type: 'other', challenge: '123' });
      expect(() => findClientDataIndices(invalidJson)).toThrow(/Substring .* not found/);
    });
  });

  // ----------------------------------------------------
  // 5. Assertion Digest Computation
  // ----------------------------------------------------
  describe('assertion digest computation', () => {
    it('matches manual step-by-step SHA-256 calculation', () => {
      const authData = buildAuthenticatorData('localhost', 0x05, 1);
      const challenge = new Uint8Array(32).fill(1);
      const { jsonBytes } = buildClientDataJSON(challenge);

      const digest = computeAssertionDigest(authData, jsonBytes);

      // Manual calculation
      const clientDataHash = sha256(jsonBytes);
      const signedMessage = concat([authData, clientDataHash]);
      const manualDigest = sha256(signedMessage);

      expect(digest).toEqual(manualDigest);
      expect(digest.length).toBe(32);
    });
  });

  // ----------------------------------------------------
  // 6. SPKI Public Key Parsing
  // ----------------------------------------------------
  describe('SPKI public key parsing', () => {
    it('successfully extracts qx and qy coordinates from standard P-256 SPKI', async () => {
      const key = await createSoftwareKey();
      const parsed = await parseP256PublicKeySPKI(key.spki);
      expect(parsed.qx.bigint).toBe(key.qx.bigint);
      expect(parsed.qy.bigint).toBe(key.qy.bigint);
      expect(parsed.qx.hex).toBe(key.qx.hex);
      expect(parsed.qy.hex).toBe(key.qy.hex);
    });

    it('rejects corrupted SPKI bytes', async () => {
      const invalidSPKI = new Uint8Array([0x30, 0x10, 0x02, 0x01, 0x00]);
      await expect(parseP256PublicKeySPKI(invalidSPKI)).rejects.toThrow();
    });
  });

  // ----------------------------------------------------
  // 7. Local Assertion Verification
  // ----------------------------------------------------
  describe('verifyAssertionLocal validation', () => {
    it('passes for a valid assertion across both WebCrypto and @noble/curves', async () => {
      const key = await createSoftwareKey();
      const rpId = 'localhost';
      const authData = buildAuthenticatorData(rpId, 0x05, 1);
      const challenge = new Uint8Array(32).fill(42);
      const { jsonBytes } = buildClientDataJSON(challenge);

      const { r, s } = signSoftwareAssertion(key.privateKey, authData, jsonBytes);

      const result = await verifyAssertionLocal({
        authenticatorData: authData,
        clientDataJSON: jsonBytes,
        r,
        s,
        qx: key.qx.bigint,
        qy: key.qy.bigint,
        expectedChallenge: challenge,
        expectedRpId: rpId,
      });

      expect(result.valid).toBe(true);
      expect(result.reasons).toEqual([]);
    });

    it('fails when clientDataJSON is tampered', async () => {
      const key = await createSoftwareKey();
      const authData = buildAuthenticatorData('localhost', 0x05, 1);
      const challenge = new Uint8Array(32).fill(42);
      const { jsonBytes } = buildClientDataJSON(challenge);
      const { r, s } = signSoftwareAssertion(key.privateKey, authData, jsonBytes);

      // Tamper clientDataJSON
      const tamperedBytes = new Uint8Array(jsonBytes);
      tamperedBytes[tamperedBytes.length - 2] = 'x'.charCodeAt(0);

      const result = await verifyAssertionLocal({
        authenticatorData: authData,
        clientDataJSON: tamperedBytes,
        r,
        s,
        qx: key.qx.bigint,
        qy: key.qy.bigint,
        expectedChallenge: challenge,
        expectedRpId: 'localhost',
      });

      expect(result.valid).toBe(false);
      expect(result.reasons.some((r) => r.includes('failed'))).toBe(true);
    });

    it('fails when challenge does not match expected challenge', async () => {
      const key = await createSoftwareKey();
      const authData = buildAuthenticatorData('localhost', 0x05, 1);
      const challenge = new Uint8Array(32).fill(42);
      const { jsonBytes } = buildClientDataJSON(challenge);
      const { r, s } = signSoftwareAssertion(key.privateKey, authData, jsonBytes);

      const wrongChallenge = new Uint8Array(32).fill(99);

      const result = await verifyAssertionLocal({
        authenticatorData: authData,
        clientDataJSON: jsonBytes,
        r,
        s,
        qx: key.qx.bigint,
        qy: key.qy.bigint,
        expectedChallenge: wrongChallenge,
        expectedRpId: 'localhost',
      });

      expect(result.valid).toBe(false);
      expect(result.reasons.some((r) => r.includes('challenge mismatch'))).toBe(true);
    });

    it('fails when rpIdHash does not match expected rpId', async () => {
      const key = await createSoftwareKey();
      const authData = buildAuthenticatorData('different-rp.com', 0x05, 1);
      const challenge = new Uint8Array(32).fill(42);
      const { jsonBytes } = buildClientDataJSON(challenge);
      const { r, s } = signSoftwareAssertion(key.privateKey, authData, jsonBytes);

      const result = await verifyAssertionLocal({
        authenticatorData: authData,
        clientDataJSON: jsonBytes,
        r,
        s,
        qx: key.qx.bigint,
        qy: key.qy.bigint,
        expectedChallenge: challenge,
        expectedRpId: 'localhost',
      });

      expect(result.valid).toBe(false);
      expect(result.reasons.some((r) => r.includes('rpIdHash does not match'))).toBe(true);
    });

    it('fails when User Presence (UP) flag is missing', async () => {
      const key = await createSoftwareKey();
      // Flags 0x04 (UV set, UP missing)
      const authData = buildAuthenticatorData('localhost', 0x04, 1);
      const challenge = new Uint8Array(32).fill(42);
      const { jsonBytes } = buildClientDataJSON(challenge);
      const { r, s } = signSoftwareAssertion(key.privateKey, authData, jsonBytes);

      const result = await verifyAssertionLocal({
        authenticatorData: authData,
        clientDataJSON: jsonBytes,
        r,
        s,
        qx: key.qx.bigint,
        qy: key.qy.bigint,
        expectedChallenge: challenge,
        expectedRpId: 'localhost',
      });

      expect(result.valid).toBe(false);
      expect(result.reasons.some((r) => r.includes('User Presence (UP)'))).toBe(true);
    });

    it('fails when User Verification (UV) flag is missing', async () => {
      const key = await createSoftwareKey();
      // Flags 0x01 (UP set, UV missing)
      const authData = buildAuthenticatorData('localhost', 0x01, 1);
      const challenge = new Uint8Array(32).fill(42);
      const { jsonBytes } = buildClientDataJSON(challenge);
      const { r, s } = signSoftwareAssertion(key.privateKey, authData, jsonBytes);

      const result = await verifyAssertionLocal({
        authenticatorData: authData,
        clientDataJSON: jsonBytes,
        r,
        s,
        qx: key.qx.bigint,
        qy: key.qy.bigint,
        expectedChallenge: challenge,
        expectedRpId: 'localhost',
      });

      expect(result.valid).toBe(false);
      expect(result.reasons.some((r) => r.includes('User Verification (UV)'))).toBe(true);
    });

    it('fails when public key is wrong', async () => {
      const key1 = await createSoftwareKey();
      const key2 = await createSoftwareKey();
      const authData = buildAuthenticatorData('localhost', 0x05, 1);
      const challenge = new Uint8Array(32).fill(42);
      const { jsonBytes } = buildClientDataJSON(challenge);
      const { r, s } = signSoftwareAssertion(key1.privateKey, authData, jsonBytes);

      // Verify against key2
      const result = await verifyAssertionLocal({
        authenticatorData: authData,
        clientDataJSON: jsonBytes,
        r,
        s,
        qx: key2.qx.bigint,
        qy: key2.qy.bigint,
        expectedChallenge: challenge,
        expectedRpId: 'localhost',
      });

      expect(result.valid).toBe(false);
      expect(result.reasons.some((r) => r.includes('failed'))).toBe(true);
    });

    it('fails when authenticatorData is truncated', async () => {
      const key = await createSoftwareKey();
      const truncatedAuthData = new Uint8Array(20).fill(1); // < 37 bytes
      const challenge = new Uint8Array(32).fill(42);
      const { jsonBytes } = buildClientDataJSON(challenge);

      const result = await verifyAssertionLocal({
        authenticatorData: truncatedAuthData,
        clientDataJSON: jsonBytes,
        r: 10n,
        s: 20n,
        qx: key.qx.bigint,
        qy: key.qy.bigint,
        expectedChallenge: challenge,
        expectedRpId: 'localhost',
      });

      expect(result.valid).toBe(false);
      expect(result.reasons.some((r) => r.includes('truncated'))).toBe(true);
    });
  });

  // ----------------------------------------------------
  // 8. Public Key Candidate Recovery
  // ----------------------------------------------------
  describe('recoverPublicKeyCandidates', () => {
    it('returns two candidates and the real public key is one of them', async () => {
      const key = await createSoftwareKey();
      const authData = buildAuthenticatorData('localhost', 0x05, 1);
      const challenge = new Uint8Array(32).fill(55);
      const { jsonBytes } = buildClientDataJSON(challenge);

      const { r, s } = signSoftwareAssertion(key.privateKey, authData, jsonBytes);

      const candidates = recoverPublicKeyCandidates(authData, jsonBytes, r, s);
      expect(candidates.length).toBe(2);

      const matchingCandidate = candidates.find(
        (c) => c.qx.hex.toLowerCase() === key.qx.hex.toLowerCase() &&
               c.qy.hex.toLowerCase() === key.qy.hex.toLowerCase()
      );

      expect(matchingCandidate).toBeDefined();
      expect(matchingCandidate?.accountId.toLowerCase()).toBe(key.accountId.toLowerCase());
    });
  });

  // ----------------------------------------------------
  // 9. toWebAuthnAuth Solidity Struct Mapping
  // ----------------------------------------------------
  describe('toWebAuthnAuth mapping', () => {
    it('formats parsed assertion to match Solidity WebAuthnAuth struct', () => {
      const authData = buildAuthenticatorData('localhost', 0x05, 1);
      const challenge = new Uint8Array(32).fill(11);
      const { jsonBytes, jsonText } = buildClientDataJSON(challenge);
      const indices = findClientDataIndices(jsonBytes);

      const struct = toWebAuthnAuth({
        authenticatorData: authData,
        clientDataJSON: jsonBytes,
        challengeIndex: indices.challengeIndex,
        typeIndex: indices.typeIndex,
        r: 12345n,
        s: 67890n,
      });

      expect(struct.authenticatorData).toBe(to0xHex(authData));
      expect(struct.clientDataJSON).toBe(jsonText);
      expect(struct.challengeIndex).toBe(BigInt(indices.challengeIndex));
      expect(struct.typeIndex).toBe(BigInt(indices.typeIndex));
      expect(struct.r).toBe(12345n);
      expect(struct.s).toBe(67890n);
    });
  });

  // ----------------------------------------------------
  // 10. Fixture Export: Deterministic Software Vector
  // ----------------------------------------------------
  describe('deterministic fixture generation', () => {
    it('generates software-vector.json and copies to contracts/test/fixtures/', async () => {
      // Deterministic throwaway test key (NOT FOR PRODUCTION)
      const fixedPrivateKey = 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20n;
      const key = await createSoftwareKey(fixedPrivateKey);

      // Deterministic challenge: 32 bytes [1..32]
      const challenge = new Uint8Array(32);
      for (let i = 0; i < 32; i++) challenge[i] = i + 1;

      const authData = buildAuthenticatorData('localhost', 0x05, 1);
      const { jsonBytes, jsonText } = buildClientDataJSON(challenge);

      const { r, s, digest, derSignature } = signSoftwareAssertion(
        key.privateKey,
        authData,
        jsonBytes
      );

      const parsed = parseAssertionResponse({
        authenticatorData: authData,
        clientDataJSON: jsonBytes,
        signature: derSignature,
      });

      const fixture = {
        _description: 'Deterministic throwaway test vector for AgentPass Phase 13/14 tests. NOT FOR PRODUCTION.',
        challenge: to0xHex(challenge, 32),
        hash: parsed.digestHex,
        r: parsed.rHex,
        s: parsed.sHex,
        sLow: parsed.sLowHex,
        qx: key.qx.hex,
        qy: key.qy.hex,
        accountId: key.accountId,
        authenticatorData: parsed.authenticatorDataHex,
        clientDataJSON: jsonText,
        typeIndex: parsed.typeIndex,
        challengeIndex: parsed.challengeIndex,
        rpId: 'localhost',
        origin: 'http://localhost:3000',
      };

      // Write to web/test-fixtures/software-vector.json
      const webFixturesDir = path.resolve(__dirname, '../../../../test-fixtures');
      if (!fs.existsSync(webFixturesDir)) {
        fs.mkdirSync(webFixturesDir, { recursive: true });
      }
      const webFixturePath = path.join(webFixturesDir, 'software-vector.json');
      fs.writeFileSync(webFixturePath, JSON.stringify(fixture, null, 2), 'utf8');

      // Also copy to contracts/test/fixtures/webauthn-vector.json
      const contractsFixturesDir = path.resolve(__dirname, '../../../../../contracts/test/fixtures');
      if (!fs.existsSync(contractsFixturesDir)) {
        fs.mkdirSync(contractsFixturesDir, { recursive: true });
      }
      const contractsFixturePath = path.join(contractsFixturesDir, 'webauthn-vector.json');
      fs.writeFileSync(contractsFixturePath, JSON.stringify(fixture, null, 2), 'utf8');

      expect(fs.existsSync(webFixturePath)).toBe(true);
      expect(fs.existsSync(contractsFixturePath)).toBe(true);
    });
  });
});
