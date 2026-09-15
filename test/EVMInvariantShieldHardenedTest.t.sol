// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../contracts/EVMInvariantShield.sol";
import "../contracts/ProtectedPoolReceiver.sol";
import "../contracts/libraries/UniswapV3InvariantChecker.sol";

interface Vm {
    function prank(address) external;
    function warp(uint256) external;
}

contract MockERC20Safe {
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

contract MockChainlinkFeed {
    int256 public price;
    uint256 public updatedAt;
    constructor(int256 _price) {
        price = _price;
        updatedAt = block.timestamp;
    }
    function setPrice(int256 _price, uint256 _updatedAt) external {
        price = _price;
        updatedAt = _updatedAt;
    }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, block.timestamp, updatedAt, 1);
    }
}

contract MockUniswapV3PoolHardened {
    uint160 public sqrtPriceX96;
    int24 public tick;
    uint128 public positionLiquidity;

    constructor(uint160 _sqrt, int24 _tick, uint128 _liq) {
        sqrtPriceX96 = _sqrt;
        tick = _tick;
        positionLiquidity = _liq;
    }

    function setSlot0(uint160 _sqrt, int24 _tick) external {
        sqrtPriceX96 = _sqrt;
        tick = _tick;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, tick, 0, 0, 0, 0, true);
    }

    function positions(bytes32) external view returns (uint128, uint256, uint256, uint128, uint128) {
        return (positionLiquidity, 0, 0, 0, 0);
    }

    function burn(int24, int24, uint128 amount) external returns (uint256, uint256) {
        positionLiquidity -= amount;
        return (0, 0);
    }

    function collect(address, int24, int24, uint128, uint128) external pure returns (uint128, uint128) {
        return (0, 0);
    }
}

contract EVMInvariantShieldHardenedTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    EVMInvariantShield public shield;
    ProtectedPoolReceiver public receiver;
    MockUniswapV3PoolHardened public pool;
    MockERC20Safe public token0;
    MockERC20Safe public token1;
    MockChainlinkFeed public feed;

    address public deployer = address(0xAAAA);
    address public sentinelBot = address(0x1111);
    address public gnosisSafe = address(0x2222);
    address public alice = address(0x3333);

    function setUp() public {
        vm.prank(deployer);
        token0 = new MockERC20Safe("WETH");
        token1 = new MockERC20Safe("USDC");

        uint160 initSqrtP = 468494958188145244569501538304; // 3,500 USDC/WETH
        int24 initTick = 81625;
        pool = new MockUniswapV3PoolHardened(initSqrtP, initTick, 10000000);

        vm.prank(deployer);
        receiver = new ProtectedPoolReceiver(
            address(token0),
            address(token1),
            address(pool),
            80000,
            83000
        );

        feed = new MockChainlinkFeed(3500 * 1e8);

        vm.prank(deployer);
        shield = new EVMInvariantShield(sentinelBot, gnosisSafe);

        vm.prank(deployer);
        receiver.setCircuitBreaker(address(shield));
    }

    function test_OwnershipAllowsUpdatingCircuitBreaker() public {
        address newBreaker = address(0x9999);
        vm.prank(deployer);
        receiver.setCircuitBreaker(newBreaker);
        require(receiver.circuitBreaker() == newBreaker, "Ownership update failed");
    }

    function test_UnpauseRequiresFreshOraclePrice() public {
        vm.prank(gnosisSafe);
        shield.registerTarget(address(pool), address(receiver), address(feed));

        pool.setSlot0(894427, 79000); // 20% crash
        vm.prank(sentinelBot);
        shield.triggerEmergencyPause(address(pool));

        // Oraculo desactualizado (2 horas de desfase)
        feed.setPrice(3500 * 1e8, block.timestamp - 7200);

        pool.setSlot0(468494958188145244569501538304, 81625); // Mercado restablecido

        vm.prank(gnosisSafe);
        try shield.unpauseTargetWithOracle(address(pool), 400000000000000000000000000000, 3600) {
            revert("TEST_FAILED: Stale oracle should revert");
        } catch Error(string memory reason) {
            require(
                keccak256(bytes(reason)) == keccak256(bytes("STALE_ORACLE_PRICE")),
                "Unexpected revert"
            );
        }
    }
}
