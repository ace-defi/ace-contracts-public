// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./AuthorizationOnlySharedJudgmentLiquidityController.sol";

/// @notice Shared USDC controller supporting both exact Vault allowance and
/// commitment-bound EIP-3009 authorization entry paths.
contract DualPathSharedJudgmentLiquidityController is
    AuthorizationOnlySharedJudgmentLiquidityController
{
    constructor(
        address poolVault_,
        address admin_,
        address judgeAdmin_,
        uint16 globalCapacityBps_,
        uint16 defaultMarketCapacityBps_,
        uint16 roundCapacityBps_,
        uint16 maxOpenRounds_
    )
        AuthorizationOnlySharedJudgmentLiquidityController(
            poolVault_,
            admin_,
            judgeAdmin_,
            globalCapacityBps_,
            defaultMarketCapacityBps_,
            roundCapacityBps_,
            maxOpenRounds_
        )
    {}

    function commitMarketJudgmentFromWallet(
        bytes32 marketId,
        uint256 roundId,
        uint256 judgmentId,
        address owner,
        uint256 entryAmount,
        uint256 maxPayoutAmount
    ) external override nonReentrant onlyJudge {
        _commitMarketJudgmentFromWallet(
            marketId,
            roundId,
            judgmentId,
            owner,
            entryAmount,
            maxPayoutAmount
        );
    }
}
