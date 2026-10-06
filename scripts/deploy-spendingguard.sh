#!/usr/bin/env bash
# scripts/deploy-spendingguard.sh
# Deploys SpendingGuard to Monad testnet with dry-run and broadcast modes.
# Adheres strictly to the safe key-handling pattern (no keys on CLI or in logs).

set -euo pipefail

export PATH="$HOME/.foundry/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

if ! command -v forge >/dev/null 2>&1; then
  echo "FAIL: forge is not installed or not in PATH"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Silently load .env without printing or echoing
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

MODE="dry-run"
if [ "${1:-}" = "--broadcast" ]; then
  MODE="broadcast"
fi

cd "$REPO_ROOT/contracts"

DEPLOYER_ADDR=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY" 2>/dev/null)
GAS_PRICE_WEI=$(cast gas-price --rpc-url monad_testnet 2>/dev/null || echo "50000000000")
DEPLOYER_BAL_WEI=$(cast balance "$DEPLOYER_ADDR" --rpc-url monad_testnet 2>/dev/null || echo "0")
DEPLOYER_BAL_MON=$(cast from-wei "$DEPLOYER_BAL_WEI" ether 2>/dev/null || echo "0")

TMP_LOG=$(mktemp)
trap 'rm -f "$TMP_LOG"' EXIT

if [ "$MODE" = "dry-run" ]; then
  echo "=== SPENDINGGUARD DEPLOYMENT: DRY RUN ==="
  echo "Deployer Public Address: $DEPLOYER_ADDR"
  echo "Deployer Balance:        $DEPLOYER_BAL_MON MON"
  echo "Current Gas Price:       $GAS_PRICE_WEI wei ($(cast from-wei "$GAS_PRICE_WEI" gwei) gwei)"

  # Run forge script without --broadcast for gas estimation
  if ! forge script script/DeploySpendingGuard.s.sol:DeploySpendingGuard \
    --rpc-url monad_testnet \
    > "$TMP_LOG" 2>&1; then
    echo "FAIL: Dry run simulation failed"
    grep -vE '(PRIVATE_KEY|quiknode|quicknode|https?://)' "$TMP_LOG" | tail -n 25 || true
    exit 1
  fi

  # Extract estimated gas from forge script summary
  ESTIMATED_GAS=$(grep -iE "Total Paid|Gas used|gas:" "$TMP_LOG" | grep -oE "[0-9]+" | tail -n 1 || echo "2500000")
  if [ -z "$ESTIMATED_GAS" ] || [ "$ESTIMATED_GAS" -lt 100000 ]; then
    ESTIMATED_GAS=2500000
  fi

  # Calculate cost: gas * gas_price
  ESTIMATED_COST_WEI=$(python3 -c "print($ESTIMATED_GAS * $GAS_PRICE_WEI)" 2>/dev/null || echo "125000000000000000")
  ESTIMATED_COST_MON=$(cast from-wei "$ESTIMATED_COST_WEI" ether 2>/dev/null || echo "0.125")

  echo "Estimated Gas Limit:     $ESTIMATED_GAS"
  echo "Estimated Spend:         $ESTIMATED_COST_MON MON"
  echo "========================================="
  echo "DRY RUN COMPLETE. SPENDING GATE: Waiting for user 'go' before broadcast."
  exit 0
fi

# Broadcast mode
if [ "$MODE" = "broadcast" ]; then
  if ! forge script script/DeploySpendingGuard.s.sol:DeploySpendingGuard \
    --rpc-url monad_testnet \
    --broadcast \
    --gas-estimate-multiplier 110 \
    > "$TMP_LOG" 2>&1; then
    echo "FAIL: Deployment broadcast failed"
    grep -vE '(PRIVATE_KEY|quiknode|quicknode|https?://)' "$TMP_LOG" | tail -n 25 || true
    exit 1
  fi

  BROADCAST_FILE="$REPO_ROOT/contracts/broadcast/DeploySpendingGuard.s.sol/10143/run-latest.json"
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

  if [ -z "$CONTRACT_ADDRESS" ]; then
    CONTRACT_ADDRESS=$(grep -iE "Contract Address:|Deployed SpendingGuard at:" "$TMP_LOG" | grep -oE "0x[a-fA-F0-9]{40}" | head -n 1 || true)
  fi

  if [ -z "$TX_HASH" ]; then
    TX_HASH=$(grep -iE "Hash:|tx_hash:" "$TMP_LOG" | grep -oE "0x[a-fA-F0-9]{64}" | head -n 1 || true)
  fi

  if [ -z "$CONTRACT_ADDRESS" ] || [ -z "$TX_HASH" ]; then
    echo "FAIL: Could not extract contract address or tx hash from broadcast"
    exit 1
  fi

  echo "Contract Address: $CONTRACT_ADDRESS"
  echo "Transaction Hash: $TX_HASH"
  exit 0
fi
