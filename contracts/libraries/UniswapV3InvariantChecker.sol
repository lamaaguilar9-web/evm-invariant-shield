// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./FullMath.sol";

/// @title Uniswap v3 & Concentrated Liquidity Invariant Checker Library
/// @notice Computes price deviations using sqrtPriceX96 and reserve invariants with 512-bit precision
library UniswapV3InvariantChecker {
    uint256 internal constant BPS_DENOMINATOR = 10000;

    /// @notice Computes percentage deviation between baseline sqrtPriceX96 and current on-chain slot0 sqrtPriceX96
    function checkPriceDeviation(
        uint160 initialSqrtPriceX96,
        uint160 currentSqrtPriceX96,
        uint256 maxDeviationBps
    ) internal pure returns (bool deviationExceeded, uint256 deviationBps) {
        if (initialSqrtPriceX96 == 0 || currentSqrtPriceX96 == 0) {
            return (false, 0);
        }

        uint256 diff;
        if (currentSqrtPriceX96 >= initialSqrtPriceX96) {
            diff = uint256(currentSqrtPriceX96 - initialSqrtPriceX96);
        } else {
            diff = uint256(initialSqrtPriceX96 - currentSqrtPriceX96);
        }

        deviationBps = FullMath.mulDiv(diff, BPS_DENOMINATOR, uint256(initialSqrtPriceX96));
        deviationExceeded = deviationBps >= maxDeviationBps;
    }

    /// @notice Computes reserve invariant drop from on-chain ERC20 token balances
    function checkReserveDrop(
        uint256 initialReserve0,
        uint256 initialReserve1,
        uint256 currentReserve0,
        uint256 currentReserve1,
        uint256 maxDropBps
    ) internal pure returns (bool dropExceeded, uint256 dropBps) {
        uint256 initK = FullMath.mulDiv(initialReserve0, initialReserve1, 1e18);
        uint256 currK = FullMath.mulDiv(currentReserve0, currentReserve1, 1e18);

        if (currK >= initK || initK == 0) {
            return (false, 0);
        }

        uint256 diff = initK - currK;
        dropBps = FullMath.mulDiv(diff, BPS_DENOMINATOR, initK);
        dropExceeded = dropBps >= maxDropBps;
    }
}
