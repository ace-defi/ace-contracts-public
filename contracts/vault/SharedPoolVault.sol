// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/ISharedPoolVaultBusinessController.sol";
import "../interfaces/IERC3009.sol";

contract SharedPoolVault is ERC20, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant CIRCUIT_BREAKER_ROLE =
        keccak256("CIRCUIT_BREAKER_ROLE");
    address public constant NATIVE_ASSET = address(0);

    address public immutable asset;
    uint8 private immutable shareDecimals;
    uint256 public exposureEpoch = 1;

    address public businessController;
    uint256 private activeAssets;
    uint256 public activeBusinessRoundCount;
    uint256 public businessEscrowAssets;
    uint256 public reservedBusinessPayout;
    uint256 public unallocatedClaimableAssets;
    uint256 public totalClaimableAssets;
    bool private localUserRedeemsFrozen;
    bool private localBusinessActionsFrozen;

    mapping(address => uint256) public claimableAssets;

    event BusinessControllerUpdated(
        address indexed previousController,
        address indexed newController
    );
    event BusinessControllerMigrated(
        address indexed previousController,
        address indexed newController,
        uint256 previousExposureEpoch,
        uint256 newExposureEpoch,
        uint256 activeAssets,
        uint256 activeSupply
    );
    event BusinessRoundOpened(uint256 activeBusinessRoundCount);
    event BusinessRoundClosed(uint256 activeBusinessRoundCount);
    event BusinessAssetsReceived(
        address indexed payer,
        uint256 amount,
        uint256 reservedPayoutAmount
    );
    event BusinessPayoutReserveIncreased(
        uint256 additionalReservedPayout,
        uint256 reservedBusinessPayout
    );
    event BusinessPayoutPoolSettled(
        uint256 payoutAmount,
        uint256 receivedAmount,
        uint256 reservedPayoutAmount,
        int256 activeAssetDelta
    );
    event BusinessPayoutPoolRefunded(
        uint256 receivedAmount,
        uint256 reservedPayoutAmount
    );
    event BusinessPayoutAllocated(address indexed recipient, uint256 amount);
    event BusinessPayoutClaimed(
        address indexed account,
        address indexed receiver,
        uint256 amount
    );
    event DirectDeposit(
        address indexed caller,
        address indexed receiver,
        uint256 assets,
        uint256 shares,
        uint256 exposureEpoch,
        uint256 activeAssetsAfter,
        uint256 totalActiveSupplyAfter
    );
    event DirectRedeem(
        address indexed caller,
        address indexed receiver,
        uint256 assets,
        uint256 shares,
        uint256 exposureEpoch,
        uint256 activeAssetsAfter,
        uint256 totalActiveSupplyAfter
    );
    event RiskAdjustedDeposit(
        address indexed caller,
        uint256 assets,
        uint256 shares,
        uint256 pricingAssets,
        uint256 riskBps
    );
    event RiskAdjustedRedeem(
        address indexed caller,
        uint256 assets,
        uint256 shares,
        uint256 pricingAssets,
        uint256 haircutBps
    );
    event UserRedeemsFrozen(address indexed caller);
    event BusinessActionsFrozen(address indexed caller);
    event AllOutflowsFrozen(address indexed caller);
    event UserRedeemsUnfrozen(address indexed caller);
    event BusinessActionsUnfrozen(address indexed caller);
    event AllOutflowsUnfrozen(address indexed caller);

    error InvalidAddress();
    error InvalidAmount();
    error InvalidAssetTransfer();
    error DirectNativeTransferDisabled();
    error ThirdPartyRequestDisabled();
    error ShareTransferDisabled();
    error InvalidBusinessController();
    error BusinessControllerAlreadySet();
    error BusinessActionsMustBeFrozen();
    error BusinessRiskWindowActive();
    error OnlyBusinessController();
    error NoActiveBusinessRound();
    error BusinessObligationsActive();
    error UserRedeemsAreFrozen();
    error BusinessActionsAreFrozen();
    error PayoutExceedsReserved();
    error UnallocatedPayoutExceeded();
    error ClaimableBalanceExceeded();
    error DeadlineExpired();
    error SlippageExceeded();
    error InsufficientShares();
    error InsufficientAvailableAssets();
    error EmptyAssetBase();
    error RiskLimitExceeded();
    error ReservedLossExceedsAssets();
    error FinalRiskBearingShare();

    constructor(
        string memory name_,
        string memory symbol_,
        address asset_,
        uint8 shareDecimals_,
        address admin_,
        address circuitBreaker_
    ) ERC20(name_, symbol_) {
        if (admin_ == address(0) || circuitBreaker_ == address(0)) {
            revert InvalidAddress();
        }

        asset = asset_;
        shareDecimals = shareDecimals_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(CIRCUIT_BREAKER_ROLE, circuitBreaker_);
    }

    receive() external payable {
        revert DirectNativeTransferDisabled();
    }

    function decimals() public view override returns (uint8) {
        return shareDecimals;
    }

    // Virtual reads preserve legacy local flags and let fresh V5 deployments
    // share the Hub's pause without duplicating the accounting implementation.
    function userRedeemsFrozen() public view virtual returns (bool) {
        return localUserRedeemsFrozen;
    }

    function businessActionsFrozen() public view virtual returns (bool) {
        return localBusinessActionsFrozen;
    }

    /// @notice Returns active LP NAV assets, excluding claimable payouts and escrow.
    function totalAssets() public view returns (uint256) {
        return activeAssets;
    }

    function totalActiveSupply() public view returns (uint256) {
        return totalSupply();
    }

    /// @notice Returns active assets available for shared business risk capacity.
    function riskBackingAssets() external view returns (uint256) {
        return activeAssets;
    }

    /// @notice Returns the raw token/ETH balance held by the vault, including non-active accounting buckets.
    function custodiedAssets() public view returns (uint256) {
        if (asset == NATIVE_ASSET) {
            return address(this).balance;
        }

        return IERC20(asset).balanceOf(address(this));
    }

    function previewDeposit(
        uint256 assets
    ) external view returns (uint256 shares) {
        if (assets == 0) {
            revert InvalidAmount();
        }

        shares = _calculateDepositShares(
            assets,
            activeAssets,
            totalSupply()
        );
    }

    function previewRedeem(
        uint256 shares
    ) external view returns (uint256 assets) {
        if (shares == 0) {
            revert InvalidAmount();
        }
        uint256 supply = totalSupply();
        if (supply == 0) {
            revert EmptyAssetBase();
        }

        assets = (activeAssets * shares) / supply;
        if (assets == 0) {
            revert InvalidAmount();
        }
    }

    /// @notice Returns the continuous B2 pricing bounds. Realized PnL is already reflected in activeAssets.
    function riskAdjustedLpState()
        public
        view
        returns (
            uint256 activeAssets_,
            uint256 businessEscrow,
            uint256 reservedLoss,
            uint256 depositPricingAssets,
            uint256 redeemPricingAssets,
            uint256 depositRiskBps,
            uint256 redeemHaircutBps
        )
    {
        activeAssets_ = activeAssets;
        businessEscrow = businessEscrowAssets;
        if (businessController != address(0)) {
            reservedLoss = ISharedPoolVaultBusinessController(
                businessController
            ).globalReservedLoss();
        }
        if (reservedLoss > activeAssets_) {
            revert ReservedLossExceedsAssets();
        }

        depositPricingAssets = activeAssets_ + businessEscrow;
        redeemPricingAssets = activeAssets_ - reservedLoss;
        if (depositPricingAssets != 0) {
            depositRiskBps = Math.min(
                Math.mulDiv(
                    businessEscrow + reservedLoss,
                    10_000,
                    depositPricingAssets
                ),
                10_000
            );
        }
        if (activeAssets_ != 0) {
            redeemHaircutBps = Math.min(
                Math.mulDiv(reservedLoss, 10_000, activeAssets_),
                10_000
            );
        }
    }

    function previewRiskAdjustedDeposit(
        uint256 assets
    ) public view returns (uint256 shares, uint256 riskBps) {
        if (assets == 0) revert InvalidAmount();
        (
            ,
            ,
            ,
            uint256 pricingAssets,
            ,
            uint256 depositRiskBps,

        ) = riskAdjustedLpState();
        shares = _calculateDepositShares(
            assets,
            pricingAssets,
            totalSupply()
        );
        riskBps = depositRiskBps;
    }

    function previewRiskAdjustedRedeem(
        uint256 shares
    ) public view returns (uint256 assets, uint256 haircutBps) {
        if (shares == 0) revert InvalidAmount();
        uint256 supply = totalSupply();
        if (supply == 0) revert EmptyAssetBase();
        (
            ,
            ,
            ,
            ,
            uint256 pricingAssets,
            ,
            uint256 redeemHaircutBps
        ) = riskAdjustedLpState();
        assets = Math.mulDiv(pricingAssets, shares, supply);
        if (assets == 0) revert InvalidAmount();
        haircutBps = redeemHaircutBps;
    }

    function setBusinessController(
        address newController
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (businessController != address(0)) {
            revert BusinessControllerAlreadySet();
        }

        _validateBusinessController(newController);

        address previousController = businessController;
        businessController = newController;
        emit BusinessControllerUpdated(previousController, newController);
    }

    /// @notice Rotates to a fresh immutable controller without moving LP assets or shares.
    /// The old accounting epoch must be fully quiescent so risk or payouts cannot be reset.
    function migrateBusinessController(
        address newController
    ) external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        _migrateBusinessController(newController, true);
    }

    function _migrateBusinessController(
        address newController,
        bool requireAllClaimsWithdrawn
    ) internal {
        address previousController = businessController;
        if (
            previousController == address(0) ||
            newController == previousController
        ) {
            revert InvalidBusinessController();
        }
        if (!businessActionsFrozen()) {
            revert BusinessActionsMustBeFrozen();
        }
        if (
            _hasActiveBusinessObligations() ||
            (
                requireAllClaimsWithdrawn
                    ? totalClaimableAssets != 0
                    : unallocatedClaimableAssets != 0
            ) ||
            ISharedPoolVaultBusinessController(previousController)
                .globalOpenRoundCount() != 0
        ) {
            revert BusinessObligationsActive();
        }
        if (
            ISharedPoolVaultBusinessController(previousController)
                .riskUsed24h() != 0
        ) {
            revert BusinessRiskWindowActive();
        }

        _validateBusinessController(newController);
        if (
            ISharedPoolVaultBusinessController(newController)
                .globalOpenRoundCount() != 0 ||
            ISharedPoolVaultBusinessController(newController).riskUsed24h() !=
            0
        ) {
            revert BusinessRiskWindowActive();
        }

        uint256 previousExposureEpoch = exposureEpoch;
        exposureEpoch = previousExposureEpoch + 1;
        businessController = newController;

        emit BusinessControllerUpdated(previousController, newController);
        emit BusinessControllerMigrated(
            previousController,
            newController,
            previousExposureEpoch,
            exposureEpoch,
            activeAssets,
            totalSupply()
        );
    }

    function openBusinessRound() external nonReentrant onlyBusinessController {
        if (businessActionsFrozen()) {
            revert BusinessActionsAreFrozen();
        }

        activeBusinessRoundCount += 1;
        emit BusinessRoundOpened(activeBusinessRoundCount);
    }

    function closeBusinessRound() external nonReentrant onlyBusinessController {
        if (activeBusinessRoundCount == 0) {
            revert NoActiveBusinessRound();
        }

        activeBusinessRoundCount -= 1;
        emit BusinessRoundClosed(activeBusinessRoundCount);
    }

    function receiveBusinessEth(
        uint256 amount,
        uint256 reservedPayoutAmount
    ) external payable nonReentrant onlyBusinessController {
        if (asset != NATIVE_ASSET) {
            revert InvalidAssetTransfer();
        }
        if (businessActionsFrozen()) {
            revert BusinessActionsAreFrozen();
        }
        if (amount == 0 || msg.value != amount) {
            revert InvalidAmount();
        }
        if (totalSupply() == 0 || activeAssets == 0) {
            revert EmptyAssetBase();
        }

        businessEscrowAssets += amount;
        reservedBusinessPayout += reservedPayoutAmount;
        _enforceBusinessPayoutSolvency();

        emit BusinessAssetsReceived(msg.sender, amount, reservedPayoutAmount);
    }

    function receiveBusinessAssetFrom(
        address payer,
        uint256 amount,
        uint256 reservedPayoutAmount
    ) external nonReentrant onlyBusinessController {
        if (asset == NATIVE_ASSET) {
            revert InvalidAssetTransfer();
        }
        if (businessActionsFrozen()) {
            revert BusinessActionsAreFrozen();
        }
        if (payer == address(0)) {
            revert InvalidAddress();
        }
        if (amount == 0) {
            revert InvalidAmount();
        }
        if (totalSupply() == 0 || activeAssets == 0) {
            revert EmptyAssetBase();
        }

        _receiveAssetFrom(payer, amount);
        businessEscrowAssets += amount;
        reservedBusinessPayout += reservedPayoutAmount;
        _enforceBusinessPayoutSolvency();

        emit BusinessAssetsReceived(payer, amount, reservedPayoutAmount);
    }

    function receiveBusinessAssetWithAuthorization(
        address payer,
        uint256 amount,
        uint256 reservedPayoutAmount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 authorizationNonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant onlyBusinessController {
        if (asset == NATIVE_ASSET) revert InvalidAssetTransfer();
        if (businessActionsFrozen()) revert BusinessActionsAreFrozen();
        if (payer == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (totalSupply() == 0 || activeAssets == 0) {
            revert EmptyAssetBase();
        }

        uint256 preAssets = custodiedAssets();
        IERC3009(asset).receiveWithAuthorization(
            payer,
            address(this),
            amount,
            validAfter,
            validBefore,
            authorizationNonce,
            v,
            r,
            s
        );
        if (custodiedAssets() - preAssets != amount) {
            revert InvalidAssetTransfer();
        }
        businessEscrowAssets += amount;
        reservedBusinessPayout += reservedPayoutAmount;
        _enforceBusinessPayoutSolvency();

        emit BusinessAssetsReceived(payer, amount, reservedPayoutAmount);
    }

    function increaseBusinessPayoutReserve(
        uint256 additionalReservedPayout
    ) external nonReentrant onlyBusinessController {
        if (businessActionsFrozen()) {
            revert BusinessActionsAreFrozen();
        }
        if (additionalReservedPayout == 0) {
            revert InvalidAmount();
        }

        reservedBusinessPayout += additionalReservedPayout;
        _enforceBusinessPayoutSolvency();

        emit BusinessPayoutReserveIncreased(
            additionalReservedPayout,
            reservedBusinessPayout
        );
    }

    function settleBusinessPayoutPool(
        uint256 payoutAmount,
        uint256 receivedAmount,
        uint256 reservedPayoutAmount
    ) external nonReentrant onlyBusinessController {
        if (businessActionsFrozen()) {
            revert BusinessActionsAreFrozen();
        }
        if (payoutAmount > reservedPayoutAmount) {
            revert PayoutExceedsReserved();
        }
        if (
            receivedAmount > businessEscrowAssets ||
            reservedPayoutAmount > reservedBusinessPayout
        ) {
            revert PayoutExceedsReserved();
        }
        if (
            payoutAmount == 0 &&
            receivedAmount == 0 &&
            reservedPayoutAmount == 0
        ) {
            revert InvalidAmount();
        }

        businessEscrowAssets -= receivedAmount;
        reservedBusinessPayout -= reservedPayoutAmount;

        int256 activeAssetDelta;
        if (payoutAmount > receivedAmount) {
            uint256 vaultLoss = payoutAmount - receivedAmount;
            _decreaseActiveAssets(vaultLoss);
            activeAssetDelta = -int256(vaultLoss);
        } else {
            uint256 vaultProfit = receivedAmount - payoutAmount;
            if (vaultProfit != 0) {
                _increaseActiveAssets(vaultProfit);
                activeAssetDelta = int256(vaultProfit);
            }
        }

        if (payoutAmount > 0) {
            unallocatedClaimableAssets += payoutAmount;
            totalClaimableAssets += payoutAmount;
        }

        emit BusinessPayoutPoolSettled(
            payoutAmount,
            receivedAmount,
            reservedPayoutAmount,
            activeAssetDelta
        );
    }

    function refundBusinessPayoutPool(
        uint256 receivedAmount,
        uint256 reservedPayoutAmount
    ) external nonReentrant onlyBusinessController {
        if (businessActionsFrozen()) {
            revert BusinessActionsAreFrozen();
        }
        if (receivedAmount == 0 && reservedPayoutAmount == 0) {
            revert InvalidAmount();
        }
        if (
            receivedAmount > businessEscrowAssets ||
            reservedPayoutAmount > reservedBusinessPayout
        ) {
            revert PayoutExceedsReserved();
        }

        businessEscrowAssets -= receivedAmount;
        reservedBusinessPayout -= reservedPayoutAmount;
        if (receivedAmount != 0) {
            unallocatedClaimableAssets += receivedAmount;
            totalClaimableAssets += receivedAmount;
        }

        emit BusinessPayoutPoolSettled(
            receivedAmount,
            receivedAmount,
            reservedPayoutAmount,
            0
        );
        emit BusinessPayoutPoolRefunded(receivedAmount, reservedPayoutAmount);
    }

    function allocateBusinessPayout(
        address recipient,
        uint256 amount
    ) external nonReentrant onlyBusinessController {
        _allocateBusinessPayout(recipient, amount);
    }

    function claimBusinessPayout(
        address receiver,
        uint256 amount
    ) external nonReentrant {
        _claimBusinessPayout(msg.sender, receiver, amount);
    }

    function allocateAndClaimBusinessPayout(
        address recipient,
        address receiver,
        uint256 amount
    ) external nonReentrant onlyBusinessController {
        _allocateBusinessPayout(recipient, amount);
        _claimBusinessPayout(recipient, receiver, amount);
    }

    function deposit(
        uint256 assets,
        address receiver,
        uint256 minShares,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 shares) {
        _requireDirectLpAction(receiver, deadline);
        if (assets == 0) {
            revert InvalidAmount();
        }

        shares = _calculateDepositShares(
            assets,
            activeAssets,
            totalSupply()
        );
        if (shares < minShares) {
            revert SlippageExceeded();
        }

        _receiveAssetFrom(msg.sender, assets);
        activeAssets += assets;
        _mint(receiver, shares);

        emit DirectDeposit(
            msg.sender,
            receiver,
            assets,
            shares,
            exposureEpoch,
            activeAssets,
            totalSupply()
        );
    }

    function redeem(
        uint256 shares,
        address receiver,
        uint256 minAssets,
        uint256 deadline
    ) external nonReentrant returns (uint256 assets) {
        _requireDirectLpAction(receiver, deadline);
        if (userRedeemsFrozen()) {
            revert UserRedeemsAreFrozen();
        }
        if (shares == 0) {
            revert InvalidAmount();
        }
        if (shares > balanceOf(msg.sender)) {
            revert InsufficientShares();
        }
        uint256 supply = totalSupply();
        if (supply == 0) {
            revert EmptyAssetBase();
        }

        assets = (activeAssets * shares) / supply;
        if (assets == 0) {
            revert InvalidAmount();
        }
        if (assets < minAssets) {
            revert SlippageExceeded();
        }

        activeAssets -= assets;
        _burn(msg.sender, shares);
        _transferAsset(receiver, assets);

        emit DirectRedeem(
            msg.sender,
            receiver,
            assets,
            shares,
            exposureEpoch,
            activeAssets,
            totalSupply()
        );
    }

    function depositRiskAdjusted(
        uint256 assets,
        address receiver,
        uint256 minShares,
        uint256 maxAcceptedRiskBps,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 shares) {
        _requireRiskAdjustedLpAction(receiver, deadline);
        uint256 riskBps;
        (shares, riskBps) = previewRiskAdjustedDeposit(assets);
        if (riskBps > maxAcceptedRiskBps) revert RiskLimitExceeded();
        if (shares < minShares) revert SlippageExceeded();

        _receiveAssetFrom(msg.sender, assets);
        activeAssets += assets;
        _mint(receiver, shares);

        emit RiskAdjustedDeposit(
            msg.sender,
            assets,
            shares,
            activeAssets + businessEscrowAssets - assets,
            riskBps
        );
        emit DirectDeposit(
            msg.sender,
            receiver,
            assets,
            shares,
            exposureEpoch,
            activeAssets,
            totalSupply()
        );
    }

    function redeemRiskAdjusted(
        uint256 shares,
        address receiver,
        uint256 minAssets,
        uint256 maxAcceptedRiskBps,
        uint256 deadline
    ) external nonReentrant returns (uint256 assets) {
        _requireRiskAdjustedLpAction(receiver, deadline);
        if (userRedeemsFrozen()) revert UserRedeemsAreFrozen();
        if (shares > balanceOf(msg.sender)) revert InsufficientShares();

        uint256 haircutBps;
        (assets, haircutBps) = previewRiskAdjustedRedeem(shares);
        if (haircutBps > maxAcceptedRiskBps) revert RiskLimitExceeded();
        if (assets < minAssets) revert SlippageExceeded();

        uint256 reservedLoss = businessController == address(0)
            ? 0
            : ISharedPoolVaultBusinessController(businessController)
                .globalReservedLoss();
        if (shares == totalSupply() && reservedLoss != 0) {
            revert FinalRiskBearingShare();
        }

        uint256 pricingAssets = activeAssets - reservedLoss;
        activeAssets -= assets;
        _burn(msg.sender, shares);
        if (businessController != address(0)) {
            ISharedPoolVaultBusinessController(businessController)
                .validatePostRedeem(activeAssets);
        }
        _transferAsset(receiver, assets);

        emit RiskAdjustedRedeem(
            msg.sender,
            assets,
            shares,
            pricingAssets,
            haircutBps
        );
        emit DirectRedeem(
            msg.sender,
            receiver,
            assets,
            shares,
            exposureEpoch,
            activeAssets,
            totalSupply()
        );
    }

    function freezeUserRedeems() external virtual onlyRole(CIRCUIT_BREAKER_ROLE) {
        localUserRedeemsFrozen = true;
        emit UserRedeemsFrozen(msg.sender);
    }

    function freezeBusinessActions() external virtual onlyRole(CIRCUIT_BREAKER_ROLE) {
        localBusinessActionsFrozen = true;
        emit BusinessActionsFrozen(msg.sender);
    }

    function freezeAllOutflows() external virtual onlyRole(CIRCUIT_BREAKER_ROLE) {
        localUserRedeemsFrozen = true;
        localBusinessActionsFrozen = true;
        emit AllOutflowsFrozen(msg.sender);
    }

    function unfreezeUserRedeems() external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        localUserRedeemsFrozen = false;
        emit UserRedeemsUnfrozen(msg.sender);
    }

    function unfreezeBusinessActions() external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        localBusinessActionsFrozen = false;
        emit BusinessActionsUnfrozen(msg.sender);
    }

    function unfreezeAllOutflows() external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        localUserRedeemsFrozen = false;
        localBusinessActionsFrozen = false;
        emit AllOutflowsUnfrozen(msg.sender);
    }

    function transfer(
        address,
        uint256
    ) public virtual override returns (bool) {
        revert ShareTransferDisabled();
    }

    function transferFrom(
        address,
        address,
        uint256
    ) public virtual override returns (bool) {
        revert ShareTransferDisabled();
    }

    function _increaseActiveAssets(uint256 amount) internal {
        if (amount == 0) {
            revert InvalidAmount();
        }

        activeAssets += amount;
    }

    function _decreaseActiveAssets(uint256 amount) internal {
        if (amount == 0) {
            revert InvalidAmount();
        }
        if (amount > activeAssets) {
            revert InsufficientAvailableAssets();
        }

        activeAssets -= amount;
    }

    function _receiveAssetFrom(address payer, uint256 amount) internal {
        if (asset == NATIVE_ASSET) {
            if (msg.value != amount) {
                revert InvalidAssetTransfer();
            }
        } else {
            if (msg.value != 0) {
                revert InvalidAssetTransfer();
            }

            IERC20 token = IERC20(asset);
            uint256 preAssets = custodiedAssets();
            token.safeTransferFrom(payer, address(this), amount);
            if (custodiedAssets() - preAssets != amount) {
                revert InvalidAssetTransfer();
            }
        }
    }

    function _transferAsset(address recipient, uint256 amount) internal {
        if (asset == NATIVE_ASSET) {
            (bool success, ) = recipient.call{value: amount}("");
            if (!success) {
                revert InvalidAssetTransfer();
            }
        } else {
            IERC20(asset).safeTransfer(recipient, amount);
        }
    }

    function _calculateDepositShares(
        uint256 assets,
        uint256 preAssets,
        uint256 preSupply
    ) private pure returns (uint256 shares) {
        if (preSupply == 0) {
            return assets;
        }
        if (preAssets == 0) {
            revert EmptyAssetBase();
        }

        shares = Math.mulDiv(assets, preSupply, preAssets);
        if (shares == 0) {
            revert InvalidAmount();
        }
    }

    function _allocateBusinessPayout(
        address recipient,
        uint256 amount
    ) private {
        if (businessActionsFrozen()) {
            revert BusinessActionsAreFrozen();
        }
        if (recipient == address(0)) {
            revert InvalidAddress();
        }
        if (amount == 0) {
            revert InvalidAmount();
        }
        if (amount > unallocatedClaimableAssets) {
            revert UnallocatedPayoutExceeded();
        }

        unallocatedClaimableAssets -= amount;
        claimableAssets[recipient] += amount;

        emit BusinessPayoutAllocated(recipient, amount);
    }

    function _claimBusinessPayout(
        address account,
        address receiver,
        uint256 amount
    ) private {
        if (businessActionsFrozen()) {
            revert BusinessActionsAreFrozen();
        }
        if (account == address(0) || receiver == address(0)) {
            revert InvalidAddress();
        }
        if (amount == 0) {
            revert InvalidAmount();
        }
        if (amount > claimableAssets[account]) {
            revert ClaimableBalanceExceeded();
        }

        claimableAssets[account] -= amount;
        totalClaimableAssets -= amount;
        _transferAsset(receiver, amount);

        emit BusinessPayoutClaimed(account, receiver, amount);
    }

    function _requireDirectLpAction(
        address receiver,
        uint256 deadline
    ) private view {
        if (receiver == address(0)) {
            revert InvalidAddress();
        }
        if (receiver != msg.sender) {
            revert ThirdPartyRequestDisabled();
        }
        if (deadline < block.timestamp) {
            revert DeadlineExpired();
        }
        if (_hasActiveBusinessObligations()) {
            revert BusinessObligationsActive();
        }
    }

    function _requireRiskAdjustedLpAction(
        address receiver,
        uint256 deadline
    ) private view {
        if (receiver == address(0)) revert InvalidAddress();
        if (receiver != msg.sender) revert ThirdPartyRequestDisabled();
        if (deadline < block.timestamp) revert DeadlineExpired();
    }

    function _hasActiveBusinessObligations() private view returns (bool) {
        return
            activeBusinessRoundCount != 0 ||
            businessEscrowAssets != 0 ||
            reservedBusinessPayout != 0;
    }

    function _validateBusinessController(address controllerAddress) private view {
        if (controllerAddress == address(0)) {
            revert InvalidAddress();
        }
        if (controllerAddress.code.length == 0) {
            revert InvalidBusinessController();
        }

        ISharedPoolVaultBusinessController controller = ISharedPoolVaultBusinessController(
                controllerAddress
            );
        if (
            controller.poolVault() != address(this) ||
            controller.asset() != asset
        ) {
            revert InvalidBusinessController();
        }
    }

    function _enforceBusinessPayoutSolvency() private view {
        if (reservedBusinessPayout > activeAssets + businessEscrowAssets) {
            revert InsufficientAvailableAssets();
        }
    }

    modifier onlyBusinessController() {
        if (msg.sender != businessController) {
            revert OnlyBusinessController();
        }
        _;
    }
}
