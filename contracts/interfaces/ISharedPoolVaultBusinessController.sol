// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface ISharedPoolVaultBusinessController {
    function poolVault() external view returns (address);

    function asset() external view returns (address);

    function globalReservedLoss() external view returns (uint256);

    function globalOpenRoundCount() external view returns (uint256);

    function riskUsed24h() external view returns (uint256);

    function validatePostRedeem(uint256 activeAssetsAfter) external view;
}
