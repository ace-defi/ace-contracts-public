// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

library LibSharedJudgmentDiamond {
    bytes32 internal constant STORAGE_POSITION =
        keccak256("ace.shared.judgment.diamond.root.storage.v1");

    struct RootStorage {
        address timelock;
        address guardian;
        bytes32 controllerBindingsHash;
        bool startsFrozen;
    }

    function rootStorage()
        internal
        pure
        returns (RootStorage storage rs)
    {
        bytes32 position = STORAGE_POSITION;
        assembly {
            rs.slot := position
        }
    }
}
