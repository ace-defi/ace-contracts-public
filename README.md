# ACE Contracts

Production contract sources for ACE V5 and its bound Lucky Draw V3 instances
on HyperEVM mainnet (chain ID **999**).

The active Judge facet adds New York session and exchange-calendar TIE seed
weights, activated on **2026-11-13**. It retains the 2026-10-23 refund principal
cap fix. Existing Vaults, Controllers, and Lucky Draw instances were not replaced.

## Scope

This repository contains the deployed governance hub, V5 vaults, liquidity
controllers, Judge diamond and facets, Scheduled TIE Seed Policy, Pyth oracle
adapter, Lucky Draw V3,
and the source files they import.

Some dependency filenames contain earlier version numbers, including the
V3/V4 vault base classes and the Lucky Draw V2 Judge reader interface. They
are required by the current contracts; they do not identify additional legacy
deployments included in this release.

Tests, localchain fixtures, deployment scripts, operational services, private
release records, credentials, and previous repository history are not included.

## Build

Use Node.js 22 and npm 10:

```sh
npm ci --ignore-scripts
npm run compile
```

The dependency lockfile and local compiler are pinned. Build settings match
the production release:

- Solidity: `0.8.19+commit.7dd6d404`
- Optimizer: enabled, 200 runs
- Via IR: enabled
- Metadata bytecode hash: `none`
- EVM target: Paris (the Solidity 0.8.19 default)
- OpenZeppelin contracts and upgradeable contracts: `4.9.6`
- Pyth Solidity SDK: `3.1.0`

Artifacts and cache files are generated locally and are not tracked. The npm
package is marked private to prevent accidental npm publication; this does not
restrict source use under the license.

### Bytecode reproduction

The clean build reproduces the active `GovernedScheduledMarketJudgeFacet` and
`ScheduledTieSeedPolicy` creation bytecode and runtime templates. The public
[release manifest](deployments/hyperevm-20261113.json) records constructor
arguments, source hashes, creation transactions, and separate template/deployed
runtime hashes. The verifier fills **only compiler-declared immutable locations**
using the recorded address/market bindings, then compares every runtime byte,
including metadata. It also checks mined creation input and the 55 selectors
currently routed by the Judge diamond.

```sh
node scripts/verify-production.cjs --offline
node scripts/verify-production.cjs
```

The second command uses the public Hyperliquid RPC by default. An optional
`HYPEREVM_RPC_URL` may select another chain-999 RPC; no signing keys are needed.
Use a synchronized system clock: the online check accepts a head age from -30
to +120 seconds and reports the block number, hash and time. RPC transport or
history availability errors are failures to verify, not evidence of a code
mismatch. Pin the public Git commit when reviewing these files; the manifest is
not a separate signed attestation. These are consistency checks, not a security
audit. Later governance upgrades may legitimately make this dated manifest fail
against current routing.

### Public verification scope

The source closure needed by the two November contracts is included here, with
locked compiler/dependencies. The deployment build used a larger compiler input;
unused private-project files are omitted, while **full bytecode equality is
required**. Read-only verification tooling and public chain evidence are included;
private operational records and credentials are not.

The previous 2026-10-23 facet and its reproducible source tree are retained in
[public commit 1c4cf74](https://github.com/ace-defi/ace-contracts-public/tree/1c4cf74ac4b3a8731df1d0921afacaa496259cc1).
Its [verified compiler input](https://hyperevmscan.io/address/0x3aC098C03752e574BBA6C833455B20fB1413Db85#code)
contains additional legacy/mocks; source visibility does not imply deployment.
The November tree's inherited base facet is a dependency of the active scheduled
facet; use the historical commit to reproduce the previous facet instance.

## Production deployments

| Component | Contract | HyperEVM address |
| --- | --- | --- |
| Governance / timelock | `GovernanceHub` | `0xD876385880F48685bf36e516CEDC73d100EA7778` |
| HYPE vault | `SharedPoolVaultV5` | `0xd39C426bd1a40b5cdB89B8CEb8464C4f78AbB29d` |
| USDC vault | `SharedPoolVaultV5` | `0xf725Ac947c7B3EF790a3E68e2Ca2Fb48ce4023eD` |
| HYPE liquidity controller | `GovernedSharedJudgmentLiquidityController` | `0x6D757eA00be86E04ca30Ac36157BA992d66AC279` |
| USDC liquidity controller | `GovernedDualPathSharedJudgmentLiquidityController` | `0xD2413a0e6753F24FEabD6B1c951C83C2beBF304A` |
| BTC/USD oracle adapter | `PythMarketUsdJudgmentOracleAdapter` | `0xAE11841D83Ab52E75475a5BB4aEbc067Bd23A307` |
| ETH/USD oracle adapter | `PythMarketUsdJudgmentOracleAdapter` | `0x12E88b379bDFC8392fA604Db7eB428C7aeAD8E04` |
| HYPE/USD oracle adapter | `PythMarketUsdJudgmentOracleAdapter` | `0xb484346156670BFaA82929A1680D957c71E15A97` |
| Judge core facet | `GovernedScheduledMarketJudgeFacet` | `0xb4a815a0a2bC931fe57BE9a6B66D52Ed5Bd6B87c` |
| Scheduled TIE seed policy | `ScheduledTieSeedPolicy` | `0x6fc0647d4E8b78c4b37256836F7db929388234a1` |
| Judge loupe facet | `SharedJudgmentDiamondLoupeFacet` | `0x36088D411D4b886408b0769DB96a268b34F8124a` |
| Judge diamond | `GovernedSharedJudgmentDiamond` | `0xB050D2CA38B2200B0F76E315CbF8f8E85a3820D0` |
| HYPE Lucky Draw | `AceLuckyDrawV3` | `0x92c4b052348808707A6Eb4D7aF493907B49951dF` |
| USDC Lucky Draw | `AceLuckyDrawV3` | `0xF5a64530F37279659cfc678F0b7477b556c5BA9E` |

Deployment transactions and current contract code can be inspected on
[HyperEVMScan](https://hyperevmscan.io/). Both the
[active facet](https://hyperevmscan.io/address/0xb4a815a0a2bC931fe57BE9a6B66D52Ed5Bd6B87c#code)
and [Policy](https://hyperevmscan.io/address/0x6fc0647d4E8b78c4b37256836F7db929388234a1#code)
passed full source verification (not a similar-match result). Independent
readback of source contents, compiler settings and constructor arguments is in the
[verification receipt](deployments/source-verification-20261113.json).
The [bytecode check receipt](deployments/bytecode-verification-20261113.json)
records the independently checked chain snapshot.
Source availability and source verification are not security guarantees.

### Scheduled TIE seed upgrade, 2026-11-13

The [executed upgrade](https://hyperevmscan.io/tx/0x914bb4fd9ac90cefdae880f14e39128833d76595677243355efd00bd1541bf77)
replaced the 55 Judge selectors and resumed rounds at block `51141793`
(2026-11-13 08:58:21 UTC), without an initializer or a Vault/Controller/Lucky
replacement. The facet runtime is **24,469 bytes**, hash
`0xfcb8f9da2d29d130e1caf69e6599d3bc21bcb60fa009398b9babd72eb7e266b6`.
The Policy runtime is **3,841 bytes**, hash
`0x907204247a3787126ff26618ff3c079b58ca561e5a201ba9b0d32e56396e9c47`.

The Policy is bound to the existing HYPE/USD market
`0xbdb01e59906dc12af7442d9557d2c3e8b193fea6c1c02f25f87c34cf29b4edc4`
and the deployed GovernanceHub. Other markets retain their configured seed weights.
New rounds snapshot weights from their **scheduled start**, not transaction arrival
time; existing rounds keep their snapshots. Settlement and claims do not call the
Policy. Governance can update the recurring weights, same-day core window, and
dated overrides through the existing timelock.

At activation, TIE seed weights were `750 / 937 / 937` basis points for weekday
core / weekday other / weekend or configured closure. This uses two distinct
values across three session categories. These are **seed-pool weights, not
estimated outcome probabilities or guaranteed payout multipliers**. Other payout
parameters and subsequent real entries also affect the quote.

The configured scheduled-start window is **09:25–15:55 America/New_York**, start
inclusive and end exclusive. For the current five-minute rounds, this corresponds
to lock/reference-price boundaries of 09:30–16:00. US daylight saving time is
handled using the post-2007 rule. The manifest lists the **34 NYSE date overrides
for 2026–2028**, including early-close start windows ending at 12:55 (13:00 lock).
These are exchange-calendar exceptions, not all US federal holidays. Exceptions
are stored by New York civil date; unlisted dates use weekly rules. They do not
refresh automatically: later calendar years and unexpected closures need a
separate governance update before they apply. The manifest records activation
configuration; later governance can change it.

### Historical deployments

| Component | Previous address | Source snapshot |
| --- | --- | --- |
| Judge core facet, 2026-10-23 | `0x3aC098C03752e574BBA6C833455B20fB1413Db85` | [1c4cf74](https://github.com/ace-defi/ace-contracts-public/tree/1c4cf74ac4b3a8731df1d0921afacaa496259cc1) |

### Refund principal cap upgrade, 2026-10-23

The Judge now rejects an entry whose principal exceeds its round's asset payout
capacity, before updating pools or transferring funds. The check covers native
HYPE, USDC allowance and EIP-3009 entry paths. It ensures the recorded payout cap
can cover a full principal refund when a round expires. Existing payout rates,
aggregate risk checks and full-refund amounts are unchanged.

The [executed governance transaction](https://hyperevmscan.io/tx/0xefc3101ff2dc03c72723795f4df4f4f71355280d4595efed4f9523ba8f54b833)
replaced 55 existing Judge selectors and resumed rounds at block `49299160`
(2026-10-23 09:27:30 UTC). It used no initializer and did not replace Vaults or
Controllers. That historical facet runtime code hash is
`0x4b25dad59b8c01b6291b8d1012fdc2b2f754c8c3d635765d23379c70f670dc8f`.

This prevents new entries with insufficient full-refund coverage; it does not
repair earlier records. Controller-side principal validation available for future
deployments is not part of the currently deployed Controller source snapshot.

## Trust model and known limitations

These disclosures describe the current deployed design, not fixes or guarantees
that privileged parties cannot cause harm.

### Governance and Vault availability

The production `GovernanceHub` uses a 24-hour timelock. The Admin Safe schedules
ordinary operations; the Guardian or Recovery Safe executes them after the delay.
Hub-authorized governance can configure or migrate business controllers, subject
to the contracts' migration checks. Two parties can jointly replace the third
through the restricted recovery path; this does not protect against collusion or
a compromise shared across the remaining parties.

The Guardian can cancel queued operations and pause immediately. `pause()` stops
new round starts; `pauseAll()` also freezes Vault business actions, LP redemption,
and payout withdrawal. Deposits remain available during an outflow freeze, so a
deposit does not imply that immediate withdrawal is possible. Existing allocated
claims are preserved but cannot be withdrawn while the relevant outflows are
frozen. Unpausing requires ordinary delayed governance.

### Lucky Draw administration and randomness

Lucky Draw prizes are funded by the project's own, asset-isolated pools, not by
LP deposits. Its Admin Safe directly controls economics, games and roles and can
withdraw available surplus, without the Hub's 24-hour delay. Reserved and already
claimable payouts are excluded from that surplus. Lucky Draw's pause blocks new
draw requests, not fulfillment or withdrawal of already claimable prizes.

Randomness uses an ACE-operated committed hash chain, not a trustless VRF. Correct
revelations and draw outcomes can be checked publicly, and assigned preimages
cannot be replaced or reordered. However, the operator knows future preimages.
An operator or associated account with an eligible Judgment can predict outcomes
and select inputs to its advantage before requesting a draw. Pool balances and
configured daily/user budgets limit prize exposure; they do not prove that the
operator cannot win its own draws. Public verifiability is not a guarantee of
operator-independent fairness.

Fulfillment is sequential and depends on the correct preimages remaining
available. Anyone with the next correct preimage can resume fulfillment after a
relayer outage. If that preimage is lost or withheld, later assigned draws can
remain blocked, reserved payouts remain locked, and the active epoch cannot be
replaced while draws are pending. There is no timeout cancellation or automatic
release path for those pending draws. Rotating a signing key does not recover
missing preimages. These are existing availability risks, not resolved by this
source release.

### USDC authorization exposure

The DualPath controller supports both Vault allowance and commitment-bound
EIP-3009 authorization. Its allowance path checks payout capacity but does not
independently cap `entryAmount` at the same boundary. Normal transfers rely on the
Judge's validation and the user's approval. If the trusted Judge/Controller path
is compromised, a large standing allowance can expose wallet funds up to the
remaining allowance and balance; the payout capacity limit is not an equivalent
wallet spending limit.

Prefer an exact, limited approval for the intended action and revoke unused
allowances. EIP-3009 authorizations bind the amount and commitment details to one
authorization rather than create a standing allowance. Neither approach is a
blanket guarantee against implementation vulnerabilities. These limitations are
disclosed, not claimed to be fixed by documentation.

For privately reporting a vulnerability, see [SECURITY.md](SECURITY.md).

## License and contact

ACE contract sources are licensed under [MIT](LICENSE). Third-party packages
retain their own licenses and notices; Solidity SPDX identifiers are preserved.

Project contact: `official@ace.pro`.
