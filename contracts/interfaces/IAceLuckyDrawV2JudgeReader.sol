// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/// @notice Narrow read-only Judge view used by AceLuckyDrawV2.
/// @dev V2 only needs the immutable Judgment record and the stable round prefix
/// through `started`; later settlement and expiry fields intentionally do not
/// participate in immediate ticket eligibility.
interface IAceLuckyDrawV2JudgeReader {
    function judgments(
        uint256 judgmentId
    )
        external
        view
        returns (
            bytes32 marketId,
            uint256 roundId,
            address user,
            uint8 entryAsset,
            uint8 direction,
            bool resolved,
            uint256 amountAsset
        );

    function rounds(
        bytes32 marketId,
        uint256 roundId
    )
        external
        view
        returns (
            bytes32 storedMarketId,
            uint256 storedRoundId,
            uint256 startTime,
            uint256 lockTime,
            uint256 settleTime,
            uint256 nativeUsdReference,
            uint256 startMarketPriceWad,
            uint256 openTwap,
            uint256 finalTwap,
            bool started
        );
}
