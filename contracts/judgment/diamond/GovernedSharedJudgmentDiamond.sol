// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./SharedJudgmentDiamond.sol";
import "../../interfaces/IGovernanceHub.sol";

interface IGovernanceBoundVault {
    function governanceHub() external view returns (address);
}

/// @notice Fresh deployment only. Identity and pause state are read from the
/// immutable Hub; the legacy root storage fields are not authority sources.
contract GovernedSharedJudgmentDiamond is SharedJudgmentDiamond {
    IGovernanceHub public immutable governanceHub;

    error UseGovernanceHub();
    error GovernanceBindingMismatch();

    constructor(
        address hub_,
        address nativeController,
        address usdcController,
        FacetCut[] memory cuts,
        address init,
        bytes memory initCalldata
    )
        SharedJudgmentDiamond(
            hub_,
            IGovernanceHub(hub_).guardian(),
            nativeController,
            usdcController,
            cuts,
            init,
            initCalldata
        )
    {
        governanceHub = IGovernanceHub(hub_);
        if (
            governanceHub.authorityEpoch() == 0 ||
            IGovernanceBoundVault(
                ISharedJudgmentLiquidityController(nativeController).poolVault()
            ).governanceHub() !=
            hub_ ||
            IGovernanceBoundVault(
                ISharedJudgmentLiquidityController(usdcController).poolVault()
            ).governanceHub() !=
            hub_
        ) revert GovernanceBindingMismatch();
    }

    function timelock() public view override returns (address) {
        return address(governanceHub);
    }
    function guardian() public view override returns (address) {
        return governanceHub.guardian();
    }
    function startsFrozen() public view override returns (bool) {
        return governanceHub.emergencyPaused();
    }
    function freezeStarts() external pure override {
        revert UseGovernanceHub();
    }
    function unfreezeStarts() external pure override {
        revert UseGovernanceHub();
    }

    function _isRootSelector(
        bytes4 selector
    ) internal pure override returns (bool) {
        return
            selector == bytes4(keccak256("governanceHub()")) ||
            super._isRootSelector(selector);
    }
}
