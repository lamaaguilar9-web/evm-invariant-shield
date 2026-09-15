// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IUniswapV3Pool.sol";

/// @title ProtectedPoolReceiver - Hardened Vault & Managed Liquidity Position Wrapper
/// @notice Protege posiciones LP con despausado seguro, SafeERC20 y quema real de liquidez en Uniswap V3
contract ProtectedPoolReceiver is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public owner;
    address public circuitBreaker;
    address public liquidityManager;
    address public immutable token0;
    address public immutable token1;
    address public immutable targetPool;

    int24 public immutable tickLower;
    int24 public immutable tickUpper;

    bool public paused;
    bool public emergencyWindDownActive;

    mapping(address => uint256) public lpBalances;
    uint256 public totalLpSupply;

    event PoolPaused();
    event PoolUnpaused();
    event EmergencyWindDownActive();
    event EmergencyWithdrawal(address indexed user, uint256 lpBurned, uint256 amount0, uint256 amount1);
    event CircuitBreakerUpdated(address indexed oldBreaker, address indexed newBreaker);
    event LiquidityManagerUpdated(address indexed oldManager, address indexed newManager);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    modifier onlyCircuitBreaker() {
        require(msg.sender == circuitBreaker, "NOT_CIRCUIT_BREAKER");
        _;
    }

    modifier onlyLiquidityManager() {
        require(msg.sender == liquidityManager, "NOT_LIQUIDITY_MANAGER");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "POOL_IS_PAUSED");
        _;
    }

    constructor(
        address _token0,
        address _token1,
        address _targetPool,
        int24 _tickLower,
        int24 _tickUpper
    ) {
        require(_token0 != address(0) && _token1 != address(0) && _targetPool != address(0), "INVALID_ADDRESS");
        token0 = _token0;
        token1 = _token1;
        targetPool = _targetPool;
        tickLower = _tickLower;
        tickUpper = _tickUpper;

        owner = msg.sender;
        circuitBreaker = msg.sender;
        liquidityManager = msg.sender;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "INVALID_OWNER");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setCircuitBreaker(address _breaker) external onlyOwner {
        require(_breaker != address(0), "INVALID_BREAKER");
        emit CircuitBreakerUpdated(circuitBreaker, _breaker);
        circuitBreaker = _breaker;
    }

    function setLiquidityManager(address _manager) external onlyOwner {
        require(_manager != address(0), "INVALID_MANAGER");
        emit LiquidityManagerUpdated(liquidityManager, _manager);
        liquidityManager = _manager;
    }

    function mintLp(address to, uint256 amount) external onlyLiquidityManager whenNotPaused {
        require(to != address(0), "INVALID_RECIPIENT");
        require(amount > 0, "INVALID_AMOUNT");
        lpBalances[to] += amount;
        totalLpSupply += amount;
    }

    function transferLp(address to, uint256 amount) external whenNotPaused returns (bool) {
        require(to != address(0), "INVALID_RECIPIENT");
        require(lpBalances[msg.sender] >= amount, "INSUFFICIENT_LP");
        lpBalances[msg.sender] -= amount;
        lpBalances[to] += amount;
        return true;
    }

    function emergencyPause() external onlyCircuitBreaker {
        paused = true;
        emit PoolPaused();
    }

    function emergencyUnpause() external onlyCircuitBreaker {
        paused = false;
        emergencyWindDownActive = false;
        emit PoolUnpaused();
    }

    function emergencyWindDown() external onlyCircuitBreaker {
        paused = true;
        emergencyWindDownActive = true;
        emit EmergencyWindDownActive();
    }

    /// @notice Extrae la liquidez proporcional de Uniswap V3 antes de transferir tokens subyacentes
    function orderlyWithdraw(uint256 lpAmount) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(emergencyWindDownActive, "WIND_DOWN_NOT_ACTIVE");
        require(lpBalances[msg.sender] >= lpAmount, "INSUFFICIENT_LP");
        uint256 total = totalLpSupply;
        require(total > 0, "ZERO_TOTAL_SUPPLY");

        // 1. Verificar posición activa en Uniswap V3
        bytes32 positionKey = keccak256(abi.encodePacked(address(this), tickLower, tickUpper));
        (uint128 positionLiquidity,,,,) = IUniswapV3Pool(targetPool).positions(positionKey);

        // 2. Quemar y recolectar la cuota correspondiente de liquidez
        if (positionLiquidity > 0) {
            uint128 liquidityToBurn = uint128((uint256(positionLiquidity) * lpAmount) / total);
            if (liquidityToBurn > 0) {
                IUniswapV3Pool(targetPool).burn(tickLower, tickUpper, liquidityToBurn);
                IUniswapV3Pool(targetPool).collect(
                    address(this),
                    tickLower,
                    tickUpper,
                    type(uint128).max,
                    type(uint128).max
                );
            }
        }

        // 3. Obtener balances disponibles
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));

        amount0 = (lpAmount * bal0) / total;
        amount1 = (lpAmount * bal1) / total;

        // 4. Actualización contable interna
        lpBalances[msg.sender] -= lpAmount;
        totalLpSupply = total - lpAmount;

        // 5. Transferencias seguras compatibles con SafeERC20
        if (amount0 > 0) {
            IERC20(token0).safeTransfer(msg.sender, amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).safeTransfer(msg.sender, amount1);
        }

        emit EmergencyWithdrawal(msg.sender, lpAmount, amount0, amount1);
    }
}
