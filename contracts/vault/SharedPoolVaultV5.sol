// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./SharedPoolVaultV4.sol";
import "../interfaces/IGovernanceHub.sol";

/// @notice Fresh deployment only. V4 accounting with a single, immutable
/// governance authority and a shared emergency pause, not independent ACLs.
contract SharedPoolVaultV5 is SharedPoolVaultV4 {
    IGovernanceHub public immutable governanceHub;

    error UseGovernanceHub();

    constructor(
        string memory name_,
        string memory symbol_,
        address asset_,
        uint8 decimals_,
        address hub_
    ) SharedPoolVaultV4(name_, symbol_, asset_, decimals_, hub_, hub_) {
        if (hub_.code.length == 0 || IGovernanceHub(hub_).authorityEpoch() == 0)
            revert InvalidAddress();
        governanceHub = IGovernanceHub(hub_);
    }

    function userRedeemsFrozen() public view override returns (bool) {
        return governanceHub.outflowsPaused();
    }
    function businessActionsFrozen() public view override returns (bool) {
        return governanceHub.outflowsPaused();
    }

    function hasRole(
        bytes32 role,
        address account
    ) public view override returns (bool) {
        return role == DEFAULT_ADMIN_ROLE && super.hasRole(role, account);
    }

    function grantRole(bytes32, address) public pure override {
        revert UseGovernanceHub();
    }
    function revokeRole(bytes32, address) public pure override {
        revert UseGovernanceHub();
    }
    function renounceRole(bytes32, address) public pure override {
        revert UseGovernanceHub();
    }
    function freezeUserRedeems() external pure override {
        revert UseGovernanceHub();
    }
    function freezeBusinessActions() external pure override {
        revert UseGovernanceHub();
    }
    function freezeAllOutflows() external pure override {
        revert UseGovernanceHub();
    }
    function unfreezeUserRedeems() external pure override {
        revert UseGovernanceHub();
    }
    function unfreezeBusinessActions() external pure override {
        revert UseGovernanceHub();
    }
    function unfreezeAllOutflows() external pure override {
        revert UseGovernanceHub();
    }
}
