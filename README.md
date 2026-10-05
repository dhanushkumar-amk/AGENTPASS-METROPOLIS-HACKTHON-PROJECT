# AgentPass

A reusable spending-limit and identity layer for AI agents on Monad. Built for the Metropolis Hackathon.

**Repo:** https://github.com/dhanushkumar-amk/AGENTPASS-METROPOLIS-HACKTHON-PROJECT

## Track

Trust, Identity & AI Infrastructure

## The problem

AI agents increasingly hold keys and act on-chain, but there is no standard way to bound what they can spend or to know which agent took an action. Delegating a full private key to an agent is an all-or-nothing risk.

## The solution

AgentPass gives each AI agent a verifiable identity plus on-chain spending limits: the owner sets the rules, the agent can only transact within them, and every action is attributable back to a specific agent.

## How it uses Monad

_Placeholder: details on how the contracts and agent flow run on the Monad testnet will be filled in as they are implemented._

## Architecture overview

_Placeholder for an architecture diagram._

- `contracts/` — Foundry project for the on-chain identity and spending-limit contracts (not implemented yet).
- `web/` — Next.js dashboard for creating agents and managing limits (not implemented yet).
- `agent/` — Agent runtime script that signs and submits transactions within its limits (not implemented yet).
- `docs/` — Additional documentation.

## Tech stack

- Foundry (Solidity)
- Next.js + TypeScript + Tailwind CSS + shadcn/ui
- viem
- Agent script (TypeScript or Python)
- Quicknode RPC
- Tenderly

## Deployed contract addresses

| Contract | Monad testnet address |
| --- | --- |
| _to be added after deployment_ | — |

## Setup and run instructions

### Environment setup

1. Copy `.env.example` to `.env`:
   ```bash
   cp .env.example .env
   ```
2. Fill in the required environment variables in `.env` (such as `QUICKNODE_RPC_URL` and `DEPLOYER_PRIVATE_KEY`). Never commit `.env` or real secrets.
3. Validate RPC connectivity and health:
   ```bash
   ./scripts/check-rpc.sh
   ```

### Foundry setup (WSL / Linux)

> **Warning:** Always use a dedicated, **testnet-only wallet** for `DEPLOYER_PRIVATE_KEY`. Never use a mainnet wallet or expose real private keys.

1. Install Foundry (if not already installed):
   ```bash
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   ```
2. Build contracts:
   ```bash
   cd contracts && forge build
   ```
3. Verify wallet derivation, chain ID (`10143`), and testnet funding:
   ```bash
   ./scripts/check-wallet.sh
   ```

_Placeholder: step-by-step setup for Foundry contracts, the web app, and the agent will be added as each part is built._

## Demo video

_Placeholder: link to the demo video will be added before the deadline._

## AI tools used

AI coding assistants (e.g. Command Code) were used to scaffold this repository, draft documentation, and generate code. All AI-generated code is reviewed by the builder before being committed.

## External libraries and attribution

_Placeholder: external libraries and their licenses will be listed here as they are added._

## License

MIT — see [LICENSE](LICENSE).
