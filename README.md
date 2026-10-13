# IMD PEPE RISK — contracts

> **Unofficial community game.** IMD RISK (RISK) is an unofficial community coin. It is **not** the IMD
> token and is not endorsed by IMD. Frontends must show the RISK contract address and never call it official.

Risk-style territorial conquest played with Pepes on a map of 6 continents and 42 territories. Matches are
2–6 players and short (5–15 min). This repository holds the on-chain part: the launch token, match lobbies
with entry fees and commit-reveal dice seeds, IMD prizes, cosmetics sales, and RISK buy-and-burn.

Build and test (Foundry; `solc 0.8.26` is pinned in `foundry.toml`, forge-std is vendored in `lib/`):

```
forge build
forge test
forge fmt --check
```

ABIs are in `docs/abi/<Contract>.json`.

## Contracts

| Contract | File | Role |
|---|---|---|
| `LaunchToken` | `src/LaunchToken.sol` | IMD RISK / RISK. Fixed supply ERC-20: 1,000,000,000 × 10^18, minted once to the deployer (the launch factory). No mint, owner, pause, fee or upgrade. |
| `Buyback` | `src/Buyback.sol` | Holds IMD from cosmetics, buys RISK through the swap venue and sends it to `0x…dEaD` in the same transaction. Routes RISK entry fees into IMD. Reports `burnedSupply()` and `circulatingSupply()`. |
| `PrizeVault` | `src/PrizeVault.sol` | Pays prizes in IMD only, by pull payment (`claim()`). Splits 60/25/15 and applies the daily cap. Holds the bonus pool. |
| `MatchFactory` | `src/MatchFactory.sol` | Lobbies, entry fees (IMD, or RISK routed to IMD), commit-reveal seed, settlement by signatures, refunds. |
| `Cosmetics` | `src/Cosmetics.sol` | Sells cosmetic items for IMD and splits the revenue (see the burn table). Items never affect combat. |
| `RiskRules` (library) | `src/lib/RiskRules.sol` | Internal (inlined) rules: dice, battle resolution (the defender wins ties), map, reinforcements, continent bonuses. |

No contract uses DELEGATECALL, CALLCODE or SELFDESTRUCT, and no contract is a proxy. Every library function is `internal`.

## Deployment parameters (for the manifest step)

Kind `evm_project`, launch token `LaunchToken`. Contracts in dependency order, each with a nonpayable
constructor that calls no other contract:

| # | Contract | Constructor arguments (in order) |
|---|---|---|
| 1 | `Buyback` | `initialOwner` = `$owner`, `imdToken` = IMD address, `riskToken` = `$token` |
| 2 | `PrizeVault` | `initialOwner` = `$owner`, `imdToken` = IMD address |
| 3 | `MatchFactory` | `initialOwner` = `$owner`, `imdToken` = IMD address, `riskToken` = `$token`, `prizeVault` = `$contract:PrizeVault`, `buybackAddr` = `$contract:Buyback` |
| 4 | `Cosmetics` | `initialOwner` = `$owner`, `imdToken` = IMD address, `prizeVault` = `$contract:PrizeVault`, `buybackAddr` = `$contract:Buyback` |

* **Owner:** `$owner` (the launch's owner, 0x3d6a89c8751a45dd577a4c1f3b34e71c58236193). No contract makes
  `msg.sender` (the factory) or `tx.origin` an owner.
* **IMD address — open conflict for review.** The launch's chain table for Robinhood Chain (4663) gives
  IMD as `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`, which is also the pool's paired currency. The brief
  quotes `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` as IMD. These differ. I have not checked either
  address on chain. I recommend the chain table's address, because it is the launch chain's IMD, but the
  manifest step and the independent review must settle this. Whichever address is used, it is immutable
  in all four contracts.
* Pool: paired with IMD, fee 12500, tick spacing 60. The factory opens the pool at the chain's LaunchFees
  fee (1.25%). None of these contracts implements trading fees.

## After launch (owner settings)

All settings below are owner-only and emit an event. Until one is set, the functions that depend on
it revert with the error named in the table.

| Setting | Setter | What to set | Where the owner gets it | Until set |
|---|---|---|---|---|
| Vault ↔ factory link | `PrizeVault.setMatchFactory(address)` (one time) | The deployed `MatchFactory` address | The launch's deployment handoff | `settle` reverts `MatchFactoryNotConfigured` |
| Swap venue | `Buyback.setVenue(address)` | An adapter implementing `ISwapVenue.swapExactInput` (in `src/lib/Common.sol`) for the RISK/IMD pool or the IMD Community Coin curve | Deployed by the owner. Its address is not known at launch. | RISK entries and `executeBuyback` revert `VenueNotConfigured` |
| Seat outcome signer | `MatchFactory.setOutcomeSigner(address)` | The seats' outcome attestation key (set to zero to disable) | The swarm seat operators | Single-signature (seat) settlement reverts `OutcomeSignerNotConfigured`. Unanimous player settlement still works. |
| Seats/stakers recipient | `Cosmetics.setSeatRewardsRecipient(address)` | The seat/staking reward contract or wallet | Owner's choice | The 35% share builds up in `Cosmetics`; `flushSeatRewards` reverts `SeatRecipientNotConfigured` |
| Items | `Cosmetics.configureItem(id, price, maxSupply, active)` | The cosmetic catalogue (price in IMD wei) | Owner's choice | `buy` reverts `ItemUnavailable` |

The swap adapter must pull `amountIn` from the caller and send at least `minAmountOut` to the recipient.
Both `Buyback` and `MatchFactory` check the balance change themselves, so they do not rely on the
adapter's return value.

## Match lifecycle

1. **Open:** `createMatch(maxPlayers 2–6, entryFee 0.1–10,000 IMD, commit, riskIn, minImdOut)`, then
   `join(...)`. `commit = keccak256(abi.encode(matchId, player, secret))`. The lobby closes when it is
   full, when the creator calls `startReveal` with at least 2 players, or when anyone calls it after the
   30-minute join window. A lobby with fewer than 2 players after the window is cancelled and refunded.
2. **Revealing (10 min):** every player calls `reveal(matchId, secret)`. The seed is the XOR of
   `keccak256(secret)` over all players, so it is fixed only once the last player reveals.
3. **Playing (30 min):** the game runs off chain, with dice from `RiskRules.die(seed, battleIndex, k)`.
   An attack rolls up to 3 dice, a defence up to 2. The highest dice are compared in pairs and the
   **defender wins ties**. Reinforcements are `max(3, territories / 3)` plus continent bonuses: North
   America 5, South America 2, Europe 5, Africa 3, Asia 7, Australia 2. The winner is decided by
   domination, or by the highest territory count when the time limit ends.
4. **Settled:** `settle(matchId, ranking, signatures)`. The ranking is the top `min(3, players)` players.
   It needs one of:
   * **unanimous:** one EIP-712 signature from every player, in join order, over
     `Outcome(matchId, seed, keccak256(abi.encode(ranking)))`, or
   * **seat-attested:** a single signature from the configured seat outcome signer. Only seat-attested
     matches draw from the bonus pool.

   Settlement is accepted until 24 hours after the play window ends.

Failure paths (all are pull refunds in IMD through `withdrawRefund()`):

* Not all players revealed by the deadline: `cancelUnrevealed` gives the revealers their entries back
  plus an equal share of the non-revealers' entries. This stops a last revealer from aborting a seed
  they don't like for free. If nobody revealed, everyone is refunded.
* Not settled within the grace period: `expire` refunds every entry.

**RISK entries:** pass `riskIn > 0` and `minImdOut ≥ entryFee`. 10% of `riskIn` is burned to `0x…dEaD`
and 90% is swapped to IMD through `Buyback`. The entry fee stays in the pot and any extra IMD goes back to
the player. Refunds are always paid in IMD.

**1 vs swarm AI** is free play off chain. It has no on-chain pot or prize, because a solo prize could be
farmed.

## Prizes and daily caps

* Each pot is the sum of its entry fees, paid in IMD only. Nothing is minted.
* Split: 1st 60%, 2nd 25%, 3rd 15%. A 2-player match pays 75% / 25%.
* Seat-attested bonus: `min(1% of the bonus pool, 50% of the pot)` is added to the prize before it is split.
* **Daily cap:** each wallet gets at most **3 rewarded placements in a rolling 24-hour window**. The window
  starts at the first rewarded placement after the previous window expired. A placement over the cap is
  not paid; its share goes to the bonus pool. `remainingRewardedWins(wallet)` exposes the count.
* Winners call `PrizeVault.claim()` (pull payment).

## Burn table

| Source | Burn | Where the rest goes |
|---|---|---|
| RISK entry fee | 10% of the RISK burned to `0x…dEaD` immediately | 90% swapped to IMD for the pot |
| Cosmetics sale (IMD) | 20% "burn share" + 10% "buyback share" = 30% sent to `Buyback`, which buys RISK and burns it in the same transaction (`executeBuyback`) | 35% to the PrizeVault bonus pool; 35% to the seats/stakers recipient |
| RISK sent to `Buyback` | `burnHeldRisk()` burns all of it | none |

Circulating supply = `totalSupply − balanceOf(0x…dEaD)` (`Buyback.circulatingSupply()`).

## Pepe ranks (game/UI content; no on-chain effect)

| Rank | Job | Notes |
|---|---|---|
| Recruit Pepe | Basic infantry | 1 army unit |
| Scout Pepe | Recon visor | UI: reveals adjacent troop counts |
| Tank Pepe | Armour plating | Display unit for 5 armies |
| Commando Pepe | Bandana, knife | Display unit for 10 armies |
| General Pepe | Rank pips | Display unit for 25 armies |

Ranks only change how army counts are displayed. Combat uses dice only. Cosmetics change appearance only.

## Assumptions and trust model

* **Randomness:** commit-reveal among the match's players. No single player controls the seed. The last
  revealer can still choose to withhold, which costs them their entry. No timestamps or block values are
  used. This is not a VRF.
* **Outcome correctness:** game moves are not verified on chain. Unanimous settlement needs every
  player's consent, so players can only redistribute their own entries. Seat-attested settlement trusts
  the seat outcome signer to report the true ranking, and that signer can also direct bonus-pool funds,
  up to 50% of the pot per match. Sybil wallets can collude in their own matches. The daily cap limits
  this per wallet, not per person.
* **Owner powers:** set or replace the swap venue, the seat outcome signer and the seats recipient;
  configure cosmetics; link the vault once; run buybacks (owner-only, so the owner picks the slippage
  bound). The owner **cannot** move prize, refund or pot funds, and cannot mint RISK. Note that a
  malicious venue could mis-handle IMD it is approved for during `executeBuyback`, or RISK during a
  route. Allowances are exact and reset after each swap.
* Tokens are assumed to be standard ERC-20s (no fee-on-transfer or rebasing). RISK is one; IMD is assumed
  to be one.

## Not implemented as asked (and why)

* **Launch token:** a plain fixed-supply ERC-20, as the launch rules require. The token itself has no
  burn tax or "1B cap" logic; the supply is fixed at 1B by construction. The factory, not these
  contracts, does the supply split and pool seeding.
* **"Launch only as IMD Community Coin (curve priced in IMD; 0.5% IMD-leg burns)":** this launch opens a
  RISK/IMD pool through the factory at the chain's 1.25% fee. A bonding curve and IMD-leg burns are not
  part of this launch. A curve can be used later through the owner-set swap venue.
* **"1% attack tax on bought Pepes":** attacks happen off chain and there are no bought units on chain,
  so this tax is not implemented. Cosmetics are appearance-only.
* **"Buyback buys RISK on curve":** buybacks go through the owner-configured venue.
* **ONCHAIN.md economy v2** (allocation, trading receiver, split factory, platform, relayer): the launch
  factory handles allocation and trading fees. The external template was not fetched or followed here.
* **"No server, multiplayer or score signer"** conflicts with "Seats sign outcomes." Both settlement
  paths are supported: unanimous player signatures need no signer, and the seat signer is optional.

## Operational responsibilities and launch checklist

- [ ] Manifest: confirm the IMD address (see the conflict above) and the constructor order above.
- [ ] Independent adversarial review before release. Tests are not an audit; these contracts hold user funds.
- [ ] Owner: `PrizeVault.setMatchFactory(<MatchFactory>)` right after launch.
- [ ] Owner: deploy and review an `ISwapVenue` adapter, then `Buyback.setVenue`.
- [ ] Owner: `MatchFactory.setOutcomeSigner(<seat key>)` if seat attestation is used.
- [ ] Owner: `Cosmetics.setSeatRewardsRecipient` and `configureItem` for the catalogue.
- [ ] Owner: call `executeBuyback` periodically with a sensible `minRiskOut`.
- [ ] Frontend: show the "unofficial" label and the RISK address, use the exact poolKey from the
      deployment handoff, show burned/circulating totals from `Buyback`, and replay dice from the seed so
      players can check an outcome before signing.
