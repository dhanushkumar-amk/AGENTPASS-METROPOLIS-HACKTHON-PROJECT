// scripts/gen-owner-key.mjs
// Generates a local P-256 (secp256r1) test keypair standing in for a WebAuthn passkey.
// Writes .secrets/owner-p256.json with restricted permissions (0600) and prints ONLY (qx, qy).

import { generateKeyPairSync } from 'node:crypto';
import { writeFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, '..');
const SECRETS_DIR = resolve(REPO_ROOT, '.secrets');
const OUTPUT_FILE = resolve(SECRETS_DIR, 'owner-p256.json');

// Generate secp256r1 (P-256 / prime256v1) keypair
const { publicKey, privateKey } = generateKeyPairSync('ec', {
  namedCurve: 'prime256v1'
});

const pubJwk = publicKey.export({ format: 'jwk' });
const privJwk = privateKey.export({ format: 'jwk' });

const qxBuf = Buffer.from(pubJwk.x, 'base64url');
const qyBuf = Buffer.from(pubJwk.y, 'base64url');
const dBuf = Buffer.from(privJwk.d, 'base64url');

const qxHex = '0x' + qxBuf.toString('hex').padStart(64, '0');
const qyHex = '0x' + qyBuf.toString('hex').padStart(64, '0');
const privHex = '0x' + dBuf.toString('hex').padStart(64, '0');

mkdirSync(SECRETS_DIR, { recursive: true, mode: 0o700 });

const keyData = {
  curve: 'secp256r1',
  privateKey: privHex,
  qx: qxHex,
  qy: qyHex
};

writeFileSync(OUTPUT_FILE, JSON.stringify(keyData, null, 2), { mode: 0o600 });

// Print ONLY the public key
console.log(`qx: ${qxHex}`);
console.log(`qy: ${qyHex}`);
