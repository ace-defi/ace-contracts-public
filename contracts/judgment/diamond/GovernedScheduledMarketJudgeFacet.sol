// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./GovernedSharedMarketJudgeFacet.sol";
import "../ScheduledTieSeedPolicy.sol";

interface IScheduledPolicyVault {
    function governanceHub() external view returns (address);
}

/// @notice Same selectors/storage as the governed facet; only new seed snapshots
/// consult the immutable policy. Settlement and claims never call the policy.
contract GovernedScheduledMarketJudgeFacet is GovernedSharedMarketJudgeFacet {
    ScheduledTieSeedPolicy private immutable seedPolicy;

    error UnexpectedPolicyMarket();

    constructor(
        address nativeController_,
        address usdcController_,
        address policy,
        bytes32 expectedMarketId
    ) GovernedSharedMarketJudgeFacet(nativeController_, usdcController_) {
        seedPolicy = ScheduledTieSeedPolicy(policy);
        if (
            expectedMarketId == bytes32(0) ||
            seedPolicy.marketId() != expectedMarketId
        ) revert UnexpectedPolicyMarket();
        address hub = seedPolicy.governanceHub();
        if (
            IScheduledPolicyVault(address(nativeVault)).governanceHub() !=
            hub ||
            IScheduledPolicyVault(address(usdcVault)).governanceHub() != hub
        ) revert FixedGovernance();
    }

    function _roundSeedWeights(
        bytes32 market,
        uint256 startTime,
        JudgeEconomics storage economics
    ) internal view override returns (uint16, uint16, uint16) {
        return
            seedPolicy.weightsFor(
                market,
                startTime,
                economics.startUpPoolBps,
                economics.startDownPoolBps,
                economics.startTiePoolBps
            );
    }
}
