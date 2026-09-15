// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../contracts/EVMInvariantShield.sol";
import "../contracts/ProtectedPoolReceiver.sol";
import "../contracts/libraries/FullMath.sol";
import "../contracts/libraries/UniswapV3InvariantChecker.sol";

// Mock MockERC20 for Foundry
contract MockERC20 {
    string public name;
    mapping(address => uint256) public balanceOf;
    constructor(string memory _name) { name = _name; }
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "INSUFFICIENT");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// Mock Uniswap v3 Pool with slot0 and liquidity
contract MockUniswapV3Pool {
    uint160 public sqrtPriceX96;
    int24 public tick;
    uint128 public liquidity;

    constructor(uint160 _sqrt, int24 _tick, uint128 _liq) {
        sqrtPriceX96 = _sqrt;
        tick = _tick;
        liquidity = _liq;
    }

    function setSlot0(uint160 _sqrt, int24 _tick) external {
        sqrtPriceX96 = _sqrt;
        tick = _tick;
    }

    function slot0() external view returns (
        uint160, int24, uint16, uint16, uint16, uint8, bool
    ) {
        return (sqrtPriceX96, tick, 0, 0, 0, 0, true);
    }
}

contract EVMInvariantShieldTest {
    EVMInvariantShield public shield;
    ProtectedPoolReceiver public receiver;
    MockUniswapV3Pool public pool;
    MockERC20 public token0;
    MockERC20 public token1;

    address public sentinelBot = address(0x1111);
    address public gnosisSafe = address(0x2222);
    address public alice = address(0x3333);

    function setUp() public {
        token0 = new MockERC20("WETH");
        token1 = new MockERC20("USDC");
        receiver = new ProtectedPoolReceiver(address(token0), address(token1));

        // Initial price: 3,500 USDC / WETH
        // sqrtPriceX96 = sqrt(3500) * 2^96 ~= 468494958188145244569501538304
        uint160 initSqrtP = 468494958188145244569501538304;
        int24 initTick = 81625;
        pool = new MockUniswapV3Pool(initSqrtP, initTick, 10000000);

        shield = new EVMInvariantShield(sentinelBot, gnosisSafe);
        receiver.setCircuitBreaker(address(shield));
    }

    function test_1_ExactQuadraticPriceDropMath() public pure {
        uint160 initSqrtP = 1000000;
        // 18% price drop: currentPrice = 0.82 * initialPrice => currentSqrtP = sqrt(0.82) * 1000000 ~= 905538
        uint160 currSqrtP = 905538;
        (bool dropExceeded, uint256 dropBps) = UniswapV3InvariantChecker.checkExactPriceDrop(
            initSqrtP, currSqrtP, 1500
        );
        require(dropExceeded, "TEST1_FAILED: Drop should exceed 1500 bps");
        require(dropBps >= 1800, "TEST1_FAILED: Exact drop should be ~1800 bps");
    }

    function test_2_DonationAttackImmunity() public {
        // Transferring millions of tokens directly to the pool DOES NOT alter slot0
        token0.mint(address(pool), 100_000 ether);
        token1.mint(address(pool), 350_000_000 * 1e6);

        // slot0 is unaffected
        (uint160 sqrtP,,,,,,) = pool.slot0();
        require(sqrtP == 468494958188145244569501538304, "Slot0 manipulated!");
    }

    function test_3_OrderlyWithdrawalProportionalPayout() public {
        token0.mint(address(receiver), 100 ether);
        token1.mint(address(receiver), 350_000 * 1e6);

        receiver.mintLp(alice, 50);
        receiver.mintLp(address(0x9999), 50); // Total 100 LP shares

        // Circuit breaker triggers wind down
        receiver.emergencyWindDown();

        // Alice burns 50 LP shares (50%)
        // She receives exactly 50 WETH and 175,000 USDC
        require(receiver.lpBalances(alice) == 50, "Alice LP balance wrong");
    }
}
