// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "../interfaces/IDiamondCut.sol";

library LibDiamond {
    bytes32 internal constant DIAMOND_STORAGE_POSITION = keccak256("ace.contracts.diamond.storage");

    struct FacetAddressAndPosition {
        address facetAddress;
        uint96 selectorPosition;
    }

    struct FacetFunctionSelectors {
        bytes4[] selectors;
        uint256 facetAddressPosition;
    }

    struct DiamondStorage {
        address contractOwner;
        mapping(bytes4 => FacetAddressAndPosition) selectorToFacetAndPosition;
        mapping(address => FacetFunctionSelectors) facetFunctionSelectors;
        address[] facetAddresses;
    }

    error NotContractOwner();
    error InvalidFacetCut();
    error FunctionAlreadyExists();
    error FunctionDoesNotExist();
    error CannotReplaceFunctionWithSameFacet();
    error CannotRemoveImmutableFunction();
    error FacetHasNoCode();
    error InitializationFailed();

    event DiamondCut(IDiamondCut.FacetCut[] diamondCut, address init, bytes calldata_);

    function diamondStorage() internal pure returns (DiamondStorage storage ds) {
        bytes32 position = DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    function setContractOwner(address newOwner) internal {
        diamondStorage().contractOwner = newOwner;
    }

    function enforceIsContractOwner() internal view {
        if (msg.sender != diamondStorage().contractOwner) {
            revert NotContractOwner();
        }
    }

    function diamondCut(IDiamondCut.FacetCut[] memory diamondCut_, address init, bytes memory calldata_) internal {
        for (uint256 i = 0; i < diamondCut_.length; i++) {
            IDiamondCut.FacetCutAction action = diamondCut_[i].action;
            if (action == IDiamondCut.FacetCutAction.Add) {
                addFunctions(diamondCut_[i].facetAddress, diamondCut_[i].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Replace) {
                replaceFunctions(diamondCut_[i].facetAddress, diamondCut_[i].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Remove) {
                removeFunctions(diamondCut_[i].facetAddress, diamondCut_[i].functionSelectors);
            } else {
                revert InvalidFacetCut();
            }
        }

        emit DiamondCut(diamondCut_, init, calldata_);
        initializeDiamondCut(init, calldata_);
    }

    function addFunctions(address facetAddress, bytes4[] memory selectors) internal {
        if (selectors.length == 0 || facetAddress == address(0)) {
            revert InvalidFacetCut();
        }
        enforceHasContractCode(facetAddress);

        DiamondStorage storage ds = diamondStorage();
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[facetAddress].selectors.length);
        if (selectorPosition == 0) {
            ds.facetFunctionSelectors[facetAddress].facetAddressPosition = ds.facetAddresses.length;
            ds.facetAddresses.push(facetAddress);
        }

        for (uint256 i = 0; i < selectors.length; i++) {
            bytes4 selector = selectors[i];
            if (ds.selectorToFacetAndPosition[selector].facetAddress != address(0)) {
                revert FunctionAlreadyExists();
            }
            ds.facetFunctionSelectors[facetAddress].selectors.push(selector);
            ds.selectorToFacetAndPosition[selector] = FacetAddressAndPosition(facetAddress, selectorPosition);
            selectorPosition++;
        }
    }

    function replaceFunctions(address facetAddress, bytes4[] memory selectors) internal {
        if (selectors.length == 0 || facetAddress == address(0)) {
            revert InvalidFacetCut();
        }
        enforceHasContractCode(facetAddress);

        DiamondStorage storage ds = diamondStorage();
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[facetAddress].selectors.length);
        if (selectorPosition == 0) {
            ds.facetFunctionSelectors[facetAddress].facetAddressPosition = ds.facetAddresses.length;
            ds.facetAddresses.push(facetAddress);
        }

        for (uint256 i = 0; i < selectors.length; i++) {
            bytes4 selector = selectors[i];
            address oldFacetAddress = ds.selectorToFacetAndPosition[selector].facetAddress;
            if (oldFacetAddress == facetAddress) {
                revert CannotReplaceFunctionWithSameFacet();
            }
            removeFunction(ds, oldFacetAddress, selector);
            ds.facetFunctionSelectors[facetAddress].selectors.push(selector);
            ds.selectorToFacetAndPosition[selector] = FacetAddressAndPosition(facetAddress, selectorPosition);
            selectorPosition++;
        }
    }

    function removeFunctions(address facetAddress, bytes4[] memory selectors) internal {
        if (selectors.length == 0 || facetAddress != address(0)) {
            revert InvalidFacetCut();
        }

        DiamondStorage storage ds = diamondStorage();
        for (uint256 i = 0; i < selectors.length; i++) {
            bytes4 selector = selectors[i];
            address oldFacetAddress = ds.selectorToFacetAndPosition[selector].facetAddress;
            removeFunction(ds, oldFacetAddress, selector);
        }
    }

    function removeFunction(DiamondStorage storage ds, address facetAddress, bytes4 selector) internal {
        if (facetAddress == address(0)) {
            revert FunctionDoesNotExist();
        }
        if (facetAddress == address(this)) {
            revert CannotRemoveImmutableFunction();
        }

        uint256 selectorPosition = ds.selectorToFacetAndPosition[selector].selectorPosition;
        uint256 lastSelectorPosition = ds.facetFunctionSelectors[facetAddress].selectors.length - 1;
        if (selectorPosition != lastSelectorPosition) {
            bytes4 lastSelector = ds.facetFunctionSelectors[facetAddress].selectors[lastSelectorPosition];
            ds.facetFunctionSelectors[facetAddress].selectors[selectorPosition] = lastSelector;
            ds.selectorToFacetAndPosition[lastSelector].selectorPosition = uint96(selectorPosition);
        }

        ds.facetFunctionSelectors[facetAddress].selectors.pop();
        delete ds.selectorToFacetAndPosition[selector];

        if (lastSelectorPosition == 0) {
            uint256 lastFacetAddressPosition = ds.facetAddresses.length - 1;
            uint256 facetAddressPosition = ds.facetFunctionSelectors[facetAddress].facetAddressPosition;
            if (facetAddressPosition != lastFacetAddressPosition) {
                address lastFacetAddress = ds.facetAddresses[lastFacetAddressPosition];
                ds.facetAddresses[facetAddressPosition] = lastFacetAddress;
                ds.facetFunctionSelectors[lastFacetAddress].facetAddressPosition = facetAddressPosition;
            }
            ds.facetAddresses.pop();
            delete ds.facetFunctionSelectors[facetAddress].facetAddressPosition;
        }
    }

    function initializeDiamondCut(address init, bytes memory calldata_) internal {
        if (init == address(0)) {
            return;
        }
        enforceHasContractCode(init);
        (bool success, ) = init.delegatecall(calldata_);
        if (!success) {
            revert InitializationFailed();
        }
    }

    function enforceHasContractCode(address contractAddress) internal view {
        uint256 contractSize;
        assembly {
            contractSize := extcodesize(contractAddress)
        }
        if (contractSize == 0) {
            revert FacetHasNoCode();
        }
    }
}
