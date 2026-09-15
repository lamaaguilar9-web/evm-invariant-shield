// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./FullMath.sol";

library UniswapV3InvariantChecker {
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

    function checkTickDelta(
        int24 initialTick,
        int24 currentTick,
        int24 maxTickDelta
    ) internal pure returns (bool tickExceeded, int24 delta) {
        delta = initialTick > currentTick ? initialTick - currentTick : currentTick - initialTick;
        tickExceeded = delta >= maxTickDelta;
    }
}
