# Backstop

First-loss-bonded capital for AI trading agents on HSK Chain (HSK Chain Horizon Hackathon, Seoul, Track 1).

An operator posts a bond. Backers fund a senior tranche that the bond protects. An agent trades WHSK/USDT on HSKSwap through the vault, under limits the contract enforces. Losses hit the bond first; settlement is a fixed waterfall.

## Guarantees enforced on-chain
- The agent can only swap WHSK/USDT through the HSKSwap router, and the vault is always the recipient.
- A buy can never spend USDT that backs senior principal: `USDT balance - amountIn >= senior deposits`. At most the bond (plus realized profit) is ever at risk, so senior backers are whole even if the token goes to zero.
- Per-trade size cap, cooldown, and a slippage floor measured against a 30 minute TWAP from the pool.
- A permissionless circuit breaker trips when mark-to-market falls below 80% of the bond lost; after that anyone can unwind.
- Settlement: senior gets principal first, then profit splits 70/30 (senior/operator); operator gets the remainder after losses.

## Layout
- `src/BackstopVault.sol` the vault. `src/HskPoolOracle.sol` TWAP quotes from the pool, no dependencies.
- `test/` unit tests, plus mainnet-fork tests (set `HSK_RPC_URL=https://mainnet.hsk.xyz`).
- `app/` the agent loop and chat UI (`VAULT`, `ORACLE` env; dry run unless `AGENT_KEY` is set).

## Scripted loss demo (HSK mainnet fork)
```
HSK_RPC_URL=https://mainnet.hsk.xyz forge test --match-test test_DemoLoss -vv
```
The agent buys with the whole bond at risk, a whale dumps 2,000,000 WHSK, the position is unwound at the crashed price, the bond absorbs the loss, and senior backers receive their 80 USDT in full.

## Known limits
- Liquidity on HSKSwap is tiny, so this is risk infrastructure, not a profit claim.
- The exit slippage floor is wide (20% of TWAP) so the position can be closed in a crash. That loss is bounded by the bond.
- Not audited.
