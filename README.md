# Flash Loan Arbitrage — Arbitrum

Smart contract infrastructure for executing atomic flash loan arbitrage on Arbitrum One. Uses Balancer flash loans to borrow capital and routes trades across Uniswap V3 and V2-style DEXs on the Arbitrum network.

Lower gas costs on L2 make smaller spreads profitable. Same atomic execution guarantees as L1.

## How It Works

1. Contract requests a flash loan from the Balancer Vault
2. Executes a buy on the lower-priced DEX
3. Executes a sell on the higher-priced DEX
4. Repays the Balancer flash loan (zero fee)
5. Profit stays in the contract

The entire sequence is atomic. If the arb is not profitable, the transaction reverts and no funds are lost.

## Architecture

### Why Balancer on Arbitrum

Aave V3 is available on Arbitrum but charges a 0.05% flash loan premium. Balancer Vault flash loans are free. On high-frequency low-margin arbitrage, that fee difference is the difference between profitable and not.

### Execution Strategies

- **V3 fee tier arbitrage:** Same token pair across different Uniswap V3 fee tiers. Concentrated liquidity creates persistent price discrepancies between the 0.05%, 0.3%, and 1% pools.
- **V3 to V2 cross-protocol:** Buy on Uniswap V3, sell on a V2 router (or vice versa). Structural pricing differences between AMM types.
- **Multi-hop routing:** For pairs without deep direct liquidity, route through intermediate tokens to capture larger effective spreads.

### Key Design Decisions

- **Balancer Vault as flash loan source:** Zero-fee flash loans on Arbitrum.
- **Approved router mapping:** Owner whitelists V2 routers to prevent unauthorized contract interactions.
- **Minimum profit enforcement:** Every arb function takes a `minProfit` parameter. If the realized profit is below this threshold after execution, the transaction reverts.
- **Owner-only execution:** All arb functions are restricted to the contract owner to prevent front-running of discovered opportunities.

## Contracts

| Contract | Purpose |
|----------|---------|
| `FlashArbitrageArbitrum.sol` | Core arbitrage logic with Balancer flash loan integration |

## Key Addresses (Arbitrum One)

| Protocol | Address |
|----------|---------|
| Balancer Vault | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` |
| Uniswap V3 SwapRouter | `0xE592427A0AEce92De3Edee1F18E0157C05861564` |

## Stack

- Solidity 0.8.20
- Balancer V2 Vault (flash loans)
- Uniswap V3 (concentrated liquidity)
- Hardhat
- ethers.js
- Arbitrum One / Arbitrum Sepolia

## Disclaimer

This is research and educational code. Flash loan arbitrage on Arbitrum, like all MEV activity, operates in a competitive environment. This contract demonstrates the architecture and mechanics of L2 flash loan arbitrage.

## License

MIT
