# TempoMultiSig

Multi-signature wallet for [Tempo](https://tempo.xyz/) — the L1 blockchain for stablecoin payments by Stripe & Paradigm.

## What Is This?

A **shared wallet** that requires multiple approvals before any funds can be sent. No single person can move money alone — a minimum number of owners must agree first.

```
Example: 3 people own a wallet → at least 2 must approve → then funds are sent
```

This is commonly used for:
- **Team/DAO treasury** — protect shared funds from a single bad actor
- **Business partnerships** — require mutual consent for every payment
- **Escrow** — buyer, seller, and arbiter each hold a key
- **Personal security** — split keys across your phone, laptop, and hardware wallet

## How It Works

### Step-by-step Flow

```
1. Alice submits: "Send 5,000 USDC to 0xVendor — Invoice #042"
   → Auto-approved by Alice (1/2 approvals)

2. Bob reviews and approves
   → Threshold reached (2/2) ✅
   → Funds sent automatically to vendor

3. Transaction is recorded on-chain with memo "Invoice #042"
```

### What if something goes wrong?

```
- Alice submits a suspicious tx → Bob calls cancel() → tx is dead
- Alice approved but changed her mind → calls revoke() before threshold
- Nobody approves for 7 days → tx expires automatically
```

## Features

- **M-of-N multisig** — configurable threshold (e.g., 2-of-3, 3-of-5)
- **TIP-20 stablecoin support** — send USDC, USDT, or any TIP-20/ERC-20 token
- **Native coin support** — also supports native chain currency transfers
- **Memo field** — attach payment notes to every transaction (invoice ID, description, etc.)
- **Auto-execute** — transaction executes automatically the moment threshold is reached
- **Cancel** — any owner can cancel a pending transaction
- **Revoke** — withdraw your approval before execution
- **Tx Expiry** — pending transactions expire after 7 days if not fully approved
- **Owner management** — add/remove owners and change threshold via multisig vote

## Contract Functions

### Core Functions

| Function | Who Can Call | Description |
|----------|-------------|-------------|
| `submit(to, value, token, memo)` | Any owner | Propose a new payment. Automatically counts as the submitter's approval. If threshold is 1, executes immediately. Returns the transaction ID. |
| `approve(txId)` | Any owner | Approve a pending transaction. If this approval reaches the threshold, the transaction executes automatically. Cannot approve twice. |
| `revoke(txId)` | Any owner | Withdraw your approval from a pending transaction. Only works if you previously approved and the tx hasn't executed yet. |
| `cancel(txId)` | Any owner | Permanently cancel a pending transaction. Once cancelled, it cannot be approved or executed. Use this for suspicious or incorrect transactions. |

### Owner Management

These functions can **only** be called by the wallet itself — meaning they must go through the submit/approve flow like any other transaction.

| Function | Description |
|----------|-------------|
| `addOwner(address)` | Add a new owner to the wallet. Maximum 20 owners allowed. |
| `removeOwner(address)` | Remove an existing owner. Fails if removal would make the owner count less than the threshold. |
| `changeThreshold(uint256)` | Change the minimum number of approvals required. Must be between 1 and the current number of owners. |

### View Functions (read-only, no gas cost)

| Function | Returns |
|----------|---------|
| `getOwners()` | Array of all owner addresses |
| `getTransaction(txId)` | Full transaction details: recipient, amount, token, memo, executed status, cancelled status, approval count, timestamp |
| `getTransactionCount()` | Total number of submitted transactions |
| `getBalance(token)` | Wallet balance for a specific token (use `address(0)` for native coin) |
| `isApproved(txId, owner)` | Whether a specific owner has approved a specific transaction |
| `isTxExpired(txId)` | Whether a transaction has passed its 7-day expiry window |
| `isOwner(address)` | Whether an address is a wallet owner |
| `threshold()` | Current approval threshold |

## Security

| Protection | What It Prevents |
|-----------|-----------------|
| **Reentrancy guard** | Malicious contracts calling back into the wallet during execution to drain funds |
| **Checks-Effects-Interactions** | State is updated before external calls, preventing manipulation |
| **Transaction expiry (7 days)** | Stale transactions that no longer reflect current intent |
| **Max 20 owners** | Gas DoS from looping over an unbounded owner array |
| **Zero-address validation** | Accidentally sending funds to the burn address or adding invalid owners |
| **Cancel mechanism** | Any owner can kill a suspicious transaction before it executes |
| **Self-call-only admin** | Owner management requires going through the multisig flow — no single owner can add/remove others |

## Test Coverage

43 tests covering every function and edge case:

| Category | Tests | What's Verified |
|----------|-------|----------------|
| Constructor | 6 | Valid setup, rejects: no owners, bad threshold, duplicates, zero address, >20 owners |
| Submit | 5 | Native + token tx, auto-approval, rejects: non-owner, zero recipient, zero value |
| Approve + Execute | 5 | Native + token execution, rejects: double approve, non-owner, already executed |
| Revoke | 2 | Successful revoke, rejects: not previously approved |
| Cancel | 3 | Cancel works, blocks further approvals, rejects: already executed |
| Expiry | 3 | Blocks approval after 7 days, view function, still works within window |
| Reentrancy | 1 | Malicious callback cannot re-enter and drain funds |
| Owner Management | 5 | Add/remove owner, change threshold, rejects: non-wallet caller, max owners, threshold break |
| View Functions | 4 | getOwners, getTransactionCount, getBalance, constants |
| Integration | 9 | Multi-tx flow, deposit, memo storage, edge cases |

## Network

| Property | Value |
|----------|-------|
| Chain | Tempo Testnet (Moderato) |
| Chain ID | 42431 |
| RPC | `https://rpc.moderato.tempo.xyz` |
| Explorer | https://explore.tempo.xyz |

## Quick Start

```bash
# Build
forge build

# Run all 43 tests
forge test -vv

# Run a specific test
forge test --match-test test_ApproveAndExecuteToken -vvv

# Deploy to Tempo testnet
OWNER1=0x... OWNER2=0x... OWNER3=0x... THRESHOLD=2 \
forge script script/Deploy.s.sol:DeployMultiSig \
  --rpc-url https://rpc.moderato.tempo.xyz \
  --broadcast --private-key $PRIVATE_KEY
```

## Built With

- [Foundry](https://github.com/foundry-rs/foundry) — Solidity toolchain
- [Tempo](https://tempo.xyz/) — L1 blockchain for payments (Stripe & Paradigm)
