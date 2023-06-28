// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {Oracle} from "v4-periphery/libraries/Oracle.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";

/// @notice Add V3-style geometric mean oracle functionality to hook contracts
/// @dev The contract heavily borrows from https://github.com/Uniswap/v4-periphery/blob/main/contracts/hooks/examples/GeomeanOracle.sol
contract OracleState {
    using Oracle for Oracle.Observation[65535];
    using PoolId for IPoolManager.PoolKey;

    /// @member index The index of the last written observation for the pool
    /// @member cardinality The cardinality of the observations array for the pool
    /// @member cardinalityNext The cardinality target of the observations array for the pool, which will replace cardinality when enough observations are written
    struct ObservationState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    /// @notice The list of observations for a given pool ID
    mapping(bytes32 => Oracle.Observation[65535]) public observations;
    /// @notice The current observation array state for the given pool ID
    mapping(bytes32 => ObservationState) public states;

    /// @notice Returns the observation for the given pool key and observation index
    function getObservation(IPoolManager.PoolKey calldata key, uint256 index)
        external
        view
        returns (Oracle.Observation memory observation)
    {
        observation = observations[key.toId()][index];
    }

    function initialize(IPoolManager.PoolKey calldata key) internal {
        bytes32 poolId = key.toId();
        (states[poolId].cardinality, states[poolId].index) = observations[poolId].initialize(uint32(block.timestamp));
    }

    /// @dev Called before any action that potentially modifies pool price or liquidity, such as swap or modify position
    function _updatePool(IPoolManager poolManager, IPoolManager.PoolKey calldata key) internal {
        bytes32 id = key.toId();
        (, int24 tick,) = poolManager.getSlot0(id);

        uint128 liquidity = poolManager.getLiquidity(id);

        (states[id].index, states[id].cardinality) = observations[id].write(
            states[id].index,
            uint32(block.timestamp),
            tick,
            liquidity,
            states[id].cardinality,
            states[id].cardinalityNext
        );
    }

    /// @notice Observe the given pool for the timestamps
    function observe(IPoolManager poolManager, IPoolManager.PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        bytes32 id = key.toId();

        ObservationState memory state = states[id];

        (, int24 tick,) = poolManager.getSlot0(id);

        uint128 liquidity = poolManager.getLiquidity(id);

        return observations[id].observe(
            uint32(block.timestamp), secondsAgos, tick, state.index, liquidity, state.cardinality
        );
    }

    /// @notice Increase the cardinality target for the given pool
    function increaseCardinalityNext(IPoolManager.PoolKey calldata key, uint16 cardinalityNext)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew)
    {
        bytes32 id = key.toId();

        ObservationState storage state = states[id];

        cardinalityNextOld = state.cardinalityNext;
        cardinalityNextNew = observations[id].grow(cardinalityNextOld, cardinalityNext);
        state.cardinalityNext = cardinalityNextNew;
    }
}
