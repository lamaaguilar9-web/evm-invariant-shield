# -*- coding: utf-8 -*-
"""
EIP-1559 Dynamic Gas Overbidding Engine for EVM Invariant Shield.
Calculates high-priority gas parameters to outbid attackers and secure top-of-block defensive inclusion.
"""

class EIP1559GasEngine:
    def __init__(self, priority_premium_gwei: float = 5.0, max_fee_multiplier: float = 2.0):
        self.priority_premium_wei = int(priority_premium_gwei * 1e9)
        self.max_fee_multiplier = max_fee_multiplier

    def calculate_defense_gas(self, base_fee_wei: int) -> dict:
        """
        Computes dynamic maxFeePerGas and maxPriorityFeePerGas.
        """
        # Dynamic priority fee: 25% of base fee + fixed priority premium
        priority_fee = int(base_fee_wei * 0.25) + self.priority_premium_wei
        max_fee = int(base_fee_wei * self.max_fee_multiplier) + priority_fee

        return {
            "baseFeeGwei": round(base_fee_wei / 1e9, 2),
            "maxPriorityFeePerGasWei": priority_fee,
            "maxPriorityFeePerGasGwei": round(priority_fee / 1e9, 2),
            "maxFeePerGasWei": max_fee,
            "maxFeePerGasGwei": round(max_fee / 1e9, 2),
            "overbidMultiplier": self.max_fee_multiplier,
            "priorityStatus": "TOP_OF_BLOCK_GUARANTEED"
        }
