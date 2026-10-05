#!/usr/bin/env bash
# scripts/check-rpc.sh
# Health-check script for AgentPass RPC providers on Monad testnet.

# Expected chain ID constant (can be overridden via EXPECTED_CHAIN_ID in .env or environment)
DEFAULT_EXPECTED_CHAIN_ID=10143

# Resolve repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env without echoing values or overwriting existing environment variables
ENV_FILE=""
if [ -f "$REPO_ROOT/.env" ]; then
  ENV_FILE="$REPO_ROOT/.env"
elif [ -f ".env" ]; then
  ENV_FILE=".env"
fi

if [ -n "$ENV_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    # Ignore comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      # Remove surrounding quotes if present
      val="${val#\"}"
      val="${val%\"}"
      val="${val#\'}"
      val="${val%\'}"
      # Only set if not already set in environment
      if [ -z "${!key+x}" ]; then
        export "$key"="$val"
      fi
    fi
  done < "$ENV_FILE"
fi

EXPECTED_CHAIN_ID="${EXPECTED_CHAIN_ID:-$DEFAULT_EXPECTED_CHAIN_ID}"

# Temporary directory for curl error logs
TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'check-rpc')
trap 'rm -rf "$TMP_DIR"' EXIT

# Helper: parse json result field
parse_json_result() {
  local json="$1"
  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -r '.result // empty' 2>/dev/null
  else
    echo "$json" | grep -oE '"result"[[:space:]]*:[[:space:]]*("0x[0-9a-fA-F]+"|[0-9]+)' | head -n1 | sed -E 's/.*"result"[[:space:]]*:[[:space:]]*"?([^"]+)"?/\1/'
  fi
}

# Helper: parse json error message
parse_json_error() {
  local json="$1"
  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -r '.error.message // .error // empty' 2>/dev/null
  else
    echo "$json" | grep -o '"message"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/.*"message"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'
  fi
}

# Helper: convert hex to decimal
to_decimal() {
  local hex="$1"
  if [[ "$hex" =~ ^0[xX][0-9a-fA-F]+$ ]]; then
    printf "%d" "$hex" 2>/dev/null || echo "$((hex))"
  elif [[ "$hex" =~ ^[0-9]+$ ]]; then
    echo "$hex"
  else
    echo ""
  fi
}

# Helper: get timestamp in milliseconds
get_time_ms() {
  local ms
  ms=$(date +%s%3N 2>/dev/null)
  if [[ "$ms" =~ ^[0-9]+$ ]]; then
    echo "$ms"
  else
    echo "$(( $(date +%s) * 1000 ))"
  fi
}

# Helper: sanitize curl error to ensure URLs are NEVER leaked
sanitize_curl_error() {
  local err_file="$1"
  local exit_code="$2"
  case "$exit_code" in
    6) echo "Could not resolve host" ;;
    7) echo "Failed to connect to host" ;;
    28) echo "Connection timed out" ;;
    3|1) echo "Invalid or unsupported URL" ;;
    52) echo "Empty reply from server" ;;
    *)
      if [ -f "$err_file" ]; then
        local line
        line=$(head -n 1 "$err_file" 2>/dev/null | sed -E 's|https?://[^ ]+||g; s/curl: \([0-9]+\) //')
        if [ -n "$line" ]; then
          echo "$line"
          return
        fi
      fi
      echo "Network error (curl exit $exit_code)"
      ;;
  esac
}

# Check a single provider
# check_provider <Name> <URL> <IsPrimary: 1|0>
check_provider() {
  local name="$1"
  local url="$2"
  local is_primary="$3"
  
  if [ -z "$url" ]; then
    if [ "$is_primary" -eq 1 ]; then
      echo "$name: FAIL (primary RPC is not set: QUICKNODE_RPC_URL is empty)"
      return 1
    else
      echo "$name: SKIPPED (not set)"
      return 0
    fi
  fi
  
  local start_ms end_ms latency_ms
  start_ms=$(get_time_ms)
  
  local err_file="$TMP_DIR/err_$name.txt"
  
  # Call eth_chainId
  local chain_res chain_exit
  chain_res=$(curl -s -S --connect-timeout 5 --max-time 8 \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
    "$url" 2>"$err_file")
  chain_exit=$?
  
  if [ $chain_exit -ne 0 ]; then
    end_ms=$(get_time_ms)
    latency_ms=$((end_ms - start_ms))
    local err_msg
    err_msg=$(sanitize_curl_error "$err_file" "$chain_exit")
    echo "$name: FAIL (connection error: $err_msg) | Latency: ${latency_ms}ms"
    return 1
  fi
  
  local rpc_err
  rpc_err=$(parse_json_error "$chain_res")
  if [ -n "$rpc_err" ]; then
    end_ms=$(get_time_ms)
    latency_ms=$((end_ms - start_ms))
    echo "$name: FAIL (RPC error: $rpc_err) | Latency: ${latency_ms}ms"
    return 1
  fi
  
  local chain_hex chain_dec
  chain_hex=$(parse_json_result "$chain_res")
  chain_dec=$(to_decimal "$chain_hex")
  
  if [ -z "$chain_dec" ]; then
    end_ms=$(get_time_ms)
    latency_ms=$((end_ms - start_ms))
    echo "$name: FAIL (invalid chain ID response) | Latency: ${latency_ms}ms"
    return 1
  fi
  
  # Call eth_blockNumber
  local block_res block_exit
  block_res=$(curl -s -S --connect-timeout 5 --max-time 8 \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":2}' \
    "$url" 2>"$err_file")
  block_exit=$?
  
  end_ms=$(get_time_ms)
  latency_ms=$((end_ms - start_ms))
  
  if [ $block_exit -ne 0 ]; then
    local err_msg
    err_msg=$(sanitize_curl_error "$err_file" "$block_exit")
    echo "$name: FAIL (connection error: $err_msg) | Latency: ${latency_ms}ms"
    return 1
  fi
  
  local block_hex block_dec
  block_hex=$(parse_json_result "$block_res")
  block_dec=$(to_decimal "$block_hex")
  
  if [ -z "$block_dec" ]; then
    echo "$name: FAIL (invalid block number response) | Latency: ${latency_ms}ms"
    return 1
  fi
  
  # Check chain ID against EXPECTED_CHAIN_ID
  if [ "$chain_dec" != "$EXPECTED_CHAIN_ID" ]; then
    echo "$name: FAIL (chain ID mismatch: expected $EXPECTED_CHAIN_ID, got $chain_dec) | Block: $block_dec | Latency: ${latency_ms}ms"
    return 1
  fi
  
  echo "$name: PASS | Chain ID: $chain_dec | Block: $block_dec | Latency: ${latency_ms}ms"
  return 0
}

# Run checks
primary_failed=0

check_provider "Quicknode" "$QUICKNODE_RPC_URL" 1 || primary_failed=1
check_provider "Backup" "$BACKUP_RPC_URL" 0 || true
check_provider "Crouton" "$CROUTON_RPC_URL" 0 || true

exit $primary_failed
