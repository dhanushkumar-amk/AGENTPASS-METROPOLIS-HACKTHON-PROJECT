# Deployments

This document tracks smart contracts deployed to the Monad Testnet (Chain ID `10143`).

## Deployed Contracts

| Contract | Network | Address | Tx hash | Explorer link | Date |
| --- | --- | --- | --- | --- | --- |
| HelloMonad | Monad Testnet | `0x03ac420bfc16bec578396e7de13792a5c806df50` | `0x69f85ce0d7146daef485cb106dc20d5c83fd80869864eaf8da7a52c0bac2a640` | [Monadscan](https://testnet.monadscan.com/address/0x03ac420bfc16bec578396e7de13792a5c806df50) | 2026-10-05 |

## Verification Command

To verify `HelloMonad` source code against Monad testnet Sourcify verifier:

```bash
forge verify-contract \
  0x03ac420bfc16bec578396e7de13792a5c806df50 \
  src/HelloMonad.sol:HelloMonad \
  --chain 10143 \
  --verifier sourcify \
  --verifier-url https://sourcify-api-monad.blockvision.org \
  --constructor-args $(cast abi-encode "constructor(string)" "Hello, Monad!")
```

## Gas Model Considerations

Monad testnet execution may account for gas charges based on the allocated gas limit rather than purely gas used. When running scripts or interacting with contracts, rely on Forge's and Cast's automatic gas estimation rather than artificially elevated gas limits.
