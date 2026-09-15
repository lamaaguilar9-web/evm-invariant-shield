// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../contracts/EVMInvariantShield.sol";
import "../contracts/ProtectedPoolReceiver.sol";
import "../contracts/libraries/FullMath.sol";
import "../contracts/libraries/UniswapV3InvariantChecker.sol";

// Interface for Foundry cheatcodes
interface Vm {
    function prank(address) external;
    function warp(uint256) external;
}

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
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

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

    // 1. Verificación de la matemática cuadrática exacta
    function test_1_ExactQuadraticPriceDropMath() public pure {
        uint160 initSqrtP = 1000000;
        // Caída de precio del 18%: P_curr = 0.82 * P_init => sqrtP = sqrt(0.82) * 1000000 ~= 905538
        uint160 currSqrtP = 905538;
        (bool dropExceeded, uint256 dropBps) = UniswapV3InvariantChecker.checkExactPriceDrop(
            initSqrtP, currSqrtP, 1500
        );
        require(dropExceeded, "TEST1_FAILED: El drop debio superar 1500 bps");
        require(dropBps >= 1800, "TEST1_FAILED: La caida exacta debio ser ~1800 bps");
    }

    // 2. Inmunidad absoluta contra Donation Attacks
    function test_2_DonationAttackImmunity() public {
        token0.mint(address(pool), 100_000 ether);
        token1.mint(address(pool), 350_000_000 * 1e6);

        // slot0 no se inmuta ante transferencias directas de tokens
        (uint160 sqrtP,,,,,,) = pool.slot0();
        require(sqrtP == 468494958188145244569501538304, "Slot0 no debe cambiar!");
    }

    // 3. Salida ordenada (orderlyWithdraw) con pagos proporcionales y ejecución real
    function test_3_OrderlyWithdrawalProportionalPayout() public {
        token0.mint(address(receiver), 100 ether);
        token1.mint(address(receiver), 350_000 * 1e6);

        // Vault manager emite 50 LP a Alice y 50 LP a Bob
        receiver.mintLp(alice, 50);
        receiver.mintLp(address(0x9999), 50); // 100 LP shares totales

        // Circuit breaker activa la liquidación ordenada
        receiver.emergencyWindDown();

        // Alice ejecuta el retiro ordenado de sus 50 LP shares
        vm.prank(alice);
        (uint256 a0, uint256 a1) = receiver.orderlyWithdraw(50);

        require(a0 == 50 ether, "Payout a0 incorrecto");
        require(a1 == 175_000 * 1e6, "Payout a1 incorrecto");
        require(receiver.lpBalances(alice) == 0, "LP no quemado");
        require(token0.balanceOf(alice) == 50 ether, "Payout token0 incorrecto");
        require(token1.balanceOf(alice) == 175_000 * 1e6, "Payout token1 incorrecto");
        require(receiver.totalLpSupply() == 50, "Total LP supply incorrecto");
    }

    // 4. Verificación de control de acceso en mintLp (Inmune a emisión arbitraria)
    function test_4_UnauthorizedMintLpReverts() public {
        address attacker = address(0x6666);
        vm.prank(attacker);
        try receiver.mintLp(attacker, 1_000_000) {
            revert("TEST4_FAILED: Attacker should not be able to mint LP");
        } catch Error(string memory reason) {
            require(
                keccak256(bytes(reason)) == keccak256(bytes("NOT_LIQUIDITY_MANAGER")),
                "Unexpected revert reason"
            );
        }
    }

    // 5. Salvaguarda en unpauseTarget con verificación de precio mínimo de mercado
    function test_5_UnpauseRevertsIfMarketNotRestored() public {
        shield.registerTarget(address(pool), address(receiver));

        // Simular caída del 20% en el pool
        pool.setSlot0(894427, 79000);

        vm.prank(sentinelBot);
        shield.triggerEmergencyPause(address(pool));

        // Multifirma intenta despausar cuando el precio aún está deprimido
        vm.prank(gnosisSafe);
        try shield.unpauseTargetWithMinPrice(address(pool), 400000000000000000000000000000) {
            revert("TEST5_FAILED: Depressed pool unpause should revert");
        } catch Error(string memory reason) {
            require(
                keccak256(bytes(reason)) == keccak256(bytes("MARKET_NOT_RESTORED: PRICE_BELOW_MINIMUM")),
                "Unexpected revert reason"
            );
        }
    }
}
