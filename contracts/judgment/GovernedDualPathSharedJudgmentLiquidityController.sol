// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./DualPathSharedJudgmentLiquidityController.sol";
import "../interfaces/IGovernanceHub.sol";

/// @notice Fresh dual-path USDC controller with non-delegable administration.
contract GovernedDualPathSharedJudgmentLiquidityController is
    DualPathSharedJudgmentLiquidityController
{
    error FixedGovernance();

    constructor(
        address vault,
        address hub,
        uint16 globalCap,
        uint16 marketCap,
        uint16 roundCap,
        uint16 maxRounds
    )
        DualPathSharedJudgmentLiquidityController(
            vault,
            hub,
            hub,
            globalCap,
            marketCap,
            roundCap,
            maxRounds
        )
    {
        if (IGovernanceHub(hub).authorityEpoch() == 0) revert FixedGovernance();
    }

    function grantRole(bytes32, address) public pure override {
        revert FixedGovernance();
    }
    function revokeRole(bytes32, address) public pure override {
        revert FixedGovernance();
    }
    function renounceRole(bytes32, address) public pure override {
        revert FixedGovernance();
    }
}
