#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Silently load .env without echoing or logging
ENV_FILE=""
if [ -f "$REPO_ROOT/.env" ]; then
  ENV_FILE="$REPO_ROOT/.env"
elif [ -f ".env" ]; then
  ENV_FILE=".env"
fi

if [ -n "$ENV_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      val="${val#\"}"
      val="${val%\"}"
      val="${val#\'}"
      val="${val%\'}"
      if [ -z "${!key+x}" ]; then
        export "$key"="$val"
      fi
    fi
  done < "$ENV_FILE"
fi

cd "$REPO_ROOT/contracts"

echo "=== T1: Chain ID ==="
cast chain-id --rpc-url monad_testnet

echo "=== T5: ERC-8004 Testnet Registry Code ==="
REG_CODE=$(cast code 0x8004A818BFB912233c491871b3d84c89A494BD9e --rpc-url monad_testnet)
echo "Code length (bytes): $((${#REG_CODE} / 2))"
echo "Code prefix: ${REG_CODE:0:66}"

echo "=== ERC-8004 Calls ==="
cast call 0x8004A818BFB912233c491871b3d84c89A494BD9e "name()(string)" --rpc-url monad_testnet || echo "name() failed"
cast call 0x8004A818BFB912233c491871b3d84c89A494BD9e "symbol()(string)" --rpc-url monad_testnet || echo "symbol() failed"

echo "=== T6: ERC-4337 EntryPoint v0.8 Code ==="
EP_CODE=$(cast code 0x4337084d9e255ff0702461cf8895ce9e3b5ff108 --rpc-url monad_testnet)
echo "EntryPoint code: $EP_CODE"
if [ "$EP_CODE" = "0x" ] || [ -z "$EP_CODE" ]; then
  echo "EntryPoint is ABSENT on Monad testnet"
else
  echo "EntryPoint is PRESENT on Monad testnet (code length: $((${#EP_CODE} / 2)))"
fi
