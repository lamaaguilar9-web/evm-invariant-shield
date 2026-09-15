// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./libraries/FullMath.sol";
import "./libraries/UniswapV3InvariantChecker.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV3Pool.sol";

/// @title EVM Invariant Shield v1.1.0 - Production Hardened Circuit Breaker
/// @notice Autonomous non-custodial protection for Uniswap v3 & Aave v3 wrappers and vaults
/// @dev Direct on-chain slot0 and balanceOf reads eliminate parameter injection DoS risks entirely
contract EVMInvariantShield {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    mapping(bytes32 => mapping(address => bool)) private _roles;

    uint256 public constant MAX_CONSECUTIVE_PAUSES = 2;
    uint256 public constant EMERGENCY_TIMEOUT = 24 hours;
    uint256 public constant DEFAULT_MAX_DEVIATION_BPS = 1500; // 15% price or reserve anomaly

    enum PoolState { NORMAL, PAUSED, EMERGENCY_WIND_DOWN }

    struct TargetConfig {
        bool isRegistered;
        PoolState state;
        address poolReceiver; // Vault or Position Manager hook
        address token0;
        address token1;
        uint160 initialSqrtPriceX96;
        uint256 initialReserve0;
        uint256 initialReserve1;
        uint256 lastPauseTimestamp;
        uint256 consecutivePauses;
    }

    mapping(address => TargetConfig) public targets;

    event TargetRegistered(address indexed targetPool, address indexed poolReceiver, uint160 initialSqrtPriceX96);
    event EmergencyPauseTriggered(address indexed targetPool, uint160 currentSqrtPriceX96, uint256 deviationBps, address indexed triggeredBy);
    event TargetUnpausedByMultisig(address indexed targetPool, address indexed unpausedBy);
    event EmergencyWindDownActivated(address indexed targetPool, uint256 timestamp);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "ACCESS_CONTROL: SENDER_LACKS_ROLE");
        _;
    }

    constructor(address sentinelBot, address gnosisSafeMultisig) {
        require(sentinelBot != address(0) && gnosisSafeMultisig != address(0), "INVALID_ADDRESS");
        _roles[PAUSER_ROLE][sentinelBot] = true;
        _roles[UNPAUSER_ROLE][gnosisSafeMultisig] = true;
        _roles[DEFAULT_ADMIN_ROLE][gnosisSafeMultisig] = true;
        emit RoleGranted(PAUSER_ROLE, sentinelBot, msg.sender);
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

    /// @notice Registers target pool and its defensive wrapper with baseline on-chain state
    function registerTarget(
        address targetPool,
        address poolReceiver,
        address token0,
        address token1
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(targetPool != address(0) && poolReceiver != address(0), "INVALID_ADDRESS");
        require(!targets[targetPool].isRegistered, "ALREADY_REGISTERED");

        // Read baseline sqrtPriceX96 directly on-chain from slot0 if supported
        uint160 sqrtPriceX96 = 0;
        try IUniswapV3Pool(targetPool).slot0() returns (uint160 _sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool) {
            sqrtPriceX96 = _sqrtPriceX96;
        } catch {
            // Fallback for non-v3 direct pool
            sqrtPriceX96 = 0;
        }

        uint256 res0 = IERC20(token0).balanceOf(targetPool);
        uint256 res1 = IERC20(token1).balanceOf(targetPool);

        targets[targetPool] = TargetConfig({
            isRegistered: true,
            state: PoolState.NORMAL,
            poolReceiver: poolReceiver,
            token0: token0,
            token1: token1,
            initialSqrtPriceX96: sqrtPriceX96,
            initialReserve0: res0,
            initialReserve1: res1,
            lastPauseTimestamp: 0,
            consecutivePauses: 0
        });

        emit TargetRegistered(targetPool, poolReceiver, sqrtPriceX96);
    }

    /// @notice HARDENED TRIGGER: Zero external parameters. State is queried 100% on-chain.
    /// @dev Eliminates parameter injection DoS attacks. Reverts if on-chain state has not suffered >15% drop.
    function triggerEmergencyPause(address targetPool) external onlyRole(PAUSER_ROLE) {
        TargetConfig storage config = targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(config.state == PoolState.NORMAL, "NOT_NORMAL");
        require(config.consecutivePauses < MAX_CONSECUTIVE_PAUSES, "MAX_PAUSES_REACHED");

        bool anomalyDetected = false;
        uint256 recordedDeviationBps = 0;
        uint160 currentSqrtPriceX96 = 0;

        // 1. Direct on-chain Uniswap v3 slot0 price check
        if (config.initialSqrtPriceX96 > 0) {
            (uint160 _currSqrtPriceX96,,,,,,) = IUniswapV3Pool(targetPool).slot0();
            currentSqrtPriceX96 = _currSqrtPriceX96;
            (bool priceExceeded, uint256 priceBps) = UniswapV3InvariantChecker.checkPriceDeviation(
                config.initialSqrtPriceX96,
                _currSqrtPriceX96,
                DEFAULT_MAX_DEVIATION_BPS
            );
            if (priceExceeded) {
                anomalyDetected = true;
                recordedDeviationBps = priceBps;
            }
        }

        // 2. Direct on-chain ERC20 reserve balance check
        if (!anomalyDetected && config.initialReserve0 > 0 && config.initialReserve1 > 0) {
            uint256 currRes0 = IERC20(config.token0).balanceOf(targetPool);
            uint256 currRes1 = IERC20(config.token1).balanceOf(targetPool);
            (bool resExceeded, uint256 resBps) = UniswapV3InvariantChecker.checkReserveDrop(
                config.initialReserve0,
                config.initialReserve1,
                currRes0,
                currRes1,
                DEFAULT_MAX_DEVIATION_BPS
            );
            if (resExceeded) {
                anomalyDetected = true;
                recordedDeviationBps = resBps;
            }
        }

        // Must strictly prove on-chain that invariant drop occurred
        require(anomalyDetected, "INVARIANT_DROP_NOT_EXCEEDED: ON_CHAIN_STATE_IS_HEALTHY");

        config.state = PoolState.PAUSED;
        config.lastPauseTimestamp = block.timestamp;
        config.consecutivePauses += 1;

        // Atomically halt the managed pool/vault wrapper
        (bool success, ) = config.poolReceiver.call(abi.encodeWithSignature("emergencyPause()"));
        require(success, "WRAPPER_HOOK_FAILED");

        emit EmergencyPauseTriggered(targetPool, currentSqrtPriceX96, recordedDeviationBps, msg.sender);
    }

    /// @notice Unpause can ONLY be executed by Gnosis Safe 3/5 Multisig after forensic review
    function unpauseTarget(address targetPool) external onlyRole(UNPAUSER_ROLE) {
        TargetConfig storage config = targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(config.state == PoolState.PAUSED, "NOT_PAUSED");

        // Recalibrate baseline directly from on-chain state
        if (config.initialSqrtPriceX96 > 0) {
            try IUniswapV3Pool(targetPool).slot0() returns (uint160 _sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool) {
                config.initialSqrtPriceX96 = _sqrtPriceX96;
            } catch {}
        }
        config.initialReserve0 = IERC20(config.token0).balanceOf(targetPool);
        config.initialReserve1 = IERC20(config.token1).balanceOf(targetPool);

        config.state = PoolState.NORMAL;
        config.consecutivePauses = 0;

        (bool success, ) = config.poolReceiver.call(abi.encodeWithSignature("emergencyUnpause()"));
        require(success, "UNPAUSE_HOOK_FAILED");

        emit TargetUnpausedByMultisig(targetPool, msg.sender);
    }

    /// @notice 24-hour timeout degradation to emergency wind down (no auto-unpause)
    function activateEmergencyWindDown(address targetPool) external {
        TargetConfig storage config = targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(config.state == PoolState.PAUSED, "NOT_PAUSED");
        require(block.timestamp >= config.lastPauseTimestamp + EMERGENCY_TIMEOUT, "TIMEOUT_NOT_REACHED");

        config.state = PoolState.EMERGENCY_WIND_DOWN;

        (bool success, ) = config.poolReceiver.call(abi.encodeWithSignature("emergencyWindDown()"));
        require(success, "WIND_DOWN_HOOK_FAILED");

        emit EmergencyWindDownActivated(targetPool, block.timestamp);
    }

    /// @notice Strictly non-custodial: rejects direct ETH transfers
    receive() external payable {
        revert("NON_CUSTODIAL: ZERO_ETH_ACCEPTED");
    }
}
