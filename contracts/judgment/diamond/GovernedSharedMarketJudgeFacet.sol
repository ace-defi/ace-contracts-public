// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./SharedMarketJudgeFacet.sol";

/// @notice Fresh Hub-governed facet. Operator management remains timelocked,
/// but administration cannot be delegated to a Safe outside the Hub registry.
contract GovernedSharedMarketJudgeFacet is SharedMarketJudgeFacet {
    error FixedGovernance();

    constructor(
        address nativeController,
        address usdcController
    ) SharedMarketJudgeFacet(nativeController, usdcController) {}

    function grantRole(bytes32 role, address account) public override {
        if (role == DEFAULT_ADMIN_ROLE) revert FixedGovernance();
        super.grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public override {
        if (role == DEFAULT_ADMIN_ROLE) revert FixedGovernance();
        super.revokeRole(role, account);
    }

    function renounceRole(bytes32 role, address account) public override {
        if (role == DEFAULT_ADMIN_ROLE) revert FixedGovernance();
        super.renounceRole(role, account);
    }
}
