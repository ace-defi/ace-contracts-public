// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

import "../interfaces/IJudgmentOracleAdapter.sol";

/// @notice Generic Pyth adapter for single-asset market/USD judgment rounds.
/// @dev The IJudgmentOracleAdapter snapshot keeps the historical `ethUsd`
/// field names. On non-Ethereum chains, this adapter treats that field as the
/// native entry asset/USD reference; HyperEVM must configure it as HYPE/USD.
contract PythMarketUsdJudgmentOracleAdapter is IJudgmentOracleAdapter {
    using Math for uint256;

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 private constant MAX_DECIMAL_EXPONENT = 77;

    IPyth public immutable pyth;
    bytes32 public immutable marketUsdPriceId;
    bytes32 public immutable nativeUsdPriceId;
    uint256 public immutable maxPriceAge;
    uint16 public immutable maxConfidenceBps;

    error InvalidAddress();
    error InvalidPriceFeed();
    error InvalidMaxPriceAge();
    error InvalidConfidenceBps();
    error UnexpectedUpdateFee();
    error InvalidHistoricalWindow();
    error InvalidPythPrice();
    error InvalidPythExponent();
    error PythConfidenceTooWide();

    constructor(
        address pyth_,
        bytes32 marketUsdPriceId_,
        bytes32 nativeUsdPriceId_,
        uint256 maxPriceAge_,
        uint16 maxConfidenceBps_
    ) {
        if (pyth_ == address(0)) {
            revert InvalidAddress();
        }
        if (marketUsdPriceId_ == bytes32(0) || nativeUsdPriceId_ == bytes32(0)) {
            revert InvalidPriceFeed();
        }
        if (maxPriceAge_ == 0) {
            revert InvalidMaxPriceAge();
        }
        if (maxConfidenceBps_ == 0 || maxConfidenceBps_ > BPS_DENOMINATOR) {
            revert InvalidConfidenceBps();
        }

        pyth = IPyth(pyth_);
        marketUsdPriceId = marketUsdPriceId_;
        nativeUsdPriceId = nativeUsdPriceId_;
        maxPriceAge = maxPriceAge_;
        maxConfidenceBps = maxConfidenceBps_;
    }

    function ethUsdPriceId() external view returns (bytes32) {
        return nativeUsdPriceId;
    }

    function getRoundStartPrices(bytes[] calldata priceUpdateData)
        external
        payable
        override
        returns (uint256 marketPriceWad, uint256 ethUsdPriceWad)
    {
        _updatePyth(priceUpdateData);

        marketPriceWad = _readPriceWad(marketUsdPriceId);
        ethUsdPriceWad = marketUsdPriceId == nativeUsdPriceId
            ? marketPriceWad
            : _readPriceWad(nativeUsdPriceId);
    }

    function getRoundSettlementPrice(bytes[] calldata priceUpdateData)
        external
        payable
        override
        returns (uint256 marketPriceWad)
    {
        _updatePyth(priceUpdateData);

        marketPriceWad = _readPriceWad(marketUsdPriceId);
    }

    function getRoundSettlementPriceAt(
        bytes[] calldata priceUpdateData,
        uint64 minPublishTime,
        uint64 maxPublishTime
    )
        external
        payable
        override
        returns (IJudgmentOracleAdapter.OracleSnapshot memory snapshot)
    {
        PythStructs.PriceFeed[] memory feeds = _parsePriceFeedsAt(
            priceUpdateData,
            _singlePriceIdArray(marketUsdPriceId),
            minPublishTime,
            maxPublishTime
        );
        uint256 marketPriceWad = _priceWad(feeds[0].price);
        uint64 marketPublishTime = uint64(feeds[0].price.publishTime);
        bool nativeMarket = marketUsdPriceId == nativeUsdPriceId;
        uint256 nativeUsdPriceWad = nativeMarket ? marketPriceWad : 0;
        uint64 nativeUsdPublishTime = nativeMarket ? marketPublishTime : 0;

        snapshot = IJudgmentOracleAdapter.OracleSnapshot({
            marketPriceWad: marketPriceWad,
            ethUsdPriceWad: nativeUsdPriceWad,
            marketPublishTime: marketPublishTime,
            ethUsdPublishTime: nativeUsdPublishTime,
            marketPriceId: marketUsdPriceId,
            ethUsdPriceId: nativeUsdPriceId,
            dataId: _oracleDataId(
                marketUsdPriceId,
                marketPublishTime,
                marketPriceWad,
                nativeUsdPriceId,
                nativeUsdPublishTime,
                nativeUsdPriceWad
            )
        });
    }

    function getUpdateFee(bytes[] calldata priceUpdateData) external view override returns (uint256) {
        return pyth.getUpdateFee(priceUpdateData);
    }

    function _updatePyth(bytes[] calldata priceUpdateData) private {
        uint256 updateFee = pyth.getUpdateFee(priceUpdateData);
        if (msg.value != updateFee) {
            revert UnexpectedUpdateFee();
        }
        if (priceUpdateData.length != 0) {
            pyth.updatePriceFeeds{value: updateFee}(priceUpdateData);
        }
    }

    function _parsePriceFeedsAt(
        bytes[] calldata priceUpdateData,
        bytes32[] memory priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) private returns (PythStructs.PriceFeed[] memory feeds) {
        // Fail closed for legacy [t-2, t+2] callers. The Judge must request
        // [t, t+2], and Pyth authenticates the first update at or after t.
        if (maxPublishTime < minPublishTime || maxPublishTime - minPublishTime > 2) {
            revert InvalidHistoricalWindow();
        }
        uint256 updateFee = pyth.getUpdateFee(priceUpdateData);
        if (msg.value != updateFee) {
            revert UnexpectedUpdateFee();
        }

        feeds = pyth.parsePriceFeedUpdatesUnique{value: updateFee}(
            priceUpdateData,
            priceIds,
            minPublishTime,
            maxPublishTime
        );
    }

    function _readPriceWad(bytes32 priceId) private view returns (uint256) {
        return _priceWad(pyth.getPriceNoOlderThan(priceId, maxPriceAge));
    }

    function _priceWad(PythStructs.Price memory price) private view returns (uint256 priceWad) {
        uint256 confidenceBps;
        (priceWad, confidenceBps) = _priceWadAndConfidence(price);
        if (confidenceBps > maxConfidenceBps) {
            revert PythConfidenceTooWide();
        }
    }

    function _priceWadAndConfidence(
        PythStructs.Price memory price
    ) private pure returns (uint256 priceWad, uint256 confidenceBps) {
        if (price.price <= 0) {
            revert InvalidPythPrice();
        }

        uint256 rawPrice = uint256(uint64(price.price));
        priceWad = _scaleToWad(rawPrice, price.expo);
        if (priceWad == 0) {
            revert InvalidPythPrice();
        }

        confidenceBps = uint256(price.conf).mulDiv(
            BPS_DENOMINATOR,
            rawPrice
        );
    }

    function _singlePriceIdArray(
        bytes32 priceId
    ) private pure returns (bytes32[] memory priceIds) {
        priceIds = new bytes32[](1);
        priceIds[0] = priceId;
    }

    function _oracleDataId(
        bytes32 marketPriceId,
        uint64 marketPublishTime,
        uint256 marketPriceWad,
        bytes32 ethUsdPriceId_,
        uint64 ethUsdPublishTime,
        uint256 ethUsdPriceWad
    ) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    "ACE_PYTH_ORACLE_SNAPSHOT_V1",
                    marketPriceId,
                    marketPublishTime,
                    marketPriceWad,
                    ethUsdPriceId_,
                    ethUsdPublishTime,
                    ethUsdPriceWad
                )
            );
    }

    function _scaleToWad(uint256 value, int32 expo) private pure returns (uint256) {
        if (value == 0) {
            return 0;
        }

        if (expo >= 0) {
            uint256 positiveExpo = uint256(uint32(expo));
            if (positiveExpo > MAX_DECIMAL_EXPONENT) {
                revert InvalidPythExponent();
            }
            return value * _pow10(positiveExpo) * WAD;
        }

        uint256 decimals = uint256(-int256(expo));
        if (decimals <= 18) {
            return value * _pow10(18 - decimals);
        }

        return value / _pow10(decimals - 18);
    }

    function _pow10(uint256 exponent) private pure returns (uint256) {
        if (exponent > MAX_DECIMAL_EXPONENT) {
            revert InvalidPythExponent();
        }

        return 10 ** exponent;
    }
}
