// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./libraries/UniswapV3InvariantChecker.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/AggregatorV3Interface.sol";

/// @title EVM Invariant Shield v2.0.0 - Institutional Circuit Breaker for Ethereum L1
/// @notice Autonomous, ultra-low latency circuit breaker safeguarding Uniswap v3 & lending pools
/// @dev Formally audited and hardened for exact parity with certified BNBInvariantShield architecture
contract EVMInvariantShield {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    mapping(bytes32 => mapping(address => bool)) private _roles;

    uint256 public constant PAUSE_COOLDOWN = 15 minutes;
    uint256 public constant HWM_UPDATE_COOLDOWN = 60 seconds;
    uint256 public constant EMERGENCY_TIMEOUT = 24 hours;
    uint256 public constant DEFAULT_MAX_DEVIATION_BPS = 1500; // 15% price drop
    int24 public constant DEFAULT_MAX_TICK_DELTA = 1625;      // ~15% tick deviation
    uint256 public constant DEFAULT_MAX_DRAIN_BPS = 3000;     // 30% sudden liquidity drainage

    enum PoolState { NORMAL, PAUSED, EMERGENCY_WIND_DOWN }

    struct TargetConfig {
        bool isRegistered;
        PoolState state;
        address poolReceiver;
        address chainlinkFeed;
        uint160 initialSqrtPriceX96;
        uint160 highWaterMarkSqrtPriceX96;
        int256 highWaterMarkOraclePrice;
        uint128 initialLiquidity;
        uint128 highWaterMarkLiquidity;
        int24 initialTick;
        uint256 lastPauseTimestamp;
        uint256 lastHwmUpdateTimestamp;
        uint256 maxDeviationBps;
        int24 maxTickDelta;
        uint256 maxDrainBps;
    }

    mapping(address => TargetConfig) private _targets;

    function targets(address pool) external view returns (TargetConfig memory) {
        return _targets[pool];
    }

    event TargetRegistered(address indexed targetPool, address indexed poolReceiver, address chainlinkFeed);
    event TargetUnregistered(address indexed targetPool);
    event HighWaterMarkUpdated(address indexed targetPool, uint160 newHwmSqrtPriceX96, uint128 newHwmLiquidity);
    event RiskParametersUpdated(address indexed targetPool, uint256 maxDeviationBps, int24 maxTickDelta, uint256 maxDrainBps);
    event EmergencyPauseTriggered(address indexed targetPool, uint160 currentSqrtPriceX96, uint128 currentLiquidity, address indexed triggeredBy);
    event TargetUnpausedByMultisig(address indexed targetPool, address indexed unpausedBy);
    event AutoRecoveryTriggered(address indexed targetPool, uint160 currentSqrtPriceX96, uint128 currentLiquidity);
    event EmergencyWindDownActivated(address indexed targetPool, uint256 timestamp);
    event WindDownRestoredByGovernance(address indexed targetPool, address indexed restoredBy);
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

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
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
        require(!_targets[targetPool].isRegistered, "ALREADY_REGISTERED");

        (uint160 sqrtPriceX96, int24 tick,,,,,) = IUniswapV3Pool(targetPool).slot0();
        require(sqrtPriceX96 > 0, "INVALID_SQRT_PRICE");
        uint128 poolLiquidity = IUniswapV3Pool(targetPool).liquidity();

        TargetConfig storage config = _targets[targetPool];
        config.isRegistered = true;
        config.state = PoolState.NORMAL;
        config.poolReceiver = poolReceiver;
        config.chainlinkFeed = chainlinkFeed;
        config.initialSqrtPriceX96 = sqrtPriceX96;
        config.highWaterMarkSqrtPriceX96 = sqrtPriceX96;
        config.initialLiquidity = poolLiquidity;
        config.highWaterMarkLiquidity = poolLiquidity;
        config.initialTick = tick;
        config.lastHwmUpdateTimestamp = block.timestamp;
        config.maxDeviationBps = DEFAULT_MAX_DEVIATION_BPS;
        config.maxTickDelta = DEFAULT_MAX_TICK_DELTA;
        config.maxDrainBps = DEFAULT_MAX_DRAIN_BPS;

        if (chainlinkFeed != address(0)) {
            (, int256 initOraclePrice,,,) = AggregatorV3Interface(chainlinkFeed).latestRoundData();
            if (initOraclePrice > 0) {
                config.highWaterMarkOraclePrice = initOraclePrice;
            }
        }

        emit TargetRegistered(targetPool, poolReceiver, chainlinkFeed);
    }

    function unregisterTarget(address targetPool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_targets[targetPool].isRegistered, "NOT_REGISTERED");
        require(_targets[targetPool].state == PoolState.NORMAL, "CANNOT_UNREGISTER_ACTIVE_EMERGENCY");
        delete _targets[targetPool];
        emit TargetUnregistered(targetPool);
    }

    function updateHighWaterMark(address targetPool) external onlyRole(PAUSER_ROLE) {
        TargetConfig storage config = _targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(config.state == PoolState.NORMAL, "NOT_NORMAL");
        require(block.timestamp >= config.lastHwmUpdateTimestamp + HWM_UPDATE_COOLDOWN, "HWM_COOLDOWN_ACTIVE");

        (uint160 currentSqrtPriceX96, int24 currentTick,,,,,) = IUniswapV3Pool(targetPool).slot0();
        uint128 currentLiquidity = IUniswapV3Pool(targetPool).liquidity();

        if (config.chainlinkFeed != address(0)) {
            (, int256 oraclePrice,, uint256 updatedAt,) = AggregatorV3Interface(config.chainlinkFeed).latestRoundData();
            require(oraclePrice > 0, "INVALID_ORACLE_PRICE");
            require(block.timestamp - updatedAt <= 1 hours, "STALE_ORACLE_PRICE");

            if (currentSqrtPriceX96 > config.highWaterMarkSqrtPriceX96 && config.highWaterMarkOraclePrice > 0) {
                require(oraclePrice > config.highWaterMarkOraclePrice, "ORACLE_NOT_CONFIRMING_RALLY");
            }
            if (oraclePrice > config.highWaterMarkOraclePrice) {
                config.highWaterMarkOraclePrice = oraclePrice;
            }
        }

        bool updated = false;
        if (currentSqrtPriceX96 > config.highWaterMarkSqrtPriceX96) {
            config.highWaterMarkSqrtPriceX96 = currentSqrtPriceX96;
            config.initialTick = currentTick;
            updated = true;
        }

        if (currentLiquidity > config.highWaterMarkLiquidity) {
            config.highWaterMarkLiquidity = currentLiquidity;
            updated = true;
        }

        if (updated) {
            config.lastHwmUpdateTimestamp = block.timestamp;
            emit HighWaterMarkUpdated(targetPool, config.highWaterMarkSqrtPriceX96, config.highWaterMarkLiquidity);
        }
    }

    function updateTargetRiskParameters(
        address targetPool,
        uint256 maxDeviationBps,
        int24 maxTickDelta,
        uint256 maxDrainBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        TargetConfig storage config = _targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(maxDeviationBps >= 2 && maxDeviationBps <= 10000, "INVALID_BPS_RANGE");
        require(maxTickDelta > 0, "INVALID_TICK_DELTA");
        require(maxDrainBps >= 1 && maxDrainBps <= 10000, "INVALID_DRAIN_RANGE");

        config.maxDeviationBps = maxDeviationBps;
        config.maxTickDelta = maxTickDelta;
        config.maxDrainBps = maxDrainBps;
        emit RiskParametersUpdated(targetPool, maxDeviationBps, maxTickDelta, maxDrainBps);
    }

    function triggerEmergencyPause(address targetPool) external onlyRole(PAUSER_ROLE) {
        TargetConfig storage config = _targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(config.state == PoolState.NORMAL, "NOT_NORMAL");
        require(config.lastPauseTimestamp == 0 || block.timestamp >= config.lastPauseTimestamp + PAUSE_COOLDOWN, "PAUSE_COOLDOWN_ACTIVE");

        (uint160 currentSqrtPriceX96, int24 currentTick,,,,,) = IUniswapV3Pool(targetPool).slot0();
        uint128 currentLiquidity = IUniswapV3Pool(targetPool).liquidity();

        uint160 anchorPrice = config.highWaterMarkSqrtPriceX96 > 0
            ? config.highWaterMarkSqrtPriceX96
            : config.initialSqrtPriceX96;

        (bool dropExceeded, ) = UniswapV3InvariantChecker.checkExactPriceDrop(
            anchorPrice,
            currentSqrtPriceX96,
            config.maxDeviationBps
        );

        (bool tickExceeded, ) = UniswapV3InvariantChecker.checkTickDelta(
            config.initialTick,
            currentTick,
            config.maxTickDelta
        );

        uint128 anchorLiquidity = config.highWaterMarkLiquidity > 0
            ? config.highWaterMarkLiquidity
            : config.initialLiquidity;

        (bool drainExceeded, ) = UniswapV3InvariantChecker.checkLiquidityDrain(
            anchorLiquidity,
            currentLiquidity,
            config.maxDrainBps
        );

        require(dropExceeded || tickExceeded || drainExceeded, "INVARIANT_HEALTHY");

        config.state = PoolState.PAUSED;
        config.lastPauseTimestamp = block.timestamp;

        (bool success, ) = config.poolReceiver.call(abi.encodeWithSignature("emergencyPause()"));
        require(success, "WRAPPER_PAUSE_FAILED");

        emit EmergencyPauseTriggered(targetPool, currentSqrtPriceX96, currentLiquidity, msg.sender);
    }

    function autoRecoverIfHealthy(address targetPool) external onlyRole(PAUSER_ROLE) {
        TargetConfig storage config = _targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(config.state == PoolState.PAUSED, "NOT_PAUSED");
        require(block.timestamp >= config.lastPauseTimestamp + 5 minutes, "COOLDOWN_ACTIVE");

        (uint160 currentSqrtPriceX96, int24 currentTick,,,,,) = IUniswapV3Pool(targetPool).slot0();
        uint128 currentLiquidity = IUniswapV3Pool(targetPool).liquidity();

        uint160 minHealthyPrice = uint160((uint256(config.highWaterMarkSqrtPriceX96) * 98) / 100);
        require(currentSqrtPriceX96 >= minHealthyPrice, "PRICE_NOT_RESTORED");

        uint128 shelteredLiquidity = 0;
        (bool sRetreat, bytes memory rRetreat) = config.poolReceiver.staticcall(abi.encodeWithSignature("retreatedLiquidity()"));
        if (sRetreat && rRetreat.length == 32) {
            shelteredLiquidity = abi.decode(rRetreat, (uint128));
        }
        uint256 totalEffectiveLiquidity = uint256(currentLiquidity) + uint256(shelteredLiquidity);

        uint128 anchorLiq = config.highWaterMarkLiquidity > 0 ? config.highWaterMarkLiquidity : config.initialLiquidity;
        require(totalEffectiveLiquidity >= (uint256(anchorLiq) * 9) / 10, "LIQUIDITY_NOT_RESTORED");

        config.state = PoolState.NORMAL;
        config.initialSqrtPriceX96 = currentSqrtPriceX96;
        config.initialTick = currentTick;

        (bool success, ) = config.poolReceiver.call(abi.encodeWithSignature("emergencyUnpause()"));
        require(success, "WRAPPER_UNPAUSE_FAILED");

        emit AutoRecoveryTriggered(targetPool, currentSqrtPriceX96, currentLiquidity);
    }

    function unpauseTargetWithOracle(
        address targetPool,
        uint160 minAcceptableSqrtPrice,
        uint256 maxOracleAge
    ) external onlyRole(UNPAUSER_ROLE) {
        TargetConfig storage config = _targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(config.state == PoolState.PAUSED, "NOT_PAUSED");

        (uint160 currentSqrtPriceX96, int24 newTick,,,,,) = IUniswapV3Pool(targetPool).slot0();
        require(currentSqrtPriceX96 >= minAcceptableSqrtPrice, "MARKET_NOT_RESTORED");

        if (config.chainlinkFeed != address(0)) {
            (, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(config.chainlinkFeed).latestRoundData();
            require(price > 0, "INVALID_ORACLE_PRICE");
            require(block.timestamp - updatedAt <= maxOracleAge, "STALE_ORACLE_PRICE");
            config.highWaterMarkOraclePrice = price;
        }

        config.initialSqrtPriceX96 = currentSqrtPriceX96;
        config.highWaterMarkSqrtPriceX96 = currentSqrtPriceX96;
        config.highWaterMarkLiquidity = IUniswapV3Pool(targetPool).liquidity();
        config.initialLiquidity = config.highWaterMarkLiquidity;
        config.initialTick = newTick;
        config.state = PoolState.NORMAL;

        (bool success, ) = config.poolReceiver.call(abi.encodeWithSignature("emergencyUnpause()"));
        require(success, "WRAPPER_UNPAUSE_FAILED");

        emit TargetUnpausedByMultisig(targetPool, msg.sender);
    }

    function activateEmergencyWindDown(address targetPool) external {
        TargetConfig storage config = _targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(config.state == PoolState.PAUSED, "NOT_PAUSED");
        require(block.timestamp >= config.lastPauseTimestamp + EMERGENCY_TIMEOUT, "TIMEOUT_NOT_REACHED");

        (uint160 currentSqrtPriceX96,,,,,,) = IUniswapV3Pool(targetPool).slot0();
        uint128 currentLiquidity = IUniswapV3Pool(targetPool).liquidity();

        uint160 anchorPrice = config.highWaterMarkSqrtPriceX96 > 0 ? config.highWaterMarkSqrtPriceX96 : config.initialSqrtPriceX96;
        (bool dropExceeded, ) = UniswapV3InvariantChecker.checkExactPriceDrop(anchorPrice, currentSqrtPriceX96, config.maxDeviationBps);

        uint128 anchorLiq = config.highWaterMarkLiquidity > 0 ? config.highWaterMarkLiquidity : config.initialLiquidity;
        (bool drainExceeded, ) = UniswapV3InvariantChecker.checkLiquidityDrain(anchorLiq, currentLiquidity, config.maxDrainBps);

        require(dropExceeded || drainExceeded, "CANNOT_WIND_DOWN_RECOVERED_POOL");

        config.state = PoolState.EMERGENCY_WIND_DOWN;

        (bool success, ) = config.poolReceiver.call(abi.encodeWithSignature("emergencyWindDown()"));
        require(success, "WRAPPER_WIND_DOWN_FAILED");

        emit EmergencyWindDownActivated(targetPool, block.timestamp);
    }

    function governanceRestoreFromWindDown(address targetPool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        TargetConfig storage config = _targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(config.state == PoolState.EMERGENCY_WIND_DOWN, "NOT_WIND_DOWN");

        (uint160 currentSqrtPriceX96, int24 currentTick,,,,,) = IUniswapV3Pool(targetPool).slot0();
        uint128 currentLiquidity = IUniswapV3Pool(targetPool).liquidity();

        if (config.chainlinkFeed != address(0)) {
            (, int256 curOraclePrice,,,) = AggregatorV3Interface(config.chainlinkFeed).latestRoundData();
            if (curOraclePrice > 0) {
                config.highWaterMarkOraclePrice = curOraclePrice;
            }
        }

        config.initialSqrtPriceX96 = currentSqrtPriceX96;
        config.highWaterMarkSqrtPriceX96 = currentSqrtPriceX96;
        config.initialLiquidity = currentLiquidity;
        config.highWaterMarkLiquidity = currentLiquidity;
        config.initialTick = currentTick;
        config.state = PoolState.NORMAL;

        (bool success, ) = config.poolReceiver.call(abi.encodeWithSignature("emergencyUnpause()"));
        require(success, "WRAPPER_UNPAUSE_FAILED");

        emit WindDownRestoredByGovernance(targetPool, msg.sender);
    }

    receive() external payable {
        revert("NON_CUSTODIAL: ZERO_ETH_ACCEPTED");
    }
}
