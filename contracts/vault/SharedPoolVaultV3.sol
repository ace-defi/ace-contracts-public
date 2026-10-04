// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./SharedPoolVault.sol";

/// @notice Shared Pool Vault whose allocated user claims survive Controller epochs.
/// A migration still requires every settled payout to be assigned to its immutable
/// owner, but users do not need to withdraw those assigned claims first.
contract SharedPoolVaultV3 is SharedPoolVault {
    constructor(
        string memory name_,
        string memory symbol_,
        address asset_,
        uint8 shareDecimals_,
        address admin_,
        address circuitBreaker_
    )
        SharedPoolVault(
            name_,
            symbol_,
            asset_,
            shareDecimals_,
            admin_,
            circuitBreaker_
        )
    {}

    function migrateBusinessController(
        address newController
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _migrateBusinessController(newController, false);
    }
}
