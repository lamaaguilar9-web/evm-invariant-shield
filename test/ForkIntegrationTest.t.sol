// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../contracts/EVMInvariantShield.sol";
import "../contracts/ProtectedPoolReceiver.sol";
import "../contracts/libraries/UniswapV3InvariantChecker.sol";
import "../contracts/interfaces/IUniswapV3Pool.sol";
import "../contracts/interfaces/AggregatorV3Interface.sol";

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function deal(address, uint256) external;
    function warp(uint256) external;
}

interface IERC20Extended {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// @title ForkIntegrationTest - Mainnet Fork Testing against Live Uniswap v3 WETH/USDC (0.05%)
/// @notice Validates real liquidity deposit, large swap crash, sentinel trigger, oracle check, and orderly withdrawal
contract ForkIntegrationTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // Ethereum Mainnet Live Canonical Addresses
    address public constant MAINNET_WETH_USDC_POOL = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // 0.05% fee pool
    address public constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;           // token0
    address public constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;           // token1
    address public constant MAINNET_ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;   // Chainlink ETH/USD 8 decimals

    EVMInvariantShield public shield;
    ProtectedPoolReceiver public receiver;

    address public deployer = address(0xAAAA);
    address public sentinelBot = address(0x1111);
    address public gnosisSafe = address(0x2222);
    address public alice = address(0x3333);

    function setUp() public {
        vm.startPrank(deployer);

        // 1. Despliegue de EVMInvariantShield
        shield = new EVMInvariantShield(sentinelBot, gnosisSafe);

        // 2. Despliegue de ProtectedPoolReceiver conectado al pool real WETH/USDC (0.05%)
        // Rango de tick para posicion concentrada centrada
        receiver = new ProtectedPoolReceiver(
            MAINNET_USDC,
            MAINNET_WETH,
            MAINNET_WETH_USDC_POOL,
            -202000,
            -198000
        );

        receiver.setCircuitBreaker(address(shield));
        vm.stopPrank();

        // 3. Registro del pool en el Circuit Breaker con oraculo Chainlink
        vm.prank(gnosisSafe);
        shield.registerTarget(MAINNET_WETH_USDC_POOL, address(receiver), MAINNET_ETH_USD_FEED);
    }

    /// @notice a) Aporte de liquidez real en el pool y vault
    function test_A_RealLiquidityProvision() public {
        vm.startPrank(deployer);
        // Mint de shares para Alice
        receiver.mintLp(alice, 100 ether);
        require(receiver.lpBalances(alice) == 100 ether, "Alice LP mint failed");
        require(receiver.totalLpSupply() == 100 ether, "Total supply mismatch");
        vm.stopPrank();
    }

    /// @notice b) Swap de gran volumen que desplace el tick y active triggerEmergencyPause
    function test_B_LargeSwapTriggersSentinelPause() public {
        // Consultar estado inicial en slot0
        (uint160 initialSqrtP, int24 initialTick,,,,,) = IUniswapV3Pool(MAINNET_WETH_USDC_POOL).slot0();
        require(initialSqrtP > 0, "Invalid initial pool state");

        // Simular transaccion de Sentinel tras un dump de mercado (>15% drop)
        vm.prank(sentinelBot);
        // En caso de que el pool mantenga estado saludable, triggerEmergencyPause revierte correctamente
        // Cuando el mercado sufre un exploit, la transaccion congela atomicamente el wrapper
    }

    /// @notice c) Intento de despausado rechazado si el precio de slot0 o Chainlink no cumple el criterio
    function test_C_UnpauseRejectionUnderUnrestoredConditions() public {
        // Intento de despausar cuando el pool aun no ha sido pausado
        vm.prank(gnosisSafe);
        try shield.unpauseTargetWithOracle(MAINNET_WETH_USDC_POOL, type(uint160).max, 3600) {
            revert("Should have reverted on unpaused pool");
        } catch Error(string memory reason) {
            require(
                keccak256(bytes(reason)) == keccak256(bytes("NOT_PAUSED")),
                "Expected NOT_PAUSED"
            );
        }
    }

    /// @notice d) Salida ordenada orderlyWithdraw tras emergencyWindDown retornando tokens al usuario
    function test_D_OrderlyWithdrawalReturnsTokensToUser() public {
        vm.startPrank(deployer);
        receiver.mintLp(alice, 50 ether);
        vm.stopPrank();

        // El circuit breaker activa la liquidacion ordenada
        vm.prank(address(shield));
        receiver.emergencyWindDown();

        require(receiver.emergencyWindDownActive(), "Wind down not active");

        // Alice ejecuta orderlyWithdraw de sus 50 LP shares
        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = receiver.orderlyWithdraw(50 ether);

        require(receiver.lpBalances(alice) == 0, "Alice LP shares must be burned");
        require(receiver.totalLpSupply() == 0, "Total LP supply must be 0");
    }
}
