// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./libraries/UniswapV3InvariantChecker.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/AggregatorV3Interface.sol";

/// @title EVM Invariant Shield v1.4.0 - Circuit Breaker con Verificación On-Chain
contract EVMInvariantShield {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    mapping(bytes32 => mapping(address => bool)) private _roles;

    uint256 public constant MAX_CONSECUTIVE_PAUSES = 2;
    uint256 public constant EMERGENCY_TIMEOUT = 24 hours;
    uint256 public constant DEFAULT_MAX_DEVIATION_BPS = 1500; // 15%
    int24 public constant DEFAULT_MAX_TICK_DELTA = 1625;

    enum PoolState { NORMAL, PAUSED, EMERGENCY_WIND_DOWN }

    struct TargetConfig {
        bool isRegistered;
        PoolState state;
        address poolReceiver;
        address chainlinkFeed;
        uint160 initialSqrtPriceX96;
        int24 initialTick;
        uint256 lastPauseTimestamp;
        uint256 consecutivePauses;
    }

    mapping(address => TargetConfig) public targets;

    event TargetRegistered(address indexed targetPool, address indexed poolReceiver, address chainlinkFeed);
    event EmergencyPauseTriggered(address indexed targetPool, uint160 currentSqrtPriceX96, address indexed triggeredBy);
    event TargetUnpausedByMultisig(address indexed targetPool, address indexed unpausedBy);
    event EmergencyWindDownActivated(address indexed targetPool, uint256 timestamp);
    event RoleGranted(bytes32 indexed role, address indexed account);
    event RoleRevoked(bytes32 indexed role, address indexed account);

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "ACCESS_CONTROL: SENDER_LACKS_ROLE");
        _;
    }

    constructor(address sentinelBot, address gnosisSafeMultisig) {
        require(sentinelBot != address(0) && gnosisSafeMultisig != address(0), "INVALID_ADDRESS");
        _roles[PAUSER_ROLE][sentinelBot] = true;
        _roles[UNPAUSER_ROLE][gnosisSafeMultisig] = true;
        _roles[DEFAULT_ADMIN_ROLE][gnosisSafeMultisig] = true;

        emit RoleGranted(PAUSER_ROLE, sentinelBot);
        emit RoleGranted(UNPAUSER_ROLE, gnosisSafeMultisig);
        emit RoleGranted(DEFAULT_ADMIN_ROLE, gnosisSafeMultisig);
    }

    function grantRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _roles[role][account] = true;
        emit RoleGranted(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _roles[role][account] = false;
        emit RoleRevoked(role, account);
    }

    function registerTarget(
        address targetPool,
        address poolReceiver,
        address chainlinkFeed
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(targetPool != address(0) && poolReceiver != address(0), "INVALID_ADDRESS");
        require(!targets[targetPool].isRegistered, "ALREADY_REGISTERED");

        (uint160 sqrtPriceX96, int24 tick,,,,,) = IUniswapV3Pool(targetPool).slot0();
        require(sqrtPriceX96 > 0, "INVALID_SQRT_PRICE");

        targets[targetPool] = TargetConfig({
            isRegistered: true,
            state: PoolState.NORMAL,
            poolReceiver: poolReceiver,
            chainlinkFeed: chainlinkFeed,
            initialSqrtPriceX96: sqrtPriceX96,
            initialTick: tick,
            lastPauseTimestamp: 0,
            consecutivePauses: 0
        });

        emit TargetRegistered(targetPool, poolReceiver, chainlinkFeed);
    }

    function triggerEmergencyPause(address targetPool) external onlyRole(PAUSER_ROLE) {
        TargetConfig storage config = targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(config.state == PoolState.NORMAL, "NOT_NORMAL");
        require(config.consecutivePauses < MAX_CONSECUTIVE_PAUSES, "MAX_PAUSES_REACHED");

        (uint160 currentSqrtPriceX96, int24 currentTick,,,,,) = IUniswapV3Pool(targetPool).slot0();

        (bool dropExceeded, ) = UniswapV3InvariantChecker.checkExactPriceDrop(
            config.initialSqrtPriceX96,
            currentSqrtPriceX96,
            DEFAULT_MAX_DEVIATION_BPS
        );

        (bool tickExceeded, ) = UniswapV3InvariantChecker.checkTickDelta(
            config.initialTick,
            currentTick,
            DEFAULT_MAX_TICK_DELTA
        );

        require(dropExceeded || tickExceeded, "INVARIANT_HEALTHY");

        config.state = PoolState.PAUSED;
        config.lastPauseTimestamp = block.timestamp;
        config.consecutivePauses += 1;

        (bool success, ) = config.poolReceiver.call(abi.encodeWithSignature("emergencyPause()"));
        require(success, "WRAPPER_PAUSE_FAILED");

        emit EmergencyPauseTriggered(targetPool, currentSqrtPriceX96, msg.sender);
    }

    /// @notice Despausado reforzado con validación de oráculo Chainlink on-chain
    function unpauseTargetWithOracle(
        address targetPool,
        uint160 minAcceptableSqrtPrice,
        uint256 maxOracleAge
    ) external onlyRole(UNPAUSER_ROLE) {
        TargetConfig storage config = targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(config.state == PoolState.PAUSED, "NOT_PAUSED");

        (uint160 currentSqrtPriceX96, int24 newTick,,,,,) = IUniswapV3Pool(targetPool).slot0();
        require(currentSqrtPriceX96 >= minAcceptableSqrtPrice, "MARKET_NOT_RESTORED");

        if (config.chainlinkFeed != address(0)) {
            (, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(config.chainlinkFeed).latestRoundData();
            require(price > 0, "INVALID_ORACLE_PRICE");
            require(block.timestamp - updatedAt <= maxOracleAge, "STALE_ORACLE_PRICE");
        }

        config.initialSqrtPriceX96 = currentSqrtPriceX96;
        config.initialTick = newTick;
        config.state = PoolState.NORMAL;
        config.consecutivePauses = 0;

        (bool success, ) = config.poolReceiver.call(abi.encodeWithSignature("emergencyUnpause()"));
        require(success, "WRAPPER_UNPAUSE_FAILED");

        emit TargetUnpausedByMultisig(targetPool, msg.sender);
    }

    function activateEmergencyWindDown(address targetPool) external {
        TargetConfig storage config = targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(config.state == PoolState.PAUSED, "NOT_PAUSED");
        require(block.timestamp >= config.lastPauseTimestamp + EMERGENCY_TIMEOUT, "TIMEOUT_NOT_REACHED");

        config.state = PoolState.EMERGENCY_WIND_DOWN;

        (bool success, ) = config.poolReceiver.call(abi.encodeWithSignature("emergencyWindDown()"));
        require(success, "WRAPPER_WIND_DOWN_FAILED");

        emit EmergencyWindDownActivated(targetPool, block.timestamp);
    }

    receive() external payable {
        revert("NON_CUSTODIAL: ZERO_ETH_ACCEPTED");
    }
}
