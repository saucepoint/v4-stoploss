
## Spark -- Loan repayment
Assumes you borrowed Dai, using Ether as collateral, to obtain exposure to PEPE.
```solidity
    // create a stop loss: sell all of the PEPE for Dai if PEPE trades for less than $0.00000150
    int24 tick = TickMath.getTickAtSqrtRatio(<num>); // sqrt(currency1/currency0) * 2**96
    uint256 amount = PEPE.balanceOf(address(this));

    bool zeroForOne = false; // assume that PEPE is currency1. so trade currency1 for currency0 (Dai)

    int24 actualTick = hook.placeStopLoss(poolKey, tick, amount, zeroForOne);
    uint256 tokenId = hook.getTokenId(poolKey, actualTick, false);

    // claim the Dai, after the order is executed
    hook.redeem(tokenId, hook.balanceOf(address(this), tokenId), address(this));

    // repay the Dai
    sparkPool.repay(address(DAI), redeemable, 2, address(this));
```

See [test/Spark.t.sol](../test/integrations/Spark.t.sol) for a working example

## Compound III -- Loan repayment
Assumes you borrowed USDC, using Ether as collateral, to obtain exposure to PEPE.
```solidity
    // create a stop loss: sell all of the PEPE for USDC if PEPE trades for less than $0.00000150
    int24 tick = TickMath.getTickAtSqrtRatio(<num>); // sqrt(currency1/currency0) * 2**96
    uint256 amount = PEPE.balanceOf(address(this));

    bool zeroForOne = false; // assume that PEPE is currency1. so trade currency1 for currency0 (USDC)

    int24 actualTick = hook.placeStopLoss(poolKey, tick, amount, zeroForOne);
    uint256 tokenId = hook.getTokenId(poolKey, actualTick, false);

    // claim the USDC, after the order is executed
    hook.redeem(tokenId, hook.balanceOf(address(this), tokenId), address(this));

    // repay the USDC
    comet.supply(address(USDC), redeemable);
```

See [test/Compound3.t.sol](../test/integrations/Compound3.t.sol) for a working example

---

A note on redeeming proceeds:

Currently external automation is required to repay loans, since stop-loss-proceeds are claimed asynchronously. This is a limitation because "pushing" the proceeds to many parties is not scalable. In an ideal scenario, the ERC-1155 receipt tokens are acceptable forms of "repayment". After creating a stop loss position, the receipt token can be transferred to the lending protocol which can be unwound for depositors. Another potential implementation is having liquidation conditions account for the receipt tokens.