// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/contracts/test/PoolDonateTest.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";

import {StopLoss} from "../../src/StopLoss.sol";
import {StopLossImplementation} from "../../src/implementation/StopLossImplementation.sol";
import {GeomeanOracle} from "v4-periphery/hooks/examples/GeomeanOracle.sol";
import {GeomeanOracleImplementation} from "v4-periphery/../test/shared/implementation/GeomeanOracleImplementation.sol";

contract StopLossTestBase is Test, Deployers {
    using PoolId for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;

    StopLoss hook = StopLoss(address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | 0x1)));
    GeomeanOracleImplementation oracle = GeomeanOracleImplementation(
        address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_MODIFY_POSITION_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | 0x2
            )
        )
    );
    PoolManager manager;
    PoolModifyPositionTest modifyPositionRouter;
    PoolSwapTest swapRouter;

    TestERC20 token0;
    TestERC20 token1;
    IPoolManager.PoolKey poolKey;
    IPoolManager.PoolKey oracleKey;
    bytes32 poolId;

    function initBase() public {
        uint256 amt = 2 ** 128;
        TestERC20 _tokenA = new TestERC20(amt);
        TestERC20 _tokenB = new TestERC20(amt);

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
        etchHook(address(oracle), address(new GeomeanOracleImplementation(manager, oracle)));
        etchHook(address(hook), address(new StopLossImplementation(manager, hook, GeomeanOracle(address(oracle)))));

        oracle.setTime(1);

        // Helpers for interacting with the pool
        modifyPositionRouter = new PoolModifyPositionTest(IPoolManager(address(manager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));

        // Provide liquidity to the pool
        token0.approve(address(modifyPositionRouter), amt);
        token1.approve(address(modifyPositionRouter), amt);

        // Approve for swapping
        token0.approve(address(swapRouter), amt);
        token1.approve(address(swapRouter), amt);
    }

    function createPool() internal {
        poolKey =
            IPoolManager.PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, IHooks(hook));
        poolId = PoolId.toId(poolKey);
        manager.initialize(poolKey, SQRT_RATIO_1_1);

        oracleKey = IPoolManager.PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            0,
            manager.MAX_TICK_SPACING(),
            IHooks(oracle)
        );
        manager.initialize(oracleKey, SQRT_RATIO_1_1);
    }

    function createLiquidity() internal {
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(-60, 60, 10 ether));
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(-120, 120, 10 ether));
        modifyPositionRouter.modifyPosition(
            poolKey, IPoolManager.ModifyPositionParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 50 ether)
        );

        modifyPositionRouter.modifyPosition(
            oracleKey,
            IPoolManager.ModifyPositionParams(
                TickMath.minUsableTick(manager.MAX_TICK_SPACING()),
                TickMath.maxUsableTick(manager.MAX_TICK_SPACING()),
                50 ether
            )
        );
    }

    // -- Test Helpers -- //
    function swap(IPoolManager.PoolKey memory key, int256 amountSpecified, bool zeroForOne) internal {
        // Perform a test swap //
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? hook.MIN_PRICE_LIMIT() : hook.MAX_PRICE_LIMIT() // unlimited impact
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(key, params, testSettings);
    }

    function etchHook(address _hook, address _implementation) public {
        // testing environment requires our contract to override `validateHookAddress`
        // well do that via the Implementation contract to avoid deploying the override with the production contract
        (, bytes32[] memory writes) = vm.accesses(address(_implementation));
        vm.etch(_hook, address(_implementation).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(_hook, slot, vm.load(address(_implementation), slot));
            }
        }
    }

    function observeMinuteTwap() internal view returns (int24) {
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = 60;
        secondsAgo[1] = 0;
        (int56[] memory tickCumulatives,) = oracle.observe(oracleKey, secondsAgo);
        int56 tickDiff = tickCumulatives[1] - tickCumulatives[0];
        return int24(tickDiff / 60);
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
