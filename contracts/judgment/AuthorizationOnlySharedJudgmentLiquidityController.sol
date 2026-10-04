// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./SharedJudgmentLiquidityController.sol";

/// @notice Shared controller for the Diamond stack. User USDC can enter only through
/// an exact EIP-3009 authorization bound to one market/round/direction commitment.
contract AuthorizationOnlySharedJudgmentLiquidityController is
    SharedJudgmentLiquidityController
{
    bytes32 public constant COMMIT_AUTHORIZATION_TYPEHASH =
        keccak256(
            "ACE_SHARED_COMMIT_AUTHORIZATION_V1(uint256 chainId,address controller,address judge,address vault,address owner,bytes32 marketId,uint256 roundId,uint8 direction,uint256 entryAmount,uint256 validAfter,uint256 validBefore,bytes32 nonceSalt)"
        );
    uint256 public constant MAX_AUTHORIZATION_VALIDITY = 1 hours;

    error AuthorizationRequired();
    error InvalidAuthorization();

    constructor(
        address poolVault_,
        address admin_,
        address judgeAdmin_,
        uint16 globalCapacityBps_,
        uint16 defaultMarketCapacityBps_,
        uint16 roundCapacityBps_,
        uint16 maxOpenRounds_
    )
        SharedJudgmentLiquidityController(
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
        bytes32,
        uint256,
        uint256,
        address,
        uint256,
        uint256
    ) external virtual override {
        revert AuthorizationRequired();
    }

    function commitAuthorizationNonce(
        address owner,
        bytes32 marketId,
        uint256 roundId,
        uint8 direction,
        uint256 entryAmount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonceSalt
    ) public view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    COMMIT_AUTHORIZATION_TYPEHASH,
                    block.chainid,
                    address(this),
                    judge,
                    address(poolVault),
                    owner,
                    marketId,
                    roundId,
                    direction,
                    entryAmount,
                    validAfter,
                    validBefore,
                    nonceSalt
                )
            );
    }

    function commitMarketJudgmentWithAuthorization(
        bytes32 marketId,
        uint256 roundId,
        uint256 judgmentId,
        address owner,
        uint8 direction,
        uint256 entryAmount,
        uint256 maxPayoutAmount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonceSalt,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant onlyJudge {
        if (asset == NATIVE_ASSET) revert InvalidAsset();
        if (
            owner == address(0) ||
            direction > 2 ||
            validBefore <= block.timestamp ||
            validBefore <= validAfter ||
            validBefore - block.timestamp > MAX_AUTHORIZATION_VALIDITY
        ) {
            revert InvalidAuthorization();
        }

        _commitJudgment(
            CommitParams({
                marketId: marketId,
                roundId: roundId,
                judgmentId: judgmentId,
                owner: owner,
                entryAmount: entryAmount,
                maxPayoutAmount: maxPayoutAmount
            })
        );
        poolVault.receiveBusinessAssetWithAuthorization(
            owner,
            entryAmount,
            0,
            validAfter,
            validBefore,
            commitAuthorizationNonce(
                owner,
                marketId,
                roundId,
                direction,
                entryAmount,
                validAfter,
                validBefore,
                nonceSalt
            ),
            v,
            r,
            s
        );
    }
}
