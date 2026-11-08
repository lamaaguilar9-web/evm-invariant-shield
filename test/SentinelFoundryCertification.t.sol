// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/EVMInvariantShield.sol";
import "../contracts/libraries/UniswapV3InvariantChecker.sol";

contract MockChainlinkAggregator {
    int256 public price = 3500e8;
    uint256 public updatedAt;

    constructor() {
        updatedAt = block.timestamp;
    }

    function setRoundData(int256 _price, uint256 _updatedAt) external {
        price = _price;
        updatedAt = _updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, block.timestamp, updatedAt, 1);
    }
}

contract MockUniswapV3PoolCert {
    uint160 public sqrtPriceX96 = 468494958188145244569501538304;
    int24 public tick = 81625;
    uint128 public liquidity = 10_000_000;

    function setSlot0(uint160 _sqrt, int24 _tick) external {
        sqrtPriceX96 = _sqrt;
        tick = _tick;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, tick, 0, 0, 0, 0, true);
    }
}

contract MockReceiverHook {
    bool public paused;
    bool public emergencyWindDownActive;
    uint256 public token0Balance = 100 ether;
    uint256 public token1Balance = 350_000e6;
    uint256 public totalLpSupply;
    mapping(address => uint256) public lpBalances;

    function mintLp(address to, uint256 amount) external {
        lpBalances[to] += amount;
        totalLpSupply += amount;
    }

    function emergencyPause() external {
        paused = true;
    }

    function emergencyUnpause() external {
        paused = false;
        emergencyWindDownActive = false;
    }

    function emergencyWindDown() external {
        paused = true;
        emergencyWindDownActive = true;
    }

    function orderlyWithdraw(address user, uint256 lpAmount) external returns (uint256 a0, uint256 a1) {
        require(emergencyWindDownActive, "WIND_DOWN_NOT_ACTIVE");
        require(lpBalances[user] >= lpAmount, "INSUFFICIENT_LP");
        uint256 total = totalLpSupply;
        require(total > 0, "ZERO_TOTAL_SUPPLY");
        a0 = (lpAmount * token0Balance) / total;
        a1 = (lpAmount * token1Balance) / total;
        lpBalances[user] -= lpAmount;
        totalLpSupply = total - lpAmount;
        token0Balance -= a0;
        token1Balance -= a1;
    }
}

/// @title SentinelFoundryCertification - Official Foundry Invariant & Fuzzing Suite (256 Runs)
contract SentinelFoundryCertification is Test {
    EVMInvariantShield public shield;
    MockUniswapV3PoolCert public pool;
    MockReceiverHook public receiver;
    MockChainlinkAggregator public feed;

    address public sentinelBot = address(0x1111);
    address public gnosisSafe = address(0x2222);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    function setUp() public {
        vm.warp(1_700_000_000);
        pool = new MockUniswapV3PoolCert();
        receiver = new MockReceiverHook();
        feed = new MockChainlinkAggregator();
        shield = new EVMInvariantShield(sentinelBot, gnosisSafe);

        vm.prank(gnosisSafe);
        shield.registerTarget(address(pool), address(receiver), address(feed));
    }

    function test_Invariant_PauseOnQuadraticDropAndOracleVerifiedUnpause() public {
        // 1. Crash pool > 15%
        pool.setSlot0(400000000000000000000000000000, 79000);
        vm.prank(sentinelBot);
        shield.triggerEmergencyPause(address(pool));
        assertTrue(receiver.paused(), "Pool must be paused");

        // 2. Stale oracle blocks unpause
        feed.setRoundData(3500e8, block.timestamp - 7200);
        pool.setSlot0(468494958188145244569501538304, 81625);
        vm.prank(gnosisSafe);
        vm.expectRevert(bytes("STALE_ORACLE_PRICE"));
        shield.unpauseTargetWithOracle(address(pool), 450000000000000000000000000000, 3600);

        // 3. Fresh oracle restores pool
        feed.setRoundData(3500e8, block.timestamp);
        vm.prank(gnosisSafe);
        shield.unpauseTargetWithOracle(address(pool), 450000000000000000000000000000, 3600);
        assertFalse(receiver.paused(), "Pool must be unpaused");
    }

    function testFuzz_ProportionalWindDownConservation(uint96 aliceLp, uint96 bobLp) public {
        vm.assume(aliceLp > 1000 && bobLp > 1000);
        receiver.mintLp(alice, aliceLp);
        receiver.mintLp(bob, bobLp);
        receiver.emergencyWindDown();

        uint256 init0 = receiver.token0Balance();
        uint256 init1 = receiver.token1Balance();

        (uint256 a0, uint256 a1) = receiver.orderlyWithdraw(alice, aliceLp);
        (uint256 b0, uint256 b1) = receiver.orderlyWithdraw(bob, bobLp);

        assertEq(receiver.totalLpSupply(), 0);
        assertApproxEqAbs(a0 + b0, init0, 1);
        assertApproxEqAbs(a1 + b1, init1, 1);
    }
}
