#!/usr/bin/env bash
# scripts/check-wallet.sh
# Verifies deployer wallet derivation, chain ID, and funding on Monad testnet.

set -euo pipefail

# Ensure foundry binaries are available
export PATH="$HOME/.foundry/bin:$PATH"

if ! command -v cast >/dev/null 2>&1; then
  echo "FAIL: cast (Foundry) is not installed or not in PATH"
  exit 1
fi

DEFAULT_EXPECTED_CHAIN_ID=10143

# Resolve repo root
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

EXPECTED_CHAIN_ID="${EXPECTED_CHAIN_ID:-$DEFAULT_EXPECTED_CHAIN_ID}"

# Check DEPLOYER_PRIVATE_KEY is set
if [ -z "${DEPLOYER_PRIVATE_KEY:-}" ]; then
  echo "FAIL: deployer key not set (DEPLOYER_PRIVATE_KEY is empty or missing)"
  exit 1
fi

# Derive address from private key without printing the key
address=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY" 2>/dev/null || true)
if [ -z "$address" ]; then
  echo "FAIL: invalid deployer private key (could not derive wallet address)"
  exit 1
fi

# Check QUICKNODE_RPC_URL is set
if [ -z "${QUICKNODE_RPC_URL:-}" ]; then
  echo "Deployer Address: $address"
  echo "FAIL: RPC down (QUICKNODE_RPC_URL is empty or missing)"
  exit 1
fi

# Fetch chain ID
chain_id=$(cast chain-id --rpc-url "$QUICKNODE_RPC_URL" 2>/dev/null || true)
if [ -z "$chain_id" ]; then
  echo "Deployer Address: $address"
  echo "FAIL: RPC down (failed to connect to RPC or fetch chain ID)"
  exit 1
fi

# Check chain ID against expected value
if [ "$chain_id" != "$EXPECTED_CHAIN_ID" ]; then
  echo "Deployer Address: $address"
  echo "Chain ID: $chain_id"
  echo "FAIL: chain ID mismatch (expected $EXPECTED_CHAIN_ID, got $chain_id)"
  exit 1
fi

# Fetch balance
balance_wei=$(cast balance "$address" --rpc-url "$QUICKNODE_RPC_URL" 2>/dev/null || true)
if [ -z "$balance_wei" ]; then
  echo "Deployer Address: $address"
  echo "Chain ID: $chain_id"
  echo "FAIL: RPC down (failed to fetch wallet balance)"
  exit 1
fi

balance_mon=$(cast from-wei "$balance_wei" 2>/dev/null || true)

echo "Deployer Address: $address"
echo "Chain ID: $chain_id"
echo "Balance: $balance_mon MON"

if [ "$balance_wei" = "0" ]; then
  echo "FAIL: wallet not funded (balance is 0 MON)"
  exit 1
fi

echo "Status: PASS"
exit 0
