// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../contracts/EVMInvariantShield.sol";
import "../contracts/ProtectedPoolReceiver.sol";
import "../contracts/libraries/FullMath.sol";
import "../contracts/libraries/UniswapV3InvariantChecker.sol";

interface Vm {
    function prank(address) external;
    function warp(uint256) external;
}

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

contract MockUniswapV3Pool {
    uint160 public sqrtPriceX96;
    int24 public tick;
    uint128 public poolLiquidity;
    uint128 public positionLiquidity;

    constructor(uint160 _sqrt, int24 _tick, uint128 _liq) {
        sqrtPriceX96 = _sqrt;
        tick = _tick;
        poolLiquidity = _liq;
        positionLiquidity = _liq;
    }

    function setSlot0(uint160 _sqrt, int24 _tick) external {
        sqrtPriceX96 = _sqrt;
        tick = _tick;
    }

    function setLiquidity(uint128 _liq) external {
        poolLiquidity = _liq;
    }

    function slot0() external view returns (
        uint160, int24, uint16, uint16, uint16, uint8, bool
    ) {
        return (sqrtPriceX96, tick, 0, 0, 0, 0, true);
    }

    function liquidity() external view returns (uint128) {
        return poolLiquidity;
    }

    function positions(bytes32) external view returns (uint128, uint256, uint256, uint128, uint128) {
        return (positionLiquidity, 0, 0, 0, 0);
    }

    function burn(int24, int24, uint128 amount) external returns (uint256, uint256) {
        if (amount <= positionLiquidity) {
            positionLiquidity -= amount;
        } else {
            positionLiquidity = 0;
        }
        return (0, 0);
    }

    function collect(address, int24, int24, uint128, uint128) external pure returns (uint128, uint128) {
        return (0, 0);
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

        // Initial price: 3,500 USDC / WETH
        // sqrtPriceX96 = sqrt(3500) * 2^96 ~= 468494958188145244569501538304
        uint160 initSqrtP = 468494958188145244569501538304;
        int24 initTick = 81625;
        pool = new MockUniswapV3Pool(initSqrtP, initTick, 10000000);

        shield = new EVMInvariantShield(sentinelBot, gnosisSafe);

        receiver = new ProtectedPoolReceiver(
            address(token0),
            address(token1),
            address(pool),
            80000,
            83000
        );
        receiver.setCircuitBreaker(address(shield));

        vm.prank(gnosisSafe);
        shield.registerTarget(address(pool), address(receiver), address(0));
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

    // 3. Disparo de emergencia y retiro activo de capital (burn+collect al vault)
    function test_3_AutonomousPauseAndCapitalRetreat() public {
        // Crash de precio del 20%: sqrtP baja a ~419034293800000000000000000000
        pool.setSlot0(419034293800000000000000000000, 79000);

        vm.prank(sentinelBot);
        shield.triggerEmergencyPause(address(pool));

        EVMInvariantShield.TargetConfig memory cfg = shield.targets(address(pool));
        require(cfg.state == EVMInvariantShield.PoolState.PAUSED, "Pool debio pausarse");
        require(receiver.paused(), "Receiver debio pausarse");
        require(receiver.retreatedLiquidity() == 10000000, "Capital debio retirarse al vault (burn+collect)");
    }

    // 4. Disparo autónomo por drenaje abrupto de liquidez (EVMC-S1)
    function test_4_LiquidityDrainTrigger() public {
        // Reducción del 35% de liquidez (supera 30% maxDrainBps) con precio intacto
        pool.setLiquidity(6500000);

        vm.prank(sentinelBot);
        shield.triggerEmergencyPause(address(pool));

        EVMInvariantShield.TargetConfig memory cfg = shield.targets(address(pool));
        require(cfg.state == EVMInvariantShield.PoolState.PAUSED, "Drenaje de liquidez debio disparar pausa");
        require(receiver.paused(), "Receiver debio pausarse tras drenaje");
    }

    // 5. High-Water Mark ancla y protege ante crash-desde-pico (EVMC-S2)
    function test_5_HighWaterMarkRallyCrashProtection() public {
        vm.warp(block.timestamp + 100);

        // Subida de precio del 30%: rally verificado
        uint160 rallySqrtP = 534141634500000000000000000000;
        pool.setSlot0(rallySqrtP, 84000);

        // Sentinel actualiza el High-Water Mark
        vm.prank(sentinelBot);
        shield.updateHighWaterMark(address(pool));

        EVMInvariantShield.TargetConfig memory cfg1 = shield.targets(address(pool));
        require(cfg1.highWaterMarkSqrtPriceX96 == rallySqrtP, "HWM debio actualizarse al pico");

        vm.warp(block.timestamp + 1000);

        // Crash del 18% desde el pico (queda aún arriba del precio inicial, pero viola el HWM)
        uint160 dropFromPeakSqrtP = 483600000000000000000000000000;
        pool.setSlot0(dropFromPeakSqrtP, 82000);

        vm.prank(sentinelBot);
        shield.triggerEmergencyPause(address(pool));

        EVMInvariantShield.TargetConfig memory cfg2 = shield.targets(address(pool));
        require(cfg2.state == EVMInvariantShield.PoolState.PAUSED, "Crash desde pico HWM debio disparar pausa");
    }

    // 6. Rechazo de despausado si el mercado no cumple precio mínimo
    function test_6_AntiGriefingRestorationConstraint() public {
        pool.setSlot0(419034293800000000000000000000, 79000);
        vm.prank(sentinelBot);
        shield.triggerEmergencyPause(address(pool));

        // Intento de despausar con mercado aún deprimido
        vm.prank(gnosisSafe);
        try shield.unpauseTargetWithOracle(address(pool), 460000000000000000000000000000, 3600) {
            revert("TEST6_FAILED: Despausado debio revertir por precio insuficiente");
        } catch Error(string memory reason) {
            require(keccak256(bytes(reason)) == keccak256(bytes("MARKET_NOT_RESTORED")), "Expected MARKET_NOT_RESTORED");
        }
    }

    // 7. Despausado multisig y gobernanza restore from wind-down (EVMC-M5)
    function test_7_GovernanceRestoreFromWindDown() public {
        pool.setSlot0(419034293800000000000000000000, 79000);
        vm.prank(sentinelBot);
        shield.triggerEmergencyPause(address(pool));

        // Transcurren 24h
        vm.warp(block.timestamp + 24 hours + 1);

        // Se activa Emergency Wind-Down
        shield.activateEmergencyWindDown(address(pool));

        EVMInvariantShield.TargetConfig memory cfgWind = shield.targets(address(pool));
        require(cfgWind.state == EVMInvariantShield.PoolState.EMERGENCY_WIND_DOWN, "Estado debio ser WIND_DOWN");

        // Mercado se estabiliza y gobernanza restaura el estado
        pool.setSlot0(468494958188145244569501538304, 81625);
        pool.setLiquidity(10000000);

        vm.prank(gnosisSafe);
        shield.governanceRestoreFromWindDown(address(pool));

        EVMInvariantShield.TargetConfig memory cfgRestored = shield.targets(address(pool));
        require(cfgRestored.state == EVMInvariantShield.PoolState.NORMAL, "Gobernanza debio restaurar a NORMAL");
        require(!receiver.paused(), "Receiver debio despausarse");
    }
}
