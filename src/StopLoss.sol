// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {ERC1155} from "solmate/tokens/ERC1155.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {UniV4UserHook} from "./UniV4UserHook.sol";

contract StopLoss is UniV4UserHook, ERC1155 {
    using PoolId for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;

    uint256 public afterSwapCount;

    mapping(bytes32 poolId => int24 tickLower) public tickLowerLasts;
    mapping(bytes32 poolId => mapping(int24 tick => mapping(bool zeroForOne => uint256 amount))) public
        stopLossPositions;

    // TODO: populate on token minting
    mapping(uint256 tokenId => TokenIdData) public tokenIdIndex;
    mapping(uint256 tokenId => bool) public tokenIdExists;

    struct TokenIdData {
        IPoolManager.PoolKey poolKey;
        int24 tickLower;
        bool zeroForOne;
    }

    constructor(IPoolManager _poolManager) UniV4UserHook(_poolManager) {}

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: true,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function afterInitialize(address, IPoolManager.PoolKey calldata key, uint160, int24 tick)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        setTickLowerLast(key.toId(), getTickLower(tick, key.tickSpacing));
        return StopLoss.afterInitialize.selector;
    }

    function afterSwap(address, IPoolManager.PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta)
        external
        override
        returns (bytes4)
    {
        afterSwapCount++;
        return StopLoss.afterSwap.selector;
    }

    // -- Stop Loss User Facing Functions -- //
    function placeStopLoss(IPoolManager.PoolKey calldata poolKey, int24 tickLower, uint256 amountIn, bool zeroForOne)
        external
    {
        stopLossPositions[poolKey.toId()][tickLower][zeroForOne] += amountIn;

        // mint the receipt token
        uint256 tokenId = getTokenId(poolKey, tickLower, zeroForOne);
        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdIndex[tokenId] = TokenIdData({poolKey: poolKey, tickLower: tickLower, zeroForOne: zeroForOne});
        }
        _mint(msg.sender, tokenId, amountIn, "");
    }

    // TODO: implement, is out of scope for the hackathon
    function killStopLoss() external {}
    // ------------------------------------- //

    // -- 1155 -- //
    function uri(uint256) public pure override returns (string memory) {
        return "https://example.com";
    }

    function getTokenId(IPoolManager.PoolKey calldata poolKey, int24 tickLower, bool zeroForOne)
        public
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encodePacked(poolKey.toId(), tickLower, zeroForOne)));
    }

    function claimable(address user, uint256 tokenId) external view returns (uint256) {
        TokenIdData memory data = tokenIdIndex[tokenId];
        // zeroForOne = true means token0 was sold and token1 was bought
        // the stop loss position pays out token1
        address token =
            data.zeroForOne ? Currency.unwrap(data.poolKey.currency1) : Currency.unwrap(data.poolKey.currency0);
        return IERC20(token).balanceOf(user);
    }
    // ---------- //

    // -- Util functions -- //
    function setTickLowerLast(bytes32 poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function getTickLower(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity
        return compressed * tickSpacing;
    }
}
