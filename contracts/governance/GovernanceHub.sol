// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @notice Fresh-deployment governance: Admin schedules, Guardian/Recovery
/// reviews and executes, and the two non-target parties can replace a party.
/// @dev No external role administration, upgrade hook, or recovery call target.
contract GovernanceHub is TimelockController, ReentrancyGuard {
    enum Party {
        Admin,
        Guardian,
        Recovery
    }

    address public admin;
    address public guardian;
    address public recovery;
    uint256 public authorityEpoch = 1;
    bool public emergencyPaused = true;
    bool public outflowsPaused = true;
    uint256 public pauseNonce = 1;

    mapping(bytes32 => uint256) public operationEpoch;
    mapping(bytes32 => uint8) public recoveryApprovals;

    event OperationEpoch(bytes32 indexed id, uint256 indexed epoch);
    event EmergencyPaused(address indexed caller, uint256 pauseNonce);
    event OutflowsPaused(address indexed caller, uint256 pauseNonce);
    event EmergencyUnpaused(uint256 pauseNonce);
    event RecoveryApproved(bytes32 indexed id, address indexed approver);
    event RecoveryApprovalRevoked(bytes32 indexed id, address indexed approver);
    event PartyReplaced(
        Party indexed party,
        address indexed previous,
        address indexed replacement,
        uint256 epoch
    );

    error InvalidPartyAddress();
    error FixedGovernance();
    error OnlyGuardian();
    error OnlySelf();
    error StalePause();
    error OperationIdUsed();
    error StaleOperation();
    error InvalidRecovery();
    error OnlyOtherParties();
    error DuplicateApproval();

    constructor(
        uint256 delay,
        address admin_,
        address guardian_,
        address recovery_
    )
        TimelockController(
            delay,
            new address[](0),
            new address[](0),
            address(0)
        )
    {
        if (delay == 0) revert FixedGovernance();
        _validateParty(admin_);
        _validateParty(guardian_);
        _validateParty(recovery_);
        if (
            admin_ == guardian_ || admin_ == recovery_ || guardian_ == recovery_
        ) {
            revert InvalidPartyAddress();
        }
        admin = admin_;
        guardian = guardian_;
        recovery = recovery_;
        emit EmergencyPaused(msg.sender, pauseNonce);
    }

    /// @dev The registry is authoritative; inherited AccessControl storage is
    /// never an alternative path to proposer, executor, or canceller authority.
    function hasRole(
        bytes32 role,
        address account
    ) public view override returns (bool) {
        if (account == address(0)) return false;
        if (role == PROPOSER_ROLE) return account == admin;
        if (role == EXECUTOR_ROLE)
            return account == guardian || account == recovery;
        if (role == CANCELLER_ROLE) return account == guardian;
        return false;
    }

    function grantRole(bytes32, address) public pure override {
        revert FixedGovernance();
    }
    function revokeRole(bytes32, address) public pure override {
        revert FixedGovernance();
    }
    function renounceRole(bytes32, address) public pure override {
        revert FixedGovernance();
    }
    function updateDelay(uint256) external pure override {
        revert FixedGovernance();
    }

    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override nonReentrant {
        _registerOperation(
            hashOperation(target, value, data, predecessor, salt)
        );
        super.schedule(target, value, data, predecessor, salt, delay);
    }

    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override nonReentrant {
        _registerOperation(
            hashOperationBatch(targets, values, data, predecessor, salt)
        );
        super.scheduleBatch(targets, values, data, predecessor, salt, delay);
    }

    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) public payable override nonReentrant {
        _checkOperation(hashOperation(target, value, data, predecessor, salt));
        super.execute(target, value, data, predecessor, salt);
    }

    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) public payable override nonReentrant {
        _checkOperation(
            hashOperationBatch(targets, values, data, predecessor, salt)
        );
        super.executeBatch(targets, values, data, predecessor, salt);
    }

    function cancel(bytes32 id) public override nonReentrant {
        super.cancel(id);
    }

    function getTimestamp(bytes32 id) public view override returns (uint256) {
        uint256 timestamp = super.getTimestamp(id);
        // Retain completed history, but hide invalidated pending/ready entries.
        if (timestamp > _DONE_TIMESTAMP && operationEpoch[id] != authorityEpoch)
            return 0;
        return timestamp;
    }

    function isOperationInvalidated(bytes32 id) external view returns (bool) {
        return
            super.getTimestamp(id) > _DONE_TIMESTAMP &&
            operationEpoch[id] != authorityEpoch;
    }

    function pause() external nonReentrant {
        if (msg.sender != guardian) revert OnlyGuardian();
        _pause();
    }

    /// @notice Escalate a starts-only pause to freeze Vault business and exits.
    function pauseAll() external nonReentrant {
        if (msg.sender != guardian) revert OnlyGuardian();
        _pauseAll();
    }

    /// @notice Only an ordinary, delayed governance operation can unpause.
    /// Bind the approval to the incident so an old unpause cannot undo a new pause.
    function unpause(uint256 expectedPauseNonce) external {
        if (msg.sender != address(this)) revert OnlySelf();
        if (!emergencyPaused || expectedPauseNonce != pauseNonce)
            revert StalePause();
        emergencyPaused = false;
        outflowsPaused = false;
        emit EmergencyUnpaused(pauseNonce);
    }

    function hashRecovery(
        Party party,
        address expectedOld,
        address replacement,
        uint256 epoch,
        uint256 deadline,
        bytes32 salt
    ) public view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    block.chainid,
                    address(this),
                    party,
                    expectedOld,
                    replacement,
                    epoch,
                    deadline,
                    salt
                )
            );
    }

    /// @notice Second matching approval performs the entire recovery. This path
    /// has no external calls, asset movement, arbitrary payload, or queue entry.
    function approveRecovery(
        Party party,
        address expectedOld,
        address replacement,
        uint256 epoch,
        uint256 deadline,
        bytes32 salt
    ) external nonReentrant {
        if (
            epoch != authorityEpoch ||
            block.timestamp > deadline ||
            expectedOld != _party(party)
        ) revert InvalidRecovery();
        _validateParty(replacement);
        if (
            replacement == admin ||
            replacement == guardian ||
            replacement == recovery
        ) revert InvalidPartyAddress();
        uint8 vote = _voterBit();
        uint8 required = uint8(7) ^ uint8(1 << uint8(party));
        if (vote & required == 0) revert OnlyOtherParties();
        bytes32 id = hashRecovery(
            party,
            expectedOld,
            replacement,
            epoch,
            deadline,
            salt
        );
        uint8 approvals = recoveryApprovals[id];
        if (approvals & vote != 0) revert DuplicateApproval();
        approvals |= vote;
        recoveryApprovals[id] = approvals;
        emit RecoveryApproved(id, msg.sender);
        if (approvals != required) return;

        if (party == Party.Admin) admin = replacement;
        else if (party == Party.Guardian) guardian = replacement;
        else recovery = replacement;
        authorityEpoch++;
        _pauseAll();
        emit PartyReplaced(party, expectedOld, replacement, authorityEpoch);
    }

    /// @dev A party can withdraw only its own approval, never someone else's.
    function revokeRecoveryApproval(bytes32 id) external nonReentrant {
        uint8 vote = _voterBit();
        recoveryApprovals[id] &= ~vote;
        emit RecoveryApprovalRevoked(id, msg.sender);
    }

    function _registerOperation(bytes32 id) private {
        // Never recycle an id: otherwise old Safe execution payloads could
        // become executable again after a rotation or cancellation.
        if (operationEpoch[id] != 0) revert OperationIdUsed();
        operationEpoch[id] = authorityEpoch;
        emit OperationEpoch(id, authorityEpoch);
    }

    function _checkOperation(bytes32 id) private view {
        if (operationEpoch[id] != authorityEpoch) revert StaleOperation();
    }

    function _pause() private {
        emergencyPaused = true;
        pauseNonce++;
        emit EmergencyPaused(msg.sender, pauseNonce);
    }

    function _pauseAll() private {
        outflowsPaused = true;
        _pause();
        emit OutflowsPaused(msg.sender, pauseNonce);
    }

    function _validateParty(address account) private view {
        if (account == address(this) || account.code.length == 0)
            revert InvalidPartyAddress();
    }

    function _party(Party party) private view returns (address) {
        if (party == Party.Admin) return admin;
        if (party == Party.Guardian) return guardian;
        return recovery;
    }

    function _voterBit() private view returns (uint8) {
        if (msg.sender == admin) return 1;
        if (msg.sender == guardian) return 2;
        if (msg.sender == recovery) return 4;
        revert OnlyOtherParties();
    }
}
