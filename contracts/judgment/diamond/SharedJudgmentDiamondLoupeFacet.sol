// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "../../diamond/interfaces/IDiamondLoupe.sol";
import "../../diamond/libraries/LibDiamond.sol";

contract SharedJudgmentDiamondLoupeFacet is IDiamondLoupe {
    bytes32 private immutable bindingsHash;

    constructor(bytes32 bindingsHash_) {
        bindingsHash = bindingsHash_;
    }

    function sharedControllerBindingsHash() external view returns (bytes32) {
        return bindingsHash;
    }

    function facets() external view override returns (Facet[] memory facets_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        facets_ = new Facet[](ds.facetAddresses.length);
        for (uint256 i = 0; i < ds.facetAddresses.length; i++) {
            address facet = ds.facetAddresses[i];
            facets_[i] = Facet(
                facet,
                ds.facetFunctionSelectors[facet].selectors
            );
        }
    }

    function facetFunctionSelectors(
        address facet
    ) external view override returns (bytes4[] memory selectors) {
        return
            LibDiamond
                .diamondStorage()
                .facetFunctionSelectors[facet]
                .selectors;
    }

    function facetAddresses()
        external
        view
        override
        returns (address[] memory facetAddresses_)
    {
        return LibDiamond.diamondStorage().facetAddresses;
    }

    function facetAddress(
        bytes4 selector
    ) external view override returns (address facetAddress_) {
        return
            LibDiamond
                .diamondStorage()
                .selectorToFacetAndPosition[selector]
                .facetAddress;
    }
}
