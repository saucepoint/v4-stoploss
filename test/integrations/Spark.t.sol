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
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract SparkTest is StopLossTestBase {
    using PoolId for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;

    // see StopLossTestBase for additional "globals"

    ISparkPool sparkPool;
    IERC20 DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function setUp() public {
        StopLossTestBase.initBase();

        // Create a V4 pool ETH/DAI at price 1700 DAI/ETH
        initPool();

        // Use 1 ETH to borrow 1500 DAI
        initSpark();
    }

    function test_sparkRepay() public {
        assertEq(WETH.balanceOf(address(this)), 0);
        assertEq(DAI.balanceOf(address(this)), 1200e18);

        // cannot withdraw ETH because of health factor
        vm.expectRevert();
        sparkPool.withdraw(address(WETH), 0.75e18, address(this));

        // use borrowed Dai to buy ETH
        swap(poolKey, 1200e18, true);

        assertEq(DAI.balanceOf(address(this)), 0);
        assertEq(WETH.balanceOf(address(this)) > 0.25e18, true);

        // create a stop loss: sell all of the ETH for Dai if ETH trades for less than 1650
        int24 tick = TickMath.getTickAtSqrtRatio(1950462530286735294571872055); // sqrt(1/1650) * 2**96
        uint256 amount = WETH.balanceOf(address(this));

        WETH.approve(address(hook), amount);
        int24 actualTick = hook.placeStopLoss(poolKey, tick, amount, false);
        uint256 tokenId = hook.getTokenId(poolKey, actualTick, false);
        assertEq(hook.balanceOf(address(this), tokenId) > 0, true);

        // trigger the stop loss
        forceStopLoss();

        // claim the Dai
        uint256 redeemable = hook.claimable(tokenId);
        assertEq(redeemable > 0, true);
        hook.redeem(tokenId, hook.balanceOf(address(this), tokenId), address(this));
        assertEq(DAI.balanceOf(address(this)), redeemable);

        // repay the Dai
        DAI.approve(address(sparkPool), redeemable);
        sparkPool.repay(address(DAI), redeemable, 2, address(this));

        // can withdraw some of the collateral
        sparkPool.withdraw(address(WETH), 0.75e18, address(this));
    }

    // -- Helpers -- //
    function initPool() internal {
        // Create the pool: DAI/ETH
        poolKey =
            IPoolManager.PoolKey(Currency.wrap(address(DAI)), Currency.wrap(address(WETH)), 3000, 60, IHooks(hook));
        assertEq(Currency.unwrap(poolKey.currency0), address(DAI));
        poolId = PoolId.toId(poolKey);
        // sqrt(1e18/1700e18) * 2**96
        uint160 sqrtPriceX96 = 1921565191587726726404356176;
        manager.initialize(poolKey, sqrtPriceX96);

        // create oracle pool
        oracleKey = IPoolManager.PoolKey(
            Currency.wrap(address(DAI)), Currency.wrap(address(WETH)), 0, manager.MAX_TICK_SPACING(), IHooks(oracle)
        );
        manager.initialize(oracleKey, sqrtPriceX96);

        // Provide liquidity to the pool
        uint256 daiAmount = 1700 * 100 ether;
        uint256 wethAmount = 100 ether;
        deal(address(DAI), address(this), daiAmount);
        deal(address(WETH), address(this), wethAmount);
        DAI.approve(address(modifyPositionRouter), daiAmount);
        WETH.approve(address(modifyPositionRouter), wethAmount);

        // provide liquidity on the range [1300, 2100] (+/- 400 from 1700)
        int24 upperTick = TickMath.getTickAtSqrtRatio(2197393864661338517058162432); // sqrt(1e18/1300e18) * 2**96
        int24 lowerTick = TickMath.getTickAtSqrtRatio(1728900247113710138698944077); // sqrt(1e18/2100e18) * 2**96
        lowerTick = lowerTick - (lowerTick % 60); // round down to multiple of tick spacing
        upperTick = upperTick - (upperTick % 60); // round down to multiple of tick spacing

        // random approximation, uses about 80 ETH and 168,500 DAI
        int256 liquidity = 32_500e18;
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(lowerTick, upperTick, liquidity));

        daiAmount = 1_000_000e18;
        wethAmount = 250e18;
        deal(address(DAI), address(this), daiAmount);
        DAI.approve(address(modifyPositionRouter), daiAmount);
        deal(address(WETH), address(this), wethAmount);
        WETH.approve(address(modifyPositionRouter), wethAmount);
        modifyPositionRouter.modifyPosition(
            oracleKey,
            IPoolManager.ModifyPositionParams(
                TickMath.minUsableTick(manager.MAX_TICK_SPACING()),
                TickMath.maxUsableTick(manager.MAX_TICK_SPACING()),
                10_000e18
            )
        );

        // Approve for swapping
        DAI.approve(address(swapRouter), 2 ** 128);
        WETH.approve(address(swapRouter), 2 ** 128);

        swap(oracleKey, 100 wei, false);
        oracle.setTime(oracle.time() + 60);

        // clear out delt tokens
        deal(address(DAI), address(this), 0);
        deal(address(WETH), address(this), 0);
        assertEq(DAI.balanceOf(address(this)), 0);
        assertEq(WETH.balanceOf(address(this)), 0);
    }

    function initSpark() internal {
        sparkPool = ISparkPool(address(0xC13e21B648A5Ee794902342038FF3aDAB66BE987));

        // supply 1 ETH as collateral
        deal(address(WETH), address(this), 1e18);
        WETH.approve(address(sparkPool), 1e18);
        sparkPool.supply(address(WETH), 1e18, address(this), 0);

        // borrow 1200 DAI, on the variable pool
        uint256 amount = 1200e18;
        sparkPool.borrow(address(DAI), amount, 2, 0, address(this));
    }

    // Execute trades to force stop loss execution to occur
    function forceStopLoss() internal {
        // Dump ETH past the tick trigger
        uint256 wethAmount = 50e18;
        deal(address(WETH), address(this), wethAmount);
        swap(oracleKey, int256(wethAmount), false);
        oracle.setTime(oracle.time() + 3000);

        // perform a swap for stop loss execution
        uint256 daiAmount = 100 wei;
        deal(address(DAI), address(this), daiAmount);
        swap(poolKey, int256(daiAmount), true);
    }
}
