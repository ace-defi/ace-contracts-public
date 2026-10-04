// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface IJudgmentOracleAdapter {
    /// @dev `dataId` is an adapter-defined opaque snapshot digest. Pyth adapters
    /// derive it from feed ids, publish times, normalized prices, and the
    /// accepted publish-time window so users can reconcile the exact oracle
    /// evidence off-chain without the Judge depending on a specific oracle
    /// provider's binary payload format.
    struct OracleSnapshot {
        uint256 marketPriceWad;
        uint256 ethUsdPriceWad;
        uint64 marketPublishTime;
        uint64 ethUsdPublishTime;
        bytes32 marketPriceId;
        bytes32 ethUsdPriceId;
        bytes32 dataId;
    }

    function getRoundStartPrices(bytes[] calldata priceUpdateData)
        external
        payable
        returns (uint256 marketPriceWad, uint256 ethUsdPriceWad);

    function getRoundSettlementPrice(bytes[] calldata priceUpdateData)
        external
        payable
        returns (uint256 marketPriceWad);

    function getRoundSettlementPriceAt(
        bytes[] calldata priceUpdateData,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (OracleSnapshot memory snapshot);

    function getUpdateFee(bytes[] calldata priceUpdateData) external view returns (uint256);
}
