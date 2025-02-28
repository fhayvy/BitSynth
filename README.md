# BitSynth: Bitcoin-Backed Synthetic Assets

BitSynth is a decentralized protocol that enables users to create synthetic assets backed by Bitcoin through the Stacks blockchain. This protocol allows for the creation of various synthetic assets while maintaining collateralization with STX tokens.

## Overview

BitSynth allows users to:
- Mint synthetic assets by locking STX as collateral
- Manage their positions by adding more collateral
- Redeem synthetic assets to recover their collateral
- Participate in the liquidation of undercollateralized positions

The protocol is designed with safety in mind, implementing various features like minimum collateralization ratios, price feed verification, governance controls, and emergency pause functionality.

## Key Components

### Synthetic Assets
- Each synthetic asset is identified by a unique asset ID
- Prices are provided by authorized oracles
- Collateralization ratio is maintained at a minimum of 150%

### User Positions
- Users can create multiple positions for different synthetic assets
- Each position tracks collateral amount, synthetic amount, and timestamps
- Positions can be partially or fully redeemed

### Protocol Fees
- Minting Fee: Applied when creating new synthetic assets
- Redemption Fee: Applied when redeeming synthetic assets
- Liquidation Penalty: Applied to liquidated positions

### Governance
- Contract owner has full administrative control
- Authorized governors can update protocol parameters
- Authorized oracles can update price data

## Contract Functions

### Asset Management
- `initialize-asset`: Initialize a new synthetic asset
- `update-price`: Update the price of a synthetic asset
- `mint-synthetic`: Create a new synthetic position
- `add-collateral`: Add collateral to an existing position
- `redeem-synthetic`: Redeem synthetic assets and recover collateral
- `liquidate-position`: Liquidate an undercollateralized position

### Governance
- `add-governor`: Add a new authorized governor
- `remove-governor`: Remove an authorized governor
- `add-oracle`: Add a new authorized oracle
- `remove-oracle`: Remove an authorized oracle
- `set-pause-state`: Pause or unpause the contract
- `update-protocol-fees`: Update protocol fee rates
- `update-cooldown-period`: Update redemption cooldown period
- `withdraw-protocol-fees`: Withdraw accumulated protocol fees

### Read-Only Functions
- `get-position`: Get details of a user's position
- `get-position-info`: Get formatted info of a user's position
- `check-collateralization-ratio`: Calculate the current ratio for a position
- `is-liquidatable`: Check if a position can be liquidated
- `get-asset-info`: Get details of a synthetic asset
- `get-asset-stats`: Get statistics for a synthetic asset
- `get-current-price`: Get the current price of an asset
- `get-protocol-fees`: Get accumulated protocol fees
- `get-fee-rates`: Get current protocol fee rates
- `get-protocol-settings`: Get current protocol settings

## Security Features

- Minimum collateralization ratio of 150%
- Price expiration to prevent using stale data
- Emergency pause functionality
- Redemption cooldown to prevent flash loan attacks
- Rigorous authorization checks

## Error Codes

| Code | Description |
|------|-------------|
| u100 | Owner only |
| u101 | Insufficient collateral |
| u102 | Below minimum mint amount |
| u103 | Above maximum mint amount |
| u104 | Invalid asset |
| u105 | Unsafe collateralization ratio |
| u106 | Position not found |
| u107 | Unauthorized |
| u108 | Price data expired |
| u109 | Transfer failed |
| u110 | Position not closed |
| u111 | Invalid fee |
| u112 | Governance only |
| u113 | Oracle only |
| u114 | Contract paused |
| u115 | In cooldown period |

## Getting Started

To interact with the BitSynth protocol:

1. Deploy the contract to the Stacks blockchain
2. Initialize synthetic assets
3. Set up oracles for price feeds
4. Users can then mint synthetic assets by providing collateral

## Development

This contract is written in Clarity, the smart contract language for the Stacks blockchain. To develop locally:

1. Install the Clarity CLI
2. Use Clarinet for local testing
3. Deploy to testnet before mainnet deployment

## Disclaimer

This protocol involves financial risk. Users should understand the risks associated with collateralized debt positions and synthetic assets before participating.