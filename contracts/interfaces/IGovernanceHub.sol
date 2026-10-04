// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface IGovernanceHub {
    function guardian() external view returns (address);
    function emergencyPaused() external view returns (bool);
    function outflowsPaused() external view returns (bool);
    function authorityEpoch() external view returns (uint256);
}
