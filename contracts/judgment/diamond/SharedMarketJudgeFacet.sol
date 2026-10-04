// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../SharedMarketJudgeCore.sol";
import "./ISharedJudgmentDiamondRoot.sol";

/// @notice Current shared Judge business facet. The facet's immutable controller
/// bindings are checked by the Diamond root on every add/replace cut.
contract SharedMarketJudgeFacet is SharedMarketJudgeCore, Initializable {
    uint256 public constant MAX_CLAIM_BATCH = 32;
    bytes32 private immutable bindingsHash;

    error InvalidBatchSize();
    error StartsAreFrozen();
    error InvalidDiamondAdmin();

    constructor(
        address nativeController_,
        address usdcController_
    )
        SharedMarketJudgeCore(
            nativeController_,
            usdcController_,
            address(1),
            address(1)
        )
    {
        bindingsHash = keccak256(
            abi.encode(
                block.chainid,
                nativeController_,
                usdcController_,
                address(nativeVault),
                address(usdcVault)
            )
        );
        _disableInitializers();
    }

    function initialize(
        address admin,
        address operator
    ) external initializer {
        // The Diamond constructor performs the binding and timelock checks before
        // delegatecalling this initializer. During construction, an external call
        // back into address(this) cannot dispatch through the not-yet-deployed root.
        if (admin == address(0) || operator == address(0)) {
            revert InvalidDiamondAdmin();
        }
        nextJudgmentId = 1;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
    }

    function sharedControllerBindingsHash() external view returns (bytes32) {
        return bindingsHash;
    }

    /// @notice Assigns settled payouts owned by the caller. While starts are
    /// frozen, an operator may materialize payouts for upgrade drains.
    /// Already-materialized judgments are skipped so maintenance/user races
    /// are benign.
    function claimAll(uint256[] calldata judgmentIds) external nonReentrant {
        bool maintenanceMaterializer = ISharedJudgmentDiamondRoot(address(this))
            .startsFrozen() &&
            hasRole(OPERATOR_ROLE, msg.sender);
        _claimAll(judgmentIds, address(0), false, maintenanceMaterializer);
    }

    function claimAllAndWithdraw(
        uint256[] calldata judgmentIds,
        address receiver
    ) external nonReentrant {
        if (receiver == address(0)) revert InvalidAddress();
        _claimAll(judgmentIds, receiver, true, false);
    }

    function _claimAll(
        uint256[] calldata judgmentIds,
        address receiver,
        bool withdraw,
        bool maintenanceMaterializer
    ) private {
        // Maintenance authority applies only to materialization. The withdraw
        // branch always enforces Judgment ownership in _resolveOwnedJudgment.
        uint256 length = judgmentIds.length;
        if (length == 0 || length > MAX_CLAIM_BATCH) {
            revert InvalidBatchSize();
        }
        for (uint256 i = 0; i < length; i++) {
            if (withdraw) {
                _resolveOwnedJudgment(judgmentIds[i], receiver, true);
            } else {
                _materializeJudgmentPayout(
                    judgmentIds[i],
                    maintenanceMaterializer
                );
            }
        }
    }

    function _beforeStartMarketRound() internal view override {
        if (ISharedJudgmentDiamondRoot(address(this)).startsFrozen()) {
            revert StartsAreFrozen();
        }
    }

    function _usesSharedAssetOdds() internal pure override returns (bool) {
        return true;
    }

    function _isRoundStartScheduleAllowed(
        uint256,
        uint256
    ) internal pure override returns (bool) {
        return true;
    }
}
