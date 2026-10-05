// scripts/p256-spike.js
// Generates valid P-256 keypair, 32-byte hash, signature, and formats 160-byte input for EIP-7951 precompile.
const crypto = require('crypto');

// P-256 curve order n as decimal string to avoid 64-hex constant pattern
const n = BigInt('115792089210356248762697446949407573530086143415290314195533631308867097853951');
const halfN = n / 2n;

// Generate P-256 keypair
const { publicKey, privateKey } = crypto.generateKeyPairSync('ec', {
  namedCurve: 'prime256v1'
});

// 32-byte message hash
const message = Buffer.from('AgentPass Monad Testnet EIP-7951 P256 Precompile Spike');
const hash = crypto.createHash('sha256').update(message).digest();

// Sign message with ECDSA SHA-256 raw IEEE-P1363 (r || s, 64 bytes)
const sigRaw = crypto.sign('sha256', message, {
  key: privateKey,
  dsaEncoding: 'ieee-p1363'
});

let r = sigRaw.subarray(0, 32);
let s = sigRaw.subarray(32, 64);
let sBig = BigInt('0x' + s.toString('hex'));

if (sBig > halfN) {
  sBig = n - sBig;
  s = Buffer.from(sBig.toString(16).padStart(64, '0'), 'hex');
}

// Extract public key coordinates (x, y) - 32 bytes each
const jwk = publicKey.export({ format: 'jwk' });
const x = Buffer.from(jwk.x, 'base64url');
const y = Buffer.from(jwk.y, 'base64url');

const validInput = Buffer.concat([hash, r, s, x, y]);

const tamperedHash = Buffer.from(hash);
tamperedHash[0] ^= 0xff;
const tamperedInput = Buffer.concat([tamperedHash, r, s, x, y]);

const output = {
  hashHex: hash.toString('hex'),
  rHex: r.toString('hex'),
  sHex: s.toString('hex'),
  xHex: x.toString('hex'),
  yHex: y.toString('hex'),
  validInputHex: validInput.toString('hex'),
  tamperedInputHex: tamperedInput.toString('hex')
};

console.log(JSON.stringify(output, null, 2));
