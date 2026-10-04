// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface ISharedJudgmentDiamondRoot {
    function timelock() external view returns (address);

    function guardian() external view returns (address);

    function startsFrozen() external view returns (bool);

    function controllerBindingsHash() external view returns (bytes32);
}

interface ISharedJudgmentFacetBindings {
    function sharedControllerBindingsHash() external view returns (bytes32);
}

interface ITimelockDelay {
    function getMinDelay() external view returns (uint256);
}
