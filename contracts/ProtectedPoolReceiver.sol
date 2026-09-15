// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ProtectedPoolReceiver - Reference Implementation for Pool Hooks
/// @notice Implements atomic pause, anti-Sybil LP transfer freeze, and emergency wind down
contract ProtectedPoolReceiver {
    address public circuitBreaker;
    bool public paused;
    bool public emergencyWindDownActive;

    mapping(address => uint256) public lpBalances;
    uint256 public totalLpSupply;

    event PoolPaused();
    event PoolUnpaused();
    event WindDownActive();
    event LpBurned(address indexed user, uint256 amount);

    modifier onlyCircuitBreaker() {
        require(msg.sender == circuitBreaker, "CALLER_NOT_CIRCUIT_BREAKER");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "POOL_IS_PAUSED");
        _;
    }

    constructor() {
        circuitBreaker = msg.sender;
    }

    function setCircuitBreaker(address _breaker) external {
        require(circuitBreaker == msg.sender, "ONLY_CREATOR");
        circuitBreaker = _breaker;
    }

    function mintLp(address to, uint256 amount) external whenNotPaused {
        lpBalances[to] += amount;
        totalLpSupply += amount;
    }

    /// @notice Anti-Sybil protection: LP transfers are frozen during pause
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
        emit WindDownActive();
    }

    /// @notice Orderly withdrawal during emergency wind-down
    function orderlyWithdraw(uint256 lpAmount) external returns (bool) {
        require(emergencyWindDownActive, "WIND_DOWN_NOT_ACTIVE");
        require(lpBalances[msg.sender] >= lpAmount, "INSUFFICIENT_LP");
        lpBalances[msg.sender] -= lpAmount;
        totalLpSupply -= lpAmount;
        emit LpBurned(msg.sender, lpAmount);
        return true;
    }
}
