// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IJudgmentOracleAdapter.sol";
import "../interfaces/ISharedJudgmentLiquidityController.sol";
import "../interfaces/ISharedPoolVault.sol";

abstract contract SharedMarketJudgeCore is AccessControl, ReentrancyGuard {
    using Math for uint256;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint256 public constant ROUND_DURATION = 600;
    uint256 public constant ENTRY_LOCK_OFFSET = 300;
    uint256 public constant ROUND_START_ALIGNMENT = 5 minutes;
    uint256 public constant ROUND_START_GATE = 60 seconds;
    uint256 internal constant _LP_WINDOW_EPOCH_DURATION = 6 hours;
    uint256 internal constant _LP_WINDOW_DURATION = 10 minutes;
    uint256 internal constant _LP_DRAIN_DURATION = 5 minutes;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_TIE_THRESHOLD_BP = 100;
    uint256 public constant MAX_MARKETS = 8;
    uint256 public constant WAD = 1e18;
    uint256 public constant MIN_NATIVE_ENTRY_AMOUNT = 1 gwei;
    uint256 public constant MIN_USDC_ENTRY_AMOUNT = 1_000;
    uint256 public constant ORACLE_PUBLISH_TIME_TOLERANCE = 2;
    uint256 internal constant PUBLIC_SETTLEMENT_GRACE = 60 seconds;
    uint256 public constant EMERGENCY_REFUND_DELAY = 30 minutes;
    uint256 public constant LOCKED_ROUND_EMERGENCY_REFUND_DELAY = 6 hours;
    /// @dev Retained for the direct v1 per-asset capped seed model.
    uint256 public constant MAX_SEED_USD_WAD = 200e18;
    uint256 public constant SHARED_SEED_FLOOR_USD_WAD = 200e18;
    uint16 public constant MAX_SEED_BPS = 10_000;
    address public constant NATIVE_ASSET = address(0);

    enum EntryAsset {
        NATIVE,
        USDC
    }

    enum Direction {
        Up,
        Down,
        Tie
    }

    enum JudgmentResult {
        Confirmed,
        Refuted,
        Refunded
    }

    enum SettlementMode {
        Lazy,
        ExpiredRefund
    }

    struct JudgeEconomics {
        uint16 tieThresholdBp;
        uint16 upDownPayoutRateBps;
        uint16 tiePayoutRateBps;
        uint16 startUpPoolBps;
        uint16 startDownPoolBps;
        uint16 startTiePoolBps;
    }

    struct MarketConfig {
        bool enabled;
        address oracleAdapter;
        JudgeEconomics economics;
    }

    struct MarketRound {
        bytes32 marketId;
        uint256 roundId;
        uint256 startTime;
        uint256 lockTime;
        uint256 settleTime;
        uint256 nativeUsdReference;
        uint256 startMarketPriceWad;
        uint256 openTwap;
        uint256 finalTwap;
        bool started;
        bool locked;
        bool aggregateSettled;
        bool expired;
        bool normalPayoutAllocationStarted;
        Direction winningSide;
        uint256 upPoolUsd;
        uint256 downPoolUsd;
        uint256 tiePoolUsd;
        uint256 nativeCapacity;
        uint256 usdcCapacity;
        uint256 nativeReservedPayoutAmount;
        uint256 usdcReservedPayoutAmount;
        uint256 nativeSettledPayoutAmount;
        uint256 usdcSettledPayoutAmount;
        uint256 nativeFinalMultiplierWad;
        uint256 usdcFinalMultiplierWad;
        uint256 nativeResolvedWinningAmount;
        uint256 usdcResolvedWinningAmount;
        uint256 nativeAllocatedPayoutAmount;
        uint256 usdcAllocatedPayoutAmount;
        uint256 nativeUpAmount;
        uint256 nativeDownAmount;
        uint256 nativeTieAmount;
        uint256 usdcUpAmount;
        uint256 usdcDownAmount;
        uint256 usdcTieAmount;
        uint256 nativeUpPoolUsd;
        uint256 nativeDownPoolUsd;
        uint256 nativeTiePoolUsd;
        uint256 usdcUpPoolUsd;
        uint256 usdcDownPoolUsd;
        uint256 usdcTiePoolUsd;
        uint16 tieThresholdBp;
        uint16 upDownPayoutRateBps;
        uint16 tiePayoutRateBps;
        uint16 startUpPoolBps;
        uint16 startDownPoolBps;
        uint16 startTiePoolBps;
    }

    struct UsdcAuthorization {
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonceSalt;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct MarketJudgment {
        bytes32 marketId;
        uint256 roundId;
        address user;
        EntryAsset entryAsset;
        Direction direction;
        bool resolved;
        uint256 amountAsset;
    }

    struct AssetSettlement {
        uint256 winningPoolUsd;
        uint256 totalPoolUsd;
        uint256 actualMultiplierWad;
        uint256 actualPayoutAmount;
        uint256 edgeAmount;
    }

    ISharedJudgmentLiquidityController public immutable nativeController;
    ISharedJudgmentLiquidityController public immutable usdcController;
    ISharedPoolVault public immutable nativeVault;
    ISharedPoolVault public immutable usdcVault;
    uint256 public nextJudgmentId = 1;

    mapping(bytes32 => MarketConfig) public markets;
    bytes32[] public marketIds;
    mapping(bytes32 => mapping(uint256 => MarketRound)) public rounds;
    mapping(uint256 => MarketJudgment) public judgments;
    mapping(bytes32 => mapping(uint256 => uint256)) public roundIdByMarketStartTime;
    mapping(bytes32 => uint16) public marketSeedBps;

    event MarketConfigured(
        bytes32 indexed marketId,
        string marketKey,
        address oracleAdapter,
        bytes32 economicsHash,
        bool enabled
    );
    event MarketSeedConfigured(
        bytes32 indexed marketId,
        uint16 seedBps,
        uint256 seedUsdCapWad
    );
    event MarketRoundStarted(
        bytes32 indexed marketId,
        uint256 indexed roundId,
        uint256 startTime,
        uint256 lockTime,
        uint256 settleTime,
        uint256 nativeUsdReference,
        uint16 tieThresholdBp,
        uint16 upDownPayoutRateBps,
        uint16 tiePayoutRateBps,
        uint16 startUpPoolBps,
        uint16 startDownPoolBps,
        uint16 startTiePoolBps,
        uint256 nativeCapacity,
        uint256 usdcCapacity
    );
    event MarketRoundLocked(
        bytes32 indexed marketId,
        uint256 indexed roundId,
        uint256 lockedAt,
        uint256 openTwap,
        uint256 upPoolUsd,
        uint256 downPoolUsd,
        uint256 tiePoolUsd
    );
    event MarketRoundSeeded(
        bytes32 indexed marketId,
        uint256 indexed roundId,
        uint16 seedBps,
        uint256 nativeSeedUsd,
        uint256 usdcSeedUsd,
        uint256 seedUsdFloorWad
    );
    event MarketOracleSnapshot(
        bytes32 indexed marketId,
        uint256 indexed roundId,
        bool indexed isClose,
        bytes32 dataId,
        bytes32 marketPriceId,
        bytes32 nativeUsdPriceId,
        uint64 marketPublishTime,
        uint64 nativeUsdPublishTime,
        uint256 marketPriceWad,
        uint256 nativeUsdPriceWad
    );
    event MarketJudgmentCommitted(
        bytes32 indexed marketId,
        uint256 indexed roundId,
        address indexed owner,
        uint256 judgmentId,
        EntryAsset entryAsset,
        Direction direction,
        uint256 amountAsset,
        uint256 notionalUsd,
        uint256 maxReservedPayout
    );
    event MarketRoundAssetSettled(
        bytes32 indexed marketId,
        uint256 indexed roundId,
        address indexed asset,
        uint256 winningPoolUsd,
        uint256 totalPoolUsd,
        uint256 payoutAmount,
        uint256 receivedAmount,
        uint256 finalMultiplierWad
    );
    event MarketRoundSharedOddsSettled(
        bytes32 indexed marketId,
        uint256 indexed roundId,
        Direction winningSide,
        uint256 winningPoolUsd,
        uint256 totalPoolUsd,
        uint256 finalMultiplierWad
    );
    event MarketRoundRevenueDistributed(
        bytes32 indexed marketId,
        uint256 indexed roundId,
        address indexed asset,
        uint256 edgeAmount,
        uint256 lpEdgeAmount,
        address teamRecipient,
        uint256 teamRevenueAmount,
        address treasuryRecipient,
        uint256 treasuryRevenueAmount
    );
    event MarketRoundSettled(
        bytes32 indexed marketId,
        uint256 indexed roundId,
        Direction winningSide,
        uint256 openPriceWad,
        uint256 finalPriceWad,
        SettlementMode settlementMode,
        uint256 settledAt
    );
    event MarketRoundExpired(
        bytes32 indexed marketId,
        uint256 indexed roundId,
        uint256 expiredAt,
        uint256 refundDelay,
        uint256 nativeRefundAmount,
        uint256 usdcRefundAmount
    );
    event MarketJudgmentResolved(
        bytes32 indexed marketId,
        address indexed owner,
        uint256 indexed judgmentId,
        uint256 roundId,
        EntryAsset payoutAsset,
        uint256 payoutAmount,
        uint256 finalMultiplierWad,
        JudgmentResult result
    );

    error InvalidAddress();
    error InvalidAmount();
    error InvalidAsset();
    error InvalidControllerBinding();
    error InvalidMarket();
    error InvalidRound();
    error InvalidJudgment();
    error InvalidRoundEconomics();
    error TooManyMarkets();
    error RoundAlreadyStarted();
    error RoundLockedAlready();
    error RoundNotLocked();
    error RoundSettledAlready();
    error EntryLocked();
    error RoundTooEarlyToLock();
    error RoundTooEarlyToSettle();
    error RoundNotSettled();
    error RoundNotExpired();
    error NotJudgmentOwner();
    error JudgmentAlreadyResolved();
    error OraclePriceInvalid();
    error ActiveMarketRounds();
    error CapacityStressed();
    error RoundStartOutsidePlayWindow();
    error RoundStartSlotAlreadyUsed();
    error InvalidAuthorization();

    constructor(
        address nativeController_,
        address usdcController_,
        address admin_,
        address operator_
    ) {
        if (
            nativeController_ == address(0) ||
            usdcController_ == address(0) ||
            admin_ == address(0) ||
            operator_ == address(0)
        ) {
            revert InvalidAddress();
        }
        if (nativeController_ == usdcController_) {
            revert InvalidControllerBinding();
        }

        nativeController = ISharedJudgmentLiquidityController(
            nativeController_
        );
        usdcController = ISharedJudgmentLiquidityController(usdcController_);
        if (
            nativeController.asset() != NATIVE_ASSET ||
            usdcController.asset() == NATIVE_ASSET
        ) {
            revert InvalidAsset();
        }

        nativeVault = ISharedPoolVault(nativeController.poolVault());
        usdcVault = ISharedPoolVault(usdcController.poolVault());
        if (
            address(nativeVault) == address(0) ||
            address(usdcVault) == address(0) ||
            address(nativeVault) == address(usdcVault) ||
            nativeVault.asset() != NATIVE_ASSET ||
            usdcVault.asset() != usdcController.asset()
        ) {
            revert InvalidControllerBinding();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(OPERATOR_ROLE, operator_);
    }

    function isSharedJudgmentLiquidityController(
        address controller
    ) external view returns (bool) {
        return
            controller != address(0) &&
            (controller == address(nativeController) ||
                controller == address(usdcController));
    }

    function marketCount() external view returns (uint256) {
        return marketIds.length;
    }

    function controllerBindingsReady() external view returns (bool) {
        return
            nativeVault.businessController() == address(nativeController) &&
            usdcVault.businessController() == address(usdcController);
    }

    function configureMarket(
        bytes32 marketId,
        string calldata marketKey,
        address oracleAdapter,
        bool enabled,
        JudgeEconomics calldata economics
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (marketId == bytes32(0) || bytes(marketKey).length == 0) {
            revert InvalidMarket();
        }
        if (oracleAdapter == address(0) || oracleAdapter.code.length == 0) {
            revert InvalidAddress();
        }
        _validateRoundEconomics(economics);
        bool existingMarket = markets[marketId].oracleAdapter != address(0);
        if (
            existingMarket &&
            (nativeController.marketOpenRoundCount(marketId) != 0 ||
                usdcController.marketOpenRoundCount(marketId) != 0)
        ) {
            revert ActiveMarketRounds();
        }

        if (!existingMarket) {
            if (marketIds.length >= MAX_MARKETS) {
                revert TooManyMarkets();
            }
            marketIds.push(marketId);
        }

        markets[marketId] = MarketConfig({
            enabled: enabled,
            oracleAdapter: oracleAdapter,
            economics: economics
        });

        emit MarketConfigured(
            marketId,
            marketKey,
            oracleAdapter,
            _economicsHash(economics),
            enabled
        );
    }

    function configureMarketSeed(
        bytes32 marketId,
        uint16 seedBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (
            marketId == bytes32(0) ||
            markets[marketId].oracleAdapter == address(0) ||
            seedBps > MAX_SEED_BPS
        ) {
            revert InvalidMarket();
        }
        if (
            nativeController.marketOpenRoundCount(marketId) != 0 ||
            usdcController.marketOpenRoundCount(marketId) != 0
        ) {
            revert ActiveMarketRounds();
        }
        marketSeedBps[marketId] = seedBps;
        // Preserve the historical event field for existing consumers. Shared
        // facets expose SHARED_SEED_FLOOR_USD_WAD for the v2 floor semantics.
        emit MarketSeedConfigured(marketId, seedBps, MAX_SEED_USD_WAD);
    }

    function startMarketRound(
        bytes32 marketId,
        uint256 roundId,
        bytes[] calldata priceUpdateData
    ) external payable nonReentrant onlyRole(OPERATOR_ROLE) {
        _beforeStartMarketRound();
        if (roundId == 0) {
            revert InvalidRound();
        }

        MarketConfig storage market = _marketReady(marketId);
        MarketRound storage round = rounds[marketId][roundId];
        if (round.started) {
            revert RoundAlreadyStarted();
        }

        uint256 startTime_ = _alignedRoundStart(block.timestamp);
        if (roundIdByMarketStartTime[marketId][startTime_] != 0) {
            revert RoundStartSlotAlreadyUsed();
        }
        roundIdByMarketStartTime[marketId][startTime_] = roundId;

        (
            uint256 startMarketPrice,
            uint256 nativeUsdReference
        ) = IJudgmentOracleAdapter(market.oracleAdapter).getRoundStartPrices{
                value: msg.value
            }(priceUpdateData);
        if (startMarketPrice == 0 || nativeUsdReference == 0) {
            revert OraclePriceInvalid();
        }

        uint256 nativeCapacity = nativeController.openMarketRoundCapacity(
            marketId,
            roundId
        );
        uint256 usdcCapacity = usdcController.openMarketRoundCapacity(
            marketId,
            roundId
        );

        round.marketId = marketId;
        round.roundId = roundId;
        round.startTime = startTime_;
        round.lockTime = startTime_ + ENTRY_LOCK_OFFSET;
        round.settleTime = startTime_ + ROUND_DURATION;
        round.nativeUsdReference = nativeUsdReference;
        round.startMarketPriceWad = startMarketPrice;
        round.started = true;
        round.nativeCapacity = nativeCapacity;
        round.usdcCapacity = usdcCapacity;
        round.tieThresholdBp = market.economics.tieThresholdBp;
        round.upDownPayoutRateBps = market.economics.upDownPayoutRateBps;
        round.tiePayoutRateBps = market.economics.tiePayoutRateBps;
        round.startUpPoolBps = market.economics.startUpPoolBps;
        round.startDownPoolBps = market.economics.startDownPoolBps;
        round.startTiePoolBps = market.economics.startTiePoolBps;
        uint16 seedBps = marketSeedBps[marketId];
        (
            uint256 nativeSeedUsd,
            uint256 usdcSeedUsd
        ) = _applyVirtualSeed(round, seedBps);

        emit MarketRoundStarted(
            marketId,
            roundId,
            round.startTime,
            round.lockTime,
            round.settleTime,
            nativeUsdReference,
            round.tieThresholdBp,
            round.upDownPayoutRateBps,
            round.tiePayoutRateBps,
            round.startUpPoolBps,
            round.startDownPoolBps,
            round.startTiePoolBps,
            nativeCapacity,
            usdcCapacity
        );
        emit MarketRoundSeeded(
            marketId,
            roundId,
            seedBps,
            nativeSeedUsd,
            usdcSeedUsd,
            SHARED_SEED_FLOOR_USD_WAD
        );
    }

    function commitJudgment(
        bytes32 marketId,
        uint256 roundId,
        EntryAsset entryAsset,
        Direction direction,
        uint256 amount
    ) external payable nonReentrant returns (uint256 judgmentId) {
        UsdcAuthorization memory emptyAuthorization;
        judgmentId = _commitJudgment(
            marketId,
            roundId,
            entryAsset,
            direction,
            amount,
            false,
            emptyAuthorization
        );
    }

    function commitJudgmentUsdcWithAuthorization(
        bytes32 marketId,
        uint256 roundId,
        Direction direction,
        uint256 amount,
        UsdcAuthorization calldata authorization
    ) external nonReentrant returns (uint256 judgmentId) {
        if (authorization.validBefore <= block.timestamp) {
            revert InvalidAuthorization();
        }
        judgmentId = _commitJudgment(
            marketId,
            roundId,
            EntryAsset.USDC,
            direction,
            amount,
            true,
            authorization
        );
    }

    function commitAuthorizationNonce(
        address owner,
        bytes32 marketId,
        uint256 roundId,
        Direction direction,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonceSalt
    ) external view returns (bytes32) {
        return
            usdcController.commitAuthorizationNonce(
                owner,
                marketId,
                roundId,
                uint8(direction),
                amount,
                validAfter,
                validBefore,
                nonceSalt
            );
    }

    function _commitJudgment(
        bytes32 marketId,
        uint256 roundId,
        EntryAsset entryAsset,
        Direction direction,
        uint256 amount,
        bool useAuthorization,
        UsdcAuthorization memory authorization
    ) private returns (uint256 judgmentId) {
        _marketReady(marketId);
        MarketRound storage round = _openRound(marketId, roundId);
        if (round.locked || block.timestamp >= round.lockTime) {
            revert EntryLocked();
        }
        if (amount == 0) {
            revert InvalidAmount();
        }

        uint256 notionalUsd;
        if (entryAsset == EntryAsset.NATIVE) {
            if (amount < MIN_NATIVE_ENTRY_AMOUNT || msg.value != amount) {
                revert InvalidAmount();
            }
            notionalUsd = _nativeToUsd(amount, round.nativeUsdReference);
        } else {
            if (amount < MIN_USDC_ENTRY_AMOUNT || msg.value != 0) {
                revert InvalidAmount();
            }
            notionalUsd = _usdcToUsd(amount);
        }
        if (notionalUsd == 0) {
            revert InvalidAmount();
        }

        _addPool(round, entryAsset, direction, amount, notionalUsd);
        uint256 maxPayoutAmount = _assetCapacity(round, entryAsset);
        if (maxPayoutAmount == 0) {
            revert InvalidAmount();
        }
        uint256 nativeReserveDelta = _aggregateReserveDelta(
            round,
            EntryAsset.NATIVE
        );
        uint256 usdcReserveDelta = _aggregateReserveDelta(
            round,
            EntryAsset.USDC
        );

        judgmentId = nextJudgmentId;
        nextJudgmentId += 1;
        judgments[judgmentId] = MarketJudgment({
            marketId: marketId,
            roundId: roundId,
            user: msg.sender,
            entryAsset: entryAsset,
            direction: direction,
            resolved: false,
            amountAsset: amount
        });

        if (entryAsset == EntryAsset.NATIVE) {
            nativeController.commitMarketJudgmentNative{value: amount}(
                marketId,
                roundId,
                judgmentId,
                msg.sender,
                amount,
                maxPayoutAmount
            );
        } else {
            if (useAuthorization) {
                usdcController.commitMarketJudgmentWithAuthorization(
                    marketId,
                    roundId,
                    judgmentId,
                    msg.sender,
                    uint8(direction),
                    amount,
                    maxPayoutAmount,
                    authorization.validAfter,
                    authorization.validBefore,
                    authorization.nonceSalt,
                    authorization.v,
                    authorization.r,
                    authorization.s
                );
            } else {
                usdcController.commitMarketJudgmentFromWallet(
                    marketId,
                    roundId,
                    judgmentId,
                    msg.sender,
                    amount,
                    maxPayoutAmount
                );
            }
        }

        _increaseAggregateReserve(
            marketId,
            roundId,
            round,
            EntryAsset.NATIVE,
            nativeReserveDelta
        );
        _increaseAggregateReserve(
            marketId,
            roundId,
            round,
            EntryAsset.USDC,
            usdcReserveDelta
        );

        emit MarketJudgmentCommitted(
            marketId,
            roundId,
            msg.sender,
            judgmentId,
            entryAsset,
            direction,
            amount,
            notionalUsd,
            maxPayoutAmount
        );
    }

    function lockMarketRound(
        bytes32 marketId,
        uint256 roundId,
        bytes[] calldata priceUpdateData
    ) external payable nonReentrant {
        MarketConfig storage market = _marketReady(marketId);
        MarketRound storage round = _openRound(marketId, roundId);
        if (round.locked) {
            revert RoundLockedAlready();
        }
        if (round.aggregateSettled) {
            revert RoundSettledAlready();
        }
        if (block.timestamp < round.lockTime) {
            revert RoundTooEarlyToLock();
        }

        IJudgmentOracleAdapter.OracleSnapshot memory snapshot = IJudgmentOracleAdapter(
                market.oracleAdapter
            ).getRoundSettlementPriceAt{value: msg.value}(
                priceUpdateData,
                _oracleWindowStart(round.lockTime),
                _oracleWindowEnd(round.lockTime)
            );
        if (snapshot.marketPriceWad == 0) {
            revert OraclePriceInvalid();
        }

        round.openTwap = snapshot.marketPriceWad;
        round.locked = true;
        _emitOracleSnapshot(marketId, roundId, false, snapshot);
        emit MarketRoundLocked(
            marketId,
            roundId,
            block.timestamp,
            snapshot.marketPriceWad,
            round.upPoolUsd,
            round.downPoolUsd,
            round.tiePoolUsd
        );
    }

    function settleMarketRound(
        bytes32 marketId,
        uint256 roundId,
        bytes[] calldata priceUpdateData
    ) external payable nonReentrant {
        MarketConfig storage market = _marketReady(marketId);
        MarketRound storage round = _openRound(marketId, roundId);
        if (!round.locked) {
            revert RoundNotLocked();
        }
        if (round.aggregateSettled) {
            revert RoundSettledAlready();
        }
        if (block.timestamp < round.settleTime) {
            revert RoundTooEarlyToSettle();
        }
        // Keep the keeper's normal path; anyone can complete a delayed round
        // using the same canonical oracle evidence, never a caller-chosen result.
        if (block.timestamp < round.settleTime + PUBLIC_SETTLEMENT_GRACE) {
            _checkRole(OPERATOR_ROLE);
        }

        IJudgmentOracleAdapter.OracleSnapshot memory snapshot = IJudgmentOracleAdapter(
                market.oracleAdapter
            ).getRoundSettlementPriceAt{value: msg.value}(
                priceUpdateData,
                _oracleWindowStart(round.settleTime),
                _oracleWindowEnd(round.settleTime)
            );
        if (snapshot.marketPriceWad == 0) {
            revert OraclePriceInvalid();
        }

        _emitOracleSnapshot(marketId, roundId, true, snapshot);
        _settleRound(marketId, roundId, round, snapshot.marketPriceWad);
    }

    function expireMarketRoundForRefund(
        bytes32 marketId,
        uint256 roundId
    ) external nonReentrant onlyRole(OPERATOR_ROLE) {
        MarketRound storage round = _refundCandidate(marketId, roundId);
        if (round.locked) {
            revert RoundLockedAlready();
        }
        if (!_roundCanExpire(round, EMERGENCY_REFUND_DELAY)) {
            revert RoundNotExpired();
        }
        _expireRoundForRefund(marketId, roundId, round, EMERGENCY_REFUND_DELAY);
    }

    function emergencyExpireLockedMarketRoundForRefund(
        bytes32 marketId,
        uint256 roundId
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        MarketRound storage round = _refundCandidate(marketId, roundId);
        if (!round.locked) {
            revert RoundNotLocked();
        }
        if (!_roundCanExpire(round, LOCKED_ROUND_EMERGENCY_REFUND_DELAY)) {
            revert RoundNotExpired();
        }
        _expireRoundForRefund(
            marketId,
            roundId,
            round,
            LOCKED_ROUND_EMERGENCY_REFUND_DELAY
        );
    }

    function claimMarketPayout(uint256 judgmentId) external nonReentrant {
        _resolveOwnedJudgment(judgmentId, address(0), false);
    }

    function claimMarketPayoutAndWithdraw(
        uint256 judgmentId,
        address receiver
    ) external nonReentrant {
        if (receiver == address(0)) {
            revert InvalidAddress();
        }
        _resolveOwnedJudgment(judgmentId, receiver, true);
    }

    function _settleRound(
        bytes32 marketId,
        uint256 roundId,
        MarketRound storage round,
        uint256 finalTwap
    ) private {
        round.finalTwap = finalTwap;
        round.aggregateSettled = true;
        Direction winningSide = _winningSide(
            round.openTwap,
            finalTwap,
            round.tieThresholdBp
        );
        round.winningSide = winningSide;

        AssetSettlement memory nativeSettlement = _assetSettlement(
            round,
            EntryAsset.NATIVE,
            winningSide
        );
        AssetSettlement memory usdcSettlement = _assetSettlement(
            round,
            EntryAsset.USDC,
            winningSide
        );

        round.nativeFinalMultiplierWad = nativeSettlement.actualMultiplierWad;
        round.usdcFinalMultiplierWad = usdcSettlement.actualMultiplierWad;
        round.nativeSettledPayoutAmount = nativeSettlement.actualPayoutAmount;
        round.usdcSettledPayoutAmount = usdcSettlement.actualPayoutAmount;

        (
            uint256 nativeLpEdge,
            uint256 nativeTeamRevenue,
            uint256 nativeTreasuryRevenue
        ) = nativeController.settleMarketRoundPayoutPool(
            marketId,
            roundId,
            nativeSettlement.actualPayoutAmount,
            nativeSettlement.edgeAmount
        );
        (
            uint256 usdcLpEdge,
            uint256 usdcTeamRevenue,
            uint256 usdcTreasuryRevenue
        ) = usdcController.settleMarketRoundPayoutPool(
            marketId,
            roundId,
            usdcSettlement.actualPayoutAmount,
            usdcSettlement.edgeAmount
        );

        emit MarketRoundAssetSettled(
            marketId,
            roundId,
            NATIVE_ASSET,
            nativeSettlement.winningPoolUsd,
            nativeSettlement.totalPoolUsd,
            nativeSettlement.actualPayoutAmount,
            _assetTotalAmount(round, EntryAsset.NATIVE),
            nativeSettlement.actualMultiplierWad
        );
        emit MarketRoundRevenueDistributed(
            marketId,
            roundId,
            NATIVE_ASSET,
            nativeSettlement.edgeAmount,
            nativeLpEdge,
            nativeController.teamRevenueRecipient(),
            nativeTeamRevenue,
            nativeController.treasuryRevenueRecipient(),
            nativeTreasuryRevenue
        );
        emit MarketRoundAssetSettled(
            marketId,
            roundId,
            usdcController.asset(),
            usdcSettlement.winningPoolUsd,
            usdcSettlement.totalPoolUsd,
            usdcSettlement.actualPayoutAmount,
            _assetTotalAmount(round, EntryAsset.USDC),
            usdcSettlement.actualMultiplierWad
        );
        emit MarketRoundRevenueDistributed(
            marketId,
            roundId,
            usdcController.asset(),
            usdcSettlement.edgeAmount,
            usdcLpEdge,
            usdcController.teamRevenueRecipient(),
            usdcTeamRevenue,
            usdcController.treasuryRevenueRecipient(),
            usdcTreasuryRevenue
        );
        if (_usesSharedAssetOdds()) {
            emit MarketRoundSharedOddsSettled(
                marketId,
                roundId,
                winningSide,
                nativeSettlement.winningPoolUsd,
                nativeSettlement.totalPoolUsd,
                nativeSettlement.actualMultiplierWad
            );
        }
        emit MarketRoundSettled(
            marketId,
            roundId,
            winningSide,
            round.openTwap,
            finalTwap,
            SettlementMode.Lazy,
            block.timestamp
        );
    }

    function _expireRoundForRefund(
        bytes32 marketId,
        uint256 roundId,
        MarketRound storage round,
        uint256 refundDelay
    ) private {
        if (round.normalPayoutAllocationStarted) {
            revert JudgmentAlreadyResolved();
        }

        uint256 nativeRefundAmount = _assetTotalAmount(round, EntryAsset.NATIVE);
        uint256 usdcRefundAmount = _assetTotalAmount(round, EntryAsset.USDC);

        round.expired = true;
        round.aggregateSettled = true;
        round.winningSide = Direction.Tie;
        round.nativeFinalMultiplierWad = WAD;
        round.usdcFinalMultiplierWad = WAD;
        round.nativeSettledPayoutAmount = nativeRefundAmount;
        round.usdcSettledPayoutAmount = usdcRefundAmount;

        nativeController.refundMarketRoundPayoutPool(marketId, roundId);
        usdcController.refundMarketRoundPayoutPool(marketId, roundId);

        emit MarketRoundExpired(
            marketId,
            roundId,
            block.timestamp,
            refundDelay,
            nativeRefundAmount,
            usdcRefundAmount
        );
        emit MarketRoundSettled(
            marketId,
            roundId,
            Direction.Tie,
            round.openTwap,
            round.finalTwap,
            SettlementMode.ExpiredRefund,
            block.timestamp
        );
    }

    function _resolveOwnedJudgment(
        uint256 judgmentId,
        address receiver,
        bool withdraw
    ) internal {
        MarketJudgment storage judgment = judgments[judgmentId];
        if (judgment.user != msg.sender) {
            revert NotJudgmentOwner();
        }
        _resolveJudgment(judgmentId, judgment, receiver, withdraw);
    }

    function _materializeJudgmentPayout(
        uint256 judgmentId,
        bool maintenanceMaterializer
    ) internal {
        MarketJudgment storage judgment = judgments[judgmentId];
        if (judgment.user == address(0)) {
            revert InvalidJudgment();
        }
        if (!maintenanceMaterializer && judgment.user != msg.sender) {
            revert NotJudgmentOwner();
        }
        if (judgment.resolved) {
            return;
        }

        _resolveJudgment(judgmentId, judgment, address(0), false);
    }

    function _resolveJudgment(
        uint256 judgmentId,
        MarketJudgment storage judgment,
        address receiver,
        bool withdraw
    ) private {
        if (judgment.resolved) {
            revert JudgmentAlreadyResolved();
        }

        MarketRound storage round = rounds[judgment.marketId][judgment.roundId];
        if (!round.aggregateSettled) {
            revert RoundNotSettled();
        }

        uint256 payoutAmount;
        uint256 multiplierWad;
        JudgmentResult result;
        if (round.expired) {
            multiplierWad = WAD;
            payoutAmount = _consumeRefundPayout(
                round,
                judgment.entryAsset,
                judgment.amountAsset
            );
            result = JudgmentResult.Refunded;
        } else {
            multiplierWad = _finalMultiplierFor(round, judgment.entryAsset);
            bool confirmed = judgment.direction == round.winningSide &&
                multiplierWad != 0;
            payoutAmount = confirmed
                ? _consumeFinalPayout(
                    round,
                    judgment.entryAsset,
                    judgment.amountAsset
                )
                : 0;
            result = confirmed
                ? JudgmentResult.Confirmed
                : JudgmentResult.Refuted;
        }

        judgment.resolved = true;
        round.normalPayoutAllocationStarted = true;
        ISharedJudgmentLiquidityController controller = _controllerFor(
            judgment.entryAsset
        );
        if (withdraw) {
            controller.allocateAndClaimSettledJudgmentPayout(
                judgmentId,
                payoutAmount,
                receiver
            );
        } else {
            controller.allocateSettledJudgmentPayout(
                judgmentId,
                payoutAmount
            );
        }

        emit MarketJudgmentResolved(
            judgment.marketId,
            judgment.user,
            judgmentId,
            judgment.roundId,
            judgment.entryAsset,
            payoutAmount,
            multiplierWad,
            result
        );
    }

    function _openRound(
        bytes32 marketId,
        uint256 roundId
    ) private view returns (MarketRound storage round) {
        round = rounds[marketId][roundId];
        if (!round.started || round.marketId != marketId) {
            revert InvalidRound();
        }
    }

    function _refundCandidate(
        bytes32 marketId,
        uint256 roundId
    ) private view returns (MarketRound storage round) {
        _marketReady(marketId);
        round = _openRound(marketId, roundId);
        if (round.aggregateSettled) {
            revert RoundSettledAlready();
        }
    }

    function _marketReady(
        bytes32 marketId
    ) private view returns (MarketConfig storage market) {
        if (marketId == bytes32(0)) {
            revert InvalidMarket();
        }
        market = markets[marketId];
        if (!market.enabled || market.oracleAdapter == address(0)) {
            revert InvalidMarket();
        }
    }

    function _requireNoCapacityStress() private view {
        for (uint256 i = 0; i < marketIds.length; i++) {
            bytes32 marketId = marketIds[i];
            if (
                markets[marketId].enabled &&
                (nativeController.capacityStressed(marketId) ||
                    usdcController.capacityStressed(marketId))
            ) {
                revert CapacityStressed();
            }
        }
    }

    function _applyVirtualSeed(
        MarketRound storage round,
        uint16 seedBps
    ) private returns (uint256 nativeSeedUsd, uint256 usdcSeedUsd) {
        if (seedBps == 0) return (0, 0);

        if (_usesSharedAssetOdds()) {
            uint256 nativeTvlUsd = _nativeToUsd(
                nativeVault.totalAssets(),
                round.nativeUsdReference
            );
            uint256 usdcTvlUsd = _usdcToUsd(usdcVault.totalAssets());
            uint256 combinedTvlUsd = nativeTvlUsd + usdcTvlUsd;
            uint256 sharedSeedUsd = Math.max(
                Math.mulDiv(
                    combinedTvlUsd,
                    seedBps,
                    BPS_DENOMINATOR
                ),
                SHARED_SEED_FLOOR_USD_WAD
            );
            // These fields attribute one shared-odds seed by the round-start
            // TVL inputs. They do not reserve either Vault or create a
            // Judgment/claimable payout; only their sum has economic meaning.
            nativeSeedUsd = combinedTvlUsd == 0
                ? sharedSeedUsd / 2
                : Math.mulDiv(sharedSeedUsd, nativeTvlUsd, combinedTvlUsd);
            usdcSeedUsd = sharedSeedUsd - nativeSeedUsd;
        } else {
            uint256 nativeSeedCandidate = Math.mulDiv(
                _nativeToUsd(
                    nativeVault.totalAssets(),
                    round.nativeUsdReference
                ),
                seedBps,
                BPS_DENOMINATOR
            );
            uint256 usdcSeedCandidate = Math.mulDiv(
                _usdcToUsd(usdcVault.totalAssets()),
                seedBps,
                BPS_DENOMINATOR
            );
            nativeSeedUsd = Math.min(
                nativeSeedCandidate,
                MAX_SEED_USD_WAD
            );
            usdcSeedUsd = Math.min(usdcSeedCandidate, MAX_SEED_USD_WAD);
        }

        (
            uint256 nativeUp,
            uint256 nativeDown,
            uint256 nativeTie
        ) = _seedSplit(round, nativeSeedUsd);
        (
            uint256 usdcUp,
            uint256 usdcDown,
            uint256 usdcTie
        ) = _seedSplit(round, usdcSeedUsd);

        round.nativeUpPoolUsd += nativeUp;
        round.nativeDownPoolUsd += nativeDown;
        round.nativeTiePoolUsd += nativeTie;
        round.usdcUpPoolUsd += usdcUp;
        round.usdcDownPoolUsd += usdcDown;
        round.usdcTiePoolUsd += usdcTie;
        round.upPoolUsd += nativeUp + usdcUp;
        round.downPoolUsd += nativeDown + usdcDown;
        round.tiePoolUsd += nativeTie + usdcTie;
    }

    function _seedSplit(
        MarketRound storage round,
        uint256 seedUsd
    ) private view returns (uint256 up, uint256 down, uint256 tie) {
        up = (seedUsd * round.startUpPoolBps) / BPS_DENOMINATOR;
        tie = (seedUsd * round.startTiePoolBps) / BPS_DENOMINATOR;
        down = seedUsd - up - tie;
    }

    /// @dev Direct v1 leaves this hook empty. The Diamond facet overrides it
    /// and reads the immutable-root start freeze flag.
    function _beforeStartMarketRound() internal view virtual {}

    function _usesSharedAssetOdds() internal pure virtual returns (bool) {
        return false;
    }

    function _addPool(
        MarketRound storage round,
        EntryAsset entryAsset,
        Direction direction,
        uint256 amountAsset,
        uint256 notionalUsd
    ) private {
        if (direction == Direction.Up) {
            round.upPoolUsd += notionalUsd;
            if (entryAsset == EntryAsset.NATIVE) {
                round.nativeUpPoolUsd += notionalUsd;
                round.nativeUpAmount += amountAsset;
            } else {
                round.usdcUpPoolUsd += notionalUsd;
                round.usdcUpAmount += amountAsset;
            }
        } else if (direction == Direction.Down) {
            round.downPoolUsd += notionalUsd;
            if (entryAsset == EntryAsset.NATIVE) {
                round.nativeDownPoolUsd += notionalUsd;
                round.nativeDownAmount += amountAsset;
            } else {
                round.usdcDownPoolUsd += notionalUsd;
                round.usdcDownAmount += amountAsset;
            }
        } else {
            round.tiePoolUsd += notionalUsd;
            if (entryAsset == EntryAsset.NATIVE) {
                round.nativeTiePoolUsd += notionalUsd;
                round.nativeTieAmount += amountAsset;
            } else {
                round.usdcTiePoolUsd += notionalUsd;
                round.usdcTieAmount += amountAsset;
            }
        }
    }

    function _increaseAggregateReserve(
        bytes32 marketId,
        uint256 roundId,
        MarketRound storage round,
        EntryAsset entryAsset,
        uint256 reserveDelta
    ) private {
        if (reserveDelta == 0) {
            return;
        }
        if (entryAsset == EntryAsset.NATIVE) {
            round.nativeReservedPayoutAmount += reserveDelta;
            nativeController.increaseMarketRoundReservedPayout(
                marketId,
                roundId,
                reserveDelta
            );
        } else {
            round.usdcReservedPayoutAmount += reserveDelta;
            usdcController.increaseMarketRoundReservedPayout(
                marketId,
                roundId,
                reserveDelta
            );
        }
    }

    function _aggregateReserveDelta(
        MarketRound storage round,
        EntryAsset entryAsset
    ) private view returns (uint256) {
        uint256 requiredReserve = _assetMaxSettlementOutflow(
            round,
            entryAsset,
            _controllerFor(entryAsset).protocolRevenueBps()
        );
        uint256 currentReserve = entryAsset == EntryAsset.NATIVE
            ? round.nativeReservedPayoutAmount
            : round.usdcReservedPayoutAmount;
        return requiredReserve > currentReserve
            ? requiredReserve - currentReserve
            : 0;
    }

    function _assetMaxSettlementOutflow(
        MarketRound storage round,
        EntryAsset entryAsset,
        uint16 protocolRevenueBps
    ) private view returns (uint256) {
        uint256 upPayout = _assetSettlementOutflow(
            round,
            entryAsset,
            Direction.Up,
            protocolRevenueBps
        );
        uint256 downPayout = _assetSettlementOutflow(
            round,
            entryAsset,
            Direction.Down,
            protocolRevenueBps
        );
        uint256 tiePayout = _assetSettlementOutflow(
            round,
            entryAsset,
            Direction.Tie,
            protocolRevenueBps
        );
        uint256 maxPayout = upPayout > downPayout ? upPayout : downPayout;
        return maxPayout > tiePayout ? maxPayout : tiePayout;
    }

    function _assetSettlementOutflow(
        MarketRound storage round,
        EntryAsset entryAsset,
        Direction direction,
        uint16 protocolRevenueBps
    ) private view returns (uint256) {
        uint256 actualPayout = _assetAggregatePayout(
            round,
            entryAsset,
            direction
        );
        uint256 theoreticalPayout = _assetAggregatePayoutAtRate(
            round,
            entryAsset,
            direction,
            uint16(BPS_DENOMINATOR)
        );
        uint256 edgeAmount = theoreticalPayout - actualPayout;
        return
            actualPayout +
            Math.mulDiv(edgeAmount, protocolRevenueBps, BPS_DENOMINATOR);
    }

    function _assetAggregatePayout(
        MarketRound storage round,
        EntryAsset entryAsset,
        Direction direction
    ) private view returns (uint256) {
        return
            _assetAggregatePayoutAtRate(
                round,
                entryAsset,
                direction,
                _payoutRateBpsFor(round, direction)
            );
    }

    function _assetAggregatePayoutAtRate(
        MarketRound storage round,
        EntryAsset entryAsset,
        Direction direction,
        uint16 payoutRateBps
    ) private view returns (uint256) {
        uint256 sidePoolUsd = _usesSharedAssetOdds()
            ? _sharedPoolFor(round, direction)
            : _assetPoolFor(round, entryAsset, direction);
        if (sidePoolUsd == 0) {
            return 0;
        }
        uint256 multiplierWad = _finalMultiplierWad(
            _usesSharedAssetOdds()
                ? _sharedTotalPoolUsd(round)
                : _assetTotalPoolUsd(round, entryAsset),
            payoutRateBps,
            sidePoolUsd
        );
        return
            (_assetWinningAmount(round, entryAsset, direction) *
                multiplierWad) / WAD;
    }

    function _assetSettlement(
        MarketRound storage round,
        EntryAsset asset_,
        Direction winningSide
    )
        private
        view
        returns (AssetSettlement memory settlement)
    {
        settlement.winningPoolUsd = _usesSharedAssetOdds()
            ? _sharedPoolFor(round, winningSide)
            : _assetPoolFor(round, asset_, winningSide);
        settlement.totalPoolUsd = _usesSharedAssetOdds()
            ? _sharedTotalPoolUsd(round)
            : _assetTotalPoolUsd(round, asset_);
        if (settlement.winningPoolUsd == 0) {
            return settlement;
        }
        settlement.actualMultiplierWad = _finalMultiplierWad(
            settlement.totalPoolUsd,
            _payoutRateBpsFor(round, winningSide),
            settlement.winningPoolUsd
        );
        uint256 theoreticalMultiplierWad = _finalMultiplierWad(
            settlement.totalPoolUsd,
            uint16(BPS_DENOMINATOR),
            settlement.winningPoolUsd
        );
        uint256 winningAmount = _assetWinningAmount(
            round,
            asset_,
            winningSide
        );
        settlement.actualPayoutAmount = Math.mulDiv(
            winningAmount,
            settlement.actualMultiplierWad,
            WAD
        );
        uint256 theoreticalPayoutAmount = Math.mulDiv(
            winningAmount,
            theoreticalMultiplierWad,
            WAD
        );
        settlement.edgeAmount =
            theoreticalPayoutAmount -
            settlement.actualPayoutAmount;
    }

    function _consumeFinalPayout(
        MarketRound storage round,
        EntryAsset entryAsset,
        uint256 amountAsset
    ) private returns (uint256 payoutAmount) {
        uint256 totalWinningAmount = _assetWinningAmount(
            round,
            entryAsset,
            round.winningSide
        );
        if (totalWinningAmount == 0) {
            revert InvalidRound();
        }

        if (entryAsset == EntryAsset.NATIVE) {
            uint256 newResolved = round.nativeResolvedWinningAmount +
                amountAsset;
            if (newResolved > totalWinningAmount) {
                revert InvalidRound();
            }
            uint256 cumulativePayout = newResolved.mulDiv(
                round.nativeSettledPayoutAmount,
                totalWinningAmount
            );
            payoutAmount =
                cumulativePayout -
                round.nativeAllocatedPayoutAmount;
            round.nativeResolvedWinningAmount = newResolved;
            round.nativeAllocatedPayoutAmount = cumulativePayout;
            return payoutAmount;
        }

        uint256 usdcNewResolved = round.usdcResolvedWinningAmount + amountAsset;
        if (usdcNewResolved > totalWinningAmount) {
            revert InvalidRound();
        }
        uint256 usdcCumulativePayout = usdcNewResolved.mulDiv(
            round.usdcSettledPayoutAmount,
            totalWinningAmount
        );
        payoutAmount = usdcCumulativePayout - round.usdcAllocatedPayoutAmount;
        round.usdcResolvedWinningAmount = usdcNewResolved;
        round.usdcAllocatedPayoutAmount = usdcCumulativePayout;
    }

    function _consumeRefundPayout(
        MarketRound storage round,
        EntryAsset entryAsset,
        uint256 amountAsset
    ) private returns (uint256 payoutAmount) {
        payoutAmount = amountAsset;
        if (entryAsset == EntryAsset.NATIVE) {
            uint256 allocated = round.nativeAllocatedPayoutAmount + amountAsset;
            if (allocated > round.nativeSettledPayoutAmount) {
                revert InvalidRound();
            }
            round.nativeAllocatedPayoutAmount = allocated;
            return payoutAmount;
        }

        uint256 usdcAllocated = round.usdcAllocatedPayoutAmount + amountAsset;
        if (usdcAllocated > round.usdcSettledPayoutAmount) {
            revert InvalidRound();
        }
        round.usdcAllocatedPayoutAmount = usdcAllocated;
    }

    function _assetCapacity(
        MarketRound storage round,
        EntryAsset entryAsset
    ) private view returns (uint256) {
        return
            entryAsset == EntryAsset.NATIVE
                ? round.nativeCapacity
                : round.usdcCapacity;
    }

    function _assetPoolFor(
        MarketRound storage round,
        EntryAsset entryAsset,
        Direction direction
    ) private view returns (uint256) {
        if (entryAsset == EntryAsset.NATIVE) {
            if (direction == Direction.Up) return round.nativeUpPoolUsd;
            if (direction == Direction.Down) return round.nativeDownPoolUsd;
            return round.nativeTiePoolUsd;
        }
        if (direction == Direction.Up) return round.usdcUpPoolUsd;
        if (direction == Direction.Down) return round.usdcDownPoolUsd;
        return round.usdcTiePoolUsd;
    }

    function _assetTotalPoolUsd(
        MarketRound storage round,
        EntryAsset entryAsset
    ) private view returns (uint256) {
        if (entryAsset == EntryAsset.NATIVE) {
            return
                round.nativeUpPoolUsd +
                round.nativeDownPoolUsd +
                round.nativeTiePoolUsd;
        }
        return round.usdcUpPoolUsd + round.usdcDownPoolUsd + round.usdcTiePoolUsd;
    }

    function _sharedPoolFor(
        MarketRound storage round,
        Direction direction
    ) private view returns (uint256) {
        if (direction == Direction.Up) return round.upPoolUsd;
        if (direction == Direction.Down) return round.downPoolUsd;
        return round.tiePoolUsd;
    }

    function _sharedTotalPoolUsd(
        MarketRound storage round
    ) private view returns (uint256) {
        return round.upPoolUsd + round.downPoolUsd + round.tiePoolUsd;
    }

    function _assetWinningAmount(
        MarketRound storage round,
        EntryAsset entryAsset,
        Direction direction
    ) private view returns (uint256) {
        if (entryAsset == EntryAsset.NATIVE) {
            if (direction == Direction.Up) return round.nativeUpAmount;
            if (direction == Direction.Down) return round.nativeDownAmount;
            return round.nativeTieAmount;
        }
        if (direction == Direction.Up) return round.usdcUpAmount;
        if (direction == Direction.Down) return round.usdcDownAmount;
        return round.usdcTieAmount;
    }

    function _assetTotalAmount(
        MarketRound storage round,
        EntryAsset entryAsset
    ) private view returns (uint256) {
        if (entryAsset == EntryAsset.NATIVE) {
            return round.nativeUpAmount + round.nativeDownAmount + round.nativeTieAmount;
        }
        return round.usdcUpAmount + round.usdcDownAmount + round.usdcTieAmount;
    }

    function _finalMultiplierFor(
        MarketRound storage round,
        EntryAsset entryAsset
    ) private view returns (uint256) {
        return
            entryAsset == EntryAsset.NATIVE
                ? round.nativeFinalMultiplierWad
                : round.usdcFinalMultiplierWad;
    }

    function _controllerFor(
        EntryAsset entryAsset
    ) private view returns (ISharedJudgmentLiquidityController) {
        return entryAsset == EntryAsset.NATIVE ? nativeController : usdcController;
    }

    function _emitOracleSnapshot(
        bytes32 marketId,
        uint256 roundId,
        bool isClose,
        IJudgmentOracleAdapter.OracleSnapshot memory snapshot
    ) private {
        emit MarketOracleSnapshot(
            marketId,
            roundId,
            isClose,
            snapshot.dataId,
            snapshot.marketPriceId,
            snapshot.ethUsdPriceId,
            snapshot.marketPublishTime,
            snapshot.ethUsdPublishTime,
            snapshot.marketPriceWad,
            snapshot.ethUsdPriceWad
        );
    }

    function _roundCanExpire(
        MarketRound storage round,
        uint256 refundDelay
    ) private view returns (bool) {
        return block.timestamp >= round.settleTime + refundDelay;
    }

    function _oracleWindowStart(uint256 targetTime) private pure returns (uint64) {
        return uint64(targetTime);
    }

    function _oracleWindowEnd(uint256 targetTime) private pure returns (uint64) {
        return uint64(targetTime + ORACLE_PUBLISH_TIME_TOLERANCE);
    }

    function _alignedRoundStart(uint256 timestamp) private view returns (uint256) {
        uint256 scheduledStart = ((timestamp + (ROUND_START_ALIGNMENT / 2)) /
            ROUND_START_ALIGNMENT) * ROUND_START_ALIGNMENT;
        uint256 gateLead = ROUND_START_GATE / 2;
        uint256 gateTrail = ROUND_START_GATE - gateLead;
        if (
            scheduledStart > timestamp + gateLead ||
            timestamp >= scheduledStart + gateTrail
        ) {
            revert RoundStartOutsidePlayWindow();
        }
        if (!_isRoundStartScheduleAllowed(timestamp, scheduledStart)) {
            revert RoundStartOutsidePlayWindow();
        }
        return scheduledStart;
    }

    function _isRoundStartScheduleAllowed(
        uint256 timestamp,
        uint256 scheduledStart
    ) internal view virtual returns (bool) {
        return
            !_isInLpWindow(timestamp) &&
            _canStartInScheduledWindow(scheduledStart);
    }

    function _isInLpWindow(uint256 timestamp) private pure returns (bool) {
        uint256 offset = timestamp % _LP_WINDOW_EPOCH_DURATION;
        uint256 lpWindowStartOffset = _LP_WINDOW_EPOCH_DURATION -
            ROUND_START_ALIGNMENT -
            _LP_WINDOW_DURATION;
        uint256 lpWindowEndOffset = lpWindowStartOffset + _LP_WINDOW_DURATION;
        return offset >= lpWindowStartOffset && offset < lpWindowEndOffset;
    }

    function _canStartInScheduledWindow(
        uint256 scheduledStart
    ) private pure returns (bool) {
        uint256 offset = scheduledStart % _LP_WINDOW_EPOCH_DURATION;
        uint256 lpWindowStartOffset = _LP_WINDOW_EPOCH_DURATION -
            ROUND_START_ALIGNMENT -
            _LP_WINDOW_DURATION;
        uint256 drainStartOffset = lpWindowStartOffset - _LP_DRAIN_DURATION;
        uint256 lpWindowEndOffset = lpWindowStartOffset + _LP_WINDOW_DURATION;
        return offset < drainStartOffset || offset >= lpWindowEndOffset;
    }

    function _winningSide(
        uint256 openTwap,
        uint256 finalTwap,
        uint16 tieThresholdBp
    ) private pure returns (Direction) {
        uint256 threshold = (openTwap * tieThresholdBp) / BPS_DENOMINATOR;
        if (finalTwap >= openTwap) {
            if (finalTwap - openTwap <= threshold) {
                return Direction.Tie;
            }
            return Direction.Up;
        }
        if (openTwap - finalTwap <= threshold) {
            return Direction.Tie;
        }
        return Direction.Down;
    }

    function _finalMultiplierWad(
        uint256 totalPoolUsd,
        uint16 payoutRateBps,
        uint256 winningPoolUsd
    ) private pure returns (uint256) {
        return
            totalPoolUsd.mulDiv(
                uint256(payoutRateBps) * WAD,
                BPS_DENOMINATOR * winningPoolUsd
            );
    }

    function _payoutRateBpsFor(
        MarketRound storage round,
        Direction direction
    ) private view returns (uint16) {
        return
            direction == Direction.Tie
                ? round.tiePayoutRateBps
                : round.upDownPayoutRateBps;
    }

    function _validateRoundEconomics(
        JudgeEconomics memory economics
    ) private pure {
        uint256 startPoolBps = uint256(economics.startUpPoolBps) +
            economics.startDownPoolBps +
            economics.startTiePoolBps;
        if (
            economics.tieThresholdBp == 0 ||
            economics.tieThresholdBp > MAX_TIE_THRESHOLD_BP ||
            startPoolBps != BPS_DENOMINATOR ||
            economics.upDownPayoutRateBps == 0 ||
            economics.upDownPayoutRateBps > BPS_DENOMINATOR ||
            economics.tiePayoutRateBps == 0 ||
            economics.tiePayoutRateBps > BPS_DENOMINATOR
        ) {
            revert InvalidRoundEconomics();
        }
    }

    function _economicsHash(
        JudgeEconomics memory economics
    ) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    economics.tieThresholdBp,
                    economics.upDownPayoutRateBps,
                    economics.tiePayoutRateBps,
                    economics.startUpPoolBps,
                    economics.startDownPoolBps,
                    economics.startTiePoolBps
                )
            );
    }

    function _nativeToUsd(
        uint256 nativeAmount,
        uint256 nativeUsdReference
    ) private pure returns (uint256) {
        return (nativeAmount * nativeUsdReference) / WAD;
    }

    function _usdcToUsd(uint256 usdcAmount) private pure returns (uint256) {
        return usdcAmount * 1e12;
    }
}
