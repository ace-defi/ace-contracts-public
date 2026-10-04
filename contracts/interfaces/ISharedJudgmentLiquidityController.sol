// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface ISharedJudgmentLiquidityController {
    function PAYOUT_EDGE_MODEL_ID() external view returns (bytes32);

    function poolVault() external view returns (address);

    function asset() external view returns (address);

    function globalOpenRoundCount() external view returns (uint256);

    function globalReservedLoss() external view returns (uint256);

    function teamRevenueRecipient() external view returns (address);

    function treasuryRevenueRecipient() external view returns (address);

    function teamRevenueBps() external view returns (uint16);

    function treasuryRevenueBps() external view returns (uint16);

    function protocolRevenueBps() external view returns (uint16);

    function marketOpenRoundCount(
        bytes32 marketId
    ) external view returns (uint256);

    function capacityStressed(bytes32 marketId) external view returns (bool);

    function openMarketRoundCapacity(
        bytes32 marketId,
        uint256 roundId
    ) external returns (uint256 capacity);

    function commitMarketJudgmentNative(
        bytes32 marketId,
        uint256 roundId,
        uint256 judgmentId,
        address owner,
        uint256 entryAmount,
        uint256 maxPayoutAmount
    ) external payable;

    function commitMarketJudgmentFromWallet(
        bytes32 marketId,
        uint256 roundId,
        uint256 judgmentId,
        address owner,
        uint256 entryAmount,
        uint256 maxPayoutAmount
    ) external;

    function commitAuthorizationNonce(
        address owner,
        bytes32 marketId,
        uint256 roundId,
        uint8 direction,
        uint256 entryAmount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonceSalt
    ) external view returns (bytes32);

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
    ) external;

    function increaseMarketRoundReservedPayout(
        bytes32 marketId,
        uint256 roundId,
        uint256 additionalReservedPayout
    ) external;

    function settleMarketRoundPayoutPool(
        bytes32 marketId,
        uint256 roundId,
        uint256 totalPayoutAmount,
        uint256 edgeAmount
    )
        external
        returns (
            uint256 lpEdgeAmount,
            uint256 teamRevenue,
            uint256 treasuryRevenue
        );

    function refundMarketRoundPayoutPool(
        bytes32 marketId,
        uint256 roundId
    ) external;

    function allocateSettledJudgmentPayout(
        uint256 judgmentId,
        uint256 payoutAmount
    ) external;

    function allocateAndClaimSettledJudgmentPayout(
        uint256 judgmentId,
        uint256 payoutAmount,
        address receiver
    ) external;
}
