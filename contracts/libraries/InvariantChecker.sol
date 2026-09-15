// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./FullMath.sol";

/// @title Gas-optimized Invariant Checker Library
/// @notice Computes in-memory k invariant checks and percentage drops in < 200 gas
library InvariantChecker {
    uint256 internal constant BPS_DENOMINATOR = 10000;

    function computeK(uint256 reserve0, uint256 reserve1) internal pure returns (uint256) {
        return FullMath.mulDiv(reserve0, reserve1, 1e18);
    }

    function checkInvariantDrop(
        uint256 initialK,
        uint256 currentK,
        uint256 maxDropBps
    ) internal pure returns (bool dropExceeded, uint256 dropBps) {
        if (currentK >= initialK) {
            return (false, 0);
        }
        uint256 diff = initialK - currentK;
        dropBps = FullMath.mulDiv(diff, BPS_DENOMINATOR, initialK);
        dropExceeded = dropBps >= maxDropBps;
    }
}
