#!/usr/bin/env bash
set -euo pipefail

# scripts/check-passkey-vector.sh
# Validates a WebAuthn passkey vector against Monad testnet P-256 precompile at 0x100
# Network: Monad Testnet (Chain ID 10143)
# Precompile: 0x0000000000000000000000000000000000000100
# Input: 160 bytes = hash[32] || r[32] || s[32] || qx[32] || qy[32]

VECTOR_FILE="${1:-web/test-fixtures/software-vector.json}"

if [ ! -f "$VECTOR_FILE" ]; then
  echo "Error: Vector file not found: $VECTOR_FILE" >&2
  exit 1
fi

# Silently load QUICKNODE_RPC_URL from .env stripping \r (never print .env or RPC URL)
RPC_URL=""
if [ -f .env ]; then
  RPC_URL=$(grep -E '^QUICKNODE_RPC_URL=' .env | head -n 1 | cut -d '=' -f 2- | tr -d '\r' || true)
fi

if [ -z "$RPC_URL" ]; then
  echo "Error: QUICKNODE_RPC_URL not configured in .env" >&2
  exit 1
fi

PRECOMPILE="0x0000000000000000000000000000000000000100"
EXPECTED="0x0000000000000000000000000000000000000000000000000000000000000001"

# Parse fields using node
PARSED_JSON=$(node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
function cleanHex(h) {
  let s = (h || "").replace(/^0x/i, "");
  return s.padStart(64, "0").slice(-64);
}
const hash = cleanHex(data.hash);
const r = cleanHex(data.r);
const s = cleanHex(data.s);
const sLow = cleanHex(data.sLow || data.s);
const qx = cleanHex(data.qx);
const qy = cleanHex(data.qy);

const inputRaw = "0x" + hash + r + s + qx + qy;
const inputLow = "0x" + hash + r + sLow + qx + qy;

console.log(JSON.stringify({ inputRaw, inputLow }));
' "$VECTOR_FILE")

INPUT_RAW=$(echo "$PARSED_JSON" | node -e 'console.log(JSON.parse(fs.readFileSync(0, "utf8")).inputRaw)')
INPUT_LOW=$(echo "$PARSED_JSON" | node -e 'console.log(JSON.parse(fs.readFileSync(0, "utf8")).inputLow)')

echo "Checking vector: $VECTOR_FILE"
echo "Precompile: $PRECOMPILE"
echo "Target: Monad Testnet (Chain ID 10143)"
echo ""

# 1. Test Raw s
echo "--- Variant 1: Raw s (default authenticator output) ---"
RET_RAW=$(cast call "$PRECOMPILE" "$INPUT_RAW" --rpc-url "$RPC_URL" 2>&1 || true)
RET_RAW_CLEAN=$(echo "$RET_RAW" | tr -d '\r' | tr -d '\n')

if [ "$RET_RAW_CLEAN" = "$EXPECTED" ]; then
  echo "Result: PASS (32-byte 1)"
  echo "Hex: $RET_RAW_CLEAN"
else
  echo "Result: FAIL"
  echo "Hex: $RET_RAW_CLEAN"
  exit 1
fi

echo ""

# 2. Test sLow
echo "--- Variant 2: sLow (normalized s <= n/2) ---"
RET_LOW=$(cast call "$PRECOMPILE" "$INPUT_LOW" --rpc-url "$RPC_URL" 2>&1 || true)
RET_LOW_CLEAN=$(echo "$RET_LOW" | tr -d '\r' | tr -d '\n')

if [ "$RET_LOW_CLEAN" = "$EXPECTED" ]; then
  echo "Result: PASS (32-byte 1)"
  echo "Hex: $RET_LOW_CLEAN"
else
  echo "Result: FAIL"
  echo "Hex: $RET_LOW_CLEAN"
  exit 1
fi

echo ""
echo "All precompile signature verification checks passed successfully."
