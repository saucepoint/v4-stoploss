// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/contracts/test/PoolDonateTest.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {StopLoss} from "../../src/StopLoss.sol";
import {StopLossImplementation} from "../../src/implementation/StopLossImplementation.sol";
import {ICometMinimal} from "./interfaces/ICometMinimal.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract Compound3Test is Test, Deployers, GasSnapshot {
    using PoolId for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;

    StopLoss hook = StopLoss(address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)));
    PoolManager manager;
    PoolModifyPositionTest modifyPositionRouter;
    PoolSwapTest swapRouter;
    TestERC20 _tokenA;
    TestERC20 _tokenB;
    TestERC20 token0;
    TestERC20 token1;
    IPoolManager.PoolKey poolKey;
    bytes32 poolId;

    ICometMinimal comet;
    IERC20 USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function setUp() public {
        // Create a V4 pool ETH/DAI at price 1700 DAI/ETH
        initV4();

        // Use 1 ETH to borrow 1500 DAI
        initComet();
    }

    function test_cometRepay() public {
        assertEq(WETH.balanceOf(address(this)), 0);
        assertEq(DAI.balanceOf(address(this)), 1200e18);

        // cannot withdraw ETH because of health factor
        vm.expectRevert();
        comet.withdraw(address(WETH), 0.75e18, address(this));

        // use borrowed Dai to buy ETH
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1200e18,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(poolKey, params, testSettings);
        // // ------------------- //

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
        forceStopLoss(actualTick);

        // claim the Dai
        uint256 redeemable = hook.claimable(tokenId);
        assertEq(redeemable > 0, true);
        hook.redeem(tokenId, hook.balanceOf(address(this), tokenId), address(this));
        assertEq(DAI.balanceOf(address(this)), redeemable);

        // repay the Dai
        DAI.approve(address(comet), redeemable);
        comet.repay(address(DAI), redeemable, 2, address(this));

        // can withdraw some of the collateral
        comet.withdraw(address(WETH), 0.75e18, address(this));
    }

    // -- Helpers -- //
    function initV4() internal {
        _tokenA = new TestERC20(2**128);
        _tokenB = new TestERC20(2**128);

        if (address(_tokenA) < address(_tokenB)) {
            token0 = _tokenA;
            token1 = _tokenB;
        } else {
            token0 = _tokenB;
            token1 = _tokenA;
        }

        manager = new PoolManager(500000);

        // testing environment requires our contract to override `validateHookAddress`
        // well do that via the Implementation contract to avoid deploying the override with the production contract
        StopLossImplementation impl = new StopLossImplementation(manager, hook);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(hook), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(hook), slot, vm.load(address(impl), slot));
            }
        }

        // Create the pool: DAI/ETH
        poolKey =
            IPoolManager.PoolKey(Currency.wrap(address(DAI)), Currency.wrap(address(WETH)), 3000, 60, IHooks(hook));
        assertEq(Currency.unwrap(poolKey.currency0), address(DAI));
        poolId = PoolId.toId(poolKey);
        // sqrt(1700e18) * 2**96
        uint160 sqrtPriceX96 = 1921565191587726726404356176;
        manager.initialize(poolKey, sqrtPriceX96);

        // Helpers for interacting with the pool
        modifyPositionRouter = new PoolModifyPositionTest(IPoolManager(address(manager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));

        // Provide liquidity to the pool
        uint256 daiAmount = 1700 * 100 ether;
        uint256 wethAmount = 100 ether;
        deal(address(DAI), address(this), daiAmount);
        deal(address(WETH), address(this), wethAmount);
        DAI.approve(address(modifyPositionRouter), daiAmount);
        WETH.approve(address(modifyPositionRouter), wethAmount);

        // provide liquidity on the range [1300, 2100] (+/- 400 from 1700)
        int24 upperTick = TickMath.getTickAtSqrtRatio(2197393864661338517058162432); // sqrt(1300e18) * 2**96
        int24 lowerTick = TickMath.getTickAtSqrtRatio(1728900247113710138698944077); // sqrt(2100e18) * 2**96
        lowerTick = lowerTick - (lowerTick % 60); // round down to multiple of tick spacing
        upperTick = upperTick - (upperTick % 60); // round down to multiple of tick spacing

        // random approximation, uses about 80 ETH and 168,500 DAI
        int256 liquidity = 32_500e18;
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(lowerTick, upperTick, liquidity));

        // Approve for swapping
        DAI.approve(address(swapRouter), 2 ** 128);
        WETH.approve(address(swapRouter), 2 ** 128);

        // clear out delt tokens
        deal(address(DAI), address(this), 0);
        deal(address(WETH), address(this), 0);
        assertEq(DAI.balanceOf(address(this)), 0);
        assertEq(WETH.balanceOf(address(this)), 0);
    }

    function initComet() internal {
        comet = ICometMinimal(address(0xc3d688B66703497DAA19211EEdff47f25384cdc3));

        // supply 1 ETH as collateral
        deal(address(WETH), address(this), 1e18);
        WETH.approve(address(comet), 1e18);
        comet.supply(address(WETH), 1e18);

        // borrow 1200 DAI, on the variable pool
        uint256 amount = 1200e18;
        comet.borrow(address(DAI), amount, 2, 0, address(this));
    }

    // Execute trades to force stop loss execution to occur
    function forceStopLoss(int24 triggerTick) internal {
        // Dump ETH past the tick trigger
        uint256 wethAmount = 20e18;
        deal(address(WETH), address(this), wethAmount);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: int256(wethAmount),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(poolKey, params, testSettings);

        (, int24 tick,) = manager.getSlot0(poolKey.toId());

        // Swap in the opposite direction of the trigger (trigger was sell ETH for Dai, zeroForOne = false)
        uint256 daiAmount = 5000e18;
        deal(address(DAI), address(this), daiAmount);

        params.zeroForOne = true;
        params.amountSpecified = int256(daiAmount);
        params.sqrtPriceLimitX96 = TickMath.MIN_SQRT_RATIO + 1;
        swapRouter.swap(poolKey, params, testSettings);
    }

    // -- Allow the test contract to receive ERC1155 tokens -- //
    receive() external payable {}

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"));
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"));
    }
}
