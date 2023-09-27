// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";

import {StopLossTestBase} from "../shared/StopLossTestBase.t.sol";
import {IPool as ISparkPool} from "aave-v3-core/contracts/interfaces/IPool.sol";
import {ICometMinimal} from "./interfaces/ICometMinimal.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract Compound3Test is StopLossTestBase {
    using PoolId for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;

    // see StopLossTestBase for additional "globals"

    ICometMinimal comet;
    IERC20 USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function setUp() public {
        StopLossTestBase.initBase();

        // Create a V4 pool ETH/USDC at price 1700 USDC/ETH
        initPool();

        // Use 1 ETH to borrow 1500 USDC
        initComet();
    }

    function test_cometRepay() public {
        assertEq(WETH.balanceOf(address(this)), 0);
        assertEq(USDC.balanceOf(address(this)), 1200e6);

        // cannot withdraw ETH because of health factor
        vm.expectRevert();
        comet.withdraw(address(WETH), 0.75e18);

        // use borrowed USDC to buy ETH
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1200e6,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(poolKey, params, testSettings);
        // // ------------------- //

        assertEq(USDC.balanceOf(address(this)), 0);
        assertEq(WETH.balanceOf(address(this)) > 0.25e18, true);

        // create a stop loss: sell all of the ETH for USDC if ETH trades for less than 1650
        int24 tick = TickMath.getTickAtSqrtRatio(1950462530286735294571872055596685); // sqrt(1e18/1650e6) * 2**96
        uint256 amount = WETH.balanceOf(address(this));

        WETH.approve(address(hook), amount);
        int24 actualTick = hook.placeStopLoss(poolKey, tick, amount, false);
        uint256 tokenId = hook.getTokenId(poolKey, actualTick, false);
        assertEq(hook.balanceOf(address(this), tokenId) > 0, true);

        // trigger the stop loss
        forceStopLoss();

        // claim the USDC
        uint256 redeemable = hook.claimable(tokenId);
        assertEq(redeemable > 0, true);
        hook.redeem(tokenId, hook.balanceOf(address(this), tokenId), address(this));
        assertEq(USDC.balanceOf(address(this)), redeemable);

        // repay the USDC
        USDC.approve(address(comet), redeemable);
        comet.supply(address(USDC), redeemable);

        // can withdraw some of the collateral
        comet.withdraw(address(WETH), 0.75e18);
    }

    // -- Helpers -- //
    function initPool() internal {
        // Create the pool: USDC/ETH
        poolKey =
            IPoolManager.PoolKey(Currency.wrap(address(USDC)), Currency.wrap(address(WETH)), 3000, 60, IHooks(hook));
        assertEq(Currency.unwrap(poolKey.currency0), address(USDC));
        poolId = PoolId.toId(poolKey);
        // sqrt(1e18/1700e6) * 2**96
        uint160 sqrtPriceX96 = 1921565191587726726404356176259791;
        manager.initialize(poolKey, sqrtPriceX96);

        // create oracle pool
        oracleKey = IPoolManager.PoolKey(
            Currency.wrap(address(USDC)), Currency.wrap(address(WETH)), 0, manager.MAX_TICK_SPACING(), IHooks(oracle)
        );
        manager.initialize(oracleKey, sqrtPriceX96);

        // Provide liquidity to the pool
        uint256 usdcAmount = 170_000e6;
        uint256 wethAmount = 100 ether;
        deal(address(USDC), address(this), usdcAmount);
        deal(address(WETH), address(this), wethAmount);
        USDC.approve(address(modifyPositionRouter), usdcAmount);
        WETH.approve(address(modifyPositionRouter), wethAmount);

        // provide liquidity on the range [1300, 2100] (+/- 400 from 1700)
        int24 upperTick = TickMath.getTickAtSqrtRatio(2197393864661338517058162432861171); // sqrt(1e18/1300e6) * 2**96
        int24 lowerTick = TickMath.getTickAtSqrtRatio(1728900247113710138698944077582074); // sqrt(1e18/2100e6) * 2**96
        lowerTick = lowerTick - (lowerTick % 60); // round down to multiple of tick spacing
        upperTick = upperTick - (upperTick % 60); // round down to multiple of tick spacing

        // random approximation, uses about 80 ETH and 168,500 USDC
        int256 liquidity = 0.325e17;
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(lowerTick, upperTick, liquidity));

        usdcAmount = 1_000_000e6;
        wethAmount = 250e18;
        deal(address(USDC), address(this), usdcAmount);
        USDC.approve(address(modifyPositionRouter), usdcAmount);
        deal(address(WETH), address(this), wethAmount);
        WETH.approve(address(modifyPositionRouter), wethAmount);
        modifyPositionRouter.modifyPosition(
            oracleKey,
            IPoolManager.ModifyPositionParams(
                TickMath.minUsableTick(manager.MAX_TICK_SPACING()),
                TickMath.maxUsableTick(manager.MAX_TICK_SPACING()),
                10_000e12
            )
        );

        // Approve for swapping
        USDC.approve(address(swapRouter), 2 ** 128);
        WETH.approve(address(swapRouter), 2 ** 128);

        swap(oracleKey, 100 wei, false);
        oracle.setTime(oracle.time() + 60);

        // clear out delt tokens
        deal(address(USDC), address(this), 0);
        deal(address(WETH), address(this), 0);
        assertEq(USDC.balanceOf(address(this)), 0);
        assertEq(WETH.balanceOf(address(this)), 0);
    }

    function initComet() internal {
        comet = ICometMinimal(address(0xc3d688B66703497DAA19211EEdff47f25384cdc3));

        // supply 1 ETH as collateral
        deal(address(WETH), address(this), 1e18);
        WETH.approve(address(comet), 1e18);
        comet.supply(address(WETH), 1e18);

        // borrow 1200 USDC, on the variable pool
        uint256 amount = 1200e6;
        comet.withdraw(address(USDC), amount);
    }

    // Execute trades to force stop loss execution to occur
    function forceStopLoss() internal {
        // Dump ETH past the tick trigger
        uint256 wethAmount = 50e18;
        deal(address(WETH), address(this), wethAmount);
        swap(oracleKey, int256(wethAmount), false);
        oracle.setTime(oracle.time() + 3000);

        // perform a swap for stop loss execution
        uint256 usdcAmount = 100 wei;
        deal(address(USDC), address(this), usdcAmount);
        swap(poolKey, int256(usdcAmount), true);
    }
}
