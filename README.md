# Flash Loan Arbitrage — Ethereum Mainnet

Smart contract infrastructure for executing atomic flash loan arbitrage across decentralized exchanges on Ethereum L1.

Borrows via DAI flash mint, executes multi-hop swaps across Uniswap V2, Uniswap V3, and SushiSwap, and repays within a single transaction. If the trade is not profitable after gas, the entire transaction reverts. No capital at risk.

## How It Works

1. Contract initiates a DAI flash mint (zero-fee borrow)
2. Swaps DAI for a target token on the lower-priced DEX
3. Sells the target token on the higher-priced DEX
4. Repays the flash mint
5. Profit remains in the contract

All four steps execute atomically in one transaction. If step 4 cannot be satisfied (meaning the arb was not profitable), the EVM reverts the entire sequence. Nothing is lost.

## Architecture

The contract supports three execution paths:

- **V2 to V2:** Uniswap V2 vs SushiSwap. Classic AMM arbitrage between identical pair pools with different reserves.
- **V3 fee tier arbitrage:** Same pair on Uniswap V3 but across different fee tiers (0.05%, 0.3%, 1%). Price discrepancies arise from concentrated liquidity positions.
- **V3 to V2 cross-protocol:** Buy on one protocol, sell on the other. Exploits structural pricing differences between constant-product and concentrated liquidity AMMs.

### Key Design Decisions

- **DAI flash mint over Aave/dYdX flash loans:** Zero fee. Aave charges 0.09%. On a 100 ETH arb, that is real money.
- **Executor whitelist:** Owner can authorize multiple bot addresses without transferring ownership.
- **Pause mechanism:** Kill switch for the contract without needing to withdraw funds first.
- **ReentrancyGuard:** Defense in depth on all external execution paths.

## Supported DEXs

| DEX | Type | Address |
|-----|------|---------|
| Uniswap V2 | Constant Product AMM | `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` |
| SushiSwap | Constant Product AMM | `0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F` |
| Uniswap V3 | Concentrated Liquidity | `0xE592427A0AEce92De3Edee1F18E0157C05861564` |

## Stack

- Solidity 0.8.20
- OpenZeppelin (Ownable, ReentrancyGuard)
- Hardhat
- ethers.js

## Disclaimer

This is research and educational code. MEV extraction on Ethereum mainnet is dominated by sophisticated searchers running custom infrastructure. This contract demonstrates the architecture and mechanics of flash loan arbitrage.

## License

MIT
