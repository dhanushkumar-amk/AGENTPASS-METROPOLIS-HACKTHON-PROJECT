#!/usr/bin/env bash
# scripts/deploy-hello.sh
# Deploys HelloMonad to Monad testnet using forge script and broadcast.

set -euo pipefail

# Ensure foundry binaries are available
export PATH="$HOME/.foundry/bin:$PATH"

if ! command -v forge >/dev/null 2>&1; then
  echo "FAIL: forge is not installed or not in PATH"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Silently load .env without echoing or overwriting existing env variables
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

if [ -z "${DEPLOYER_PRIVATE_KEY:-}" ]; then
  echo "FAIL: DEPLOYER_PRIVATE_KEY is not set"
  exit 1
fi

if [ -z "${QUICKNODE_RPC_URL:-}" ]; then
  echo "FAIL: QUICKNODE_RPC_URL is not set"
  exit 1
fi

cd "$REPO_ROOT/contracts"

TMP_LOG=$(mktemp)
trap 'rm -f "$TMP_LOG"' EXIT

# Execute forge script with broadcast without passing private keys on CLI
if ! forge script script/DeployHello.s.sol:DeployHello \
  --rpc-url monad_testnet \
  --broadcast \
  > "$TMP_LOG" 2>&1; then
  echo "FAIL: Deployment script execution failed"
  grep -vE '(PRIVATE_KEY|quiknode|quicknode|https?://)' "$TMP_LOG" | tail -n 20 || true
  exit 1
fi

# Locate latest broadcast run file
BROADCAST_FILE="$REPO_ROOT/contracts/broadcast/DeployHello.s.sol/10143/run-latest.json"

CONTRACT_ADDRESS=""
TX_HASH=""

if [ -f "$BROADCAST_FILE" ]; then
  if command -v python3 >/dev/null 2>&1; then
    CONTRACT_ADDRESS=$(python3 -c "import json; data=json.load(open('$BROADCAST_FILE')); print(data.get('transactions', [{}])[0].get('contractAddress') or '')" 2>/dev/null || true)
    TX_HASH=$(python3 -c "import json; data=json.load(open('$BROADCAST_FILE')); print(data.get('transactions', [{}])[0].get('hash') or '')" 2>/dev/null || true)
  elif command -v jq >/dev/null 2>&1; then
    CONTRACT_ADDRESS=$(jq -r '.transactions[0].contractAddress // empty' "$BROADCAST_FILE" 2>/dev/null || true)
    TX_HASH=$(jq -r '.transactions[0].hash // empty' "$BROADCAST_FILE" 2>/dev/null || true)
  fi
fi

# Fallback: extract from forge log output if not found in json
if [ -z "$CONTRACT_ADDRESS" ]; then
  CONTRACT_ADDRESS=$(grep -iE "Contract Address:|Deployed HelloMonad at:" "$TMP_LOG" | grep -oE "0x[a-fA-F0-9]{40}" | head -n 1 || true)
fi

if [ -z "$TX_HASH" ]; then
  TX_HASH=$(grep -iE "Hash:|tx_hash:" "$TMP_LOG" | grep -oE "0x[a-fA-F0-9]{64}" | head -n 1 || true)
fi

if [ -z "$CONTRACT_ADDRESS" ] || [ -z "$TX_HASH" ]; then
  echo "FAIL: Could not extract contract address or transaction hash from deployment output"
  exit 1
fi

echo "Contract Address: $CONTRACT_ADDRESS"
echo "Transaction Hash: $TX_HASH"
exit 0
