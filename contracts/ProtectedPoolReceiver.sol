// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IERC20.sol";

/// @title ProtectedPoolReceiver v1.1.0 - Hardened Liquidity Vault & Pool Wrapper
/// @notice Implements atomic circuit breaker pause, anti-Sybil LP freeze, and non-custodial emergency asset withdrawal
contract ProtectedPoolReceiver {
    address public circuitBreaker;
    address public immutable token0;
    address public immutable token1;

    bool public paused;
    bool public emergencyWindDownActive;
    uint256 private _reentrancyStatus;

    mapping(address => uint256) public lpBalances;
    uint256 public totalLpSupply;

    event PoolPaused();
    event PoolUnpaused();
    event EmergencyWindDownActive();
    event EmergencyWithdrawal(address indexed user, uint256 lpBurned, uint256 amount0, uint256 amount1);

    modifier onlyCircuitBreaker() {
        require(msg.sender == circuitBreaker, "NOT_CIRCUIT_BREAKER");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "POOL_IS_PAUSED");
        _;
    }

    modifier nonReentrant() {
        require(_reentrancyStatus != 2, "REENTRANCY_GUARD");
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    constructor(address _token0, address _token1) {
        require(_token0 != address(0) && _token1 != address(0), "INVALID_TOKENS");
        token0 = _token0;
        token1 = _token1;
        circuitBreaker = msg.sender;
        _reentrancyStatus = 1;
    }

    function setCircuitBreaker(address _breaker) external {
        require(circuitBreaker == msg.sender, "ONLY_CREATOR");
        circuitBreaker = _breaker;
    }

    function mintLp(address to, uint256 amount) external whenNotPaused {
        lpBalances[to] += amount;
        totalLpSupply += amount;
    }

    /// @notice Anti-Sybil protection: LP transfers are strictly frozen during pause
    function transferLp(address to, uint256 amount) external whenNotPaused returns (bool) {
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

    /// @notice Full non-reentrant emergency exit: users burn LP shares and receive proportional underlying ERC20 tokens
    function orderlyWithdraw(uint256 lpAmount) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(emergencyWindDownActive, "WIND_DOWN_NOT_ACTIVE");
        require(lpBalances[msg.sender] >= lpAmount, "INSUFFICIENT_LP");
        uint256 total = totalLpSupply;
        require(total > 0, "ZERO_TOTAL_SUPPLY");

        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));

        amount0 = (lpAmount * bal0) / total;
        amount1 = (lpAmount * bal1) / total;

        lpBalances[msg.sender] -= lpAmount;
        totalLpSupply = total - lpAmount;

        if (amount0 > 0) {
            require(IERC20(token0).transfer(msg.sender, amount0), "TRANSFER_0_FAILED");
        }
        if (amount1 > 0) {
            require(IERC20(token1).transfer(msg.sender, amount1), "TRANSFER_1_FAILED");
        }

        emit EmergencyWithdrawal(msg.sender, lpAmount, amount0, amount1);
    }
}
