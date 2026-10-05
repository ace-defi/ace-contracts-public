# ACE Contracts

Production contract sources for ACE V5 and its bound Lucky Draw V3 instances
on HyperEVM mainnet (chain ID **999**).

## Scope

This repository contains the deployed governance hub, V5 vaults, liquidity
controllers, Judge diamond and facets, Pyth oracle adapter, Lucky Draw V3,
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

### Bytecode reproduction limitation

This minimal snapshot excludes unrelated sources from the original compilation
input. With the smaller input, `GovernedSharedMarketJudgeFacet` compiles to
different bytecode despite identical contract sources and compiler settings.
Rebuilding with the original input reproduces the production facet exactly;
this repository does not claim byte-for-byte reproduction of that facet.
The other production contract types reproduce their creation bytecode and
runtime templates. The production facet's source verification is linked below.

### Public verification scope

The Judge facet's [Sourcify verification record](https://sourcify.dev/server/v2/contract/999/0x76965a2F9A2e027933406C824Bc689C2F625e2dD?fields=all)
contains the original compilation input with 109 source files, including mocks,
legacy implementations, and Lucky Draw V1/V2. Those files are already public
through source verification even though they are not all included here. This
repository's minimal scope is not a claim that the wider verification input is
private, or that every source in that input is an active production deployment.

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
| Judge core facet | `GovernedSharedMarketJudgeFacet` | `0x76965a2F9A2e027933406C824Bc689C2F625e2dD` |
| Judge loupe facet | `SharedJudgmentDiamondLoupeFacet` | `0x36088D411D4b886408b0769DB96a268b34F8124a` |
| Judge diamond | `GovernedSharedJudgmentDiamond` | `0xB050D2CA38B2200B0F76E315CbF8f8E85a3820D0` |
| HYPE Lucky Draw | `AceLuckyDrawV3` | `0x92c4b052348808707A6Eb4D7aF493907B49951dF` |
| USDC Lucky Draw | `AceLuckyDrawV3` | `0xF5a64530F37279659cfc678F0b7477b556c5BA9E` |

Deployment transactions and contract code can be inspected on
[HyperEVMScan](https://hyperevmscan.io/). The Judge core facet's source match
is also available on
[Sourcify](https://repo.sourcify.dev/999/0x76965a2F9A2e027933406C824Bc689C2F625e2dD).

Runtime bytecode includes constructor-bound immutable values. A comparison
with compiler output must account for the compiler's declared immutable
references, rather than assume the runtime template is the deployed bytecode.
Source availability and source verification are not security guarantees.

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
