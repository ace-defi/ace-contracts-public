// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/ISharedPoolVault.sol";

interface ISharedJudgeControllerRegistry {
    function isSharedJudgmentLiquidityController(
        address controller
    ) external view returns (bool);
}

contract SharedJudgmentLiquidityController is AccessControl, ReentrancyGuard {
    bytes32 public constant JUDGE_ADMIN_ROLE = keccak256("JUDGE_ADMIN_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_CONFIGURABLE_OPEN_ROUNDS = 20;
    uint8 public constant MAX_CONFIGURED_MARKETS = 20;
    uint16 public constant MAX_PROTOCOL_REVENUE_BPS = 4_000;
    bytes32 public constant PAYOUT_EDGE_MODEL_ID =
        keccak256("ACE_SHARED_V4_PAYOUT_EDGE_TEAM_TREASURY_V1");
    uint256 public constant RISK_WINDOW_DURATION = 1 days;
    uint256 public constant RISK_BUCKET_DURATION = 1 hours;
    // Current partial hour plus the preceding 24 hours. A loss bucket expires
    // only after its full hour is outside the window, which is conservative by
    // at most one hour and never understates the rolling budget.
    uint8 public constant RISK_BUCKET_COUNT = 25;
    address public constant NATIVE_ASSET = address(0);

    ISharedPoolVault public immutable poolVault;
    address public immutable asset;
    uint16 public globalCapacityBps;
    uint16 public defaultMarketCapacityBps;
    uint16 public roundCapacityBps;
    uint16 public maxOpenRounds;

    address public teamRevenueRecipient;
    address public treasuryRevenueRecipient;
    uint16 public teamRevenueBps;
    uint16 public treasuryRevenueBps;

    address public judge;
    uint256 public globalOpenRoundCount;
    uint256 public globalReservedLoss;

    struct MarketConfig {
        bool enabled;
        uint16 capacityBps;
    }

    struct RoundRisk {
        uint256 capacity;
        uint256 reservedObligation;
        uint256 settlementReservedPayout;
        uint256 reservedLoss;
        uint256 escrowedEntryAmount;
        bool opened;
        bool closed;
        bool aggregateSettled;
    }

    struct JudgmentRisk {
        address owner;
        bytes32 marketId;
        uint256 roundId;
        uint256 maxReservedPayout;
        bool settled;
    }

    struct CommitParams {
        bytes32 marketId;
        uint256 roundId;
        uint256 judgmentId;
        address owner;
        uint256 entryAmount;
        uint256 maxPayoutAmount;
    }

    struct RiskBucket {
        uint64 startedAt;
        uint256 realizedLoss;
    }

    struct ActiveRoundKey {
        bytes32 marketId;
        uint256 roundId;
    }

    mapping(bytes32 => MarketConfig) public markets;
    mapping(bytes32 => uint256) public marketOpenRoundCount;
    mapping(bytes32 => uint256) public marketReservedLoss;
    mapping(bytes32 => mapping(uint256 => RoundRisk)) public rounds;
    mapping(uint256 => JudgmentRisk) public judgments;
    bytes32[] private configuredMarketIds;
    mapping(bytes32 => bool) private configuredMarketKnown;
    ActiveRoundKey[] private activeRoundKeys;
    mapping(bytes32 => mapping(uint256 => uint256))
        private activeRoundIndexPlusOne;
    mapping(uint8 => RiskBucket) private riskBuckets;
    uint256 private rollingRealizedLoss;

    event JudgeUpdated(address indexed previousJudge, address indexed newJudge);
    event MaxOpenRoundsUpdated(
        uint16 previousMaxOpenRounds,
        uint16 newMaxOpenRounds
    );
    event RiskLimitsUpdated(
        uint16 previousGlobalCapacityBps,
        uint16 newGlobalCapacityBps,
        uint16 previousDefaultMarketCapacityBps,
        uint16 newDefaultMarketCapacityBps,
        uint16 previousRoundCapacityBps,
        uint16 newRoundCapacityBps
    );
    event RevenueDistributionConfigured(
        address indexed teamRecipient,
        uint16 teamBps,
        address indexed treasuryRecipient,
        uint16 treasuryBps
    );
    event MarketConfigured(
        bytes32 indexed marketId,
        bool enabled,
        uint16 capacityBps
    );
    event MarketRoundCapacityOpened(
        bytes32 indexed marketId,
        uint256 indexed roundId,
        uint256 capacity
    );
    event MarketJudgmentCommitted(
        bytes32 indexed marketId,
        uint256 indexed roundId,
        uint256 indexed judgmentId,
        address owner,
        uint256 entryAmount,
        uint256 maxReservedPayout
    );
    event MarketRoundReservedPayoutIncreased(
        bytes32 indexed marketId,
        uint256 indexed roundId,
        uint256 additionalReservedPayout,
        uint256 reservedObligation,
        uint256 additionalReservedLoss
    );
    event MarketRoundClosed(bytes32 indexed marketId, uint256 indexed roundId);
    event MarketRoundPayoutPoolSettled(
        bytes32 indexed marketId,
        uint256 indexed roundId,
        uint256 payoutAmount,
        uint256 receivedAmount,
        uint256 reservedPayoutAmount
    );
    event MarketRoundRevenueDistributed(
        bytes32 indexed marketId,
        uint256 indexed roundId,
        uint256 edgeAmount,
        uint256 lpEdgeAmount,
        address indexed teamRecipient,
        uint256 teamRevenue,
        address treasuryRecipient,
        uint256 treasuryRevenue
    );
    event MarketRoundPayoutPoolRefunded(
        bytes32 indexed marketId,
        uint256 indexed roundId,
        uint256 refundAmount,
        uint256 reservedPayoutAmount
    );
    event MarketJudgmentPayoutAllocated(
        bytes32 indexed marketId,
        uint256 indexed roundId,
        uint256 indexed judgmentId,
        address owner,
        uint256 payoutAmount
    );
    event SharedRiskReserved(
        bytes32 indexed marketId,
        uint256 additionalReservedLoss,
        uint256 globalReservedLoss,
        uint256 marketReservedLoss
    );
    event SharedRiskReleased(
        bytes32 indexed marketId,
        uint256 releasedReservedLoss,
        uint256 globalReservedLoss,
        uint256 marketReservedLoss
    );
    event SharedRollingRiskSettled(
        uint256 realizedLoss,
        uint256 profitOffset,
        uint256 rollingNetLoss24h,
        uint256 activeReservedLoss,
        uint256 riskUsed24h
    );

    error InvalidAddress();
    error InvalidAmount();
    error InvalidBps();
    error InvalidProtocolRevenue();
    error InvalidMaxOpenRounds();
    error InvalidJudge();
    error InvalidAsset();
    error InvalidMarket();
    error InvalidRound();
    error InvalidJudgment();
    error JudgeAlreadySet();
    error MarketHasOpenRounds();
    error RoundAlreadyOpened();
    error RoundClosedAlready();
    error TooManyOpenRounds();
    error CapacityExceeded();
    error RiskBudgetExceeded();
    error CapacityStressed();
    error JudgmentAlreadyExists();
    error JudgmentAlreadySettled();
    error PayoutExceedsReserved();
    error OnlyJudge();
    error OnlyPoolVault();
    error TooManyMarkets();
    error PostRedeemCapacityExceeded();
    error ActiveRiskBudget();

    constructor(
        address poolVault_,
        address admin_,
        address judgeAdmin_,
        uint16 globalCapacityBps_,
        uint16 defaultMarketCapacityBps_,
        uint16 roundCapacityBps_,
        uint16 maxOpenRounds_
    ) {
        if (
            poolVault_ == address(0) ||
            admin_ == address(0) ||
            judgeAdmin_ == address(0)
        ) {
            revert InvalidAddress();
        }
        if (
            globalCapacityBps_ == 0 ||
            globalCapacityBps_ > BPS_DENOMINATOR ||
            defaultMarketCapacityBps_ == 0 ||
            defaultMarketCapacityBps_ > globalCapacityBps_ ||
            roundCapacityBps_ == 0 ||
            roundCapacityBps_ > defaultMarketCapacityBps_
        ) {
            revert InvalidBps();
        }
        if (
            maxOpenRounds_ == 0 ||
            maxOpenRounds_ > MAX_CONFIGURABLE_OPEN_ROUNDS
        ) {
            revert InvalidMaxOpenRounds();
        }

        poolVault = ISharedPoolVault(poolVault_);
        asset = ISharedPoolVault(poolVault_).asset();
        globalCapacityBps = globalCapacityBps_;
        defaultMarketCapacityBps = defaultMarketCapacityBps_;
        roundCapacityBps = roundCapacityBps_;
        maxOpenRounds = maxOpenRounds_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(JUDGE_ADMIN_ROLE, judgeAdmin_);
    }

    function setJudge(address newJudge) external onlyRole(JUDGE_ADMIN_ROLE) {
        if (newJudge == address(0)) {
            revert InvalidAddress();
        }
        if (judge != address(0)) {
            revert JudgeAlreadySet();
        }
        if (
            newJudge.code.length == 0 ||
            !ISharedJudgeControllerRegistry(newJudge)
                .isSharedJudgmentLiquidityController(address(this))
        ) {
            revert InvalidJudge();
        }

        address previousJudge = judge;
        judge = newJudge;

        emit JudgeUpdated(previousJudge, newJudge);
    }

    function setMaxOpenRounds(
        uint16 newMaxOpenRounds
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (
            newMaxOpenRounds == 0 ||
            newMaxOpenRounds > MAX_CONFIGURABLE_OPEN_ROUNDS ||
            uint256(newMaxOpenRounds) < globalOpenRoundCount
        ) {
            revert InvalidMaxOpenRounds();
        }

        uint16 previousMaxOpenRounds = maxOpenRounds;
        maxOpenRounds = newMaxOpenRounds;

        emit MaxOpenRoundsUpdated(previousMaxOpenRounds, newMaxOpenRounds);
    }

    /// @notice Updates the global/market-default/round risk hierarchy only
    /// after every open obligation and rolling realized loss has expired.
    /// Existing market-specific limits remain explicit and must fit the new
    /// global/round bounds; governance can stage a change through this setter
    /// and configureMarket while the Controller is quiescent.
    function setRiskLimits(
        uint16 newGlobalCapacityBps,
        uint16 newDefaultMarketCapacityBps,
        uint16 newRoundCapacityBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (
            newGlobalCapacityBps == 0 ||
            newGlobalCapacityBps > BPS_DENOMINATOR ||
            newDefaultMarketCapacityBps == 0 ||
            newDefaultMarketCapacityBps > newGlobalCapacityBps ||
            newRoundCapacityBps == 0 ||
            newRoundCapacityBps > newDefaultMarketCapacityBps
        ) {
            revert InvalidBps();
        }
        if (
            globalOpenRoundCount != 0 ||
            globalReservedLoss != 0 ||
            rollingNetLoss24h() != 0
        ) {
            revert ActiveRiskBudget();
        }
        for (uint256 i = 0; i < configuredMarketIds.length; i++) {
            uint16 marketCapacityBps = markets[
                configuredMarketIds[i]
            ].capacityBps;
            if (
                marketCapacityBps < newRoundCapacityBps ||
                marketCapacityBps > newGlobalCapacityBps
            ) {
                revert InvalidBps();
            }
        }

        uint16 previousGlobalCapacityBps = globalCapacityBps;
        uint16 previousDefaultMarketCapacityBps = defaultMarketCapacityBps;
        uint16 previousRoundCapacityBps = roundCapacityBps;
        globalCapacityBps = newGlobalCapacityBps;
        defaultMarketCapacityBps = newDefaultMarketCapacityBps;
        roundCapacityBps = newRoundCapacityBps;

        emit RiskLimitsUpdated(
            previousGlobalCapacityBps,
            newGlobalCapacityBps,
            previousDefaultMarketCapacityBps,
            newDefaultMarketCapacityBps,
            previousRoundCapacityBps,
            newRoundCapacityBps
        );
    }

    /// @notice Configures the protocol shares of payout haircut Edge. The
    /// remaining Edge stays in active LP NAV. Changes apply only to future
    /// rounds.
    function configureRevenueDistribution(
        address newTeamRecipient,
        uint16 newTeamRevenueBps,
        address newTreasuryRecipient,
        uint16 newTreasuryRevenueBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (globalOpenRoundCount != 0) {
            revert ActiveRiskBudget();
        }
        uint256 totalRevenueBps =
            uint256(newTeamRevenueBps) + newTreasuryRevenueBps;
        if (
            totalRevenueBps > MAX_PROTOCOL_REVENUE_BPS ||
            (newTeamRevenueBps == 0) !=
            (newTeamRecipient == address(0)) ||
            (newTreasuryRevenueBps == 0) !=
            (newTreasuryRecipient == address(0)) ||
            (newTeamRevenueBps != 0 &&
                newTreasuryRevenueBps != 0 &&
                newTeamRecipient == newTreasuryRecipient) ||
            newTeamRecipient == address(this) ||
            newTeamRecipient == address(poolVault) ||
            newTreasuryRecipient == address(this) ||
            newTreasuryRecipient == address(poolVault)
        ) {
            revert InvalidProtocolRevenue();
        }

        teamRevenueRecipient = newTeamRecipient;
        teamRevenueBps = newTeamRevenueBps;
        treasuryRevenueRecipient = newTreasuryRecipient;
        treasuryRevenueBps = newTreasuryRevenueBps;

        emit RevenueDistributionConfigured(
            newTeamRecipient,
            newTeamRevenueBps,
            newTreasuryRecipient,
            newTreasuryRevenueBps
        );
    }

    function protocolRevenueBps() external view returns (uint16) {
        return teamRevenueBps + treasuryRevenueBps;
    }

    function configureMarket(
        bytes32 marketId,
        bool enabled,
        uint16 capacityBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (marketId == bytes32(0)) {
            revert InvalidMarket();
        }
        if (
            configuredMarketKnown[marketId] &&
            (marketOpenRoundCount[marketId] != 0 ||
                marketReservedLoss[marketId] != 0)
        ) {
            revert MarketHasOpenRounds();
        }
        if (
            enabled &&
            (capacityBps == 0 ||
                capacityBps > globalCapacityBps ||
                capacityBps < roundCapacityBps)
        ) {
            revert InvalidBps();
        }

        if (enabled && !configuredMarketKnown[marketId]) {
            if (configuredMarketIds.length >= MAX_CONFIGURED_MARKETS) {
                revert TooManyMarkets();
            }
            configuredMarketKnown[marketId] = true;
            configuredMarketIds.push(marketId);
        } else if (!enabled && configuredMarketKnown[marketId]) {
            _removeConfiguredMarket(marketId);
        }

        markets[marketId] = MarketConfig({
            enabled: enabled,
            capacityBps: capacityBps
        });

        emit MarketConfigured(marketId, enabled, capacityBps);
    }

    function openMarketRoundCapacity(
        bytes32 marketId,
        uint256 roundId
    ) external nonReentrant onlyJudge returns (uint256 capacity) {
        if (roundId == 0) {
            revert InvalidRound();
        }
        _requireMarketReady(marketId);

        RoundRisk storage round = rounds[marketId][roundId];
        if (round.opened) {
            revert RoundAlreadyOpened();
        }
        if (globalOpenRoundCount >= maxOpenRounds) {
            revert TooManyOpenRounds();
        }

        capacity = getRoundCapacity(marketId);
        if (capacity == 0 || capacityStressed(marketId)) {
            revert CapacityStressed();
        }

        round.capacity = capacity;
        round.opened = true;
        activeRoundIndexPlusOne[marketId][roundId] =
            activeRoundKeys.length +
            1;
        activeRoundKeys.push(
            ActiveRoundKey({marketId: marketId, roundId: roundId})
        );
        globalOpenRoundCount += 1;
        marketOpenRoundCount[marketId] += 1;
        poolVault.openBusinessRound();

        emit MarketRoundCapacityOpened(marketId, roundId, capacity);
    }

    function commitMarketJudgmentNative(
        bytes32 marketId,
        uint256 roundId,
        uint256 judgmentId,
        address owner,
        uint256 entryAmount,
        uint256 maxPayoutAmount
    ) external payable nonReentrant onlyJudge {
        if (asset != NATIVE_ASSET) {
            revert InvalidAsset();
        }
        if (msg.value != entryAmount) {
            revert InvalidAmount();
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
        poolVault.receiveBusinessEth{value: entryAmount}(entryAmount, 0);
    }

    function commitMarketJudgmentFromWallet(
        bytes32 marketId,
        uint256 roundId,
        uint256 judgmentId,
        address owner,
        uint256 entryAmount,
        uint256 maxPayoutAmount
    ) external virtual nonReentrant onlyJudge {
        _commitMarketJudgmentFromWallet(
            marketId,
            roundId,
            judgmentId,
            owner,
            entryAmount,
            maxPayoutAmount
        );
    }

    function _commitMarketJudgmentFromWallet(
        bytes32 marketId,
        uint256 roundId,
        uint256 judgmentId,
        address owner,
        uint256 entryAmount,
        uint256 maxPayoutAmount
    ) internal {
        if (asset == NATIVE_ASSET) {
            revert InvalidAsset();
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
        poolVault.receiveBusinessAssetFrom(owner, entryAmount, 0);
    }

    function increaseMarketRoundReservedPayout(
        bytes32 marketId,
        uint256 roundId,
        uint256 additionalReservedPayout
    ) external nonReentrant onlyJudge {
        if (additionalReservedPayout == 0) {
            revert InvalidAmount();
        }
        _requireMarketReady(marketId);

        RoundRisk storage round = rounds[marketId][roundId];
        if (!round.opened || round.closed) {
            revert InvalidRound();
        }

        (
            uint256 additionalReservedPayoutForVault,
            uint256 additionalReservedLoss
        ) = _increaseRoundReserve(
            marketId,
            round,
            additionalReservedPayout
        );
        if (additionalReservedPayoutForVault != 0) {
            poolVault.increaseBusinessPayoutReserve(
                additionalReservedPayoutForVault
            );
        }

        emit MarketRoundReservedPayoutIncreased(
            marketId,
            roundId,
            additionalReservedPayout,
            round.reservedObligation,
            additionalReservedLoss
        );
    }

    function settleMarketRoundPayoutPool(
        bytes32 marketId,
        uint256 roundId,
        uint256 totalPayoutAmount,
        uint256 edgeAmount
    )
        external
        nonReentrant
        onlyJudge
        returns (
            uint256 lpEdgeAmount,
            uint256 teamRevenue,
            uint256 treasuryRevenue
        )
    {
        RoundRisk storage round = _openRound(marketId, roundId);
        if (round.closed) {
            revert RoundClosedAlready();
        }
        uint256 receivedAmount = round.escrowedEntryAmount;
        uint256 reservedPayoutAmount = round.reservedObligation;
        uint256 releasedReservedLoss = round.reservedLoss;
        teamRevenue = Math.mulDiv(
            edgeAmount,
            teamRevenueBps,
            BPS_DENOMINATOR
        );
        treasuryRevenue = Math.mulDiv(
            edgeAmount,
            treasuryRevenueBps,
            BPS_DENOMINATOR
        );
        lpEdgeAmount = edgeAmount - teamRevenue - treasuryRevenue;
        uint256 totalSettlementPayout =
            totalPayoutAmount + teamRevenue + treasuryRevenue;
        if (
            totalSettlementPayout > round.settlementReservedPayout ||
            totalSettlementPayout > reservedPayoutAmount
        ) {
            revert PayoutExceedsReserved();
        }

        if (receivedAmount != 0 || reservedPayoutAmount != 0) {
            poolVault.settleBusinessPayoutPool(
                totalSettlementPayout,
                receivedAmount,
                reservedPayoutAmount
            );
        } else if (totalSettlementPayout != 0) {
            revert PayoutExceedsReserved();
        }
        if (teamRevenue != 0) {
            poolVault.allocateBusinessPayout(
                teamRevenueRecipient,
                teamRevenue
            );
        }
        if (treasuryRevenue != 0) {
            poolVault.allocateBusinessPayout(
                treasuryRevenueRecipient,
                treasuryRevenue
            );
        }

        _releaseReservedLoss(marketId, releasedReservedLoss);
        uint256 lpRealizedLoss = totalSettlementPayout > receivedAmount
            ? totalSettlementPayout - receivedAmount
            : 0;
        uint256 lpRealizedProfit = receivedAmount > totalSettlementPayout
            ? receivedAmount - totalSettlementPayout
            : 0;
        _recordRealizedPnl(
            lpRealizedLoss,
            lpRealizedProfit
        );
        _closeRound(marketId, roundId, round);

        emit MarketRoundPayoutPoolSettled(
            marketId,
            roundId,
            totalPayoutAmount,
            receivedAmount,
            reservedPayoutAmount
        );
        emit MarketRoundRevenueDistributed(
            marketId,
            roundId,
            edgeAmount,
            lpEdgeAmount,
            teamRevenueRecipient,
            teamRevenue,
            treasuryRevenueRecipient,
            treasuryRevenue
        );
        emit MarketRoundClosed(marketId, roundId);
    }

    function refundMarketRoundPayoutPool(
        bytes32 marketId,
        uint256 roundId
    ) external nonReentrant onlyJudge {
        RoundRisk storage round = _openRound(marketId, roundId);
        if (round.closed) {
            revert RoundClosedAlready();
        }

        uint256 refundAmount = round.escrowedEntryAmount;
        uint256 reservedPayoutAmount = round.reservedObligation;
        uint256 releasedReservedLoss = round.reservedLoss;

        if (refundAmount != 0 || reservedPayoutAmount != 0) {
            poolVault.refundBusinessPayoutPool(
                refundAmount,
                reservedPayoutAmount
            );
        }

        _releaseReservedLoss(marketId, releasedReservedLoss);
        _closeRound(marketId, roundId, round);

        emit MarketRoundPayoutPoolRefunded(
            marketId,
            roundId,
            refundAmount,
            reservedPayoutAmount
        );
        emit MarketRoundClosed(marketId, roundId);
    }

    function allocateSettledJudgmentPayout(
        uint256 judgmentId,
        uint256 payoutAmount
    ) external nonReentrant onlyJudge {
        (
            bytes32 marketId,
            uint256 roundId,
            address owner
        ) = _settleJudgmentPayout(judgmentId, payoutAmount);
        if (payoutAmount > 0) {
            poolVault.allocateBusinessPayout(owner, payoutAmount);
        }

        emit MarketJudgmentPayoutAllocated(
            marketId,
            roundId,
            judgmentId,
            owner,
            payoutAmount
        );
    }

    function allocateAndClaimSettledJudgmentPayout(
        uint256 judgmentId,
        uint256 payoutAmount,
        address receiver
    ) external nonReentrant onlyJudge {
        if (receiver == address(0)) {
            revert InvalidAddress();
        }
        (
            bytes32 marketId,
            uint256 roundId,
            address owner
        ) = _settleJudgmentPayout(judgmentId, payoutAmount);
        if (payoutAmount > 0) {
            poolVault.allocateAndClaimBusinessPayout(
                owner,
                receiver,
                payoutAmount
            );
        }

        emit MarketJudgmentPayoutAllocated(
            marketId,
            roundId,
            judgmentId,
            owner,
            payoutAmount
        );
    }

    function getGlobalLossCap() public view returns (uint256) {
        return _capacityForBps(globalCapacityBps);
    }

    function getMarketLossCap(
        bytes32 marketId
    ) public view returns (uint256) {
        MarketConfig memory market = markets[marketId];
        if (!market.enabled) {
            return 0;
        }
        return _capacityForBps(market.capacityBps);
    }

    function getRoundCapacity(
        bytes32 marketId
    ) public view returns (uint256) {
        if (!markets[marketId].enabled) {
            return 0;
        }
        return _capacityForBps(roundCapacityBps);
    }

    function capacityStressed(bytes32 marketId) public view returns (bool) {
        MarketConfig memory market = markets[marketId];
        if (!market.enabled) {
            return true;
        }

        uint256 roundCapacity = _capacityForBps(roundCapacityBps);
        uint256 globalCap = _capacityForBps(globalCapacityBps);
        uint256 marketCap = _capacityForBps(market.capacityBps);
        if (
            roundCapacity == 0 ||
            globalCap == 0 ||
            marketCap == 0 ||
            globalReservedLoss > globalCap ||
            marketReservedLoss[marketId] > marketCap ||
            riskUsed24h() > globalCap
        ) {
            return true;
        }

        for (uint256 i = 0; i < activeRoundKeys.length; i++) {
            ActiveRoundKey memory key = activeRoundKeys[i];
            if (
                key.marketId == marketId &&
                rounds[key.marketId][key.roundId].reservedLoss > roundCapacity
            ) {
                return true;
            }
        }
        return false;
    }

    function configuredMarketCount() external view returns (uint256) {
        return configuredMarketIds.length;
    }

    function activeRoundCount() external view returns (uint256) {
        return activeRoundKeys.length;
    }

    function rollingNetLoss24h() public view returns (uint256) {
        return _rollingRiskTotalView();
    }

    function riskUsed24h() public view returns (uint256) {
        return globalReservedLoss + rollingNetLoss24h();
    }

    /// @notice Returns the minimum active NAV needed to preserve every unresolved hard reserve cap.
    /// Realized losses remain in the rolling budget but do not become a second redeem liability.
    function minimumBackingAssetsForOpenRisk()
        public
        view
        returns (uint256 minimumAssets)
    {
        minimumAssets = _assetsRequiredForRisk(
            globalReservedLoss,
            globalCapacityBps
        );
        for (uint256 i = 0; i < configuredMarketIds.length; i++) {
            bytes32 marketId = configuredMarketIds[i];
            uint256 required = _assetsRequiredForRisk(
                marketReservedLoss[marketId],
                markets[marketId].capacityBps
            );
            if (required > minimumAssets) minimumAssets = required;
        }
        for (uint256 i = 0; i < activeRoundKeys.length; i++) {
            ActiveRoundKey memory key = activeRoundKeys[i];
            uint256 required = _assetsRequiredForRisk(
                rounds[key.marketId][key.roundId].reservedLoss,
                roundCapacityBps
            );
            if (required > minimumAssets) minimumAssets = required;
        }
    }

    function validatePostRedeem(uint256 activeAssetsAfter) external view {
        if (msg.sender != address(poolVault)) revert OnlyPoolVault();
        if (activeAssetsAfter < minimumBackingAssetsForOpenRisk()) {
            revert PostRedeemCapacityExceeded();
        }
    }

    function _commitJudgment(CommitParams memory params) internal {
        _requireMarketReady(params.marketId);
        if (params.judgmentId == 0 || params.owner == address(0)) {
            revert InvalidJudgment();
        }
        if (params.entryAmount == 0 || params.maxPayoutAmount == 0) {
            revert InvalidAmount();
        }
        if (judgments[params.judgmentId].owner != address(0)) {
            revert JudgmentAlreadyExists();
        }
        if (capacityStressed(params.marketId)) {
            revert CapacityStressed();
        }

        RoundRisk storage round = rounds[params.marketId][params.roundId];
        if (!round.opened || round.closed) {
            revert InvalidRound();
        }
        if (params.maxPayoutAmount > round.capacity) {
            revert CapacityExceeded();
        }

        round.escrowedEntryAmount += params.entryAmount;
        judgments[params.judgmentId] = JudgmentRisk({
            owner: params.owner,
            marketId: params.marketId,
            roundId: params.roundId,
            maxReservedPayout: params.maxPayoutAmount,
            settled: false
        });

        emit MarketJudgmentCommitted(
            params.marketId,
            params.roundId,
            params.judgmentId,
            params.owner,
            params.entryAmount,
            params.maxPayoutAmount
        );
    }

    function _increaseRoundReserve(
        bytes32 marketId,
        RoundRisk storage round,
        uint256 additionalReservedPayout
    )
        private
        returns (
            uint256 additionalReservedPayoutForVault,
            uint256 additionalReservedLoss
        )
    {
        if (capacityStressed(marketId)) {
            revert CapacityStressed();
        }

        uint256 newSettlementReservedPayout = round
            .settlementReservedPayout +
            additionalReservedPayout;
        if (newSettlementReservedPayout > round.capacity) {
            revert CapacityExceeded();
        }
        round.settlementReservedPayout = newSettlementReservedPayout;
        return _syncRoundReserve(marketId, round);
    }

    function _syncRoundReserve(
        bytes32 marketId,
        RoundRisk storage round
    )
        private
        returns (
            uint256 additionalReservedPayoutForVault,
            uint256 additionalReservedLoss
        )
    {
        uint256 newReservedObligation = round.settlementReservedPayout;
        if (newReservedObligation <= round.reservedObligation) {
            return (0, 0);
        }
        additionalReservedPayoutForVault =
            newReservedObligation -
            round.reservedObligation;

        uint256 newReservedLoss = newReservedObligation >
            round.escrowedEntryAmount
            ? newReservedObligation - round.escrowedEntryAmount
            : 0;
        if (newReservedLoss > getRoundCapacity(marketId)) {
            revert RiskBudgetExceeded();
        }
        if (newReservedLoss > round.reservedLoss) {
            additionalReservedLoss = newReservedLoss - round.reservedLoss;
            _reserveLoss(marketId, additionalReservedLoss);
            round.reservedLoss = newReservedLoss;
        }

        round.reservedObligation = newReservedObligation;
    }

    function _reserveLoss(
        bytes32 marketId,
        uint256 additionalReservedLoss
    ) private {
        if (additionalReservedLoss == 0) {
            return;
        }

        _refreshRiskWindow();
        uint256 globalCap = getGlobalLossCap();
        uint256 marketCap = getMarketLossCap(marketId);
        if (globalCap == 0 || marketCap == 0) {
            revert CapacityStressed();
        }
        if (
            globalReservedLoss + additionalReservedLoss > globalCap ||
            marketReservedLoss[marketId] + additionalReservedLoss > marketCap ||
            globalReservedLoss +
                _rollingNetLossState() +
                additionalReservedLoss >
            globalCap
        ) {
            revert RiskBudgetExceeded();
        }

        globalReservedLoss += additionalReservedLoss;
        marketReservedLoss[marketId] += additionalReservedLoss;

        emit SharedRiskReserved(
            marketId,
            additionalReservedLoss,
            globalReservedLoss,
            marketReservedLoss[marketId]
        );
    }

    function _releaseReservedLoss(
        bytes32 marketId,
        uint256 releasedReservedLoss
    ) private {
        if (releasedReservedLoss == 0) {
            return;
        }

        globalReservedLoss -= releasedReservedLoss;
        marketReservedLoss[marketId] -= releasedReservedLoss;

        emit SharedRiskReleased(
            marketId,
            releasedReservedLoss,
            globalReservedLoss,
            marketReservedLoss[marketId]
        );
    }

    function _settleJudgmentPayout(
        uint256 judgmentId,
        uint256 payoutAmount
    )
        private
        returns (bytes32 marketId, uint256 roundId, address owner)
    {
        JudgmentRisk storage judgment = judgments[judgmentId];
        if (judgment.owner == address(0)) {
            revert InvalidJudgment();
        }
        if (judgment.settled) {
            revert JudgmentAlreadySettled();
        }

        RoundRisk storage round = rounds[judgment.marketId][judgment.roundId];
        if (!round.aggregateSettled || !round.closed) {
            revert InvalidRound();
        }
        if (payoutAmount > judgment.maxReservedPayout) {
            revert PayoutExceedsReserved();
        }

        judgment.settled = true;
        marketId = judgment.marketId;
        roundId = judgment.roundId;
        owner = judgment.owner;
    }

    function _closeRound(
        bytes32 marketId,
        uint256 roundId,
        RoundRisk storage round
    ) private {
        poolVault.closeBusinessRound();

        round.reservedObligation = 0;
        round.settlementReservedPayout = 0;
        round.reservedLoss = 0;
        round.escrowedEntryAmount = 0;
        round.aggregateSettled = true;
        round.closed = true;
        globalOpenRoundCount -= 1;
        marketOpenRoundCount[marketId] -= 1;
        _removeActiveRound(marketId, roundId);
    }

    function _openRound(
        bytes32 marketId,
        uint256 roundId
    ) private view returns (RoundRisk storage round) {
        if (marketId == bytes32(0)) {
            revert InvalidMarket();
        }
        round = rounds[marketId][roundId];
        if (!round.opened) {
            revert InvalidRound();
        }
    }

    function _requireMarketReady(bytes32 marketId) private view {
        if (marketId == bytes32(0) || !markets[marketId].enabled) {
            revert InvalidMarket();
        }
    }

    function _capacityForBps(uint16 bps) private view returns (uint256) {
        return (poolVault.riskBackingAssets() * bps) / BPS_DENOMINATOR;
    }

    function _recordRealizedPnl(
        uint256 realizedLoss,
        uint256 realizedProfit
    ) private {
        _refreshRiskWindow();
        uint256 profitOffset;
        if (realizedLoss != 0 || realizedProfit != 0) {
            RiskBucket storage bucket = _currentRiskBucket();
            if (realizedLoss != 0) {
                bucket.realizedLoss += realizedLoss;
                rollingRealizedLoss += realizedLoss;
            }
            if (realizedProfit != 0) {
                profitOffset = realizedProfit > rollingRealizedLoss
                    ? rollingRealizedLoss
                    : realizedProfit;
                if (profitOffset != 0) {
                    _consumeRollingLoss(profitOffset);
                }
            }
        }
        emit SharedRollingRiskSettled(
            realizedLoss,
            profitOffset,
            _rollingNetLossState(),
            globalReservedLoss,
            globalReservedLoss + _rollingNetLossState()
        );
    }

    function _refreshRiskWindow() private {
        uint256 cutoff = block.timestamp > RISK_WINDOW_DURATION
            ? block.timestamp - RISK_WINDOW_DURATION
            : 0;
        for (uint8 i = 0; i < RISK_BUCKET_COUNT; i++) {
            RiskBucket storage bucket = riskBuckets[i];
            if (
                bucket.startedAt != 0 &&
                uint256(bucket.startedAt) + RISK_BUCKET_DURATION <= cutoff
            ) {
                _subtractRiskBucket(bucket);
                delete riskBuckets[i];
            }
        }
    }

    function _currentRiskBucket()
        private
        returns (RiskBucket storage bucket)
    {
        uint256 bucketNumber = block.timestamp / RISK_BUCKET_DURATION;
        uint8 bucketIndex = uint8(bucketNumber % RISK_BUCKET_COUNT);
        uint64 startedAt = uint64(bucketNumber * RISK_BUCKET_DURATION);
        bucket = riskBuckets[bucketIndex];
        if (bucket.startedAt != startedAt) {
            _subtractRiskBucket(bucket);
            bucket.startedAt = startedAt;
            bucket.realizedLoss = 0;
        }
    }

    function _subtractRiskBucket(RiskBucket storage bucket) private {
        if (bucket.startedAt == 0) return;
        rollingRealizedLoss -= bucket.realizedLoss;
    }

    /// @dev Profit consumes the oldest still-live loss first. It is not stored as
    /// a transferable credit, so it cannot offset losses realized after the
    /// originally offset loss leaves the 24-hour window.
    function _consumeRollingLoss(uint256 amount) private {
        uint256 remaining = amount;
        for (uint8 consumed = 0; consumed < RISK_BUCKET_COUNT; consumed++) {
            uint8 oldestIndex = type(uint8).max;
            uint64 oldestStartedAt = type(uint64).max;
            for (uint8 i = 0; i < RISK_BUCKET_COUNT; i++) {
                RiskBucket storage candidate = riskBuckets[i];
                if (
                    candidate.realizedLoss != 0 &&
                    candidate.startedAt < oldestStartedAt
                ) {
                    oldestIndex = i;
                    oldestStartedAt = candidate.startedAt;
                }
            }
            if (oldestIndex == type(uint8).max) break;

            RiskBucket storage bucket = riskBuckets[oldestIndex];
            uint256 consumedLoss = bucket.realizedLoss > remaining
                ? remaining
                : bucket.realizedLoss;
            bucket.realizedLoss -= consumedLoss;
            rollingRealizedLoss -= consumedLoss;
            remaining -= consumedLoss;
            if (remaining == 0) break;
        }
    }

    function _rollingRiskTotalView() private view returns (uint256 realizedLoss) {
        uint256 cutoff = block.timestamp > RISK_WINDOW_DURATION
            ? block.timestamp - RISK_WINDOW_DURATION
            : 0;
        for (uint8 i = 0; i < RISK_BUCKET_COUNT; i++) {
            RiskBucket storage bucket = riskBuckets[i];
            if (
                bucket.startedAt != 0 &&
                uint256(bucket.startedAt) + RISK_BUCKET_DURATION > cutoff
            ) {
                realizedLoss += bucket.realizedLoss;
            }
        }
    }

    function _rollingNetLossState() private view returns (uint256) {
        return rollingRealizedLoss;
    }

    function _assetsRequiredForRisk(
        uint256 risk,
        uint16 capacityBps
    ) private pure returns (uint256) {
        if (risk == 0) return 0;
        if (capacityBps == 0) return type(uint256).max;
        return
            Math.mulDiv(
                risk,
                BPS_DENOMINATOR,
                capacityBps,
                Math.Rounding.Up
            );
    }

    function _removeActiveRound(bytes32 marketId, uint256 roundId) private {
        uint256 indexPlusOne = activeRoundIndexPlusOne[marketId][roundId];
        if (indexPlusOne == 0) revert InvalidRound();
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = activeRoundKeys.length - 1;
        if (index != lastIndex) {
            ActiveRoundKey memory moved = activeRoundKeys[lastIndex];
            activeRoundKeys[index] = moved;
            activeRoundIndexPlusOne[moved.marketId][moved.roundId] = index + 1;
        }
        activeRoundKeys.pop();
        delete activeRoundIndexPlusOne[marketId][roundId];
    }

    function _removeConfiguredMarket(bytes32 marketId) private {
        uint256 length = configuredMarketIds.length;
        for (uint256 i = 0; i < length; i++) {
            if (configuredMarketIds[i] != marketId) continue;
            uint256 lastIndex = length - 1;
            if (i != lastIndex) {
                configuredMarketIds[i] = configuredMarketIds[lastIndex];
            }
            configuredMarketIds.pop();
            configuredMarketKnown[marketId] = false;
            return;
        }
    }

    modifier onlyJudge() {
        if (msg.sender != judge) {
            revert OnlyJudge();
        }
        _;
    }
}
