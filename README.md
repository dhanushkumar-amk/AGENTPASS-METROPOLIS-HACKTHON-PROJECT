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

_Placeholder: step-by-step setup for Foundry contracts, the web app, and the agent will be added as each part is built._

## Demo video

_Placeholder: link to the demo video will be added before the deadline._

## AI tools used

AI coding assistants (e.g. Command Code) were used to scaffold this repository, draft documentation, and generate code. All AI-generated code is reviewed by the builder before being committed.

## External libraries and attribution

_Placeholder: external libraries and their licenses will be listed here as they are added._

## License

MIT — see [LICENSE](LICENSE).
