// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./FullMath.sol";

/// @title Uniswap v3 Rigorous Invariant & Price Deviation Checker
/// @notice Computes exact quadratic price drop (P = sqrtP^2 / 2^192) and tick delta without raw balanceOf exposure
library UniswapV3InvariantChecker {
    uint256 internal constant BPS_DENOMINATOR = 10000;
    // 1 tick = ~1 bps (0.0100005%). 15% price crash corresponds to ln(0.85)/ln(1.0001) ~= 1625 ticks
    int24 internal constant TICK_DROP_15_PERCENT = 1625;

    /// @notice Computes exact percentage price drop using squared sqrtPriceX96 ratio
    /// @dev P_current / P_initial = (sqrtP_current / sqrtP_initial)^2
    /// @param initialSqrtPriceX96 Baseline price from slot0
    /// @param currentSqrtPriceX96 Current on-chain price from slot0
    /// @param maxDropBps Threshold in basis points (e.g., 1500 = 15%)
    /// @return dropExceeded True if price dropped by more than maxDropBps
    /// @return priceDropBps The computed price drop in basis points
    function checkExactPriceDrop(
        uint160 initialSqrtPriceX96,
        uint160 currentSqrtPriceX96,
        uint256 maxDropBps
    ) internal pure returns (bool dropExceeded, uint256 priceDropBps) {
        if (initialSqrtPriceX96 == 0 || currentSqrtPriceX96 >= initialSqrtPriceX96) {
            return (false, 0); // No drop (price increased or baseline invalid)
        }

        // sqrtRatio = (currentSqrtPriceX96 * 10000) / initialSqrtPriceX96
        uint256 sqrtRatioBps = FullMath.mulDiv(
            uint256(currentSqrtPriceX96),
            BPS_DENOMINATOR,
            uint256(initialSqrtPriceX96)
        );

        // priceRatioBps = (sqrtRatioBps^2) / 10000
        uint256 priceRatioBps = FullMath.mulDiv(
            sqrtRatioBps,
            sqrtRatioBps,
            BPS_DENOMINATOR
        );

        if (priceRatioBps >= BPS_DENOMINATOR) {
            return (false, 0);
        }

        priceDropBps = BPS_DENOMINATOR - priceRatioBps;
        dropExceeded = priceDropBps >= maxDropBps;
    }

    /// @notice Secondary validation via tick delta (immune to single-block token donations)
    function checkTickDelta(
        int24 initialTick,
        int24 currentTick,
        int24 maxTickDelta
    ) internal pure returns (bool deltaExceeded, int24 delta) {
        delta = initialTick - currentTick; // Positive if price dropped
        deltaExceeded = delta >= maxTickDelta;
    }
}
