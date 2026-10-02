// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./FullMath.sol";

/// @title UniswapV3InvariantChecker - Invariant Validation Library for Uniswap v3 on Ethereum L1
/// @notice Computes quadratic price drops, tick divergences, and liquidity drops with zero overflow
library UniswapV3InvariantChecker {
    /// @notice Computes exact quadratic price drop in basis points (10000 = 100%)
    /// @dev P = (sqrtPriceX96)^2 / 2^192. Ratio of prices = (currentSqrt / initialSqrt)^2
    function checkExactPriceDrop(
        uint160 initialSqrtPriceX96,
        uint160 currentSqrtPriceX96,
        uint256 maxDropBps
    ) internal pure returns (bool dropExceeded, uint256 priceDropBps) {
        if (currentSqrtPriceX96 >= initialSqrtPriceX96) {
            return (false, 0);
        }

        uint256 ratio = FullMath.mulDiv(uint256(currentSqrtPriceX96), 10000, uint256(initialSqrtPriceX96));
        uint256 priceRatio = FullMath.mulDiv(ratio, ratio, 10000);

        if (priceRatio < 10000) {
            priceDropBps = 10000 - priceRatio;
        } else {
            priceDropBps = 0;
        }

        dropExceeded = priceDropBps >= maxDropBps;
    }

    /// @notice Computes tick delta between observations
    function checkTickDelta(
        int24 initialTick,
        int24 currentTick,
        int24 maxTickDelta
    ) internal pure returns (bool tickExceeded, int24 delta) {
        delta = initialTick > currentTick ? initialTick - currentTick : currentTick - initialTick;
        tickExceeded = delta >= maxTickDelta;
    }

    /// @notice Computes sudden concentrated active liquidity drainage in basis points
    function checkLiquidityDrain(
        uint128 initialLiquidity,
        uint128 currentLiquidity,
        uint256 maxDrainBps
    ) internal pure returns (bool drainExceeded, uint256 drainBps) {
        if (currentLiquidity >= initialLiquidity || initialLiquidity == 0) {
            return (false, 0);
        }

        uint256 drop = uint256(initialLiquidity - currentLiquidity);
        drainBps = FullMath.mulDiv(drop, 10000, uint256(initialLiquidity));
        drainExceeded = drainBps >= maxDrainBps;
    }
}
