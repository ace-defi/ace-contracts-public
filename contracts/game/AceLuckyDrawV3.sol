// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IAceLuckyDrawV2JudgeReader.sol";

/// @notice Amount-proportional, asset-isolated Lucky Draw funded by an independent prize pool.
/// @dev V3 randomness is ACE-operated but publicly auditable. The operator knows
/// future preimages and can delay fulfillment, but cannot replace, skip, replay,
/// or reorder a preimage after a draw is assigned to it.
contract AceLuckyDrawV3 is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant RNG_ROLE = keccak256("RNG_ROLE");
    bytes32 public constant CIRCUIT_BREAKER_ROLE =
        keccak256("CIRCUIT_BREAKER_ROLE");
    bytes32 public constant CHAIN_DOMAIN = keccak256("ACE_LUCKY_DRAW_CHAIN_V1");
    bytes32 public constant ROLL_DOMAIN = keccak256("ACE_LUCKY_DRAW_ROLL_V1");

    address public constant NATIVE_ASSET = address(0);
    uint256 public constant WAD = 1e18;
    /// @notice Minimum Judgment notional for one draw. It is not a ticket unit.
    uint256 public constant MIN_NOTIONAL_USD_WAD = 10e18;
    /// @notice The fair expected prize is 0.75% of the Judgment asset amount.
    uint16 public constant BASE_REWARD_BPS = 75;
    uint256 public constant USDC_TO_USD_WAD = 1e12;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint8 public constant MIN_MODULO = 2;
    uint8 public constant MAX_MODULO = 100;
    uint8 public constant D6_MODULO = 6;
    uint8 public constant SELECTION_EXACT = 0;
    uint8 public constant SELECTION_BIG = 1;
    uint8 public constant SELECTION_SMALL = 2;
    uint8 public constant SELECTION_ODD = 3;
    uint8 public constant SELECTION_EVEN = 4;
    uint8 public constant MAX_SELECTION_TYPE = SELECTION_EVEN;
    uint8 private constant PLAY_SELECTION_SHIFT = 7;
    uint8 private constant PLAY_NUMBER_SHIFT = 10;
    uint8 public constant MAX_DRAW_COUNT = 1;
    uint32 public constant MAX_EPOCH_LENGTH = 65_535;

    enum EpochStatus {
        None,
        Prepared,
        Active,
        Closed,
        Cancelled
    }

    struct Epoch {
        bytes32 commitment;
        bytes32 currentHead;
        uint32 length;
        uint32 assigned;
        uint32 fulfilled;
        uint64 preparedAt;
        uint64 activatedAt;
        uint64 closedAt;
        EpochStatus status;
    }

    struct Play {
        uint8 modulo;
        uint8 selectionType;
        uint8 number;
    }

    struct Draw {
        address user;
        bytes32 luckyWordHash;
        uint256 judgmentId;
        uint256 epochId;
        uint32 chainIndex;
        uint64 economicsVersion;
        uint64 requestDay;
        uint256 playPacked;
        uint8 outcome;
        uint256 basePrize;
        uint256 maxPayout;
        uint256 payout;
        bool fulfilled;
    }

    IAceLuckyDrawV2JudgeReader public immutable judge;
    address public immutable asset;
    uint8 public immutable eligibleEntryAsset;
    uint256 public immutable firstEligibleJudgmentId;

    uint64 public economicsVersion;
    uint256 public dailyPayoutBudget;
    uint256 public userDailyPayoutBudget;

    uint256 public latestEpochId;
    uint256 public currentEpochId;
    uint256 public preparedEpochId;
    uint256 public nextDrawId = 1;
    uint256 public totalReservedPayout;
    uint256 public totalClaimablePayout;

    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => Draw) public draws;
    mapping(uint256 => mapping(uint32 => uint256)) public drawIdByEpochIndex;
    mapping(uint256 => uint256) public drawIdByJudgmentId;
    mapping(address => uint256) public claimablePayout;
    mapping(uint256 => uint256) public dailyReservedPayout;
    mapping(uint256 => uint256) public dailyAwardedPayout;
    mapping(uint256 => mapping(address => uint256))
        public userDailyReservedPayout;
    mapping(uint256 => mapping(address => uint256))
        public userDailyAwardedPayout;
    mapping(uint8 => mapping(uint8 => bool)) public gameEnabled;

    event EconomicsConfigured(
        uint64 indexed economicsVersion,
        uint16 baseRewardBps,
        uint256 dailyPayoutBudget,
        uint256 userDailyPayoutBudget
    );
    event EpochPrepared(
        uint256 indexed epochId,
        bytes32 indexed commitment,
        uint32 length,
        uint256 preparedAt
    );
    event EpochCancelled(
        uint256 indexed epochId,
        bytes32 indexed commitment,
        uint256 preparedAt,
        uint256 cancelledAt
    );
    event EpochActivated(uint256 indexed epochId, uint256 activatedAt);
    event EpochClosed(uint256 indexed epochId, uint256 closedAt);
    event GameAvailabilityConfigured(
        uint8 indexed modulo,
        uint8 indexed selectionType,
        bool enabled
    );
    event DrawRequested(
        uint256 indexed drawId,
        address indexed user,
        uint256 indexed epochId,
        uint256 judgmentId,
        uint32 chainIndex,
        uint256 playPacked,
        bytes32 luckyWordHash,
        uint64 economicsVersion,
        uint256 basePrize,
        uint256 maxPayout,
        uint256 requestDay
    );
    event DrawFulfilled(
        uint256 indexed drawId,
        address indexed user,
        uint256 indexed epochId,
        uint32 chainIndex,
        bytes32 preimage,
        uint8 outcome,
        uint256 payout
    );
    event PoolFunded(address indexed funder, uint256 amount);
    event SurplusWithdrawn(address indexed recipient, uint256 amount);
    event PayoutClaimed(
        address indexed user,
        address indexed recipient,
        uint256 amount
    );

    error InvalidAddress();
    error InvalidAmount();
    error InvalidAssetTransfer();
    error InvalidEconomics();
    error EconomicsChanged();
    error InvalidJudgment();
    error NotJudgmentOwner();
    error JudgmentAlreadyUsed();
    error JudgmentBeforeEligibility();
    error WrongEntryAsset();
    error JudgmentBelowMinimum();
    error InvalidGame();
    error GameDisabled();
    error InvalidSelection();
    error AssignmentChanged();
    error NoActiveEpoch();
    error EpochAlreadyPrepared();
    error NoPreparedEpoch();
    error InvalidEpoch();
    error EpochExhausted();
    error PendingDraws();
    error InvalidDraw();
    error DrawAlreadyFulfilled();
    error DrawOutOfOrder();
    error InvalidPreimage();
    error InsufficientPrizePool();
    error DailyBudgetExceeded();
    error UserDailyBudgetExceeded();
    error InsufficientSurplus();
    error NothingToClaim();

    constructor(
        address judge_,
        address asset_,
        uint256 firstEligibleJudgmentId_,
        uint256 dailyPayoutBudget_,
        uint256 userDailyPayoutBudget_,
        address admin_,
        address rngOperator_,
        address circuitBreaker_
    ) {
        if (
            judge_ == address(0) ||
            judge_.code.length == 0 ||
            admin_ == address(0) ||
            rngOperator_ == address(0) ||
            circuitBreaker_ == address(0)
        ) {
            revert InvalidAddress();
        }
        if (firstEligibleJudgmentId_ == 0) revert InvalidJudgment();
        if (
            asset_ != NATIVE_ASSET &&
            (asset_.code.length == 0 || IERC20Metadata(asset_).decimals() != 6)
        ) {
            revert InvalidAddress();
        }

        judge = IAceLuckyDrawV2JudgeReader(judge_);
        asset = asset_;
        eligibleEntryAsset = asset_ == NATIVE_ASSET ? 0 : 1;
        firstEligibleJudgmentId = firstEligibleJudgmentId_;
        _setEconomics(dailyPayoutBudget_, userDailyPayoutBudget_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(RNG_ROLE, rngOperator_);
        _grantRole(CIRCUIT_BREAKER_ROLE, circuitBreaker_);

        _setGameEnabled(D6_MODULO, SELECTION_EXACT, true);
        _setGameEnabled(D6_MODULO, SELECTION_BIG, true);
        _setGameEnabled(D6_MODULO, SELECTION_SMALL, true);
        _setGameEnabled(D6_MODULO, SELECTION_ODD, true);
        _setGameEnabled(D6_MODULO, SELECTION_EVEN, true);
        _pause();
    }

    receive() external payable {
        if (asset != NATIVE_ASSET || msg.value == 0) {
            revert InvalidAssetTransfer();
        }
        emit PoolFunded(msg.sender, msg.value);
    }

    function setEconomics(
        uint256 dailyPayoutBudget_,
        uint256 userDailyPayoutBudget_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setEconomics(dailyPayoutBudget_, userDailyPayoutBudget_);
    }

    /// @notice Enables or disables one reviewed modulo/selection pair for new requests.
    /// @dev Existing draws retain their packed selection and remain fulfillable.
    function setGameEnabled(
        uint8 modulo,
        uint8 selectionType,
        bool enabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setGameEnabled(modulo, selectionType, enabled);
    }

    function pause() external onlyRole(CIRCUIT_BREAKER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function prepareEpoch(
        bytes32 commitment,
        uint32 length
    ) external onlyRole(RNG_ROLE) returns (uint256 epochId) {
        if (preparedEpochId != 0) revert EpochAlreadyPrepared();
        if (
            commitment == bytes32(0) || length == 0 || length > MAX_EPOCH_LENGTH
        ) {
            revert InvalidEpoch();
        }

        epochId = latestEpochId + 1;
        latestEpochId = epochId;
        preparedEpochId = epochId;
        epochs[epochId] = Epoch({
            commitment: commitment,
            currentHead: commitment,
            length: length,
            assigned: 0,
            fulfilled: 0,
            preparedAt: uint64(block.timestamp),
            activatedAt: 0,
            closedAt: 0,
            status: EpochStatus.Prepared
        });

        emit EpochPrepared(epochId, commitment, length, block.timestamp);
    }

    /// @notice Discards an unactivated epoch whose committed chain cannot be used.
    /// @dev Cancelled epoch ids remain consumed so replacement chains use a new domain.
    function cancelPreparedEpoch() external onlyRole(RNG_ROLE) {
        uint256 epochId = preparedEpochId;
        if (epochId == 0) revert NoPreparedEpoch();

        Epoch storage epoch = epochs[epochId];
        if (
            epoch.status != EpochStatus.Prepared ||
            epoch.assigned != 0 ||
            epoch.fulfilled != 0
        ) {
            revert InvalidEpoch();
        }

        uint64 cancelledAt = uint64(block.timestamp);
        epoch.status = EpochStatus.Cancelled;
        epoch.closedAt = cancelledAt;
        preparedEpochId = 0;

        emit EpochCancelled(
            epochId,
            epoch.commitment,
            epoch.preparedAt,
            cancelledAt
        );
    }

    function activatePreparedEpoch() external onlyRole(RNG_ROLE) {
        uint256 epochId = preparedEpochId;
        if (epochId == 0) revert NoPreparedEpoch();

        uint256 previousEpochId = currentEpochId;
        if (previousEpochId != 0) {
            Epoch storage previous = epochs[previousEpochId];
            if (
                previous.status != EpochStatus.Active ||
                previous.assigned != previous.fulfilled
            ) {
                revert PendingDraws();
            }
            previous.status = EpochStatus.Closed;
            previous.closedAt = uint64(block.timestamp);
            emit EpochClosed(previousEpochId, block.timestamp);
        }

        Epoch storage next = epochs[epochId];
        if (next.status != EpochStatus.Prepared) revert InvalidEpoch();
        next.status = EpochStatus.Active;
        next.activatedAt = uint64(block.timestamp);
        currentEpochId = epochId;
        preparedEpochId = 0;

        emit EpochActivated(epochId, block.timestamp);
    }

    function _basePrizeForJudgment(
        address user,
        uint256 judgmentId
    ) private view returns (uint256 basePrize) {
        if (judgmentId < firstEligibleJudgmentId) {
            revert JudgmentBeforeEligibility();
        }
        if (drawIdByJudgmentId[judgmentId] != 0) {
            revert JudgmentAlreadyUsed();
        }

        (
            bytes32 marketId,
            uint256 roundId,
            address judgmentUser,
            uint8 entryAsset,
            ,
            ,
            uint256 amountAsset
        ) = judge.judgments(judgmentId);
        if (marketId == bytes32(0) || roundId == 0 || amountAsset == 0) {
            revert InvalidJudgment();
        }
        if (judgmentUser != user) revert NotJudgmentOwner();
        if (entryAsset != eligibleEntryAsset) revert WrongEntryAsset();

        (
            bytes32 storedMarketId,
            uint256 storedRoundId,
            ,
            ,
            ,
            uint256 nativeUsdReference,
            ,
            ,
            ,
            bool started
        ) = judge.rounds(marketId, roundId);
        if (
            storedMarketId != marketId || storedRoundId != roundId || !started
        ) {
            revert InvalidJudgment();
        }

        uint256 notionalUsdWad;
        if (entryAsset == 0) {
            if (nativeUsdReference == 0) revert InvalidJudgment();
            // Judge stores the round-pinned HYPE/USD price as 18-decimal USD per HYPE.
            notionalUsdWad = Math.mulDiv(amountAsset, nativeUsdReference, WAD);
        } else {
            notionalUsdWad = amountAsset * USDC_TO_USD_WAD;
        }
        if (notionalUsdWad < MIN_NOTIONAL_USD_WAD) {
            revert JudgmentBelowMinimum();
        }
        basePrize = basePrizeForAmount(amountAsset);
        if (basePrize == 0) revert InvalidAmount();
    }

    /// @notice Consumes one qualifying Judgment and requests its only draw atomically.
    function requestDrawForJudgment(
        uint256 judgmentId,
        uint256 expectedEpochId,
        uint32 expectedChainIndex,
        uint64 expectedEconomicsVersion,
        Play calldata play,
        bytes32 luckyWordHash
    ) external nonReentrant whenNotPaused returns (uint256 drawId) {
        uint256 basePrize = _basePrizeForJudgment(msg.sender, judgmentId);
        return
            _requestDraw(
                msg.sender,
                judgmentId,
                basePrize,
                expectedEpochId,
                expectedChainIndex,
                expectedEconomicsVersion,
                play,
                luckyWordHash
            );
    }

    function _requestDraw(
        address user,
        uint256 judgmentId,
        uint256 basePrize,
        uint256 expectedEpochId,
        uint32 expectedChainIndex,
        uint64 expectedEconomicsVersion,
        Play calldata play,
        bytes32 luckyWordHash
    ) private returns (uint256 drawId) {
        uint256 epochId = currentEpochId;
        if (epochId == 0) revert NoActiveEpoch();
        Epoch storage epoch = epochs[epochId];
        if (epoch.status != EpochStatus.Active) revert NoActiveEpoch();
        if (epoch.assigned >= epoch.length) revert EpochExhausted();
        if (
            expectedEpochId != epochId ||
            expectedChainIndex != epoch.assigned + 1
        ) {
            revert AssignmentChanged();
        }
        uint64 economicsVersionSnapshot = economicsVersion;
        if (expectedEconomicsVersion != economicsVersionSnapshot) {
            revert EconomicsChanged();
        }

        _validatePlay(play);
        uint256 playPacked = _packPlay(play);
        uint256 maxPayout = _payoutFor(
            basePrize,
            play.modulo,
            play.selectionType
        );

        uint256 liabilities = totalReservedPayout + totalClaimablePayout;
        uint256 poolBalance = assetBalance();
        if (
            poolBalance < liabilities || poolBalance - liabilities < maxPayout
        ) {
            revert InsufficientPrizePool();
        }

        uint256 requestDay = block.timestamp / 1 days;
        uint256 dayExposure = dailyReservedPayout[requestDay] +
            dailyAwardedPayout[requestDay];
        if (
            maxPayout > dailyPayoutBudget ||
            dayExposure > dailyPayoutBudget - maxPayout
        ) {
            revert DailyBudgetExceeded();
        }
        uint256 userDayExposure = userDailyReservedPayout[requestDay][user] +
            userDailyAwardedPayout[requestDay][user];
        if (
            maxPayout > userDailyPayoutBudget ||
            userDayExposure > userDailyPayoutBudget - maxPayout
        ) {
            revert UserDailyBudgetExceeded();
        }

        uint32 chainIndex = epoch.assigned + 1;
        epoch.assigned = chainIndex;
        totalReservedPayout += maxPayout;
        dailyReservedPayout[requestDay] += maxPayout;
        userDailyReservedPayout[requestDay][user] += maxPayout;

        drawId = nextDrawId;
        nextDrawId += 1;
        drawIdByJudgmentId[judgmentId] = drawId;
        draws[drawId] = Draw({
            user: user,
            luckyWordHash: luckyWordHash,
            judgmentId: judgmentId,
            epochId: epochId,
            chainIndex: chainIndex,
            economicsVersion: economicsVersionSnapshot,
            requestDay: uint64(requestDay),
            playPacked: playPacked,
            outcome: 0,
            basePrize: basePrize,
            maxPayout: maxPayout,
            payout: 0,
            fulfilled: false
        });
        drawIdByEpochIndex[epochId][chainIndex] = drawId;

        emit DrawRequested(
            drawId,
            user,
            epochId,
            judgmentId,
            chainIndex,
            playPacked,
            luckyWordHash,
            economicsVersionSnapshot,
            basePrize,
            maxPayout,
            requestDay
        );
    }

    /// @notice Reveals the next committed preimage and settles exactly its assigned draw.
    /// @dev Anyone holding the correct preimage may restore progress after a relayer outage.
    function fulfillNext(
        uint256 drawId,
        bytes32 preimage
    ) external nonReentrant {
        Draw storage draw = draws[drawId];
        if (draw.user == address(0)) revert InvalidDraw();
        if (draw.fulfilled) revert DrawAlreadyFulfilled();

        uint256 epochId = currentEpochId;
        if (epochId == 0) revert NoActiveEpoch();
        Epoch storage epoch = epochs[epochId];
        uint32 expectedIndex = epoch.fulfilled + 1;
        if (
            epoch.status != EpochStatus.Active ||
            draw.epochId != epochId ||
            draw.chainIndex != expectedIndex ||
            drawIdByEpochIndex[epochId][expectedIndex] != drawId
        ) {
            revert DrawOutOfOrder();
        }
        if (
            hashChainLink(epochId, expectedIndex, preimage) != epoch.currentHead
        ) {
            revert InvalidPreimage();
        }

        epoch.currentHead = preimage;
        epoch.fulfilled = expectedIndex;

        Play memory play = _unpackPlay(draw.playPacked);
        uint8 outcome = uint8(
            uint256(
                keccak256(
                    abi.encode(
                        ROLL_DOMAIN,
                        block.chainid,
                        address(this),
                        drawId,
                        draw.judgmentId,
                        draw.user,
                        draw.luckyWordHash,
                        preimage
                    )
                )
            ) % play.modulo
        );
        uint8 displayedOutcome = outcome + 1;
        uint256 payout;
        if (_isWinning(play, outcome)) {
            payout = _payoutFor(
                draw.basePrize,
                play.modulo,
                play.selectionType
            );
        }

        draw.fulfilled = true;
        draw.outcome = displayedOutcome;
        draw.payout = payout;
        totalReservedPayout -= draw.maxPayout;
        dailyReservedPayout[draw.requestDay] -= draw.maxPayout;
        userDailyReservedPayout[draw.requestDay][draw.user] -= draw.maxPayout;
        if (payout != 0) {
            totalClaimablePayout += payout;
            claimablePayout[draw.user] += payout;
            dailyAwardedPayout[draw.requestDay] += payout;
            userDailyAwardedPayout[draw.requestDay][draw.user] += payout;
        }

        emit DrawFulfilled(
            drawId,
            draw.user,
            epochId,
            expectedIndex,
            preimage,
            displayedOutcome,
            payout
        );
    }

    function fund(uint256 amount) external payable nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (asset == NATIVE_ASSET) {
            if (msg.value != amount) revert InvalidAssetTransfer();
        } else {
            if (msg.value != 0) revert InvalidAssetTransfer();
            IERC20 token = IERC20(asset);
            uint256 balanceBefore = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), amount);
            if (token.balanceOf(address(this)) - balanceBefore != amount) {
                revert InvalidAssetTransfer();
            }
        }
        emit PoolFunded(msg.sender, amount);
    }

    function withdrawSurplus(
        address payable recipient,
        uint256 amount
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (amount > availablePool()) revert InsufficientSurplus();

        _transferAsset(recipient, amount);
        emit SurplusWithdrawn(recipient, amount);
    }

    function claim(address payable recipient) external nonReentrant {
        if (recipient == address(0)) revert InvalidAddress();
        uint256 amount = claimablePayout[msg.sender];
        if (amount == 0) revert NothingToClaim();

        claimablePayout[msg.sender] = 0;
        totalClaimablePayout -= amount;
        _transferAsset(recipient, amount);
        emit PayoutClaimed(msg.sender, recipient, amount);
    }

    function assetBalance() public view returns (uint256) {
        if (asset == NATIVE_ASSET) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    function availablePool() public view returns (uint256) {
        uint256 balance = assetBalance();
        uint256 liabilities = totalReservedPayout + totalClaimablePayout;
        return balance > liabilities ? balance - liabilities : 0;
    }

    function currentDayExposure() external view returns (uint256) {
        uint256 day = block.timestamp / 1 days;
        return dailyReservedPayout[day] + dailyAwardedPayout[day];
    }

    /// @notice Returns reserved plus awarded exposure for `user` in the current UTC day.
    function currentUserDayExposure(
        address user
    ) external view returns (uint256) {
        uint256 day = block.timestamp / 1 days;
        return
            userDailyReservedPayout[day][user] +
            userDailyAwardedPayout[day][user];
    }

    function nextAssignment()
        external
        view
        returns (
            uint256 epochId,
            uint32 chainIndex,
            uint64 currentEconomicsVersion
        )
    {
        epochId = currentEpochId;
        Epoch storage epoch = epochs[epochId];
        if (
            epochId == 0 ||
            epoch.status != EpochStatus.Active ||
            epoch.assigned >= epoch.length
        ) {
            return (epochId, 0, economicsVersion);
        }
        return (epochId, epoch.assigned + 1, economicsVersion);
    }

    function basePrizeForAmount(
        uint256 amountAsset
    ) public pure returns (uint256) {
        return Math.mulDiv(amountAsset, BASE_REWARD_BPS, BPS_DENOMINATOR);
    }

    function quotePayout(
        uint256 amountAsset,
        uint8 modulo,
        uint8 selectionType
    ) external view returns (uint256) {
        _validateGameDefinition(modulo, selectionType);
        if (!gameEnabled[modulo][selectionType]) revert GameDisabled();
        return
            _payoutFor(basePrizeForAmount(amountAsset), modulo, selectionType);
    }

    function getDrawPlay(uint256 drawId) external view returns (Play memory) {
        Draw storage draw = draws[drawId];
        if (draw.user == address(0)) revert InvalidDraw();
        return _unpackPlay(draw.playPacked);
    }

    function getDrawOutcome(uint256 drawId) external view returns (uint8) {
        Draw storage draw = draws[drawId];
        if (draw.user == address(0) || !draw.fulfilled) {
            revert InvalidDraw();
        }
        return draw.outcome;
    }

    function hashChainLink(
        uint256 epochId,
        uint32 index,
        bytes32 preimage
    ) public view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CHAIN_DOMAIN,
                    block.chainid,
                    address(this),
                    epochId,
                    index,
                    preimage
                )
            );
    }

    function _setEconomics(
        uint256 dailyPayoutBudget_,
        uint256 userDailyPayoutBudget_
    ) private {
        if (
            dailyPayoutBudget_ == 0 ||
            userDailyPayoutBudget_ == 0 ||
            userDailyPayoutBudget_ > dailyPayoutBudget_
        ) {
            revert InvalidEconomics();
        }
        dailyPayoutBudget = dailyPayoutBudget_;
        userDailyPayoutBudget = userDailyPayoutBudget_;
        economicsVersion += 1;
        emit EconomicsConfigured(
            economicsVersion,
            BASE_REWARD_BPS,
            dailyPayoutBudget_,
            userDailyPayoutBudget_
        );
    }

    function _payoutFor(
        uint256 basePrize,
        uint8 modulo,
        uint8 selectionType
    ) private pure returns (uint256) {
        return
            Math.mulDiv(
                basePrize,
                modulo,
                _winningCount(modulo, selectionType)
            );
    }

    function _setGameEnabled(
        uint8 modulo,
        uint8 selectionType,
        bool enabled
    ) private {
        _validateGameDefinition(modulo, selectionType);
        gameEnabled[modulo][selectionType] = enabled;
        emit GameAvailabilityConfigured(modulo, selectionType, enabled);
    }

    function _validatePlay(Play calldata play) private view {
        _validateGameDefinition(play.modulo, play.selectionType);
        if (!gameEnabled[play.modulo][play.selectionType]) {
            revert GameDisabled();
        }
        if (play.selectionType == SELECTION_EXACT) {
            if (play.number == 0 || play.number > play.modulo) {
                revert InvalidSelection();
            }
        } else if (play.number != 0) {
            revert InvalidSelection();
        }
    }

    function _validateGameDefinition(
        uint8 modulo,
        uint8 selectionType
    ) private pure {
        if (
            modulo < MIN_MODULO ||
            modulo > MAX_MODULO ||
            selectionType > MAX_SELECTION_TYPE
        ) {
            revert InvalidGame();
        }
    }

    function _packPlay(Play calldata play) private pure returns (uint256) {
        return
            uint256(play.modulo) |
            (uint256(play.selectionType) << PLAY_SELECTION_SHIFT) |
            (uint256(play.number) << PLAY_NUMBER_SHIFT);
    }

    function _unpackPlay(
        uint256 packed
    ) private pure returns (Play memory play) {
        play.modulo = uint8(packed & 0x7f);
        play.selectionType = uint8((packed >> PLAY_SELECTION_SHIFT) & 0x07);
        play.number = uint8((packed >> PLAY_NUMBER_SHIFT) & 0x7f);
    }

    function _winningCount(
        uint8 modulo,
        uint8 selectionType
    ) private pure returns (uint256) {
        if (selectionType == SELECTION_EXACT) return 1;

        uint256 lowerHalf = uint256(modulo) / 2;
        if (
            selectionType == SELECTION_SMALL || selectionType == SELECTION_EVEN
        ) {
            return lowerHalf;
        }
        return uint256(modulo) - lowerHalf;
    }

    function _isWinning(
        Play memory play,
        uint8 outcome
    ) private pure returns (bool) {
        uint256 displayed = uint256(outcome) + 1;
        if (play.selectionType == SELECTION_EXACT) {
            return displayed == play.number;
        }
        if (play.selectionType == SELECTION_BIG) {
            return displayed > uint256(play.modulo) / 2;
        }
        if (play.selectionType == SELECTION_SMALL) {
            return displayed <= uint256(play.modulo) / 2;
        }
        if (play.selectionType == SELECTION_ODD) {
            return displayed % 2 == 1;
        }
        return displayed % 2 == 0;
    }

    function _transferAsset(address payable recipient, uint256 amount) private {
        if (asset == NATIVE_ASSET) {
            (bool success, ) = recipient.call{value: amount}("");
            if (!success) revert InvalidAssetTransfer();
        } else {
            IERC20(asset).safeTransfer(recipient, amount);
        }
    }
}
