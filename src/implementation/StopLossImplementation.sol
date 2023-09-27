// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {StopLoss} from "../StopLoss.sol";

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {GeomeanOracle} from "v4-periphery/hooks/examples/GeomeanOracle.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";

contract StopLossImplementation is StopLoss {
    constructor(IPoolManager poolManager, StopLoss addressToEtch, GeomeanOracle oracle) StopLoss(poolManager, oracle) {
        Hooks.validateHookAddress(addressToEtch, getHooksCalls());
    }

    // make this a no-op in testing
    function validateHookAddress(BaseHook _this) internal pure override {}
}
