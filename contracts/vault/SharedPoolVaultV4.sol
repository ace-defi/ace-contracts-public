// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./SharedPoolVaultV3.sol";

/// @notice Shared Pool Vault with standard transferable ERC20 LP shares.
/// @dev Transfers move only LP ownership. Assigned business payout claims remain
/// with the address to which the Controller allocated them.
contract SharedPoolVaultV4 is SharedPoolVaultV3 {
    constructor(
        string memory name_,
        string memory symbol_,
        address asset_,
        uint8 shareDecimals_,
        address admin_,
        address circuitBreaker_
    )
        SharedPoolVaultV3(
            name_,
            symbol_,
            asset_,
            shareDecimals_,
            admin_,
            circuitBreaker_
        )
    {}

    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        _transfer(_msgSender(), to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }
}
