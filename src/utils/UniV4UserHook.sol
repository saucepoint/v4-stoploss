// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

abstract contract UniV4UserHook is BaseHook {
    using CurrencyLibrary for Currency;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    /**
     * @dev Swap tokens **owned** by the contract
     */
    function swap(IPoolManager.PoolKey memory key, IPoolManager.SwapParams memory params, address receiver)
        internal
        returns (BalanceDelta delta)
    {
        delta = abi.decode(poolManager.lock(abi.encodeCall(this.handleSwap, (key, params, receiver))), (BalanceDelta));

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    function modifyPosition(
        IPoolManager.PoolKey memory key,
        IPoolManager.ModifyPositionParams memory params,
        address caller
    ) internal returns (BalanceDelta delta) {
        delta = abi.decode(
            poolManager.lock(abi.encodeCall(this.handleModifyPosition, (key, params, caller))), (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(caller, ethBalance);
        }
    }

    function handleSwap(IPoolManager.PoolKey memory key, IPoolManager.SwapParams memory params, address sender)
        external
        returns (BalanceDelta delta)
    {
        delta = poolManager.swap(key, params);

        if (params.zeroForOne) {
            if (delta.amount0() > 0) {
                if (key.currency0.isNative()) {
                    poolManager.settle{value: uint128(delta.amount0())}(key.currency0);
                } else {
                    IERC20Minimal(Currency.unwrap(key.currency0)).transfer(
                        address(poolManager), uint128(delta.amount0())
                    );
                    poolManager.settle(key.currency0);
                }
            }
            if (delta.amount1() < 0) {
                poolManager.take(key.currency1, sender, uint128(-delta.amount1()));
            }
        } else {
            if (delta.amount1() > 0) {
                if (key.currency1.isNative()) {
                    poolManager.settle{value: uint128(delta.amount1())}(key.currency1);
                } else {
                    IERC20Minimal(Currency.unwrap(key.currency1)).transfer(
                        address(poolManager), uint128(delta.amount1())
                    );
                    poolManager.settle(key.currency1);
                }
            }
            if (delta.amount0() < 0) {
                poolManager.take(key.currency0, sender, uint128(-delta.amount0()));
            }
        }
    }

    function handleModifyPosition(
        IPoolManager.PoolKey memory key,
        IPoolManager.ModifyPositionParams memory params,
        address caller
    ) external returns (BalanceDelta delta) {
        delta = poolManager.modifyPosition(key, params);
        if (delta.amount0() > 0) {
            if (key.currency0.isNative()) {
                poolManager.settle{value: uint128(delta.amount0())}(key.currency0);
            } else {
                IERC20Minimal(Currency.unwrap(key.currency0)).transferFrom(
                    caller, address(poolManager), uint128(delta.amount0())
                );
                poolManager.settle(key.currency0);
            }
        }
        if (delta.amount1() > 0) {
            if (key.currency1.isNative()) {
                poolManager.settle{value: uint128(delta.amount1())}(key.currency1);
            } else {
                IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(
                    caller, address(poolManager), uint128(delta.amount1())
                );
                poolManager.settle(key.currency1);
            }
        }

        if (delta.amount0() < 0) {
            poolManager.take(key.currency0, caller, uint128(-delta.amount0()));
        }
        if (delta.amount1() < 0) {
            poolManager.take(key.currency1, caller, uint128(-delta.amount1()));
        }
    }
}
