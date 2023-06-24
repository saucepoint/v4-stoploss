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
import {IPool as ISparkPool} from "aave-v3-core/contracts/interfaces/IPool.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract SparkTest is Test, Deployers, GasSnapshot {
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

    ISparkPool sparkPool;
    IERC20 DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function setUp() public {
        // Create a V4 pool ETH/DAI at price 1700 DAI/ETH
        initV4();

        // Use 1 ETH to borrow 1500 DAI
        initSpark();
    }

    // Stop loss execution happens when theres a trade in the opposite direction
    // of the position. To test execution, we have a zeroForOne stop loss when
    // the tick price is less than 100. The pool by default is initialized to tick
    // price 0. Therefore, assume the pool had enough trades to move the tick price
    // below 100. On the next oneForZero trade, the stop loss should be executed.
    function test_sparkRepay() public {
        assertEq(WETH.balanceOf(address(this)), 0);
        assertEq(DAI.balanceOf(address(this)), 1200e18);
        
        // use borrowed Dai to buy ETH
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1200e18,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(poolKey, params, testSettings);
        // // ------------------- //
        
        // assertEq(DAI.balanceOf(address(this)), 0);
        // assertEq(WETH.balanceOf(address(this)) > 0.25e18, true);


        // create a stop loss: sell ETH for Dai if ETH trades for less than 1600

        // trigger the stop loss

        // claim the Dai

        // repay the Dai
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
        uint160 sqrtPriceX96 = 3266660825699135434887405499641;
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
        int24 lowerTick = TickMath.getTickAtSqrtRatio(2856612024059740072175611162719); // sqrt(1300e18) * 2**96
        int24 upperTick = TickMath.getTickAtSqrtRatio(3630690518938791291267782562922); // sqrt(2100e18) * 2**96
        lowerTick = lowerTick - (lowerTick % 60); // round down to multiple of tick spacing
        upperTick = upperTick - (upperTick % 60); // round down to multiple of tick spacing

        // random approximation, uses about 90 ETH
        int256 liquidity = 17e18; 
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(lowerTick, upperTick, liquidity));
        console.log(DAI.balanceOf(address(this)));

        // Approve for swapping
        DAI.approve(address(swapRouter), 2**128);
        WETH.approve(address(swapRouter), 2**128);

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
