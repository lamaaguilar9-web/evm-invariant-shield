// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./libraries/FullMath.sol";
import "./libraries/InvariantChecker.sol";

/// @title EVM Invariant Shield - Autonomous Non-Custodial Circuit Breaker
/// @notice Protects Ethereum L1 DeFi pools (Uniswap v3, Aave v3) against atomic flash-loans and pool drain attacks
/// @dev Implements asymmetric governance: Bot has PAUSER_ROLE; Gnosis Safe multisig (3/5) has UNPAUSER_ROLE
contract EVMInvariantShield {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    // Roles mapping
    mapping(bytes32 => mapping(address => bool)) private _roles;

    // Configuration constants
    uint256 public constant MAX_CONSECUTIVE_PAUSES = 2;
    uint256 public constant EMERGENCY_TIMEOUT = 24 hours;
    uint256 public constant DEFAULT_MAX_DROP_BPS = 1500; // 15% drop

    enum PoolState { NORMAL, PAUSED, EMERGENCY_WIND_DOWN }

    struct PoolConfig {
        bool isRegistered;
        PoolState state;
        uint256 initialK;
        uint256 lastPauseTimestamp;
        uint256 consecutivePauses;
        address poolReceiver;
    }

    mapping(address => PoolConfig) public pools;

    // Events
    event PoolRegistered(address indexed poolAddress, address indexed poolReceiver, uint256 initialK);
    event EmergencyPauseTriggered(address indexed poolAddress, uint256 currentK, uint256 dropBps, address indexed triggeredBy);
    event PoolUnpausedByMultisig(address indexed poolAddress, address indexed unpausedBy);
    event EmergencyWindDownActivated(address indexed poolAddress, uint256 timestamp);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    modifier onlyRole(bytes32 role) {
        require(hasRole(role, msg.sender), "ACCESS_CONTROL: SENDER_LACKS_ROLE");
        _;
    }

    constructor(address sentinelBot, address gnosisSafeMultisig) {
        require(sentinelBot != address(0), "INVALID_SENTINEL_BOT");
        require(gnosisSafeMultisig != address(0), "INVALID_MULTISIG");

        // Sentinel Bot has exclusively PAUSER_ROLE
        _roles[PAUSER_ROLE][sentinelBot] = true;
        emit RoleGranted(PAUSER_ROLE, sentinelBot, msg.sender);

        // Gnosis Safe multisig has UNPAUSER_ROLE and DEFAULT_ADMIN_ROLE
        _roles[UNPAUSER_ROLE][gnosisSafeMultisig] = true;
        _roles[DEFAULT_ADMIN_ROLE][gnosisSafeMultisig] = true;
        emit RoleGranted(UNPAUSER_ROLE, gnosisSafeMultisig, msg.sender);
        emit RoleGranted(DEFAULT_ADMIN_ROLE, gnosisSafeMultisig, msg.sender);
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    function grantRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _roles[role][account] = true;
        emit RoleGranted(role, account, msg.sender);
    }

    function revokeRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _roles[role][account] = false;
        emit RoleRevoked(role, account, msg.sender);
    }

    /// @notice Registers a target pool (Uniswap v3 / Aave v3 wrapper) for circuit breaker monitoring
    function registerPool(
        address poolAddress,
        address poolReceiver,
        uint256 initialReserve0,
        uint256 initialReserve1
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(poolAddress != address(0) && poolReceiver != address(0), "INVALID_ADDRESS");
        require(!pools[poolAddress].isRegistered, "ALREADY_REGISTERED");

        uint256 initialK = InvariantChecker.computeK(initialReserve0, initialReserve1);
        require(initialK > 0, "INVALID_INITIAL_K");

        pools[poolAddress] = PoolConfig({
            isRegistered: true,
            state: PoolState.NORMAL,
            initialK: initialK,
            lastPauseTimestamp: 0,
            consecutivePauses: 0,
            poolReceiver: poolReceiver
        });

        emit PoolRegistered(poolAddress, poolReceiver, initialK);
    }

    /// @notice Autonomous trigger executed by Sentinel Bot (<45ms) upon cryptographic invariant drop > 15%
    function triggerEmergencyPause(
        address poolAddress,
        uint256 currentReserve0,
        uint256 currentReserve1
    ) external onlyRole(PAUSER_ROLE) {
        PoolConfig storage config = pools[poolAddress];
        require(config.isRegistered, "POOL_NOT_REGISTERED");
        require(config.state == PoolState.NORMAL, "POOL_NOT_IN_NORMAL_STATE");
        require(config.consecutivePauses < MAX_CONSECUTIVE_PAUSES, "MAX_CONSECUTIVE_PAUSES_REACHED");

        uint256 currentK = InvariantChecker.computeK(currentReserve0, currentReserve1);
        (bool dropExceeded, uint256 dropBps) = InvariantChecker.checkInvariantDrop(
            config.initialK,
            currentK,
            DEFAULT_MAX_DROP_BPS
        );

        require(dropExceeded, "INVARIANT_DROP_NOT_EXCEEDED");

        config.state = PoolState.PAUSED;
        config.lastPauseTimestamp = block.timestamp;
        config.consecutivePauses += 1;

        // Atomically invoke pool receiver pause hook to halt swaps / LP burns
        (bool success, ) = config.poolReceiver.call(
            abi.encodeWithSignature("emergencyPause()")
        );
        require(success, "HOOK_EXECUTION_FAILED");

        emit EmergencyPauseTriggered(poolAddress, currentK, dropBps, msg.sender);
    }

    /// @notice Unpause can ONLY be executed by Gnosis Safe 3/5 Multisig after forensic review
    function unpausePool(address poolAddress, uint256 newReserve0, uint256 newReserve1) external onlyRole(UNPAUSER_ROLE) {
        PoolConfig storage config = pools[poolAddress];
        require(config.isRegistered, "POOL_NOT_REGISTERED");
        require(config.state == PoolState.PAUSED, "POOL_NOT_PAUSED");

        uint256 newK = InvariantChecker.computeK(newReserve0, newReserve1);
        require(newK > 0, "INVALID_NEW_K");

        config.state = PoolState.NORMAL;
        config.initialK = newK;
        config.consecutivePauses = 0; // Reset consecutive pauses upon multisig confirmation

        (bool success, ) = config.poolReceiver.call(
            abi.encodeWithSignature("emergencyUnpause()")
        );
        require(success, "UNPAUSE_HOOK_FAILED");

        emit PoolUnpausedByMultisig(poolAddress, msg.sender);
    }

    /// @notice Timeout degradation: after 24h, pool transitions to orderly emergency wind down
    /// @dev Does NOT auto-unpause; strictly allows user orderly exit without attacker drainage
    function activateEmergencyWindDown(address poolAddress) external {
        PoolConfig storage config = pools[poolAddress];
        require(config.isRegistered, "POOL_NOT_REGISTERED");
        require(config.state == PoolState.PAUSED, "NOT_PAUSED");
        require(block.timestamp >= config.lastPauseTimestamp + EMERGENCY_TIMEOUT, "TIMEOUT_NOT_REACHED");

        config.state = PoolState.EMERGENCY_WIND_DOWN;

        (bool success, ) = config.poolReceiver.call(
            abi.encodeWithSignature("emergencyWindDown()")
        );
        require(success, "WIND_DOWN_HOOK_FAILED");

        emit EmergencyWindDownActivated(poolAddress, block.timestamp);
    }

    /// @notice Non-custodial verification: contract rejects direct ETH and has 0 token custody
    receive() external payable {
        revert("NON_CUSTODIAL: ETH_REJECTED");
    }
}
