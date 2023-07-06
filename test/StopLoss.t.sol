// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";

import {StopLossTestBase} from "./shared/StopLossTestBase.t.sol";

contract StopLossTest is StopLossTestBase {
    using PoolId for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;

    // see StopLossTestBase for "globals"

    function setUp() public {
        StopLossTestBase.initBase();

        StopLossTestBase.createPool();

        StopLossTestBase.createLiquidity();
    }

    // Place/open a stop loss position
    function test_place() public {
        int24 tick = 100;
        uint256 amount = 100e18;
        bool zeroForOne = true;

        uint256 balanceBefore = token0.balanceOf(address(this));
        token0.approve(address(hook), amount);

        // place the stop loss position to sell 100 tokens at tick 0
        int24 actualTick = hook.placeStopLoss(poolKey, tick, amount, zeroForOne);
        assertEq(actualTick, 60); // tick spacing of 60 means we "round" tick 100 to 60
        uint256 balanceAfter = token0.balanceOf(address(this));
        assertEq(balanceBefore - balanceAfter, amount);

        int256 stopLossAmt = hook.stopLossPositions(poolKey.toId(), actualTick, zeroForOne);
        assertEq(stopLossAmt, int256(amount));

        // contract received a receipt token
        uint256 tokenId = hook.getTokenId(poolKey, actualTick, zeroForOne);
        assertEq(tokenId != 0, true);
        uint256 receiptBal = hook.balanceOf(address(this), tokenId);
        assertEq(receiptBal, amount);
    }

    // TODO: make sure the oracle and hook init is synced (tick state)
    function testOracleInit() public {
        // populate the oracle
        swap(oracleKey, 2e18, false);
        oracle.setTime(oracle.time() + 60);

        swap(poolKey, 1e18, false);
    }

    function test_stoploss_oracle_zeroForOne() public {
        // place a stop loss at tick 100
        int24 tick = 100;
        uint256 amount = 10e18;
        bool zeroForOne = true;
        token0.approve(address(hook), amount);
        int24 actualTick = hook.placeStopLoss(poolKey, tick, amount, zeroForOne);

        // move the twap past 100 by swapping zeroForOne (buy currency1)
        swap(oracleKey, 2e18, false);
        oracle.setTime(oracle.time() + 60);
        int24 twapTick = observeMinuteTwap();
        assertEq(100 < twapTick, true);

        // perform a swap for stop loss execution
        swap(poolKey, 100 wei, false);

        // stoploss should be executed
        int256 stopLossAmt = hook.stopLossPositions(poolKey.toId(), tick, zeroForOne);
        assertEq(stopLossAmt, 0);

        // receipt tokens are redeemable for token1 (token0 was sold in the stop loss)
        uint256 tokenId = hook.getTokenId(poolKey, actualTick, zeroForOne);
        uint256 redeemable = hook.claimable(tokenId);
        assertEq(redeemable, token1.balanceOf(address(hook))); // we're the only holders so we can redeem it all

        // redeem all of the receipt for the underlying
        uint256 balanceBefore = token1.balanceOf(address(this));
        hook.redeem(tokenId, hook.balanceOf(address(this), tokenId), address(this));
        uint256 balanceAfter = token1.balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, redeemable);
        assertEq(token1.balanceOf(address(hook)), 0); // redeemed it all
    }
}
