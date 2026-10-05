# RPC Providers & Configuration

This document outlines the RPC provider strategy, configuration rules, and health monitoring for AgentPass on Monad testnet.

## Supported Providers

- **Quicknode (Primary)**: The primary RPC provider for deploying contracts, executing agent transactions, and running health checks.
- **Crouton (Backup)**: Secondary/backup RPC endpoint for fallback queries and redundancy.
- **Generic Backup / Secondary Providers**: Additional fallback RPC endpoints (e.g., public testnet endpoints or alternative node services) configured via `BACKUP_RPC_URL`.

## Golden Rule: Environment-Driven Configuration

> **All code across contracts, agent runtime scripts, and web applications MUST read the RPC URL from the environment.**

- **No Hardcoding**: Never hardcode RPC URLs, API keys, or provider endpoints in code or configuration files tracked by version control.
- **Provider Switching**: By sourcing RPC endpoints exclusively from environment variables (`QUICKNODE_RPC_URL`, `BACKUP_RPC_URL`, `CROUTON_RPC_URL`), providers can be swapped, rotated, or failed over without making any code changes or redeployments.
- **Security & Privacy**: RPC URLs often contain authentication tokens or sensitive endpoints. Storing them exclusively in local `.env` files (which are git-ignored) prevents credential leakage.

## Chain Details

| Parameter | Value | Description |
| --- | --- | --- |
| Network | Monad Testnet | Target blockchain network |
| Chain ID (Decimal) | `10143` | Expected chain ID verified during health checks |
| Chain ID (Hex) | `0x279f` | Hex representation returned by `eth_chainId` |
| Config Key | `EXPECTED_CHAIN_ID` | Default is `10143`; can be overridden in environment |

## Health Check Script

AgentPass includes a lightweight RPC health-check script at `scripts/check-rpc.sh`:

- **Execution**:
  ```bash
  ./scripts/check-rpc.sh
  ```
- **Validation**:
  - Validates `eth_chainId` matches `EXPECTED_CHAIN_ID` (10143).
  - Fetches latest block number via `eth_blockNumber`.
  - Measures request round-trip latency (in milliseconds).
  - Skips unset backup providers gracefully.
  - Returns exit code `1` if `QUICKNODE_RPC_URL` is unset or fails, and `0` when primary RPC is healthy.
- **Security Guarantee**:
  - The script never logs, prints, or exposes the actual RPC URL.
