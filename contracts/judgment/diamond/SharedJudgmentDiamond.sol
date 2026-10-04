// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "../../diamond/interfaces/IDiamondCut.sol";
import "../../diamond/libraries/LibDiamond.sol";
import "../../interfaces/ISharedJudgmentLiquidityController.sol";
import "../../interfaces/ISharedPoolVault.sol";
import "./ISharedJudgmentDiamondRoot.sol";
import "./LibSharedJudgmentDiamond.sol";

/// @notice EIP-2535 shared Judge with an immutable diamondCut root. Vault and
/// controller code remain directly deployed and cannot be replaced by this Diamond.
contract SharedJudgmentDiamond is IDiamondCut {
    ISharedJudgmentLiquidityController private immutable nativeController_;
    ISharedJudgmentLiquidityController private immutable usdcController_;
    ISharedPoolVault private immutable nativeVault_;
    ISharedPoolVault private immutable usdcVault_;

    event StartsFrozen(address indexed guardian);
    event StartsUnfrozen(address indexed timelock);

    error InvalidAddress();
    error InvalidControllerBinding();
    error InvalidFacetBinding();
    error InvalidTimelock();
    error OnlyTimelock();
    error OnlyGuardian();
    error StartsMustBeFrozen();
    error OpenObligations();
    error RootSelectorImmutable();
    error InvalidInitialization();
    error DirectNativeTransferDisabled();

    constructor(
        address timelock_,
        address guardian_,
        address nativeControllerAddress,
        address usdcControllerAddress,
        FacetCut[] memory initialCut,
        address init,
        bytes memory initCalldata
    ) payable {
        if (
            timelock_ == address(0) ||
            guardian_ == address(0) ||
            timelock_ == guardian_ ||
            nativeControllerAddress == address(0) ||
            usdcControllerAddress == address(0) ||
            nativeControllerAddress == usdcControllerAddress
        ) {
            revert InvalidAddress();
        }
        if (timelock_.code.length == 0) revert InvalidTimelock();
        try ITimelockDelay(timelock_).getMinDelay() returns (uint256) {} catch {
            revert InvalidTimelock();
        }

        nativeController_ = ISharedJudgmentLiquidityController(
            nativeControllerAddress
        );
        usdcController_ = ISharedJudgmentLiquidityController(
            usdcControllerAddress
        );
        nativeVault_ = ISharedPoolVault(nativeController_.poolVault());
        usdcVault_ = ISharedPoolVault(usdcController_.poolVault());
        if (
            nativeController_.asset() != address(0) ||
            usdcController_.asset() == address(0) ||
            address(nativeVault_) == address(0) ||
            address(usdcVault_) == address(0) ||
            address(nativeVault_) == address(usdcVault_) ||
            nativeVault_.asset() != address(0) ||
            usdcVault_.asset() != usdcController_.asset()
        ) {
            revert InvalidControllerBinding();
        }

        LibSharedJudgmentDiamond.RootStorage storage rs = LibSharedJudgmentDiamond
            .rootStorage();
        rs.timelock = timelock_;
        rs.guardian = guardian_;
        rs.controllerBindingsHash = _expectedBindingsHash();
        rs.startsFrozen = true;
        LibDiamond.setContractOwner(timelock_);

        _validateFacetBindings(initialCut);
        _validateInitialization(init, initCalldata, timelock_);
        LibDiamond.diamondCut(initialCut, init, initCalldata);
    }

    function diamondCut(
        FacetCut[] calldata diamondCut_,
        address init,
        bytes calldata initCalldata
    ) external override {
        _enforceTimelock();
        if (!startsFrozen()) revert StartsMustBeFrozen();
        _enforceNoOpenObligations();
        _validateFacetBindings(diamondCut_);
        if (init != address(0)) _validateFacetBinding(init);
        LibDiamond.diamondCut(diamondCut_, init, initCalldata);
    }

    function freezeStarts() external virtual {
        if (msg.sender != guardian()) revert OnlyGuardian();
        LibSharedJudgmentDiamond.rootStorage().startsFrozen = true;
        emit StartsFrozen(msg.sender);
    }

    function unfreezeStarts() external virtual {
        _enforceTimelock();
        LibSharedJudgmentDiamond.rootStorage().startsFrozen = false;
        emit StartsUnfrozen(msg.sender);
    }

    function timelock() public view virtual returns (address) {
        return LibSharedJudgmentDiamond.rootStorage().timelock;
    }

    function guardian() public view virtual returns (address) {
        return LibSharedJudgmentDiamond.rootStorage().guardian;
    }

    function startsFrozen() public view virtual returns (bool) {
        return LibSharedJudgmentDiamond.rootStorage().startsFrozen;
    }

    function controllerBindingsHash() public view returns (bytes32) {
        return
            LibSharedJudgmentDiamond
                .rootStorage()
                .controllerBindingsHash;
    }

    function _validateFacetBindings(FacetCut[] memory cuts) private view {
        for (uint256 i = 0; i < cuts.length; i++) {
            for (uint256 j = 0; j < cuts[i].functionSelectors.length; j++) {
                if (_isRootSelector(cuts[i].functionSelectors[j])) {
                    revert RootSelectorImmutable();
                }
            }
            if (cuts[i].action == FacetCutAction.Remove) continue;
            _validateFacetBinding(cuts[i].facetAddress);
        }
    }

    function _validateFacetBinding(address facet) private view {
        if (facet == address(0) || facet.code.length == 0) {
            revert InvalidFacetBinding();
        }
        try
            ISharedJudgmentFacetBindings(facet)
                .sharedControllerBindingsHash()
        returns (bytes32 actual) {
            if (actual != controllerBindingsHash()) {
                revert InvalidFacetBinding();
            }
        } catch {
            revert InvalidFacetBinding();
        }
    }

    function _validateInitialization(
        address init,
        bytes memory initCalldata,
        address expectedAdmin
    ) private view {
        if (initCalldata.length != 68) revert InvalidInitialization();
        _validateFacetBinding(init);

        bytes4 selector;
        address admin;
        address operator;
        assembly {
            selector := mload(add(initCalldata, 32))
            admin := mload(add(initCalldata, 36))
            operator := mload(add(initCalldata, 68))
        }
        if (
            selector != bytes4(keccak256("initialize(address,address)")) ||
            admin != expectedAdmin ||
            operator == address(0)
        ) {
            revert InvalidInitialization();
        }
    }

    function _enforceNoOpenObligations() private view {
        if (
            nativeController_.globalOpenRoundCount() != 0 ||
            usdcController_.globalOpenRoundCount() != 0 ||
            nativeController_.globalReservedLoss() != 0 ||
            usdcController_.globalReservedLoss() != 0 ||
            nativeVault_.activeBusinessRoundCount() != 0 ||
            usdcVault_.activeBusinessRoundCount() != 0 ||
            nativeVault_.businessEscrowAssets() != 0 ||
            usdcVault_.businessEscrowAssets() != 0 ||
            nativeVault_.reservedBusinessPayout() != 0 ||
            usdcVault_.reservedBusinessPayout() != 0 ||
            nativeVault_.unallocatedClaimableAssets() != 0 ||
            usdcVault_.unallocatedClaimableAssets() != 0
        ) {
            revert OpenObligations();
        }
    }

    function _enforceTimelock() private view {
        if (msg.sender != timelock()) revert OnlyTimelock();
    }

    function _expectedBindingsHash() private view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    block.chainid,
                    address(nativeController_),
                    address(usdcController_),
                    address(nativeVault_),
                    address(usdcVault_)
                )
            );
    }

    function _isRootSelector(bytes4 selector) internal pure virtual returns (bool) {
        return
            selector == IDiamondCut.diamondCut.selector ||
            selector == bytes4(keccak256("freezeStarts()")) ||
            selector == bytes4(keccak256("unfreezeStarts()")) ||
            selector == bytes4(keccak256("timelock()")) ||
            selector == bytes4(keccak256("guardian()")) ||
            selector == bytes4(keccak256("startsFrozen()")) ||
            selector == bytes4(keccak256("controllerBindingsHash()"));
    }

    receive() external payable {
        revert DirectNativeTransferDisabled();
    }

    fallback() external payable {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        address facet = ds
            .selectorToFacetAndPosition[msg.sig]
            .facetAddress;
        require(facet != address(0), "SharedJudgmentDiamond: selector missing");
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(
                gas(),
                facet,
                0,
                calldatasize(),
                0,
                0
            )
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }
}
