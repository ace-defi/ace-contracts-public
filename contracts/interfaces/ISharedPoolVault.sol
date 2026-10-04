// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface ISharedPoolVault {
    function asset() external view returns (address);

    function businessController() external view returns (address);

    function totalAssets() external view returns (uint256);

    function riskBackingAssets() external view returns (uint256);

    function custodiedAssets() external view returns (uint256);

    function businessEscrowAssets() external view returns (uint256);

    function reservedBusinessPayout() external view returns (uint256);

    function unallocatedClaimableAssets() external view returns (uint256);

    function totalClaimableAssets() external view returns (uint256);

    function claimableAssets(address account) external view returns (uint256);

    function exposureEpoch() external view returns (uint256);

    function activeBusinessRoundCount() external view returns (uint256);

    function previewDeposit(
        uint256 assets
    ) external view returns (uint256 shares);

    function previewRedeem(
        uint256 shares
    ) external view returns (uint256 assets);

    function riskAdjustedLpState()
        external
        view
        returns (
            uint256 activeAssets,
            uint256 businessEscrow,
            uint256 reservedLoss,
            uint256 depositPricingAssets,
            uint256 redeemPricingAssets,
            uint256 depositRiskBps,
            uint256 redeemHaircutBps
        );

    function previewRiskAdjustedDeposit(
        uint256 assets
    ) external view returns (uint256 shares, uint256 riskBps);

    function previewRiskAdjustedRedeem(
        uint256 shares
    ) external view returns (uint256 assets, uint256 haircutBps);

    function deposit(
        uint256 assets,
        address receiver,
        uint256 minShares,
        uint256 deadline
    ) external payable returns (uint256 shares);

    function redeem(
        uint256 shares,
        address receiver,
        uint256 minAssets,
        uint256 deadline
    ) external returns (uint256 assets);

    function depositRiskAdjusted(
        uint256 assets,
        address receiver,
        uint256 minShares,
        uint256 maxAcceptedRiskBps,
        uint256 deadline
    ) external payable returns (uint256 shares);

    function redeemRiskAdjusted(
        uint256 shares,
        address receiver,
        uint256 minAssets,
        uint256 maxAcceptedRiskBps,
        uint256 deadline
    ) external returns (uint256 assets);

    function openBusinessRound() external;

    function closeBusinessRound() external;

    function receiveBusinessEth(
        uint256 amount,
        uint256 reservedPayoutAmount
    ) external payable;

    function receiveBusinessAssetFrom(
        address payer,
        uint256 amount,
        uint256 reservedPayoutAmount
    ) external;

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
    ) external;

    function increaseBusinessPayoutReserve(
        uint256 additionalReservedPayout
    ) external;

    function settleBusinessPayoutPool(
        uint256 payoutAmount,
        uint256 receivedAmount,
        uint256 reservedPayoutAmount
    ) external;

    function refundBusinessPayoutPool(
        uint256 receivedAmount,
        uint256 reservedPayoutAmount
    ) external;

    function allocateBusinessPayout(address recipient, uint256 amount) external;

    function claimBusinessPayout(address receiver, uint256 amount) external;

    function allocateAndClaimBusinessPayout(
        address recipient,
        address receiver,
        uint256 amount
    ) external;
}
