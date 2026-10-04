// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface IDiamondCut {
    enum FacetCutAction {
        Add,
        Replace,
        Remove
    }

    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    event DiamondCut(FacetCut[] diamondCut, address init, bytes calldata_);

    function diamondCut(FacetCut[] calldata diamondCut_, address init, bytes calldata calldata_) external;
}
